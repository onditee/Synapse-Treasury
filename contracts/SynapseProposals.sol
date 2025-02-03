// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ITreasury {
    function getBalance() external view returns (uint256);
    function executeTransfer(address recipient, uint256 amount) external;
}

contract SynapseProposals {
    //STRUCTS AND ENUMS DEFINITIONS (voting options, proposal types)
    enum VoteOption { YES, NO, ABSTAIN }
    enum ProposalType { INVESTMENT, CHARITY, PROJECT, OTHER }
    
    struct Proposal {
        address proposer;
        ProposalType pType;
        uint256 amount;
        uint256 createdAt;
        uint256 deadline;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 abstainVotes;
        bool executed;
        bool isAgentProposal;
        string metadataCID; // IPFS CID for proposal metadata
    }

    // STATE VARIABLES
    ITreasury public treasury;
    address public owner;
    
    uint256 public constant QUORUM_PERCENT = 20; // 20% minimum participation
    uint256 public constant VOTE_DURATION = 7 days;
    uint256 public constant MAX_TREASURY_PERCENT = 10; // Max 10% per proposal
    
    mapping(address => bool) public authorizedProposers;
    mapping(address => bool) public authorizedAgents;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    
    uint256 public proposalCount;

    // EVENTS
    event ProposalCreated(
        uint256 indexed id,
        address indexed proposer,
        ProposalType pType,
        uint256 amount,
        bool isAgentProposal,
        string metadataCID
    );
    
    event Voted(
        uint256 indexed proposalId,
        address indexed voter,
        VoteOption vote,
        bool isAgentVote
    );
    event ProposalExecuted(
        uint256 indexed proposalId,
        address executor
    );

    //  MODIFIERS
    modifier onlyOwner() {
        require(msg.sender == owner, "Unauthorized");
        _;
    }

    modifier onlyProposer() {
        require(authorizedProposers[msg.sender], "Not authorized proposer");
        _;
    }

    modifier onlyAgent() {
        require(authorizedAgents[msg.sender], "Not authorized agent");
        _;
    }

    //CONSTRUCTOR 
    constructor(address _treasury) {
        owner = msg.sender;
        treasury = ITreasury(_treasury);
    }

    //CORE FUNCTIONS 
    function createProposal(
        ProposalType _type,
        uint256 _amount,
        bool _isAgentProposal,
        string memory _metadataCID
    ) public returns (uint256) {
        require(bytes(_metadataCID).length > 0, "Metadata required");
        // Validate proposer type
        if(_isAgentProposal) {
            require(authorizedAgents[msg.sender], "Agent not authorized");
        } else {
            require(authorizedProposers[msg.sender], "Proposer not authorized");
        }

        // Validate amount
        uint256 treasuryBalance = treasury.getBalance();
        require(
            _amount <= (treasuryBalance * MAX_TREASURY_PERCENT) / 100,
            "Amount exceeds max percentage"
        );

        Proposal storage newProposal = proposals[proposalCount];
        newProposal.proposer = msg.sender;
        newProposal.pType = _type;
        newProposal.amount = _amount;
        newProposal.createdAt = block.timestamp;
        newProposal.deadline = block.timestamp + VOTE_DURATION;
        newProposal.isAgentProposal = _isAgentProposal;
        newProposal.metadataCID = _metadataCID;

        emit ProposalCreated(
            proposalCount,
            msg.sender,
            _type,
            _amount,
            _isAgentProposal,
            _metadataCID
        );

        return proposalCount++;
    }

    function vote( uint256 _proposalId, VoteOption _vote, bool _isAgentVote) public {
        Proposal storage proposal = proposals[_proposalId];
        require(block.timestamp <= proposal.deadline, "Voting period ended");
        require(!hasVoted[_proposalId][msg.sender], "Already voted");

        // Agent validation
        if(_isAgentVote) {
            require(authorizedAgents[msg.sender], "Unauthorized agent vote");
        }

        // Record vote
        hasVoted[_proposalId][msg.sender] = true;
        
        if(_vote == VoteOption.YES) proposal.yesVotes++;
        else if(_vote == VoteOption.NO) proposal.noVotes++;
        else proposal.abstainVotes++;

        emit Voted(_proposalId, msg.sender, _vote, _isAgentVote);
    }

    function executeProposal(uint256 _proposalId) external {
        Proposal storage proposal = proposals[_proposalId];
        require(!proposal.executed, "Already executed");
        require(block.timestamp > proposal.deadline, "Voting ongoing");

        // Calculate quorum
        uint256 totalVotes = proposal.yesVotes + proposal.noVotes + proposal.abstainVotes;
        uint256 quorum = (treasury.getBalance() * QUORUM_PERCENT) / 100;
        require(totalVotes >= quorum, "Quorum not met");

        // Check majority
        require(proposal.yesVotes > proposal.noVotes, "Proposal rejected");

        proposal.executed = true;
        // Execute fund transfer
        address recipientAddress = proposal.proposer;
        treasury.executeTransfer(recipientAddress, proposal.amount);

        // Emit event for proposal execution
        emit ProposalExecuted(_proposalId, msg.sender);
        
    }

    // AGENTIC FUNCTIONS 
    function agentCreateProposal(
        ProposalType _type,
        uint256 _amount,
        string memory _metadataCID
    ) external onlyAgent returns (uint256) {
        return createProposal(_type, _amount, true, _metadataCID);
    }

    function agentVote(uint256 _proposalId, VoteOption _vote) external onlyAgent {
        vote(_proposalId, _vote, true);
    }

    //ADMIN FUNCTIONS 
    function addProposer(address _proposer) external onlyOwner {
        authorizedProposers[_proposer] = true;
    }

    function addAgent(address _agent) external onlyOwner {
        authorizedAgents[_agent] = true;
    }

    function updateTreasury(address _newTreasury) external onlyOwner {
        treasury = ITreasury(_newTreasury);
    }
}