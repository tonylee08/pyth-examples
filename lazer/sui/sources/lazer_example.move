module lazer_example::lazer_example;

use lazer_example::i64::{Self, I64};
use lazer_example::i16::{Self, I16};
use sui::bcs;
use sui::clock::Clock;
use sui::ecdsa_k1::secp256k1_ecrecover;
use sui::event;

const UPDATE_MESSAGE_MAGIC: u32 = 1296547300;
const PAYLOAD_MAGIC: u32 = 2479346549;

const E_STALE_UPDATE: u64 = 1;
const E_FEED_NOT_FOUND: u64 = 2;
const E_PRICE_UNAVAILABLE: u64 = 3;

public enum Channel has copy, drop {
    Invalid,
    RealTime,
    FixedRate50ms,
    FixedRate200ms,
}

public struct Update has drop {
    timestamp: u64,
    channel: Channel,
    feeds: vector<Feed>,
}

/// The feed struct is based on the Lazer rust protocol definition defined here:
/// https://github.com/pyth-network/pyth-crosschain/blob/main/lazer/sdk/rust/protocol/src/types.rs#L10
///
/// Some fields in Lazer are optional, as in Lazer might return None for them due to some conditions (for example,
/// not having enough publishers to calculate the price) and that is why they are represented as Option<Option<T>>.
/// The first Option<T> is for the existence of the field within the update data and the second Option<T> is for the
/// value of the field.
public struct Feed has drop {
    /// Unique identifier for the price feed (e.g., 1 for BTC/USD, 2 for ETH/USD)
    feed_id: u32,
    /// Current aggregate price from all publishers
    price: Option<Option<I64>>,
    /// Best bid price available across all publishers
    best_bid_price: Option<Option<I64>>,
    /// Best ask price available across all publishers
    best_ask_price: Option<Option<I64>>,
    /// Number of publishers contributing to this price feed
    publisher_count: Option<u16>,
    /// Price exponent (typically negative, e.g., -8 means divide price by 10^8)
    exponent: Option<I16>,
    /// Confidence interval representing price uncertainty
    confidence: Option<Option<I64>>,
    /// Funding rate for derivative products (e.g., perpetual futures)
    funding_rate: Option<Option<I64>>,
    /// Timestamp when the funding rate was last updated
    funding_timestamp: Option<Option<u64>>,
}

