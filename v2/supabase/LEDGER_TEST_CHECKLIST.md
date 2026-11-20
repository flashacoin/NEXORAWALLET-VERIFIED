# NEXORA V2 Ledger — Verification Checklist

This checklist is for a disposable Supabase project after migration 001 is applied. Do not run financial tests against production wallets.

## Preconditions
- [ ] Use an isolated test Supabase project and test user.
- [ ] Apply migration 001 only in that disposable project.
- [ ] Confirm a test USDT wallet exists with a known starting balance.
- [ ] Keep the service-role key server-side; never put it in browser code.
- [ ] Do not test against a wallet holding real funds.

## Ledger behavior
- [ ] Positive deposit credit increases wallet balance and inserts one ledger row.
- [ ] Negative withdrawal debit reduces balance and inserts one row.
- [ ] Negative payment debit reduces balance and inserts one row.
- [ ] Positive withdrawal/payment refund increases balance and inserts one row.
- [ ] Zero amount is rejected.
- [ ] More than 10 decimal places is rejected.
- [ ] Negative credit is rejected.
- [ ] Positive debit is rejected.
- [ ] Insufficient balance is rejected and leaves ledger/balance unchanged.
- [ ] Repeating the exact idempotency key and same operation returns the original ledger ID and does not change balance twice.
- [ ] Reusing the idempotency key with a different user, wallet, asset, amount, type, or reference is rejected.
- [ ] Missing/short/oversized idempotency key is rejected.
- [ ] A non-service-role request cannot execute the ledger posting function.
- [ ] Direct client insert/update/delete against financial tables is denied by grants/RLS.
- [ ] Two concurrent debit attempts cannot take the balance below zero.
- [ ] Admin adjustments require a reference type and produce an audit record in the calling admin workflow.

## Deployment gate
Do not enable deposits, withdrawals, transfers, or payment fulfillment until all checks above pass and the blockchain/payment provider verification path has been reviewed.
