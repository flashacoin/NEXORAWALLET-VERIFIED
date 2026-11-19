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
