// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract OpenInvariantsTest is StdInvariant, Test {
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig helperConfig;
    address wETH;
    address wBTC;
    Handler handler;

    uint256 public constant START_BALANCE = 10 ether;

    function setUp() external {
        DeployDSC deployDSC = new DeployDSC();

        (dsc, dscEngine, helperConfig) = deployDSC.run();

        (,, wETH, wBTC,) = helperConfig.networkConfig();

        handler = new Handler(dsc, dscEngine);

        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(wETH).balanceOf(address(dscEngine));
        uint256 totalWbtcDeposited = IERC20(wBTC).balanceOf(address(dscEngine));

        uint256 wethUsdValue = dscEngine.getUsdValue(wETH, totalWethDeposited);
        uint256 wbtcUsdValue = dscEngine.getUsdValue(wBTC, totalWbtcDeposited);

        console.log("wethUsdValue: ", wethUsdValue);
        console.log("wbtcUsdValue: ", wbtcUsdValue);
        console.log("total supply: ", totalSupply);
        console.log("Times mint is called: ", handler.timesMintIsCalled());

        assert((wethUsdValue + wbtcUsdValue) >= totalSupply);
    }
}