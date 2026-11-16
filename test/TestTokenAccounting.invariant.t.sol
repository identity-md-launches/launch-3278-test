// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TestToken} from "src/TestToken.sol";
import {MockFactory} from "./mocks/LaunchMocks.sol";

/// @dev Expected state comes only from submitted inputs and the specified economics. In particular,
/// neither balanceOf, allowance, burnOn nor isBurnExempt is used to construct expected transitions.
contract TokenAccountingHandler is Test {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000e18;
    uint64 public constant LAUNCH = 73;
    TestToken public immutable token;
    MockFactory public immutable factory;
    address public immutable pool;
    address[] public actors;
    address public expectedDistributor;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public expectedBurned;
    uint256 public positiveTransfers;
    uint256 public expectedRejections;
    uint256 public lastSupply;
    bool public unexpectedOutcome;
    bool public supplyIncreased;

    constructor(TestToken token_, MockFactory factory_, address pool_) {
        token = token_;
        factory = factory_;
        pool = pool_;
        actors.push(address(factory_));
        actors.push(pool_);
        actors.push(makeAddr("accounting distributor A"));
        actors.push(makeAddr("accounting distributor B"));
        actors.push(makeAddr("accounting alice"));
        actors.push(makeAddr("accounting bob"));
        actors.push(makeAddr("accounting spender"));
        expectedDistributor = actors[2];
        factory.setDistributor(LAUNCH, expectedDistributor);
        expectedBalance[address(factory)] = INITIAL_SUPPLY;
        // Seed all roles so the early random calls exercise real value transfers.
        for (uint256 i = 1; i < actors.length; ++i) {
            uint256 amount = INITIAL_SUPPLY / 20;
            factory.move(token, actors[i], amount);
            expectedBalance[actors[i]] = amount;
            expectedBalance[address(factory)] -= amount;
        }
        lastSupply = INITIAL_SUPPLY;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 raw, uint8 mode) external {
        address from = _actor(fromSeed);
        _move(from, from, _recipient(toSeed), _amount(raw, expectedBalance[from], mode), false);
    }

    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        _move(from, from, _actor(toSeed), expectedBalance[from], false);
    }

    function transferToSelf(uint256 fromSeed, uint256 raw) external {
        address from = _actor(fromSeed);
        _move(from, from, from, bound(raw, 0, expectedBalance[from]), false);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 raw, uint8 mode) external {
        uint256 amount = mode % 3 == 0 ? 0 : mode % 3 == 1 ? type(uint256).max : raw;
        _approve(_actor(ownerSeed), _recipient(spenderSeed), amount);
    }

    /// @dev Uses approvals left by previous random calls; never grants an allowance here.
    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 raw, uint8 mode) external {
        address owner = _actor(ownerSeed);
        address operator = _actor(spenderSeed);
        uint256 available = expectedBalance[owner];
        if (expectedAllowance[owner][operator] < available) available = expectedAllowance[owner][operator];
        _move(operator, owner, _recipient(toSeed), _amount(raw, available, mode), true);
    }

    /// @dev Guarantees additional successful delegated paths without replacing the independent
    /// approval/spending actions above. Some allowance remains for subsequent calls to consume.
    function approveAndSpend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 raw, bool infinite)
        external
    {
        address owner = _actor(ownerSeed);
        address operator = _actor(spenderSeed);
        uint256 balance = expectedBalance[owner];
        _approve(owner, operator, infinite ? type(uint256).max : balance);
        _move(operator, owner, _actor(toSeed), bound(raw, 0, balance), true);
    }

    function revokeAndAttemptSpend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed) external {
        address owner = _actor(ownerSeed);
        address operator = _actor(spenderSeed);
        _approve(owner, operator, 0);
        _move(operator, owner, _actor(toSeed), 1, true);
    }

    function transferFromToZero(uint256 ownerSeed, uint256 spenderSeed, uint256 raw) external {
        address owner = _actor(ownerSeed);
        address operator = _actor(spenderSeed);
        uint256 amount = bound(raw, 0, expectedBalance[owner]);
        _approve(owner, operator, amount);
        _move(operator, owner, address(0), amount, true);
    }

    function registerDistributor(uint256 seed) external {
        expectedDistributor = seed % 4 == 0 ? address(0) : actors[2 + seed % 3];
        factory.setDistributor(LAUNCH, expectedDistributor);
        _checkSupply();
    }

    function registerOtherLaunch(uint256 seed) external {
        factory.setDistributor(LAUNCH + 1, _recipient(seed));
        _checkSupply();
    }

    function _approve(address owner, address operator, uint256 amount) private {
        bytes memory errorData;
        if (operator == address(0)) {
            errorData = abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0));
        }
        _call(owner, abi.encodeCall(token.approve, (operator, amount)), errorData);
        if (errorData.length == 0) expectedAllowance[owner][operator] = amount;
        _checkSupply();
    }

    function _move(address operator, address from, address to, uint256 amount, bool delegated) private {
        uint256 allowed = expectedAllowance[from][operator];
        bytes memory errorData;
        if (delegated && allowed < amount) {
            errorData =
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, operator, allowed, amount);
        } else if (to == address(0)) {
            errorData = abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0));
        } else if (expectedBalance[from] < amount) {
            errorData = abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, from, expectedBalance[from], amount
            );
        }
        bytes memory data = delegated
            ? abi.encodeCall(token.transferFrom, (from, to, amount))
            : abi.encodeCall(token.transfer, (to, amount));
        _call(operator, data, errorData);
        if (errorData.length == 0) {
            bool exempt = from == address(factory) || from == pool || to == pool || from == expectedDistributor;
            uint256 burned = exempt ? 0 : amount / 100;
            expectedBalance[from] -= amount;
            expectedBalance[to] += amount - burned; // Also correct when from == to.
            expectedBurned += burned;
            if (delegated && allowed != type(uint256).max) expectedAllowance[from][operator] -= amount;
            if (amount != 0) ++positiveTransfers;
        }
        _checkSupply();
    }

    /// @dev A persistent flag makes an unexpected revert fail an invariant even when Foundry's
    /// default fail_on_revert is false. Expected failures must match the full custom error.
    function _call(address caller, bytes memory data, bytes memory expectedError) private {
        vm.prank(caller);
        (bool ok, bytes memory returned) = address(token).call(data);
        if (expectedError.length == 0) {
            if (!ok || keccak256(returned) != keccak256(abi.encode(true))) unexpectedOutcome = true;
        } else {
            ++expectedRejections;
            if (ok || keccak256(returned) != keccak256(expectedError)) unexpectedOutcome = true;
        }
    }

    function _checkSupply() private {
        uint256 actualSupply = token.totalSupply();
        if (actualSupply > lastSupply) supplyIncreased = true;
        lastSupply = actualSupply;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _recipient(uint256 seed) private view returns (address) {
        uint256 index = seed % (actors.length + 1);
        return index == actors.length ? address(0) : actors[index];
    }

    function _amount(uint256 raw, uint256 available, uint8 mode) private pure returns (uint256) {
        uint256 choice = mode % 8;
        if (choice == 0) return 0;
        if (choice == 1) return 1;
        if (choice == 2) return 99;
        if (choice == 3) return 100;
        if (choice == 4) return available;
        if (choice == 5) return available + 1;
        if (choice == 6) return type(uint256).max;
        return bound(raw, 0, available);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
contract TestTokenAccountingInvariantTest is Test {
    TestToken internal token;
    TokenAccountingHandler internal handler;

    function setUp() public {
        MockFactory factory = new MockFactory();
        address pool = makeAddr("accounting pool");
        token = factory.deploy(pool, 73);
        handler = new TokenAccountingHandler(token, factory, pool);
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferAll.selector;
        selectors[2] = handler.transferToSelf.selector;
        selectors[3] = handler.approve.selector;
        selectors[4] = handler.transferFrom.selector;
        selectors[5] = handler.approveAndSpend.selector;
        selectors[6] = handler.revokeAndAttemptSpend.selector;
        selectors[7] = handler.transferFromToZero.selector;
        selectors[8] = handler.registerDistributor.selector;
        selectors[9] = handler.registerOtherLaunch.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_allBalancesMatchIndependentLedgerAndSupply() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "actor balance diverged");
            sum += token.balanceOf(actor);
        }
        assertEq(sum, token.totalSupply(), "balances do not sum to supply");
        assertEq(token.totalSupply() + handler.expectedBurned(), 1_000_000_000e18, "burn conservation failed");
        assertEq(token.balanceOf(address(0)), 0, "burned tokens credited to zero");
    }

    function invariant_allowancesMatchIndependentApprovalHistory() public view {
        for (uint256 i; i < handler.actorCount(); ++i) {
            address owner = handler.actors(i);
            assertEq(token.allowance(owner, address(0)), 0);
            for (uint256 j; j < handler.actorCount(); ++j) {
                address operator = handler.actors(j);
                assertEq(
                    token.allowance(owner, operator), handler.expectedAllowance(owner, operator), "allowance diverged"
                );
            }
        }
    }

    function invariant_outcomesSupplyAndDistributorRemainCorrect() public view {
        assertFalse(handler.unexpectedOutcome(), "unexpected success, revert, error data or return value");
        assertFalse(handler.supplyIncreased(), "supply increased during a sequence");
        assertEq(token.launchDistributor(), handler.expectedDistributor());
        assertEq(token.FACTORY(), address(handler.factory()));
        assertEq(token.POOL_MANAGER(), handler.pool());
        assertEq(token.LAUNCH_NUMBER(), 73);
    }

    /// @dev Pins a nonvacuous sequence alongside the randomized campaign, including all action
    /// selectors, repeated allowance use, a failed debit, a burn and a changing distributor.
    function test_modelSequenceExercisesSuccessfulAndRejectedCalls() public {
        handler.approve(4, 6, 500, 2);
        handler.transferFrom(4, 6, 5, 0, 3); // Spend 100 of the existing 500 approval.
        handler.transferFrom(4, 6, 4, 0, 3); // Delegated self-transfer also spends 100.
        handler.revokeAndAttemptSpend(4, 6, 5);
        handler.transferFromToZero(4, 6, 100);
        handler.approveAndSpend(4, 6, 5, 200, true);
        handler.transferFrom(4, 6, 5, 0, 3);
        handler.transfer(4, 5, 0, 6); // uint256.max must be a balance error, not a panic.
        handler.transfer(4, 5, 0, 2); // Dust has no burn.
        handler.transferToSelf(5, 100);
        handler.registerDistributor(1); // Replace distributor A with B.
        handler.transfer(2, 5, 0, 3); // The old distributor now burns.
        handler.transfer(3, 5, 0, 3); // The new distributor remains exempt.
        handler.registerOtherLaunch(4);
        handler.transferAll(5, 4);
        assertGt(handler.positiveTransfers(), 0);
        assertGt(handler.expectedRejections(), 0);
        assertGt(handler.expectedBurned(), 0);
        invariant_allBalancesMatchIndependentLedgerAndSupply();
        invariant_allowancesMatchIndependentApprovalHistory();
        invariant_outcomesSupplyAndDistributorRemainCorrect();
    }
}
