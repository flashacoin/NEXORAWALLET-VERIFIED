-- NEXORA V2: chain-verified manual withdrawal completion.
-- A transaction hash alone is never sufficient to complete a withdrawal.
-- The Edge Function verifies the solidified TRON receipt before recording evidence.
create table if not exists public.nx_withdrawal_verification_evidence (
  id uuid primary key default gen_random_uuid(),
  withdrawal_id uuid not null references public.nx_withdrawals(id) on delete restrict,
  network_code text not null check (network_code = 'TRON-TRC20'),
  tx_hash text not null check (tx_hash ~ '^[a-f0-9]{64}$'),
  event_index integer not null check (event_index >= 0),
  asset_code text not null check (asset_code = 'USDT'),
  token_contract_address text not null check (length(token_contract_address) between 1 and 64),
  sender_address text not null check (length(sender_address) between 1 and 64),
  recipient_address text not null check (length(recipient_address) between 1 and 64),
  amount_base_units numeric(78,0) not null check (amount_base_units > 0),
  block_number bigint not null check (block_number >= 0),
  confirmations integer not null check (confirmations >= 1),
  receipt_result text not null check (receipt_result = 'SUCCESS'),
  verifier_version text not null check (length(verifier_version) between 1 and 64),
  verified_at timestamptz not null default now(),
  constraint nx_withdrawal_evidence_event_unique unique(network_code, tx_hash, event_index),
  constraint nx_withdrawal_evidence_withdrawal_unique unique(withdrawal_id)
);
alter table public.nx_withdrawal_verification_evidence enable row level security;
revoke all on public.nx_withdrawal_verification_evidence from public, anon, authenticated, service_role;

create or replace function public.nx_prevent_withdrawal_evidence_mutation()
returns trigger language plpgsql set search_path=''
as $$ begin raise exception 'withdrawal verification evidence is immutable'; end $$;
drop trigger if exists nx_withdrawal_evidence_immutable on public.nx_withdrawal_verification_evidence;
create trigger nx_withdrawal_evidence_immutable before update or delete
on public.nx_withdrawal_verification_evidence for each row
execute function public.nx_prevent_withdrawal_evidence_mutation();

