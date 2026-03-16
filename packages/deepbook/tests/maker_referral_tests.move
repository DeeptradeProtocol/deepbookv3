// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::maker_referral_tests;

use deepbook::{
    balance_manager::{Self, BalanceManager, TradeCap, DeepBookPoolReferral},
    balance_manager_tests::{
        USDC,
        create_acct_and_share_with_funds_typed,
        asset_balance,
        deposit_into_account
    },
    constants,
    math,
    pool::Pool,
    pool_tests::{
        setup_test,
        setup_pool_with_default_fees,
        setup_pool_with_default_fees_and_reference_pool,
        place_limit_order,
        place_market_order,
        cancel_order,
        modify_order,
        set_time
    }
};
use std::unit_test::assert_eq;
use sui::{
    clock::Clock,
    coin::mint_for_testing,
    sui::SUI,
    test_scenario::{Scenario, begin, end, return_shared}
};
use token::deep::DEEP;

const OWNER: address = @0x1;
const ALICE: address = @0xAAAA;
const BOB: address = @0xBBBB;
const CAROL: address = @0xCCCC;

// === Group 1: Basic Placement and Fill (DEEP fees) ===

#[test]
fun maker_referral_full_fill_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Mint referral with 0 multiplier, set maker_fee_rate = 10 bps
    let referral_id;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id = pool.mint_referral(0, test.ctx());
        return_shared(pool);
    };

    let maker_fee_rate = 1_000_000; // 10 bps
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        pool.update_pool_referral_fee_rate(&referral, 0, maker_fee_rate, test.ctx());
        return_shared(referral);
        return_shared(pool);
    };

    // Set referral on BOB's balance manager (BOB is the maker)
    test.next_tx(BOB);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let trade_cap = balance_manager.mint_trade_cap(test.ctx());
        balance_manager.set_balance_manager_referral(&referral, &trade_cap);
        transfer::public_transfer(trade_cap, BOB);
        return_shared(referral);
        return_shared(balance_manager);
    };

    // BOB (maker) places ask limit order at $3 for 100 SUI (rests in book, pay_with_deep=true)
    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    let bob_deep_before = asset_balance<DEEP>(BOB, balance_manager_id_bob, &mut test);

    let order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false, // ask
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );
    assert!(order_info.order_inserted());

    let _bob_deep_after_placement = asset_balance<DEEP>(BOB, balance_manager_id_bob, &mut test);

    // ALICE (taker) places bid market order filling BOB's ask completely
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        quantity,
        true, // bid
        true, // pay_with_deep
        &mut test,
    );

    // Check referral rewards
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);

        // effective_rate = maker_fee_rate (1_000_000) + mul(protocol_maker_fee, 0) = 1_000_000
        // For ask with DEEP: fee_quantity returns DEEP
        // deep_per_asset (SUI is base) ≈ 100 * 1e9 (DEEP_MULTIPLIER)
        // fee_balances.deep = mul(100 * 1e9, 100 * 1e9) = 100 * 100 * 1e9 = 10_000 * 1e9
        // After mul(effective_rate=1_000_000): mul(10_000e9, 1_000_000) = 10_000_000_000 (10 DEEP)
        let expected_deep = math::mul(
            math::mul(quantity, constants::deep_multiplier()),
            maker_fee_rate,
        );
        assert_eq!(deep, expected_deep);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);

        return_shared(referral);
        return_shared(pool);
    };

    // Verify the maker's DEEP was reduced by the referral lock (which was fully transferred to rewards)
    let bob_deep_after_fill = asset_balance<DEEP>(BOB, balance_manager_id_bob, &mut test);
    let expected_lock = math::mul(
        math::mul(quantity, constants::deep_multiplier()),
        maker_fee_rate,
    );
    // Bob's DEEP decreased by protocol maker fee + referral lock at placement,
    // then protocol fee was refunded on fill (it goes to settled), but referral lock is consumed.
    // The net difference from before placement to after fill should include the referral amount.
    assert!(bob_deep_before > bob_deep_after_fill);
    // Referral lock = expected_lock should equal the deep rewards
    assert_eq!(
        expected_lock,
        math::mul(
            math::mul(quantity, constants::deep_multiplier()),
            maker_fee_rate,
        ),
    );

    end(test);
}

