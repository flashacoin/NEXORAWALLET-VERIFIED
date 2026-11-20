-- NEXORA V2: admin withdrawal review transitions and atomic rejection refund
-- Draft migration. The Edge Function must authenticate the admin UUID allowlist before calling these RPCs.

create or replace function public.nx_admin_review_withdrawal(
  p_withdrawal_id uuid,
  p_admin_user_id uuid,
  p_action text,
  p_rejection_reason text default null
) returns public.nx_withdrawals
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_w public.nx_withdrawals%rowtype;
  v_refund_id uuid;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'not authorized'; end if;
  if p_admin_user_id is null then raise exception 'admin required'; end if;
  if p_action not in ('approve','reject') then raise exception 'invalid action'; end if;

  select * into v_w from public.nx_withdrawals
    where id=p_withdrawal_id for update;
  if not found then raise exception 'withdrawal not found'; end if;

  if p_action='approve' then
    if v_w.status not in ('requested','review') then raise exception 'withdrawal cannot be approved from current status'; end if;
    update public.nx_withdrawals set status='processing', reviewed_by=p_admin_user_id,
      reviewed_at=now(), updated_at=now() where id=p_withdrawal_id returning * into v_w;
    insert into public.nx_admin_audit_logs(admin_user_id,action,target_type,target_id,before_data,after_data)
      values(p_admin_user_id,'withdrawal_approved','withdrawal',p_withdrawal_id::text,
        jsonb_build_object('status',v_w.status),jsonb_build_object('status','processing'));
    return v_w;
  end if;

  if p_action='reject' then
    if v_w.status not in ('requested','review','approved') then raise exception 'withdrawal cannot be rejected from current status'; end if;
    if p_rejection_reason is null or length(trim(p_rejection_reason)) < 3 then raise exception 'rejection reason required'; end if;
    if v_w.ledger_debit_id is null then raise exception 'reserve ledger entry missing'; end if;
    v_refund_id := public.nx_post_ledger_entry(
      v_w.user_id,v_w.asset_code,v_w.amount+v_w.fee_amount,'withdrawal_refund',
      'withdrawal-refund:'||v_w.id::text,'withdrawal',v_w.id,
      jsonb_build_object('withdrawal_id',v_w.id,'reason',p_rejection_reason,'admin_user_id',p_admin_user_id)
    );
    update public.nx_withdrawals set status='rejected', rejection_reason=p_rejection_reason,
      reviewed_by=p_admin_user_id, reviewed_at=now(), ledger_refund_id=v_refund_id,
      updated_at=now() where id=p_withdrawal_id returning * into v_w;
    insert into public.nx_admin_audit_logs(admin_user_id,action,target_type,target_id,before_data,after_data)
      values(p_admin_user_id,'withdrawal_rejected_refunded','withdrawal',p_withdrawal_id::text,
        jsonb_build_object('status',v_w.status),jsonb_build_object('status','rejected','refund_ledger_id',v_refund_id,'reason',p_rejection_reason));
    return v_w;
  end if;
  raise exception 'unsupported action';
end;
$$;

create or replace function public.nx_admin_complete_withdrawal(
  p_withdrawal_id uuid,
  p_admin_user_id uuid,
  p_tx_hash text
) returns public.nx_withdrawals
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_w public.nx_withdrawals%rowtype;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'not authorized'; end if;
  if p_admin_user_id is null then raise exception 'admin required'; end if;
  if p_tx_hash is null or length(trim(p_tx_hash)) < 20 or length(p_tx_hash) > 160 then raise exception 'transaction hash required'; end if;

  select * into v_w from public.nx_withdrawals where id=p_withdrawal_id for update;
  if not found then raise exception 'withdrawal not found'; end if;
  if v_w.status <> 'processing' then raise exception 'withdrawal must be processing to complete'; end if;

  update public.nx_withdrawals set status='completed',tx_hash=p_tx_hash,updated_at=now()
    where id=p_withdrawal_id returning * into v_w;
  insert into public.nx_admin_audit_logs(admin_user_id,action,target_type,target_id,before_data,after_data)
    values(p_admin_user_id,'withdrawal_completed','withdrawal',p_withdrawal_id::text,
      jsonb_build_object('status','processing'),jsonb_build_object('status','completed','tx_hash',p_tx_hash));
  return v_w;
end;
$$;

revoke all on function public.nx_admin_review_withdrawal(uuid,uuid,text,text) from public, anon, authenticated;
revoke all on function public.nx_admin_complete_withdrawal(uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.nx_admin_review_withdrawal(uuid,uuid,text,text) to service_role;
grant execute on function public.nx_admin_complete_withdrawal(uuid,uuid,text) to service_role;
