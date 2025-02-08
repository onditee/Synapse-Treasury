import { AgentKit } from '@coinbase/agentkit';
import { ethers } from 'ethers';
import TreasuryABI from './TreasuryABI.json';
import config from './agent-config.json';

class RebalanceAgent {
  constructor() {
    this.provider = new ethers.JsonRpcProvider(config.rpcUrl);
    this.treasury = new ethers.Contract(
      config.treasuryAddress,
      TreasuryABI,
      this.provider
    );
    
    this.agent = new AgentKit({
      name: 'TreasuryRebalancer',
      pollingInterval: config.checkInterval * 1000
    });
  }

  async start() {
    this.agent.registerTrigger({
      name: 'check-allocation',
      execute: async () => {
        // Use getWethAllocation instead of getEthAllocation
        const wethAlloc = await this.treasury.getWethAllocation();
        const totalValue = await this.treasury.getTotalValue();
        
        return {
          wethAllocation: wethAlloc,
          totalValue: totalValue.toString()
        };
      },
      condition: (result) => {
        // Compare wethAllocation with the ETH thresholds in config
        return result.wethAllocation > config.thresholds.ETH.max || 
               result.wethAllocation < config.thresholds.ETH.min;
      }
    });

    this.agent.registerAction({
      name: 'execute-rebalance',
      trigger: 'check-allocation',
      execute: async (signer) => {
        // Create a contract instance connected to the signer so we can send a transaction.
        const contract = new ethers.Contract(
          config.treasuryAddress,
          TreasuryABI,
          signer
        );
        
        const tx = await contract.checkAndRebalance();
        return tx.waitForReceipt();
      }
    });

    this.agent.start();
  }
}

new RebalanceAgent().start();
