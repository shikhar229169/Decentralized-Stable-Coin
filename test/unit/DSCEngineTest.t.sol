// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

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
    uint256 public constant DSC_MINT_AMOUNT = 2 ether;    // 1 DSC

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

    modifier approveAndDepositCollateral() {
        vm.startPrank(user);
        IERC20(wETH).approve(address(dscEngine), COLLATERAL_AMOUNT);
        dscEngine.depositCollateral(wETH, COLLATERAL_AMOUNT);
        vm.stopPrank();
        _;
    }

    modifier approve(address token, address approver, uint256 amount) {
        vm.prank(approver);
        ERC20Mock(token).approve(address(dscEngine), amount);
        _;
    }

    modifier mintDSC() {
        vm.prank(user);
        dscEngine.mintDSC(DSC_MINT_AMOUNT);
        _;
    }

    ///////////////////////// 
    //  Constructor Tests  //
    /////////////////////////
    address[] tokenAddress;
    address[] priceFeedsAddress;

    function test_ConstructorRevertsIfPriceFeedsLenDifferTokenLength() public {
        tokenAddress.push(wETH);
        priceFeedsAddress.push(ethPriceFeed);
        priceFeedsAddress.push(btcPriceFeed);

        vm.expectRevert(
            DSCEngine.DSCEngine__diffSizeOfTokenAndPriceFeedsArray.selector
        );
        new DSCEngine(tokenAddress, priceFeedsAddress, address(dsc));
    }


    /////////////////
    // Price Tests //
    /////////////////
    function test_GetTokenAmountFromUSD() public {
        uint256 usdAmt = 100 ether;  // 100 DSC
        // 100 / 2000 = 0.05 ETH
        uint256 actualWeth = 0.05 ether;
        uint256 expectedWeth = dscEngine.getTokenAmountFromUSD(wETH, usdAmt);

        assertEq(expectedWeth, actualWeth);
    }

    function testGetUSDValue() public {
        (, int256 price,,,) = AggregatorV3Interface(ethPriceFeed).latestRoundData();
        uint256 ethAmount = 15e18;
        uint256 expectedValue = ((uint256(price) * 1e10) * ethAmount) / 1e18;
        uint256 usdValue = dscEngine.getUsdValue(wETH, ethAmount);

        assertEq(usdValue, expectedValue);
    }


    /////////////////////////////
    // Deposit Collateral Test //
    /////////////////////////////
    function test_DepositCollateral_RevertsIfCollateralIsZero() public {
        vm.startPrank(user);
        ERC20Mock(wETH).approve(address(dscEngine), COLLATERAL_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__amtIsZero.selector);
        dscEngine.depositCollateral(wETH, 0);
        vm.stopPrank();
    }

    function test_DepositCollateral_Reverts_IfUserNotApprovedEnoughAmount() public {
        vm.expectRevert(
            "ERC20: insufficient allowance"
        );

        vm.prank(user);
        dscEngine.depositCollateral(wETH, COLLATERAL_AMOUNT);
    }

    function test_DepositCollateral_Reverts_IfTokenNotAllowedAsCollateral() public {
        ERC20Mock attackToken = new ERC20Mock("Attack", "ATK", user, COLLATERAL_AMOUNT);
        
        vm.expectRevert(
            DSCEngine.DSCEngine__tokenNotAllowedAsCollateral.selector
        );

        vm.prank(user);
        dscEngine.depositCollateral(address(attackToken), COLLATERAL_AMOUNT);
    }

    function testDepositCollateral() public approve(wETH, user, COLLATERAL_AMOUNT) {
        vm.expectEmit(true, true, true, false, address(dscEngine));
        emit collateralDeposited(user, address(wETH), COLLATERAL_AMOUNT);

        vm.prank(user);
        dscEngine.depositCollateral(wETH, COLLATERAL_AMOUNT);

        uint256 amountDeposited = dscEngine.getCollateralDepositedAmount(user, wETH);
        uint256 amountDepositedCheck2 = IERC20(wETH).balanceOf(address(dscEngine));
        uint256 userWethBalance = ERC20Mock(wETH).balanceOf(user);
        (uint256 totalDscMinted, uint256 collateralAmountInUSD) = dscEngine.getAccountInfo(user);
        uint256 collateralDepositedConvFromUSD = dscEngine.getTokenAmountFromUSD(wETH, collateralAmountInUSD);

        assertEq(amountDeposited, COLLATERAL_AMOUNT);
        assertEq(amountDepositedCheck2, COLLATERAL_AMOUNT);
        assertEq(collateralDepositedConvFromUSD, COLLATERAL_AMOUNT);
        assertEq(userWethBalance, 0);
        assertEq(totalDscMinted, 0);
    }

    ////////////////////////
    // Health Factor Test //
    ////////////////////////
    function test_HealthFactor_Reverts_IfNoDscMinted() public approveAndDepositCollateral {
        vm.expectRevert(
            DSCEngine.DSCEngine__noDscMintedCantCalculateHealthFactor.selector
        );

        dscEngine.getHealthFactor(user);
    }

    function test_HealthFactor_GivesCorrectValue_IfParametersAreGood() public approveAndDepositCollateral mintDSC {
        // 10 eth collateral - 20000 dollar
        // ((20000 dollar * 50)/100) / 2 = 5000
        uint256 expectedHealthFactor = 5000 ether;
        uint256 actualHealthFactor = dscEngine.getHealthFactor(user);

        assertEq(actualHealthFactor, expectedHealthFactor);
    }

    ///////////////////
    // Mint DSC Test //
    ///////////////////
    function test_MintDSC_Reverts_IfAmountProvidedIsZero() public approveAndDepositCollateral {
        uint256 mintAmt = 0;

        vm.expectRevert(
            DSCEngine.DSCEngine__amtIsZero.selector
        );

        vm.prank(user);
        dscEngine.mintDSC(mintAmt);
    }

    // if the deposited amount is 0
    function test_MintDSC_Reverts_IfHealthFactorBroken() public {
        uint256 mintAmt = 1 ether;   // 1 DSC
        uint256 expectedHealthFactor = 0;   // as no collateral is deposited

        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__brokenHealthFactor.selector, expectedHealthFactor)
        );

        dscEngine.mintDSC(mintAmt);
    }

    function test_MintDSC_IfHealthFactorIsGood() public {
        
    }
}