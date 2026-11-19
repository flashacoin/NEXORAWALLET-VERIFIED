# NEXORA Wallet V2 API (initial read-only release)

## Function
`nexora-wallet`

## Supported actions
Send a POST request with a Supabase Auth access token in the Authorization header:
`Authorization: Bearer <access_token>`

JSON body:
- `{"action":"wallet"}` — authenticated user's wallet rows
- `{"action":"history"}` — last 100 ledger entries for that user
- `{"action":"deposits"}` — last 100 deposit records for that user
- `{"action":"withdrawals"}` — last 100 withdrawal records for that user

## Security notes
- This first version is read-only.
- It validates the access token using Supabase Auth's `/auth/v1/user` endpoint.
- It derives user ID from the validated auth response; it never accepts user ID from the request body.
- It uses server-side service credentials only to read rows and explicitly filters all user-facing records by the verified user ID.
- It must not be deployed with secrets in client-side code.
- Wildcard CORS is temporary for preview and should be restricted to the production site and Telegram Mini App origins before public release.

## Required environment variables
Set these in the Supabase Edge Function secret store:
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY` or `SUPABASE_PUBLISHABLE_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`

Do not put any of these secrets into the website, Telegram bot code, GitHub, or user-visible messages.

## Deployment
This function has been committed to the development branch only. It has not been deployed, tested against the live database, or enabled for real-money operations.

## Next
Validate the database migration, deploy to a test environment, and verify authenticated read-only requests before implementing financial writes, deposit verification, withdrawal processing, or admin actions.
