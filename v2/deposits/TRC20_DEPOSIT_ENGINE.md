# NEXORA V2 — USDT TRC20 Deposit Engine

## Status
Deposit-monitoring design and acceptance criteria only. No chain monitor is deployed and no funds are credited.

## Required flow
1. User requests/opens assigned deposit address. Address comes from trusted server-side allocator, never user input.
2. Display network warning: USDT on TRON (TRC20) only.
3. Chain watcher scans configured addresses using reliable TRON node/provider; credentials remain server-side.
4. Validate official token contract, destination, transaction success, transfer event, amount > 0, and transaction/event identifiers.
5. Wait for configurable confirmation threshold. Status detected/confirming; no credit before threshold.
6. Record event unique key: network + tx hash + event index, and provider event ID when available.
7. Credit ledger exactly once using idempotency key derived from network + tx hash + event index. Bind amount, recipient, asset, and user mapping to verified event.
8. Mark deposit credited only after ledger posting succeeds; store ledger ID and credited timestamp.
9. Reorg/invalid event: no credit. If credited transfer is later reversed, trigger controlled review/freeze; do not auto-create arbitrary negative balance.
10. Admin view shows state, confirmations, hash, amount, user, address, and reason. No manual credit without verified chain data and audit.

## Security and reliability
- Allowlist network and token contract; do not trust symbol alone.
- Do not credit based on user input, screenshots, pasted hashes, or untrusted webhook payload.
- Verify webhook signature or independently query trusted node API.
- Keep provider secrets server-side only.
- Use unique event keys/idempotency to handle duplicate callbacks.
- Validate decimals and precision; avoid float arithmetic.
- Monitor provider health, lag, stuck events, duplicates, and errors.
- Emergency pause crediting if integrity is uncertain.
- Separate watcher and credit worker from UI/API.

## Lifecycle
Statuses: detected -> confirming -> confirmed -> credited. Exception states: ignored, reorged, or review_required (review_required needs migration update).

## Acceptance tests
- Valid incoming transfer detected.
- Wrong contract/network never credited.
- Failed/reverted transfer never credited.
- Wrong destination never credited.
- Invalid/zero/out-of-precision amount rejected.
- Below threshold never credited.
- Duplicate event credits only once.
- Same transaction hash with different event index handled distinctly when supported.
- Forged provider callback cannot credit.
- Worker restart resumes safely.
- Provider outage pauses processing and alerts.
- Reorg triggers review without uncontrolled balance mutation.
- Admin action is audited and cannot bypass verification.
