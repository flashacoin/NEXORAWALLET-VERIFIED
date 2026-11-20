# NEXORA Wallet V2 — Staging Test Guide

**Test only in a staging Supabase project. No real funds, live wallet keys, or live payouts.**

## Before testing
- [ ] Confirm you are working with the staging Supabase project, not production.
- [ ] Apply all migrations in `v2/supabase/migrations/` in filename order.
- [ ] Deploy Edge Functions from `v2/supabase/functions/`.
- [ ] Configure function secrets. Keep service-role keys out of HTML, Telegram, and Git.
- [ ] Set `NEXORA_ADMIN_USER_IDS` to the intended admin UUID(s).
- [ ] Configure withdrawal min/max/fee secrets. If not configured, withdrawal submissions should remain disabled.
- [ ] Add the website and password-recovery redirect URLs to Supabase Auth URL configuration.
- [ ] Create two dummy user accounts (User A, User B) and one designated admin account.
- [ ] Do not use an actual USDT transaction for deposit tests.

## User checks
1. Sign in with User A. Confirm wallet page loads.
2. Submit a dummy deposit claim with a syntactically valid 64-character TX hash. Confirm it is labeled submitted/pending and **does not increase the wallet balance**.
3. Try submitting the same hash again. Confirm duplicate rejection.
4. Sign out, sign in as User B, and confirm User A's deposit submission and ledger are not visible.
5. Try malformed amount, malformed TX hash, and unsupported network; each should be rejected.
6. Try requesting a withdrawal with invalid address, unsupported network, invalid amount, and a repeated idempotency key; confirm rejection or safe duplicate behavior.
7. Test forgot-password email only after the redirect URLs have been configured. Follow the email to the reset page and change the password. Confirm sign-in with the new password.

## Admin checks
1. Sign in as the designated admin in the admin panel.
2. Confirm the overview and queue load.
3. Open the deposit queue and try Copy. Confirm the hash is copied (clipboard permission may be required).
4. Open TronScan for a sample hash. It opens an external explorer; this is only evidence review, not automatic verification.
5. Sign in as a non-admin and attempt an admin API request. Confirm it is denied.
6. Sign out and confirm the queue is no longer displayed as authenticated.

## Admin exports
- [ ] Sign in as the admin and load live deposit submissions. Export CSV and confirm the file opens in a spreadsheet with columns intact; do not treat submitted hashes as verified deposits.
- [ ] Sign in as the admin and load live withdrawals. Export CSV and confirm the fields (request ID, user, amount, fee, net payout, destination, status, and date) are present. Confirm demo data cannot be exported as live records.
- [ ] Test CSV formula injection using cells beginning with `=`, `+`, `-`, `@`, including leading whitespace/control characters before those symbols; exports should neutralize them.\n- [ ] Treat CSV files as sensitive: store them securely and do not share user identifiers or wallet destinations publicly.

## Withdrawal workflow checks
- Re-run the reject action on an already rejected test withdrawal; it must return safely without adding another refund.
- If a rejected withdrawal is missing its refund-ledger reference, the admin retry must fail for manual audit instead of silently accepting inconsistent state.
- Request a withdrawal using staging values only.
- Confirm the amount and fee reservation are reflected correctly.
- Approve a test request; approval must not broadcast or send money.
- Reject another test request and confirm the reserved amount is refunded exactly once.
- Completion should only be tested with a simulated/staging transaction hash. Never mark a real payout complete without an actual payout performed by the authorized operator.
- Re-submit actions and confirm they do not double-refund, double-reserve, or duplicate ledger entries.

## Stop and report
Stop testing and report the exact screen/error if any of these occur:
- a submitted deposit claim credits a wallet automatically;
- one user can see another user's records;
- a non-admin can access admin actions;
- a repeated request causes duplicate balance changes;
- an approval unexpectedly broadcasts funds;
- any service-role secret appears in browser code.

## Current limitations
The deposit claim queue is not a blockchain verification system. A TX hash alone is untrusted. Automated TRON deposit validation, atomic deposit-credit settlement, production payout integration, and independently validated deployment are not complete. This build is not ready for real funds.


## Transaction retry and failure regression matrix

Run these cases only against staging accounts and a staging database. Record the request ID, expected state, actual state, and ledger row IDs for each case.

| Case | Repeat/failure setup | Expected result |
|---|---|---|
| Withdrawal request retry | Submit identical details with the same idempotency key twice | Return the original withdrawal ID; reserve funds only once |
| Idempotency mismatch | Reuse a key with a different amount, fee, network, or destination | Reject; do not create another withdrawal or ledger debit |
| Insufficient balance | Request more than the available balance | Reject atomically; no withdrawal row with a successful reserve |
| Admin approval retry | Approve a request, repeat as same admin | Safe response; no duplicate ledger movement and no payout |
| Admin reject retry | Reject once, then repeat | No second refund; refund ledger reference remains present |
| Refund reference missing | Simulate rejected state without refund reference in staging | Fail closed and require manual audit |
| Completion retry | Complete with same hash after completion | Idempotent response; no duplicate payout record |
| Duplicate completion hash | Use a hash already attached to another withdrawal | Reject the duplicate hash |
| Invalid completion hash | Submit non-hex or wrong-length hash | Reject; state remains processing |
| Concurrent actions | Trigger approve/reject concurrently for one request | Only one valid state transition; no double refund or reserve |

These are manual staging scenarios in this guide, not proof that automated integration tests currently execute them. CI syntax checks and static assertions are not substitutes for database-backed concurrency tests.