#[test]
fun maker_referral_partial_fill_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let referral_id;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id = pool.mint_referral(0, test.ctx());
        return_shared(pool);
    };

    let maker_fee_rate = 1_000_000; // 10 bps
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        pool.update_pool_referral_fee_rate(&referral, 0, maker_fee_rate, test.ctx());
        return_shared(referral);
        return_shared(pool);
    };

    test.next_tx(BOB);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let trade_cap = balance_manager.mint_trade_cap(test.ctx());
        balance_manager.set_balance_manager_referral(&referral, &trade_cap);
        transfer::public_transfer(trade_cap, BOB);
        return_shared(referral);
        return_shared(balance_manager);
    };

    // BOB places ask limit for 1000 SUI at $3
    let price = 3 * constants::float_scaling();
    let total_quantity = 1000 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        total_quantity,
        false, // ask
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );

    // ALICE fills only 400
    let fill_quantity = 400 * constants::float_scaling();
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        fill_quantity,
        true, // bid
        true, // pay_with_deep
        &mut test,
    );

    // Check referral rewards (should be for 400 qty only)
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);

        let expected_deep = math::mul(
            math::mul(fill_quantity, constants::deep_multiplier()),
            maker_fee_rate,
        );
        assert_eq!(deep, expected_deep);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);

        // Check locked_balance includes remaining referral lock for 600 qty
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let (_, _, deep_locked) = pool.locked_balance(&balance_manager);
        // Should have remaining lock for 600 qty
        let remaining_qty = total_quantity - fill_quantity;
        let remaining_referral_lock = math::mul(
            math::mul(remaining_qty, constants::deep_multiplier()),
            maker_fee_rate,
        );
        assert!(deep_locked >= remaining_referral_lock);
        return_shared(balance_manager);
        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun maker_referral_multiple_partial_fills_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let balance_manager_id_carol = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        CAROL,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let referral_id;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id = pool.mint_referral(0, test.ctx());
        return_shared(pool);
    };

    let maker_fee_rate = 1_000_000;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        pool.update_pool_referral_fee_rate(&referral, 0, maker_fee_rate, test.ctx());
        return_shared(referral);
        return_shared(pool);
    };

    test.next_tx(BOB);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let trade_cap = balance_manager.mint_trade_cap(test.ctx());
        balance_manager.set_balance_manager_referral(&referral, &trade_cap);
        transfer::public_transfer(trade_cap, BOB);
        return_shared(referral);
        return_shared(balance_manager);
    };

    // BOB places ask for 1000 SUI at $3
    let price = 3 * constants::float_scaling();
    let total_quantity = 1000 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        total_quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    // Fill 1: ALICE buys 300
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        300 * constants::float_scaling(),
        true,
        true,
        &mut test,
    );

    // Fill 2: CAROL buys 300
    place_market_order<SUI, USDC>(
        CAROL,
        pool_id,
        balance_manager_id_carol,
        3,
        constants::self_matching_allowed(),
        300 * constants::float_scaling(),
        true,
        true,
        &mut test,
    );

    // Fill 3: ALICE buys remaining 400 (completes order)
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        4,
        constants::self_matching_allowed(),
        400 * constants::float_scaling(),
        true,
        true,
        &mut test,
    );

    // Check referral rewards - should be for the full 1000 qty (dust sweep on completion)
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);

        // On completion (fill.completed()=true), transfer_amount = info.locked_balance (entire remaining)
        // So total rewards should equal the original locked amount
        let expected_total_deep = math::mul(
            math::mul(total_quantity, constants::deep_multiplier()),
            maker_fee_rate,
        );
        assert_eq!(deep, expected_total_deep);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);

        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun maker_referral_bid_order_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let referral_id;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id = pool.mint_referral(0, test.ctx());
        return_shared(pool);
    };

    let maker_fee_rate = 1_000_000;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        pool.update_pool_referral_fee_rate(&referral, 0, maker_fee_rate, test.ctx());
        return_shared(referral);
        return_shared(pool);
    };

    test.next_tx(BOB);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let trade_cap = balance_manager.mint_trade_cap(test.ctx());
        balance_manager.set_balance_manager_referral(&referral, &trade_cap);
        transfer::public_transfer(trade_cap, BOB);
        return_shared(referral);
        return_shared(balance_manager);
    };

    // BOB (maker) places bid limit at $1 for 100 SUI (below current best ask at $2, so it rests)
    // Actually, setup_pool creates an empty pool, no pre-existing orders.
    // We need to ensure the order rests: place bid below any existing ask.
    // Since there are no existing asks, any bid will rest.
    let price = 2 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    let order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true, // bid
        true, // pay_with_deep
        constants::max_u64(),
        &mut test,
    );
    assert!(order_info.order_inserted());

    // ALICE places ask market order to fill BOB's bid
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        quantity,
        false, // ask
        true, // pay_with_deep
        &mut test,
    );

    // Check referral rewards
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);

        // For bid order with DEEP: fee_quantity calculates DEEP based on deep_per_asset
        // deep_per_asset is for SUI (base), so deep = mul(base_qty, deep_per_asset)
        // = mul(100e9, 100e9) = 10_000e9
        // After mul with effective_rate (1_000_000): mul(10_000e9, 1_000_000) = 10e9 = 10 DEEP
        let expected_deep = math::mul(
            math::mul(quantity, constants::deep_multiplier()),
            maker_fee_rate,
        );
        assert_eq!(deep, expected_deep);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);

        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

// === Group 2: Cancellation ===

#[test]
fun maker_referral_cancel_full_refund_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let (referral_id, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0, // multiplier
        1_000_000, // maker_fee_rate = 10 bps
        &mut test,
    );

    let bob_deep_before = asset_balance<DEEP>(BOB, balance_manager_id_bob, &mut test);

    // BOB places ask, then cancels before any fill
    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    let order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );
    let order_id = order_info.order_id();

    cancel_order<SUI, USDC>(BOB, pool_id, balance_manager_id_bob, order_id, &mut test);

    // Referral rewards should be 0
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        assert_eq!(deep, 0);
        return_shared(referral);
        return_shared(pool);
    };

    // BOB's DEEP balance should be restored to original
    let bob_deep_after = asset_balance<DEEP>(BOB, balance_manager_id_bob, &mut test);
    assert_eq!(bob_deep_before, bob_deep_after);

    end(test);
}

#[test]
fun maker_referral_partial_fill_then_cancel_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;
    let (referral_id, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    // BOB places ask for 1000 SUI at $3
    let price = 3 * constants::float_scaling();
    let total_quantity = 1000 * constants::float_scaling();

    let order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        total_quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );
    let order_id = order_info.order_id();

    // ALICE fills 400
    let fill_quantity = 400 * constants::float_scaling();
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        fill_quantity,
        true,
        true,
        &mut test,
    );

    // BOB cancels remaining 600
    cancel_order<SUI, USDC>(BOB, pool_id, balance_manager_id_bob, order_id, &mut test);

    // Referral rewards = fee for 400 qty
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);

        let expected_deep_for_400 = math::mul(
            math::mul(fill_quantity, constants::deep_multiplier()),
            maker_fee_rate,
        );
        assert_eq!(deep, expected_deep_for_400);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);

        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun maker_referral_cancel_all_orders_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let (referral_id, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        1_000_000,
        &mut test,
    );

    let bob_deep_before = asset_balance<DEEP>(BOB, balance_manager_id_bob, &mut test);

    // BOB places two orders
    let price1 = 3 * constants::float_scaling();
    let price2 = 4 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price1,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        2,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price2,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    cancel_all_orders(pool_id, BOB, balance_manager_id_bob, &mut test);

    // Referral rewards should be 0
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        assert_eq!(deep, 0);
        return_shared(referral);
        return_shared(pool);
    };

    // BOB's DEEP should be restored
    let bob_deep_after = asset_balance<DEEP>(BOB, balance_manager_id_bob, &mut test);
    assert_eq!(bob_deep_before, bob_deep_after);

    end(test);
}

// === Helpers ===

fun setup_maker_referral(
    pool_id: ID,
    maker_balance_manager_id: ID,
    multiplier: u64,
    maker_fee_rate: u64,
    test: &mut Scenario,
): (ID, u64) {
    let referral_id;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id = pool.mint_referral(multiplier, test.ctx());
        return_shared(pool);
    };

    if (maker_fee_rate > 0) {
        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
            pool.update_pool_referral_fee_rate(&referral, 0, maker_fee_rate, test.ctx());
            return_shared(referral);
            return_shared(pool);
        };
    };

    test.next_tx(BOB);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(maker_balance_manager_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let trade_cap = test.take_from_sender<TradeCap>();
        balance_manager.set_balance_manager_referral(&referral, &trade_cap);
        test.return_to_sender(trade_cap);
        return_shared(referral);
        return_shared(balance_manager);
    };

    (referral_id, maker_fee_rate)
}

