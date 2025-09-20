# USDPOracle — Multi-Source DEX Price Oracle for USDT/USD
Aggregates spot USDT/USD from multiple UniswapV2-style DEX pairs with weighted averaging, outlier filtering, TWAP on internal history, a circuit breaker, and emergency controls implemented in [USDPOracle()](USDPOracle.sol:7).

## Overview
- Contract: [USDPOracle()](USDPOracle.sol:7)
- License: [SPDX-License-Identifier: MIT](USDPOracle.sol:1)
- Compiler: [pragma solidity ^0.8.13](USDPOracle.sol:2)
- Purpose: Provide an on-chain USDT/USD oracle by aggregating spot prices from multiple DEX pairs and enforcing safety features (outlier filtering, circuit breaker, staleness checks, liquidity threshold).
- Trust/assumptions: relies on honest configuration of sources and regular updates by authorized updaters; prices are derived from instantaneous DEX reserves (spot), not on-chain cumulative TWAP.

## Key Characteristics
- Output decimals: [PRICE_DECIMALS](USDPOracle.sol:36) = 8.
- Spot price aggregation across multiple sources via [updatePrices()](USDPOracle.sol:255) using [_getPriceFromDEX()](USDPOracle.sol:311), median outlier filtering in [_aggregatePrices()](USDPOracle.sol:345) with median from [_calculateMedian()](USDPOracle.sol:383).
- Outlier filter threshold: [priceDeviationThreshold](USDPOracle.sol:88) in basis points relative to median; sources exceeding threshold are excluded and [OutlierDetected()](USDPOracle.sol:116) is emitted.
- Weighted averaging: per-source [weight](USDPOracle.sol:54) applied in [_aggregatePrices()](USDPOracle.sol:345).
- Minimum sources required: [MIN_SOURCES_REQUIRED](USDPOracle.sol:40) before aggregation proceeds; otherwise [InsufficientSources()](USDPOracle.sol:125).
- Circuit breaker: deviation check in [_shouldTripCircuitBreaker()](USDPOracle.sol:405) vs [lastAggregatedPrice](USDPOracle.sol:100) using [circuitBreakerThreshold](USDPOracle.sol:89). Emits [CircuitBreakerTripped()](USDPOracle.sol:112) and requires [resetCircuitBreaker()](USDPOracle.sol:495) to clear.
- TWAP (time-weighted average) over internally stored aggregated prices via [getTWAP()](USDPOracle.sol:215); storage managed by [_storePriceInHistory()](USDPOracle.sol:417) with ring buffer size [maxHistorySize](USDPOracle.sol:81) and default [twapPeriod](USDPOracle.sol:86).
- Emergency controls: [setEmergencyPaused()](USDPOracle.sol:502), [setEmergencyPrice()](USDPOracle.sol:513). When paused, [latestAnswer()](USDPOracle.sol:176) returns [emergencyPrice](USDPOracle.sol:97). Events: [EmergencyPaused()](USDPOracle.sol:114), [EmergencyUnpaused()](USDPOracle.sol:115).
- Staleness checks: [latestAnswer()](USDPOracle.sol:176) reverts [PriceStale()](USDPOracle.sol:126) if (now - [lastUpdateTimestamp](USDPOracle.sol:101)) > [maxPriceAge](USDPOracle.sol:87).
- Access control: [onlyOwner()](USDPOracle.sol:14) for configuration, [onlyAuthorizedUpdater()](USDPOracle.sol:151) for [updatePrices()](USDPOracle.sol:255), and [nonReentrant()](USDPOracle.sol:25) on updates. Optional [onlyPriceConsumer()](USDPOracle.sol:158) modifier and [priceConsumers](USDPOracle.sol:93) mapping exist but are not currently enforced on any read function.
- Liquidity gate: sources with USDT reserves below [MIN_LIQUIDITY_THRESHOLD](USDPOracle.sol:43) are ignored in [_getPriceFromDEX()](USDPOracle.sol:311).

