// scripts/deploy.js
const { ethers } = require("hardhat");

async function main() {
  // Sepolia Testnet Addresses
  const SEPOLIA_ADDRESSES = {
    AAVE_POOL: "0x368EedF3f56ad10b9bC57eed4Dac65B26Bb667f6",
    USDC: "0xEbCC972B6B3eB15C0592BE1871838963d0B94278",
    DAI: "0xe5118E47e061ab15Ca972D045b35193F673bcc36",
    WETH: "0xA1A245cc76414DC143687D9c3DE1152396f352D6"
  };

  // Get deployer account
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);

  // Deploy SynapseProposals first
  const SynapseProposals = await ethers.getContractFactory("SynapseProposals");
  const synapseProposals = await SynapseProposals.deploy();
  await synapseProposals.waitForDeployment();
  console.log("SynapseProposals deployed to:", synapseProposals.target);

  // Deploy Treasury with Sepolia addresses
  const Treasury = await ethers.getContractFactory("Treasury");
  const treasury = await Treasury.deploy();
  await treasury.waitForDeployment();
  console.log("Treasury deployed to:", treasury.target);

  // Initialize contracts
  console.log("Initializing contracts...");
  const tx1 = await treasury.setProposalsContract(synapseProposals.target);
  await tx1.wait();
  console.log("Proposals contract set in Treasury");

  // Set AgentKit operator if needed
  const tx2 = await treasury.setAgentKitOperator(agentAddress);
  await tx2.wait();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });