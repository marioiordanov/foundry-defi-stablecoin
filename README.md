1. Relative Stability (Anchored/Pegged) -> $1.00
   1. Chainlink Price Feed
   2. Set a function to exchange ETH & BTC -> $$$
2. Stability Mechanism (Minting): Algorithmic (Decentralized)
   1. People can only mint stable coin with enough collateral
3. Collateral: Exogenous (Crypto)
   1. wETH
   2. wBTC




Example workflow

1. User deposits collateral of Token ETH with precision 18 -> 1ETH - 1e18
2. User tries to mint 50 DSC tokens
   1. user minted DSC tokens +=50
   2. ETH/USD -> 2000 USD comes in the form 2000 * 1e8
   3. collateral value is price - 2000* 1e8 * ADDITIONAL_FEED_PRECISION * amount / PRECISION = 2000 * 1e8 * 1e10 * 1e18 / 1e18 = 2000 * 1e18
   4. total dsc minted - 50, total collateral value - 2000 * 1e18
   5. collateralValueAdjustedForThreshold - collateral value * 50 / 100 = 1000 * 1e18
   6. 1000 * 1e18 * 1e18/total dsc minted = 1000 * 1e36 / 50 = 20 * 1e36 > 1e18

if dsc minted = 2000 * 1e18
1000 * 1e18 * 1e18 / 2000* 1e18 = 1e18/2 = 5*1e17 <? 1e18

this is if dsc has 18 decimals
what if dsc have 2 decimals like real USD

the value of 500 will be 5 DSC => 5USD

if dsc minted = 2000 * 1e2
1000 * 1e18*1e18 / 2000 * 1e2

