// scripts/deploy.js
const { ethers } = require("hardhat");

async function main() {
  const SWAP_ROUTER = "0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48";
  const AAVE_POOL   = "0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951";
  const BRIDGE      = ethers.ZeroAddress; // isi jika ada bridge

  const DeFiHub = await ethers.getContractFactory("DeFiHub");
  const defiHub = await DeFiHub.deploy(SWAP_ROUTER, AAVE_POOL, BRIDGE);

  await defiHub.waitForDeployment();
  console.log("DeFiHub deployed to:", await defiHub.getAddress());
}

main().catch(console.error);