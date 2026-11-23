-- NEXORA V2: immutable, read-only deposit verification evidence.
-- Records an exact match to a pending submission; never changes submission status,
-- wallet balances, deposits, or ledger rows.
create table if not exists public.nx_deposit_verification_evidence (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.nx_deposit_submissions(id) on delete restrict,
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
  constraint nx_deposit_evidence_event_unique unique(network_code, tx_hash, event_index),
  constraint nx_deposit_evidence_submission_unique unique(submission_id)
);

alter table public.nx_deposit_verification_evidence enable row level security;
revoke all on public.nx_deposit_verification_evidence from public, anon, authenticated, service_role;

create or replace function public.nx_prevent_deposit_evidence_mutation()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  raise exception 'deposit verification evidence is immutable';
end
$$;

drop trigger if exists nx_deposit_evidence_immutable on public.nx_deposit_verification_evidence;
create trigger nx_deposit_evidence_immutable
before update or delete on public.nx_deposit_verification_evidence
for each row execute function public.nx_prevent_deposit_evidence_mutation();

create or replace function public.nx_record_deposit_evidence(
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
language plpgsql
security definer
set search_path=''
as $$
declare
  v_submission public.nx_deposit_submissions%rowtype;
  v_existing public.nx_deposit_verification_evidence%rowtype;
  v_amount_base_units numeric(78,0);
  v_evidence_id uuid;
begin
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception 'not authorized';
  end if;
  if p_tx_hash is null or p_tx_hash !~* '^[a-f0-9]{64}$'
     or p_event_index is null or p_event_index < 0
     or coalesce(p_token_contract_address,'') = ''
     or coalesce(p_sender_address,'') = ''
     or coalesce(p_recipient_address,'') = ''
     or p_amount_base_units is null or p_amount_base_units !~ '^[1-9][0-9]*$'
     or length(p_amount_base_units) > 78
     or p_block_number is null or p_block_number < 0
     or p_confirmations is null or p_confirmations < 1
     or p_receipt_result is distinct from 'SUCCESS'
     or coalesce(p_verifier_version,'') = ''
     or length(p_verifier_version) > 64 then
    raise exception 'invalid deposit evidence';
  end if;
  v_amount_base_units := p_amount_base_units::numeric;

  select * into v_submission
  from public.nx_deposit_submissions
  where network_code = 'TRON-TRC20' and tx_hash = lower(p_tx_hash)
  for update;

  if not found then
    return jsonb_build_object('matched', false, 'reason', 'no_matching_submission');
  end if;
  if v_submission.asset_code <> 'USDT'
     or v_submission.status not in ('submitted','review') then
    return jsonb_build_object('matched', false, 'reason', 'submission_not_pending');
  end if;
  if v_submission.amount * 1000000 <> v_amount_base_units then
    return jsonb_build_object('matched', false, 'reason', 'amount_mismatch');
  end if;

  select * into v_existing
  from public.nx_deposit_verification_evidence
  where (network_code = 'TRON-TRC20' and tx_hash = lower(p_tx_hash) and event_index = p_event_index)
     or submission_id = v_submission.id
  limit 1;

  if found then
    -- Preserve the first immutable snapshot if a retry later observes more confirmations.
    if v_existing.submission_id = v_submission.id
       and v_existing.network_code = 'TRON-TRC20'
       and v_existing.tx_hash = lower(p_tx_hash)
       and v_existing.event_index = p_event_index
       and v_existing.token_contract_address = p_token_contract_address
       and v_existing.sender_address = p_sender_address
       and v_existing.recipient_address = p_recipient_address
       and v_existing.amount_base_units = v_amount_base_units
       and v_existing.block_number = p_block_number
       and v_existing.receipt_result = p_receipt_result then
      return jsonb_build_object('matched', true, 'evidence_id', v_existing.id, 'duplicate_retry', true);
    end if;
    return jsonb_build_object('matched', false, 'reason', 'duplicate_event_or_submission');
  end if;

  insert into public.nx_deposit_verification_evidence(
    submission_id, network_code, tx_hash, event_index, asset_code,
    token_contract_address, sender_address, recipient_address,
    amount_base_units, block_number, confirmations, receipt_result, verifier_version
  ) values (
    v_submission.id, 'TRON-TRC20', lower(p_tx_hash), p_event_index, 'USDT',
    p_token_contract_address, p_sender_address, p_recipient_address,
    v_amount_base_units, p_block_number, p_confirmations, p_receipt_result, p_verifier_version
  ) returning id into v_evidence_id;

  return jsonb_build_object('matched', true, 'evidence_id', v_evidence_id, 'duplicate_retry', false);
end
$$;

revoke all on function public.nx_record_deposit_evidence(text,integer,text,text,text,text,bigint,integer,text,text) from public, anon, authenticated;
grant execute on function public.nx_record_deposit_evidence(text,integer,text,text,text,text,bigint,integer,text,text) to service_role;
