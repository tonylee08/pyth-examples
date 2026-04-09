/**
 * One-shot: subscribe to ETH/USD (Lazer feed id 2) and try to post the update
 * to a `PriceStore` configured for a *different* feed (e.g. the BTC/USD store
 * created via `create_store(1)`). The Move contract should abort with
 * `E_FEED_NOT_FOUND = 2` because `find_feed` cannot match feed id 1 in a
 * payload that only contains feed id 2.
 *
 * Run with:
 *   pnpm run start:post_sui_wrong_feed
 *
 * Reuses the same env vars as `post_sui.ts` — including STORE_ID, which
 * intentionally points at the existing BTC store.
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

// ETH/USD on Pyth Lazer — intentionally NOT the same feed the BTC store expects.
const WRONG_FEED_ID = 2;
const SUI_CLOCK_OBJECT_ID = "0x6";

const sui = new SuiClient({ url: getFullnodeUrl(SUI_NETWORK) });
const signer = Ed25519Keypair.fromSecretKey(SUI_PRIVATE_KEY);

const main = async () => {
  console.log(`signer address: ${signer.toSuiAddress()}`);
  console.log(`network:        ${SUI_NETWORK}`);
  console.log(`package:        ${PACKAGE_ID}`);
  console.log(`store:          ${STORE_ID} (expects feed 1 / BTC)`);
  console.log(`sending feed:   ${WRONG_FEED_ID} (ETH) — should fail`);

  const lazer = await PythLazerClient.create({
    urls: ["wss://pyth-lazer.dourolabs.app/v1/stream"],
    token: ACCESS_TOKEN,
  });

  // Wait for the first leEcdsa update on feed 2, then resolve.
  const updateHex = await new Promise<string>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error("timed out waiting for ETH update")),
      10_000,
    );

    lazer.addMessageListener((message) => {
      if (message.type !== "json") return;
      if (message.value.type !== "streamUpdated") return;
      const data = message.value.leEcdsa?.data;
      if (data) {
        clearTimeout(timer);
        resolve(data);
      }
    });

    lazer.subscribe({
      type: "subscribe",
      subscriptionId: 1,
      priceFeedIds: [WRONG_FEED_ID],
      properties: ["price", "exponent"],
      formats: ["leEcdsa"],
      deliveryFormat: "json",
      channel: "fixed_rate@200ms",
      jsonBinaryEncoding: "hex",
    });
  });

  console.log(`got ETH update (${updateHex.length / 2} bytes), submitting...`);

  const updateBytes = Buffer.from(updateHex, "hex");
  const tx = new Transaction();
  // Same two-call PTB as post_sui.ts: Pyth verifies, our consumer takes the
  // verified Update. The signature check passes (the bytes ARE a valid signed
  // ETH update), so the abort comes from `find_feed` inside our `update_price`,
  // not from the verifier.
  const verifiedUpdate = await addParseAndVerifyLeEcdsaUpdateCall({
    client: sui,
    tx,
    stateObjectId: PYTH_LAZER_STATE_ID,
    update: updateBytes,
  });
  tx.moveCall({
    target: `${PACKAGE_ID}::lazer_example::update_price`,
    arguments: [
      tx.object(STORE_ID),
      verifiedUpdate,
      tx.object(SUI_CLOCK_OBJECT_ID),
    ],
  });

  try {
    const result = await sui.signAndExecuteTransaction({
      signer,
      transaction: tx,
      options: { showEffects: true },
    });
    const status = result.effects?.status?.status ?? "unknown";
    const error = result.effects?.status?.error;
    console.log(`tx digest: ${result.digest}`);
    console.log(`status:    ${status}`);
    if (error) {
      console.log(`error:     ${error}`);
      console.log(
        "\nExpected: a MoveAbort with code 2 (E_FEED_NOT_FOUND) inside `lazer_example::find_feed`.",
      );
    } else {
      console.warn(
        "\nUnexpected: the transaction succeeded. Did STORE_ID get pointed at a feed-2 store?",
      );
    }
  } catch (err) {
    // Pre-flight (dry-run) failures land here instead of in `effects.status.error`.
    console.log("submission threw:");
    console.log(err instanceof Error ? err.message : err);
    console.log(
      "\nExpected: a MoveAbort with code 2 (E_FEED_NOT_FOUND) inside `lazer_example::find_feed`.",
    );
  } finally {
    lazer.shutdown();
  }
};

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
