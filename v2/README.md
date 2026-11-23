# NEXORA Wallet V2 — Web Preview / Deployment

## V2 website source
The V2 wallet frontend is in this folder (index.html). It is separate from the legacy website at repository root.

## Automated GitHub Pages workflow
A deployment workflow is available at .github/workflows/deploy-nexora-v2-pages.yml. It publishes the contents of v2/ to the Pages site root when V2 files change on nexora-v2-deposit-dev, or when manually dispatched.

### One-time Pages setup
1. Open repository Settings → Pages.
2. Under Build and deployment, set Source to GitHub Actions.
3. Save the setting.
4. Open Actions → Deploy NEXORA V2 to GitHub Pages → Run workflow, and select nexora-v2-deposit-dev if manual run is offered.
5. Wait for both build and deploy jobs to succeed. The live URL is shown by the deploy job and in Settings → Pages.

## Important safety status
The V2 frontend is still a development preview. The backend functions and migrations are not yet deployed/verified in staging. Do not use it for real USDT deposits, balances, or withdrawals. Do not connect the production Telegram bot Mini App to this preview until staging validation and security checks are completed.
