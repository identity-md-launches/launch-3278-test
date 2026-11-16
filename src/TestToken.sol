// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The one view of the launch factory this token reads: the MerkleDistributor of a launch.
interface ILaunchFactory {
    function distributorOf(uint64 launchNumber) external view returns (address);
}

/// @title Test (TEST)
/// @notice A fixed-supply ERC-20 that burns 1% of every ordinary transfer.
/// @dev The whole supply (1,000,000,000 TEST, 18 decimals) is minted once, in the constructor, to the
/// deployer. Nothing can mint afterwards: there is no owner, no minter, no pause, no blacklist and no
/// upgrade path, so the supply can only ever shrink.
///
/// The burn is skipped for the launch's own flows so that each of them moves exactly what it says:
/// - transfers sent by the launch factory (the swarm share to the distributor, the seed to the pool);
/// - transfers sent by the launch's MerkleDistributor (contributor claims);
/// - transfers INTO the Uniswap v4 PoolManager (the seed and sells into the launch pool, which the
///   manager's settle() needs to arrive whole).
/// Transfers OUT of the PoolManager are not exempt: the manager is a permissionless singleton whose
/// flash accounting (unlock/sync/settle/take) lets anyone pay tokens in and take them straight out
/// again, so exempting its outgoing leg would make the burn optional for every holder. Instead the
/// burn is paid once, when tokens leave the manager: a buy delivers 99% of what the pool pays out, and
/// a relay or an ERC-6909 claim redemption pays the same 1% as a direct transfer.
/// Every other transfer, including one made by an address that received tokens through an exempt
/// flow, pays the burn. The burn is taken from the sender: the recipient receives 99% of the amount
/// and the remaining 1% leaves the supply.
contract TestToken is ERC20 {
    /// @notice The whole supply, minted once to the deployer: 1,000,000,000 TEST in minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice The burn rate on ordinary transfers, in basis points (100 = 1%).
    uint256 public constant BURN_BPS = 100;

    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice The launch factory. Its own transfers are never burned, and it names the distributor.
    address public immutable FACTORY;

    /// @notice The Uniswap v4 PoolManager. Transfers into it are never burned; transfers out of it are.
    address public immutable POOL_MANAGER;

    /// @notice The gas the distributor lookup forwards to the factory. A mapping getter, also behind a
    /// proxy, needs a few thousand; the rest is headroom. Fixed so that the lookup's answer never
    /// depends on how much gas the caller sent, and so that a misbehaving factory can cost an
    /// ordinary transfer at most this much.
    uint256 public constant LOOKUP_GAS = 50_000;

    /// @dev What must be left before the lookup so the factory really receives LOOKUP_GAS (EIP-150
    /// forwards at most 63/64 of what is left) plus the call's own overhead.
    uint256 private constant LOOKUP_GAS_REQUIRED = LOOKUP_GAS + LOOKUP_GAS / 63 + 5_000;

    /// @notice This launch's number, the key under which the factory records its distributor.
    uint64 public immutable LAUNCH_NUMBER;

    /// @notice Emitted alongside the ERC-20 events whenever an ordinary transfer burns part of its amount.
    event TransferBurned(address indexed from, address indexed to, uint256 amount, uint256 burned);

    /// @notice The launch factory address must be set.
    error FactoryIsZero();

    /// @notice The PoolManager address must be set.
    error PoolManagerIsZero();

    /// @notice The call did not have enough gas left to run the distributor lookup in full. It reverts
    /// rather than treating the unfinished lookup as "no distributor" and burning the transfer.
    error LookupOutOfGas();

    /// @param factory_ The launch factory (the manifest's $factory). The constructor's caller.
    /// @param poolManager_ The chain's Uniswap v4 PoolManager (the manifest's $poolManager).
    /// @param launchNumber_ This launch's number (the manifest's $launchNumber).
    constructor(address factory_, address poolManager_, uint64 launchNumber_) ERC20("Test", "TEST") {
        if (factory_ == address(0)) revert FactoryIsZero();
        if (poolManager_ == address(0)) revert PoolManagerIsZero();
        FACTORY = factory_;
        POOL_MANAGER = poolManager_;
        LAUNCH_NUMBER = launchNumber_;
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice How much of `amount` an ordinary transfer burns. Rounds down, so amounts below 100
    /// minor units burn nothing. Defined for every uint256: the whole and the remainder are scaled
    /// separately so the intermediate product cannot overflow, and the result equals
    /// floor(amount * BURN_BPS / BPS_DENOMINATOR).
    function burnOn(uint256 amount) public pure returns (uint256) {
        // forge-lint: disable-next-line(divide-before-multiply)
        return (amount / BPS_DENOMINATOR) * BURN_BPS + ((amount % BPS_DENOMINATOR) * BURN_BPS) / BPS_DENOMINATOR;
    }

    /// @notice This launch's MerkleDistributor as the factory currently records it, or the zero
    /// address when the factory has not recorded one, has no code, or does not answer within
    /// LOOKUP_GAS.
    /// @dev A revert, a codeless factory or a malformed answer is treated as "no distributor" rather
    /// than reverting, so a factory that misbehaves can never block ordinary transfers. The lookup
    /// always forwards exactly LOOKUP_GAS, so its answer is the same at every gas limit the caller
    /// might send; if the caller has not left enough gas for that, the call reverts with
    /// LookupOutOfGas instead of burning a transfer the full lookup would have exempted.
    function launchDistributor() public view returns (address) {
        if (gasleft() < LOOKUP_GAS_REQUIRED) revert LookupOutOfGas();
        bytes memory callData = abi.encodeWithSelector(ILaunchFactory.distributorOf.selector, LAUNCH_NUMBER);
        address factory = FACTORY;
        uint256 lookupGas = LOOKUP_GAS;
        bool ok;
        uint256 answerSize;
        uint256 word;
        // Only the first word of the answer is copied (into the scratch space), so a factory that
        // returns a huge payload cannot make the transfer pay for copying it.
        assembly ("memory-safe") {
            ok := staticcall(lookupGas, factory, add(callData, 32), mload(callData), 0, 32)
            answerSize := returndatasize()
            word := mload(0)
        }
        if (!ok || answerSize < 32) return address(0);
        // The word is decoded as an integer and truncated on purpose: a well-formed answer has its
        // upper 96 bits clear, and a malformed one must not revert the transfer.
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(word));
    }

    /// @notice Whether a transfer from `from` to `to` is one of the launch flows that skip the burn:
    /// sent by the factory, sent by the registered distributor, or sent into the PoolManager.
    function isBurnExempt(address from, address to) public view returns (bool) {
        if (from == FACTORY || to == POOL_MANAGER) return true;
        address distributor = launchDistributor();
        return distributor != address(0) && from == distributor;
    }

    /// @dev Mints and burns pass through untouched. Exempt flows move the full amount. Everything
    /// else burns `burnOn(value)` from the sender and delivers the rest.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || isBurnExempt(from, to)) {
            super._update(from, to, value);
            return;
        }
        // Check the whole debit first, so a shortfall is reported against the amount sent rather
        // than against what is left after the burn step.
        uint256 fromBalance = balanceOf(from);
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        uint256 burned = burnOn(value);
        if (burned != 0) {
            super._update(from, address(0), burned);
            emit TransferBurned(from, to, value, burned);
        }
        super._update(from, to, value - burned);
    }
}
