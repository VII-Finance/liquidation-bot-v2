// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {Test} from "forge-std/Test.sol";

import {Liquidator} from "./Liquidator.sol";

import "forge-std/console2.sol";

contract DeployLiquidator is Script {
    function run() public {
        // uint256 deployerPrivateKey = vm.envUint("LIQUIDATOR_PRIVATE_KEY");

        //mainnet
        // address swapperAddress = 0xBF4D90a9c3F1CC9Bb5FeA7F3C6c2F264DD652BFE;
        // address swapVerifierAddress = 0xae26485ACDDeFd486Fe9ad7C2b34169d360737c7;
        // address evcAddress = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
        // address pyth = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;

        //unichain
        address swapperAddress = 0xe253a6E5a86D0981eEeBAfE754fA35eC449a71Fd;
        address swapVerifierAddress = 0xDAd370C74A9Fe7e6bfd55De69Baf81060e51eab4;
        address evcAddress = 0x2A1176964F5D7caE5406B627Bf6166664FE83c60;
        address pyth = 0x2880aB155794e7179c9eE2e38200202908C17B43;

        address deployer = 0x12e74f3C61F6b4d17a9c3Fdb3F42e8f18a8bB394;
        vm.startBroadcast();
        

        Liquidator liquidator = new Liquidator(deployer, swapperAddress, swapVerifierAddress, evcAddress, pyth);
        vm.stopBroadcast();
    }
}
