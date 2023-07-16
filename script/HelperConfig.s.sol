// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address ethPriceFeed;
        address btcPriceFeed;
        address wETH;
        address wBTC;
        uint256 deployerKey;
    }

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_FEED = 2000e8;
    int256 public constant BTC_USD_FEED = 1000e8;

    NetworkConfig public networkConfig;

    constructor() {
        if (block.chainid == 11155111) {
            networkConfig = getSepoliaConfig();
        }
        else {
            networkConfig = getAnvilConfig();
        }
    }

    function getSepoliaConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            ethPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            btcPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            wETH: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wBTC: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getAnvilConfig() public returns (NetworkConfig memory) {
        if (networkConfig.ethPriceFeed != address(0)) {
            return networkConfig;
        }

        vm.startBroadcast();

        MockV3Aggregator ethPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_FEED);
        MockV3Aggregator btcPriceFeed = new MockV3Aggregator(DECIMALS, BTC_USD_FEED);

        ERC20Mock wETH = new ERC20Mock("wETH", "wETH", msg.sender, 1000e8);
        ERC20Mock wBTC = new ERC20Mock("wBTC", "wBTC", msg.sender, 1000e8);

        vm.stopBroadcast();

        return NetworkConfig({
            ethPriceFeed: address(ethPriceFeed),
            btcPriceFeed: address(btcPriceFeed),
            wETH: address(wETH),
            wBTC: address(wBTC),
            deployerKey: vm.envUint("ANVIL_PRIVATE_KEY")
        });
    }
}