/// Parse the Lazer update message and validate the signature.
///
/// The parsing logic is based on the Lazer rust protocol definition defined here:
/// https://github.com/pyth-network/pyth-crosschain/tree/main/lazer/sdk/rust/protocol
public fun parse_and_validate_update(update: vector<u8>): Update {
    let mut cursor = bcs::new(update);

    let magic = cursor.peel_u32();
    assert!(magic == UPDATE_MESSAGE_MAGIC, 0);

    let mut signature = vector::empty<u8>();

    let mut sig_i = 0;
    while (sig_i < 65) {
        signature.push_back(cursor.peel_u8());
        sig_i = sig_i + 1;
    };

    let payload_len = cursor.peel_u16();

    let payload = cursor.into_remainder_bytes();

    assert!((payload_len as u64) == payload.length(), 0);

    // 0 stands for keccak256 hash
    let pubkey = secp256k1_ecrecover(&signature, &payload, 0);

    // Lazer signer pubkey
    assert!(pubkey == x"03a4380f01136eb2640f90c17e1e319e02bbafbeef2e6e67dc48af53f9827e155b", 0);

    let mut cursor = bcs::new(payload);
    let payload_magic = cursor.peel_u32();
    assert!(payload_magic == PAYLOAD_MAGIC, 0);

    let timestamp = cursor.peel_u64();
    let channel_value = cursor.peel_u8();
    let channel = if (channel_value == 0) {
        Channel::Invalid
    } else if (channel_value == 1) {
        Channel::RealTime
    } else if (channel_value == 2) {
        Channel::FixedRate50ms
    } else if (channel_value == 3) {
        Channel::FixedRate200ms
    } else {
        Channel::Invalid // Default to Invalid for unknown values
    };

    let mut feeds = vector::empty<Feed>();
    let mut feed_i = 0;

    let feed_count = cursor.peel_u8();

    while (feed_i < feed_count) {
        let feed_id = cursor.peel_u32();
        let mut feed = Feed {
            feed_id: feed_id,
            price: option::none(),
            best_bid_price: option::none(),
            best_ask_price: option::none(),
            publisher_count: option::none(),
            exponent: option::none(),
            confidence: option::none(),
            funding_rate: option::none(),
            funding_timestamp: option::none(),
        };

        let properties_count = cursor.peel_u8();
        let mut properties_i = 0;

        while (properties_i < properties_count) {
            let property_id = cursor.peel_u8();

            if (property_id == 0) {
                let price = cursor.peel_u64();
                if (price != 0) {
                    feed.price = option::some(option::some(i64::from_u64(price)));
                } else {
                    feed.price = option::some(option::none());
                }
            } else if (property_id == 1) {
                let best_bid_price = cursor.peel_u64();
                if (best_bid_price != 0) {
                    feed.best_bid_price = option::some(option::some(i64::from_u64(best_bid_price)));
                } else {
                    feed.best_bid_price = option::some(option::none());
                }
            } else if (property_id == 2) {
                let best_ask_price = cursor.peel_u64();
                if (best_ask_price != 0) {
                    feed.best_ask_price = option::some(option::some(i64::from_u64(best_ask_price)));
                } else {
                    feed.best_ask_price = option::some(option::none());
                }
            } else if (property_id == 3) {
                let publisher_count = cursor.peel_u16();
                feed.publisher_count = option::some(publisher_count);
            } else if (property_id == 4) {
                let exponent = cursor.peel_u16();
                feed.exponent = option::some(i16::from_u16(exponent));
            } else if (property_id == 5) {
                let confidence = cursor.peel_u64();
                if (confidence != 0) {
                    feed.confidence = option::some(option::some(i64::from_u64(confidence)));
                } else {
                    feed.confidence = option::some(option::none());
                }
            } else if (property_id == 6) {
                let exists = cursor.peel_u8();
                if (exists == 1) {
                    let funding_rate = cursor.peel_u64();
                    feed.funding_rate = option::some(option::some(i64::from_u64(funding_rate)));
                } else {
                    feed.funding_rate = option::some(option::none());
                }
            } else if (property_id == 7) {
                let exists = cursor.peel_u8();

                if (exists == 1) {
                    let funding_timestamp = cursor.peel_u64();
                    feed.funding_timestamp = option::some(option::some(funding_timestamp));
                } else {
                    feed.funding_timestamp = option::some(option::none());
                }
            } else {
                // When we have an unknown property, we do not know its length, and therefore
                // we cannot ignore it and parse the next properties.
                abort 0
            };

            properties_i = properties_i + 1;
        };

        vector::push_back(&mut feeds, feed);

        feed_i = feed_i + 1;
    };

    let remaining_bytes = cursor.into_remainder_bytes();
    assert!(remaining_bytes.length() == 0, 0);

    Update {
        timestamp: timestamp,
        channel: channel,
        feeds: feeds,
    }
}

/// Shared object that holds the latest price for a single Lazer feed.
/// Created once per feed via `create_store` and updated by `update_price`.
public struct PriceStore has key {
    id: UID,
    /// Lazer feed id this store tracks (e.g. 1 for BTC/USD).
    feed_id: u32,
    /// Latest price reported by Lazer. Interpreted with `exponent`.
    price: I64,
    /// Decimal exponent for `price` (typically negative, e.g. -8).
    exponent: I16,
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
        price: i64::new(0, false),
        exponent: i16::new(0, false),
        lazer_timestamp_us: 0,
        last_updated_ms: 0,
    };
    transfer::share_object(store);
}

