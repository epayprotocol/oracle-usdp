// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title USDP Oracle - Multi-Source DEX Price Oracle for USDT/USD
/// @notice Aggregates USDT/USD prices from multiple BSC DEXs for USDP ecosystem
/// @dev Implements weighted averages, outlier detection, and circuit breakers
contract USDPOracle {
    /*//////////////////////////////////////////////////////////////
                               OWNERSHIP
    //////////////////////////////////////////////////////////////*/
    
    address public owner;
    
    modifier onlyOwner() {
        require(msg.sender == owner, "UNAUTHORIZED");
        _;
    }
    
    /*//////////////////////////////////////////////////////////////
                           REENTRANCY GUARD
    //////////////////////////////////////////////////////////////*/
    
    uint256 private _status = 1;
    
    modifier nonReentrant() {
        require(_status == 1, "REENTRANCY");
        _status = 2;
        _;
        _status = 1;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/
    
    uint256 public constant PRICE_DECIMALS = 8; // Standard oracle decimals
    uint256 public constant MAX_PRICE_DEVIATION = 500; // 5% in basis points
    uint256 public constant CIRCUIT_BREAKER_THRESHOLD = 1000; // 10% in basis points
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MIN_SOURCES_REQUIRED = 2;
    uint256 public constant MAX_PRICE_AGE = 3600; // 1 hour
    uint256 public constant TWAP_PERIOD = 1800; // 30 minutes default
    uint256 public constant MIN_LIQUIDITY_THRESHOLD = 10000 * 1e18; // $10k minimum liquidity

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/
    
    struct PriceSource {
        address pairAddress;
        string name;
        bool isActive;
        uint256 weight; // Weight for aggregation (basis points)
        uint256 lastUpdateTime;
        uint256 lastPrice;
        bool isToken0USDT; // True if USDT is token0 in the pair
    }

    struct PriceData {
        uint256 price;
        uint256 timestamp;
        uint256 blockNumber;
    }

    struct CircuitBreakerData {
        uint256 lastPrice;
        uint256 lastUpdateTime;
        bool isTripped;
    }

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/
    
    mapping(uint256 => PriceSource) public priceSources;
    uint256 public sourceCount;
    
    // TWAP data storage - circular buffer for efficiency
    mapping(uint256 => PriceData) public priceHistory;
    uint256 public currentIndex;
    uint256 public maxHistorySize = 120; // Store 2 hours of data (1min intervals)
    
    CircuitBreakerData public circuitBreaker;
    
    // Oracle parameters
    uint256 public twapPeriod = TWAP_PERIOD;
    uint256 public maxPriceAge = MAX_PRICE_AGE;
    uint256 public priceDeviationThreshold = MAX_PRICE_DEVIATION;
    uint256 public circuitBreakerThreshold = CIRCUIT_BREAKER_THRESHOLD;
    
    // Access control
    mapping(address => bool) public authorizedUpdaters;
    mapping(address => bool) public priceConsumers;
    
    // Emergency controls
    bool public emergencyPaused;
    uint256 public emergencyPrice; // Fallback price during emergencies
    
    // Last aggregated price data
    uint256 public lastAggregatedPrice;
    uint256 public lastUpdateTimestamp;
    uint256 public lastValidSourceCount;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    
    event PriceUpdated(uint256 indexed price, uint256 timestamp, uint256 sourceCount);
    event SourceAdded(uint256 indexed sourceId, address pairAddress, string name);
    event SourceUpdated(uint256 indexed sourceId, bool isActive, uint256 weight);
    event SourceRemoved(uint256 indexed sourceId);
    event CircuitBreakerTripped(uint256 oldPrice, uint256 newPrice, uint256 timestamp);
    event CircuitBreakerReset(uint256 timestamp);
    event EmergencyPaused(uint256 timestamp);
    event EmergencyUnpaused(uint256 timestamp);
    event OutlierDetected(uint256 indexed sourceId, uint256 price, uint256 medianPrice);
    event AuthorizedUpdaterChanged(address indexed updater, bool authorized);
    event PriceConsumerChanged(address indexed consumer, bool authorized);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    
    error InsufficientSources();
    error PriceStale();
    error CircuitBreakerActive();
    error EmergencyPausedError();
    error UnauthorizedAccess();
    error InvalidPriceSource();
    error InvalidParameters();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    
    constructor(address _owner) {
        owner = _owner;
        // Initialize with conservative emergency price (1 USD)
        emergencyPrice = 1 * 10**PRICE_DECIMALS;
        lastAggregatedPrice = emergencyPrice;
        lastUpdateTimestamp = block.timestamp;
        
        emit OwnershipTransferred(address(0), _owner);
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/
    
    modifier onlyAuthorizedUpdater() {
        if (!authorizedUpdaters[msg.sender] && msg.sender != owner) {
            revert UnauthorizedAccess();
        }
        _;
    }

    modifier onlyPriceConsumer() {
        if (!priceConsumers[msg.sender] && msg.sender != owner) {
            revert UnauthorizedAccess();
        }
        _;
    }

    modifier notPaused() {
        if (emergencyPaused) revert EmergencyPausedError();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           CORE ORACLE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Get the latest USDT/USD price (implements Oracle interface)
    /// @return price USDT/USD price with 8 decimals
    function latestAnswer() external view returns (uint256) {
        if (emergencyPaused) {
            return emergencyPrice;
        }
        
        if (circuitBreaker.isTripped) {
            revert CircuitBreakerActive();
        }
        
        if (block.timestamp - lastUpdateTimestamp > maxPriceAge) {
            revert PriceStale();
        }
        
        return lastAggregatedPrice;
    }

    /// @notice Get current price with validation status
    /// @return price Current price
    /// @return isValid Whether the price is fresh and valid
    function getPrice() external view returns (uint256 price, bool isValid) {
        price = lastAggregatedPrice;
        isValid = !emergencyPaused && 
                 !circuitBreaker.isTripped && 
                 (block.timestamp - lastUpdateTimestamp <= maxPriceAge) &&
                 lastValidSourceCount >= MIN_SOURCES_REQUIRED;
    }

    /// @notice Check if current price is valid and fresh
    /// @return isValid True if price is valid
    function isValidPrice() external view returns (bool) {
        return !emergencyPaused && 
               !circuitBreaker.isTripped && 
               (block.timestamp - lastUpdateTimestamp <= maxPriceAge) &&
               lastValidSourceCount >= MIN_SOURCES_REQUIRED;
    }

    /// @notice Get Time-Weighted Average Price over specified period
    /// @param period Time period in seconds (max 2 hours)
    /// @return twapPrice Time-weighted average price
    function getTWAP(uint256 period) external view returns (uint256) {
        if (period == 0 || period > 7200) { // Max 2 hours
            period = twapPeriod;
        }
        
        uint256 weightedSum;
        uint256 totalTime;
        uint256 targetTimestamp = block.timestamp - period;
        
        // Walk backwards through price history
        uint256 index = currentIndex;
        uint256 count = 0;
        
        while (count < maxHistorySize && priceHistory[index].timestamp > targetTimestamp) {
            PriceData memory data = priceHistory[index];
            if (data.timestamp == 0) break;
            
            uint256 nextIndex = index == 0 ? maxHistorySize - 1 : index - 1;
            uint256 nextTimestamp = priceHistory[nextIndex].timestamp;
            
            if (nextTimestamp < targetTimestamp) {
                nextTimestamp = targetTimestamp;
            }
            
            uint256 timeDelta = data.timestamp - nextTimestamp;
            weightedSum += data.price * timeDelta;
            totalTime += timeDelta;
            
            index = nextIndex;
            count++;
        }
        
        return totalTime > 0 ? weightedSum / totalTime : lastAggregatedPrice;
    }

    /*//////////////////////////////////////////////////////////////
                          PRICE UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Update prices from all active sources and aggregate
    function updatePrices() external onlyAuthorizedUpdater notPaused nonReentrant {
        uint256[] memory prices = new uint256[](sourceCount);
        uint256[] memory weights = new uint256[](sourceCount);
        uint256 validSources = 0;
        
        // Collect prices from all active sources
        for (uint256 i = 0; i < sourceCount; i++) {
            PriceSource storage source = priceSources[i];
            if (!source.isActive) continue;
            
            uint256 price = _getPriceFromDEX(source);
            if (price > 0) {
                prices[validSources] = price;
                weights[validSources] = source.weight;
                validSources++;
                
                // Update source data
                source.lastPrice = price;
                source.lastUpdateTime = block.timestamp;
            }
        }
        
        if (validSources < MIN_SOURCES_REQUIRED) {
            revert InsufficientSources();
        }
        
        // Filter outliers and calculate weighted average
        uint256 aggregatedPrice = _aggregatePrices(prices, weights, validSources);
        
        // Circuit breaker check
        if (_shouldTripCircuitBreaker(aggregatedPrice)) {
            circuitBreaker.isTripped = true;
            circuitBreaker.lastPrice = lastAggregatedPrice;
            circuitBreaker.lastUpdateTime = block.timestamp;
            emit CircuitBreakerTripped(lastAggregatedPrice, aggregatedPrice, block.timestamp);
            return;
        }
        
        // Update state
        lastAggregatedPrice = aggregatedPrice;
        lastUpdateTimestamp = block.timestamp;
        lastValidSourceCount = validSources;
        
        // Store in TWAP history
        _storePriceInHistory(aggregatedPrice);
        
        emit PriceUpdated(aggregatedPrice, block.timestamp, validSources);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL PRICE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Get price from a specific DEX pair
    /// @param source Price source configuration
    /// @return price Current price from the DEX (0 if invalid)
    function _getPriceFromDEX(PriceSource memory source) internal view returns (uint256) {
        try IUniswapV2Pair(source.pairAddress).getReserves() returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 /*blockTimestampLast*/
        ) {
            // Check minimum liquidity
            uint256 usdtReserves = source.isToken0USDT ? reserve0 : reserve1;
            if (usdtReserves < MIN_LIQUIDITY_THRESHOLD) {
                return 0;
            }
            
            // Calculate price (USDT per USD)
            // Since we want USDT/USD rate and both are ~$1, rate should be ~1
            uint256 price;
            if (source.isToken0USDT) {
                // USDT is token0, USD is token1
                price = (uint256(reserve1) * 10**PRICE_DECIMALS) / uint256(reserve0);
            } else {
                // USD is token0, USDT is token1  
                price = (uint256(reserve0) * 10**PRICE_DECIMALS) / uint256(reserve1);
            }
            
            return price;
        } catch {
            return 0;
        }
    }

    /// @notice Aggregate prices using weighted average with outlier filtering
    /// @param prices Array of prices from sources
    /// @param weights Array of weights for each source
    /// @param count Number of valid sources
    /// @return aggregatedPrice Final aggregated price
    function _aggregatePrices(
        uint256[] memory prices,
        uint256[] memory weights,
        uint256 count
    ) internal returns (uint256) {
        if (count == 1) {
            return prices[0];
        }
        
        // Calculate median for outlier detection
        uint256 median = _calculateMedian(prices, count);
        
        uint256 weightedSum;
        uint256 totalWeight;
        
        // Filter outliers and calculate weighted average
        for (uint256 i = 0; i < count; i++) {
            uint256 deviation = prices[i] > median ? 
                ((prices[i] - median) * BASIS_POINTS) / median :
                ((median - prices[i]) * BASIS_POINTS) / median;
            
            if (deviation <= priceDeviationThreshold) {
                weightedSum += prices[i] * weights[i];
                totalWeight += weights[i];
            } else {
                // Find source ID for event (simplified approach)
                emit OutlierDetected(i, prices[i], median);
            }
        }
        
        require(totalWeight > 0, "No valid prices after filtering");
        return weightedSum / totalWeight;
    }

    /// @notice Calculate median of price array
    /// @param prices Array of prices
    /// @param count Number of prices
    /// @return median Median price
    function _calculateMedian(uint256[] memory prices, uint256 count) internal pure returns (uint256) {
        // Simple bubble sort for small arrays
        for (uint256 i = 0; i < count - 1; i++) {
            for (uint256 j = 0; j < count - i - 1; j++) {
                if (prices[j] > prices[j + 1]) {
                    uint256 temp = prices[j];
                    prices[j] = prices[j + 1];
                    prices[j + 1] = temp;
                }
            }
        }
        
        if (count % 2 == 0) {
            return (prices[count / 2 - 1] + prices[count / 2]) / 2;
        } else {
            return prices[count / 2];
        }
    }

    /// @notice Check if circuit breaker should be tripped
    /// @param newPrice New aggregated price
    /// @return shouldTrip True if circuit breaker should trip
    function _shouldTripCircuitBreaker(uint256 newPrice) internal view returns (bool) {
        if (lastAggregatedPrice == 0) return false;
        
        uint256 deviation = newPrice > lastAggregatedPrice ?
            ((newPrice - lastAggregatedPrice) * BASIS_POINTS) / lastAggregatedPrice :
            ((lastAggregatedPrice - newPrice) * BASIS_POINTS) / lastAggregatedPrice;
            
        return deviation > circuitBreakerThreshold;
    }

    /// @notice Store price in TWAP history buffer
    /// @param price Price to store
    function _storePriceInHistory(uint256 price) internal {
        currentIndex = (currentIndex + 1) % maxHistorySize;
        priceHistory[currentIndex] = PriceData({
            price: price,
            timestamp: block.timestamp,
            blockNumber: block.number
        });
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Add a new price source
    /// @param pairAddress DEX pair contract address
    /// @param name Human readable name
    /// @param weight Weight for aggregation (basis points)
    /// @param isToken0USDT True if USDT is token0 in pair
    function addPriceSource(
        address pairAddress,
        string calldata name,
        uint256 weight,
        bool isToken0USDT
    ) external onlyOwner {
        if (pairAddress == address(0) || weight == 0) {
            revert InvalidParameters();
        }
        
        priceSources[sourceCount] = PriceSource({
            pairAddress: pairAddress,
            name: name,
            isActive: true,
            weight: weight,
            lastUpdateTime: 0,
            lastPrice: 0,
            isToken0USDT: isToken0USDT
        });
        
        emit SourceAdded(sourceCount, pairAddress, name);
        sourceCount++;
    }

    /// @notice Update price source configuration
    /// @param sourceId Source ID to update
    /// @param isActive Whether source is active
    /// @param weight New weight for aggregation
    function updatePriceSource(
        uint256 sourceId,
        bool isActive,
        uint256 weight
    ) external onlyOwner {
        if (sourceId >= sourceCount) {
            revert InvalidPriceSource();
        }
        
        priceSources[sourceId].isActive = isActive;
        priceSources[sourceId].weight = weight;
        
        emit SourceUpdated(sourceId, isActive, weight);
    }

    /// @notice Set authorized price updater
    /// @param updater Address to authorize/deauthorize
    /// @param authorized True to authorize, false to revoke
    function setAuthorizedUpdater(address updater, bool authorized) external onlyOwner {
        authorizedUpdaters[updater] = authorized;
        emit AuthorizedUpdaterChanged(updater, authorized);
    }

    /// @notice Set authorized price consumer
    /// @param consumer Address to authorize/deauthorize  
    /// @param authorized True to authorize, false to revoke
    function setPriceConsumer(address consumer, bool authorized) external onlyOwner {
        priceConsumers[consumer] = authorized;
        emit PriceConsumerChanged(consumer, authorized);
    }

    /// @notice Reset circuit breaker
    function resetCircuitBreaker() external onlyOwner {
        circuitBreaker.isTripped = false;
        emit CircuitBreakerReset(block.timestamp);
    }

    /// @notice Emergency pause oracle
    /// @param paused True to pause, false to unpause
    function setEmergencyPaused(bool paused) external onlyOwner {
        emergencyPaused = paused;
        if (paused) {
            emit EmergencyPaused(block.timestamp);
        } else {
            emit EmergencyUnpaused(block.timestamp);
        }
    }

    /// @notice Set emergency fallback price
    /// @param price Emergency price with 8 decimals
    function setEmergencyPrice(uint256 price) external onlyOwner {
        emergencyPrice = price;
    }

    /// @notice Update oracle parameters
    /// @param _twapPeriod New TWAP period
    /// @param _maxPriceAge New maximum price age
    /// @param _priceDeviationThreshold New outlier threshold
    /// @param _circuitBreakerThreshold New circuit breaker threshold
    function updateParameters(
        uint256 _twapPeriod,
        uint256 _maxPriceAge,
        uint256 _priceDeviationThreshold,
        uint256 _circuitBreakerThreshold
    ) external onlyOwner {
        if (_twapPeriod == 0 || _maxPriceAge == 0) {
            revert InvalidParameters();
        }
        
        twapPeriod = _twapPeriod;
        maxPriceAge = _maxPriceAge;
        priceDeviationThreshold = _priceDeviationThreshold;
        circuitBreakerThreshold = _circuitBreakerThreshold;
    }

    /// @notice Transfer ownership to new address
    /// @param newOwner New owner address
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_ADDRESS");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Get price source information
    /// @param sourceId Source ID
    /// @return source Price source data
    function getPriceSource(uint256 sourceId) external view returns (PriceSource memory) {
        if (sourceId >= sourceCount) {
            revert InvalidPriceSource();
        }
        return priceSources[sourceId];
    }

    /// @notice Get oracle status information
    /// @return currentPrice Current aggregated price
    /// @return lastUpdate Timestamp of last update
    /// @return validSources Number of valid price sources
    /// @return isCircuitBreakerTripped Circuit breaker status
    /// @return isPaused Emergency pause status
    /// @return isStale Whether price data is stale
    function getOracleStatus() external view returns (
        uint256 currentPrice,
        uint256 lastUpdate,
        uint256 validSources,
        bool isCircuitBreakerTripped,
        bool isPaused,
        bool isStale
    ) {
        currentPrice = lastAggregatedPrice;
        lastUpdate = lastUpdateTimestamp;
        validSources = lastValidSourceCount;
        isCircuitBreakerTripped = circuitBreaker.isTripped;
        isPaused = emergencyPaused;
        isStale = (block.timestamp - lastUpdateTimestamp) > maxPriceAge;
    }

    /// @notice Get current parameters
    /// @return _twapPeriod Current TWAP period
    /// @return _maxPriceAge Maximum price age
    /// @return _priceDeviationThreshold Outlier detection threshold
    /// @return _circuitBreakerThreshold Circuit breaker threshold
    function getParameters() external view returns (
        uint256 _twapPeriod,
        uint256 _maxPriceAge,
        uint256 _priceDeviationThreshold,
        uint256 _circuitBreakerThreshold
    ) {
        _twapPeriod = twapPeriod;
        _maxPriceAge = maxPriceAge;
        _priceDeviationThreshold = priceDeviationThreshold;
        _circuitBreakerThreshold = circuitBreakerThreshold;
    }
}

/*//////////////////////////////////////////////////////////////
                           INTERFACES
//////////////////////////////////////////////////////////////*/

/// @notice Uniswap V2 Pair interface for price fetching
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}
