# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Does

A multi-chain liquidation bot for the Euler Protocol. It monitors EVC (Ethereum Vault Connector) events to track account positions, calculates health scores, simulates liquidations, gets swap quotes via 1Inch API, checks profitability against gas costs, and executes liquidations via `Liquidator.sol`.

## Commands

### Python Setup
```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
mkdir logs state
```

### Run Locally
```bash
flask run --port 8080
```

### Docker
```bash
docker compose build --progress=plain && docker compose up
```

### Solidity Contracts
```bash
# Install Foundry
foundryup

# Build contracts
forge install && forge build

# Deploy liquidator contract
forge script contracts/DeployLiquidator.sol --rpc-url $RPC_URL --broadcast --ffi -vvv --slow --evm-version shanghai

# Run liquidation setup test (creates positions on a fork)
forge script test/LiquidationSetupWithVaultCreated.sol --rpc-url $RPC_URL --broadcast --ffi -vvv --slow --evm-version shanghai

# Run Foundry tests
forge test
```

### Linting
```bash
pylint app/
```

## Architecture

### Core Flow
1. `EVCListener` scans `AccountStatusCheck` events from the EVC contract to discover accounts
2. `AccountMonitor` maintains a priority queue of accounts, scheduling updates based on health score and position size
3. For unhealthy accounts (health < 1.0), `Liquidator` simulates liquidation across each collateral asset
4. `Quoter` uses the 1Inch API with binary search to find the exact swap amount needed to repay debt
5. Profitability check: simulate tx gas cost vs. expected profit in ETH terms
6. Execution: `Liquidator.sol` performs a 7-step EVC batch (enable collateral, enable controller, liquidate, swap via ISwapper, repay, disable controller, sweep profit)
7. Excess collateral goes to `profit_receiver` as eTokens

### Key Classes (`app/liquidation/liquidation_bot.py`)
- **`Vault`** — Wraps EVault contract; calls `accountLiquidity()`, `checkLiquidation()`, and other vault methods
- **`Account`** — Tracks health score, position size, and update scheduling for a single account
- **`AccountMonitor`** — Main orchestrator; priority queue loop that calls vault liquidity checks and triggers liquidations
- **`EVCListener`** — Subscribes to EVC `AccountStatusCheck` logs to add/refresh accounts
- **`SmartUpdateListener`** — Allows manual account update triggers
- **`Liquidator`** — Static methods: `simulate_liquidation()`, `execute_liquidation()`, `binary_search_swap_amount()`
- **`PullOracleHandler`** — Fetches and batches Pyth oracle price updates for accurate on-chain pricing
- **`Quoter`** — Wraps 1Inch API calls with retry logic and slippage handling

### Supporting Modules
- **`bot_manager.py`** — `ChainManager` instantiates one `AccountMonitor` + `EVCListener` per configured chain
- **`config_loader.py`** — Loads `config.yaml` and `.env`; provides `ChainConfig` with per-chain contract addresses and Web3 instance
- **`utils.py`** — Logging setup, contract creation helpers, Slack notifications, API request wrapper
- **`routes.py`** — Flask endpoints: `GET /allPositions` returns all tracked accounts across chains
- **`application.py`** — Flask app factory entry point

### Configuration
**`config.yaml`** — Main config with:
- Health score thresholds (`HS_LIQUIDATION`, `HS_HIGH_RISK`, `HS_SAFE`)
- Update interval matrix (position size bucket × health bucket → seconds between checks)
- Per-chain contract addresses (EVC, LIQUIDATOR_CONTRACT, SWAPPER, SWAP_VERIFIER, WETH, PYTH)
- API parameters (retries, slippage, swap delays)
- Profit receiver address

**`.env`** (from `.env.example`):
```
LIQUIDATOR_EOA=<public key>
LIQUIDATOR_PRIVATE_KEY=<private key>
MAINNET_RPC_URL=...
BASE_RPC_URL=...
SWAP_API_URL=<1inch endpoint>
SLACK_WEBHOOK_URL=<optional>
```

### Multi-Chain Support
Chains are identified by chain ID in `config.yaml`. Currently configured: Ethereum (1), Base (8453), Swell (1923), Sonic (146), BOB (60808), Berachain (80094).

### State Persistence
The `state/` directory stores serialized account state per chain so the bot can resume without re-scanning all historical events.

### Contracts (`contracts/`)
- **`Liquidator.sol`** — Main on-chain executor; called with collateral/liability vault addresses, violator address, and encoded swap data
- **`ISwapper.sol`** — Interface the Liquidator calls to swap seized collateral for debt repayment
- **`SwapVerifier.sol`** — Verifies swap output meets minimum amounts
- ABIs for EVault, EVC, EulerRouter, oracle interfaces are in `contracts/*.json`

---

