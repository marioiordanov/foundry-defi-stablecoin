// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin-contracts/mocks/ERC20Mock.sol";
import {AggregatorV3Interface} from "@chainlink-contracts/v0.8/interfaces/AggregatorV3Interface.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {MockFailedERC20} from "../mocks/MockFailedERC20.sol";

contract DSCEngineTest is Test {
    DecentralizedStableCoin private dsc;
    DSCEngine private dscEngine;
    HelperConfig private helperConfig;

    address private weth;
    address private wbtc;
    AggregatorV3Interface private ethUsdPriceFeed;

    uint256 private constant LIQUIDATOR_STARTING_DSC_BALANCE = 1 ether;
    uint256 private constant STARTING_USER_ERC20_BALANCE = 100 ether;
    uint256 private constant AMOUNT_COLLATERAL = 1 ether;
    address private USER = makeAddr("USER");

    uint256 private constant PRICE_CHANGE_IN_PERCENTAGE = 90;
    uint256 private constant PERCENTAGE_DENOMINATOR = 100;
    uint256 private constant LIQUIDATOR_BONUS_PERCENTAGE = 10;

    function setUp() public {
        DeployDSC deployDsc = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployDsc.run();

        (address ethUsdPriceFeedAddress,, address wethAddress, address wbtcAddress,) =
            helperConfig.activeNetworkConfig();
        weth = wethAddress;
        wbtc = wbtcAddress;
        ethUsdPriceFeed = AggregatorV3Interface(ethUsdPriceFeedAddress);

        ERC20Mock(weth).mint(USER, STARTING_USER_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_USER_ERC20_BALANCE);
    }

    modifier depositedCollateral(address collateral, DSCEngine engine) {
        depositCollateral(collateral, engine);
        _;
    }

    modifier depositedCollateralAndMintedDsc(address collateral, DSCEngine engine) {
        depositCollateralAndMintDsc(collateral, engine);
        _;
    }

    function useFailedTransfersERC20() private returns (DSCEngine, address) {
        MockFailedERC20 failedErc20 = new MockFailedERC20();
        failedErc20.mint(USER, STARTING_USER_ERC20_BALANCE);

        address[] memory erc20TokenAddresses = new address[](1);
        erc20TokenAddresses[0] = address(failedErc20);
        address[] memory localPriceFeedAddresses = new address[](1);
        localPriceFeedAddresses[0] = address(ethUsdPriceFeed);

        DecentralizedStableCoin stableCoin = new DecentralizedStableCoin();
        DSCEngine engine = new DSCEngine(erc20TokenAddresses, localPriceFeedAddresses, address(stableCoin));
        stableCoin.transferOwnership(address(engine));
        return (engine, address(failedErc20));
    }

    function depositCollateral(address collateralAddress, DSCEngine engine) private {
        vm.startPrank(USER);
        IERC20(collateralAddress).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(collateralAddress, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function depositCollateralAndMintDsc(address collateral, DSCEngine engine) private {
        depositCollateral(collateral, engine);

        vm.startPrank(USER);
        uint256 dscAmountEqualToCollateral = getDscAmountFromCollateralAmount(collateral, AMOUNT_COLLATERAL);
        (uint256 numerator, uint256 denominator) = engine.getOvercollateralizationRatio();
        engine.mintDsc(dscAmountEqualToCollateral * numerator / denominator);
        vm.stopPrank();
    }

    function getDscAmountFromCollateralAmount(address collateral, uint256 amount) private view returns (uint256) {
        (uint256 usdAmount, uint256 decimals) = dscEngine.getUsdValue(collateral, amount);
        return dsc.convertUsdAmountToDSC(usdAmount, decimals);
    }

    ////////////////////
    // Price tests /////
    ////////////////////

    function testGetUsdValue() public {
        uint256 amountInEthers = 15 ether;

        // 15e18 * 2000/ETH = 30,000e18
        uint256 expectedUsd = 30000 * 10 ** dscEngine.USD_VALUE_DECIMALS();
        (uint256 actualUsd, uint256 usdDecimals) = dscEngine.getUsdValue(weth, amountInEthers);

        assertEq(actualUsd, expectedUsd);
        assertEq(usdDecimals, dscEngine.USD_VALUE_DECIMALS());
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmountInDsc = 100 * 10 ** dsc.decimals();
        //100/2000 = 0.05
        // eth price is 2000$
        uint256 expectedWeth = 0.05 ether;

        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmountInDsc);

        assertEq(expectedWeth, actualWeth);
    }

    function testUsdValueFromCollateral() public view {
        uint256 wethCollateralAmount = 6915120017154;

        (uint256 usdValue, uint256 decimals) = dscEngine.getUsdValue(weth, wethCollateralAmount);
        console.log("usd value: %d, decimals: %d", usdValue, decimals);
        uint256 collateralInDsc = dsc.convertUsdAmountToDSC(usdValue, decimals);
        uint256 totalDscMinted = 0;
        console.log(collateralInDsc);

        uint256 collateralValueInUsd = 1;
        uint256 usdDecimals = 2;

        console.log(
            "health factor: ", (collateralValueInUsd * (10 ** dsc.decimals())) * 50 / (5122 * 100 * (10 ** usdDecimals))
        );

        int256 maxDscToMint = int256((collateralInDsc / 2)) - int256(totalDscMinted);
        console.log("maxdscTomint: ", uint256(maxDscToMint));

        /**
         * [127579] Handler::mintDSC(5122, 307)
         * ├─ [61733] DSCEngine::getAccountInformation(0x7d67D1161e20113C7c816a2a28e61098154c0780) [staticcall]
         * │   ├─ [0] console::log("totalDscMinted: ", 0) [staticcall]
         * │   │   └─ ← ()
         * │   ├─ [0] console::log(ERC20Mock: [0xBb2180ebd78ce97360503434eD37fcf4a1Df61c3], 6915120017154 [6.915e12]) [staticcall]
         * │   │   └─ ← ()
         * │   ├─ [2303] MockV3Aggregator::decimals() [staticcall]
         * │   │   └─ ← 8
         * │   ├─ [244] ERC20Mock::decimals() [staticcall]
         * │   │   └─ ← 18
         * │   ├─ [8993] MockV3Aggregator::latestRoundData() [staticcall]
         * │   │   └─ ← 1, 200000000000 [2e11], 1, 1, 1
         * │   ├─ [0] console::log(ERC20Mock: [0xDB8cFf278adCCF9E9b5da745B44E754fC4EE3C76], 0) [staticcall]
         * │   │   └─ ← ()
         * │   ├─ [2303] MockV3Aggregator::decimals() [staticcall]
         * │   │   └─ ← 8
         * │   ├─ [244] ERC20Mock::decimals() [staticcall]
         * │   │   └─ ← 18
         * │   ├─ [8993] MockV3Aggregator::latestRoundData() [staticcall]
         * │   │   └─ ← 1, 3000000000000 [3e12], 1, 1, 1
         * │   └─ ← 0, 1, 2
         * ├─ [0] console::log("totalDscMinted: ", 0) [staticcall]
         * │   └─ ← ()
         * ├─ [0] console::log("totalCollateralUsd: ", 1) [staticcall]
         * │   └─ ← ()
         * ├─ [1187] DecentralizedStableCoin::convertUsdAmountToDSC(1, 2) [staticcall]
         * │   └─ ← 10000000000000000 [1e16]
         * ├─ [0] console::log("collateralInDsc: ", 10000000000000000 [1e16]) [staticcall]
         * │   └─ ← ()
         * ├─ [0] console::log("Bound Result", 5122) [staticcall]
         * │   └─ ← ()
         * ├─ [0] console::log("maxdscTomint: ", 5000000000000000 [5e15]) [staticcall]
         * │   └─ ← ()
         * ├─ [0] console::log("amount: ", 5122) [staticcall]
         * │   └─ ← ()
         * ├─ [0] VM::startPrank(0x7d67D1161e20113C7c816a2a28e61098154c0780)
         * │   └─ ← ()
         * ├─ [41543] DSCEngine::mintDsc(5122)
         * │   ├─ [0] console::log("totalDscMinted: ", 5122) [staticcall]
         * │   │   └─ ← ()
         * │   ├─ [0] console::log(ERC20Mock: [0xBb2180ebd78ce97360503434eD37fcf4a1Df61c3], 6915120017154 [6.915e12]) [staticcall]
         * │   │   └─ ← ()
         * │   ├─ [303] MockV3Aggregator::decimals() [staticcall]
         * │   │   └─ ← 8
         * │   ├─ [244] ERC20Mock::decimals() [staticcall]
         * │   │   └─ ← 18
         * │   ├─ [993] MockV3Aggregator::latestRoundData() [staticcall]
         * │   │   └─ ← 1, 200000000000 [2e11], 1, 1, 1
         * │   ├─ [0] console::log(ERC20Mock: [0xDB8cFf278adCCF9E9b5da745B44E754fC4EE3C76], 0) [staticcall]
         * │   │   └─ ← ()
         * │   ├─ [303] MockV3Aggregator::decimals() [staticcall]
         * │   │   └─ ← 8
         * │   ├─ [244] ERC20Mock::decimals() [staticcall]
         * │   │   └─ ← 18
         * │   ├─ [993] MockV3Aggregator::latestRoundData() [staticcall]
         * │   │   └─ ← 1, 3000000000000 [3e12], 1, 1, 1
         * │   ├─ [0] console::log("collateralValueAdjustedForThreshold: ", 0) [staticcall]
         * │   │   └─ ← ()
         * │   ├─ [0] console::log("totalDscMinted: ", 5122) [staticcall]
         * │   │   └─ ← ()
         * │   ├─ [200] DecentralizedStableCoin::decimals() [staticcall]
         * │   │   └─ ← 18
         * │   └─ ← DSCEngine__HealthFactorIsBelowMinimum(0)
         * └─ ← DSCEngine__HealthFactorIsBelowMinimum(0)
         */
    }

    ///////////////////////
    // Constructor tests //
    ///////////////////////

    address[] private tokenAddresses;
    address[] private priceFeedAddresses;

    function testRevertsIfTokenLengthDoenstMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);

        priceFeedAddresses.push(makeAddr("priceFeed"));

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testRevertsIfOneOfTheAddressesIsZeroAddress() public {
        tokenAddresses.push(address(0));
        priceFeedAddresses.push(makeAddr("priceFeed"));
        vm.expectRevert(DSCEngine.DSCEngine__ZeroAddressNotAllowed.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////////////////////////////
    // Deposit collateral tests /////
    /////////////////////////////////
    function testRevertsIfCollateralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__AmountMustBeMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
    }

    function testRevertsIfUserDidntApprovedEngineToSpendTokens() public depositedCollateral(weth, dscEngine) {
        vm.startPrank(USER);
        vm.expectRevert();
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock("RANDOM", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);

        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dscEngine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral(weth, dscEngine) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd, uint256 usdDecimals) =
            dscEngine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;

        uint256 expectedDepositAmount =
            dscEngine.getTokenAmountFromUsd(weth, dsc.convertUsdAmountToDSC(collateralValueInUsd, usdDecimals));

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testDepositCollateralRevertsIfTransferFromFails() public {
        (DSCEngine engine, address mockErc20) = useFailedTransfersERC20();
        uint256 startingBalance = IERC20(mockErc20).balanceOf(USER);

        vm.startPrank(USER);
        IERC20(mockErc20).approve(address(engine), AMOUNT_COLLATERAL);
        MockFailedERC20(mockErc20).setTransferFailures(false, true);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        engine.depositCollateral(mockErc20, AMOUNT_COLLATERAL);

        (uint256 totalDscMinted, uint256 collateralValueInUsd,) = engine.getAccountInformation(USER);

        assertEq(IERC20(mockErc20).balanceOf(USER), startingBalance);
        assertEq(totalDscMinted, 0);
        assertEq(collateralValueInUsd, 0);
    }

    ///////////////////////
    // Mint DSC tests /////
    ///////////////////////

    function testMintDSCRevertsifAmountIsZero() public {
        vm.startPrank(USER);
        assertEq(dsc.balanceOf(USER), 0);
        vm.expectRevert(DSCEngine.DSCEngine__AmountMustBeMoreThanZero.selector);
        dscEngine.mintDsc(0);
    }

    function testMintDSCRevertsIfCollateralIsNotEnough() public depositedCollateral(weth, dscEngine) {
        vm.startPrank(USER);
        (uint256 usdCollateral, uint256 decimals) = dscEngine.getAccountCollateralValueInUsd(USER);
        uint256 amountToMint = dsc.convertUsdAmountToDSC(usdCollateral, decimals);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorIsBelowMinimum.selector, 0));
        dscEngine.mintDsc(amountToMint);
    }

    function testMintDSCRevertsIfThereIsNoCollateral() public {
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorIsBelowMinimum.selector, 0));
        dscEngine.mintDsc(AMOUNT_COLLATERAL);
    }

    function testMintDSCSucceeds() public depositedCollateral(weth, dscEngine) {
        vm.startPrank(USER);
        (uint256 usdValue, uint256 usdDecimals) = dscEngine.getAccountCollateralValueInUsd(USER);
        (uint256 numeratorThreshold, uint256 denominatorThreshold) = dscEngine.getOvercollateralizationRatio();
        uint256 usdValueThreshold = usdValue * numeratorThreshold / denominatorThreshold;
        uint256 expectedDscToMint = dsc.convertUsdAmountToDSC(usdValueThreshold, usdDecimals);
        dscEngine.mintDsc(expectedDscToMint);
        assertEq(dsc.balanceOf(USER), expectedDscToMint);
    }

    ////////////////////
    // Burn DSC tests //
    ////////////////////

    function testBurnDSCRevertsIfAmountIsZero() public depositedCollateralAndMintedDsc(weth, dscEngine) {
        vm.startPrank(USER);
        assert(dsc.balanceOf(USER) > 0);
        vm.expectRevert(DSCEngine.DSCEngine__AmountMustBeMoreThanZero.selector);
        dscEngine.burnDsc(0);
    }

    function testBurnDSCRevertsIfDSCAmountIsGreaterThanMinted()
        public
        depositedCollateralAndMintedDsc(weth, dscEngine)
    {
        uint256 dscAmount = dsc.balanceOf(USER);
        vm.startPrank(USER);
        vm.expectRevert();
        dscEngine.burnDsc(dscAmount + 1);
    }

    function testBurnDSCIsSuccessful() public depositedCollateralAndMintedDsc(weth, dscEngine) {
        uint256 dscAmount = dsc.balanceOf(USER);
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), dscAmount);
        dscEngine.burnDsc(dscAmount);
        assertEq(dsc.balanceOf(USER), 0);
    }

    /////////////////////////////
    // Redeem collateral tests //
    /////////////////////////////
    function testRedeemCollateralRevertsIfAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__AmountMustBeMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
    }

    function testRedeemCollateralRevertsIfMaximumOfDSCIsMintedAndUserTriesToRedeemWithoutBurning()
        public
        depositedCollateralAndMintedDsc(weth, dscEngine)
    {
        vm.startPrank(USER);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorIsBelowMinimum.selector, 0));
        dscEngine.redeemCollateral(weth, 1);
    }

    function testCanRedeemCollateral() public depositedCollateralAndMintedDsc(weth, dscEngine) {
        vm.startPrank(USER);
        uint256 startingBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 dscBalance = dsc.balanceOf(USER);
        uint256 dscBurnAmount = dscBalance / 2;

        (, uint256 collateralValueInUsd, uint256 decimals) = dscEngine.getAccountInformation(USER);

        console.log(dscBurnAmount / 10 ** dsc.decimals());
        uint256 maximumCollateralThatCanBeRedeemedInWETH = dscEngine.getTokenAmountFromUsd(weth, dscBurnAmount);
        console.log(maximumCollateralThatCanBeRedeemedInWETH);

        dsc.approve(address(dscEngine), dscBurnAmount);
        dscEngine.burnDsc(dscBurnAmount);

        dscEngine.redeemCollateral(weth, maximumCollateralThatCanBeRedeemedInWETH);

        assertEq(ERC20Mock(weth).balanceOf(USER), startingBalance + maximumCollateralThatCanBeRedeemedInWETH);
    }

    function testCanRedeemAllCollateral() public depositedCollateral(weth, dscEngine) {
        vm.startPrank(USER);

        uint256 startingBalance = ERC20Mock(weth).balanceOf(USER);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);

        assertEq(ERC20Mock(weth).balanceOf(USER), startingBalance + AMOUNT_COLLATERAL);
    }

    function testRedeemCollateralRevertsIfUserDoenstPutAnyCollateral() public {
        vm.startPrank(USER);
        // underflow
        vm.expectRevert();
        dscEngine.redeemCollateral(weth, 1);
    }

    function testRedeemCollateralRevertsIfTransferFails() public {
        (DSCEngine engine, address mockErc20) = useFailedTransfersERC20();
        MockFailedERC20(mockErc20).setTransferFailures(true, false);

        vm.startPrank(USER);
        IERC20(mockErc20).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(mockErc20, AMOUNT_COLLATERAL);

        (uint256 totalDscMinted, uint256 collateralValueInUsd,) = engine.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
        assert(collateralValueInUsd > 0);

        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        engine.redeemCollateral(mockErc20, AMOUNT_COLLATERAL);

        (, uint256 collateralValueInUsdAfterFailedRedeem,) = engine.getAccountInformation(USER);
        assertEq(collateralValueInUsd, collateralValueInUsdAfterFailedRedeem);
    }

    /////////////////////////
    // Health factor tests //
    /////////////////////////

    function testIfUserHasntMintedAnyDSCHealthFactorIsMaxUint256() public {
        assertEq(dscEngine.getHealthFactor(USER), type(uint256).max);
    }

    /////////////////////
    // Liquidate tests //
    /////////////////////

    function testLiquidateRevertsIfUserHasntMintedAnyDSC() public depositedCollateralAndMintedDsc(weth, dscEngine) {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsFine.selector);
        dscEngine.liquidate(weth, makeAddr("random"), 1);
    }

    function testLiquidateRevertsIfLiquidatorDoenstHaveAnyDSC()
        public
        depositedCollateralAndMintedDsc(weth, dscEngine)
    {
        address liquidator = makeAddr("liquidator");

        (, int256 price,,,) = ethUsdPriceFeed.latestRoundData();

        int256 newPrice = int256(uint256(price) * PRICE_CHANGE_IN_PERCENTAGE / PERCENTAGE_DENOMINATOR);

        (, uint256 collateralValueInUsdBeforePriceDrops,) = dscEngine.getAccountInformation(USER);

        MockV3Aggregator(address(ethUsdPriceFeed)).updateAnswer(newPrice);
        (, int256 priceAfterUpdate,,,) = ethUsdPriceFeed.latestRoundData();

        (, uint256 collateralValueInUsdAfterPriceDrops,) = dscEngine.getAccountInformation(USER);

        assert(collateralValueInUsdBeforePriceDrops > collateralValueInUsdAfterPriceDrops);

        (uint256 debt,, uint256 debtDecimals) = dscEngine.getAccountInformation(USER);
        (uint256 numerator, uint256 denominator) = dscEngine.getOvercollateralizationRatio();
        uint256 debtToCover = debt * denominator * (PERCENTAGE_DENOMINATOR - PRICE_CHANGE_IN_PERCENTAGE)
            / PERCENTAGE_DENOMINATOR / numerator;

        vm.prank(liquidator);
        vm.expectRevert();
        dscEngine.liquidate(weth, USER, debtToCover);
    }

    function testLiquidateRevertsIfHealthFactorDoesntImprove()
        public
        depositedCollateralAndMintedDsc(weth, dscEngine)
    {
        address liquidator = makeAddr("liquidator");
        vm.prank(address(dscEngine));
        uint256 liquidationAmount = 10;
        dsc.mint(liquidator, liquidationAmount);

        vm.startPrank(liquidator);
        dsc.approve(address(dscEngine), liquidationAmount);

        (, int256 price,,,) = ethUsdPriceFeed.latestRoundData();

        int256 newPrice = int256(uint256(price) * PRICE_CHANGE_IN_PERCENTAGE / PERCENTAGE_DENOMINATOR);
        MockV3Aggregator(address(ethUsdPriceFeed)).updateAnswer(newPrice);

        (uint256 dscMintedBeforeLiquidation, uint256 totalUSDValueBeforeLiquidation,) =
            dscEngine.getAccountInformation(USER);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        dscEngine.liquidate(weth, USER, liquidationAmount);

        (uint256 dscMintedAfterLiquidation, uint256 totalUSDValueAfterLiquidation,) =
            dscEngine.getAccountInformation(USER);

        assertEq(dscMintedAfterLiquidation, dscMintedBeforeLiquidation);
        assertEq(totalUSDValueBeforeLiquidation, totalUSDValueAfterLiquidation);
    }

    function testLiquidateImprovesHealthFactor() public depositedCollateralAndMintedDsc(weth, dscEngine) {
        address liquidator = makeAddr("liquidator");
        uint256 liquidatorWethStartingBalance = IERC20(weth).balanceOf(liquidator);

        (, int256 price,,,) = ethUsdPriceFeed.latestRoundData();

        int256 newPrice = int256(uint256(price) * PRICE_CHANGE_IN_PERCENTAGE / PERCENTAGE_DENOMINATOR);
        MockV3Aggregator(address(ethUsdPriceFeed)).updateAnswer(newPrice);

        (uint256 debt,,) = dscEngine.getAccountInformation(USER);
        (uint256 numerator, uint256 denominator) = dscEngine.getOvercollateralizationRatio();
        uint256 debtToCover = debt * numerator / denominator;

        uint256 expectedCollateralGainForLiquidator = dscEngine.getTokenAmountFromUsd(weth, debtToCover);
        expectedCollateralGainForLiquidator = expectedCollateralGainForLiquidator
            * (LIQUIDATOR_BONUS_PERCENTAGE + PERCENTAGE_DENOMINATOR) / PERCENTAGE_DENOMINATOR;

        vm.prank(address(dscEngine));
        dsc.mint(liquidator, debtToCover);
        uint256 liquidatorDscStartingBalance = dsc.balanceOf(liquidator);

        vm.startPrank(liquidator);
        dsc.approve(address(dscEngine), debtToCover);
        dscEngine.liquidate(weth, USER, debtToCover);

        (uint256 newDebt,,) = dscEngine.getAccountInformation(USER);
        assertEq(debt - debtToCover, newDebt);

        assertEq(
            IERC20(weth).balanceOf(liquidator), liquidatorWethStartingBalance + expectedCollateralGainForLiquidator
        );
        assertEq(IERC20(dsc).balanceOf(liquidator), liquidatorDscStartingBalance - debtToCover);
    }

    function testTruncate() public view {
        bytes32 val = 0x0112233445566778899aabbccddeeff99112233445566778899aabbccddeeff0;
        console.logBytes20(bytes20(val));

        console.log(uint256(0x0112233445566778899aabbccddeeff99112233445566778899aabbccddeeff0));
        console.log(uint256(0x1112233445566778899aabbccddeeff99112233445566778899aabbccddeeff0));

        console.logBytes32(bytes32(bytes20(val)));
    }
}