## How It Works
- Data sources: Each source is a [PriceSource](USDPOracle.sol:49) pointing to a UniswapV2-style pair ([IUniswapV2Pair()](USDPOracle.sol:606)). Fields include [pairAddress](USDPOracle.sol:50), [name](USDPOracle.sol:51), [isActive](USDPOracle.sol:52), [weight](USDPOracle.sol:54), [isToken0USDT](USDPOracle.sol:56), plus last values.
- Price fetch: [_getPriceFromDEX()](USDPOracle.sol:311) calls pair.[getReserves()](USDPOracle.sol:607) and computes USDT/USD as:
  - If [isToken0USDT](USDPOracle.sol:56) is true: price = reserve1 / reserve0 scaled by 10^[PRICE_DECIMALS](USDPOracle.sol:36).
  - Else: price = reserve0 / reserve1 scaled by 10^[PRICE_DECIMALS](USDPOracle.sol:36).
  - If the USDT-side reserve is below [MIN_LIQUIDITY_THRESHOLD](USDPOracle.sol:43), returns 0. Any getReserves failure is caught (try/catch) and returns 0.
- Aggregation flow in [updatePrices()](USDPOracle.sol:255):
  - Iterate active sources; collect prices > 0 with their [weight](USDPOracle.sol:54).
  - Require at least [MIN_SOURCES_REQUIRED](USDPOracle.sol:40) or revert [InsufficientSources()](USDPOracle.sol:125).
  - Compute median with [_calculateMedian()](USDPOracle.sol:383); discard entries deviating more than [priceDeviationThreshold](USDPOracle.sol:88); emit [OutlierDetected()](USDPOracle.sol:116) for each exclusion.
  - Weighted average surviving prices in [_aggregatePrices()](USDPOracle.sol:345) (reverts with a require message if all weights are filtered out).
  - Circuit-breaker check via [_shouldTripCircuitBreaker()](USDPOracle.sol:405); if tripped, set breaker state and emit [CircuitBreakerTripped()](USDPOracle.sol:112) without updating price.
  - On success: update [lastAggregatedPrice](USDPOracle.sol:100), [lastUpdateTimestamp](USDPOracle.sol:101), [lastValidSourceCount](USDPOracle.sol:102); push to history via [_storePriceInHistory()](USDPOracle.sol:417); emit [PriceUpdated()](USDPOracle.sol:108).
- TWAP: [getTWAP()](USDPOracle.sol:215) walks the ring buffer [priceHistory](USDPOracle.sol:79) backward, time-weights samples until the requested period (default [twapPeriod](USDPOracle.sol:86), max 2h). Falls back to [lastAggregatedPrice](USDPOracle.sol:100) if not enough history.
- Read path: [latestAnswer()](USDPOracle.sol:176) returns the last aggregated price unless paused (returns [emergencyPrice](USDPOracle.sol:97)) or if the breaker is active ([CircuitBreakerActive()](USDPOracle.sol:127)) or data is stale ([PriceStale()](USDPOracle.sol:126)). [getPrice()](USDPOracle.sol:195) returns the price plus a boolean validity flag.

## Public API
- Read functions
  - [latestAnswer()](USDPOracle.sol:176): Returns current USDT/USD with 8 decimals; reverts on breaker/stale; returns emergency price when paused.
  - [getPrice()](USDPOracle.sol:195): Returns (price, isValid) where isValid reflects pause/breaker/staleness and source count.
  - [isValidPrice()](USDPOracle.sol:205): Convenience boolean validity check.
  - [getTWAP()](USDPOracle.sol:215): Time-weighted average of aggregated prices over a given period (defaults to [twapPeriod](USDPOracle.sol:86)).
  - [getPriceSource()](USDPOracle.sol:553): Fetches a [PriceSource](USDPOracle.sol:49) by id.
  - [getOracleStatus()](USDPOracle.sol:567): Returns key runtime status including current price, last update, valid source count, breaker/paused/stale flags.
  - [getParameters()](USDPOracle.sol:588): Returns current [twapPeriod](USDPOracle.sol:86), [maxPriceAge](USDPOracle.sol:87), [priceDeviationThreshold](USDPOracle.sol:88), [circuitBreakerThreshold](USDPOracle.sol:89).
- Update/aggregation
  - [updatePrices()](USDPOracle.sol:255): Pulls from all active sources, filters outliers, computes weighted average, runs the circuit breaker, updates state/history, and emits [PriceUpdated()](USDPOracle.sol:108). Restricted by [onlyAuthorizedUpdater()](USDPOracle.sol:151), [notPaused()](USDPOracle.sol:165), and [nonReentrant()](USDPOracle.sol:25).
