# NEXORA Wallet V2 — Consolidated Build & Test Handoff

## Workflow change
Development is now grouped into complete build batches. The user should not need to approve each small component. Finish the planned components, integrate them, verify repository code statically, then provide one test handoff.

## Modules to finish as a coherent V2 build
- Authentication/session lifecycle and password recovery.
- User wallet display, ledger/history, withdrawal submission, and withdrawal tracking.
- Admin authentication/allowlist, overview, user/deposit/withdrawal/ledger/audit/settings views.
- Withdrawal request/review/rejection/refund/completion state transitions.
- Deposits: safely track submitted transaction references and admin verification. No automatic credit until verification is reliable and replay-protected.
- Payment orders and wallet settlement/refund idempotency.
- Telegram bot and Mini App connection to the same database, using authenticated account linking.
- Settings/limits/fees controlled by admin and validated server-side.
- UI consistency, navigation, loading/empty/error states, responsive layouts.
- Documentation, environment-variable inventory, migration order, and test checklist.

## Safety rules
- Never touch the legacy production branch or wallet.
- Do not expose service-role credentials.
- Do not accept client-provided user IDs, fees, admin roles, balance values, or verification claims.
- Never credit a deposit from a submitted transaction hash alone.
- Keep blockchain payout and real-money deposit processing disabled until provider/on-chain verification and staging tests are completed.
- Fail closed if financial settings are missing or invalid.
- Test idempotency, duplicate requests, concurrent balance changes, authorization, and refunds.

## Static validation / test readiness
Before test handoff, verify every new/modified function and UI file; confirm endpoint names, migration RPC names/arguments, authentication, and configuration registration agree. Mark checks as verified only when actually run. GitHub commits alone are not runtime test evidence.

## User's eventual test handoff
Give the user a single concise list of URLs/pages and exact actions to test (signup/login, wallet, deposit request, withdrawal request, admin review, rejection/refund, completion/hash, payment orders, Telegram Mini App). Clearly separate items that require Supabase migration/deployment, provider configuration, or testnet funds. Include expected outcomes and any failures still outstanding.
