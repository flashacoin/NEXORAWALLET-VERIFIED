-- NEXORA V2: manual deposits, user proof reference and admin-only settlement.
alter table public.nx_deposit_submissions
  add column if not exists assigned_deposit_address text,
  add column if not exists proof_path text,
  add column if not exists reviewed_by uuid references auth.users(id),
  add column if not exists reviewed_at timestamptz;

create or replace function public.nx_submit_deposit(
  p_user_id uuid,p_amount numeric,p_network_code text,p_tx_hash text,p_proof_path text
) returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_id uuid; v_address text;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'not authorized'; end if;
  if p_user_id is null or p_amount is null or p_amount <= 0 or p_amount <> round(p_amount,6) then raise exception 'invalid amount'; end if;
  if p_network_code <> 'TRON-TRC20' then raise exception 'unsupported network'; end if;
  if p_tx_hash is null or length(trim(p_tx_hash)) < 6 or length(trim(p_tx_hash)) > 200 then raise exception 'invalid transaction reference'; end if;
  if p_proof_path is null or length(p_proof_path)>500 or p_proof_path !~ ('^deposit-proofs/'||p_user_id::text||'/[A-Za-z0-9_.-]+$') then
    raise exception 'payment screenshot proof is required';
  end if;
  select address into v_address from public.nx_wallet_addresses
    where user_id=p_user_id and asset_code='USDT' and network_code=p_network_code and active=true;
  if v_address is null then raise exception 'deposit address has not been assigned; contact support'; end if;
  insert into public.nx_deposit_submissions(user_id,asset_code,network_code,amount,tx_hash,status,assigned_deposit_address,proof_path)
    values(p_user_id,'USDT',p_network_code,p_amount,trim(p_tx_hash),'submitted',v_address,p_proof_path)
    returning id into v_id;
  return v_id;
end $$;
revoke all on function public.nx_submit_deposit(uuid,numeric,text,text,text) from public,anon,authenticated;
grant execute on function public.nx_submit_deposit(uuid,numeric,text,text,text) to service_role;

create or replace function public.nx_admin_review_manual_deposit(
  p_submission_id uuid,p_admin_user_id uuid,p_action text,p_admin_note text default null
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_s public.nx_deposit_submissions%rowtype; v_d public.nx_deposits%rowtype; v_ledger_id uuid; v_deposit_id uuid;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'not authorized'; end if;
  if p_admin_user_id is null or p_action not in ('approve','reject') then raise exception 'invalid admin action'; end if;
  if p_admin_note is not null and length(p_admin_note)>500 then raise exception 'admin note too long'; end if;
  select * into v_s from public.nx_deposit_submissions where id=p_submission_id for update;
  if not found then raise exception 'deposit submission not found'; end if;
  if v_s.status='credited' and p_action='approve' then
    select * into v_d from public.nx_deposits where tx_hash=v_s.tx_hash and user_id=v_s.user_id;
    if not found or v_d.ledger_id is null then raise exception 'credited submission requires manual audit'; end if;
    return jsonb_build_object('credited',true,'duplicate_retry',true,'deposit_id',v_d.id,'ledger_id',v_d.ledger_id);
  end if;
  if v_s.status not in ('submitted','review') then raise exception 'submission is not awaiting review'; end if;
  if p_action='reject' then
    update public.nx_deposit_submissions set status='rejected',admin_note=p_admin_note,reviewed_by=p_admin_user_id,reviewed_at=now(),updated_at=now() where id=p_submission_id;
    insert into public.nx_admin_audit_logs(admin_user_id,action,target_type,target_id,before_data,after_data)
    values(p_admin_user_id,'deposit_manually_rejected','deposit_submission',p_submission_id::text,
      jsonb_build_object('status',v_s.status),jsonb_build_object('status','rejected','admin_note',p_admin_note));
    return jsonb_build_object('credited',false,'status','rejected');
  end if;
  if v_s.assigned_deposit_address is null or v_s.proof_path is null then raise exception 'assigned address and screenshot proof are required'; end if;
  insert into public.nx_deposits(user_id,asset_code,network_code,deposit_address,tx_hash,event_index,amount,confirmations,required_confirmations,status)
    values(v_s.user_id,'USDT',v_s.network_code,v_s.assigned_deposit_address,v_s.tx_hash,0,v_s.amount,0,1,'confirmed')
    returning id into v_deposit_id;
  v_ledger_id:=public.nx_post_ledger_entry(v_s.user_id,'USDT',v_s.amount,'deposit_credit',
    'manual-deposit-credit:'||v_s.id::text,'deposit',v_deposit_id,
    jsonb_build_object('submission_id',v_s.id,'manual_admin_id',p_admin_user_id,'tx_reference',v_s.tx_hash,'proof_path',v_s.proof_path));
  update public.nx_deposits set status='credited',ledger_id=v_ledger_id,credited_at=now(),updated_at=now() where id=v_deposit_id;
  update public.nx_deposit_submissions set status='credited',admin_note=p_admin_note,reviewed_by=p_admin_user_id,reviewed_at=now(),verified_at=now(),updated_at=now() where id=p_submission_id;
  insert into public.nx_admin_audit_logs(admin_user_id,action,target_type,target_id,before_data,after_data)
  values(p_admin_user_id,'deposit_manually_approved','deposit',v_deposit_id::text,
    jsonb_build_object('submission_status',v_s.status),
    jsonb_build_object('submission_id',v_s.id,'status','credited','amount',v_s.amount,'ledger_id',v_ledger_id,'manual_review',true));
  return jsonb_build_object('credited',true,'duplicate_retry',false,'deposit_id',v_deposit_id,'ledger_id',v_ledger_id);
end $$;
revoke all on function public.nx_admin_review_manual_deposit(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.nx_admin_review_manual_deposit(uuid,uuid,text,text) to service_role;
