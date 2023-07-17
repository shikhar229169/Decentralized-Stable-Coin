// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**@title DSCEngine
 * @author Shikhar Agarwal
 * 
 * It ensures that the tokens maintain a 1 token == $1 pegged
 * Dollar Pegged
 * Algorithmic
 * Exogeneous
 * 
 * Our DSC system should be over collateralized. 
 * At no point, the value of all collateral <= the dollar backed value of all DSC
 * 
 * @notice This contract is the engine of the DSC system.
 * Handle all the logic for mining and redeeming DSC, as
 * well as depositing & withdrawing collateral.
*/
contract DSCEngine is ReentrancyGuard {
    ///////////////// 
    //   Errors    //
    /////////////////
    error DSCEngine__amtIsZero();
    error DSCEngine__diffSizeOfTokenAndPriceFeedsArray();
    error DSCEngine__AddressShouldNotBeZero();
    error DSCEngine__tokenNotAllowedAsCollateral();
    error DSCEngine__transferFailed();
    error DSCEngine__brokenHealthFactor(uint256 healthFactor);
    error DSCEngine__mintFailed();
    error DSCEngine__AmountIsMoreThanDeposited();
    error DSCEngine__redeemtionFailed();
    error DSCEngine__AmountExceedsDSCToken();
    error DSCEngine__dscTransferFailed();
    error DSCEngine__healthFactorIsNotBroken();
    error DSCEngine__healthFactorNotImproved();
    error DSCEngine__noDscMintedCantCalculateHealthFactor();

    //////////
    // Type //
    //////////
    using OracleLib for AggregatorV3Interface;

    /////////////////////// 
    //  State Variables  //
    ///////////////////////
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 dscAmountMinted) private s_dscMinted;
    DecentralizedStableCoin private immutable i_DSC;
    address[] private s_collateralTokens;

    uint8 private constant MAX_DECIMALS = 18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    //////////////// 
    //   Events   //
    ////////////////
    event collateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event dscMinted(address indexed to, uint256 indexed amount);
    event dscBurnt(address indexed onBehalfOf, address indexed from, uint256 indexed amount);
    event collateralReedemed(address indexed from, address indexed to, address indexed token, uint256 amount);

    ///////////////// 
    //  Modifiers  //
    /////////////////
    modifier moreThanZero(uint256 amt) {
        if (amt == 0) {
            revert DSCEngine__amtIsZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__tokenNotAllowedAsCollateral();
        }
        _;
    }

    constructor(address[] memory tokenAddress, address[] memory priceFeedsAddress, address dscAddress) {
        if (tokenAddress.length != priceFeedsAddress.length) {
            revert DSCEngine__diffSizeOfTokenAndPriceFeedsArray();
        }

        for (uint256 i=0; i<tokenAddress.length; i++) {
            if (tokenAddress[i] == address(0) || priceFeedsAddress[i] == address(0)) {
                revert DSCEngine__AddressShouldNotBeZero();
            }
            s_priceFeeds[tokenAddress[i]] = priceFeedsAddress[i];
            s_collateralTokens.push(tokenAddress[i]);
        }

        i_DSC = DecentralizedStableCoin(dscAddress);
    }

    //////////////////////////
    //  External Functions  //
    //////////////////////////

    /**@param token The token to deposit as collateral
     * @param collateralAmt The amount to be deposited for collateral
     * @param dscAmount The amount of DSC user wants to be minted
     * @notice Allows user to deposit collateral and mint dsc in single txn
    */
    function depositCollateralAndMintDSC(address token, uint256 collateralAmt, uint256 dscAmount) external {
        depositCollateral(token, collateralAmt);
        mintDSC(dscAmount);
    }

    /**@param tokenCollateralAddress The address of token to deposit as collateral
     * @param amount The amount of collateral user wants to deposit
     * @notice follows CEI - checks effect interaction (on the basis of our modifier checks its gonna effect the user interactions)
    */
    function depositCollateral(
        address tokenCollateralAddress, 
        uint256 amount
    ) public moreThanZero(amount) isAllowedToken(tokenCollateralAddress) nonReentrant {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amount;
        emit collateralDeposited(msg.sender, tokenCollateralAddress, amount);
        (bool success) = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amount);

        if (!success) {
            revert DSCEngine__transferFailed();
        }
    }

    /**@param token The token to redeem the deposited collateral
     * @param collateralAmount The amount of collateral to redeem
     * @param dscBurnAmount The amount of DSC to burn
     * @notice This function burns DSC and then redeems collateral in a single txn
    */
    function redeemCollateralForDSC(address token, uint256 collateralAmount, uint256 dscBurnAmount) external {
        burnDSC(dscBurnAmount);
        redeemCollateral(token, collateralAmount);
    }

    /**@param token The token to redeem the deposited collateral
     * @param amount The amount to redeem back
    */
    function redeemCollateral(address token, uint256 amount) public moreThanZero(amount) isAllowedToken(token) nonReentrant {
        _redeemCollateral(token, amount, msg.sender, msg.sender);
        
        if (s_dscMinted[msg.sender] != 0) {
            _revertIfHealthFactorIsBroken(msg.sender);
        }
    }

    /**@param amount The amount of DSC to mint
     * @notice user must have more collateral value than min threshold
     * @notice Follows CEI
    */
    function mintDSC(uint256 amount) public moreThanZero(amount) nonReentrant {
        s_dscMinted[msg.sender] += amount;
        _revertIfHealthFactorIsBroken(msg.sender);

        emit dscMinted(msg.sender, amount);

        bool minted = i_DSC.mint(msg.sender, amount);

        if (!minted) {
            revert DSCEngine__mintFailed();
        }
    }

    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDSC(msg.sender, msg.sender, amount);
    }

    /**@param collateral The collateral token address to liquidate from user
     * @param user The user to liquidate, who has broken health factor
     * @param debtToCover The amount of DSC to burn from user, and improve user's health factor
     * @notice You can partially liquidate a user  
     * @notice Follows CEI - Checks effect Interaction
    */
    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) isAllowedToken(collateral) nonReentrant {
        uint256 startHealthFactor = _healthFactor(user);
        if (startHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__healthFactorIsNotBroken();
        }

        uint256 collateralAmountFromDebtCovered = getTokenAmountFromUSD(collateral, debtToCover);
        uint256 bonusCollateral = (collateralAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 netCollateralAmount = collateralAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(collateral, netCollateralAmount, user, msg.sender);
        _burnDSC(user, msg.sender, debtToCover);

        uint256 endingUserHealthFactor = _healthFactor(user);

        if (endingUserHealthFactor <= startHealthFactor) {
            revert DSCEngine__healthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /////////////////////////////////////////
    //  Private & Internal View Functions  //
    /////////////////////////////////////////
    function _redeemCollateral(address token, uint256 amount, address from, address to) private {
        if (amount > s_collateralDeposited[from][token]) {
            revert DSCEngine__AmountIsMoreThanDeposited();
        }

        s_collateralDeposited[from][token] -= amount;

        emit collateralReedemed(from, to, token, amount);
        (bool success) = IERC20(token).transfer(to, amount);

        if (!success) {
            revert DSCEngine__redeemtionFailed();
        }
    }

    /**@dev Low level internal functions, do not call unless the calling function
     * checks for health factors and revert if it is broken
    */
    function _burnDSC(address onBehalfOf, address from, uint256 amountToBurn) private {
        if (amountToBurn > s_dscMinted[onBehalfOf]) {
            revert DSCEngine__AmountExceedsDSCToken();
        }

        s_dscMinted[onBehalfOf] -= amountToBurn;
         
        (bool success) = i_DSC.transferFrom(from, address(this), amountToBurn);
        if (!success) {
            revert DSCEngine__dscTransferFailed();
        }

        emit dscBurnt(onBehalfOf, from, amountToBurn);

        i_DSC.burn(amountToBurn);
    }

    function _getAccountInfo(address user) private view returns (uint256 totalDSCMinted, uint256 collateralValueInUSD) {
        totalDSCMinted = s_dscMinted[user];
        collateralValueInUSD = getAccountCollateralValue(user);
    }

    /**@param user The address of user for which we need to check health factor
     * Returns how close a user is to get liquidated
     * @notice If the factor is below 1, the user will be liquidated
    */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = _getAccountInfo(user);

        if (totalDSCMinted == 0) {
            revert DSCEngine__noDscMintedCantCalculateHealthFactor();
        }

        uint256 collateralAdjustedForThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__brokenHealthFactor(userHealthFactor);
        }
    }


    ////////////////////////////////////////
    //  Public & Internal View Functions  //
    ////////////////////////////////////////
    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalCollateralInUSD = 0;

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];

            totalCollateralInUSD += getUsdValue(token, amount);
        }

        return totalCollateralInUSD;
    }

    function getUsdValue(address token, uint256 amount) public isAllowedToken(token) view returns (uint256) {
        address priceFeeds = s_priceFeeds[token];

        (, int256 price,,,) = AggregatorV3Interface(priceFeeds).stalePriceCheck();

        uint8 addtionalDecimal = MAX_DECIMALS - AggregatorV3Interface(priceFeeds).decimals();
        uint256 additionalFeedPrecision = 10 ** uint256(addtionalDecimal);
        return ((uint256(price) * additionalFeedPrecision) * amount) / PRECISION;
    }

    function getTokenAmountFromUSD(address token, uint256 usdAmount) public isAllowedToken(token) view returns (uint256 tokenAmount) {
        AggregatorV3Interface priceFeeds = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price, , ,) = priceFeeds.stalePriceCheck();
        uint8 additonalDecimal = MAX_DECIMALS - priceFeeds.decimals();
        uint256 additionalFeedPrecision = 10 ** uint256(additonalDecimal);
        tokenAmount = (usdAmount * PRECISION) / (uint256(price) * additionalFeedPrecision);
    }

    /////////////////////////////////
    //  External & View Functions  //
    /////////////////////////////////
    function getCollateralToken(uint256 idx) external view returns (address) {
        return s_collateralTokens[idx];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeedAddress(address token) external isAllowedToken(token) view returns (address) {
        return s_priceFeeds[token];
    }

    function getCollateralDepositedAmount(address user, address token) external isAllowedToken(token) view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getAccountInfo(address user) external view returns (uint256, uint256) {
        return _getAccountInfo(user);
    }

    function getDscMinted(address user) external view returns (uint256) {
        return s_dscMinted[user];
    }

    function getDscAddress() external view returns (address) {
        return address(i_DSC);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /////////////////////////////////
    //  External & Pure Functions  //
    /////////////////////////////////
    function getMaxDecimals() external pure returns (uint8) {
        return MAX_DECIMALS;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }
    
    function getMinimumHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }
}