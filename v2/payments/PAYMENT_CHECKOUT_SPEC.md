# NEXORA V2 — Payment Checkout and Telegram Stars

## Status
Design specification. Payment creation, verification, and fulfillment are not enabled yet.

## Supported methods
- USDT TRC20: payment only counts after independent chain verification.
- Telegram Stars (XTR): only count successful Telegram payment updates; never trust a client-side success message.
- Wallet balance: server-authorized atomic debit with ledger and idempotency.

## Checkout sequence
1. Server creates order with unique idempotency key, fixed product code, price/currency, and expiry.
2. Client displays server-provided amount and supported method; product price cannot be changed client-side.
3. USDT order: server assigns destination and verifies contract, amount, destination, chain finality, and transaction/event ID.
4. Stars order: bot sends invoice; backend handles successful payment update and validates payload/order, currency, amount, and charge identifiers.
5. Wallet order: backend atomically debits using ledger posting and checks balance.
6. Mark order paid only after verified payment. Fulfill once; fulfillment idempotency key is order ID.
7. Refunds require backend authorization, ledger entry where relevant, provider-specific refund confirmation, and audit log.

## Security controls
- Payment order IDs and payloads are unpredictable; never use client-provided price or user ID as proof of payment.
- Unique provider charge IDs and unique idempotency keys prevent replay.
- Verify webhook/provider updates and handle retries safely.
- Keep provider secrets server-side.
- Expire unpaid orders; late payment enters review, not automatic fulfillment.
- Log order state changes and administrator actions.
- Do not enable fulfillment until payment verification is tested in sandbox.

## Acceptance tests
- Invalid payload cannot mark order paid.
- Wrong amount/currency/product never fulfills.
- Repeated callback only fulfills once.
- Duplicate provider charge rejected.
- Expired order is not automatically fulfilled.
- USDT transfer with wrong token contract/network/destination never paid.
- Stars invoice is validated against server order and successful-payment event.
- Wallet payment fails on insufficient balance; no partial debit.
- Failed payment does not fulfill; retry follows explicit order rules.
- Refunds are idempotent and auditable.
