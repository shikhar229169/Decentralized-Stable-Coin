// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngineTest is Test {
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    address user = makeAddr("user");
    uint256 START_BALANCE = 10 ether;
    int256 public constant ETH_USD_FEED = 2000e8;
    int256 public constant BTC_USD_FEED = 1000e8;
    address ethPriceFeed;
    address btcPriceFeed;
    address wETH;
    address wBTC;
    uint256 deployerKey;
    uint256 public constant COLLATERAL_AMOUNT = 10 ether;

    event collateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event dscMinted(address indexed to, uint256 indexed amount);

    function setUp() external {
        HelperConfig helperConfig;
        DeployDSC deployDSC = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployDSC.run();

        (ethPriceFeed, 
        btcPriceFeed,
        wETH,
        wBTC,
        deployerKey) = helperConfig.networkConfig();

        vm.deal(user, START_BALANCE);
        ERC20Mock(wETH).mint(user, COLLATERAL_AMOUNT);
        ERC20Mock(wBTC).mint(user, COLLATERAL_AMOUNT);
    }

    modifier approve(address token, address approver, uint256 amount) {
        vm.prank(approver);
        ERC20Mock(token).approve(address(dscEngine), amount);
        _;
    }


    function testGetUSDValue() public {
        (, int256 price,,,) = AggregatorV3Interface(ethPriceFeed).latestRoundData();
        uint256 ethAmount = 15e18;
        uint256 expectedValue = ((uint256(price) * 1e10) * ethAmount) / 1e18;
        uint256 usdValue = dscEngine.getUsdValue(wETH, ethAmount);

        assertEq(usdValue, expectedValue);
    }

    function test_DepositCollateral_RevertsIfCollateralIsZero() public {
        vm.startPrank(user);
        ERC20Mock(wETH).approve(address(dscEngine), COLLATERAL_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__amtIsZero.selector);
        dscEngine.depositCollateral(wETH, 0);
        vm.stopPrank();
    }

    function testDepositCollateral() public approve(wETH, user, COLLATERAL_AMOUNT) {
        vm.expectEmit(true, true, true, false, address(dscEngine));
        emit collateralDeposited(user, address(wETH), COLLATERAL_AMOUNT);

        vm.prank(user);
        dscEngine.depositCollateral(wETH, COLLATERAL_AMOUNT);
        uint256 amountDeposited = dscEngine.getCollateralDepositedAmount(user, wETH);
        // uint256 amountDeposited2;
        uint256 userWethBalance = ERC20Mock(wETH).balanceOf(user);

        assertEq(amountDeposited, COLLATERAL_AMOUNT);
        assertEq(userWethBalance, 0);
    }
}