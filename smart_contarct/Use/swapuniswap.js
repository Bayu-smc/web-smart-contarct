await usdc.approve(defiHubAddress, amountIn);
await defiHub.swap(usdcAddress, wethAddress, 3000, amountIn, minOut);