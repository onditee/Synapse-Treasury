// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "c:/Users/Ted/node_modules/@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "c:/Users/Ted/node_modules/@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "c:/Users/Ted/node_modules/@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

interface IAavePool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external;
    function getReserveData(address asset) external view returns (uint256, address);
}

//Interface for Erc20 metadata
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}
contract Treasury is ReentrancyGuard {

    AggregatorV3Interface internal ethPriceFeed; //= AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419); // ETH/USD Mainnet
    mapping(address => AggregatorV3Interface) public priceFeeds; // Token -> Price Feed 
    // STATE VARIABLES
    address public owner;
    address public proposalsContract;
    
    mapping(address => uint256) public tokenBalances; 
    mapping(address => uint256) public aavePrincipal; // Tracks principal deposited to Aave per token
    mapping(address => uint256) public yieldGenerated; // Tracks interest earned per token
    mapping(address => address) public aTokenMapping; // Maps underlying tokens to their aToken addresses

    IAavePool public constant AAVE_POOL = IAavePool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    uint256 public constant MAX_AAVE_EXPOSURE = 80; // 80% of treasury

    // EVENTS
    event FundsDeposited(address indexed token, uint256 amount);
    event FundsWithdrawn(address indexed token, uint256 amount);
    event DefiDeposit(address indexed token, uint256 amount);
    event DefiWithdrawal(address indexed token, uint256 amount);
    event YieldEarned(address token, uint256 amount);

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
        ethPriceFeed = AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        //Other price feeds
        priceFeeds[0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = AggregatorV3Interface(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6); // USDC/USD
        priceFeeds[0x6B175474E89094C44Da98b954EedeAC495271d0F] = AggregatorV3Interface(0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9); // DAI/USD
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
        require(
            IERC20(_token).balanceOf(address(this)) >= _amount,
            "Insufficient token balance"
        );

        //Check to make sure we are not exceeding Max aave exposure
        uint256 maxDeposit = (getTotalValue() * MAX_AAVE_EXPOSURE) / 100;
        
        require(_amount <= maxDeposit, "Exceeds Aave cap");

        // Update token balance before transfer to Aave
        tokenBalances[_token] -= _amount;
        
        // Get aToken address if not already mapped
        if (aTokenMapping[_token] == address(0)) {
            (, address aToken) = AAVE_POOL.getReserveData(_token);
            aTokenMapping[_token] = aToken;
        }
        IERC20(_token).approve(address(AAVE_POOL), _amount);
        AAVE_POOL.deposit(_token, _amount, address(this), 0);
        
        // Track principal deposited
        aavePrincipal[_token] += _amount;
        
        emit DefiDeposit(_token, _amount);
    }

    function withdrawFromAave(
        address _token,
        uint256 _amount
    ) external onlyProposals nonReentrant {
        require(
            aavePrincipal[_token] >= _amount,
            "Withdrawal exceeds principal"
        );

        address aToken = aTokenMapping[_token];
        uint256 currentATokenBalance = IERC20(aToken).balanceOf(address(this));

        //Yeild calculation
        uint256 principal = aavePrincipal[_token];

        uint256 yield = (currentATokenBalance * _amount) / principal - _amount;

        AAVE_POOL.withdraw(_token, _amount, address(this));
        
        //Updated balances and tracking
        
        tokenBalances[_token] += _amount + yield;
        aavePrincipal[_token] -= _amount;
        yieldGenerated[_token] += yield;

        emit DefiWithdrawal(_token, _amount);
        emit YieldEarned(_token, yield);
    }

    //Asset Valuation Helper 
    function getAavePositionValue(address _token) public view returns (uint256) {
        
        address aToken = aTokenMapping[_token];
        return IERC20(aToken).balanceOf(address(this));
        
    }
    //Oracle Functions
    function getAssetValue(address token) public view returns (uint256) {
        
        if(token == address(0)) { // ETH
            uint256 ethPrice = getLatestPrice(ethPriceFeed);
            return (tokenBalances[token] * ethPrice) / (10 ** ethPriceFeed.decimals());
        }

        AggregatorV3Interface feed = priceFeeds[token];
        require(address(feed) != address(0), "Price feed not found");
        
        uint256 tokenPrice = getLatestPrice(feed);
        uint256 tokenDecimals = 10 ** IERC20Metadata(token).decimals();
        
        return (tokenBalances[token] * tokenPrice) / tokenDecimals;
    }

    function getTotalValue() public view returns (uint256) {
        
        uint256 total = getAssetValue(address(0)); // ETH value
        
        //Stablecoin values
        address[] memory stablecoins = new address[](2);
        stablecoins[0] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
        stablecoins[1] = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // DAI
        
        for(uint256 i = 0; i < stablecoins.length; i++) {
            total += getAssetValue(stablecoins[i]);
        }
        
        return total;
    }

    function getEthAllocation() public view returns (uint256) {
        
        uint256 ethValue = getAssetValue(address(0));
        uint256 totalValue = getTotalValue();
        return (ethValue * 100) / totalValue;
    }


    function getLatestPrice(AggregatorV3Interface priceFeed) internal view returns (uint256) {
        (
            ,
            int256 price,
            ,
            uint256 timeStamp,
        ) = priceFeed.latestRoundData();
        
        require(price > 0, "Invalid price");
        require(timeStamp >= block.timestamp - 1 hours, "Stale price");
        
        return uint256(price);
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
    function updatePriceFeed(address token, address feed) external onlyOwner {

        require(feed != address(0), "Invalid feed address");
        priceFeeds[token] = AggregatorV3Interface(feed);
    }

    // Accept ETH deposits
    receive() external payable {
        tokenBalances[address(0)] += msg.value;
        emit FundsDeposited(address(0), msg.value);
    }
}