/// Verify a Lazer `leEcdsa` update and write the matching feed into `store`.
///
/// Aborts if:
/// - the signature or magic bytes don't match (via `parse_and_validate_update`),
/// - the update is older than what's already stored (`E_STALE_UPDATE`),
/// - the store's feed id is not present in the update (`E_FEED_NOT_FOUND`),
/// - the matched feed has no price or no exponent (`E_PRICE_UNAVAILABLE`).
public fun update_price(
    store: &mut PriceStore,
    update: vector<u8>,
    clock: &Clock,
) {
    let parsed = parse_and_validate_update(update);
    assert!(parsed.timestamp > store.lazer_timestamp_us, E_STALE_UPDATE);

    let feed = find_feed(&parsed.feeds, store.feed_id);

    // Both Option layers must be Some: the field must exist in the update,
    // and the value must be present (Lazer can return None if there are not
    // enough publishers).
    assert!(feed.price.is_some(), E_PRICE_UNAVAILABLE);
    let price_outer = feed.price.borrow();
    assert!(price_outer.is_some(), E_PRICE_UNAVAILABLE);
    let price = *price_outer.borrow();

    assert!(feed.exponent.is_some(), E_PRICE_UNAVAILABLE);
    let exponent = *feed.exponent.borrow();

    store.price = price;
    store.exponent = exponent;
    store.lazer_timestamp_us = parsed.timestamp;
    store.last_updated_ms = clock.timestamp_ms();

    event::emit(PriceUpdated {
        feed_id: store.feed_id,
        price,
        exponent,
        lazer_timestamp_us: parsed.timestamp,
    });
}

/// Read-only accessors — useful from PTBs and other modules.
public fun price(store: &PriceStore): I64 { store.price }
public fun exponent(store: &PriceStore): I16 { store.exponent }
public fun feed_id(store: &PriceStore): u32 { store.feed_id }
public fun lazer_timestamp_us(store: &PriceStore): u64 { store.lazer_timestamp_us }
public fun last_updated_ms(store: &PriceStore): u64 { store.last_updated_ms }

/// Linear scan for the feed with `target_id`. Aborts if not present.
fun find_feed(feeds: &vector<Feed>, target_id: u32): &Feed {
    let len = feeds.length();
    let mut i = 0;
    while (i < len) {
        let feed = &feeds[i];
        if (feed.feed_id == target_id) {
            return feed
        };
        i = i + 1;
    };
    abort E_FEED_NOT_FOUND
}

