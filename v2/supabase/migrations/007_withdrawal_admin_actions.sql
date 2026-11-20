-- NEXORA V2: admin withdrawal state transitions (DRAFT; review before applying)
-- Admin identity is enforced by the Edge Function allowlist; RPCs require service_role.
-- This migration assumes 001_wallet_ledger.sql and the withdrawal reservation migration are applied.

create or replace function public.nx_admin_approve_withdrawal(p_withdrawal_id uuid, p_admin_user_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_row public.nx_withdrawals%rowtype;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'not authorized'; end if;
  if p_admin_user_id is null then raise exception 'admin identity required'; end if;
  select * into v_row from public.nx_withdrawals where id=p_withdrawal_id for update;
  if not found then raise exception 'withdrawal not found'; end if;
  if v_row.status not in ('requested','review') then raise exception 'withdrawal is not awaiting review'; end if;
  update public.nx_withdrawals set status='approved', reviewed_by=p_admin_user_id,
    reviewed_at=now(), updated_at=now() where id=p_withdrawal_id;
  insert into public.nx_admin_audit_logs(admin_user_id,action,target_type,target_id,before_data,after_data)
  values(p_admin_user_id,'withdrawal_approved','withdrawal',p_withdrawal_id::text,
    jsonb_build_object('status',v_row.status),jsonb_build_object('status','approved'));
  return jsonb_build_object('id',p_withdrawal_id,'status','approved');
end; $$;

create or replace function public.nx_admin_reject_withdrawal(p_withdrawal_id uuid, p_admin_user_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_row public.nx_withdrawals%rowtype; v_refund_id uuid;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'not authorized'; end if;
  if p_admin_user_id is null then raise exception 'admin identity required'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 or length(trim(p_reason)) > 500 then raise exception 'rejection reason required (3-500 characters)'; end if;
  select * into v_row from public.nx_withdrawals where id=p_withdrawal_id for update;
  if not found then raise exception 'withdrawal not found'; end if;
  if v_row.status not in ('requested','review') then raise exception 'withdrawal is not awaiting review'; end if;
  if v_row.ledger_debit_id is null then raise exception 'reserved debit is missing; manual review required'; end if;
  v_refund_id := public.nx_post_ledger_entry(v_row.user_id,v_row.asset_code,
    v_row.amount + v_row.fee_amount,'withdrawal_refund',
    'withdrawal-refund:'||v_row.id::text,'withdrawal',v_row.id,
    jsonb_build_object('admin_user_id',p_admin_user_id,'reason',trim(p_reason)));
  update public.nx_withdrawals set status='rejected', rejection_reason=trim(p_reason,
    reviewed_by=p_admin_user_id, reviewed_at=now(), ledger_refund_id=v_refund_id, updated_at=now()
    where id=p_withdrawal_id;
  insert into public.nx_admin_audit_logs(admin_user_id,action,target_type,target_id,before_data,after_data)
  values(p_admin_user_id,'withdrawal_rejected','withdrawal',p_withdrawal_id::text,
    jsonb_build_object('status',v_row.status),jsonb_build_object('status','rejected','reason',trim(p_reason),'refund_ledger_id',v_refund_id));
  return jsonb_build_object('id',p_withdrawal_id,'status','rejected','refund_ledger_id',v_refund_id);
end; $$;

create or replace function public.nx_admin_complete_withdrawal(p_withdrawal_id uuid, p_admin_user_id uuid, p_tx_hash text)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_row public.nx_withdrawals%rowtype; v_hash text;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'not authorized'; end if;
  if p_admin_user_id is null then raise exception 'admin identity required'; end if;
  v_hash := trim(coalesce(p_tx_hash,''));
  if v_hash !~ '^[A-Fa-f0-9]{64}$' then raise exception 'invalid TRON transaction hash'; end if;
  select * into v_row from public.nx_withdrawals where id=p_withdrawal_id for update;
  if not found then raise exception 'withdrawal not found'; end if;
  if v_row.status not in ('approved','processing') then raise exception 'withdrawal must be approved before completion'; end if;
  if v_row.tx_hash is not null and v_row.tx_hash <> v_hash then raise exception 'transaction hash already recorded'; end if;
  update public.nx_withdrawals set status='completed', tx_hash=v_hash,
    reviewed_by=p_admin_user_id, reviewed_at=coalesce(reviewed_at,now()), updated_at=now()
    where id=p_withdrawal_id;
  insert into public.nx_admin_audit_logs(admin_user_id,action,target_type,target_id,before_data,after_data)
  values(p_admin_user_id,'withdrawal_completed','withdrawal',p_withdrawal_id::text,
    jsonb_build_object('status',v_row.status,'tx_hash',v_row.tx_hash),jsonb_build_object('status','completed','tx_hash',v_hash));
  return jsonb_build_object('id',p_withdrawal_id,'status','completed','tx_hash',v_hash);
end; $$;

revoke all on function public.nx_admin_approve_withdrawal(uuid,uuid) from public,anon,authenticated;
revoke all on function public.nx_admin_reject_withdrawal(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.nx_admin_complete_withdrawal(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.nx_admin_approve_withdrawal(uuid,uuid) to service_role;
grant execute on function public.nx_admin_reject_withdrawal(uuid,uuid,text) to service_role;
grant execute on function public.nx_admin_complete_withdrawal(uuid,uuid,text) to service_role;
