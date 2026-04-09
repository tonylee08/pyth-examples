/**
 * Subscribes to BTC/USD via Pyth Lazer and posts the latest signed update to a
 * Sui `PriceStore` shared object once per second.
 *
 * Companion to `lazer/sui/sources/lazer_example.move` — the Move package must be
 * published to Sui and a `PriceStore` created (via `create_store`) before this
 * script can run. See `lazer/sui/README.md` for the publish + create-store flow.
 *
 * Verification model: this script builds a two-call Programmable Transaction
 * Block. The first call invokes Pyth's official on-chain verifier
 * (`pyth_lazer::pyth_lazer::parse_and_verify_le_ecdsa_update`) via the
 * `@pythnetwork/pyth-lazer-sui-js` SDK helper, which returns a verified
 * `Update` value. The second call passes that value into our consumer's
 * `update_price`. Because `Update` cannot be constructed outside the
 * `pyth_lazer` package, the type system itself enforces "this came from
 * Pyth's verifier" — no trust assumptions in the consumer code.
 *
 * Required env vars:
 *   ACCESS_TOKEN          Pyth Lazer API token (must be entitled to crypto feeds).
 *   SUI_PRIVATE_KEY       Bech32 ed25519 secret key, e.g. `suiprivkey1...`. Get one
 *                         with `sui keytool export --key-identity <addr>`.
 *   PACKAGE_ID            Object id returned by `sui client publish`.
 *   STORE_ID              Object id of the shared `PriceStore` (from `create_store`).
 *   PYTH_LAZER_STATE_ID   Pyth-managed Lazer State shared object id (testnet/mainnet
 *                         defaults documented in `.env.example`).
 *
 * Optional env vars:
 *   SUI_NETWORK       "testnet" (default) | "mainnet" | "devnet" | "localnet".
 *   POST_INTERVAL_MS  How often to post on-chain. Default 1000 (= 1 update/sec).
 */

import { PythLazerClient } from "@pythnetwork/pyth-lazer-sdk";
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { addParseAndVerifyLeEcdsaUpdateCall } from "@pythnetwork/pyth-lazer-sui-js";

type SuiNetwork = "testnet" | "mainnet" | "devnet" | "localnet";

const requireEnv = (name: string): string => {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
};

const ACCESS_TOKEN = requireEnv("ACCESS_TOKEN");
const SUI_PRIVATE_KEY = requireEnv("SUI_PRIVATE_KEY");
const PACKAGE_ID = requireEnv("PACKAGE_ID");
const STORE_ID = requireEnv("STORE_ID");
const PYTH_LAZER_STATE_ID = requireEnv("PYTH_LAZER_STATE_ID");
const SUI_NETWORK = (process.env.SUI_NETWORK ?? "testnet") as SuiNetwork;
const POST_INTERVAL_MS = Number(process.env.POST_INTERVAL_MS ?? "1000");

// BTC/USD on Pyth Lazer.
const BTC_FEED_ID = 1;

// Sui Clock is at a well-known shared object id.
const SUI_CLOCK_OBJECT_ID = "0x6";

const sui = new SuiClient({ url: getFullnodeUrl(SUI_NETWORK) });
const signer = Ed25519Keypair.fromSecretKey(SUI_PRIVATE_KEY);

// Holds the most recent leEcdsa update we've received from Lazer. The drain
// loop reads this — we deliberately overwrite older updates instead of
// queueing, so the on-chain write is always the freshest price available.
let latestUpdateHex: string | undefined;
let lastPostedAt = 0;
let inFlight = false;

const main = async () => {
  console.log(`signer address: ${signer.toSuiAddress()}`);
  console.log(`network:        ${SUI_NETWORK}`);
  console.log(`package:        ${PACKAGE_ID}`);
  console.log(`store:          ${STORE_ID}`);
  console.log(`lazer state:    ${PYTH_LAZER_STATE_ID}`);
  console.log(`post interval:  ${POST_INTERVAL_MS}ms`);

  const lazer = await PythLazerClient.create({
    urls: ["wss://pyth-lazer.dourolabs.app/v1/stream"],
    token: ACCESS_TOKEN,
  });

  lazer.addMessageListener((message) => {
    if (message.type !== "json") return;
    if (message.value.type !== "streamUpdated") return;
    const data = message.value.leEcdsa?.data;
    if (data) {
      latestUpdateHex = data;
    }
  });

  lazer.addAllConnectionsDownListener(() => {
    console.error("All Lazer connections are down");
  });

  lazer.subscribe({
    type: "subscribe",
    subscriptionId: 1,
    priceFeedIds: [BTC_FEED_ID],
    // The Move parser supports both `price` and `exponent`, and `update_price`
    // requires both to be present.
    properties: ["price", "exponent"],
    // `leEcdsa` is the format Pyth's Sui verifier expects.
    formats: ["leEcdsa"],
    deliveryFormat: "json",
    // Subscribe at 200ms upstream; the drain loop below throttles to 1Hz.
    channel: "fixed_rate@200ms",
    jsonBinaryEncoding: "hex",
  });

  // Drain loop: every tick, if enough time has elapsed and we have a fresh
  // update buffered and no transaction is in flight, post one.
  setInterval(() => void postIfDue(), Math.min(250, POST_INTERVAL_MS));

  // Graceful shutdown on Ctrl+C.
  process.on("SIGINT", () => {
    console.log("\nShutting down...");
    lazer.shutdown();
    process.exit(0);
  });
};

const postIfDue = async () => {
  if (inFlight) return;
  if (!latestUpdateHex) return;
  if (Date.now() - lastPostedAt < POST_INTERVAL_MS) return;

  inFlight = true;
  // Snapshot + clear so a slow tx doesn't re-post the same bytes.
  const updateHex = latestUpdateHex;
  latestUpdateHex = undefined;
  // Mark `lastPostedAt` BEFORE awaiting the tx so the cooldown clock starts
  // when the post *began*, not when it confirmed. Otherwise the cadence
  // becomes (POST_INTERVAL_MS + tx confirmation latency) ≈ 2s on testnet.
  lastPostedAt = Date.now();

  try {
    const updateBytes = Buffer.from(updateHex, "hex");

    const tx = new Transaction();
    // Step 1: Pyth's on-chain verifier. Returns a verified `Update` value
    // into the PTB. Internally this RPCs `getObject(stateObjectId)` to
    // resolve the latest package id behind the upgrade cap, so it adds
    // ~50–200ms to each tx build. Acceptable for 1Hz.
    const verifiedUpdate = await addParseAndVerifyLeEcdsaUpdateCall({
      client: sui,
      tx,
      stateObjectId: PYTH_LAZER_STATE_ID,
      update: updateBytes,
    });

    // Step 2: hand the verified Update straight to our consumer. The Move
    // type system guarantees this Update came from Pyth's verifier — we
    // don't (and can't) check it ourselves.
    tx.moveCall({
      target: `${PACKAGE_ID}::lazer_example::update_price`,
      arguments: [
        tx.object(STORE_ID),
        verifiedUpdate,
        tx.object(SUI_CLOCK_OBJECT_ID),
      ],
    });

    const result = await sui.signAndExecuteTransaction({
      signer,
      transaction: tx,
      options: { showEffects: true },
    });

    const status = result.effects?.status?.status ?? "unknown";
    console.log(`[${new Date().toISOString()}] posted ${result.digest} (${status})`);
  } catch (err) {
    console.error("post failed:", err instanceof Error ? err.message : err);
  } finally {
    inFlight = false;
  }
};

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
