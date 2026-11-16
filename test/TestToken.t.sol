// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TestToken} from "../src/TestToken.sol";
import {
    MockFactory,
    RevertingFactory,
    ShortAnswerFactory,
    ExpensiveLookupFactory,
    GasGuzzlingFactory,
    ReturnBombFactory,
    FlashAccountingManager,
    PoolManagerRelay
} from "./mocks/LaunchMocks.sol";

contract TestTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint64 constant LAUNCH = 42;

    MockFactory factory;
    TestToken token;

    address poolManager = makeAddr("poolManager");
    address distributor = makeAddr("distributor");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        factory = new MockFactory();
        token = factory.deploy(poolManager, LAUNCH);
    }

    // ----------------------------------------------------------------- metadata and construction

    function test_metadata() public view {
        assertEq(token.name(), "Test");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 18);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.BURN_BPS(), 100);
        assertEq(token.BPS_DENOMINATOR(), 10_000);
        assertEq(token.FACTORY(), address(factory));
        assertEq(token.POOL_MANAGER(), poolManager);
        assertEq(token.LAUNCH_NUMBER(), LAUNCH);
    }

    function test_constructorMintsWholeSupplyToDeployerOnce() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
    }

    function test_constructorEmitsMintTransfer() public {
        MockFactory other = new MockFactory();
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), address(other), SUPPLY);
        other.deploy(poolManager, LAUNCH);
    }

    function test_constructorRejectsZeroFactory() public {
        vm.expectRevert(TestToken.FactoryIsZero.selector);
        new TestToken(address(0), poolManager, LAUNCH);
    }

    function test_constructorRejectsZeroPoolManager() public {
        vm.expectRevert(TestToken.PoolManagerIsZero.selector);
        new TestToken(address(factory), address(0), LAUNCH);
    }

    function test_constructorAcceptsLaunchNumberZero() public {
        TestToken t = new TestToken(address(factory), poolManager, 0);
        assertEq(t.LAUNCH_NUMBER(), 0);
        assertEq(t.balanceOf(address(this)), SUPPLY);
    }

    // ---------------------------------------------------------------------------- burn math

    function test_burnOnIsOnePercentRoundedDown() public view {
        assertEq(token.burnOn(10_000), 100);
        assertEq(token.burnOn(100), 1);
        assertEq(token.burnOn(99), 0);
        assertEq(token.burnOn(1), 0);
        assertEq(token.burnOn(0), 0);
        assertEq(token.burnOn(1e18), 1e16);
        assertEq(token.burnOn(SUPPLY), SUPPLY / 100);
    }

    function testFuzz_burnOnNeverExceedsOnePercent(uint256 amount) public view {
        amount = bound(amount, 0, SUPPLY);
        uint256 burned = token.burnOn(amount);
        assertEq(burned, amount / 100);
        assertLe(burned * 100, amount);
    }

    function test_burnOnIsDefinedForEveryAmount() public view {
        uint256 max = type(uint256).max;
        assertEq(token.burnOn(max), max / 100);
        assertEq(token.burnOn(max - 1), (max - 1) / 100);
        assertEq(token.burnOn(max / 100 + 1), (max / 100 + 1) / 100);
        assertEq(token.burnOn(1e75), 1e73);
    }

    function testFuzz_burnOnIsOnePercentOverTheWholeDomain(uint256 amount) public view {
        assertEq(token.burnOn(amount), amount / 100);
    }

    // ------------------------------------------------------------------- ordinary transfers burn

    function test_ordinaryTransferBurnsOnePercent() public {
        _fund(alice, 1_000e18);
        uint256 supplyBefore = token.totalSupply();

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, address(0), 1e18);
        vm.expectEmit(true, true, true, true);
        emit TestToken.TransferBurned(alice, bob, 100e18, 1e18);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, bob, 99e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100e18));

        assertEq(token.balanceOf(alice), 900e18, "sender pays the full amount");
        assertEq(token.balanceOf(bob), 99e18, "recipient gets 99%");
        assertEq(token.totalSupply(), supplyBefore - 1e18, "1% left the supply");
    }

    function test_ordinaryTransferFromBurnsOnePercentAndSpendsFullAllowance() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        token.approve(carol, 200e18);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(carol);
        assertTrue(token.transferFrom(alice, bob, 200e18));

        assertEq(token.balanceOf(alice), 800e18);
        assertEq(token.balanceOf(bob), 198e18);
        assertEq(token.balanceOf(carol), 0, "the spender receives nothing");
        assertEq(token.allowance(alice, carol), 0, "allowance is spent by the full amount");
        assertEq(token.totalSupply(), supplyBefore - 2e18);
    }

    function test_dustTransferBurnsNothing() public {
        _fund(alice, 1_000e18);
        uint256 supplyBefore = token.totalSupply();
        vm.prank(alice);
        token.transfer(bob, 99);
        assertEq(token.balanceOf(bob), 99);
        assertEq(token.totalSupply(), supplyBefore);
    }

    function test_transferToSelfStillBurns() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        token.transfer(alice, 100e18);
        assertEq(token.balanceOf(alice), 999e18);
    }

    function test_zeroAmountTransferSucceedsWithoutBurn() public {
        _fund(alice, 1e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 1e18);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_whoeverReceivedAnExemptTransferPaysTheBurnOnward() public {
        factory.setDistributor(LAUNCH, distributor);
        factory.move(token, distributor, 1_000e18);
        vm.prank(distributor);
        token.transfer(alice, 1_000e18);
        assertEq(token.balanceOf(alice), 1_000e18, "claim arrived whole");

        vm.prank(alice);
        token.transfer(bob, 1_000e18);
        assertEq(token.balanceOf(bob), 990e18, "the claimant's own transfer is burned");
    }

    function testFuzz_ordinaryTransferConservesAmount(uint256 funded, uint256 amount) public {
        funded = bound(funded, 1, SUPPLY / 2);
        amount = bound(amount, 0, funded);
        _fund(alice, funded);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        token.transfer(bob, amount);

        uint256 burned = amount / 100;
        assertEq(token.balanceOf(alice), funded - amount);
        assertEq(token.balanceOf(bob), amount - burned);
        assertEq(token.totalSupply(), supplyBefore - burned);
        assertEq(token.balanceOf(bob) + burned, amount, "received plus burned is the amount sent");
    }

    // ------------------------------------------------------------------- launch flows are whole

    function test_factoryTransfersAreWhole() public {
        uint256 swarm = SUPPLY / 10;
        assertTrue(factory.move(token, distributor, swarm));
        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(address(factory)), SUPPLY - swarm);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_factoryTransferFromIsWhole() public {
        vm.prank(address(factory));
        token.approve(carol, 500e18);
        vm.prank(carol);
        token.transferFrom(address(factory), bob, 500e18);
        assertEq(token.balanceOf(bob), 500e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_distributorTransfersAreWholeOnceRegistered() public {
        factory.setDistributor(LAUNCH, distributor);
        assertEq(token.launchDistributor(), distributor);
        factory.move(token, distributor, 1_000e18);

        vm.prank(distributor);
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_unregisteredDistributorIsNotExempt() public {
        assertEq(token.launchDistributor(), address(0));
        factory.move(token, distributor, 1_000e18);
        vm.prank(distributor);
        token.transfer(alice, 1_000e18);
        assertEq(token.balanceOf(alice), 990e18);
    }

    function test_distributorOfAnotherLaunchIsNotExempt() public {
        factory.setDistributor(LAUNCH + 1, distributor);
        factory.move(token, distributor, 1_000e18);
        vm.prank(distributor);
        token.transfer(alice, 1_000e18);
        assertEq(token.balanceOf(alice), 990e18);
    }

    function test_transfersToPoolManagerAreWhole() public {
        _fund(alice, 1_000e18);
        vm.prank(alice);
        token.transfer(poolManager, 1_000e18);
        assertEq(token.balanceOf(poolManager), 1_000e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transfersFromPoolManagerPayTheBurn() public {
        // The manager's outgoing leg is an ordinary transfer: the manager is debited the full amount
        // and the recipient receives 99%. This is what stops a pay-in/take-out relay through the
        // manager's flash accounting from moving tokens burn-free.
        factory.move(token, poolManager, 1_000e18);
        vm.expectEmit(true, true, true, true);
        emit TestToken.TransferBurned(poolManager, alice, 1_000e18, 10e18);
        vm.prank(poolManager);
        token.transfer(alice, 1_000e18);
        assertEq(token.balanceOf(alice), 990e18);
        assertEq(token.balanceOf(poolManager), 0);
        assertEq(token.totalSupply(), SUPPLY - 10e18);
    }

    function test_seedAndRoundTripSwapSettleExactly() public {
        // Seed: factory -> pool manager, whole.
        uint256 seed = (SUPPLY * 9_000) / 10_000;
        factory.move(token, poolManager, seed);
        assertEq(token.balanceOf(poolManager), seed);
        // Buy: the pool pays out 5,000 TEST; the manager is debited exactly that (its delta
        // accounting is unaffected) and the trader receives 99% of it.
        vm.prank(poolManager);
        token.transfer(alice, 5_000e18);
        assertEq(token.balanceOf(alice), 4_950e18);
        assertEq(token.balanceOf(poolManager), seed - 5_000e18);
        // Sell: the trader pays its whole balance into the manager and it arrives whole, so
        // settle() credits exactly what the swap debits.
        vm.prank(alice);
        token.transfer(poolManager, 4_950e18);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(poolManager), seed - 50e18);
        assertEq(token.totalSupply(), SUPPLY - 50e18, "the only burn is the one on the buy");
    }

    function test_relayThroughThePoolManagerStillPaysTheBurn() public {
        // The real PoolManager is permissionless: anyone may unlock it, pay TEST in (exempt, so
        // settle() credits the full amount) and take it straight out to any recipient. The burn is
        // paid on the way out, so the relay delivers exactly what a direct transfer would.
        FlashAccountingManager manager = new FlashAccountingManager();
        MockFactory f = new MockFactory();
        TestToken t = f.deploy(address(manager), LAUNCH);
        f.move(t, alice, 1_000_000e18);
        PoolManagerRelay relay = new PoolManagerRelay(manager, t);
        uint256 supplyBefore = t.totalSupply();

        vm.startPrank(alice);
        t.approve(address(relay), 100_000e18);
        vm.expectEmit(true, true, true, true);
        emit TestToken.TransferBurned(address(manager), bob, 100_000e18, 1_000e18);
        relay.send(bob, 100_000e18);
        vm.stopPrank();

        assertEq(t.balanceOf(alice), 900_000e18, "alice is debited the amount");
        assertEq(t.balanceOf(address(manager)), 0, "nothing stays in the manager");
        assertEq(t.balanceOf(bob), 99_000e18, "bob receives 99%, as from a direct transfer");
        assertEq(t.totalSupply(), supplyBefore - 1_000e18, "1% left the supply");
    }

    function test_isBurnExemptMatchesTheRules() public {
        factory.setDistributor(LAUNCH, distributor);
        assertTrue(token.isBurnExempt(address(factory), alice));
        assertTrue(token.isBurnExempt(alice, poolManager));
        assertTrue(token.isBurnExempt(address(factory), poolManager));
        assertTrue(token.isBurnExempt(distributor, alice));
        assertFalse(token.isBurnExempt(poolManager, alice), "the manager's outgoing leg pays the burn");
        assertFalse(token.isBurnExempt(alice, bob));
        assertFalse(token.isBurnExempt(alice, address(factory)));
        assertFalse(token.isBurnExempt(alice, distributor));
    }

    // -------------------------------------------------------------- distributor lookup robustness

    function test_factoryWithoutCodeDoesNotBlockTransfers() public {
        address bare = makeAddr("bareFactory");
        TestToken t = new TestToken(bare, poolManager, LAUNCH);
        assertEq(t.launchDistributor(), address(0));
        assertTrue(t.transfer(alice, 100e18));
        assertEq(t.balanceOf(alice), 99e18);
    }

    function test_revertingFactoryDoesNotBlockTransfers() public {
        TestToken t = new TestToken(address(new RevertingFactory()), poolManager, LAUNCH);
        assertEq(t.launchDistributor(), address(0));
        assertTrue(t.transfer(alice, 100e18));
        assertEq(t.balanceOf(alice), 99e18);
    }

    function test_shortAnswerFactoryDoesNotBlockTransfers() public {
        TestToken t = new TestToken(address(new ShortAnswerFactory()), poolManager, LAUNCH);
        assertEq(t.launchDistributor(), address(0));
        assertTrue(t.transfer(alice, 100e18));
        assertEq(t.balanceOf(alice), 99e18);
    }

    function test_returnBombFactoryDoesNotBlockTransfers() public {
        TestToken t = new TestToken(address(new ReturnBombFactory()), poolManager, LAUNCH);
        assertEq(t.launchDistributor(), address(0));
        uint256 gasBefore = gasleft();
        assertTrue(t.transfer(alice, 100e18));
        assertLt(gasBefore - gasleft(), 200_000, "the oversized answer is not copied");
        assertEq(t.balanceOf(alice), 99e18);
    }

    function test_gasGuzzlingFactoryCostsAtMostLookupGasAndDoesNotBlockTransfers() public {
        TestToken t = new TestToken(address(new GasGuzzlingFactory()), poolManager, LAUNCH);
        uint256 gasBefore = gasleft();
        assertEq(t.launchDistributor(), address(0));
        uint256 used = gasBefore - gasleft();
        assertGe(used, t.LOOKUP_GAS(), "the factory burned the whole stipend");
        assertLt(used, t.LOOKUP_GAS() + 20_000, "and nothing beyond it");
        assertTrue(t.transfer(alice, 100e18));
        assertEq(t.balanceOf(alice), 99e18);
    }

    // ------------------------------------------------- lookup result is independent of the gas limit

    /// @dev A wallet sends about what eth_estimateGas returns, the lowest limit that does not revert.
    /// The lookup forwards a fixed stipend, so at that limit it answers exactly as it does with gas
    /// to spare: the distributor's claim arrives whole, never burned for lack of gas.
    function test_distributorClaimAtWalletGasArrivesWholeWithAnExpensiveLookup() public {
        // About 28k gas of work in the lookup: ten times a getter, within LOOKUP_GAS.
        _checkClaimIsIdenticalAtWalletGasAndWithGasToSpare(120, true);
    }

    function test_distributorClaimAtWalletGasArrivesWholeWithAGetterLookup() public {
        _checkClaimIsIdenticalAtWalletGasAndWithGasToSpare(0, true);
    }

    /// @dev A lookup that cannot finish within LOOKUP_GAS is "no distributor" at every gas limit,
    /// so the outcome is the same whether the wallet sends the estimate or much more.
    function test_lookupBeyondTheStipendIsNoDistributorAtEveryGasLimit() public {
        _checkClaimIsIdenticalAtWalletGasAndWithGasToSpare(5_000, false);
    }

    function test_launchDistributorRevertsRatherThanAnsweringShortOfGas() public {
        factory.setDistributor(LAUNCH, distributor);
        // Enough gas for the call to start, not enough for the stipend to be forwarded whole.
        (bool ok, bytes memory data) =
            address(token).call{gas: 45_000}(abi.encodeWithSelector(token.launchDistributor.selector));
        assertFalse(ok, "the lookup must not answer when it cannot run in full");
        assertEq(bytes4(data), TestToken.LookupOutOfGas.selector);
    }

    function test_transferShortOfLookupGasRevertsInsteadOfBurningTheClaim() public {
        factory.setDistributor(LAUNCH, distributor);
        factory.move(token, distributor, 1_000e18);
        uint256 supplyBefore = token.totalSupply();
        // Enough gas for the transfer itself, not enough to forward the lookup's full stipend.
        vm.prank(distributor);
        (bool ok, bytes memory data) =
            address(token).call{gas: 52_000}(abi.encodeWithSelector(token.transfer.selector, alice, 100e18));
        assertFalse(ok, "a transfer that cannot run the lookup reverts");
        assertEq(bytes4(data), TestToken.LookupOutOfGas.selector);
        assertEq(token.balanceOf(distributor), 1_000e18);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), supplyBefore, "nothing was burned");
    }

    function _checkClaimIsIdenticalAtWalletGasAndWithGasToSpare(uint256 iterations, bool expectExempt) internal {
        ExpensiveLookupFactory f = new ExpensiveLookupFactory(distributor, iterations);
        TestToken t = f.deploy(poolManager, LAUNCH);
        f.move(t, distributor, 1_000e18);
        bytes memory data = abi.encodeWithSelector(t.transfer.selector, alice, 100e18);

        // The lowest gas limit at which the claim does not revert: what a wallet would send.
        uint256 lo = 21_000;
        uint256 hi = 2_000_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snapshot = vm.snapshotState();
            vm.prank(distributor);
            (bool ok,) = address(t).call{gas: mid}(data);
            vm.revertToState(snapshot);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
        uint256 walletGas = lo;
        assertLt(walletGas, 2_000_000, "the claim never succeeded");

        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(distributor);
        (bool okAtWalletGas, bytes memory retAtWalletGas) = address(t).call{gas: walletGas}(data);
        bytes32 logsAtWalletGas = keccak256(abi.encode(vm.getRecordedLogs()));
        uint256 aliceAtWalletGas = t.balanceOf(alice);
        uint256 supplyAtWalletGas = t.totalSupply();
        vm.revertToState(snap);

        vm.recordLogs();
        vm.prank(distributor);
        (bool okWithSpare, bytes memory retWithSpare) = address(t).call{gas: 16_000_000}(data);
        bytes32 logsWithSpare = keccak256(abi.encode(vm.getRecordedLogs()));

        assertTrue(okAtWalletGas && okWithSpare);
        assertEq(retAtWalletGas, retWithSpare, "at a wallet's gas the call returns something else");
        assertEq(logsAtWalletGas, logsWithSpare, "at a wallet's gas the call emits different events");
        assertEq(aliceAtWalletGas, t.balanceOf(alice), "at a wallet's gas the recipient gets a different amount");
        assertEq(supplyAtWalletGas, t.totalSupply(), "at a wallet's gas the supply changes differently");
        if (expectExempt) {
            assertEq(t.balanceOf(alice), 100e18, "the claim arrived whole");
            assertEq(t.totalSupply(), SUPPLY, "nothing was burned");
        } else {
            assertEq(t.balanceOf(alice), 99e18, "the unresolved distributor is taxed like anyone");
            assertEq(t.totalSupply(), SUPPLY - 1e18);
        }
    }

    // ------------------------------------------------------------------------- failure paths

    function test_transferRevertsOnInsufficientBalance() public {
        _fund(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 100e18, 100e18 + 1)
        );
        token.transfer(bob, 100e18 + 1);
    }

    function test_transferRevertsWhenBurnWouldExceedBalance() public {
        // The sender is debited the full amount, burn included, so a balance that covers only the
        // delivered 99% is not enough.
        _fund(alice, 99e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 99e18, 100e18));
        token.transfer(bob, 100e18);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        _fund(alice, 100e18);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 0, 1e18));
        token.transferFrom(alice, bob, 1e18);
    }

    function test_transferFromRevertsWhenAllowanceCoversOnlyTheNetAmount() public {
        _fund(alice, 100e18);
        vm.prank(alice);
        token.approve(carol, 99e18);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 99e18, 100e18));
        token.transferFrom(alice, bob, 100e18);
    }

    function test_transferToZeroAddressReverts() public {
        _fund(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1e18);
    }

    function test_strangerCannotMoveTheFactorySupply() public {
        vm.prank(alice);
        vm.expectRevert();
        token.transferFrom(address(factory), alice, 1);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
    }

    function test_noMintOrAdminEntryPoints() public {
        _fund(alice, 100e18);
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "issue(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "setFeeExempt(address,bool)",
            "setBurnBps(uint256)",
            "upgradeTo(address)"
        ];
        address[2] memory callers = [bob, address(factory)];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < signatures.length; ++i) {
                bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 100e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 1e18), "the holder can still transfer");
    }

    // ------------------------------------------------------------------------------ helpers

    /// @dev Funds `who` through the exempt factory flow so the balance equals `amount` exactly.
    function _fund(address who, uint256 amount) internal {
        factory.move(token, who, amount);
        assertEq(token.balanceOf(who), amount);
    }
}
