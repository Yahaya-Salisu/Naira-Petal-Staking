// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import {NairaPetalStaking} from "../src/NairaPetalStaking.sol";

contract DeployNairaPetal {
    NairaPetalStaking public nairaPetalStaking;

    function run() public {
        
        vm.startBroadcast();
        nairaPetalStaking = new NairaPetalStaking();
        vm.stopBroadcast();
    }
}