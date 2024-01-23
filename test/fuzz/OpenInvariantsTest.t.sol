// // SPDX-License-Identifier: MIT
// // Have our invariants(properties)

// // What are our invariants?

// // 1. The total supply of DSC should be less than the total value of collateral
// // 2. Getter view functions should never revert <- evergreen

// pragma solidity ^0.8.18;

// import {Test} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

// contract OpenInvariantsTest is StdInvariant, Test {
//     DeployDSC deployer;
//     DSCEngine dscEngine;
//     DecentralizedStableCoin dsc;
//     HelperConfig helperConfig;
//     address weth;
//     address wbtc;

//     function setUp() external {
//         deployer = new DeployDSC();
//         (dsc, dscEngine, helperConfig) = deployer.run();
//         targetContract(address(dscEngine));
//         (,, weth, wbtc,) = helperConfig.activeNetworkConfig();
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         // get value of all the collateral
//         // compare it to all the debt

//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
//         uint256 totalBtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine));

//         (uint256 wethUsdValue, uint256 wethUsdDecimals) = dscEngine.getUsdValue(weth, totalWethDeposited);
//         (uint256 btcUsdValue, uint256 btcUsdDecimals) = dscEngine.getUsdValue(wbtc, totalBtcDeposited);

//         assert(
//             totalSupply
//                 <= dsc.convertUsdAmountToDSC(wethUsdValue, wethUsdDecimals)
//                     + dsc.convertUsdAmountToDSC(btcUsdValue, btcUsdDecimals)
//         );
//     }
// }
