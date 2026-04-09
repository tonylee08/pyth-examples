/// Pyth Lazer Sui consumer example.
///
/// This module is a *consumer* of the official `pyth_lazer` package — it does
/// not parse or verify Lazer updates itself. Instead, the off-chain publisher
/// builds a Programmable Transaction Block (PTB) with two calls in sequence:
///
/// 1. `pyth_lazer::pyth_lazer::parse_and_verify_le_ecdsa_update(state, clock, bytes)`
///    runs Pyth's verifier and returns a verified `Update` value.
/// 2. `lazer_example::update_price(store, update, clock)` writes the relevant
///    feed into our `PriceStore`.
///
/// Because `pyth_lazer::update::Update::new` is package-scoped, the only way
/// to get an `Update` value is via Pyth's verifier. The Move type system
/// therefore enforces "this came from Pyth's verifier" — no assertions
/// needed in our code.
module lazer_example::lazer_example;

use pyth_lazer::update::{Self, Update};
use pyth_lazer::feed::{Self, Feed};
use pyth_lazer::i64::I64;
use pyth_lazer::i16::I16;
use sui::clock::Clock;
use sui::event;

const E_STALE_UPDATE: u64 = 1;
const E_FEED_NOT_FOUND: u64 = 2;
const E_PRICE_UNAVAILABLE: u64 = 3;

/// Shared object that holds the latest price for a single Lazer feed.
/// Created once per feed via `create_store` and updated by `update_price`.
public struct PriceStore has key {
    id: UID,
    /// Lazer feed id this store tracks (e.g. 1 for BTC/USD).
    feed_id: u32,
    /// Latest price reported by Lazer. `none` until the first successful
    /// `update_price` call. Interpreted with `exponent`.
    price: Option<I64>,
    /// Decimal exponent for `price` (typically negative, e.g. -8). `none`
    /// until the first successful `update_price` call.
    exponent: Option<I16>,
    /// Timestamp of the latest update, in microseconds (Lazer's units).
    lazer_timestamp_us: u64,
    /// Sui clock timestamp (ms) when the store was last touched. Diagnostic only.
    last_updated_ms: u64,
}

/// Emitted on every successful `update_price` call.
public struct PriceUpdated has copy, drop {
    feed_id: u32,
    price: I64,
    exponent: I16,
    lazer_timestamp_us: u64,
}

/// Create and share a `PriceStore` for the given Lazer feed id.
/// Call this once per feed; subsequent updates use `update_price`.
public fun create_store(feed_id: u32, ctx: &mut TxContext) {
    let store = PriceStore {
        id: object::new(ctx),
        feed_id,
        price: option::none(),
        exponent: option::none(),
        lazer_timestamp_us: 0,
        last_updated_ms: 0,
    };
    transfer::share_object(store);
}

/// Write the matching feed from a verified Lazer `Update` into `store`.
///
/// `update` must be the value returned by
/// `pyth_lazer::pyth_lazer::parse_and_verify_le_ecdsa_update` in the same PTB —
/// the type system enforces this since `Update` cannot be constructed outside
/// the `pyth_lazer` package.
///
/// Aborts if:
/// - the update is older than what's already stored (`E_STALE_UPDATE`),
/// - the store's feed id is not present in the update (`E_FEED_NOT_FOUND`),
/// - the matched feed has no price or no exponent (`E_PRICE_UNAVAILABLE`).
public fun update_price(
    store: &mut PriceStore,
    update: Update,
    clock: &Clock,
) {
    let ts = update::timestamp(&update);
    assert!(ts > store.lazer_timestamp_us, E_STALE_UPDATE);

    let feed = find_feed(update::feeds_ref(&update), store.feed_id);

    // Both Option layers must be Some: the field must exist in the update,
    // and the value must be present (Lazer can return None if there are not
    // enough publishers).
    let price_outer = feed::price(feed);
    assert!(price_outer.is_some(), E_PRICE_UNAVAILABLE);
    let price_inner = price_outer.borrow();
    assert!(price_inner.is_some(), E_PRICE_UNAVAILABLE);
    let price = *price_inner.borrow();

    let exp_outer = feed::exponent(feed);
    assert!(exp_outer.is_some(), E_PRICE_UNAVAILABLE);
    let exponent = *exp_outer.borrow();

    store.price = option::some(price);
    store.exponent = option::some(exponent);
    store.lazer_timestamp_us = ts;
    store.last_updated_ms = clock.timestamp_ms();

    event::emit(PriceUpdated {
        feed_id: store.feed_id,
        price,
        exponent,
        lazer_timestamp_us: ts,
    });
}

/// Read-only accessors — useful from PTBs and other modules.
public fun price(store: &PriceStore): Option<I64> { store.price }
public fun exponent(store: &PriceStore): Option<I16> { store.exponent }
public fun feed_id(store: &PriceStore): u32 { store.feed_id }
public fun lazer_timestamp_us(store: &PriceStore): u64 { store.lazer_timestamp_us }
public fun last_updated_ms(store: &PriceStore): u64 { store.last_updated_ms }

/// Linear scan for the feed with `target_id`. Aborts with `E_FEED_NOT_FOUND`
/// if no matching feed is in the update. Pyth's `pyth_lazer::update` only
/// exposes `feeds_ref(): &vector<Feed>`, so the caller still has to filter.
fun find_feed(feeds: &vector<Feed>, target_id: u32): &Feed {
    let len = feeds.length();
    let mut i = 0;
    while (i < len) {
        let f = &feeds[i];
        if (feed::feed_id(f) == target_id) {
            return f
        };
        i = i + 1;
    };
    abort E_FEED_NOT_FOUND
}
