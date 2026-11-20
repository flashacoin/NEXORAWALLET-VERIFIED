# NEXORA V2 Server-Side Order Processing

Status: implementation blueprint with pseudocode contracts. Not deployed. No real payments are processed.

## Trust boundaries
- All routes require Supabase Auth JWT; verify signature and issuer/audience via Supabase auth APIs.
- Derive user_id from verified JWT; never accept user identity from request JSON.
- Server owns product prices, fees, payment method availability, expiration, order state and fulfillment.
- Service-role secrets stay in server environment only.
- Client can read its own orders under RLS; clients cannot write orders/events/jobs.

## API contract
### POST /orders
Request: { product_code, quantity, payment_method, idempotency_key }
Validation: product is active; quantity bounded; method enabled; key nonempty; request rate-limited.
Server: load product/price from config, compute amount/fees, snapshot product/pricing, generate order ID, set expires_at, status pending, create payment instructions (provider-specific).
Response: { order_id, status, amount_due, currency, payment_method, expires_at, instructions }.
Do not return secrets or internal provider payload.

### GET /orders/:id
Require JWT. Only return order belonging to authenticated user; admins use separately authorized admin endpoint.

### POST /orders/:id/cancel
Only allow pending/unpaid order cancellation. Atomic status transition; cannot cancel paid/fulfillment orders.

## Atomic paid settlement (server internal only)
Input: verified evidence record and order id.
1. Validate payment evidence independently (provider signature or chain event; correct asset/network/address, amount, order, unique event).
2. Insert evidence with unique(provider, provider_event_id); duplicate is no-op.
3. Lock order row.
4. Require pending_payment and unexpired; late payment becomes reconciliation review.
5. Compare exact expected amount, asset/currency, network/method and destination.
6. Mark paid, paid_at, payment_verified_at, provider reference, amount received.
7. Insert one fulfillment job with deterministic fulfillment key; unique order_id prevents duplicates.
8. Commit transaction. Only then worker may process fulfillment.

Use transaction-level rollback on any unexpected condition. Do not perform network calls while holding DB locks.

## Allowed transitions
- created -> pending_payment
- pending_payment -> paid | expired | cancelled | review
- review -> paid | expired | cancelled (admin action with reason and audit)
- paid -> fulfillment_pending
- fulfillment_pending -> fulfilled | fulfillment_failed
- paid / fulfilled -> refund_pending (only controlled refund process)
- refund_pending -> refunded | refund_failed
Terminal states: expired, cancelled, refunded; fulfilled is terminal for ordinary fulfillment but refund can be separate.

## Worker requirements
- Claim jobs using safe queue claiming/locking and leases (short DB transaction).
- Retry transient errors with capped exponential backoff; set attempt count, last error (sanitized), next retry time.
- Unique fulfillment key/idempotent provider action; worker crash recovery.
- No fulfillment on unverified/expired payment.
- Admin pause flag checked before new work; already claimed jobs handled deterministically.

## Idempotency and concurrency
- Unique idempotency key scoped to user and operation (schema must be adjusted from global uniqueness if desired).
- If key is reused with different product/quantity/method, return conflict.
- Settlement and job insert occur in one transaction.
- Event identity unique; same event cannot settle two orders.
- Optimistic version or locked row prevents transition races.
- Retry after response loss returns existing order/result, not another order.

## Logging
Record order state changes, actor, reason, evidence ID, correlation/request ID, timestamp. Never store secrets or full sensitive webhook payload. Audit admin decisions.

## Implementation sequencing
1. Refine migration with orders status vocabulary and constraints/indexes.
2. Implement authenticated order create/read/cancel functions.
3. Implement settlement transaction (internal only).
4. Implement queue worker with idempotent fulfillment adapter.
5. Add tests for race, expiry, duplicate events, mismatch, rollback, retry.
6. Test in isolated project; review before deployment.