- Admin/configuration
  - [addPriceSource()](USDPOracle.sol:435): Adds a new DEX pair source; sets [isToken0USDT](USDPOracle.sol:56) orientation and [weight](USDPOracle.sol:54). Emits [SourceAdded()](USDPOracle.sol:109).
  - [updatePriceSource()](USDPOracle.sol:463): Activates/deactivates and/or changes [weight](USDPOracle.sol:54). Emits [SourceUpdated()](USDPOracle.sol:110).
  - [setAuthorizedUpdater()](USDPOracle.sol:481): Grants/revokes updater role. Emits [AuthorizedUpdaterChanged()](USDPOracle.sol:117).
  - [setPriceConsumer()](USDPOracle.sol:489): Grants/revokes consumer role (currently unused by any read path). Emits [PriceConsumerChanged()](USDPOracle.sol:118).
  - [resetCircuitBreaker()](USDPOracle.sol:495): Clears breaker state. Emits [CircuitBreakerReset()](USDPOracle.sol:113).
  - [setEmergencyPaused()](USDPOracle.sol:502): Pauses/unpauses the oracle. Emits [EmergencyPaused()](USDPOracle.sol:114) or [EmergencyUnpaused()](USDPOracle.sol:115).
  - [setEmergencyPrice()](USDPOracle.sol:513): Sets fallback price used by [latestAnswer()](USDPOracle.sol:176) when paused.
  - [updateParameters()](USDPOracle.sol:522): Updates [twapPeriod](USDPOracle.sol:86), [maxPriceAge](USDPOracle.sol:87), [priceDeviationThreshold](USDPOracle.sol:88), [circuitBreakerThreshold](USDPOracle.sol:89).
  - [transferOwnership()](USDPOracle.sol:540): Transfers [owner](USDPOracle.sol:12); emits [OwnershipTransferred()](USDPOracle.sol:119).

## Events
- [PriceUpdated()](USDPOracle.sol:108): Emitted after a successful aggregation update.
- [SourceAdded()](USDPOracle.sol:109): New price source registered.
- [SourceUpdated()](USDPOracle.sol:110): Source activation/weight change.
- [SourceRemoved()](USDPOracle.sol:111): Declared but not emitted by any function in this version.
- [CircuitBreakerTripped()](USDPOracle.sol:112): New price deviated beyond breaker threshold.
- [CircuitBreakerReset()](USDPOracle.sol:113): Breaker cleared by owner.
- [EmergencyPaused()](USDPOracle.sol:114) / [EmergencyUnpaused()](USDPOracle.sol:115): Pause state toggled.
- [OutlierDetected()](USDPOracle.sol:116): A source’s price deviated beyond [priceDeviationThreshold](USDPOracle.sol:88) and was excluded.
- [AuthorizedUpdaterChanged()](USDPOracle.sol:117): Updater role changed.
- [PriceConsumerChanged()](USDPOracle.sol:118): Consumer role changed.
- [OwnershipTransferred()](USDPOracle.sol:119): Ownership moved to a new address.

## Configuration & Access Control
- Owner: [owner](USDPOracle.sol:12). Transfers via [transferOwnership()](USDPOracle.sol:540).
- Updater role: managed by [setAuthorizedUpdater()](USDPOracle.sol:481); required by [updatePrices()](USDPOracle.sol:255) through [onlyAuthorizedUpdater()](USDPOracle.sol:151).
- Consumer role: managed by [setPriceConsumer()](USDPOracle.sol:489); note [onlyPriceConsumer()](USDPOracle.sol:158) is not applied to any current read function.
- Admin-only operations: [addPriceSource()](USDPOracle.sol:435), [updatePriceSource()](USDPOracle.sol:463), [resetCircuitBreaker()](USDPOracle.sol:495), [setEmergencyPaused()](USDPOracle.sol:502), [setEmergencyPrice()](USDPOracle.sol:513), [updateParameters()](USDPOracle.sol:522), [transferOwnership()](USDPOracle.sol:540).

## Integration Example
Note: Prices use 8 decimals ([PRICE_DECIMALS](USDPOracle.sol:36)). The simplest read is [latestAnswer()](USDPOracle.sol:176). For freshness checks, use [getPrice()](USDPOracle.sol:195) or [isValidPrice()](USDPOracle.sol:205).

```solidity
// Minimal interface for integration
interface IUSDPOracle {
    function latestAnswer() external view returns (uint256);
    function getPrice() external view returns (uint256 price, bool isValid);
}

contract UsesOracle {
    IUSDPOracle public oracle;
    constructor(address oracle_) { oracle = IUSDPOracle(oracle_); }

    function readSpot() external view returns (uint256) {
        // Returns 8-decimal USDT/USD from latest update or emergency price if paused
        return oracle.latestAnswer(); // Calls [latestAnswer()](USDPOracle.sol:176)
    }

    function readWithValidity() external view returns (uint256, bool) {
        // Returns (price, isValid) where validity checks pause/breaker/staleness/source-count
        return oracle.getPrice(); // Calls [getPrice()](USDPOracle.sol:195)
    }
}
```

