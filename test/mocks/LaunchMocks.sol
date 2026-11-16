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
