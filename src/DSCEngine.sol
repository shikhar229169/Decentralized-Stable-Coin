// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

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
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    //////////////// 
    //   Events   //
    ////////////////
    event collateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event dscMinted(address indexed to, uint256 indexed amount);

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

    function depositCollateralAndMintDSC() external {
        
    }

    /**@param tokenCollateralAddress The address of token to deposit as collateral
     * @param amount The amount of collateral user wants to deposit
     * @notice follows CEI - checks effect interaction (on the basis of our modifier checks its gonna effect the user interactions)
    */
    function depositCollateral(
        address tokenCollateralAddress, 
        uint256 amount
    ) external moreThanZero(amount) isAllowedToken(tokenCollateralAddress) nonReentrant {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amount;
        emit collateralDeposited(msg.sender, tokenCollateralAddress, amount);
        (bool success) = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amount);

        if (!success) {
            revert DSCEngine__transferFailed();
        }
    }

    function redeemCollateralForDSC() external {

    }

    function redeemCollateral() external {
        
    }

    /**@param amount The amount of DSC to mint
     * @notice user must have more collateral value than min threshold
     * @notice Follows CEI
    */
    function mintDSC(uint256 amount) external moreThanZero(amount) nonReentrant {
        s_dscMinted[msg.sender] += amount;
        _revertIfHealthFactorIsBroken(msg.sender);

        emit dscMinted(msg.sender, amount);

        bool minted = i_DSC.mint(msg.sender, amount);

        if (!minted) {
            revert DSCEngine__mintFailed();
        }
    }

    function burnDSC() external {

    }

    function liquidate() external {

    }

    function getHealthFactor() external view {
        
    }

    /////////////////////////////////////////
    //  Private & Internal View Functions  //
    /////////////////////////////////////////
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

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        address priceFeeds = s_priceFeeds[token];
        if (priceFeeds == address(0)) {
            revert DSCEngine__tokenNotAllowedAsCollateral();
        }

        (, int256 price,,,) = AggregatorV3Interface(priceFeeds).latestRoundData();

        uint8 addtionalDecimal = MAX_DECIMALS - AggregatorV3Interface(priceFeeds).decimals();
        uint256 additionalFeedPrecision = 10 ** uint256(addtionalDecimal);
        return ((uint256(price) * additionalFeedPrecision) * amount) / PRECISION;
    }
}