## Collateral Type Flow

The bot supports three types of collateral: regular Euler vaults (EVaults), Uniswap V3 wrappers, and Uniswap V4 wrappers. Detection happens at `liquidation_bot.py:1189` — it tries to instantiate a `Vault` (EVault) first; if that fails, it falls back to `WrapperCollateral`.

---

### Regular EVault Collateral

**Detection:** `asset()` call succeeds on the collateral address.

**Python flow (`calculate_liquidation_profit`):**
1. Get the vault's underlying asset via `vault.underlying_asset_address`
2. Get `checkLiquidation()` result: `max_repay` and `seized_collateral_shares`
3. Redeem seized shares to get `seized_collateral_amount` (underlying units)
4. Get one swap quote: `collateral_asset → borrowed_asset`
5. Build `LiquidationParams` with `collateral_asset = underlying`, `additional_token = ZERO_ADDRESS`

**Solidity flow (`Liquidator.sol` — 7-step EVC batch):**
1. Enable controller (liability vault)
2. Enable collateral vault
3. Liquidate account (seize shares from violator)
4. Redeem shares → underlying via `IERC4626.redeem()`
5. Swap collateral → borrowed asset via ISwapper multicall
6. Repay debt; sweep any leftover collateral to `profit_receiver`
7. Disable controller

---

### Uniswap V3 Wrapper Collateral

**Detection:** `asset()` fails, then `token0()` / `token1()` succeed (V3 interface).

**Key difference from EVault:** The wrapper holds Uniswap V3 LP NFTs as ERC6909 tokens. Unwrapping produces **two tokens** (token0, token1). The NFT token IDs must be enabled as collateral in the liquidator's EVC account before liquidation.

**Python flow (`WrapperCollateral.__init__`):**
- Calls `token0()` / `token1()` for the pair addresses
- Calls `pool()` for the V3 pool address (used for price via `slot0()`)
- Sets `wrapper_type = "v3"`

**Python flow (`calculate_wrapper_liquidation_profit`):**
- Simulates unwrap amounts for both tokens via `Vault.check_liquidation_wrapper()`
- Routes to one of four swap cases based on which token(s) match `borrowed_asset`:

| Case | Condition | Swaps needed | `collateral_asset` | `additional_token` |
|------|-----------|-------------|---------------------|---------------------|
| A | `token0 == borrowed` | Swap token1 only | token1 | ZERO_ADDRESS |
| B | `token1 == borrowed` | Swap token0 only | token0 | ZERO_ADDRESS |
| C | Neither matches | Swap both | token0 | token1 |
| D | Both match borrowed | No swaps | ZERO_ADDRESS | ZERO_ADDRESS |

**Solidity flow (`Liquidator.sol` — 7+N-step EVC batch):**
1. Enable controller
2. Enable collateral vault
3. *(Steps 3..2+N)* Enable each wrapper token ID as collateral (one batch item per NFT token ID)
4. Liquidate account
5. Unwrap: iterate `getEnabledTokenIds()`, call `wrapper.unwrap(tokenId, ...)` for each
6. Multicall swaps + repay + sweep(s): sweep `collateral_asset` if non-zero, sweep `additional_token` if non-zero
7. Disable controller
8. Disable collateral

---

### Uniswap V4 Wrapper Collateral

**Detection:** `asset()` fails, `token0()` fails, then `currency0()` / `currency1()` succeed (V4 interface).

**ETH handling — both ERC20 tokens:** `currency0` and `currency1` return normal ERC20 addresses. The flow is identical to V3 with the swap cases above.

**ETH handling — one token is native ETH:** V4 represents native ETH as `address(0)` in `currency0` or `currency1`. The bot replaces `address(0)` with `WETH` at `WrapperCollateral.__init__` (`liquidation_bot.py:182`):
```python
self.token0 = weth if raw_currency0 == ZERO_ADDRESS else raw_currency0
self.token1 = weth if raw_currency1 == ZERO_ADDRESS else raw_currency1
```
This means the rest of the liquidation flow treats the ETH leg as WETH — swap quotes are requested for WETH in/out, and the ISwapper handles the WETH wrapping/unwrapping internally.

**Python flow (`WrapperCollateral.__init__`):**
- Calls `currency0()` / `currency1()` — gets raw values (may include `address(0)` for ETH)
- Calls `weth()` on the wrapper to get the WETH address for that chain
- Substitutes `address(0) → WETH`
- Calls `poolId()` instead of `pool()` (V4 uses a pool ID, not a pool address)
- Sets `wrapper_type = "v4"`
- Price fetched via `StateView.getSlot0(poolId)` instead of `pool.functions.slot0()`

**Oracle resolution (`PullOracleHandler.get_feed_ids`):**
- For V3: resolves `token0()` / `token1()` → Pyth feed IDs
- For V4: resolves `currency0()` / `currency1()` with `address(0) → WETH` → Pyth feed IDs

