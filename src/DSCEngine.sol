// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin-contracts/security/ReentrancyGuard.sol";
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
    error DSCEngine__HealthFactorIsFine();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__ZeroAddressNotAllowed();

    /////////////////////
    // State Variables //
    /////////////////////
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 public constant USD_VALUE_DECIMALS = 2;
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
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

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
            if (tokenAddresses[i] == address(0) || priceFeedAddresses[i] == address(0)) {
                revert DSCEngine__ZeroAddressNotAllowed();
            }
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dscAddress = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////
    // External functions //
    ////////////////////////

    /*
     * @param tokenCollateralAddress The address of the collateral token to deposit.
     * @param amountCollateral The amount of collateral to deposit.
     * @param dscAmountToMint The amount of decentralized stable coin to mint.
     * @notice this function will deposit your collateral and mint DSC in one transaction.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 dscAmountToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(dscAmountToMint);
    }

    /*
     * @notice Follows CEI.
     * @param tokenCollateralAddress The address of the collateral token to deposit.
     * @param amountCollateral The amount of collateral to deposit.
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
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

    /*
     *
     * @param tokenCollateralAddress The address of the collateral token to redeem.
     * @param amountCollateral The amount of collateral to redeem.
     * @param amountDscToBurn The amount of DSC to burn.
     * @notice This function burns DSC and redeems collateral in one transaction.
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor
    }

    // in order to redeem collateral
    // 1. health factor must be above minimum
    function redeemCollateral(address collateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(collateralAddress, amountCollateral, msg.sender, msg.sender);

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // 1. Check if collateral value is greater than DSC amount
    /*
     * @notice Follows CEI.
     * @param dscAmountToMint The amount of decentralized stable coin to mint.
     * @notice they must have more collateral value than the minimum threshold.
    */
    function mintDsc(uint256 dscAmountToMint) public moreThanZero(dscAmountToMint) nonReentrant {
        s_dscMinted[msg.sender] += dscAmountToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dscAddress.mint(msg.sender, dscAmountToMint);

        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amountToBurn) public moreThanZero(amountToBurn) {
        _burnDsc(amountToBurn, msg.sender, msg.sender);

        _revertIfHealthFactorIsBroken(msg.sender); //probably not needed
    }

    /*
     *
     * @param collateral The address of the collateral token to liquidate.
     * @param user The user that has broken the health factor. Their health factor should be below MINIMUM_HEALTH_FACTOR.
     * @param debtToCover The amount of DSC to improve the users health factor.
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation reward for liquidating a user.
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized.
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we would be unable to incentive liquidators.
     * For example if the value of the collateral drops down before anyone could be liquidated.
     * 
     * Follows CEI: Checks, Effects, Interactions
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsFine();
        }

        // we want to burn their DSC debt
        // and take their collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // also give 10% bonus to the liquidator
        // we should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury

        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        // First we redeem the user collateral and send it to the msg.sender (liquidator)
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        // We need to burn DSC. Whoever is calling liquidate is paying the DSC debt from its own DSC tokens
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);

        if (endingUserHealthFactor <= startingHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    ///////////////////////////////////////
    // Private & Internal view functions //
    ///////////////////////////////////////

    function _redeemCollateral(address collateralAddress, uint256 amountCollateral, address from, address to) private {
        s_collateralDeposited[from][collateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, collateralAddress, amountCollateral);

        bool success = IERC20(collateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1 then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd, uint256 usdDecimals) = _getAccountInformation(user);
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }

        // get collateral threshold
        uint256 collateralValueAdjustedForThreshold =
            (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
        }

        // factor is collateral threshold in usd multiplied by DSC token decimals / total dsc minted
        // this is done to remove decimals from the equation
        return (collateralValueAdjustedForThreshold * (10 ** i_dscAddress.decimals()))
            / (totalDscMinted * 10 ** usdDecimals);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd, uint256 usdDecimals)
    {
        // 1. get all collateral
        // 2. get all dsc minted
        // 3. get all collateral value in usd
        totalDscMinted = s_dscMinted[user];
        (collateralValueInUsd, usdDecimals) = getAccountCollateralValueInUsd(user);
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

    /*
     * notice Low level internal function, do not call unless the function calling it is checking for health factors being broken.
     */
    function _burnDsc(uint256 amountToBurn, address onBehalfOf, address dscFrom) private {
        s_dscMinted[onBehalfOf] -= amountToBurn;
        bool success = i_dscAddress.transferFrom(dscFrom, address(this), amountToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        i_dscAddress.burn(amountToBurn);
    }

    function getAccountCollateralValueInUsd(address user)
        public
        view
        returns (uint256 totalCollateralValueInUsd, uint256 usdDecimals)
    {
        /// loop through each collateral token
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            (uint256 tokenUsdValue, uint256 decimals) = getUsdValue(token, amount);
            totalCollateralValueInUsd += tokenUsdValue;
            usdDecimals = decimals;
        }
    }

    /*
     * @param token The address of the token to get the USD value for.
        * @param amount The amount of the token to get the USD value for.
        * @notice This function will return the USD value of the token amount with decimals specified in the contract USD_VALUE_DECIMALS
        * @dev Returns the decimals that the usd value holds.
        * 
     */
    function getUsdValue(address token, uint256 amount) public view returns (uint256, uint256) {
        // 1. get price feed
        // 2. get price feed decimals
        // 3. get token decimals
        // 4. calculate in usd amount with usd decimals
        // formula is like this: (price * amount * 10^usd_decimals) / (10** token decimals * 10 ** price feed decimals)
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        uint256 priceFeedDecimals = priceFeed.decimals();
        uint256 tokenDecimals = ERC20(token).decimals();
        (, int256 price,,,) = priceFeed.latestRoundData();

        uint256 usdValue =
            uint256(price) * amount * (10 ** USD_VALUE_DECIMALS) / (10 ** tokenDecimals * 10 ** priceFeedDecimals);

        return (usdValue, USD_VALUE_DECIMALS);
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInDSC) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        uint256 priceFeedDecimals = priceFeed.decimals();

        // Example:
        // DSC decimals -> 5 => 100 DSC = 100e5
        // price feed decimals -> 8 => 1000 USD = 1000e8
        // token decimals -> 18 => 1 ETH = 1e18
        // if usd amount in dsc is 100$ then for the price of ETH/USD = 1000$ then for 100$ it should get 0.1 ETH = 1e17
        // 100e5 * 1e8 * 1e18 / 1000e8 * 1e5 => 100e5 * 1e26 / 1000e13 => 1e7 * 1e26/ 1e16 => 1e33/1e16 => 1e17

        uint256 tokenAmount = (usdAmountInDSC * 10 ** priceFeedDecimals) * (10 ** ERC20(token).decimals())
            / (uint256(price) * 10 ** i_dscAddress.decimals());

        return tokenAmount;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd, uint256 usdDecimals)
    {
        return _getAccountInformation(user);
    }

    function getOvercollateralizationRatio() public pure returns (uint256 numerator, uint256 denominator) {
        return (LIQUIDATION_THRESHOLD, LIQUIDATION_PRECISION);
    }
}
