# NEXORA Wallet V2 — Security Readiness Audit

**Status: DEVELOPMENT / NOT READY FOR REAL FUNDS**

This checklist is an engineering gate. Items are not marked passed unless verified by an actual test or deployment check.

## Critical blockers before any real funds
- [ ] Apply migrations in a staging Supabase project and verify schema/RLS/functions.
- [ ] Confirm admin user allowlist uses UUIDs only and server-side env.
- [ ] Verify service-role keys are never exposed in website or Telegram Mini App bundles.
- [ ] Configure trusted TRON provider/API key server-side.
- [ ] Configure canonical USDT TRC20 contract for the intended network.
- [ ] Configure deposit address(es) and establish address ownership/security.
- [ ] Verify TRON transaction successful result, event log, exact token contract, recipient, amount, and required confirmations.
- [ ] Reject failed, reverted, unconfirmed, wrong-token, wrong-network, wrong-recipient, and mismatched-amount transactions.
- [ ] Make deposit credit atomic and idempotent: one chain TX can create at most one wallet credit.
- [ ] Add deposit admin review actions protected by server-side identity and audit logs.
- [ ] Validate withdrawals with secure admin review, replay-safe ledger actions, and separate payout process.
- [ ] Never automatically broadcast a payout from this test UI.
- [ ] Review ledger constraints, negative balance protection, concurrency and rollback behavior.
- [ ] Set fees, min/max, limits and asset/network settings server-side; fail closed if missing.
- [ ] Confirm secrets rotation, rate limits, monitoring, backups, recovery, and incident procedures.

## Staged test cases
1. Sign-in/sign-out, expired session and unauthorized access.
2. User A cannot read User B wallet, ledger, withdrawals, or deposit submissions.
3. Non-admin user is denied all admin API actions.
4. Malformed amount/hash/address and unsupported network are rejected.
5. Same deposit hash submitted by two accounts is rejected globally.
6. Repeated withdrawal request key does not reserve funds twice.
7. Concurrent requests cannot spend the same available balance.
8. Withdrawal rejection refunds reservation exactly once.
9. Withdrawal completion requires valid admin action and TX reference; completion is replay-safe.
10. Provider timeout, invalid API key, empty/partial provider response fail closed.
11. Deposits never credit based on a user-submitted hash alone.
12. Admin and ledger actions are logged with actor, timestamp, action, reference and outcome.

## Implemented, but not independently runtime-tested here
- User deposit submission form/API and submission history.
- Deposit queue with global unique network/hash constraint.
- Read-only admin deposit queue.
- Admin-only TRON provider evidence preview endpoint (manual review only).
- Withdrawal request and admin RPC foundations.

## Explicitly incomplete
- Automated on-chain deposit verification.
- Deposit credit RPC/atomic settlement.
- Admin approve/reject deposit workflow.
- Real payout integration.
- Runtime integration test suite and deployed staging validation.

## Safe test policy
Use staging, dummy accounts and no-money simulations. Do not send USDT, expose production wallet keys, or enable live credit/payout until critical blockers are checked and independently reviewed.
