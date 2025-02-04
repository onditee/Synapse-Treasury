// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


interface IAavePool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external;
}

contract Treasury is ReentrancyGuard {
    // STATE VARIABLES
    address public owner;
    address public proposalsContract;
    
    mapping(address => uint256) public tokenBalances;
    mapping(address => mapping(address => uint256)) public aaveDeposits; // [user][token] => amount

    IAavePool public constant AAVE_POOL = IAavePool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    
    // EVENTS
    event FundsDeposited(address indexed token, uint256 amount);
    event FundsWithdrawn(address indexed token, uint256 amount);
    event DefiDeposit(address indexed token, uint256 amount);
    event DefiWithdrawal(address indexed token, uint256 amount);

    // MODIFIERS
    modifier onlyOwner() {
        require(msg.sender == owner, "Unauthorized");
        _;
    }

    modifier onlyProposals() {
        require(msg.sender == proposalsContract, "Only proposals contract");
        _;
    }

    // CONSTRUCTOR
    constructor() {
        owner = msg.sender;
        
    }

    // CORE FUNCTIONS
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function executeTransfer(
        address payable _to,
        uint256 _amount,
        address _token
    ) external onlyProposals nonReentrant {
        if (_token == address(0)) {
            (bool sent, ) = _to.call{value: _amount}("");
            require(sent, "ETH transfer failed");
        } else {
            require(IERC20(_token).transfer(_to, _amount), "Token transfer failed");
        }
        tokenBalances[_token] -= _amount;
    }

    // DEFI INTEGRATIONS
    function depositToAave(
        address _token,
        uint256 _amount
    ) external onlyProposals nonReentrant {
        IERC20(_token).approve(address(AAVE_POOL), _amount);
        AAVE_POOL.deposit(_token, _amount, address(this), 0);
        aaveDeposits[address(this)][_token] += _amount;
        emit DefiDeposit(_token, _amount);
    }

    function withdrawFromAave(
        address _token,
        uint256 _amount
    ) external onlyProposals nonReentrant {
        AAVE_POOL.withdraw(_token, _amount, address(this));
        aaveDeposits[address(this)][_token] -= _amount;
        emit DefiWithdrawal(_token, _amount);
    }

    // ADMIN FUNCTIONS
    function setProposalsContract(address _proposals) external onlyOwner {
        proposalsContract = _proposals;
    }

    function emergencyWithdraw(
        address _token,
        uint256 _amount
    ) external onlyOwner {
        if (_token == address(0)) {
            payable(owner).transfer(_amount);
        } else {
            IERC20(_token).transfer(owner, _amount);
        }
    }

    // Accept ETH deposits
    receive() external payable {
        tokenBalances[address(0)] += msg.value;
        emit FundsDeposited(address(0), msg.value);
    }
}