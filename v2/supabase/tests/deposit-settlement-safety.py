from pathlib import Path
migration = Path("v2/supabase/migrations/016_atomic_deposit_settlement.sql").read_text().lower()
for marker in ["nx_settle_verified_deposit","coalesce(auth.role(),'') <> 'service_role'","for update",
               "p_expected_token_contract","p_expected_recipient","p_required_confirmations",
               "deposit_credit","deposit-credit:tron-trc20:","verification_evidence_id",
               "status='credited'","nx_admin_audit_logs","revoke all on function"]:
    if marker not in migration:
        raise SystemExit(f"Missing settlement safety guard: {marker}")
endpoint = Path("v2/supabase/functions/nexora-deposit-settle/index.ts").read_text()
for marker in ["NEXORA_ADMIN_USER_IDS","Authorization: authorization","Administrator access required",
               "SUPABASE_SERVICE_ROLE_KEY","NEXORA_USDT_CONTRACT","NEXORA_DEPOSIT_ADDRESS",
               "NEXORA_DEPOSIT_CONFIRMATIONS","nx_settle_verified_deposit","p_expected_token_contract",
               "p_expected_recipient","p_required_confirmations","submission_id","evidence_id"]:
    if marker.lower() not in endpoint.lower():
        raise SystemExit(f"Missing endpoint safety guard: {marker}")
for forbidden in ["p_amount:", "p_user_id:", "p_tx_hash:", "nx_post_ledger_entry"]:
    if forbidden.lower() in endpoint.lower():
        raise SystemExit(f"Endpoint must not accept/directly write financial values: {forbidden}")
print("Deposit settlement safety assertions OK")
