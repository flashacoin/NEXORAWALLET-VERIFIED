# NEXORA V2 — TRON USDT Deposit Verification and Settlement Design

**Status: design only. No automatic deposit crediting is implemented by this document.**
**Scope: TRON mainnet, USDT TRC-20, server-side verification, exactly-once wallet credit.**
**Do not apply this design to production funds until independently reviewed and staging-tested.**

## 1. Trust boundaries

- The browser and Telegram Mini App are untrusted. A submitted transaction hash, amount, recipient, token symbol, screenshot, or client-side "verified" flag is only a claim.
- The authenticated user may submit a hash for review, but cannot choose the user ID, verified amount, token contract, recipient, block, event index, or confirmation count used for settlement.
- Only a server-side verifier may create a trusted verification record. The database settlement function must accept a reference to that record, never raw client-supplied blockchain fields.
- Admin UI is for review and visibility. It must not be able to turn a submitted hash into a credit merely by changing a status.
- Provider responses are external input. Validate response shape, HTTP status, transaction identity, event identity, and all required fields; fail closed on missing, inconsistent, stale, or malformed data.

## 2. Required server configuration

Use secret server-side configuration only:

- TRON mainnet provider base URL, pinned to the intended network.
- Provider API key (never expose it to HTML, Telegram, logs, or user-visible errors).
- Official USDT TRC-20 contract address, checked against Tether's current official documentation before deployment.
- The wallet's configured deposit recipient address(es), validated as TRON addresses.
- A confirmation/finality policy approved by the operator after reviewing current TRON network/provider semantics.
- A maximum provider response size and bounded request timeout/retry policy.

Do not guess or hardcode a deposit address, token contract, or confirmation threshold. Do not accept these values from the request body.

## 3. Verification algorithm (server only)

For each submitted 64-hex transaction ID:

1. Normalize the transaction ID to lowercase and validate its exact format.
2. Fetch the transaction and receipt/event data from the configured mainnet provider. Check the provider's documented semantics and current API version before relying on any field.
3. Require the returned transaction ID to equal the requested ID.
4. Require successful on-chain execution; a broadcast/accepted transaction, pending transaction, failed receipt, or missing receipt is not a deposit.
5. Select only a TRC-20 Transfer event emitted by the configured official USDT contract. Do not trust the event's token name or symbol.
6. Decode the Transfer event using the canonical event signature and ABI rules. Validate the event's contract address, indexed sender/recipient topics, and data length.
7. Require the decoded recipient to match one of the server-configured deposit addresses exactly after canonical address decoding. Never compare untrusted display strings.
8. Decode the token amount as an integer base-unit value. USDT uses its verified contract decimals; convert to a fixed-precision decimal string using integer arithmetic only. Never use floating-point arithmetic.
9. Require the event to be in a confirmed, canonical block according to the configured policy. Obtain block/transaction confirmation data from the provider's documented source; fail closed if unavailable or inconsistent.
10. Identify the event by the tuple (network, transaction ID, event/log index). A transaction may contain multiple token transfers; do not assume the first event is the user's payment.
11. Match the event to a pending user submission using trusted server-side data. Compare exact amount and expected deposit address; mismatches go to manual review, not credit.
12. Persist an immutable evidence record containing the network, tx ID, event index, block number/hash, contract, recipient, integer base units, normalized amount, provider/source identifiers, verification time, and verifier version. Store a response hash or bounded redacted evidence, not secrets.
13. Re-check finality immediately before settlement if the provider's model requires it. Any reorg, provider disagreement, or evidence inconsistency blocks settlement.

A transaction hash alone is never proof. A matching event from the wrong contract, wrong recipient, failed transaction, wrong amount, unconfirmed block, or duplicate event must never credit a wallet.

## 4. Atomic exactly-once settlement

Implement settlement only after the verifier and evidence schema have been reviewed.

The database transaction should:

1. Be executable only by the trusted service role / narrowly scoped server function.
2. Lock the pending submission and its trusted verification evidence row.
3. Require the evidence status to be verified and the evidence fields to match the submission and configured asset/network.
4. Enforce a database uniqueness constraint on (network_code, tx_hash, event_index), independent of user ID.
5. Enforce a unique ledger idempotency key derived from the normalized network, transaction ID, and event index.
6. Insert one immutable deposit record and one positive ledger entry, then update the wallet balance and mark the submission credited in the same database transaction.
7. Return the original settlement result for an exact retry. Reject reuse of the idempotency key with any different user, wallet, asset, amount, or reference.
8. Prevent concurrent settlement attempts from producing more than one ledger entry or balance increment.
9. Write an audit record with the verifier/evidence reference and settlement outcome.
10. Never accept amount, user ID, recipient, contract, confirmations, or "verified" status from the caller as authoritative settlement arguments.

No partial outcome is acceptable: if any insert, ledger write, balance update, or status transition fails, the entire database transaction must roll back.

## 5. Required automated tests before enabling credit

Use deterministic mocked provider fixtures and a disposable PostgreSQL database. Tests must cover:

- Valid confirmed USDT Transfer to the configured recipient.
- Wrong token contract and fake token symbol.
- Wrong recipient and malformed recipient topic.
- Failed transaction receipt.
- Pending/unconfirmed transaction and confirmation count below policy.
- Missing transaction, missing event, malformed provider payload, provider timeout, HTTP error, and rate limiting.
- Wrong amount, decimal/precision boundary, zero amount, and integer overflow/oversized values.
- Wrong network/provider endpoint and mismatched transaction ID.
- Multiple Transfer events in one transaction; select only the matching event index.
- Same transaction/event submitted by two users.
- Duplicate transaction/event submitted twice.
- Exact settlement retry returns the same result without a second credit.
- Reuse of an idempotency key with changed amount/user/asset is rejected.
- Two concurrent settlement calls produce exactly one ledger row and one balance increment.
- Evidence mutation or attempt to settle an unverified/rejected record is rejected.
- Reorg or provider disagreement before settlement blocks credit.

Tests must assert both final wallet balance and ledger row count/type/reference. A passing static check is not a substitute for these database-backed tests.

## 6. Operational controls

- Keep the current deposit preview explicitly read-only until all acceptance tests pass.
- Separate "submitted", "needs review", "verified evidence", "credited", and "rejected" states. Only the atomic settlement function may transition to credited.
- Make manual review an explicit hold, not an alternate path that silently posts a ledger entry.
- Add rate limits, bounded retries, structured redacted logs, alerting, and a reconciliation report for verified-but-not-settled records.
- Keep a daily reconciliation between provider events, evidence rows, deposit records, ledger entries, and wallet balances.
- Document incident handling for provider outage, chain reorganization, duplicate events, and erroneous credits.
- Deploy to a separate staging Supabase project first. Do not apply unreviewed migrations to the existing/live project.
- Do not test with real funds or broadcast transactions during development.

## 7. Current implementation boundary

The existing `nexora-deposit-verify-preview` function fetches transaction/event evidence for an administrator and always reports `manual_review_required`. It does not establish finality, validate the full Transfer event, or write to the ledger. The admin deposit-submission queue is read-only. This boundary must remain in place until the verification engine, immutable evidence storage, atomic settlement RPC, concurrency tests, and independent security review are complete.
