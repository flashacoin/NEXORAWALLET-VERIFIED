from pathlib import Path

preview = Path("v2/supabase/functions/nexora-deposit-verify-preview/index.ts").read_text()
admin = Path("v2/supabase/functions/nexora-admin/index.ts").read_text().lower()

# The preview validates solidified TRON receipt evidence but remains manual-review-only.
required_preview = [
    "verification_status: \"manual_review_required\"",
    "normalizeSolidifiedTransferLogs",
    "validateUsdtTransfer",
    "/walletsolidity/gettransactioninfobyid",
    "/walletsolidity/getnowblock",
    "does not match a pending submission",
    "does not credit a wallet",
]
for marker in required_preview:
    if marker.lower() not in preview.lower():
        raise SystemExit(f"Deposit preview is missing a verification or safety guard: {marker}")

for forbidden in [
    "nx_post_ledger_entry",
    "insert into public.nx_wallet_ledger",
    "update public.wallets",
    "nx_admin_settle_deposit",
    "nx_submit_deposit",
]:
    if forbidden.lower() in preview.lower():
        raise SystemExit(f"Deposit preview must remain read-only; found: {forbidden}")

# Admin API exposes the submission queue only, not a deposit approval/credit action.
if 'action === "deposit_submissions"' not in admin:
    raise SystemExit("Admin deposit submission review action is missing")
for forbidden in ["deposit_approve", "nx_admin_settle_deposit", "deposit_credit"]:
    if forbidden in admin:
        raise SystemExit(f"Unreviewed deposit credit action found in admin API: {forbidden}")

print("Deposit preview safety OK: solidified receipt validation, manual review, no database or wallet writes")
