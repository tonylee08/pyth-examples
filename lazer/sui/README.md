# Pyth Lazer Sui Implementation

**⚠️ DISCLAIMER: This is an example implementation for demonstration purposes only. It has not been audited and should be used at your own risk. Do not use this code in production without proper security review and testing.**

A Sui Move implementation example for parsing and validating [Pyth Lazer](https://docs.pyth.network/lazer) price feed updates. This project demonstrates on-chain verification and parsing of cryptographically signed price feed data from the Pyth Network's high-frequency Lazer protocol. Look at the [`lazer_example` module](./sources/lazer_example.move) for the main implementation.

## Prerequisites

- [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install) installed
- Basic familiarity with Move programming language

## Building and Testing the Project

1. **Build the project**:
   ```bash
   sui move build
   ```

2. **Run all tests**:
```bash
sui move test
```

**Run specific test**:
```bash
sui move test test_parse_and_validate_update
```

## Important Notes
- The `parse_and_validate_update` function uses a single hardcoded public key for signature verification. However, in a real-world scenario, the set of valid public keys may change over time, and multiple keys might be required. For production use, store the authorized public keys in the contract's configuration storage and reference them dynamically, rather than relying on a hardcoded value.
- There is no proper error handling in the `parse_and_validate_update` function and all the assertions use the same error code (0).

## Updating an on-chain object from a TypeScript publisher

The Move package also exposes a `PriceStore` shared object plus two helpers:

- `create_store(feed_id: u32)` — creates and shares a `PriceStore` for a given Lazer feed id (e.g. `1` for BTC/USD).
- `update_price(store, update, clock)` — verifies a Lazer `leEcdsa` update and writes the matching feed into the store. Aborts if the signature is bad, the update is older than the stored one (`E_STALE_UPDATE = 1`), the requested feed isn't in the update (`E_FEED_NOT_FOUND = 2`), or the price/exponent is missing (`E_PRICE_UNAVAILABLE = 3`). Emits a `PriceUpdated` event on success.

A companion off-chain publisher lives at [`lazer/js/src/sui/post_sui.ts`](../js/src/sui/post_sui.ts). It subscribes to BTC/USD over the Lazer WebSocket and posts to `update_price` once per second.

### End-to-end setup (Sui testnet)

1. **Build & test the Move package**
   ```bash
   cd lazer/sui
   sui move build
   sui move test
   ```

2. **Publish to Sui testnet** (requires `sui client switch --env testnet` and a funded address from the [testnet faucet](https://faucet.sui.io/))
   ```bash
   sui client publish --gas-budget 200000000
   ```
   Note the `Published Object` package id — call it `PACKAGE_ID`.

3. **Create a `PriceStore` for BTC/USD (feed id `1`)**
   ```bash
   sui client call \
     --package $PACKAGE_ID \
     --module lazer_example \
     --function create_store \
     --args 1 \
     --gas-budget 20000000
   ```
   In the effects, find the newly created shared object — that id is `STORE_ID`.

4. **Install the JS dependencies**
   ```bash
   cd ../js
   pnpm install
   ```

5. **Configure environment variables**

   Copy the example file and fill in the four required values:
   ```bash
   cp .env.example .env
   $EDITOR .env
   ```
   `.env` is gitignored at the repo root, so your token and private key stay local. The `pnpm` script loads it automatically via Node's built-in `--env-file-if-exists` flag (no `dotenv` dependency).

6. **Run the publisher**
   ```bash
   pnpm run start:post_sui
   ```
   You should see one transaction digest printed roughly every second. Inspect the store with `sui client object $STORE_ID` to confirm `price`, `exponent`, and `lazer_timestamp_us` are advancing.

Customize the cadence with `POST_INTERVAL_MS` (default `1000`) or switch networks with `SUI_NETWORK` (`testnet` | `mainnet` | `devnet` | `localnet`).