#[test]
public fun test_parse_and_validate_update() {
    /*
    The test data is from the Lazer subscription:
    > Request
    {"subscriptionId": 1, "type": "subscribe", "priceFeedIds": [1, 2, 112], "properties": ["price", "bestBidPrice", "bestAskPrice", "exponent", "fundingRate", "fundingTimestamp"], "chains": ["leEcdsa"], "channel": "fixed_rate@200ms", "jsonBinaryEncoding": "hex"}
    < Response
    {
        "type": "streamUpdated",
        "subscriptionId": 1,
        "parsed": {
            "timestampUs": "1753787555800000",
            "priceFeeds": [
                {
                    "priceFeedId": 1,
                    "price": "11838353875029",
                    "bestBidPrice": "11838047151903",
                    "bestAskPrice": "11839270720540",
                    "exponent": -8
                },
                {
                    "priceFeedId": 2,
                    "price": "382538699314",
                    "bestBidPrice": "382520831095",
                    "bestAskPrice": "382561500067",
                    "exponent": -8
                },
                {
                    "priceFeedId": 112,
                    "price": "118856300000000000",
                    "exponent": -12,
                    "fundingRate": 100000000,
                    "fundingTimestamp": 1753776000000000
                }
            ]
        },
        "leEcdsa": {
            "encoding": "hex",
            "data": "e4bd474daafa101a7cdc2f4af22f5735aa3278f7161ae15efa9eac3851ca437e322fde467c9475497e1297499344826fe1209f6de234dce35bdfab8bf6b073be12a07cb201930075d3c793c063467c0f3b0600030301000000060055a0e054c40a0000011f679842c40a0000021c94868bc40a000004f8ff0600070002000000060032521511590000000177ac04105900000002a33b71125900000004f8ff060007007000000006000038d1d42c43a60101000000000000000002000000000000000004f4ff060100e1f50500000000070100e07ecb0c3b0600"
        }
    }
    */

    let hex_message = x"e4bd474daafa101a7cdc2f4af22f5735aa3278f7161ae15efa9eac3851ca437e322fde467c9475497e1297499344826fe1209f6de234dce35bdfab8bf6b073be12a07cb201930075d3c793c063467c0f3b0600030301000000060055a0e054c40a0000011f679842c40a0000021c94868bc40a000004f8ff0600070002000000060032521511590000000177ac04105900000002a33b71125900000004f8ff060007007000000006000038d1d42c43a60101000000000000000002000000000000000004f4ff060100e1f50500000000070100e07ecb0c3b0600";
    
    let Update { timestamp, channel, feeds } = parse_and_validate_update(hex_message);
    
    // If we reach this point, the function worked correctly
    // (no assertion failures in parse_and_validate_update)
    assert!(timestamp == 1753787555800000, 0);
    assert!(channel == Channel::FixedRate200ms, 0);
    assert!(vector::length(&feeds) == 3, 0);

    let feed_1 = vector::borrow(&feeds, 0);
    assert!(feed_1.feed_id == 1, 0);
    assert!(feed_1.price == option::some(option::some(i64::from_u64(11838353875029))), 0);
    assert!(feed_1.best_bid_price == option::some(option::some(i64::from_u64(11838047151903))), 0);
    assert!(feed_1.best_ask_price == option::some(option::some(i64::from_u64(11839270720540))), 0);
    assert!(feed_1.exponent == option::some(i16::new(8, true)), 0);
    assert!(feed_1.publisher_count == option::none(), 0);
    assert!(feed_1.confidence == option::none(), 0);
    assert!(feed_1.funding_rate == option::some(option::none()), 0);
    assert!(feed_1.funding_timestamp == option::some(option::none()), 0);

    let feed_2 = vector::borrow(&feeds, 1);
    assert!(feed_2.feed_id == 2, 0);
    assert!(feed_2.price == option::some(option::some(i64::from_u64(382538699314))), 0);
    assert!(feed_2.best_bid_price == option::some(option::some(i64::from_u64(382520831095))), 0);
    assert!(feed_2.best_ask_price == option::some(option::some(i64::from_u64(382561500067))), 0);
    assert!(feed_2.exponent == option::some(i16::new(8, true)), 0);
    assert!(feed_2.publisher_count == option::none(), 0);
    assert!(feed_2.confidence == option::none(), 0);
    assert!(feed_2.funding_rate == option::some(option::none()), 0);
    assert!(feed_2.funding_timestamp == option::some(option::none()), 0);

    let feed_3 = vector::borrow(&feeds, 2);
    assert!(feed_3.feed_id == 112, 0);
    assert!(feed_3.price == option::some(option::some(i64::from_u64(118856300000000000))), 0);
    assert!(feed_3.best_bid_price == option::some(option::none()), 0);
    assert!(feed_3.best_ask_price == option::some(option::none()), 0);
    assert!(feed_3.exponent == option::some(i16::new(12, true)), 0);
    assert!(feed_3.publisher_count == option::none(), 0);
    assert!(feed_3.confidence == option::none(), 0);
    assert!(feed_3.funding_rate == option::some(option::some(i64::from_u64(100000000))), 0);
    assert!(feed_3.funding_timestamp == option::some(option::some(1753776000000000)), 0);
}
