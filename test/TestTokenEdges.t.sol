// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TestToken} from "src/TestToken.sol";
import {MockFactory} from "./mocks/LaunchMocks.sol";

/// @dev A transfer must not call an ERC-20 recipient, even if it has a reverting fallback.
contract RejectingRecipient {
    fallback() external {
        revert("no callbacks");
    }
}

/// forge-config: default.fuzz.runs = 1000
contract TestTokenEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint64 internal constant LAUNCH = 42;
    MockFactory internal factory;
    TestToken internal token;
    address internal pool = makeAddr("edge pool");
    address internal distributor = makeAddr("edge distributor");
    address internal alice = makeAddr("edge alice");
    address internal bob = makeAddr("edge bob");
    address internal spender = makeAddr("edge spender");

    function setUp() public {
        factory = new MockFactory();
        token = factory.deploy(pool, LAUNCH);
        factory.setDistributor(LAUNCH, distributor);
    }

    function test_constructorCreditsCallerEvenWhenFactoryIsDifferent() public {
        TestToken other = new TestToken(address(factory), pool, type(uint64).max);
        assertEq(other.balanceOf(address(this)), SUPPLY);
        assertEq(other.balanceOf(address(factory)), 0);
        assertEq(other.totalSupply(), SUPPLY);
        factory.setDistributor(type(uint64).max, distributor);
        assertEq(other.launchDistributor(), distributor);
        assertEq(other.LAUNCH_NUMBER(), type(uint64).max);
    }

    function test_roundingBoundariesAndFullSupplyDirectAndDelegated() public {
        uint256[10] memory amounts = [uint256(0), 1, 98, 99, 100, 101, 199, 200, 201, SUPPLY];
        factory.move(token, alice, SUPPLY);
        for (uint256 i; i < amounts.length; ++i) {
            for (uint256 delegated; delegated < 2; ++delegated) {
                uint256 snap = vm.snapshotState();
                uint256 amount = amounts[i];
                if (delegated == 1) {
                    vm.prank(alice);
                    token.approve(spender, amount);
                }
                vm.recordLogs();
                if (delegated == 1) {
                    vm.prank(spender);
                    assertTrue(token.transferFrom(alice, bob, amount));
                    assertEq(token.allowance(alice, spender), 0);
                } else {
                    vm.prank(alice);
                    assertTrue(token.transfer(bob, amount));
                }
                _assertTransferLogs(vm.getRecordedLogs(), alice, bob, amount, amount / 100);
                assertEq(token.balanceOf(alice), SUPPLY - amount);
                assertEq(token.balanceOf(bob), amount - amount / 100);
                assertEq(token.balanceOf(spender), 0);
                assertEq(token.balanceOf(address(0)), 0);
                assertEq(token.totalSupply(), SUPPLY - amount / 100);
                assertTrue(vm.revertToStateAndDelete(snap));
            }
        }
    }

    function test_approvalOverwriteRevokeAndEventsDoNotMoveValue() public {
        factory.move(token, alice, 1_000);
        uint256[5] memory amounts = [uint256(500), 7, 7, type(uint256).max, 0];
        for (uint256 i; i < amounts.length; ++i) {
            vm.expectEmit(true, true, false, true, address(token));
            emit IERC20.Approval(alice, spender, amounts[i]);
            vm.prank(alice);
            assertTrue(token.approve(spender, amounts[i]));
            assertEq(token.allowance(alice, spender), amounts[i]);
            assertEq(token.allowance(spender, alice), 0);
            assertEq(token.balanceOf(alice), 1_000);
            assertEq(token.balanceOf(spender), 0);
            assertEq(token.totalSupply(), SUPPLY);
        }
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_infiniteAllowanceSurvivesRepeatedTransfersAndCanBeRevoked() public {
        factory.move(token, alice, 1_000);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        for (uint256 i; i < 5; ++i) {
            vm.prank(spender);
            assertTrue(token.transferFrom(alice, bob, 200));
            assertEq(token.allowance(alice, spender), type(uint256).max);
        }
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 990);
        assertEq(token.totalSupply(), SUPPLY - 10);
        vm.prank(alice);
        token.approve(spender, 0);
        assertEq(token.allowance(alice, spender), 0);
    }

    function test_transferFromSelfStillNeedsApproval() public {
        factory.move(token, alice, 1_000);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 100));
        token.transferFrom(alice, bob, 100);
        vm.prank(alice);
        token.approve(alice, 100);
        vm.prank(alice);
        assertTrue(token.transferFrom(alice, bob, 100));
        assertEq(token.allowance(alice, alice), 0);
        assertEq(token.balanceOf(alice), 900);
        assertEq(token.balanceOf(bob), 99);
    }

    function test_delegatedSelfTransferBurnsOnlyFeeButSpendsGrossAllowance() public {
        factory.move(token, alice, 1_000);
        vm.prank(alice);
        token.approve(spender, 1_000);
        vm.recordLogs();
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, alice, 1_000));
        _assertTransferLogs(vm.getRecordedLogs(), alice, alice, 1_000, 10);
        assertEq(token.balanceOf(alice), 990);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.totalSupply(), SUPPLY - 10);
    }

    function test_zeroTransfersFromEmptyHolderNeedNoAllowanceAndEmitTransfer() public {
        vm.recordLogs();
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        _assertTransferLogs(vm.getRecordedLogs(), alice, bob, 0, 0);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_exemptSpendersCannotSkipAnOrdinaryHoldersBurn() public {
        factory.move(token, alice, 300);
        address[3] memory callers = [address(factory), pool, distributor];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(alice);
            token.approve(callers[i], 100);
            vm.prank(callers[i]);
            assertTrue(token.transferFrom(alice, bob, 100));
            assertEq(token.allowance(alice, callers[i]), 0);
        }
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 297);
        assertEq(token.totalSupply(), SUPPLY - 3);
    }

    function test_exemptSpendersStillNeedAllowance() public {
        factory.move(token, alice, 100);
        address[3] memory callers = [address(factory), pool, distributor];
        for (uint256 i; i < callers.length; ++i) {
            bytes32 beforeState = _state(alice, bob, callers[i]);
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, callers[i], 0, 100)
            );
            token.transferFrom(alice, bob, 100);
            assertEq(_state(alice, bob, callers[i]), beforeState);
        }
    }

    function test_receivingAtFactoryOrDistributorDoesNotExemptOrdinarySender() public {
        factory.move(token, alice, 200);
        uint256 factoryBefore = token.balanceOf(address(factory));
        vm.prank(alice);
        token.transfer(address(factory), 100);
        vm.prank(alice);
        token.transfer(distributor, 100);
        assertEq(token.balanceOf(address(factory)), factoryBefore + 99);
        assertEq(token.balanceOf(distributor), 99);
        assertEq(token.totalSupply(), SUPPLY - 2);
    }

    function test_allLaunchFlowsEmitOnlyTheGrossTransfer() public {
        address[4] memory from = [address(factory), distributor, alice, bob];
        address[4] memory to = [bob, bob, pool, pool];
        factory.move(token, distributor, 100);
        factory.move(token, alice, 100);
        for (uint256 i; i < from.length; ++i) {
            vm.recordLogs();
            vm.prank(from[i]);
            assertTrue(token.transfer(to[i], 100));
            _assertTransferLogs(vm.getRecordedLogs(), from[i], to[i], 100, 0);
            assertEq(token.totalSupply(), SUPPLY);
        }
    }

    /// @dev The PoolManager is a permissionless singleton, so what leaves it (a buy, a take, a claim
    /// redemption) is an ordinary transfer: the burn and its events, exactly as for any holder.
    function test_transfersOutOfThePoolManagerBurnAndEmitTheBurn() public {
        factory.move(token, pool, 10_000);
        address[3] memory to = [bob, distributor, address(factory)];
        uint256 burned;
        for (uint256 i; i < to.length; ++i) {
            uint256 before = token.balanceOf(to[i]);
            vm.recordLogs();
            vm.prank(pool);
            assertTrue(token.transfer(to[i], 1_000));
            _assertTransferLogs(vm.getRecordedLogs(), pool, to[i], 1_000, 10);
            assertEq(token.balanceOf(to[i]), before + 990);
            burned += 10;
        }
        // Into itself is the one outgoing leg that is still exempt, because it is also an incoming one.
        vm.recordLogs();
        vm.prank(pool);
        assertTrue(token.transfer(pool, 1_000));
        _assertTransferLogs(vm.getRecordedLogs(), pool, pool, 1_000, 0);
        assertEq(token.balanceOf(pool), 7_000);
        assertEq(token.totalSupply(), SUPPLY - burned);
    }

    function test_poolManagerSpendingAHoldersAllowanceIntoItselfIsWhole() public {
        factory.move(token, alice, 1_000);
        vm.prank(alice);
        token.approve(pool, 1_000);
        vm.prank(pool);
        assertTrue(token.transferFrom(alice, pool, 1_000));
        assertEq(token.balanceOf(pool), 1_000);
        assertEq(token.allowance(alice, pool), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_distributorReplacementRevokesOldExemptionImmediately() public {
        factory.move(token, distributor, 200);
        factory.move(token, alice, 200);
        factory.setDistributor(LAUNCH + 1, spender);
        factory.setDistributor(LAUNCH, alice);
        assertEq(token.launchDistributor(), alice);
        vm.prank(distributor);
        token.transfer(bob, 100);
        vm.prank(alice);
        token.transfer(bob, 100);
        assertEq(token.balanceOf(bob), 199);
        factory.setDistributor(LAUNCH, address(0));
        vm.prank(alice);
        token.transfer(bob, 100);
        assertEq(token.balanceOf(bob), 298);
        assertEq(token.totalSupply(), SUPPLY - 2);
    }

    function test_recipientContractCannotRejectAnERC20Transfer() public {
        factory.move(token, alice, 100);
        RejectingRecipient recipient = new RejectingRecipient();
        vm.prank(alice);
        assertTrue(token.transfer(address(recipient), 100));
        assertEq(token.balanceOf(address(recipient)), 99);
        assertEq(token.totalSupply(), SUPPLY - 1);
    }

    function test_zeroSpenderApprovalRevertsEvenForZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        assertEq(token.allowance(alice, address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroCallerCannotApproveOrTransfer() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.approve(spender, 0);
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        token.transfer(alice, 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroRecipientRejectedForEveryExemptionIncludingZeroAmount() public {
        address[4] memory senders = [address(factory), distributor, pool, alice];
        for (uint256 i; i < senders.length; ++i) {
            bytes32 beforeState = _state(senders[i], address(0), spender);
            vm.prank(senders[i]);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            token.transfer(address(0), 0);
            assertEq(_state(senders[i], address(0), spender), beforeState);
        }
    }

    function test_insufficientBalanceRevertsForExemptSourcesToo() public {
        address[3] memory sources = [address(factory), distributor, pool];
        for (uint256 i; i < sources.length; ++i) {
            uint256 balance = token.balanceOf(sources[i]);
            bytes32 beforeState = _state(sources[i], bob, spender);
            vm.prank(sources[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, sources[i], balance, balance + 1)
            );
            token.transfer(bob, balance + 1);
            assertEq(_state(sources[i], bob, spender), beforeState);
        }
    }

    function test_maximumTransferAmountRejectsBalanceBeforeBurnArithmetic() public {
        factory.move(token, alice, SUPPLY);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        bytes memory errorData =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, SUPPLY, type(uint256).max);
        bytes32 beforeState = _state(alice, bob, spender);
        vm.prank(alice);
        vm.expectRevert(errorData);
        token.transfer(bob, type(uint256).max);
        vm.prank(spender);
        vm.expectRevert(errorData);
        token.transferFrom(alice, bob, type(uint256).max);
        assertEq(_state(alice, bob, spender), beforeState);
    }

    function testFuzz_failedTransferFromRestoresAllowanceOnBalanceFailure(uint256 funded, uint256 excess) public {
        funded = bound(funded, 0, SUPPLY);
        uint256 amount = funded + bound(excess, 1, SUPPLY);
        factory.move(token, alice, funded);
        vm.prank(alice);
        token.approve(spender, amount);
        bytes32 beforeState = _state(alice, bob, spender);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, funded, amount));
        token.transferFrom(alice, bob, amount);
        assertEq(_state(alice, bob, spender), beforeState, "failed call changed balances, supply or allowance");
    }

    function testFuzz_failedTransferFromRestoresAllowanceOnInvalidReceiver(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        factory.move(token, alice, amount);
        vm.prank(alice);
        token.approve(spender, amount);
        bytes32 beforeState = _state(alice, address(0), spender);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), amount);
        assertEq(_state(alice, address(0), spender), beforeState);
    }

    function testFuzz_shortAllowanceCannotDebitOrBurn(uint256 amount, uint256 allowed) public {
        amount = bound(amount, 1, SUPPLY);
        allowed = bound(allowed, 0, amount - 1);
        factory.move(token, alice, amount);
        vm.prank(alice);
        token.approve(spender, allowed);
        bytes32 beforeState = _state(alice, bob, spender);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        token.transferFrom(alice, bob, amount);
        assertEq(_state(alice, bob, spender), beforeState);
    }

    function testFuzz_transferAndTransferFromHaveIdenticalEconomicEffects(uint256 amount, bool self) public {
        amount = bound(amount, 0, SUPPLY);
        address to = self ? alice : bob;
        factory.move(token, alice, SUPPLY);
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(alice);
        assertTrue(token.transfer(to, amount));
        bytes32 directLogs = keccak256(abi.encode(vm.getRecordedLogs()));
        bytes32 directState = _state(alice, to, spender);
        assertTrue(vm.revertToStateAndDelete(snap));
        vm.prank(alice);
        token.approve(spender, amount);
        vm.recordLogs();
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, to, amount));
        assertEq(keccak256(abi.encode(vm.getRecordedLogs())), directLogs);
        assertEq(_state(alice, to, spender), directState);
    }

    function testFuzz_roundTripLosesExactlyTheTwoBurns(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        factory.move(token, alice, amount);
        vm.prank(alice);
        token.transfer(bob, amount);
        uint256 firstReceipt = token.balanceOf(bob);
        assertEq(firstReceipt, amount - amount / 100);
        vm.prank(bob);
        token.transfer(alice, firstReceipt);
        uint256 loss = amount / 100 + firstReceipt / 100;
        assertEq(token.balanceOf(alice) + loss, amount);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply() + loss, SUPPLY);
    }

    function testFuzz_splitTransferRoundingSavesAtMostOneMinorUnit(uint256 amount, uint256 first) public {
        amount = bound(amount, 0, SUPPLY);
        first = bound(first, 0, amount);
        factory.move(token, alice, amount);
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        token.transfer(bob, amount);
        uint256 singleReceipt = token.balanceOf(bob);
        uint256 singleSupply = token.totalSupply();
        assertTrue(vm.revertToStateAndDelete(snap));
        vm.startPrank(alice);
        token.transfer(bob, first);
        token.transfer(bob, amount - first);
        vm.stopPrank();
        assertGe(token.balanceOf(bob), singleReceipt);
        assertLe(token.balanceOf(bob) - singleReceipt, 1);
        assertEq(token.totalSupply() - singleSupply, token.balanceOf(bob) - singleReceipt);
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_burnQuoteMonotonicAndPeriod100(uint256 amount, uint256 delta) public view {
        amount = bound(amount, 0, SUPPLY - 100);
        delta = bound(delta, 0, 100);
        uint256 beforeBurn = token.burnOn(amount);
        assertGe(token.burnOn(amount + delta), beforeBurn);
        assertLe(token.burnOn(amount + delta) - beforeBurn, 1);
        assertEq(token.burnOn(amount + 100), beforeBurn + 1);
    }

    function _state(address from, address to, address operator) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.totalSupply(),
                token.balanceOf(from),
                token.balanceOf(to),
                token.balanceOf(operator),
                token.balanceOf(address(factory)),
                token.balanceOf(pool),
                token.balanceOf(distributor),
                token.balanceOf(address(0)),
                token.allowance(from, operator)
            )
        );
    }

    function _assertTransferLogs(Vm.Log[] memory logs, address from, address to, uint256 gross, uint256 burned)
        internal
        view
    {
        assertEq(logs.length, burned == 0 ? 1 : 3, "unexpected transfer/burn event count");
        if (burned != 0) {
            _assertTransferLog(logs[0], from, address(0), burned);
            assertEq(logs[1].emitter, address(token));
            assertEq(logs[1].topics.length, 3);
            assertEq(logs[1].topics[0], keccak256("TransferBurned(address,address,uint256,uint256)"));
            assertEq(logs[1].topics[1], bytes32(uint256(uint160(from))));
            assertEq(logs[1].topics[2], bytes32(uint256(uint160(to))));
            assertEq(logs[1].data, abi.encode(gross, burned));
        }
        _assertTransferLog(logs[logs.length - 1], from, to, gross - burned);
    }

    function _assertTransferLog(Vm.Log memory entry, address from, address to, uint256 amount) internal view {
        assertEq(entry.emitter, address(token));
        assertEq(entry.topics.length, 3);
        assertEq(entry.topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(entry.topics[1], bytes32(uint256(uint160(from))));
        assertEq(entry.topics[2], bytes32(uint256(uint160(to))));
        assertEq(entry.data, abi.encode(amount));
    }
}
