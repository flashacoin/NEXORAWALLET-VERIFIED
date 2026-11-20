# NEXORA V2 Order API Test Checklist

Implementation: `functions/nexora-orders/index.ts`. These checks are not executed yet.

## Authentication
- [ ] Missing Bearer token returns 401.
- [ ] Invalid/expired token returns 401.
- [ ] Request user identity comes only from verified Supabase Auth user.
- [ ] User A cannot read or cancel User B order.

## Create
- [ ] Invalid JSON and unknown action rejected.
- [ ] Invalid product code/payment method/idempotency key rejected.
- [ ] Missing server catalog setting returns service unavailable (not a permissive fallback).
- [ ] Inactive or unsupported product/method rejected.
- [ ] Client attempts to provide amount/currency/user/status ignored (server catalog is authoritative).
- [ ] USDT TRON method uses USDT and TRON-TRC20.
- [ ] Stars uses XTR.
- [ ] Created order has server-side 15-minute expiration.
- [ ] Idempotent replay with same key and same request returns existing order.
- [ ] Same key with different user/product/method/price snapshot rejected.
- [ ] Concurrent same-key create calls do not create duplicate orders (implementation race behavior needs hardening/testing).

## Read and cancel
- [ ] User can retrieve own order.
- [ ] Nonexistent/foreign order returns not found.
- [ ] Invalid UUID rejected.
- [ ] Cancel only affects own pending order.
- [ ] Paid, fulfilled, or already cancelled order cannot be cancelled.
- [ ] Concurrent cancellation/payment race has deterministic atomic behavior.

## Security and reliability review
- [ ] Service-role key never leaves server.
- [ ] Catalog table has RLS enabled and no client write policy.
- [ ] API rate limits applied before enabling publicly.
- [ ] Audit log is added for order creation/cancellation.
- [ ] Order creation and cancellation are reviewed for transaction/atomicity.
- [ ] Test against disposable Supabase project; no live deployment.