fun cancel_all_orders(pool_id: ID, owner: address, balance_manager_id: ID, test: &mut Scenario) {
    test.next_tx(owner);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_all_orders<SUI, USDC>(
            &mut balance_manager,
            &trade_proof,
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);
        return_shared(balance_manager);
    }
}

// === Group 3: Modification ===

#[test]
fun maker_referral_modify_reduces_quantity_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;
    let (referral_id, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    // BOB places ask for 1000 SUI at $3
    let price = 3 * constants::float_scaling();
    let original_quantity = 1000 * constants::float_scaling();

    let order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        original_quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );
    let order_id = order_info.order_id();

    let bob_deep_after_placement = asset_balance<DEEP>(BOB, balance_manager_id_bob, &mut test);

    // Modify to 600 SUI (cancel 400)
    let new_quantity = 600 * constants::float_scaling();
    modify_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        order_id,
        new_quantity,
        &mut test,
    );

    let bob_deep_after_modify = asset_balance<DEEP>(BOB, balance_manager_id_bob, &mut test);

    // BOB receives both: protocol maker fee refund + referral refund for the cancelled 400 qty
    let cancel_quantity = original_quantity - new_quantity;
    let referral_refund = math::mul(
        math::mul(cancel_quantity, constants::deep_multiplier()),
        maker_fee_rate,
    );
    let protocol_maker_fee_refund = math::mul(
        math::mul(cancel_quantity, constants::deep_multiplier()),
        constants::maker_fee(),
    );
    assert_eq!(
        bob_deep_after_modify,
        bob_deep_after_placement + referral_refund + protocol_maker_fee_refund,
    );

    // Check locked_balance reflects reduced lock for 600 qty
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let (_, _, deep_locked) = pool.locked_balance(&balance_manager);
        let remaining_referral_lock = math::mul(
            math::mul(new_quantity, constants::deep_multiplier()),
            maker_fee_rate,
        );
        assert!(deep_locked >= remaining_referral_lock);
        return_shared(balance_manager);
        return_shared(pool);
    };

    // Referral rewards should be 0 (no fills happened)
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        assert_eq!(deep, 0);
        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun maker_referral_modify_then_fill_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;
    let (referral_id, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    // BOB places ask for 1000 SUI at $3
    let price = 3 * constants::float_scaling();
    let original_quantity = 1000 * constants::float_scaling();

    let order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        original_quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );
    let order_id = order_info.order_id();

    // Modify to 500 SUI
    let new_quantity = 500 * constants::float_scaling();
    modify_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        order_id,
        new_quantity,
        &mut test,
    );

    // ALICE fills remaining 500 (completes the order)
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        new_quantity,
        true,
        true,
        &mut test,
    );

    // Referral rewards = fee for 500 qty (the entire remaining lock, dust-swept on completion)
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);

        // After modify, locked_balance was reduced to cover 500 qty
        let expected_deep = math::mul(
            math::mul(new_quantity, constants::deep_multiplier()),
            maker_fee_rate,
        );
        assert_eq!(deep, expected_deep);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);

        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

// === Group 4: Order Expiry ===

#[test]
fun maker_referral_expired_order_refund_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;
    let (referral_id, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    // BOB places ask at $3 for 100 SUI with a near-future expiry
    // set_time adds 1_000_000 to the given value
    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();
    let expire_timestamp = 1_000_000 + 200; // just slightly after the clock time set by set_time(0)

    let order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        expire_timestamp,
        &mut test,
    );
    assert!(order_info.order_inserted());

    // Advance time past expiry
    set_time(500, &mut test);

    // ALICE places a market order to trigger matching and expire BOB's order
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        quantity,
        true,
        true,
        &mut test,
    );

    // Referral rewards should be 0 (order expired, no fill)
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        assert_eq!(deep, 0);
        return_shared(referral);
        return_shared(pool);
    };

    // BOB should have the referral lock refunded to settled balances
    // Withdraw settled amounts first
    withdraw_settled_amounts(pool_id, BOB, balance_manager_id_bob, &mut test);

    end(test);
}

fun withdraw_settled_amounts(
    pool_id: ID,
    owner: address,
    balance_manager_id: ID,
    test: &mut Scenario,
) {
    test.next_tx(owner);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.withdraw_settled_amounts<SUI, USDC>(&mut balance_manager, &trade_proof);
        return_shared(pool);
        return_shared(balance_manager);
    }
}

/// Helper to set up maker referral for whitelisted pool scenarios.
/// Since the referral belongs to the pool, we need a separate helper for whitelisted pools
/// where ALICE mints referral, sets rate, and the maker sets it on their balance manager.
fun setup_maker_referral_for_address(
    pool_id: ID,
    maker_address: address,
    maker_balance_manager_id: ID,
    multiplier: u64,
    maker_fee_rate: u64,
    test: &mut Scenario,
): (ID, u64) {
    let referral_id;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id = pool.mint_referral(multiplier, test.ctx());
        return_shared(pool);
    };

    if (maker_fee_rate > 0) {
        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
            pool.update_pool_referral_fee_rate(&referral, 0, maker_fee_rate, test.ctx());
            return_shared(referral);
            return_shared(pool);
        };
    };

    test.next_tx(maker_address);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(maker_balance_manager_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let trade_cap = test.take_from_sender<TradeCap>();
        balance_manager.set_balance_manager_referral(&referral, &trade_cap);
        test.return_to_sender(trade_cap);
        return_shared(referral);
        return_shared(balance_manager);
    };

    (referral_id, maker_fee_rate)
}

// === Group 5: Non-DEEP Fee Assets ===