**Solidity flow:** Identical to V3 — the same `redeemOrUnwrap()` path handles both since both use the `IERC721WrapperBase` interface. The WETH substitution means the unwrapped ETH is already WETH when it arrives at the ISwapper.

---

### Collateral Type Comparison

| Aspect | EVault | V3 Wrapper | V4 Wrapper (ERC20) | V4 Wrapper (ETH leg) |
|--------|--------|------------|---------------------|----------------------|
| Detection | `asset()` works | `token0()` works | `currency0()` works | `currency0()` == `address(0)` |
| Tokens on unwrap | 1 | 2 | 2 | 2 (ETH → WETH) |
| Pool price source | N/A | `pool.slot0()` | N/A | N/A |
| Price source | Oracle | `IUniswapV3Pool.slot0()` | `StateView.getSlot0(poolId)` | `StateView.getSlot0(poolId)` |
| Swap cases | 1 (always swap) | 0–2 (cases A–D) | 0–2 (cases A–D) | 0–2 (cases A–D, WETH as ETH) |
| Token ID enablement | None | Required per NFT | Required per NFT | Required per NFT |
| Redemption method | `IERC4626.redeem()` | `wrapper.unwrap(tokenId)` | `wrapper.unwrap(tokenId)` | `wrapper.unwrap(tokenId)` |
| `additional_token` param | Always zero | Non-zero in case C | Non-zero in case C | Non-zero in case C |

---

## Swap Flow

### Input amount

The sell amount passed to the API is **`seized_collateral_assets * 0.999`** (`liquidation_bot.py:1292`). The bot calls `checkLiquidation()` to get `seized_collateral_shares`, converts them to underlying units via `convertToAssets()`, then shaves off 0.1% to absorb rounding. For wrappers, the same `* 0.999` is applied independently to each of the two unwrapped token amounts.

### API call (`Quoter.get_swap_api_quote`)

All swaps go through the VII/Euler swap API (wrapping 1Inch). Key parameters:

| Param | Value | Meaning |
|-------|-------|---------|
| `amount` | `seized_assets * 0.999` | Exact input — sell this much |
| `swapperMode` | `"0"` | Exact input swap |
| `slippage` | `config.SWAP_SLIPPAGE` (e.g. `1` = 1%) | Encoded into swap calldata by the API |
| `isRepay` | `False` | Just swap, don't repay inside the swap |
| `receiver` | `config.SWAPPER` | Swap output lands at the Swapper contract |

The API returns `amountOut` (expected output) and `swap.multicallItems[].data` (pre-encoded calldata for each swap step), which gets stored in `swap_data` and passed verbatim to `Liquidator.sol`.

### Slippage — two layers

**Layer 1 — DEX-level, encoded by the API** (`liquidation_bot.py:1299`):
`slippage = config.SWAP_SLIPPAGE` is sent to the API, which encodes a minimum output into the swap calldata. The DEX swap will revert on-chain if actual output falls below `amountOut * (1 - slippage%)`.

**Layer 2 — pre-flight check in the bot** (`liquidation_bot.py:1293`):
```python
# Regular vault only:
min_amount_out = max_repay
```
`Quoter.get_swap_api_quote()` checks `amountOut >= min_amount_out` and returns `None` if not, aborting the liquidation before any transaction is sent. For wrapper tokens this is `0` (the two token outputs are pooled, so neither alone needs to cover the full repay).

### Profitability check (off-chain only)

```
leftover_borrow = amountOut - max_repay
```
If `borrowed_asset != WETH`, a second quote converts `leftover_borrow` to ETH. Then:
```
net_profit = leftover_borrow_in_eth - (estimate_gas(tx) * gas_price * 1.2)
```
This is simulation-only — there is **no on-chain profit assertion**.

### On-chain execution (inside the EVC batch)

The Swapper's `multicall` receives these items in order:

1. **Swap calldata** — the pre-encoded 1Inch items from `swap_data`; executes the actual DEX swap(s), output stays in the Swapper contract
2. **`ISwapper.repay(borrowedAsset, vault, type(uint256).max, this)`** — repays as much debt as the Swapper holds (all of the swap output)
3. **`ISwapper.sweep(borrowedAsset, 0, receiver)`** — sends leftover borrowed asset (profit) to `profit_receiver`
4. **`ISwapper.sweep(collateralAsset, 0, receiver)`** — wrapper only: sweeps whichever token was not swapped (case A/B/C)
5. **`ISwapper.sweep(additionalToken, 0, receiver)`** — wrapper case C only: sweeps the second unswapped token

`SwapVerifier` is **not called** in the liquidation path — the only slippage protection on-chain is what the API encoded into the swap calldata itself.
