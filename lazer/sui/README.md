# Pyth Lazer Sui Implementation

**⚠️ DISCLAIMER: This is an example implementation for demonstration purposes only. It has not been audited and should be used at your own risk. Do not use this code in production without proper security review and testing.**

A minimal Sui Move *consumer* of the official `pyth_lazer` package. This contract no longer parses or verifies Lazer updates itself — instead, the off-chain publisher builds a two-call Programmable Transaction Block (PTB):

1. `pyth_lazer::pyth_lazer::parse_and_verify_le_ecdsa_update(state, clock, bytes)` — Pyth's on-chain verifier validates the secp256k1 signature against the rotatable trusted-signer set in the shared `State` object and returns a verified `Update` value.
2. `lazer_example::update_price(store, update, clock)` — our consumer takes that verified `Update` (which can only have come from Pyth's verifier, since `Update::new` is package-scoped) and writes the matching feed into a `PriceStore`.

This is the pattern Pyth recommends. See [`lazer_example` module](./sources/lazer_example.move) for the (~140-line) implementation.

## Prerequisites

- [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install) installed
- Basic familiarity with Move programming language

## Building the Project

```bash
sui move build
```

There are no Move unit tests in this consumer — `pyth_lazer::update::Update` cannot be constructed outside the upstream package, so `update_price` is exercised via integration tests (run the JS publisher and observe the on-chain object advance). Pyth's package has its own tests for the verifier.

## Important Notes

- **Use `rev = "sui-testnet"` in `Move.toml` for testnet.** Wormhole is custom-deployed on Sui testnet for maintenance reasons, so the upstream `main` branch will not work there. For mainnet deploys, swap to `rev = "main"`.
- **Pyth Lazer State object ids** (canonical source: [`SuiLazerContracts.json`](https://github.com/pyth-network/pyth-crosschain/blob/sui-testnet/contract_manager/src/store/contracts/SuiLazerContracts.json) in the contract_manager — testnet entry only exists on the `sui-testnet` branch):
  - Testnet: `0xe2b9096a5ea341a9f1eef126b2203727e29e73fdb0641ade2e1e32942f97e4d8`
  - Mainnet: `0xd0db9c1e9212a98120384bf78d8b8c985d87b9ee6921dffcf9d1394062911573`
- **Verification happens in the PTB, not in the contract.** Per [Pyth's guidance](https://docs.pyth.network/price-feeds/pro/integrate-as-consumer/sui), `parse_and_verify_le_ecdsa_update` must be called from the JS PTB and the resulting `Update` passed into the consumer. This decouples your contract from Lazer signer rotations.
- `update_price` enforces a monotonic timestamp guard (`E_STALE_UPDATE = 1`); upstream does not enforce a maximum age, so callers must compare against the last-stored value themselves.

## Updating an on-chain object from a TypeScript publisher

The Move package also exposes a `PriceStore` shared object plus two helpers:

- `create_store(feed_id: u32)` — creates and shares a `PriceStore` for a given Lazer feed id (e.g. `1` for BTC/USD). Initial `price` and `exponent` are `option::none()` until the first `update_price` lands.
- `update_price(store, update, clock)` — takes a verified `pyth_lazer::update::Update` (produced by `parse_and_verify_le_ecdsa_update` earlier in the same PTB) and writes the matching feed into the store. Aborts if the update is older than the stored one (`E_STALE_UPDATE = 1`), the requested feed isn't in the update (`E_FEED_NOT_FOUND = 2`), or the price/exponent is missing (`E_PRICE_UNAVAILABLE = 3`). Emits a `PriceUpdated` event on success.

A companion off-chain publisher lives at [`lazer/js/src/sui/post_sui.ts`](../js/src/sui/post_sui.ts). It uses `@pythnetwork/pyth-lazer-sui-js` to build the two-call PTB and posts a fresh BTC/USD update once per second.

### End-to-end setup (Sui testnet)

1. **Build the Move package**
   ```bash
   cd lazer/sui
   sui move build
   ```

2. **(Workaround) Patch the `pyth_lazer` git cache.** Sui CLI 1.69 reads each git-source dependency's `Published.toml` to learn its on-chain package id. The upstream `pyth_lazer` package doesn't ship that file (only `wormhole` does), so without this step `sui client publish` fails with `Unpublished dependencies: pyth_lazer`. Drop one in by hand:

   ```bash
   PYTH_LAZER_CACHE=$(find ~/.move/git -type d -path "*pyth-crosschain*lazer/contracts/sui" | head -1)
   cat > "$PYTH_LAZER_CACHE/Published.toml" <<'EOF'
   [published.testnet]
   chain-id = "4c78adac"
   published-at = "0xf5bd2141967507050a91b58de3d95e77c432cd90d1799ee46effc27430a68c21"
   original-id = "0xf5bd2141967507050a91b58de3d95e77c432cd90d1799ee46effc27430a68c21"
   version = 1
   toolchain-version = "1.64.0"
   build-config = { flavor = "sui", edition = "2024" }
   upgrade-capability = "0x6b9d46bf924eb34879eb4868441e996b0b8ccb1b36e25d264b5f53d8ea18d143"
   EOF
   ```

   The package id and upgrade-cap come from querying the on-chain Lazer State object's `upgrade_cap` field (`sui client object 0xe2b9...`). If upstream eventually adds `Published.toml` (or pins it via `dep-replacements` cleanly), this workaround can be removed.

3. **Publish to Sui testnet** (requires `sui client switch --env testnet` and a funded address from the [testnet faucet](https://faucet.sui.io/))
   ```bash
   sui client publish --gas-budget 500000000
   ```
   Note the `Published Object` package id — call it `PACKAGE_ID`.

4. **Create a `PriceStore` for BTC/USD (feed id `1`)**
   ```bash
   sui client call \
     --package $PACKAGE_ID \
     --module lazer_example \
     --function create_store \
     --args 1 \
     --gas-budget 20000000
   ```
   In the effects, find the newly created shared object — that id is `STORE_ID`.

5. **Install the JS dependencies**
   ```bash
   cd ../js
   pnpm install
   ```

6. **Configure environment variables**

   Copy the example file and fill in the five required values (`ACCESS_TOKEN`, `SUI_PRIVATE_KEY`, `PACKAGE_ID`, `STORE_ID`, `PYTH_LAZER_STATE_ID`):
   ```bash
   cp .env.example .env
   $EDITOR .env
   ```
   For testnet, set `PYTH_LAZER_STATE_ID=0xe2b9096a5ea341a9f1eef126b2203727e29e73fdb0641ade2e1e32942f97e4d8` (mainnet value is in `.env.example`). `.env` is gitignored at the repo root, so your token and private key stay local. The `pnpm` script loads it automatically via Node's built-in `--env-file-if-exists` flag (no `dotenv` dependency).

7. **Run the publisher**
   ```bash
   pnpm run start:post_sui
   ```
   You should see one transaction digest printed roughly every second. Inspect the store with `sui client object $STORE_ID` to confirm `price`, `exponent`, and `lazer_timestamp_us` are advancing.

Customize the cadence with `POST_INTERVAL_MS` (default `1000`) or switch networks with `SUI_NETWORK` (`testnet` | `mainnet` | `devnet` | `localnet`).
