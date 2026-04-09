# Pyth Lazer → Sui Example

A pruned fork of [pyth-network/pyth-examples](https://github.com/pyth-network/pyth-examples) focused on a single end-to-end example: subscribing to a Pyth Lazer (Pyth Pro) price feed and updating an on-chain Sui object once per second.

## What's here

- [`lazer/sui/`](./lazer/sui) — Sui Move package (`lazer_example`) that verifies a Pyth Lazer `leEcdsa` update and stores the latest price for one feed in a shared `PriceStore` object. See [`lazer/sui/README.md`](./lazer/sui/README.md) for the full publish + run flow.
- [`lazer/js/`](./lazer/js) — TypeScript publisher that subscribes to BTC/USD over Pyth Lazer's WebSocket and posts updates to the Move contract. Configured via `.env` (see [`lazer/js/.env.example`](./lazer/js/.env.example)).

## Quick start

See [`lazer/sui/README.md`](./lazer/sui/README.md) for the full walkthrough — build the Move package, publish to testnet, create a `PriceStore`, and run the publisher.