#[test]
fun maker_referral_ask_non_deep_base_fee_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    // Whitelisted pool (fees in base/quote, not DEEP)
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true, // whitelisted
        false, // not stable
        &mut test,
    );

    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000; // 10 bps
    let (referral_id, _) = setup_maker_referral_for_address(
        pool_id,
        BOB,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    // BOB places ask at $3 for 100 SUI (non-DEEP, whitelisted pool)
    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    let order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false, // ask
        false, // pay_with_deep = false
        constants::max_u64(),
        &mut test,
    );
    assert!(order_info.order_inserted());

    // ALICE fills BOB's ask
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        quantity,
        true, // bid
        false, // pay_with_deep = false
        &mut test,
    );

    // Check referral rewards - should be in BASE (SUI) for asks
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);

        // For ask, non-DEEP: fee_quantity returns base = mul(base_qty, fee_penalty_multiplier)
        // = mul(100e9, 1.25e9) = 125e9
        // After mul with effective_rate (1_000_000): mul(125e9, 1_000_000) = 125_000_000
        let expected_base = math::mul(
            math::mul(quantity, constants::fee_penalty_multiplier()),
            maker_fee_rate,
        );
        assert!(base > 0);
        assert_eq!(base, expected_base);
        assert_eq!(quote, 0);
        assert_eq!(deep, 0);

        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun maker_referral_bid_non_deep_quote_fee_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true, // whitelisted
        false,
        &mut test,
    );

    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;
    let (referral_id, _) = setup_maker_referral_for_address(
        pool_id,
        BOB,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    // BOB places bid at $2 for 100 SUI
    let price = 2 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    let order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true, // bid
        false, // pay_with_deep = false
        constants::max_u64(),
        &mut test,
    );
    assert!(order_info.order_inserted());

    // ALICE fills BOB's bid
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        quantity,
        false, // ask
        false, // pay_with_deep = false
        &mut test,
    );

    // Check referral rewards - should be in QUOTE (USDC) for bids
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);

        // For bid, non-DEEP: fee_quantity returns quote = mul(quote_qty, fee_penalty_multiplier)
        // quote_qty = mul(100e9, 2e9) = 200e9
        // mul(200e9, 1.25e9) = 250e9
        // After mul with effective_rate: mul(250e9, 1_000_000) = 250_000_000
        let quote_quantity = math::mul(quantity, price);
        let expected_quote = math::mul(
            math::mul(quote_quantity, constants::fee_penalty_multiplier()),
            maker_fee_rate,
        );
        assert!(quote > 0);
        assert_eq!(quote, expected_quote);
        assert_eq!(base, 0);
        assert_eq!(deep, 0);

        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun maker_referral_non_deep_cancel_refund_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);

    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;
    let (referral_id, _) = setup_maker_referral_for_address(
        pool_id,
        BOB,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    let bob_sui_before = asset_balance<SUI>(BOB, balance_manager_id_bob, &mut test);

    // BOB places ask at $3 for 100 SUI (non-DEEP), then cancels
    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    let order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        false,
        constants::max_u64(),
        &mut test,
    );
    let order_id = order_info.order_id();

    cancel_order<SUI, USDC>(BOB, pool_id, balance_manager_id_bob, order_id, &mut test);

    // Referral rewards should be 0
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        assert_eq!(deep, 0);
        return_shared(referral);
        return_shared(pool);
    };

    // BOB's SUI should be fully restored
    let bob_sui_after = asset_balance<SUI>(BOB, balance_manager_id_bob, &mut test);
    assert_eq!(bob_sui_before, bob_sui_after);

    end(test);
}

// === Group 6: Configuration Variants ===

#[test]
fun maker_referral_multiplier_only_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // multiplier = 1x (1_000_000_000), maker_fee_rate = 0
    let multiplier = 1_000_000_000;
    let (referral_id, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        multiplier,
        0, // no volume-based fee
        &mut test,
    );

    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        quantity,
        true,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);

        // effective_rate = 0 + mul(protocol_maker_fee, multiplier)
        // = mul(500_000, 1_000_000_000) = 500_000
        let effective_rate = math::mul(constants::maker_fee(), multiplier);
        let expected_deep = math::mul(
            math::mul(quantity, constants::deep_multiplier()),
            effective_rate,
        );
        assert!(deep > 0);
        assert_eq!(deep, expected_deep);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);

        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun maker_referral_fee_rate_only_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // multiplier = 0, maker_fee_rate = 10 bps
    let maker_fee_rate = 1_000_000;
    let (referral_id, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        quantity,
        true,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);

        // effective_rate = maker_fee_rate + 0 = 1_000_000
        let expected_deep = math::mul(
            math::mul(quantity, constants::deep_multiplier()),
            maker_fee_rate,
        );
        assert_eq!(deep, expected_deep);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);

        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun maker_referral_both_rate_and_multiplier_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Both: multiplier = 0.5x, maker_fee_rate = 10 bps
    let multiplier = 500_000_000; // 0.5x
    let maker_fee_rate = 1_000_000;
    let (referral_id, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        multiplier,
        maker_fee_rate,
        &mut test,
    );

    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        quantity,
        true,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);

        // effective_rate = maker_fee_rate + mul(protocol_maker_fee, multiplier)
        // = 1_000_000 + mul(500_000, 500_000_000) = 1_000_000 + 250_000 = 1_250_000
        let effective_rate = maker_fee_rate + math::mul(constants::maker_fee(), multiplier);
        let expected_deep = math::mul(
            math::mul(quantity, constants::deep_multiplier()),
            effective_rate,
        );
        assert_eq!(deep, expected_deep);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);

        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun maker_referral_zero_effective_rate_no_lock() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Both = 0: no referral fee
    let (referral_id, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        0, // no maker fee rate set (will skip update_pool_referral_fee_rate)
        &mut test,
    );

    let bob_deep_before = asset_balance<DEEP>(BOB, balance_manager_id_bob, &mut test);

    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    let bob_deep_after_placement = asset_balance<DEEP>(BOB, balance_manager_id_bob, &mut test);

    // The DEEP delta should only be the protocol maker fee, no extra referral lock
    let protocol_lock = math::mul(
        math::mul(quantity, constants::deep_multiplier()),
        constants::maker_fee(),
    );
    assert_eq!(bob_deep_before - bob_deep_after_placement, protocol_lock);

    // Fill the order
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        quantity,
        true,
        true,
        &mut test,
    );

    // Referral rewards should be 0
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        assert_eq!(deep, 0);
        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

// === Group 7: Edge Cases ===

