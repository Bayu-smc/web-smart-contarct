// 1. Approve token ke contract DeFiHub
await usdc.approve(defiHubAddress, amount);
// 2. Supply
await defiHub.supply(usdcAddress, amount);