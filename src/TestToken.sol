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
/// - transfers to or from the Uniswap v4 PoolManager (buys and sells against the launch pool).
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

    /// @notice The Uniswap v4 PoolManager. Transfers to or from it are never burned.
    address public immutable POOL_MANAGER;

    /// @notice This launch's number, the key under which the factory records its distributor.
    uint64 public immutable LAUNCH_NUMBER;

    /// @notice Emitted alongside the ERC-20 events whenever an ordinary transfer burns part of its amount.
    event TransferBurned(address indexed from, address indexed to, uint256 amount, uint256 burned);

    /// @notice The launch factory address must be set.
    error FactoryIsZero();

    /// @notice The PoolManager address must be set.
    error PoolManagerIsZero();

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
    /// minor units burn nothing.
    function burnOn(uint256 amount) public pure returns (uint256) {
        return (amount * BURN_BPS) / BPS_DENOMINATOR;
    }

    /// @notice This launch's MerkleDistributor as the factory currently records it, or the zero
    /// address when the factory has not recorded one, has no code, or does not answer.
    /// @dev A failed or malformed answer is treated as "no distributor" rather than reverting, so a
    /// factory that misbehaves can never block ordinary transfers.
    function launchDistributor() public view returns (address) {
        (bool ok, bytes memory data) =
            FACTORY.staticcall(abi.encodeWithSelector(ILaunchFactory.distributorOf.selector, LAUNCH_NUMBER));
        if (!ok || data.length < 32) return address(0);
        // The word is decoded as an integer and truncated on purpose: a well-formed answer has its
        // upper 96 bits clear, and a malformed one must not revert the transfer.
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(abi.decode(data, (uint256))));
    }

    /// @notice Whether a transfer from `from` to `to` is one of the launch flows that skip the burn.
    function isBurnExempt(address from, address to) public view returns (bool) {
        if (from == FACTORY || from == POOL_MANAGER || to == POOL_MANAGER) return true;
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
