import { AgentKit } from '@agentkit/core';
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
        const ethAlloc = await this.treasury.getEthAllocation();
        const totalValue = await this.treasury.getTotalValue();
        
        return {
          ethAllocation: ethAlloc,
          totalValue: totalValue.toString()
        };
      },
      condition: (result) => {
        return result.ethAllocation > config.thresholds.ETH.max || 
               result.ethAllocation < config.thresholds.ETH.min;
      }
    });

    this.agent.registerAction({
      name: 'execute-rebalance',
      trigger: 'check-allocation',
      execute: async (signer) => {
        const contract = new ethers.Contract(
          config.treasuryAddress,
          TreasuryABI,
          signer
        );
        
        const tx = await contract.checkAndRebalance();
        return tx.wait();
      }
    });

    this.agent.start();
  }
}

new RebalanceAgent().start();