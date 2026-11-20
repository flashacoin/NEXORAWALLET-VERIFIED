# NEXORA V2 Payment Order Engine Test Checklist

Status: test plan committed; implementation and execution pending. Run only in an isolated Supabase project or test environment.

## Order creation and lifecycle
- [ ] Authenticated user can create an order; unauthenticated request is rejected.
- [ ] Server chooses the price, currency, provider, service snapshot and expiry; client-supplied overrides are ignored/rejected.
- [ ] Order ID is unique and idempotency key reuse for a different order is rejected.
- [ ] Allowed transitions only; arbitrary status updates from clients are rejected.
- [ ] Expiry uses server time and expires unpaid orders.

## Payment verification
- [ ] Valid payment for correct order, amount, asset and method marks paid once.
- [ ] Invalid signature/provider proof or unverified transaction cannot settle.
- [ ] Wrong asset, network, destination, amount or mismatched order is rejected or placed into review.
- [ ] Underpayment, overpayment and payment after expiry are held for reconciliation, not auto-fulfilled.
- [ ] Duplicate provider event ID cannot create a second settlement.
- [ ] Same payment evidence cannot be applied to two orders.
- [ ] Concurrent duplicate callbacks produce exactly one settlement and one fulfillment job.
- [ ] Telegram Stars successful-payment update verifies expected currency, payload/order mapping and total amount; pre-checkout alone never fulfills.
- [ ] TRC20 watcher verifies token contract, destination, amount, tx/event identity and configured confirmations.

## Fulfillment reliability
- [ ] Fulfillment starts only after paid state and verified payment evidence.
- [ ] Exactly one durable job is created for an order.
- [ ] Retry after service timeout uses the same fulfillment key and cannot deliver twice.
- [ ] Crash after paid transition but before job execution leaves a recoverable queued job.
- [ ] Failed fulfillment is observable and retried or escalated without changing payment status to unpaid.

## Admin and security
- [ ] User cannot read another user's order/payment records.
- [ ] User cannot write order status, payment event, or fulfillment job directly.
- [ ] Admin override requires authorized admin, reason, and audit event.
- [ ] Admin double-click/concurrent approval has one safe result.
- [ ] Pause prevents new order/fulfillment processing but preserves payment evidence.
- [ ] Secrets and full provider payloads are not exposed to users or logs.

## Refunds and reconciliation
- [ ] Refund request and provider refund proof are separate from original payment evidence.
- [ ] Duplicate refund notification cannot refund twice.
- [ ] Partial refund is supported only if explicitly configured and reconciled.
- [ ] Order/payment history remains immutable and auditable.

## Pass criteria
Every test has a reproducible input and expected outcome. No test is marked passed until run against the implementation in an isolated environment. Do not enable production payments based only on this checklist.
