// scripts/deploy.js
const { ethers } = require("hardhat");
require("dotenv").config();

async function main() {
  // Get deployer account
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);

  // Deploy the Treasury contract first
  const Treasury = await ethers.getContractFactory("Treasury");
  const treasury = await Treasury.deploy();
  await treasury.waitForDeployment();

  const treasuryAddress = await treasury.getAddress();

  console.log("Treasury deployed at:", treasuryAddress);


  //Verify connectivity by calling getBalance()
  let treasuryBalance = await treasury.getBalance();
  console.log("Initial Treasury balance:", treasuryBalance.toString());


  //Deploy the SynapseProposals contract with Treasury address as a parameter
  const SynapseProposals = await ethers.getContractFactory("SynapseProposals");
  const synapseProposals = await SynapseProposals.deploy(treasuryAddress);
  await synapseProposals.waitForDeployment();

  const proposalAddress = await synapseProposals.getAddress();

  console.log("SynapseProposals deployed at:", proposalAddress);

  //Link the SynapseProposals contract to the Treasury contract
  const setProposalTx = await treasury.setProposalsContract(proposalAddress);
  await setProposalTx.wait();
  console.log("Treasury proposals contract set to:", proposalAddress);

  // Debug: log the environment variables to ensure they are loaded
  console.log("CDP_API_KEY_NAME:", process.env.CDP_API_KEY_NAME);
  console.log("CDP_API_KEY_PRIVATE_KEY:", process.env.CDP_API_KEY_PRIVATE_KEY);
  console.log("NETWORK_ID:", process.env.NETWORK_ID);

  //Initialize the Coinbase AgentKit agent
  const { CdpWalletProvider, AgentKit } = require("@coinbase/agentkit");

  //using environment variables to create or load an agent
  const walletProvider = await CdpWalletProvider.configureWithWallet({
    apiKeyName: process.env.CDP_API_KEY_NAME,
    apiKeyPrivate: process.env.CDP_API_KEY_PRIVATE_KEY,
    networkId: process.env.NETWORK_ID || "base-sepolia",
  });

   // Create an AgentKit instance from the wallet provider
   const agentKit = await AgentKit.from({
    walletProvider,
  });

  //Agent's wallet address
  const agentWalletAddress = agentKit.getAddress()
  console.log("AgentKit agent wallet address:", agentWalletAddress);

  //Set Agent as the agentKitOperator in the Treasury contract
  const setAgentTx = await treasury.setAgentKitOperator(agentWalletAddress);
  await setAgentTx.wait();
  console.log("LFGGG!!! Treasury agent operator set to:", agentWalletAddress);

  //Add deployer as an authorized proposer with voting power Corruption LOL
  const proposerTx = await synapseProposals.addProposer(deployer.address, 100);
  await proposerTx.wait();
  console.log("Deployer added as authorized proposer with voting power 100 - You can stay mad ;D");

  //Create 3 Agents as DAO members 
  console.log("Creating 3 autonomous proposal agents...");
  for (let i = 0; i < 3; i++) {
    const randomWallet = ethers.Wallet.createRandom();
    // Connect the wallet to your provider
    const agentSigner = randomWallet.connect(ethers.provider);
    // Add this agent as an authorized agent (voting power 50)
    const addAgentTx = await synapseProposals.addAgent(agentSigner.address, 50);
    await addAgentTx.wait();
    console.log(`Autonomous Proposal Agent ${i+1} added: ${agentSigner.address} with 50 voting power`);
  }

}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment error:",error);
    process.exit(1);
  });