# NEXORA V2 Admin Withdrawal RPC Test Checklist

Status: draft; migration 007 is not applied or runtime-tested.

## RPC state rules
- Approve: only requested/review -> approved.
- Reject: only requested/review, reason length 3-500, debit reference present, atomic refund.
- Complete: only approved/processing -> completed; valid 64-character hex TRON transaction hash required.
- Each action locks the withdrawal row with FOR UPDATE and writes an audit event.

## Required test cases (Supabase staging only)
1. Non-service-role call to each RPC is rejected.
2. Missing withdrawal ID is rejected.
3. Approve pending withdrawal succeeds once; second approval fails due state.
4. Reject with blank/short reason fails without refund.
5. Reject pending request refunds amount plus fee once; repeat reject fails by state.
6. Reject request with missing reservation ledger debit fails safely.
7. Complete without approval fails.
8. Complete with invalid transaction hash fails.
9. Complete approved withdrawal succeeds and writes hash/audit entry.
10. Completion replay with same hash is idempotent at state level (returns failure unless explicitly made replay-safe); different hash is rejected.
11. Concurrent reject/approve attempts: exactly one state transition succeeds.
12. Concurrent reject/completion attempts: only allowed state path succeeds.
13. Inspect ledger balances and audit rows after every test; verify rollback on errors.

## Preconditions before enabling actions in UI
- Apply reviewed migrations to an isolated Supabase test project.
- Verify the withdrawal reservation engine is present and compatible with this migration.
- Run all test cases above.
- Implement and test admin Edge Function action handlers that check the server-side admin allowlist and call these RPCs.
- Only then connect UI buttons. This draft contains no payout provider and does not send blockchain transactions.
