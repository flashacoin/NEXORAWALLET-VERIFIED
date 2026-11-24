-- NEXORA V2: explicitly manual payout confirmation. No blockchain provider is called.
alter table public.nx_withdrawals
  add column if not exists payout_proof_path text;

create or replace function public.nx_admin_complete_withdrawal(
  p_withdrawal_id uuid,
  p_admin_user_id uuid,
  p_tx_hash text,
  p_payout_proof_path text default null
) returns public.nx_withdrawals
language plpgsql security definer set search_path=''
as $$
declare
  v_w public.nx_withdrawals%rowtype;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'not authorized'; end if;
  if p_admin_user_id is null then raise exception 'admin required'; end if;
  if p_tx_hash is null or length(trim(p_tx_hash)) < 6 or length(trim(p_tx_hash)) > 200 then
    raise exception 'a valid manually recorded transaction reference is required';
  end if;
  if p_payout_proof_path is not null and
     (length(p_payout_proof_path) > 500 or p_payout_proof_path !~ '^withdrawal-proofs/[A-Za-z0-9_./-]+$') then
    raise exception 'invalid private payout proof path';
  end if;
  select * into v_w from public.nx_withdrawals where id=p_withdrawal_id for update;
  if not found then raise exception 'withdrawal not found'; end if;
  if v_w.status='completed' and v_w.tx_hash=trim(p_tx_hash)
     and v_w.payout_proof_path is not distinct from p_payout_proof_path then
    return v_w;
  end if;
  if v_w.status <> 'processing' then raise exception 'withdrawal must be approved and processing before manual completion'; end if;
  if exists(select 1 from public.nx_withdrawals where tx_hash=trim(p_tx_hash) and id<>p_withdrawal_id) then
    raise exception 'transaction reference already used';
  end if;
  update public.nx_withdrawals
    set status='completed',tx_hash=trim(p_tx_hash),payout_proof_path=p_payout_proof_path,updated_at=now()
    where id=p_withdrawal_id returning * into v_w;
  insert into public.nx_admin_audit_logs(admin_user_id,action,target_type,target_id,before_data,after_data)
  values(p_admin_user_id,'withdrawal_manually_completed','withdrawal',p_withdrawal_id::text,
    jsonb_build_object('status','processing'),
    jsonb_build_object('status','completed','tx_reference',trim(p_tx_hash),
      'payout_proof_path',p_payout_proof_path,'payout_amount',v_w.amount,
      'fee_charged_on_top',v_w.fee_amount,'manual_confirmation',true));
  return v_w;
end;
$$;
revoke all on function public.nx_admin_complete_withdrawal(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.nx_admin_complete_withdrawal(uuid,uuid,text,text) to service_role;
