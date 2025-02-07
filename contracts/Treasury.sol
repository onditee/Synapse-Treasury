// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "c:/Users/Ted/node_modules/@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "c:/Users/Ted/node_modules/@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "c:/Users/Ted/node_modules/@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "c:/Users/Ted/node_modules/@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

interface IAavePool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external;
    function getReserveData(address asset) external view returns (uint256, address);
}

//Interface for Erc20 metadata
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint) external;
}
contract Treasury is ReentrancyGuard {

    AggregatorV3Interface internal ethPriceFeed; //= AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419); // ETH/USD Mainnet
    mapping(address => AggregatorV3Interface) public priceFeeds; // Token -> Price Feed 
    // STATE VARIABLES
    address public owner;
    address public proposalsContract;
    IUniswapV2Router02 public uniswapRouter = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    address public agentKitOperator;

    struct AssetConfig {
        uint256 target;         // Target allocation percentage (100 = 1%)
        uint256 upperThreshold; // Max deviation above target
        uint256 lowerThreshold; // Max deviation below target
        address[] swapPath;     // Default swap path for rebalancing
    }
    
    mapping(address => uint256) public tokenBalances; 
    mapping(address => uint256) public aavePrincipal; // Tracks principal deposited to Aave per token
    mapping(address => uint256) public yieldGenerated; // Tracks interest earned per token
    mapping(address => address) public aTokenMapping; // Maps underlying tokens to their aToken addresses
    mapping(address => AssetConfig) public assetConfigs;
    
    //Constants
    IAavePool public constant AAVE_POOL = IAavePool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    uint256 public constant MAX_AAVE_EXPOSURE = 80; // 80% of treasury
    uint256 public constant MAX_SLIPPAGE = 5; // 5% slippage protection
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    IWETH public constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // EVENTS
    event FundsDeposited(address indexed token, uint256 amount);
    event FundsWithdrawn(address indexed token, uint256 amount);
    event DefiDeposit(address indexed token, uint256 amount);
    event DefiWithdrawal(address indexed token, uint256 amount);
    event YieldEarned(address token, uint256 amount);
    //event RebalanceTriggered(address indexed asset, uint256 amountSold, uint256 amountBought);
    event AllocationConfigured(address indexed asset, uint256 target, uint256 upper, uint256 lower);
    event RebalanceSuggested(uint256 timestamp, address[] assets, uint256[] allocations);
    event SwapExecuted( address indexed assetSold, address indexed assetBought,uint256 amountSold, uint256 amountBought);
    event RebalanceCycle(address indexed triggerer,uint256 totalValueBefore, uint256 totalValueAfter, uint256 ethBefore, uint256 ethAfter);

    // MODIFIERS
    modifier onlyOwner() {
        require(msg.sender == owner, "Unauthorized");
        _;
    }

    modifier onlyProposals() {
        require(msg.sender == proposalsContract, "Only proposals contract");
        _;
    }
    modifier onlyAgentKit() {
        require(msg.sender == agentKitOperator, "Only AgentKit");
        _;
    }

    // Asset configuration management
    function configureAsset(
        address _asset,
        uint256 _target,
        uint256 _upperThreshold,
        uint256 _lowerThreshold,
        address[] calldata _swapPath) external onlyOwner {
            require(_target + _upperThreshold <= 100, "Invalid thresholds");
            
            assetConfigs[_asset] = AssetConfig({
                target: _target,
                upperThreshold: _upperThreshold,
                lowerThreshold: _lowerThreshold,
                swapPath: _swapPath
                });
        emit AllocationConfigured(_asset, _target, _upperThreshold, _lowerThreshold);
    }

    // CONSTRUCTOR
    constructor() {
        owner = msg.sender;
        ethPriceFeed = AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        //Other price feeds
        priceFeeds[0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = AggregatorV3Interface(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6); // USDC/USD
        priceFeeds[0x6B175474E89094C44Da98b954EedeAC495271d0F] = AggregatorV3Interface(0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9); // DAI/USD
        
        //ETH
        // WETH->USDC
        //configureAsset(address(0), 30, 5, 5, [address(WETH), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48]);

        //UNI
        // UNI->WETH->USDC
        //configureAsset(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984, 10, 3, 3, [0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984, address(WETH), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48]);
    }

    // CORE FUNCTIONS
    //will need to update this - only eth is shown
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

    // Core rebalancing logic
    function _rebalanceAsset(address _asset, uint256 _totalValue) internal {
        AssetConfig memory config = assetConfigs[_asset];
        if(config.target == 0) return;

        uint256 currentAllocation = (getAssetValue(_asset) * 100) / _totalValue;
        
        if(currentAllocation > config.target + config.upperThreshold) {
            _sellExcess(_asset, _totalValue, currentAllocation, config);
        }
        else if(currentAllocation < config.target - config.lowerThreshold) {
            _buyNeeded(_asset, _totalValue, currentAllocation, config);
        }
    }

    function checkAndRebalance() external onlyAgentKit nonReentrant {
        uint256 totalBefore = getTotalValue();
        uint256 ethBefore = getAssetValue(address(0));

        uint256 totalValue = getTotalValue();
        require(totalValue > 0, "No assets to rebalance");
        
        // Check ETH allocation first
        _rebalanceAsset(address(0), totalValue);
        
        // Check configured assets
        address[] memory tokens = new address[](4);
        tokens[0] = address(WETH);
        tokens[1] = USDC;
        tokens[2] = DAI;
        tokens[3] = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984; // UNI

        
        for(uint256 i = 0; i < tokens.length; i++) {
            _rebalanceAsset(tokens[i], totalValue);
        }
        uint256 ethAfter = getAssetValue(address(0));
        emit RebalanceCycle(msg.sender,totalBefore,getTotalValue(),ethBefore, getAssetValue(address(0)));
    }

    function _sellExcess(address _asset, uint256 _totalValue, uint256 _currentAlloc, AssetConfig memory _config) internal {
        uint256 excessPercentage = _currentAlloc - _config.target;
        uint256 excessValue = (excessPercentage * _totalValue) / 100;
        
        // Calculate slippage-protected minimum
        uint256 minOut = _getMinOutput(_asset, _config.swapPath, excessValue);
        
        if(_asset == address(0)) { // ETH
            _swapEthForStable(excessValue, minOut, _config.swapPath);
        } else {
            _swapTokenForStable(_asset, excessValue, minOut, _config.swapPath);
        }
    }

    function _swapEthForStable(uint256 _amount, uint256 _minOut, address[] memory _path) internal {
        uniswapRouter.swapExactETHForTokens{value: _amount}(
            _minOut,
            _path,
            address(this),
            block.timestamp + 15 minutes
        );
        tokenBalances[address(0)] -= _amount;
        tokenBalances[_path[_path.length-1]] += _minOut;
    }

    function _getMinOutput(address _asset, address[] memory _path, uint256 _amount) internal view returns (uint256) {
        uint256 price = _asset == address(0) ? 
            getLatestPrice(ethPriceFeed) :
            getLatestPrice(priceFeeds[_asset]);
            
        uint256 expectedOut = (_amount * price) / (10 ** 18); // Price in USD with 18 decimals
        return (expectedOut * (100 - MAX_SLIPPAGE)) / 100;
    }

    function _buyNeeded(
        address _asset,
        uint256 _totalValue,
        uint256 _currentAlloc,
        AssetConfig memory _config
        ) internal {
            
            uint256 deficitPercentage = _config.target - _currentAlloc;
            uint256 deficitValue = (deficitPercentage * _totalValue) / 100;
            
            // Determine which stablecoin to use for purchase
            address stablecoin = _findBestStableSource(deficitValue);
            
            // Calculate slippage-protected maximum input
            uint256 maxIn = _getMaxInput(_asset, _config.swapPath, deficitValue);
            
            if(_asset == address(0)) {
                // ETH
                _swapStableForEth(maxIn, deficitValue, _config.swapPath);
            } else {
                _swapStableForToken(_asset, maxIn, deficitValue, stablecoin, _config.swapPath);
                }
                
        }

    function _swapStableForToken(
        address _targetToken,
        uint256 _maxStableAmount,
        uint256 _minTokenAmount,
        address _stablecoin,
        address[] memory _path) internal nonReentrant {
            
            require(_path[0] == _stablecoin, "Path must start with stablecoin");
            require(_path[_path.length-1] == _targetToken, "Path must end with target");
            
            // Verify stablecoin balance
            
            require( tokenBalances[_stablecoin] >= _maxStableAmount,"Insufficient stable balance");
            
            // Approve and swap
            
            IERC20(_stablecoin).approve(address(uniswapRouter), _maxStableAmount);
            
            uniswapRouter.swapTokensForExactTokens(
                _minTokenAmount,
                _maxStableAmount,
                _path,
                address(this),
                block.timestamp + 15 minutes
                );
                
            // Update balances
            
            tokenBalances[_stablecoin] -= _maxStableAmount;
            tokenBalances[_targetToken] += _minTokenAmount;

            emit SwapExecuted(_stablecoin,_targetToken,_maxStableAmount,_minTokenAmount);
        }

    //Swap ERC20 Token -> Stablecoin
    function _swapTokenForStable(
        address _token,
        uint256 _amount,
        uint256 _minStableAmount,
        address[] memory _path
        ) internal nonReentrant {
            require(_path[0] == _token, "Path must start with token");
            require( IERC20(_token).balanceOf(address(this)) >= _amount, "Insufficient token balance");
            
        // Approve and execute swap
        IERC20(_token).approve(address(uniswapRouter), _amount);
        
        uniswapRouter.swapExactTokensForTokens(
            _amount,
            _minStableAmount,
            _path,
            address(this),
            block.timestamp + 15 minutes);
            
        // Update balances
        tokenBalances[_token] -= _amount;
        address stablecoin = _path[_path.length-1];
        tokenBalances[stablecoin] += _minStableAmount;

        emit SwapExecuted(_token, stablecoin, _amount, _minStableAmount);
    }
    
    function _swapStableForEth( uint256 _stableAmount, uint256 _minEthAmount, address[] memory _path ) internal nonReentrant {
        
        require(_path[_path.length-1] == address(0), "Path must end with ETH");
        
        address stablecoin = _path[0];
        
        require( tokenBalances[stablecoin] >= _stableAmount, "Insufficient stable balance");
        
        // Approve and execute swap
        
        IERC20(stablecoin).approve(address(uniswapRouter), _stableAmount);
        
        uniswapRouter.swapTokensForExactETH(
            _minEthAmount,
            _stableAmount,
            _path,
            address(this),
            block.timestamp + 15 minutes
            );
            
        // Update balances
        
        tokenBalances[stablecoin] -= _stableAmount;
        tokenBalances[address(0)] += _minEthAmount;
        
        emit SwapExecuted(stablecoin, address(0), _stableAmount, _minEthAmount);
        
    }

    function _findBestStableSource(uint256 _required) internal view returns (address) {
        
        // Simplified version I will only prioritize USDC then DAI: I don't have much time lol
        
        if(tokenBalances[USDC] >= _required) {
            
            return USDC;
            
        }
        
        if(tokenBalances[DAI] >= _required) {
            
            return DAI;
        
        }
        
        revert("Insufficient stable liquidity");
    }
    
    function _getMaxInput(
        address _asset,
        address[] memory _path,
        uint256 _targetValue
        ) internal view returns (uint256) {
            
            uint256 price = _asset == address(0) ? 
            getLatestPrice(ethPriceFeed) :
            getLatestPrice(priceFeeds[_asset]);
            
            uint256 expectedIn = (_targetValue * (10 ** 18)) / price; // Convert USD value to token amount
            
            return (expectedIn * (100 + MAX_SLIPPAGE)) / 100;
        }

    function suggestRebalance() external onlyAgentKit {
        
        uint256[] memory allocations = new uint256[](3);
        allocations[0] = getEthAllocation();
        allocations[1] = (getAssetValue(USDC) * 100) / getTotalValue();
        allocations[2] = (getAssetValue(DAI) * 100) / getTotalValue();
        
        address[] memory assets = new address[](3);
        assets[0] = address(0);
        assets[1] = USDC;
        assets[2] = DAI;
        
        emit RebalanceSuggested(block.timestamp, assets, allocations);
        
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

    function getAllocations() external view returns (
        uint256 ethAllocation,
        uint256 usdcAllocation,
        uint256 daiAllocation,
        uint256 totalValue) {
            totalValue = getTotalValue();
            ethAllocation = (getAssetValue(address(0)) * 100) / totalValue;
            usdcAllocation = (getAssetValue(USDC) * 100) / totalValue;
            daiAllocation = (getAssetValue(DAI) * 100) / totalValue;
            
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

    function setAgentKitOperator(address _operator) external onlyOwner {
        agentKitOperator = _operator;
    }

    // Accept ETH deposits and converting to WETH for consistency 
    receive() external payable {
        WETH.deposit{value: msg.value}();
        tokenBalances[address(WETH)] += msg.value;
        emit FundsDeposited(address(WETH), msg.value);
    }
}