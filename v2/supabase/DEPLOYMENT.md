# NEXORA Wallet V2 — Supabase deployment checklist

Project ref: `enfmybsgkhonjprlgusk`
Supabase project: NEXORA

## Function layout

- `functions/nexora-wallet/index.ts`: authenticated read-only wallet API.
- `config.toml`: project reference and JWT verification settings.
- `migrations/`: reviewed SQL migrations.

## Important safety notes

- Do not deploy wallet API until the V2 database migration has been reviewed and applied.
- Never commit service-role keys or other secret keys.
- Do not enable deposit credits, withdrawal payouts, or balance editing in this read-only API.
- Keep the production website and existing bot on their current deployment until V2 has been tested.

## Deployment steps (when approved)

Run commands from the repository root:

```bash
cd v2/supabase
supabase login
supabase link --project-ref enfmybsgkhonjprlgusk
supabase functions deploy nexora-wallet
```

Before deploying, verify the Edge Function secrets in Supabase Dashboard > Edge Functions > Secrets. The function needs the project URL, a server-side Supabase key, and a public/authentication key. Use only the Supabase dashboard to set secrets; never paste secret values into GitHub or chat.

After deployment, test with a valid signed-in user's token. Verify wallet, ledger, deposit and withdrawal reads only return records belonging to that user. Also test an expired token and a request with no token; both must be rejected.

This guide is preparation only. Deployment and database migration have not been performed.

## V2 development functions and secrets inventory

The following functions are implemented in the development branch. Their presence in GitHub does not mean they are deployed:

- `nexora-wallet` — authenticated wallet reads.
- `nexora-admin` — admin-only review and reporting, including evidence-backed withdrawal completion.
- `nexora-deposit-submit` — authenticated deposit submission.
- `nexora-deposit-verify-preview` — admin-only TRON verification; records immutable evidence and does not credit.
- `nexora-deposit-settle` — admin-only atomic settlement from previously recorded evidence.
- `nexora-withdrawal-submit` — authenticated withdrawal request and reserve.
- `nexora-telegram-link` — authenticated wallet + signed Telegram Mini App identity linking.

### Required server-side secrets

Set these only in Supabase Dashboard → Project Settings / Edge Functions → Secrets (menu wording may vary). Never put values in GitHub, the website, Telegram messages, or this document.

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY` (or `SUPABASE_PUBLISHABLE_KEY`)
- `SUPABASE_SERVICE_ROLE_KEY`
- `NEXORA_ADMIN_USER_IDS` — comma-separated Supabase Auth user UUID allowlist.
- `TRONGRID_API_KEY`
- `TRONGRID_BASE_URL` — normally `https://api.trongrid.io`.
- `NEXORA_USDT_CONTRACT` — verified official TRC20 USDT contract address for the target network.
- `NEXORA_DEPOSIT_ADDRESS` — controlled TRON deposit address.
- `NEXORA_DEPOSIT_CONFIRMATIONS` — positive integer threshold.
- `NEXORA_WITHDRAWAL_CONFIRMATIONS` — positive integer threshold.
- `TELEGRAM_BOT_TOKEN` — token for the exact Telegram bot whose Mini App is being used; keep it server-side only.

Do not set or rotate production secrets as part of development-only work. Confirm the target bot and network before configuring the Telegram token or TRON addresses.

### Migration order

Apply reviewed migrations in numeric order, only in a disposable/staging project first:

`001` through `016`, followed by `017_telegram_account_linking.sql`.

Migration `017` creates a one-to-one Telegram-to-wallet identity binding. Its RPC is service-role-only; the Edge Function first verifies Telegram's signed Mini App `initData` and the user's Supabase session. The migration has not been applied to the live Supabase project.

### Function deployment commands (staging only, after approval)

From `v2/supabase`, deploy the relevant functions only after staging migrations and secrets have been reviewed:

```bash
supabase functions deploy nexora-wallet
supabase functions deploy nexora-admin
supabase functions deploy nexora-deposit-submit
supabase functions deploy nexora-deposit-verify-preview
supabase functions deploy nexora-deposit-settle
supabase functions deploy nexora-withdrawal-submit
supabase functions deploy nexora-telegram-link
```

Do not run these commands against production as part of this build. The user-facing website and bot remain preview-only until staging verification and explicit production authorization.
