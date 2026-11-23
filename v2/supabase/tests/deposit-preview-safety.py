from pathlib import Path

preview = Path("v2/supabase/functions/nexora-deposit-verify-preview/index.ts").read_text()
admin = Path("v2/supabase/functions/nexora-admin/index.ts").read_text().lower()
migration = Path("v2/supabase/migrations/013_deposit_verification_evidence.sql").read_text().lower()

required_preview = [
    'verification_status: "manual_review_required"',
    "normalizeSolidifiedTransferLogs",
    "validateUsdtTransfer",
    "/walletsolidity/gettransactioninfobyid",
    "/walletsolidity/getnowblock",
    "nx_record_deposit_evidence",
    "matched_evidence",
    "no deposit has been credited",
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
    "nx_deposits",
]:
    if forbidden.lower() in preview.lower():
        raise SystemExit(f"Deposit preview must not settle or credit; found: {forbidden}")

for marker in [
    "unique(network_code, tx_hash, event_index)",
    "unique(submission_id)",
    "before update or delete",
    "deposit verification evidence is immutable",
    "coalesce(auth.role(),'') <> 'service_role'",
    "grant execute on function public.nx_record_deposit_evidence",
]:
    if marker not in migration:
        raise SystemExit(f"Deposit evidence migration is missing safety guard: {marker}")

if 'action === "deposit_submissions"' not in admin:
    raise SystemExit("Admin deposit submission review action is missing")
for forbidden in ["deposit_approve", "nx_admin_settle_deposit"]:
    if forbidden in admin:
        raise SystemExit(f"Unreviewed deposit credit action found in admin API: {forbidden}")

print("Deposit evidence safety OK: exact match persistence, immutable evidence, manual review, no wallet writes")