Ensure the oracle is configured and updated by an authorized updater before reads: owner calls [addPriceSource()](USDPOracle.sol:435), [setAuthorizedUpdater()](USDPOracle.sol:481), and an authorized updater calls [updatePrices()](USDPOracle.sol:255).

## Security Considerations & Limitations
- Spot-price basis: Prices are instantaneous reserves from DEX pairs via [_getPriceFromDEX()](USDPOracle.sol:311), not on-chain cumulative TWAP; short-term manipulation is possible on low-liquidity pairs. The design mitigates via [MIN_LIQUIDITY_THRESHOLD](USDPOracle.sol:43), [priceDeviationThreshold](USDPOracle.sol:88), weighting, and multiple sources.
- Update frequency: Data becomes stale after [maxPriceAge](USDPOracle.sol:87); [latestAnswer()](USDPOracle.sol:176) reverts [PriceStale()](USDPOracle.sol:126). Ensure frequent [updatePrices()](USDPOracle.sol:255) calls.
- Circuit breaker behavior: When tripped, [latestAnswer()](USDPOracle.sol:176) reverts [CircuitBreakerActive()](USDPOracle.sol:127) until [resetCircuitBreaker()](USDPOracle.sol:495). Integration should handle this revert path.
- Decimals/normalization: Reserve ratios are used directly; the code does not read token decimals. If a pair’s tokens differ in decimals, computed price can be off by a constant factor. Thresholds like [MIN_LIQUIDITY_THRESHOLD](USDPOracle.sol:43) assume 18-decimal USDT on BSC.
- Orientation correctness: Misconfiguring [isToken0USDT](USDPOracle.sol:56) for a source will invert the ratio. Verify pair orientation when using [addPriceSource()](USDPOracle.sol:435).
- Outlier event indexing: [OutlierDetected()](USDPOracle.sol:116) emits the loop index, not a persistent sourceId, which may complicate monitoring.
- Paused mode: When paused, updates are blocked ([notPaused()](USDPOracle.sol:165) on [updatePrices()](USDPOracle.sol:255)), and reads return [emergencyPrice](USDPOracle.sol:97) via [latestAnswer()](USDPOracle.sol:176). Consider whether consumers should accept emergency pricing.
- Require-based revert string: [_aggregatePrices()](USDPOracle.sol:345) uses a string revert if all prices are filtered; integrators should account for this non-custom error path.
- Roles: Updater and owner are trusted to configure sources/weights and to update frequently. Overly centralized updaters are a risk.
- Unused constructs: [SourceRemoved()](USDPOracle.sol:111) event and [onlyPriceConsumer()](USDPOracle.sol:158)/[priceConsumers](USDPOracle.sol:93) are present but unused in this version.

## Development Notes
- Compiler: [pragma solidity ^0.8.13](USDPOracle.sol:2). Arithmetic uses built-in overflow checks.
- Dependencies: Local [IUniswapV2Pair()](USDPOracle.sol:606) interface ([getReserves()](USDPOracle.sol:607), [token0()](USDPOracle.sol:608), [token1()](USDPOracle.sol:609)); no external imports.
- Typical setup (tests/devnets):
  1) Owner: [addPriceSource()](USDPOracle.sol:435) for 2+ pairs, carefully setting [isToken0USDT](USDPOracle.sol:56) and [weight](USDPOracle.sol:54).
  2) Owner: [setAuthorizedUpdater()](USDPOracle.sol:481) for a keeper/bot.
  3) Updater bot: regularly call [updatePrices()](USDPOracle.sol:255) (e.g., every few minutes) to keep data fresh for [getTWAP()](USDPOracle.sol:215)/[latestAnswer()](USDPOracle.sol:176).
  4) Optionally adjust parameters via [updateParameters()](USDPOracle.sol:522), and manage emergency state via [setEmergencyPaused()](USDPOracle.sol:502)/[setEmergencyPrice()](USDPOracle.sol:513).
- Testing tips: simulate outliers to observe [OutlierDetected()](USDPOracle.sol:116); test breaker thresholds and stale logic; verify TWAP output vs controlled update intervals.

## License
This repository follows [SPDX-License-Identifier: MIT](USDPOracle.sol:1).