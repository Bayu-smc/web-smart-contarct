await dai.approve(defiHubAddress, repayAmount);
await defiHub.repay(daiAddress, repayAmount, 2);