# NEXORA V2 Order Idempotency Hardening

Status: code committed; not runtime-tested or deployed.

## Current protections
- `nx_payment_orders.idempotency_key` has a database UNIQUE constraint in draft migration 001.
- API checks for an existing order before insertion.
- If concurrent inserts collide with the database uniqueness constraint (HTTP 409), API re-queries and returns the existing order only when user, product, amount and payment method match.
- Reuse of a key for a different operation returns HTTP 409.
- The database unique constraint, not the preflight lookup, is the final duplicate-order protection.

## Remaining limitations
- Idempotency keys are globally unique in draft schema, not scoped per user. This avoids cross-user duplicates but a key collision between users rejects the later request. Consider migration to unique(user_id, idempotency_key) after review.
- Catalog configuration is still draft and must be reviewed.
- API has not been deployed or integration-tested.
- Cancel and payment-settlement race behavior still needs database transaction/RPC implementation and tests.
- No payment is verified or fulfilled by this API.

## Test checklist
- [ ] Two simultaneous create requests with identical key and request: one DB order, both requests resolve to same order.
- [ ] Concurrent same key but differing product/method: one order only; conflicting request gets 409.
- [ ] Same key reused by another user is rejected without exposing the first user's order data.
- [ ] Client timeout after successful insertion; retry returns the existing order.
- [ ] Database unique constraint is verified in isolated project.
- [ ] Test cancel/payment race after transactional settlement implementation.

Do not deploy to production or process real payments until isolated tests and review are complete.
