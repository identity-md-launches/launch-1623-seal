// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SealToken} from "../src/SealToken.sol";

/// @title Deploy script for seal (SEAL)
/// @notice The token takes no constructor arguments, so deployment has no configuration beyond the
///         broadcasting account, which receives the whole supply. The IMD launch deploys the token
///         through its factory from the built bytecode; this script exists for local and manual
///         deployments and for tests, which call `deploy()` directly.
contract DeploySealToken is Script {
    /// @notice Deploys the token. Whoever calls this (the broadcaster under `run()`) receives the supply.
    function deploy() public returns (SealToken token) {
        token = new SealToken();
    }

    /// @notice Entry point for `forge script`. Reads nothing from the environment.
    function run() external returns (SealToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
