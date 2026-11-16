// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TestToken} from "../src/TestToken.sol";
import {MockFactory, RevertingFactory, ShortAnswerFactory} from "./mocks/LaunchMocks.sol";

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

    function test_transfersFromPoolManagerAreWhole() public {
        factory.move(token, poolManager, 1_000e18);
        vm.prank(poolManager);
        token.transfer(alice, 1_000e18);
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_seedAndRoundTripSwapMoveExactAmounts() public {
        // Seed: factory -> pool manager.
        uint256 seed = (SUPPLY * 9_000) / 10_000;
        factory.move(token, poolManager, seed);
        assertEq(token.balanceOf(poolManager), seed);
        // Buy: pool manager -> trader.
        vm.prank(poolManager);
        token.transfer(alice, 5_000e18);
        assertEq(token.balanceOf(alice), 5_000e18);
        // Sell: trader -> pool manager.
        vm.prank(alice);
        token.transfer(poolManager, 5_000e18);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(poolManager), seed);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_isBurnExemptMatchesTheRules() public {
        factory.setDistributor(LAUNCH, distributor);
        assertTrue(token.isBurnExempt(address(factory), alice));
        assertTrue(token.isBurnExempt(poolManager, alice));
        assertTrue(token.isBurnExempt(alice, poolManager));
        assertTrue(token.isBurnExempt(distributor, alice));
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
