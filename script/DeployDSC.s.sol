// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDSC is Script {

    address[] tokenAddresses;
    address[] priceFeedsAddresses;

    function run() external returns (DecentralizedStableCoin, DSCEngine, HelperConfig) {
        
        HelperConfig helperConfig = new HelperConfig();

        (address ethPriceFeed, address btcPriceFeed, address wETH, address wBTC, uint256 deployerKey) = helperConfig.networkConfig();

        tokenAddresses = [wETH, wBTC];
        priceFeedsAddresses = [ethPriceFeed, btcPriceFeed];

        vm.startBroadcast(deployerKey);

        DecentralizedStableCoin dsc = new DecentralizedStableCoin();
        DSCEngine dscEngine = new DSCEngine(tokenAddresses, priceFeedsAddresses, address(dsc));
        dsc.transferOwnership(address(dscEngine));

        vm.stopBroadcast();

        return (dsc, dscEngine, helperConfig);
    }

}