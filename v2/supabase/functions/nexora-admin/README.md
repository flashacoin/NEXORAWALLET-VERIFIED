# NEXORA V2 Admin API

Function name: `nexora-admin`

## Security
- Validates Supabase access tokens using Auth `/auth/v1/user`.
- Admin authorization uses a server-side allowlist environment secret `NEXORA_ADMIN_USER_IDS`, comma-separated UUIDs.
- Does not trust client-provided email, role, or user ID.
- Read-only only. No approve/reject/adjust/payment action exists in this first milestone.

## Actions (POST JSON)
- `overview`: returns recent users, wallet rows, deposits, withdrawals.
- `users`: returns recent profiles.
- `deposits`: returns recent deposit records.
- `withdrawals`: returns recent withdrawal records.
- `settings`: returns wallet settings.
- `audit`: returns recent audit log rows.

Header: `Authorization: Bearer <Supabase Auth access token>`

## Required function secrets
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY` or `SUPABASE_PUBLISHABLE_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `NEXORA_ADMIN_USER_IDS` (comma-separated UUIDs; keep private)

## Deployment status
Committed to branch `nexora-v2`. Not deployed, not tested live. Before deployment verify migration/schema, secrets, restrict CORS to trusted website and Telegram Mini App origins, and perform security tests. Do not enable financial writes until approval workflows and audit logs are verified.
