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
  console.log("Treasury deployed at:", treasury.address);


  //Verify connectivity by calling getBalance()
  let treasuryBalance = await treasury.getBalance();
  console.log("Initial Treasury balance:", treasuryBalance.toString());


  //Deploy the SynapseProposals contract with Treasury address as a parameter
  const SynapseProposals = await ethers.getContractFactory("SynapseProposals");
  const synapseProposals = await SynapseProposals.deploy(treasury.address);
  await synapseProposals.waitForDeployment();
  console.log("SynapseProposals deployed at:", synapseProposals.address);

  //Link the SynapseProposals contract to the Treasury contract
  const setProposalTx = await treasury.setProposalsContract(synapseProposals.address);
  await setProposalTx.wait();
  console.log("Treasury proposals contract set to:", synapseProposals.address);

  //Initialize the Coinbase AgentKit agent
  const { initializeAgent } = require("@coinbase/agentkit");

  //using environment variables to create or load an agent
  const agent = await initializeAgent({
    apiKeyName: process.env.CDP_API_KEY_NAME,
    apiKeyPrivateKey: process.env.CDP_API_KEY_PRIVATE_KEY,
    openAIApiKey: process.env.OPENAI_API_KEY,
    networkId: process.env.NETWORK_ID || "base-sepolia"
  });

  //Agent's wallet address
  const agentWalletAddress = agent.wallet.address;
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