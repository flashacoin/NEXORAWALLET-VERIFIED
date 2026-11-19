# NEXORA WALLET V2 — Rebuild plan

## Agreed product scope
- New user and admin interface, not a patch of the old demo UI.
- Single backend/database shared by web, Telegram bot, and Telegram Mini App.
- USDT TRC20 as the initial crypto network.
- Telegram Stars payment support for eligible Telegram digital goods/services.
- Payment-first: verified payment before activation/delivery.
- Real wallet ledger; no demo balance, no browser-local financial records.
- Admin visibility and control for operational settings, users, payment/deposit/withdrawal states, support, and audit logs.

## Development safety
- V2 work is isolated on branch `nexora-v2`.
- Existing production branch is not modified during initial rebuild.
- UI previews must not imply balances or payments are live.
- Financial operations must be server-side, idempotent, auditable, and protected with RLS/authz.
- Private signing keys must not be in client code, repo, or plaintext database.
- Before mainnet operations: security review, wallet/custody infrastructure, testnet, and applicable compliance requirements.

## UI preview files
- `v2/index.html`: user dashboard concept.
- `v2/admin.html`: admin control center concept.