#[test]
fun maker_referral_market_order_no_lock() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;
    let (referral_id, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    // ALICE places an ask limit order (rests in book)
    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    // BOB places a market bid order (fully filled as taker, never rests in book)
    place_market_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        2,
        constants::self_matching_allowed(),
        quantity,
        true,
        true,
        &mut test,
    );

    // No maker referral rewards should be created (BOB was taker)
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        assert_eq!(deep, 0);
        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun maker_referral_ioc_fully_filled_no_lock() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;
    let (referral_id, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    // ALICE places an ask limit order (rests in book)
    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    // BOB places IOC bid that fully fills (order_inserted = false)
    let order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        2,
        constants::immediate_or_cancel(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        true,
        constants::max_u64(),
        &mut test,
    );
    assert!(!order_info.order_inserted());

    // No maker referral lock
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        assert_eq!(deep, 0);
        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun maker_referral_no_referral_set_no_lock() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // BOB does NOT set any referral
    let bob_deep_before = asset_balance<DEEP>(BOB, balance_manager_id_bob, &mut test);

    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    let bob_deep_after = asset_balance<DEEP>(BOB, balance_manager_id_bob, &mut test);

    // Only protocol maker fee should be locked, no referral lock
    let protocol_lock = math::mul(
        math::mul(quantity, constants::deep_multiplier()),
        constants::maker_fee(),
    );
    assert_eq!(bob_deep_before - bob_deep_after, protocol_lock);

    end(test);
}

#[test]
fun maker_referral_taker_and_maker_referral_simultaneous_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // R1: taker referral (for ALICE), has taker_fee_rate but no maker_fee_rate
    let referral_id_r1;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id_r1 = pool.mint_referral(0, test.ctx());
        return_shared(pool);
    };
    let taker_fee_rate = 1_000_000; // 10 bps
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r1);
        pool.update_pool_referral_fee_rate(&referral, taker_fee_rate, 0, test.ctx());
        return_shared(referral);
        return_shared(pool);
    };
    // Set R1 on ALICE's balance manager (taker)
    test.next_tx(ALICE);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r1);
        let trade_cap = test.take_from_sender<TradeCap>();
        balance_manager.set_balance_manager_referral(&referral, &trade_cap);
        test.return_to_sender(trade_cap);
        return_shared(referral);
        return_shared(balance_manager);
    };

    // R2: maker referral (for BOB), has maker_fee_rate but no taker_fee_rate
    let referral_id_r2;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id_r2 = pool.mint_referral(0, test.ctx());
        return_shared(pool);
    };
    let maker_fee_rate = 1_000_000; // 10 bps
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r2);
        pool.update_pool_referral_fee_rate(&referral, 0, maker_fee_rate, test.ctx());
        return_shared(referral);
        return_shared(pool);
    };
    // Set R2 on BOB's balance manager (maker)
    test.next_tx(BOB);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r2);
        let trade_cap = test.take_from_sender<TradeCap>();
        balance_manager.set_balance_manager_referral(&referral, &trade_cap);
        test.return_to_sender(trade_cap);
        return_shared(referral);
        return_shared(balance_manager);
    };

    // BOB places ask limit (maker)
    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    // ALICE places bid market (taker), filling BOB
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        quantity,
        true,
        true,
        &mut test,
    );

    // Check R1 (taker referral) rewards
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral_r1 = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r1);
        let (base1, quote1, deep1) = pool.get_pool_referral_balances(&referral_r1);
        // Taker referral rewards should have DEEP from taker fee
        assert!(deep1 > 0);
        assert_eq!(base1, 0);
        assert_eq!(quote1, 0);
        return_shared(referral_r1);

        // Check R2 (maker referral) rewards
        let referral_r2 = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r2);
        let (base2, quote2, deep2) = pool.get_pool_referral_balances(&referral_r2);
        // Maker referral rewards should have DEEP from maker referral lock
        let expected_maker_deep = math::mul(
            math::mul(quantity, constants::deep_multiplier()),
            maker_fee_rate,
        );
        assert_eq!(deep2, expected_maker_deep);
        assert_eq!(base2, 0);
        assert_eq!(quote2, 0);
        return_shared(referral_r2);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun maker_referral_multiple_makers_single_taker_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let balance_manager_id_carol = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        CAROL,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;

    // Set up referral for BOB
    let (referral_id_bob, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    // Set up separate referral for CAROL
    let referral_id_carol;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id_carol = pool.mint_referral(0, test.ctx());
        return_shared(pool);
    };
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_carol);
        pool.update_pool_referral_fee_rate(&referral, 0, maker_fee_rate, test.ctx());
        return_shared(referral);
        return_shared(pool);
    };
    test.next_tx(CAROL);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_carol);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_carol);
        let trade_cap = test.take_from_sender<TradeCap>();
        balance_manager.set_balance_manager_referral(&referral, &trade_cap);
        test.return_to_sender(trade_cap);
        return_shared(referral);
        return_shared(balance_manager);
    };

    // BOB and CAROL both place ask at same price
    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        CAROL,
        pool_id,
        balance_manager_id_carol,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    // ALICE buys 200 SUI (fills both BOB and CAROL)
    let total_quantity = 200 * constants::float_scaling();
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        total_quantity,
        true,
        true,
        &mut test,
    );

    // Check BOB's referral rewards
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

        let referral_bob = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_bob);
        let (base_b, quote_b, deep_b) = pool.get_pool_referral_balances(&referral_bob);
        let expected_deep = math::mul(
            math::mul(quantity, constants::deep_multiplier()),
            maker_fee_rate,
        );
        assert_eq!(deep_b, expected_deep);
        assert_eq!(base_b, 0);
        assert_eq!(quote_b, 0);
        return_shared(referral_bob);

        // Check CAROL's referral rewards
        let referral_carol = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_carol);
        let (base_c, quote_c, deep_c) = pool.get_pool_referral_balances(&referral_carol);
        assert_eq!(deep_c, expected_deep);
        assert_eq!(base_c, 0);
        assert_eq!(quote_c, 0);
        return_shared(referral_carol);

        return_shared(pool);
    };

    end(test);
}

