// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink-contracts/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Mario
 * The system is designed to be minimalistic as possible and have tokens that maintain 1 token = 1 $.
 * This stablecoin has the properties:
 * - Exogenous collateral
 * - Dollar pegged
 * - Algorithmically stable
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ value of all the DSC.
 *
 * @notice This contract is the core of the DSC system. It handles all the logic for minting and redeeming DSC tokens, as well as depositing and withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    /////////////////////
    // Errors ///////////
    /////////////////////
    error DSCEngine__AmountMustBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorIsBelowMinimum(uint256 userHealthFactor);
    error DSCEngine__MintFailed();

    /////////////////////
    // State Variables //
    /////////////////////
    uint256 private constant USD_VALUE_DECIMALS = 2;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;
    mapping(address token => address priceFeed) private s_priceFeeds; // token to price feed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // user to token to amount
    DecentralizedStableCoin private immutable i_dscAddress;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;

    address[] private s_collateralTokens;

    /////////////////////
    // Events ///////////
    /////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    /////////////////////
    // Modifiers ////////
    /////////////////////

    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__AmountMustBeMoreThanZero();
        }

        _;
    }

    modifier isAllowedToken(address _tokenAddress) {
        if (s_priceFeeds[_tokenAddress] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }

        _;
    }

    /////////////////////
    // Functions ////////
    /////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD price feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dscAddress = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////
    // External functions //
    ////////////////////////

    function depositCollateralAndMintDsc() external {}

    /*
     * @notice Follows CEI.
     * @param tokenCollateralAddress The address of the collateral token to deposit.
     * @param amountCollateral The amount of collateral to deposit.
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    // 1. Check if collateral value is greater than DSC amount
    /*
     * @notice Follows CEI.
     * @param dscAmountToMint The amount of decentralized stable coin to mint.
     * @notice they must have more collateral value than the minimum threshold.
    */
    function mintDsc(uint256 dscAmountToMint) external moreThanZero(dscAmountToMint) nonReentrant {
        s_dscMinted[msg.sender] += dscAmountToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dscAddress.mint(msg.sender, dscAmountToMint);

        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}

    ///////////////////////////////////////
    // Private & Internal view functions //
    ///////////////////////////////////////
    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1 then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total dsc minted
        // total collateral value

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralValueAdjustedForThreshold =
            (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralValueAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        // 1. get all collateral
        // 2. get all dsc minted
        // 3. get all collateral value in usd
        totalDscMinted = s_dscMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUsd(user);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. check health factor
        // 2. revert if they dont
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBelowMinimum(userHealthFactor);
        }
    }

    ///////////////////////////////////////
    // Public & External view functions ///
    ///////////////////////////////////////

    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        /// loop through each collateral token
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        // get price feed
        // get price
        // multiply by amount
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 eth = 1000 usd
        // the returned value from chainlink will be 1000 * 1e8

        // 1 eth = 1000 usd
        // amount = 1e18

        //getUsdValue(1 ether)
        //price = 1000 * 1e8
        // amount = 1e18
        // usd value should be 1000
        // (price * 1e10) * amount / 1e18 => (1000 * 1e8 * 1e10) * 1e18 / 1e18 => 1000 * 1e18

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getUsdValueModified(address token, uint256 amount) public view returns (uint256) {
        // 1. get price feed
        // 2. get price feed decimals
        // 3. get token decimals
        // 4. calculate in usd amount with usd decimals
        // formula is like this: (price * amount * 10^usd_decimals) / (10** token decimals * 10 ** price feed decimals)
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        uint256 priceFeedDecimals = priceFeed.decimals();
        uint256 tokenDecimals = ERC20(token).decimals();
        (, int256 price,,,) = priceFeed.latestRoundData();

        return uint256(price) * amount * (10 ** USD_VALUE_DECIMALS) / (10 ** tokenDecimals * 10 ** priceFeedDecimals);
    }

    function _healthFactorModified(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        uint256 collateralValueAdjustedForThreshold =
            (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralValueAdjustedForThreshold * (10 ** ERC20(i_dscAddress).decimals())) / totalDscMinted
            * 10 ** USD_VALUE_DECIMALS;
    }
}
