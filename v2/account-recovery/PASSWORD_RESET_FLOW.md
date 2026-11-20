# NEXORA V2 — Password Recovery and Account Reset

## Status
Specification only. No recovery endpoint or bot OTP flow is deployed.

## Recovery sequence
1. User enters email on the recovery page. Return the same neutral response regardless of whether the account exists.
2. Send a Supabase Auth password-recovery email using the configured provider.
3. After email recovery verification, require Telegram verification only for accounts with a verified, linked Telegram ID and available private bot chat.
4. Generate a server-side random OTP; store only its hash, user ID, purpose, created/expiry times, attempt count and consumed state. OTP expires after 5 minutes and has at most 5 attempts.
5. Deliver OTP to the linked Telegram account in the official bot's private chat. Never accept a Telegram ID supplied by the user in the browser.
6. Verify OTP server-side with atomic consume and rate limiting. Require both email recovery proof and Telegram OTP before allowing password change when Telegram verification is enabled for the account.
7. Update password using Supabase Auth recovery flow/admin server API only after verification. Never log or store plaintext password or OTP.
8. Invalidate recovery token/OTP, audit the recovery outcome, and revoke other sessions if supported and appropriate. Notify user of successful reset through email and Telegram.

## Security and edge cases
- Use generic responses to prevent email/account enumeration.
- Rate limit by account, IP, and Telegram identity; apply cooldowns.
- Hash OTP with a server-side secret or keyed HMAC; do not store plaintext.
- No OTP in URL, analytics, logs, or admin tables readable by clients.
- Require private bot chat; never send recovery OTP to groups/channels.
- Expire OTP and email recovery links; reject replay and concurrent double-use.
- Telegram unavailable or not linked: provide a documented secure fallback support flow with identity verification; do not silently bypass the second factor.
- Admin support cannot reveal or set users' passwords. Any recovery override must be tightly restricted, separately audited, and not part of ordinary admin UI.
- Return success only after password update succeeds.

## Acceptance tests
- Unknown email response is indistinguishable from known account response.
- Invalid or expired email recovery token rejected.
- Telegram not linked cannot pass Telegram OTP step.
- Wrong/expired OTP rejected and attempt limit enforced.
- OTP replay and concurrent use rejected.
- Telegram group/channel delivery and verification rejected.
- Browser-supplied Telegram ID rejected.
- Telegram or email delivery failure does not allow reset.
- Successful password reset requires both proofs.
- Password update failure does not report success.
- User notification and audit events are generated without exposing secrets.
