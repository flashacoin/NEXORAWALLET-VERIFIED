-- NEXORA V2: atomic exactly-once settlement for independently verified TRON USDT deposits.
-- Server-only RPC. Requires immutable verifier evidence and expected contract, recipient,
-- and confirmation threshold from trusted server configuration. No production deployment.

alter table public.nx_deposit_submissions
  drop constraint if exists nx_deposit_submissions_status_check;
alter table public.nx_deposit_submissions
  add constraint nx_deposit_submissions_status_check
  check (status in ('submitted','review','verified','rejected','credited'));

alter table public.nx_deposits
  add column if not exists verification_evidence_id uuid
    references public.nx_deposit_verification_evidence(id) on delete restrict;
create unique index if not exists nx_deposits_verification_evidence_unique
  on public.nx_deposits(verification_evidence_id)
  where verification_evidence_id is not null;

create or replace function public.nx_settle_verified_deposit(
  p_submission_id uuid,
  p_evidence_id uuid,
  p_expected_token_contract text,
  p_expected_recipient text,
  p_required_confirmations integer
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_submission public.nx_deposit_submissions%rowtype;
  v_evidence public.nx_deposit_verification_evidence%rowtype;
  v_deposit public.nx_deposits%rowtype;
  v_ledger_id uuid;
  v_amount numeric(30,10);
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'not authorized'; end if;
  if p_submission_id is null or p_evidence_id is null
     or coalesce(p_expected_token_contract,'') = ''
     or coalesce(p_expected_recipient,'') = ''
     or p_required_confirmations is null or p_required_confirmations < 1 then
    raise exception 'valid settlement configuration and identifiers required';
  end if;

  select * into v_submission from public.nx_deposit_submissions
    where id=p_submission_id for update;
  if not found then raise exception 'deposit submission not found'; end if;

  select * into v_evidence from public.nx_deposit_verification_evidence
    where id=p_evidence_id and submission_id=p_submission_id for update;
  if not found then raise exception 'matching verified deposit evidence required'; end if;

  if v_submission.network_code <> 'TRON-TRC20'
     or v_submission.asset_code <> 'USDT'
     or v_evidence.network_code <> v_submission.network_code
     or v_evidence.asset_code <> v_submission.asset_code
     or v_evidence.receipt_result <> 'SUCCESS'
     or v_evidence.token_contract_address <> p_expected_token_contract
     or v_evidence.recipient_address <> p_expected_recipient
     or v_evidence.confirmations < p_required_confirmations then
    raise exception 'deposit verification evidence does not meet settlement policy';
  end if;
  if v_evidence.amount_base_units <> v_submission.amount * 1000000 then
    raise exception 'verified deposit amount does not match submission';
  end if;
  if v_submission.amount <> round(v_submission.amount,6) then
    raise exception 'deposit amount precision is invalid';
  end if;

  if v_submission.status='credited' then
    select * into v_deposit from public.nx_deposits
      where verification_evidence_id=p_evidence_id for update;
    if not found or v_deposit.user_id <> v_submission.user_id
       or v_deposit.tx_hash <> v_submission.tx_hash
       or v_deposit.amount <> v_submission.amount
       or v_deposit.ledger_id is null or v_deposit.status <> 'credited' then
      raise exception 'credited submission is missing consistent settlement records; manual audit required';
    end if;
    return jsonb_build_object('settled',true,'duplicate_retry',true,
      'deposit_id',v_deposit.id,'ledger_id',v_deposit.ledger_id);
  end if;

  if v_submission.status not in ('submitted','review','verified') then
    raise exception 'deposit submission is not eligible for settlement';
  end if;

  v_amount := v_evidence.amount_base_units / 1000000;
  insert into public.nx_deposits(
    user_id,asset_code,network_code,deposit_address,tx_hash,event_index,
    amount,confirmations,required_confirmations,status,verification_evidence_id
  ) values (
    v_submission.user_id,'USDT','TRON-TRC20',p_expected_recipient,
    v_submission.tx_hash,v_evidence.event_index,v_amount,
    v_evidence.confirmations,p_required_confirmations,'confirmed',p_evidence_id
  ) returning * into v_deposit;

  v_ledger_id := public.nx_post_ledger_entry(
    v_submission.user_id,'USDT',v_amount,'deposit_credit',
    'deposit-credit:TRON-TRC20:'||v_submission.tx_hash||':'||v_evidence.event_index::text,
    'deposit',v_deposit.id,
    jsonb_build_object('submission_id',v_submission.id,'verification_evidence_id',v_evidence.id,
      'network_code','TRON-TRC20','tx_hash',v_submission.tx_hash,'event_index',v_evidence.event_index,
      'token_contract_address',v_evidence.token_contract_address,'recipient_address',v_evidence.recipient_address,
      'block_number',v_evidence.block_number,'confirmations',v_evidence.confirmations)
  );

  update public.nx_deposits set status='credited',ledger_id=v_ledger_id,
    credited_at=now(),updated_at=now() where id=v_deposit.id returning * into v_deposit;
  update public.nx_deposit_submissions set status='credited',
    verified_at=coalesce(verified_at,now()),updated_at=now() where id=v_submission.id;

  insert into public.nx_admin_audit_logs(action,target_type,target_id,before_data,after_data)
  values ('deposit_credited_by_verified_evidence','deposit',v_deposit.id::text,
    jsonb_build_object('submission_status',v_submission.status),
    jsonb_build_object('submission_id',v_submission.id,'verification_evidence_id',v_evidence.id,
      'ledger_id',v_ledger_id,'amount',v_amount,'asset_code','USDT','network_code','TRON-TRC20'));

  return jsonb_build_object('settled',true,'duplicate_retry',false,
    'deposit_id',v_deposit.id,'ledger_id',v_ledger_id);
end;
$$;

revoke all on function public.nx_settle_verified_deposit(uuid,uuid,text,text,integer)
  from public,anon,authenticated;
grant execute on function public.nx_settle_verified_deposit(uuid,uuid,text,text,integer)
  to service_role;
