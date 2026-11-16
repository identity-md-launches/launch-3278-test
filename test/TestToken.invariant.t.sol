// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../src/TestToken.sol";
import {MockFactory} from "./mocks/LaunchMocks.sol";

/// @notice Drives the token with random transfers from a small cast of actors, launch addresses
/// included, and records what every ordinary transfer should have burned.
contract TokenHandler is Test {
    TestToken public immutable token;
    MockFactory public immutable factory;
    address public immutable poolManager;
    address public immutable distributor;

    address[] public actors;
    uint256 public expectedBurned;

    constructor(TestToken token_, MockFactory factory_, address poolManager_, address distributor_) {
        token = token_;
        factory = factory_;
        poolManager = poolManager_;
        distributor = distributor_;
        actors.push(address(factory_));
        actors.push(poolManager_);
        actors.push(distributor_);
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        if (!_expectedExemption(from, to)) expectedBurned += amount / 100;
        vm.prank(from);
        token.transfer(to, amount);
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.approve(spender, amount);
        if (!_expectedExemption(from, to)) expectedBurned += amount / 100;
        vm.prank(spender);
        token.transferFrom(from, to, amount);
    }

    function registerDistributor(bool registered) external {
        factory.setDistributor(token.LAUNCH_NUMBER(), registered ? distributor : address(0));
    }

    // The oracle must not ask the token how much to burn or whom to exempt.
    function _expectedExemption(address from, address to) internal view returns (bool) {
        // Transfers out of the PoolManager are ordinary: only transfers into it are exempt.
        return from == address(factory) || to == poolManager || from == factory.distributorOf(token.LAUNCH_NUMBER());
    }
}

contract TestTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint64 constant LAUNCH = 7;

    TestToken token;
    TokenHandler handler;

    function setUp() public {
        MockFactory factory = new MockFactory();
        address poolManager = makeAddr("poolManager");
        address distributor = makeAddr("distributor");
        token = factory.deploy(poolManager, LAUNCH);
        handler = new TokenHandler(token, factory, poolManager, distributor);
        targetContract(address(handler));
    }

    function invariant_supplyNeverGrows() public view {
        assertLe(token.totalSupply(), SUPPLY);
    }

    function invariant_supplyIsInitialMinusBurns() public view {
        assertEq(token.totalSupply(), SUPPLY - handler.expectedBurned());
    }

    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply());
    }
}
