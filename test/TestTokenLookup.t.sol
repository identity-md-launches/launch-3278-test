// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestToken, ILaunchFactory} from "src/TestToken.sol";
import {MockFactory} from "./mocks/LaunchMocks.sol";

/// forge-config: default.fuzz.runs = 1000
contract TestTokenLookupTest is Test {
    MockFactory internal factory;
    TestToken internal token;
    address internal pool = makeAddr("lookup pool");
    address internal distributor = makeAddr("lookup distributor");
    address internal alice = makeAddr("lookup alice");
    address internal bob = makeAddr("lookup bob");
    uint64 internal constant LAUNCH = type(uint64).max;

    function setUp() public {
        factory = new MockFactory();
        token = factory.deploy(pool, LAUNCH);
        factory.setDistributor(LAUNCH, distributor);
        factory.move(token, alice, 1_000);
        factory.move(token, distributor, 1_000);
    }

    function test_lookupUsesExactSelectorAndFullLaunchNumber() public {
        bytes memory request = abi.encodeCall(ILaunchFactory.distributorOf, (LAUNCH));
        vm.expectCall(address(factory), request);
        assertEq(token.launchDistributor(), distributor);
        assertEq(token.LAUNCH_NUMBER(), type(uint64).max);
    }

    function testFuzz_allShortAnswerLengthsFailClosed(uint8 rawLength, bytes32 rawAnswer) public {
        uint256 length = bound(rawLength, 0, 31);
        bytes memory answer = new bytes(length);
        for (uint256 i; i < length; ++i) {
            answer[i] = rawAnswer[i];
        }
        vm.mockCall(address(factory), abi.encodeCall(ILaunchFactory.distributorOf, (LAUNCH)), answer);
        assertEq(token.launchDistributor(), address(0));
        assertFalse(token.isBurnExempt(distributor, bob));
        vm.prank(distributor);
        assertTrue(token.transfer(bob, 100));
        assertEq(token.balanceOf(distributor), 900);
        assertEq(token.balanceOf(bob), 99);
        assertEq(token.totalSupply(), 1_000_000_000e18 - 1);
    }

    function testFuzz_canonicalAddressAnswerIsDecodedExactly(address result) public {
        vm.mockCall(address(factory), abi.encodeCall(ILaunchFactory.distributorOf, (LAUNCH)), abi.encode(result));
        assertEq(token.launchDistributor(), result);
    }

    function testFuzz_revertDataCannotBeMistakenForADistributor(bytes32 noise) public {
        // Even an ABI-sized revert payload beginning with a plausible address is not an answer.
        vm.mockCallRevert(
            address(factory), abi.encodeCall(ILaunchFactory.distributorOf, (LAUNCH)), abi.encode(distributor, noise)
        );
        assertEq(token.launchDistributor(), address(0));
        vm.prank(distributor);
        assertTrue(token.transfer(bob, 100));
        assertEq(token.balanceOf(bob), 99);
        assertEq(token.totalSupply(), 1_000_000_000e18 - 1);
    }

    function test_lookupFailureDoesNotAffectFactoryOrPoolFlows() public {
        vm.mockCallRevert(address(factory), abi.encodeCall(ILaunchFactory.distributorOf, (LAUNCH)), "");
        assertTrue(factory.move(token, bob, 100));
        vm.prank(alice);
        assertTrue(token.transfer(pool, 100));
        assertEq(token.balanceOf(pool), 100);
        assertEq(token.totalSupply(), 1_000_000_000e18);
        // Out of the PoolManager is an ordinary transfer whether or not the lookup answers.
        vm.prank(pool);
        assertTrue(token.transfer(bob, 100));
        assertEq(token.balanceOf(bob), 199);
        assertEq(token.balanceOf(pool), 0);
        assertEq(token.totalSupply(), 1_000_000_000e18 - 1);
    }

    function test_recoveredLookupRestoresClaimsWithoutPersistingAnExemption() public {
        bytes memory request = abi.encodeCall(ILaunchFactory.distributorOf, (LAUNCH));
        vm.mockCallRevert(address(factory), request, "unavailable");
        vm.prank(distributor);
        token.transfer(bob, 100);
        vm.clearMockedCalls();
        vm.prank(distributor);
        token.transfer(bob, 100);
        assertEq(token.balanceOf(bob), 199);
        assertEq(token.totalSupply(), 1_000_000_000e18 - 1);
        // Recovery grants the distributor exemption, never its recipients.
        vm.prank(bob);
        token.transfer(alice, 100);
        assertEq(token.balanceOf(bob), 99);
        assertEq(token.balanceOf(alice), 1_099);
        assertEq(token.totalSupply(), 1_000_000_000e18 - 2);
    }
}
