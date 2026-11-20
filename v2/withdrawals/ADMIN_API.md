# NEXORA V2 Withdrawal Admin API

**Draft implementation — not deployed or runtime-tested.**

Function: `nexora-withdrawal-admin`
Gateway JWT verification: enabled in `config.toml`
Admin identity: authenticated Supabase user UUID must appear in `NEXORA_ADMIN_USER_IDS` environment variable (comma-separated list).

Endpoint: `POST /functions/v1/nexora-withdrawal-admin`
Authorization: `Bearer <user access token>`

## Operations

### List
Request:
```json
{"action":"list","status":"requested"}
```
Status filter optional. Allowed: requested, review, processing, completed, rejected, cancelled, failed. Returns up to 200 most recent rows.

### Approve
Request:
```json
{"action":"review","withdrawal_id":"<uuid>","review_action":"approve"}
```
Transitions requested/review to processing. This is the point at which admin should manually perform the payout, after confirming all details.

### Reject
Request:
```json
{"action":"review","withdrawal_id":"<uuid>","review_action":"reject","reason":"<reason>" }
```
Reason is required by database RPC. Rejection refunds amount + fee via idempotent ledger entry in the same transaction as status update.

### Complete
Request:
```json
{"action":"complete","withdrawal_id":"<uuid>","tx_hash":"<blockchain transaction hash>" }
```
Only processing withdrawals can be marked completed.

## Required test checklist

- Unauthenticated request returns 401.
- Non-admin UUID returns 403.
- List without status and with each valid status filter works.
- Invalid status rejected with 400.
- Approve requested withdrawal once; it becomes processing. Re-approve fails.
- Reject requested withdrawal with a reason; wallet balance is restored exactly once and row becomes rejected.
- Reject without reason fails.
- Reject processing withdrawal fails.
- Complete a processing withdrawal with TX hash; becomes completed.
- Complete completed/rejected/requested withdrawal fails.
- Malformed IDs and hashes are rejected.
- API unavailable before migrations returns a safe 503, without leaking database internals.
- Confirm each mutation creates an audit log record.
- Confirm admin UUID is server allowlisted and never sourced from request body.

## Deployment blockers

- Apply and test migrations 001–006 in a disposable test Supabase project.
- Resolve duplicate-request concurrency handling in migration 005.
- Review and validate TRON address checksum.
- Implement withdrawal request user-facing Edge Function and UI.
- Validate status transitions and audit before connecting live funds.
- Manual payout is assumed; this endpoint does not send crypto.
