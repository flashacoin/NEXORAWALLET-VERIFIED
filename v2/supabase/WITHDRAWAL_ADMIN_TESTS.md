# NEXORA V2 Withdrawal/Admin RPC Test Checklist

Status: source code is committed; **not applied or runtime-tested**. Use an isolated Supabase staging project only.

## Migration order
1. `001_wallet_ledger.sql`
2. `005_atomic_withdrawal_request.sql`
3. `006_admin_withdrawal_review.sql`
4. `007_withdrawal_admin_actions.sql` (historical no-op; superseded by 006)

Migrations 002–004 support payment/order flows and are separate.

## Actual state transitions
- Request: reserve `amount + fee` in the ledger and create status `requested`.
- Approve: `requested/review -> processing` (the existing RPC in 006 sets processing, not approved).
- Reject: `requested/review -> rejected`; atomically refund amount + fee using an idempotency key.
- Complete: `processing -> completed`; require a 64-character hex TRON transaction hash.
- Replays: approve by same admin while already processing should return the row; rejected replay returns the rejected row; completed replay with same hash returns the row. A different hash after completion must not be accepted.

## Staging test cases
1. Calls without service-role context are rejected by each RPC.
2. Unknown withdrawal ID returns an error.
3. Approve requested withdrawal; status becomes processing and audit row is written.
4. Repeat approve with same admin; safe replay returns existing processing record.
5. Reject with blank/short reason fails.
6. Reject requested withdrawal; refund equals amount + fee, ledger debit/refund IDs populated, audit row written.
7. Repeat rejection; no second refund is created and the existing rejected record is returned.
8. Missing reserve debit prevents rejection/refund.
9. Complete requested withdrawal (not processing) fails.
10. Complete processing withdrawal with malformed transaction hash fails.
11. Complete processing withdrawal with valid 64-hex hash; status becomes completed and audit row is written.
12. Repeat completion with same hash; safe replay succeeds without duplicate audit.
13. Repeat completion with different hash; fails.
14. Concurrent approve/reject on one request: verify row locking results in only one valid state transition.
15. Concurrent reject/complete: verify invalid state transition fails.
16. Inspect wallet balance, ledger entries, withdrawal status, refund reference, and audit records after each test. Confirm failures roll back.

## Admin UI/API
- `nexora-admin` authenticates the bearer token through Supabase Auth and checks the server-side `NEXORA_ADMIN_USER_IDS` allowlist.
- Actions map to migration 006 RPCs: `withdrawal_approve`, `withdrawal_reject`, `withdrawal_complete`.
- UI uses live withdrawal records only after admin sign-in. Demo controls stay disabled.
- The browser must never call ledger-write RPCs directly.

## Before any live-money release
- Review all migrations as a set and verify the actual schema.
- Deploy to staging, apply migrations, and run every test above.
- Test the Edge Function against staging, including non-admin rejection.
- Verify TRON transaction hash against the blockchain before an admin marks a payout completed; current UI only accepts a hash string and does not verify chain transaction.
- Keep real payout sending disabled until independent security review and operational controls are in place.
