// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WalletGas} from "./helpers/WalletGas.sol";
import {TestToken} from "src/TestToken.sol";
import {MockFactory, RevertingFactory, ShortAnswerFactory} from "./mocks/LaunchMocks.sol";

/// @dev transfer and transferFrom both reach the caught staticcall in launchDistributor.
contract TestTokenWalletGasTest is WalletGas {
    MockFactory internal factory;
    TestToken internal token;
    address internal pool = makeAddr("wallet-gas pool");
    address internal distributor = makeAddr("wallet-gas distributor");
    address internal alice = makeAddr("wallet-gas alice");
    address internal bob = makeAddr("wallet-gas bob");
    address internal spender = makeAddr("wallet-gas spender");

    function setUp() public {
        factory = new MockFactory();
        token = factory.deploy(pool, 42);
        factory.setDistributor(42, distributor);
        factory.move(token, alice, 1_000e18);
        factory.move(token, distributor, 1_000e18);
        factory.move(token, pool, 1_000e18);
    }

    function test_walletGasOrdinaryTransfer() public {
        assertSameAtWalletGas(alice, address(token), abi.encodeCall(token.transfer, (bob, 100e18)));
    }

    function test_walletGasSelfTransfer() public {
        assertSameAtWalletGas(alice, address(token), abi.encodeCall(token.transfer, (alice, 100e18)));
    }

    function test_walletGasZeroAndDustTransfers() public {
        assertSameAtWalletGas(bob, address(token), abi.encodeCall(token.transfer, (alice, 0)));
        assertSameAtWalletGas(alice, address(token), abi.encodeCall(token.transfer, (bob, 99)));
    }

    function test_walletGasTransferFromFiniteAndInfiniteAllowance() public {
        vm.prank(alice);
        token.approve(spender, 100e18);
        bytes memory data = abi.encodeCall(token.transferFrom, (alice, bob, 100e18));
        assertSameAtWalletGas(spender, address(token), data);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        assertSameAtWalletGas(spender, address(token), data);
    }

    function test_walletGasDistributorTransferAndTransferFrom() public {
        assertSameAtWalletGas(distributor, address(token), abi.encodeCall(token.transfer, (bob, 100e18)));
        vm.prank(distributor);
        token.approve(spender, 100e18);
        assertSameAtWalletGas(spender, address(token), abi.encodeCall(token.transferFrom, (distributor, bob, 100e18)));
    }

    function test_walletGasFactoryAndPoolTransfers() public {
        assertSameAtWalletGas(address(factory), address(token), abi.encodeCall(token.transfer, (bob, 100e18)));
        assertSameAtWalletGas(pool, address(token), abi.encodeCall(token.transfer, (bob, 100e18)));
        assertSameAtWalletGas(alice, address(token), abi.encodeCall(token.transfer, (pool, 100e18)));
    }

    function test_walletGasUnregisteredDistributor() public {
        factory.setDistributor(42, address(0));
        assertSameAtWalletGas(distributor, address(token), abi.encodeCall(token.transfer, (bob, 100e18)));
    }

    function test_walletGasLookupAndExemptionViews() public {
        assertSameAtWalletGas(alice, address(token), abi.encodeCall(token.launchDistributor, ()));
        assertSameAtWalletGas(alice, address(token), abi.encodeCall(token.isBurnExempt, (distributor, bob)));
        assertSameAtWalletGas(alice, address(token), abi.encodeCall(token.isBurnExempt, (alice, bob)));
    }

    function test_walletGasRevertingFactory() public {
        _checkUnavailableFactory(address(new RevertingFactory()));
    }

    function test_walletGasShortAnswerFactory() public {
        _checkUnavailableFactory(address(new ShortAnswerFactory()));
    }

    function test_walletGasCodelessFactory() public {
        _checkUnavailableFactory(makeAddr("wallet-gas codeless factory"));
    }

    function _checkUnavailableFactory(address factoryAddress) internal {
        TestToken other = new TestToken(factoryAddress, pool, 42);
        assertSameAtWalletGas(address(this), address(other), abi.encodeCall(other.transfer, (bob, 100e18)));
        other.approve(spender, 100e18);
        assertSameAtWalletGas(spender, address(other), abi.encodeCall(other.transferFrom, (address(this), bob, 100e18)));
    }
}
