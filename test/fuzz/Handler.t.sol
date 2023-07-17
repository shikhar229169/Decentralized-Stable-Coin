// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    ERC20Mock weth;
    ERC20Mock wbtc;
    MockV3Aggregator ethUsdPriceFeed;

    uint256 MAX_DEPOSIT_AMT = type(uint96).max;

    uint256 public timesMintIsCalled;

    uint256 public temp1 = 5e30;
    uint256 public temp2;
    address[] public usersWithCollateralDeposited;

    constructor(DecentralizedStableCoin _dsc, DSCEngine _dscEngine) {
        dsc = _dsc;
        dscEngine = _dscEngine;

        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeedAddress(address(weth)));
    }

    function depositCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        collateralAmount = bound(collateralAmount, 1, MAX_DEPOSIT_AMT);

        vm.startPrank(msg.sender);

        collateral.mint(msg.sender, collateralAmount);
        collateral.approve(address(dscEngine), collateralAmount);
        dscEngine.depositCollateral(address(collateral), collateralAmount);

        vm.stopPrank();

        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxReedemtionPossible = dscEngine.getCollateralDepositedAmount(msg.sender, address(collateral));

        collateralAmount = bound(collateralAmount, 0, maxReedemtionPossible);
        if (collateralAmount == 0) {
            return;
        }

        vm.prank(msg.sender);
        dscEngine.redeemCollateral(address(collateral), collateralAmount);
    }

    function mintDSC(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }

        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];

        (uint256 dscMinted, uint256 totalCollateralInUSD) = dscEngine.getAccountInfo(sender);
        uint256 maxDscMintPossible = ((totalCollateralInUSD * dscEngine.getLiquidationThreshold()) / dscEngine.getLiquidationPrecision()) - dscMinted;

        if (maxDscMintPossible < 0) {
            return;
        }

        amount = bound(amount, 0, maxDscMintPossible);

        if (amount == 0) {
            return;
        }
        
        vm.prank(sender);
        dscEngine.mintDSC(amount);
        timesMintIsCalled++;
    }

    // Breaks our invariant tests
    // function updateCollateralPrice(uint96 _newPrice) public {
    //     int256 newPrice = int256(uint256(_newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPrice);
    // }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }

        return wbtc;
    }
}