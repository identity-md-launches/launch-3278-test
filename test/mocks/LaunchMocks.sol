// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestToken} from "../../src/TestToken.sol";

/// @notice Stands in for the launch factory: deploys the token so that it is the constructor's
/// caller and holds the supply, records the distributor, and sends tokens as the factory does.
contract MockFactory {
    mapping(uint64 => address) public distributorOf;

    function deploy(address poolManager, uint64 launchNumber) external returns (TestToken) {
        return new TestToken(address(this), poolManager, launchNumber);
    }

    function setDistributor(uint64 launchNumber, address distributor) external {
        distributorOf[launchNumber] = distributor;
    }

    function move(TestToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice A factory whose distributor lookup reverts.
contract RevertingFactory {
    function distributorOf(uint64) external pure returns (address) {
        revert("no");
    }
}

/// @notice A factory whose distributor lookup answers with fewer than 32 bytes.
contract ShortAnswerFactory {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 0x01)
            return(0, 1)
        }
    }
}

/// @notice A factory whose distributor lookup does a tunable amount of work before answering, to
/// show that the token's answer does not depend on the gas the caller sent.
contract ExpensiveLookupFactory {
    address public immutable distributor;
    uint256 public immutable iterations;

    constructor(address distributor_, uint256 iterations_) {
        distributor = distributor_;
        iterations = iterations_;
    }

    function deploy(address poolManager, uint64 launchNumber) external returns (TestToken) {
        return new TestToken(address(this), poolManager, launchNumber);
    }

    function move(TestToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function distributorOf(uint64) external view returns (address) {
        bytes32 h;
        for (uint256 i; i < iterations; ++i) {
            h = keccak256(abi.encode(h, i));
        }
        // Never true; keeps the loop from being optimised away.
        if (h == bytes32(uint256(1))) return address(0);
        return distributor;
    }
}

/// @notice A factory whose distributor lookup never finishes: it burns whatever gas it is given.
contract GasGuzzlingFactory {
    function distributorOf(uint64) external pure returns (address) {
        uint256 i;
        while (true) {
            ++i;
        }
        return address(uint160(i));
    }
}

/// @notice A factory whose distributor lookup answers with a very large payload.
contract ReturnBombFactory {
    fallback() external {
        assembly ("memory-safe") {
            return(0, 0x100000)
        }
    }
}

interface IUnlockCallbackLike {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @notice The ERC-20 side of Uniswap v4's PoolManager flash accounting, reduced to what the tests
/// use: unlock() runs the caller's callback and requires every delta settled; sync() snapshots the
/// manager's balance; settle() credits the caller with what arrived since; take() debits the caller
/// and transfers to any recipient. No pool is involved and nothing here charges a fee.
contract FlashAccountingManager {
    address private syncedCurrency;
    uint256 private syncedReserves;
    bool private unlocked;
    uint256 private nonzeroDeltas;
    mapping(address => mapping(address => int256)) private deltaOf;

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(!unlocked, "AlreadyUnlocked");
        unlocked = true;
        result = IUnlockCallbackLike(msg.sender).unlockCallback(data);
        require(nonzeroDeltas == 0, "CurrencyNotSettled");
        unlocked = false;
    }

    function sync(address currency) external {
        syncedCurrency = currency;
        syncedReserves = TestToken(currency).balanceOf(address(this));
    }

    function settle() external returns (uint256 paid) {
        require(unlocked, "ManagerLocked");
        address currency = syncedCurrency;
        paid = TestToken(currency).balanceOf(address(this)) - syncedReserves;
        syncedCurrency = address(0);
        _account(msg.sender, currency, int256(paid));
    }

    function take(address currency, address to, uint256 amount) external {
        require(unlocked, "ManagerLocked");
        _account(msg.sender, currency, -int256(amount));
        TestToken(currency).transfer(to, amount);
    }

    function _account(address locker, address currency, int256 change) private {
        int256 before = deltaOf[locker][currency];
        int256 next = before + change;
        if (before == 0 && next != 0) ++nonzeroDeltas;
        else if (before != 0 && next == 0) --nonzeroDeltas;
        deltaOf[locker][currency] = next;
    }
}

/// @notice What any holder could deploy: moves TEST from its caller to anyone by paying it into the
/// pool manager and taking it straight back out in one unlock, touching no pool.
contract PoolManagerRelay is IUnlockCallbackLike {
    FlashAccountingManager private immutable manager;
    TestToken private immutable token;

    constructor(FlashAccountingManager manager_, TestToken token_) {
        manager = manager_;
        token = token_;
    }

    function send(address to, uint256 amount) external {
        manager.unlock(abi.encode(msg.sender, to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the manager");
        (address from, address to, uint256 amount) = abi.decode(data, (address, address, uint256));
        manager.sync(address(token));
        token.transferFrom(from, address(manager), amount);
        manager.settle();
        manager.take(address(token), to, amount);
        return "";
    }
}
