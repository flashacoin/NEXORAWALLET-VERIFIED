# NEXORA V2 Withdrawal Workflow (Implementation Plan)

## Status
Workflow specification only. No real withdrawal processing is enabled.

## Lifecycle
1. **Requested** — authenticated user submits asset, network, destination address, amount.
2. **Reserved** — server validates limits, address/network, available balance, and idempotency key. Server atomically debits/reserves amount plus fee using ledger entries.
3. **Review** — pending admin review. Admin may approve or reject; each decision must be logged.
4. **Approved** — payout worker may queue the transaction; approval alone does not send money.
5. **Processing** — payout provider/broadcaster creates transaction; store tx hash.
6. **Completed** — verify transaction success on-chain before marking complete.
7. **Rejected / Cancelled / Failed** — if funds were reserved, issue one idempotent refund entry. Refund and state transition must occur in a single database transaction.

## Security rules
- User identity comes only from verified Supabase JWT; never accept user_id from browser payload.
- Use server-side network/asset allowlists, destination-address validation, amount/fee/limits, and risk checks.
- Use a single database transaction to reserve funds and create the withdrawal record.
- Idempotency key is mandatory and bound to the user/request details.
- Admin approval/rejection requires server-side admin allowlist, re-authentication/step-up protection for sensitive actions, and immutable audit logs.
- Payout signer private keys are never stored in Supabase tables, client code, or bot command code. Use a dedicated signer/provider with restricted permissions and limits.
- The payout worker must independently confirm approval and reservation before sending.
- Mark completed only after chain/provider verification; never based on a client-supplied tx hash.
- Reject duplicate payout attempts for the same withdrawal ID.
- Use rate limits and cooldowns; apply monitoring and emergency pause.
- No user-facing action can directly modify balances.

## Admin review requirements
- Display withdrawal ID, masked user identifier, asset/network, amount, fee, destination address, created time, and risk flags.
- Admin actions: approve, reject with reason, pause queue. Each action requires a confirmation and audit log.
- Show payout transaction hash and final status after verification.

## Acceptance tests
- Insufficient balance request rejected.
- Invalid network/address rejected.
- Request replay with same key does not create duplicate reserve.
- Same key with changed parameters rejected.
- Concurrent requests cannot reserve more than balance.
- Reject refunds exactly once.
- Approved withdrawal cannot be approved twice.
- A payout cannot be sent before approval.
- Provider failure does not lose funds; reserve remains until retry or refund.
- Completion requires verified on-chain/provider result.
- Emergency pause blocks new withdrawal requests and payout execution.
