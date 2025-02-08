// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

interface IAavePool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external;
    struct ReserveData{
        uint256 configuration; 
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        address aTokenAddress;
    }
    function getReserveData(address asset) external view returns (ReserveData memory);
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

    mapping(address => AggregatorV3Interface) public priceFeeds; // Token -> Price Feed 
    // STATE VARIABLES
    address public owner;
    address public proposalsContract;
    IUniswapV2Router02 public uniswapRouter = IUniswapV2Router02(0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008);
    address public agentKitOperator;
    address[] public aaveAssets;
    mapping(address => bool) public isAaveAsset;

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
    IAavePool public constant AAVE_POOL = IAavePool(0x368EedF3f56ad10b9bC57eed4Dac65B26Bb667f6);
    uint256 public constant MAX_AAVE_EXPOSURE = 8000; // 80% of treasury
    uint256 public constant MAX_SLIPPAGE = 5; // 5% slippage protection
    address public constant USDC = 0xEbCC972B6B3eB15C0592BE1871838963d0B94278;
    address public constant DAI = 0xe5118E47e061ab15Ca972D045b35193F673bcc36;
    IWETH public constant WETH = IWETH(0xA1A245cc76414DC143687D9c3DE1152396f352D6);

    // EVENTS
    event FundsDeposited(address indexed token, uint256 amount);
    event FundsWithdrawn(address indexed token, uint256 amount);
    event DefiDeposit(address indexed token, uint256 amount);
    event DefiWithdrawal(address indexed token, uint256 amount);
    event YieldEarned(address token, uint256 amount);
    event AllocationConfigured(address indexed asset, uint256 target, uint256 upper, uint256 lower);
    event RebalanceSuggested(uint256 timestamp, address[] assets, uint256[] allocations);
    event SwapExecuted( address indexed assetSold, address indexed assetBought,uint256 amountSold, uint256 amountBought);
    event RebalanceCycle(address indexed triggerer,uint256 totalValueBefore, uint256 totalValueAfter, uint256 wethBefore, uint256 wethAfter);

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
            require(_target + _upperThreshold <= 10000, "Invalid thresholds");
            
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
        //Weth
        priceFeeds[address(WETH)] = AggregatorV3Interface(0x694AA1769357215DE4FAC081bf1f309aDC325306);
        //Other price feeds
        priceFeeds[0xEbCC972B6B3eB15C0592BE1871838963d0B94278] = AggregatorV3Interface(0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E); // USDC/USD
        priceFeeds[0xe5118E47e061ab15Ca972D045b35193F673bcc36] = AggregatorV3Interface(0x14866185B1962B63C3Ea9E03Bc1da838bab34C19); // DAI/USD

        address[] memory wethPath = new address[](3);
        wethPath[0] = address(WETH);
        wethPath[1] = USDC;
        wethPath[2] = DAI;
        
        //configureAsset(address(WETH), 3000, 500, 500, wethPath); // 30% target allocation
       
        //UNI
        // UNI->WETH->USDC
        //configureAsset(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984, 10, 3, 3, [0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984, address(WETH), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48]);
    }

    // CORE FUNCTIONS
    //will need to update this - only eth is shown
    function getBalance() external view returns (uint256) {
        return IERC20(address(WETH)).balanceOf(address(this));
    }

    function executeTransfer(
        address payable _to,
        uint256 _amount,
        address _token
    ) external onlyProposals nonReentrant {
        require(tokenBalances[_token] >= _amount, "Insufficient liquid balance");
        require(IERC20(_token).transfer(_to, _amount), "Token transfer failed");
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
        uint256 totalValue = getTotalValue();
        uint256 maxAllowed = (totalValue * MAX_AAVE_EXPOSURE) / 10000;
        uint256 currentExposure = getAaveTotalValue();
        
        require(currentExposure + _amount <= maxAllowed, "Exceeds Aave cap");

        // Update token balance before transfer to Aave
        tokenBalances[_token] -= _amount;
        
        // Get aToken address if not already mapped
        if (aTokenMapping[_token] == address(0)) { 
            IAavePool.ReserveData memory reserveData = AAVE_POOL.getReserveData(_token);
            address aToken = reserveData.aTokenAddress;
            aTokenMapping[_token] = aToken;

            if (!isAaveAsset[_token]) {
                aaveAssets.push(_token);
                isAaveAsset[_token] = true;
            }
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
        // Calculate yield only if current balance exceeds principal
        uint256 yield = currentATokenBalance - principal;
        if (currentATokenBalance > principal) {
            yield = (yield * _amount) / principal;
        }

        AAVE_POOL.withdraw(_token, _amount, address(this));
        
        //Updated balances and tracking
        
        tokenBalances[_token] += _amount + yield;
        aavePrincipal[_token] -= _amount;
        yieldGenerated[_token] += yield;

        emit DefiWithdrawal(_token, _amount);
        emit YieldEarned(_token, yield);
    }
    
    function getAaveTotalValue() public view returns (uint256 total) {
        
        for (uint256 i = 0; i < aaveAssets.length; i++) {
            
            address token = aaveAssets[i];
            address aToken = aTokenMapping[token];
            
            uint256 aTokenBalance = IERC20(aToken).balanceOf(address(this));
            
            AggregatorV3Interface feed = priceFeeds[token];
            
            require(address(feed) != address(0), "Price feed not found");
            
            uint256 price = getLatestPrice(feed);
            
            uint8 decimals = IERC20Metadata(token).decimals();
            
            total += (aTokenBalance * price) / (10 ** decimals);
            }

        return total;
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

        uint256 currentAllocation = (getAssetValue(_asset) * 10000) / _totalValue;
        
        if(currentAllocation > config.target + config.upperThreshold) {
            _sellExcess(_asset, _totalValue, currentAllocation, config);
        }
        else if(currentAllocation < config.target - config.lowerThreshold) {
            _buyNeeded(_asset, _totalValue, currentAllocation, config);
        }
    }

    function checkAndRebalance() external onlyAgentKit nonReentrant {
        uint256 totalBefore = getTotalValue();
        uint256 wethBefore = getAssetValue(address(WETH));

        uint256 totalValue = getTotalValue();
        require(totalValue > 0, "No assets to rebalance");
        
        // Check WETH allocation first
        _rebalanceAsset(address(WETH), totalValue);
        
        // Check configured assets
        address[] memory tokens = new address[](4);
        tokens[0] = address(WETH);
        tokens[1] = USDC;
        tokens[2] = DAI;
        //tokens[3] = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984; // UNI

        
        for(uint256 i = 0; i < tokens.length; i++) {
            _rebalanceAsset(tokens[i], totalValue);
        }
        emit RebalanceCycle(msg.sender,totalBefore,getTotalValue(),wethBefore, getAssetValue(address(WETH)));
    }

    function _sellExcess(address _asset, uint256 _totalValue, uint256 _currentAlloc, AssetConfig memory _config) internal {
        uint256 excessPercentage = _currentAlloc - _config.target;
        uint256 excessValue = (excessPercentage * _totalValue) / 10000;
        
        // Calculate slippage-protected minimum
        uint256 minOut = _getMinOutput(_asset, _config.swapPath, excessValue);
        
        _swapTokenForStable(_asset, excessValue, minOut, _config.swapPath);
    }

   function _getMinOutput(address _asset, address[] memory _path, uint256 _amount) internal view returns (uint256) {
        uint8 tokenDecimals = IERC20Metadata(_asset).decimals();
        AggregatorV3Interface feed = priceFeeds[_asset];
        uint8 feedDecimals = feed.decimals();
        uint256 price = getLatestPrice(feed);
        uint256 expectedOut = (_amount * price) / (10 ** tokenDecimals);
        expectedOut = (expectedOut * (10 ** IERC20Metadata(_path[_path.length-1]).decimals())) / (10 ** feedDecimals);
        return (expectedOut * (100 - MAX_SLIPPAGE)) / 100;
        
    }

    function _buyNeeded(
        address _asset,
        uint256 _totalValue,
        uint256 _currentAlloc,
        AssetConfig memory _config
        ) internal {
            
            uint256 deficitPercentage = _config.target - _currentAlloc;
            uint256 deficitValue = (deficitPercentage * _totalValue) / 10000;
            
            // Determine which stablecoin to use for purchase
            address stablecoin = _findBestStableSource(deficitValue);
            
            // Calculate slippage-protected maximum input
            uint256 maxIn = _getMaxInput(_asset, _config.swapPath, deficitValue);
            
            _swapStableForToken(_asset, maxIn, deficitValue, stablecoin, _config.swapPath);
                
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
            uint256 stableBalanceBefore = IERC20(_stablecoin).balanceOf(address(this));
            uint[] memory amounts = uniswapRouter.swapTokensForExactTokens(
                _minTokenAmount,
                _maxStableAmount,
                _path,
                address(this),
                block.timestamp + 15 minutes
                );

            uint256 stableSpent = stableBalanceBefore - IERC20(_stablecoin).balanceOf(address(this));  
            // Update balances
            
            tokenBalances[_stablecoin] -= stableSpent;
            tokenBalances[_targetToken] += amounts[amounts.length - 1];

            emit SwapExecuted(_stablecoin, _targetToken, stableSpent, amounts[amounts.length - 1]);
        }

    //Swap ERC20 Token -> Stablecoin
    function _swapTokenForStable(
        address _token,
        uint256 _amount,
        uint256 _minStableAmount,
        address[] memory _path
        ) internal nonReentrant {
            require(_path[0] == _token, "Path must start with token");
            //require(_token == address(WETH) || _token == otherTokens, "Invalid token");
            require( IERC20(_token).balanceOf(address(this)) >= _amount, "Insufficient token balance");
            
        // Approve and execute swap
        IERC20(_token).approve(address(uniswapRouter), _amount);
        uint256 balanceBefore = IERC20(_path[_path.length-1]).balanceOf(address(this));
        uniswapRouter.swapExactTokensForTokens(
            _amount,
            _minStableAmount,
            _path,
            address(this),
            block.timestamp + 15 minutes);
            
        // Update balances
        uint256 received = IERC20(_path[_path.length-1]).balanceOf(address(this)) - balanceBefore;
        tokenBalances[_token] -= _amount;
        address stablecoin = _path[_path.length-1];
        tokenBalances[stablecoin] += received;


        emit SwapExecuted(_token, stablecoin, _amount, received);
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

            uint256 price = getLatestPrice(priceFeeds[_asset]);
            uint256 expectedIn = (_targetValue * (10 ** 18)) / price; // Convert USD value to token amount
            
            return (expectedIn * (100 + MAX_SLIPPAGE)) / 100;
        }

    function suggestRebalance() external onlyAgentKit {
        
        uint256[] memory allocations = new uint256[](3);
        allocations[0] = getWethAllocation();
        allocations[1] = (getAssetValue(USDC) * 100) / getTotalValue();
        allocations[2] = (getAssetValue(DAI) * 100) / getTotalValue();
        
        address[] memory assets = new address[](3);
        assets[0] = address(WETH);
        assets[1] = USDC;
        assets[2] = DAI;
        
        emit RebalanceSuggested(block.timestamp, assets, allocations);
        
    }

    //Oracle Functions
    function getAssetValue(address token) public view returns (uint256) {
        uint256 balance = tokenBalances[token];
        
        if (aTokenMapping[token] != address(0)) {
            
            balance += IERC20(aTokenMapping[token]).balanceOf(address(this));
            }

        if(token == address(WETH)) { // WETH
            uint256 wethPrice = getLatestPrice(priceFeeds[address(WETH)]);
            return (tokenBalances[token] * wethPrice) / (10 ** 18);
        }

        AggregatorV3Interface feed = priceFeeds[token];
        require(address(feed) != address(0), "Price feed not found");
        
        uint256 tokenPrice = getLatestPrice(feed);
        uint256 tokenDecimals = 10 ** IERC20Metadata(token).decimals();
        
        return (tokenBalances[token] * tokenPrice) / tokenDecimals;
    }

    function getTotalValue() public view returns (uint256) {
        
        uint256 total = getAssetValue(address(WETH)); // WETH value
        
        //Stablecoin values
        address[] memory stablecoins = new address[](2);
        stablecoins[0] = USDC;
        stablecoins[1] = DAI;
        
        for(uint256 i = 0; i < stablecoins.length; i++) {
            total += getAssetValue(stablecoins[i]);
        }
        
        return total;
    }

    function getWethAllocation() public view returns (uint256) {
        
        uint256 wethValue = getAssetValue(address(WETH));
        uint256 totalValue = getTotalValue();
        return (wethValue * 100) / totalValue;
    }

    function getAllocations() external view returns (
        uint256 wethAllocation,
        uint256 usdcAllocation,
        uint256 daiAllocation,
        uint256 totalValue) {
            totalValue = getTotalValue();
            wethAllocation = (getAssetValue(address(WETH)) * 100) / totalValue;
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
        require(timeStamp >= block.timestamp - 5 minutes, "Stale price");
        
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
        if (_token == address(WETH)) {
            WETH.withdraw(_amount);
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

//Archive
/***

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

 */