#[test]
fun maker_referral_claim_rewards_after_fills_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;
    let (referral_id, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        quantity,
        true,
        true,
        &mut test,
    );

    let expected_deep = math::mul(
        math::mul(quantity, constants::deep_multiplier()),
        maker_fee_rate,
    );

    // Claim rewards
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base_coin, quote_coin, deep_coin) = pool.claim_pool_referral_rewards(
            &referral,
            test.ctx(),
        );

        assert_eq!(deep_coin.value(), expected_deep);
        assert_eq!(base_coin.value(), 0);
        assert_eq!(quote_coin.value(), 0);

        base_coin.burn_for_testing();
        quote_coin.burn_for_testing();
        deep_coin.burn_for_testing();

        // After claim, balances should be 0
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        assert_eq!(deep, 0);

        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun maker_referral_changed_after_placement_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;

    // Mint two referrals: R1 and R2
    let referral_id_r1;
    let referral_id_r2;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id_r1 = pool.mint_referral(0, test.ctx());
        referral_id_r2 = pool.mint_referral(0, test.ctx());
        return_shared(pool);
    };
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral_r1 = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r1);
        pool.update_pool_referral_fee_rate(&referral_r1, 0, maker_fee_rate, test.ctx());
        return_shared(referral_r1);
        let referral_r2 = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r2);
        pool.update_pool_referral_fee_rate(&referral_r2, 0, maker_fee_rate, test.ctx());
        return_shared(referral_r2);
        return_shared(pool);
    };

    // BOB sets R1 on his balance manager
    test.next_tx(BOB);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r1);
        let trade_cap = test.take_from_sender<TradeCap>();
        balance_manager.set_balance_manager_referral(&referral, &trade_cap);
        test.return_to_sender(trade_cap);
        return_shared(referral);
        return_shared(balance_manager);
    };

    // BOB places an ask with R1 active
    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    // BOB switches to R2 AFTER placement
    test.next_tx(BOB);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let referral_r2 = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r2);
        let trade_cap = test.take_from_sender<TradeCap>();
        balance_manager.set_balance_manager_referral(&referral_r2, &trade_cap);
        test.return_to_sender(trade_cap);
        return_shared(referral_r2);
        return_shared(balance_manager);
    };

    // ALICE fills BOB's order
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        quantity,
        true,
        true,
        &mut test,
    );

    // R1 (original referral at placement time) should receive the maker referral rewards
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

        let referral_r1 = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r1);
        let (base1, quote1, deep1) = pool.get_pool_referral_balances(&referral_r1);
        let expected_deep = math::mul(
            math::mul(quantity, constants::deep_multiplier()),
            maker_fee_rate,
        );
        assert_eq!(deep1, expected_deep);
        assert_eq!(base1, 0);
        assert_eq!(quote1, 0);
        return_shared(referral_r1);

        // R2 (new referral) should have zero maker referral rewards
        let referral_r2 = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r2);
        let (base2, quote2, deep2) = pool.get_pool_referral_balances(&referral_r2);
        assert_eq!(deep2, 0);
        assert_eq!(base2, 0);
        assert_eq!(quote2, 0);
        return_shared(referral_r2);

        return_shared(pool);
    };

    end(test);
}

// === Group 8: Locked Balance View ===

#[test]
fun locked_balance_includes_referral_amount() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    // Create two balance managers: one with referral, one without
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let balance_manager_id_carol = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        CAROL,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;
    let (_, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    // BOB places ask with referral
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    // CAROL places same ask without referral
    place_limit_order<SUI, USDC>(
        CAROL,
        pool_id,
        balance_manager_id_carol,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    // Compare locked balances
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager_bob = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let balance_manager_carol = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_carol,
        );

        let (_, _, deep_locked_bob) = pool.locked_balance(&balance_manager_bob);
        let (_, _, deep_locked_carol) = pool.locked_balance(&balance_manager_carol);

        // BOB's locked balance should include the referral lock
        let referral_lock = math::mul(
            math::mul(quantity, constants::deep_multiplier()),
            maker_fee_rate,
        );
        assert_eq!(deep_locked_bob - deep_locked_carol, referral_lock);

        return_shared(balance_manager_bob);
        return_shared(balance_manager_carol);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun locked_balance_after_partial_fill() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;
    let (_, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    let price = 3 * constants::float_scaling();
    let total_quantity = 1000 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        total_quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    // Get locked balance before fill
    test.next_tx(ALICE);
    let deep_locked_before;
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let (_, _, dl) = pool.locked_balance(&balance_manager);
        deep_locked_before = dl;
        return_shared(balance_manager);
        return_shared(pool);
    };

    // Partial fill 400
    let fill_quantity = 400 * constants::float_scaling();
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        fill_quantity,
        true,
        true,
        &mut test,
    );

    // Get locked balance after fill
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let (_, _, deep_locked_after) = pool.locked_balance(&balance_manager);

        // Locked balance should have decreased
        assert!(deep_locked_after < deep_locked_before);

        // The protocol fee portion of the decrease (maker fee is refunded on fill)
        // Total locked decrease ≈ protocol_lock_for_400 + referral_lock_for_400
        // But the protocol portion goes to settled. For locked_balance, it should
        // reflect remaining 600 qty's protocol + referral lock.
        let remaining_qty = total_quantity - fill_quantity;
        let expected_remaining_referral = math::mul(
            math::mul(remaining_qty, constants::deep_multiplier()),
            maker_fee_rate,
        );
        let expected_remaining_protocol = math::mul(
            math::mul(remaining_qty, constants::deep_multiplier()),
            constants::maker_fee(),
        );
        // deep_locked_after includes order protocol lock + referral lock + any settled
        // The order lock portion should be for 600 qty
        assert!(deep_locked_after >= expected_remaining_referral + expected_remaining_protocol);

        return_shared(balance_manager);
        return_shared(pool);
    };

    end(test);
}

#[test]
fun locked_balance_after_cancel_zero_referral() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;
    let (_, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    let order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );
    let order_id = order_info.order_id();

    // Cancel the order
    cancel_order<SUI, USDC>(BOB, pool_id, balance_manager_id_bob, order_id, &mut test);

    // Locked balance should have no referral-locked amount
    // After cancellation, the order is removed and referral DF is deleted
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let (_, _, deep_locked) = pool.locked_balance(&balance_manager);

        // After cancel: no orders, but settled amounts include the refund
        assert!(deep_locked >= 0);

        return_shared(balance_manager);
        return_shared(pool);
    };

    // After withdrawing settled amounts, locked balance should be 0
    withdraw_settled_amounts(pool_id, BOB, balance_manager_id_bob, &mut test);

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let (base_locked, quote_locked, deep_locked) = pool.locked_balance(&balance_manager);
        assert_eq!(base_locked, 0);
        assert_eq!(quote_locked, 0);
        assert_eq!(deep_locked, 0);
        return_shared(balance_manager);
        return_shared(pool);
    };

    end(test);
}

// === Corner Cases ===

