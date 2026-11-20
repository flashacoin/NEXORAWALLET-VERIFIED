# NEXORA V2 — Secure Telegram Account Linking

## Status
Security specification only. The link endpoint and bot verification are not deployed.

## Linking flow
1. Require a verified Supabase session on the website.
2. Server generates a cryptographically random one-time code; do not generate it in browser code.
3. Store only a hash of the code, associated with the authenticated wallet user, created time, expiry (5 minutes), attempt count, and consumed state.
4. Website displays the code and instructions to send it to the official bot in a private chat.
5. Bot receives code in private chat only and sends it to the server verification endpoint over authenticated server-to-server transport.
6. Verification atomically checks hash, expiry, unused status, attempt limit, and that Telegram account is not already linked to another user. Consume code on success.
7. Save Telegram ID with unique constraint. Record audit event. Return generic errors that do not leak account existence.
8. Unlink requires authenticated session and recent reauthentication; record audit event and invalidate relevant sessions/tokens where applicable.

## Abuse prevention
- Code expires after 5 minutes.
- Maximum 5 failed attempts per code; lock/consume after limit.
- Rate limit code creation and verification per user and per Telegram ID/IP.
- Code must be unpredictable and one-time; store hash, not plaintext.
- Accept verification only from private bot chat; ignore groups/channels.
- Never trust Telegram ID or wallet user ID submitted by browser.
- Enforce unique Telegram ID and unique active link per wallet account.
- Use generic failure responses; log detailed reason privately.
- Do not use legacy predictable link codes or `/linktg` flow.

## Acceptance tests
- Expired code fails.
- Code reuse fails.
- Wrong code attempts are capped.
- Group chat verification rejected.
- Forged browser Telegram ID rejected.
- Telegram account already linked to another wallet rejected.
- Concurrent attempts cannot consume code twice or create duplicate links.
- Unlink without reauthentication denied.
- All link/unlink actions audit logged.
- API and bot outages do not falsely report linked status.
