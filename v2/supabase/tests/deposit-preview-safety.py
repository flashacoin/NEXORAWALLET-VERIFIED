from pathlib import Path

preview = Path("v2/supabase/functions/nexora-deposit-verify-preview/index.ts").read_text().lower()
admin = Path("v2/supabase/functions/nexora-admin/index.ts").read_text().lower()

# The current endpoint is evidence-only. A submitted hash must never reach a
# balance-changing path until a separately reviewed verifier/settlement exists.
required_preview = [
    "verification_status",
    "manual_review_required",
    "no transaction confirmation threshold",
    "no ledger credit has been verified",
]
for marker in required_preview:
    if marker not in preview:
        raise SystemExit(f"Deposit preview lost its manual-review warning: {marker}")

for forbidden in [
    "nx_post_ledger_entry",
    "insert into public.nx_wallet_ledger",
    "update public.wallets",
    "nx_admin_settle_deposit",
]:
    if forbidden in preview:
        raise SystemExit(f"Deposit preview must remain read-only; found: {forbidden}")

# Admin API currently exposes only the read-only submission queue, not an
# approve/credit action based on the submitted hash.
if 'action === "deposit_submissions"' not in admin:
    raise SystemExit("Admin deposit submission review action is missing")
for forbidden in [
    "deposit_approve",
    "nx_admin_settle_deposit",
]:
    if forbidden in admin:
        raise SystemExit(f"Unreviewed deposit credit action found in admin API: {forbidden}")

print("Deposit preview safety OK: evidence-only, manual review, no balance/ledger writes")