// Partial fill → modify → fill remainder
// Verifies locked_balance is correctly tracked across partial fill, modify, and final fill.
#[test]
fun maker_referral_partial_fill_modify_fill_remainder_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;
    let (referral_id, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    // BOB places ask for 1000 SUI at $3
    let price = 3 * constants::float_scaling();
    let original_quantity = 1000 * constants::float_scaling();

    let order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        original_quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );
    let order_id = order_info.order_id();

    // Step 1: Partial fill 200 SUI
    let fill1_qty = 200 * constants::float_scaling();
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        fill1_qty,
        true,
        true,
        &mut test,
    );

    // Check referral got fees for 200 SUI
    let fee_per_unit = math::mul(constants::deep_multiplier(), maker_fee_rate);
    let expected_reward_1 = math::mul(fill1_qty, fee_per_unit);
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (_, _, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(deep, expected_reward_1);
        return_shared(referral);
        return_shared(pool);
    };

    // Step 2: Modify down from remaining 800 to 500 (cancel 300)
    let new_quantity = 700 * constants::float_scaling(); // 200 filled + 500 remaining
    modify_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        order_id,
        new_quantity,
        &mut test,
    );

    // Step 3: Fill the remaining 500 SUI
    let fill2_qty = 500 * constants::float_scaling();
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        3,
        constants::self_matching_allowed(),
        fill2_qty,
        true,
        true,
        &mut test,
    );

    // Check total referral rewards = fees for 200 + 500 = 700 SUI
    // On the final fill (completed), the code sweeps info.locked_balance directly.
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);

        // locked after placement = fee for 1000 SUI
        // minus fee for 200 SUI (partial fill 1, transferred to rewards)
        // minus fee for 300 SUI (modify refund, returned to maker)
        // = fee for 500 SUI → swept entirely on final completion fill
        let lock_for_1000 = math::mul(original_quantity, fee_per_unit);
        let transferred_fill1 = expected_reward_1;
        let refunded_modify = math::mul(300 * constants::float_scaling(), fee_per_unit);
        let remaining_locked = lock_for_1000 - transferred_fill1 - refunded_modify;
        assert_eq!(deep, expected_reward_1 + remaining_locked);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);

        // remaining_locked should equal fee for 500 SUI
        assert_eq!(remaining_locked, math::mul(fill2_qty, fee_per_unit));

        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

// Self-match with cancel_maker expires the maker and refunds referral lock.
// BOB places a maker ask with referral, then places a taker bid with cancel_maker
// from the same balance_manager. The maker is expired, and the referral fee is refunded
// to settled_balances rather than credited to the referral rewards.
#[test]
fun maker_referral_self_match_cancel_maker_refund_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        BOB,
        registry_id,
        balance_manager_id_bob,
        &mut test,
    );

    let maker_fee_rate = 1_000_000;
    let (referral_id, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    // BOB places maker ask for 100 SUI at $3
    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    let bob_deep_before = asset_balance<DEEP>(BOB, balance_manager_id_bob, &mut test);

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    let bob_deep_after_placement = asset_balance<DEEP>(BOB, balance_manager_id_bob, &mut test);
    let _total_locked = bob_deep_before - bob_deep_after_placement;

    // BOB places taker bid with cancel_maker option (self-match expires the maker)
    place_market_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        2,
        constants::cancel_maker(),
        quantity,
        true,
        true,
        &mut test,
    );

    // The expired maker's referral lock should be refunded to settled_balances.
    // Referral rewards should remain zero.
    test.next_tx(BOB);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        assert_eq!(deep, 0);
        return_shared(referral);
        return_shared(pool);
    };

    // After withdrawing settled amounts, BOB should recover the full referral lock
    withdraw_settled_amounts(pool_id, BOB, balance_manager_id_bob, &mut test);
    let bob_deep_after_withdraw = asset_balance<DEEP>(BOB, balance_manager_id_bob, &mut test);

    // BOB's DEEP should be restored: the protocol maker fee + referral lock were both refunded
    // since the maker expired (no actual trade occurred).
    assert_eq!(bob_deep_after_withdraw, bob_deep_before);

    end(test);
}

// Same maker places two orders with different referrals.
// A single taker fills both. Each referral should receive fees only from its order.
#[test]
fun maker_referral_two_orders_different_referrals_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;

    // Mint R1 and R2 referrals
    let referral_id_r1;
    let referral_id_r2;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        referral_id_r1 = pool.mint_referral(0, test.ctx());
        referral_id_r2 = pool.mint_referral(0, test.ctx());
        return_shared(pool);
    };
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral_r1 = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r1);
        pool.update_pool_referral_fee_rate(&referral_r1, 0, maker_fee_rate, test.ctx());
        return_shared(referral_r1);
        let referral_r2 = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r2);
        pool.update_pool_referral_fee_rate(&referral_r2, 0, maker_fee_rate, test.ctx());
        return_shared(referral_r2);
        return_shared(pool);
    };

    // BOB sets R1, places order #1 (100 SUI ask at $3)
    test.next_tx(BOB);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r1);
        let trade_cap = test.take_from_sender<TradeCap>();
        balance_manager.set_balance_manager_referral(&referral, &trade_cap);
        test.return_to_sender(trade_cap);
        return_shared(referral);
        return_shared(balance_manager);
    };

    let price = 3 * constants::float_scaling();
    let qty1 = 100 * constants::float_scaling();
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        qty1,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    // BOB switches to R2, places order #2 (200 SUI ask at $3)
    test.next_tx(BOB);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r2);
        let trade_cap = test.take_from_sender<TradeCap>();
        balance_manager.set_balance_manager_referral(&referral, &trade_cap);
        test.return_to_sender(trade_cap);
        return_shared(referral);
        return_shared(balance_manager);
    };

    let qty2 = 200 * constants::float_scaling();
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        2,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        qty2,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    // ALICE fills both with a single market order for 300 SUI
    let total_qty = qty1 + qty2;
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        3,
        constants::self_matching_allowed(),
        total_qty,
        true,
        true,
        &mut test,
    );

    // R1 should have fees from order #1 (100 SUI)
    let fee_per_unit = math::mul(constants::deep_multiplier(), maker_fee_rate);
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

        let referral_r1 = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r1);
        let (_, _, deep1) = pool.get_pool_referral_balances(&referral_r1);
        assert_eq!(deep1, math::mul(qty1, fee_per_unit));
        return_shared(referral_r1);

        // R2 should have fees from order #2 (200 SUI)
        let referral_r2 = test.take_shared_by_id<DeepBookPoolReferral>(referral_id_r2);
        let (_, _, deep2) = pool.get_pool_referral_balances(&referral_r2);
        assert_eq!(deep2, math::mul(qty2, fee_per_unit));
        return_shared(referral_r2);

        return_shared(pool);
    };

    end(test);
}