create or replace function public.nx_record_withdrawal_evidence(
  p_withdrawal_id uuid,
  p_tx_hash text,
  p_event_index integer,
  p_token_contract_address text,
  p_sender_address text,
  p_recipient_address text,
  p_amount_base_units text,
  p_block_number bigint,
  p_confirmations integer,
  p_receipt_result text,
  p_verifier_version text
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_w public.nx_withdrawals%rowtype;
  v_existing public.nx_withdrawal_verification_evidence%rowtype;
  v_amount numeric(78,0);
  v_id uuid;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'not authorized'; end if;
  if p_withdrawal_id is null or p_tx_hash is null or p_tx_hash !~* '^[a-f0-9]{64}$'
     or p_event_index is null or p_event_index < 0
     or coalesce(p_token_contract_address,'') = '' or coalesce(p_sender_address,'') = ''
     or coalesce(p_recipient_address,'') = ''
     or p_amount_base_units is null or p_amount_base_units !~ '^[1-9][0-9]*$'
     or length(p_amount_base_units) > 78 or p_block_number is null or p_block_number < 0
     or p_confirmations is null or p_confirmations < 1
     or p_receipt_result is distinct from 'SUCCESS'
     or coalesce(p_verifier_version,'') = '' or length(p_verifier_version) > 64 then
    raise exception 'invalid withdrawal evidence';
  end if;
  v_amount := p_amount_base_units::numeric;
  select * into v_w from public.nx_withdrawals where id=p_withdrawal_id for update;
  if not found then raise exception 'withdrawal not found'; end if;
  if v_w.status <> 'processing' then raise exception 'withdrawal must be processing for verification'; end if;
  if v_w.asset_code <> 'USDT' or v_w.network_code <> 'TRON-TRC20' then raise exception 'unsupported withdrawal asset or network'; end if;
  if v_w.destination_address <> p_recipient_address then raise exception 'withdrawal recipient mismatch'; end if;
  -- The on-chain payout must equal the full requested amount. The fee is charged on top.
  if v_w.amount * 1000000 <> v_amount then raise exception 'withdrawal payout amount mismatch'; end if;

  select * into v_existing from public.nx_withdrawal_verification_evidence
   where (network_code='TRON-TRC20' and tx_hash=lower(p_tx_hash) and event_index=p_event_index)
      or withdrawal_id=p_withdrawal_id limit 1;
  if found then
    if v_existing.withdrawal_id=p_withdrawal_id and v_existing.tx_hash=lower(p_tx_hash)
       and v_existing.event_index=p_event_index and v_existing.token_contract_address=p_token_contract_address
       and v_existing.sender_address=p_sender_address and v_existing.recipient_address=p_recipient_address
       and v_existing.amount_base_units=v_amount and v_existing.block_number=p_block_number
       and v_existing.receipt_result=p_receipt_result then
      return jsonb_build_object('recorded',true,'evidence_id',v_existing.id,'duplicate_retry',true);
    end if;
    return jsonb_build_object('recorded',false,'reason','duplicate_event_or_withdrawal');
  end if;

  insert into public.nx_withdrawal_verification_evidence(
    withdrawal_id,network_code,tx_hash,event_index,asset_code,token_contract_address,
    sender_address,recipient_address,amount_base_units,block_number,confirmations,receipt_result,verifier_version
  ) values (
    p_withdrawal_id,'TRON-TRC20',lower(p_tx_hash),p_event_index,'USDT',p_token_contract_address,
    p_sender_address,p_recipient_address,v_amount,p_block_number,p_confirmations,p_receipt_result,p_verifier_version
  ) returning id into v_id;
  return jsonb_build_object('recorded',true,'evidence_id',v_id,'duplicate_retry',false);
end;
$$;
revoke all on function public.nx_record_withdrawal_evidence(uuid,text,integer,text,text,text,text,bigint,integer,text,text) from public,anon,authenticated;
grant execute on function public.nx_record_withdrawal_evidence(uuid,text,integer,text,text,text,text,bigint,integer,text,text) to service_role;

create or replace function public.nx_admin_complete_withdrawal(
  p_withdrawal_id uuid,p_admin_user_id uuid,p_tx_hash text
) returns public.nx_withdrawals
language plpgsql security definer set search_path=''
as $$
declare
  v_w public.nx_withdrawals%rowtype;
  v_e public.nx_withdrawal_verification_evidence%rowtype;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'not authorized'; end if;
  if p_admin_user_id is null then raise exception 'admin required'; end if;
  if p_tx_hash is null or p_tx_hash !~ '^[A-Fa-f0-9]{64}$' then raise exception 'invalid TRON transaction hash'; end if;
  select * into v_w from public.nx_withdrawals where id=p_withdrawal_id for update;
  if not found then raise exception 'withdrawal not found'; end if;
  select * into v_e from public.nx_withdrawal_verification_evidence
   where withdrawal_id=p_withdrawal_id and tx_hash=lower(p_tx_hash);
  if not found then raise exception 'verified on-chain withdrawal evidence required'; end if;
  if v_w.status='completed' and lower(v_w.tx_hash)=lower(p_tx_hash) then return v_w; end if;
  if v_w.status <> 'processing' then raise exception 'withdrawal must be processing to complete'; end if;
  if v_e.recipient_address <> v_w.destination_address
     or v_e.amount_base_units <> v_w.amount * 1000000
     or v_e.receipt_result <> 'SUCCESS' then raise exception 'verified withdrawal evidence does not match request'; end if;
  if exists(select 1 from public.nx_withdrawals where lower(tx_hash)=lower(p_tx_hash) and id<>p_withdrawal_id) then raise exception 'transaction hash already used'; end if;
  update public.nx_withdrawals set status='completed',tx_hash=lower(p_tx_hash),updated_at=now()
   where id=p_withdrawal_id returning * into v_w;
  insert into public.nx_admin_audit_logs(admin_user_id,action,target_type,target_id,before_data,after_data)
   values(p_admin_user_id,'withdrawal_completed','withdrawal',p_withdrawal_id::text,
    jsonb_build_object('status','processing'),
    jsonb_build_object('status','completed','tx_hash',lower(p_tx_hash),'evidence_id',v_e.id,
      'payout_amount',v_w.amount,'fee_charged_on_top',v_w.fee_amount));
  return v_w;
end;
$$;
revoke all on function public.nx_admin_complete_withdrawal(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.nx_admin_complete_withdrawal(uuid,uuid,text) to service_role;

-- TRC20 USDT supports six decimal places. Fee is reserved on top of the full payout amount.
create or replace function public.nx_request_withdrawal(
  p_user_id uuid,p_amount numeric,p_fee numeric,p_network_code text,
  p_destination_address text,p_idempotency_key text
) returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  v_id uuid;
  v_debit_id uuid;
  v_existing public.nx_withdrawals%rowtype;
  v_total numeric;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'not authorized'; end if;
  if p_user_id is null then raise exception 'user required'; end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount,6) then raise exception 'withdrawal amount must use at most six decimal places'; end if;
  if p_fee is null or p_fee < 0 or p_fee <> round(p_fee,6) then raise exception 'withdrawal fee must use at most six decimal places'; end if;
  if p_network_code <> 'TRON-TRC20' then raise exception 'unsupported network'; end if;
  if p_destination_address is null or p_destination_address !~ '^T[1-9A-HJ-NP-Za-km-z]{33}$' then raise exception 'invalid TRON address format'; end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) < 8 or length(p_idempotency_key) > 200 then raise exception 'invalid idempotency key'; end if;
  v_total := p_amount + p_fee;
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text || ':' || p_idempotency_key, 0));
  select * into v_existing from public.nx_withdrawals where user_id=p_user_id and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.amount <> p_amount or v_existing.fee_amount <> p_fee
      or v_existing.network_code <> p_network_code or v_existing.destination_address <> p_destination_address then
      raise exception 'idempotency key reused with different withdrawal details';
    end if;
    return v_existing.id;
  end if;
  insert into public.nx_withdrawals(user_id,asset_code,network_code,destination_address,amount,fee_amount,status,idempotency_key)
   values(p_user_id,'USDT',p_network_code,p_destination_address,p_amount,p_fee,'requested',p_idempotency_key)
   returning id into v_id;
  v_debit_id := public.nx_post_ledger_entry(
    p_user_id,'USDT',-v_total,'withdrawal_debit','withdrawal-reserve:'||v_id::text,
    'withdrawal',v_id,jsonb_build_object('withdrawal_id',v_id,'payout_amount',p_amount,'fee_amount',p_fee)
  );
  update public.nx_withdrawals set ledger_debit_id=v_debit_id,updated_at=now() where id=v_id;
  return v_id;
end;
$$;
revoke all on function public.nx_request_withdrawal(uuid,numeric,numeric,text,text,text) from public,anon,authenticated;
grant execute on function public.nx_request_withdrawal(uuid,numeric,numeric,text,text,text) to service_role;
revoke insert,update,delete on public.nx_withdrawals from anon,authenticated;
