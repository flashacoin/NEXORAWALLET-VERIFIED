# Wallet order settlement test checklist

Draft tests for an isolated Supabase project after migrations 001–003 are reviewed/applied. Do not test with production funds.

## Happy path
- Create pending wallet order for authenticated test user.
- Fund test wallet through a trusted test-only credit.
- Call settlement once; verify wallet decreases exactly by order amount.
- Verify one ledger entry: `payment_debit`, negative amount, reference order ID.
- Verify order is `paid`, has payment_verified_at and fulfillment key/status.
- Verify exactly one fulfillment job is queued.

## Idempotency / concurrency
- Repeat settlement request: no second debit and no duplicate fulfillment job.
- Send two simultaneous settlement requests for same order: exactly one debit.
- Retry with same order ID after success: returns paid/reused.
- Ledger idempotency key mismatch attempts must fail.

## Guardrails
- Insufficient balance: function errors and order stays pending, no ledger row/job.
- Expired order: marked expired, no debit/job.
- Cancelled/failed/refunded orders cannot settle.
- Non-wallet payment order cannot settle through this RPC.
- User ID mismatch is rejected.
- Missing order is rejected.
- Currency other than USDT is rejected.
- Direct RPC invocation by anon/authenticated role denied.
- Verify debit, paid update and fulfillment-job insert rollback together on forced failure.

## Known boundary
This RPC does not authorize callers by user JWT itself; only service_role can execute it. The Edge Function must validate the user's Supabase JWT and pass the verified user ID. It is not deployed and not yet runtime-tested.
