# NEXORA V2 withdrawal request RPC — review checklist

Migration: `005_atomic_withdrawal_request.sql`

**Status: draft only. Not deployed and not runtime-tested. Use a disposable Supabase test project first.**

## Behavior

- Only a server-side service-role invocation is accepted.
- Supports USDT on TRON TRC20 only.
- Destination address must match a basic TRON Base58 address shape (checksum/network verification still must be added).
- Amount and fee must be positive/non-negative respectively, with at most 10 decimal places.
- The withdrawal record is inserted, the wallet is debited by amount + fee, and its ledger debit ID is saved in one transaction.
- Idempotency key is scoped per user; repeated matching requests return the existing withdrawal ID.
- Reusing the key with a different amount, fee, network, or address is rejected.
- Clients cannot insert, update, or delete withdrawal rows directly.

## Test cases

1. Valid request: creates one request and one negative ledger entry; wallet drops by amount + fee.
2. Insufficient balance (including fee): entire RPC rolls back; no request row remains and balance is unchanged.
3. Repeat same request key and same payload: returns the same ID; no second debit.
4. Repeat key with changed payload: errors; no additional debit.
5. Invalid amount (zero, negative, excessive precision): rejected.
6. Invalid fee (negative, excessive precision): rejected.
7. Unsupported network: rejected.
8. Malformed TRON address: rejected.
9. Missing/short idempotency key: rejected.
10. Client JWT (non-service-role) call: denied.
11. Concurrent duplicate requests: unique index ensures only one withdrawal record; verify losing request returns a clean idempotent response (current RPC may surface a unique-conflict error and needs race-safe retry handling).
12. Confirm ledger entry reference points to withdrawal ID and debit id is stored on the withdrawal.

## Remaining before real payouts

- Add race-safe handling for concurrent same-key requests.
- Verify TRON address checksum and network format, not regex alone.
- Add server-controlled fee, min/max, daily limits and user eligibility settings.
- Build admin approve/reject/processing/completed state transitions with audit events and double-payout prevention.
- Rejection refund must be atomic and idempotent.
- Add provider/manual payout verification, webhook or transaction hash confirmation.
- Test migration/RPC in a disposable project and review security before production.
- Do not enable real-money withdrawal UI until all checks pass.