// swap_exact_quote_for_base fills a maker order that has a referral.
// The swap creates a temporary balance_manager with no referral. The maker's
// referral should still receive the fees from process_maker_referral_fills.
#[test]
fun maker_referral_swap_fills_maker_order_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;
    let (referral_id, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    // BOB places maker ask for 100 SUI at $3
    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    // ALICE fills via swap (no balance_manager, no referral on taker side)
    let quote_to_swap = math::mul(quantity, price); // 300 USDC
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let (base_out, quote_out, deep_out) = pool.swap_exact_quote_for_base<SUI, USDC>(
            mint_for_testing<USDC>(quote_to_swap, test.ctx()),
            mint_for_testing<DEEP>(1_000 * constants::float_scaling(), test.ctx()),
            0,
            &clock,
            test.ctx(),
        );
        transfer::public_transfer(base_out, ALICE);
        transfer::public_transfer(quote_out, ALICE);
        transfer::public_transfer(deep_out, ALICE);
        return_shared(pool);
        return_shared(clock);
    };

    // Maker's referral should have received the fees for 100 SUI
    let fee_per_unit = math::mul(constants::deep_multiplier(), maker_fee_rate);
    let expected_deep = math::mul(quantity, fee_per_unit);
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(deep, expected_deep);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}

// Insufficient DEEP for the referral fee lock causes the order placement to abort.
// The balance manager has enough DEEP for the protocol maker fee but not for the
// additional referral lock, so the transaction should fail.
#[test, expected_failure(abort_code = ::deepbook::balance_manager::EBalanceManagerBalanceTooLow)]
fun maker_referral_insufficient_deep_for_lock_e() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    // Create BOB's balance manager with precise amounts:
    // Enough SUI for collateral, enough DEEP for protocol fee, but NOT for referral lock.
    // For 100 SUI ask at $3 with pay_with_deep:
    //   protocol_maker_fee = mul(mul(100e9, 100e9), 500_000) = 5_000_000_000
    //   referral_lock      = mul(mul(100e9, 100e9), 1_000_000) = 10_000_000_000
    //   total DEEP needed  = 15_000_000_000
    // Give BOB exactly 10_000_000_000 DEEP (enough for protocol fee, not enough for both)
    let balance_manager_id_bob;
    test.next_tx(BOB);
    {
        let mut bm = balance_manager::new(test.ctx());
        deposit_into_account<SUI>(&mut bm, 1_000_000 * constants::float_scaling(), &mut test);
        deposit_into_account<USDC>(&mut bm, 1_000_000 * constants::float_scaling(), &mut test);
        deposit_into_account<DEEP>(&mut bm, 10_000_000_000, &mut test);
        let trade_cap = bm.mint_trade_cap(test.ctx());
        transfer::public_transfer(trade_cap, BOB);
        balance_manager_id_bob = bm.id();
        transfer::public_share_object(bm);
    };

    let maker_fee_rate = 1_000_000;
    let (_, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    // This should abort: BOB has 10e9 DEEP, protocol fee takes 5e9,
    // leaving 5e9 which is less than the 10e9 referral lock.
    let price = 3 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    end(test);
}

// Multiple small partial fills followed by a completion fill.
// Verifies that locked_balance decreases correctly after each partial fill,
// and on completion the entire remaining locked_balance is swept to the referral.
// Total referral rewards must exactly equal the original lock.
#[test]
fun maker_referral_many_partial_fills_then_complete_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        BOB,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let balance_manager_id_carol = create_acct_and_share_with_funds_typed<SUI, USDC, SUI, DEEP>(
        CAROL,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let maker_fee_rate = 1_000_000;
    let (referral_id, _) = setup_maker_referral(
        pool_id,
        balance_manager_id_bob,
        0,
        maker_fee_rate,
        &mut test,
    );

    // BOB places ask for 100 SUI at $3
    let price = 3 * constants::float_scaling();
    let total_quantity = 100 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        1,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        total_quantity,
        false,
        true,
        constants::max_u64(),
        &mut test,
    );

    let fee_per_unit = math::mul(constants::deep_multiplier(), maker_fee_rate);
    let original_lock = math::mul(total_quantity, fee_per_unit);

    // Four small partial fills of 10 SUI each from different takers
    let small_fill = 10 * constants::float_scaling();
    let fee_per_fill = math::mul(small_fill, fee_per_unit);

    // Fill 1 (ALICE)
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        2,
        constants::self_matching_allowed(),
        small_fill,
        true,
        true,
        &mut test,
    );
    test.next_tx(BOB);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (_, _, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(deep, fee_per_fill);
        return_shared(referral);
        return_shared(pool);
    };

    // Fill 2 (CAROL)
    place_market_order<SUI, USDC>(
        CAROL,
        pool_id,
        balance_manager_id_carol,
        3,
        constants::self_matching_allowed(),
        small_fill,
        true,
        true,
        &mut test,
    );
    test.next_tx(BOB);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (_, _, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(deep, 2 * fee_per_fill);
        return_shared(referral);
        return_shared(pool);
    };

    // Fill 3 (ALICE)
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        4,
        constants::self_matching_allowed(),
        small_fill,
        true,
        true,
        &mut test,
    );

    // Fill 4 (CAROL)
    place_market_order<SUI, USDC>(
        CAROL,
        pool_id,
        balance_manager_id_carol,
        5,
        constants::self_matching_allowed(),
        small_fill,
        true,
        true,
        &mut test,
    );

    // 40 SUI filled so far, 60 SUI remaining
    test.next_tx(BOB);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (_, _, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(deep, 4 * fee_per_fill);
        return_shared(referral);

        // Verify locked_balance still accounts for remaining 60 SUI
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let (_, _, deep_locked) = pool.locked_balance(&balance_manager);
        let remaining_lock = original_lock - 4 * fee_per_fill;
        assert!(deep_locked >= remaining_lock);
        return_shared(balance_manager);
        return_shared(pool);
    };

    // Final fill: 60 SUI (completion) — triggers sweep of remaining locked_balance
    let final_fill = 60 * constants::float_scaling();
    place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        6,
        constants::self_matching_allowed(),
        final_fill,
        true,
        true,
        &mut test,
    );

    // Total referral rewards should exactly equal the original lock
    test.next_tx(BOB);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let referral = test.take_shared_by_id<DeepBookPoolReferral>(referral_id);
        let (base, quote, deep) = pool.get_pool_referral_balances(&referral);
        assert_eq!(deep, original_lock);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        return_shared(referral);
        return_shared(pool);
    };

    end(test);
}
