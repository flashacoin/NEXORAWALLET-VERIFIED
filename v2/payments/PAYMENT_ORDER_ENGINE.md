# NEXORA V2 Payment Order Engine

Status: design committed; not deployed.

## Purpose
Create one server-authoritative order lifecycle shared by website, Telegram bot and Mini App. Payment confirmation is never accepted from a browser, client, screenshot or Telegram message.

## Order lifecycle
- `created`: server creates a unique order and stores the price, asset, method and service snapshot.
- `pending_payment`: payment instructions are issued; expiry is fixed server-side.
- `payment_detected`: provider/blockchain event is received and recorded but not yet sufficient for delivery.
- `paid`: payment has been verified against the expected order, amount, asset, network and provider event; transition is idempotent.
- `fulfillment_pending`: a durable job is queued for service delivery.
- `fulfilled`: delivery result is recorded with a unique fulfillment key.
- `expired`: order expired without valid payment.
- `failed`: verification or fulfillment failed; reason is recorded without leaking secrets.
- `refund_pending` / `refunded`: refund is separately tracked and verified.

## Order invariants
1. Server-generated order ID and immutable order snapshot (service/product, quantity, amount, currency/asset, payment method, fee and expiry).
2. Client cannot set paid/fulfilled/refund status or directly write payment records.
3. Every provider event is deduplicated using provider + event ID (or chain + tx hash + event index).
4. A verified payment may settle exactly one order; order settlement is atomic and idempotent.
5. Amount and asset/network must match. Underpayments, overpayments and late payments are quarantined for admin review; they do not automatically fulfill.
6. Fulfillment happens only after payment settlement, via a durable server-side queue; retries use a unique fulfillment key.
7. Status changes use an allowed-transition check and are recorded in an append-only audit trail.
8. Expired orders cannot fulfill automatically. Late payment requires a documented admin decision.
9. Refunds do not erase payment history and must not silently credit/debit the wallet.
10. Admin override requires allowlisted admin identity, reason, reauthentication/step-up where supported, and audit record.

## Payment method verification
### USDT TRC20
- Verify token contract, network, destination address/order allocation, amount, transaction hash and event index.
- Require configured confirmation threshold and account for chain reorgs.
- Use a unique chain event key; never trust submitted transaction hash alone.
- Provider/watcher credentials remain server-side.
- Manual reconciliation is available for ambiguous payments.

### Telegram Stars (XTR)
- Use Telegram's invoice/payment flow for digital goods/services.
- Verify Telegram's successful-payment update on the bot backend.
- Store charge identifiers and order mapping; deduplicate updates.
- Handle refunds via supported Telegram mechanisms and record refund status.
- Never fulfill from a pre-checkout callback alone.

## Shared services
Website, bot and Mini App call the same authenticated backend order API. Catalog pricing, fees, method availability, limits and order expiry are server-configured. Admin UI can inspect and manage orders but cannot bypass audit/verification rules.

## Minimum order fields
- order_id, user_id, status, item/service key, quantity
- amount_due, currency/asset, payment_method, network (nullable)
- fee snapshot, pricing snapshot, created_at, expires_at
- payment_verified_at, provider/chain reference (nullable), verification metadata (restricted)
- fulfillment key, fulfillment status, fulfilled_at (nullable)
- failure/late-payment reason (nullable)
- timestamps and version for transition/concurrency control

## Required test cases
- Valid payment settles and fulfills once.
- Duplicate webhook/event does not settle or fulfill twice.
- Wrong asset/network/address, invalid contract, amount mismatch, or unverified event cannot fulfill.
- Underpayment/overpayment and late payment are held for review.
- Expiry races payment: one safe deterministic outcome, no duplicate fulfillment.
- Concurrent settlement attempts yield one paid transition.
- Fulfillment retries do not duplicate service delivery.
- Refund state is separately auditable.
- Unauthorized client/admin status writes are denied.
- Emergency pause stops new orders and fulfillment while preserving reconciliation.

## Deployment gates
This document is not a live payment integration. Before enabling money movement, implement and test schema + backend transitions, connect verified TRON and Telegram payment sources, add monitoring/alerting, test on sandbox/testnet or isolated project, review secrets and permissions, and obtain a security review. Production/live branch remains untouched.
