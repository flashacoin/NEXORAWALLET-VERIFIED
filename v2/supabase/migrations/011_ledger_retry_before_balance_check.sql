-- NEXORA V2: make ledger retries return the original entry before balance checks.
-- This prevents a repeated debit from failing merely because the first debit reduced balance.
-- Apply after migration 010 on a staging database first.

create or replace function public.nx_post_ledger_entry(
  p_user_id uuid,
  p_asset_code text,
  p_amount numeric,
  p_entry_type text,
  p_idempotency_key text,
  p_reference_type text default null,
  p_reference_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet_id uuid;
  v_balance numeric;
  v_entry_id uuid;
begin
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception 'not authorized';
  end if;
  if p_user_id is null or p_asset_code is null or length(trim(p_asset_code)) = 0 then
    raise exception 'user and asset are required';
  end if;
  if p_amount is null or p_amount = 0 then
    raise exception 'amount must be non-zero';
  end if;
  if p_amount <> round(p_amount, 10) then
    raise exception 'amount precision exceeds 10 decimal places';
  end if;
  if p_entry_type not in ('deposit_credit','withdrawal_debit','withdrawal_refund',
    'payment_debit','payment_refund','admin_adjustment','transfer_debit','transfer_credit') then
    raise exception 'invalid entry type';
  end if;
  if p_entry_type in ('deposit_credit','withdrawal_refund','payment_refund','transfer_credit') and p_amount <= 0 then
    raise exception 'credit entries must be positive';
  end if;
  if p_entry_type in ('withdrawal_debit','payment_debit','transfer_debit') and p_amount >= 0 then
    raise exception 'debit entries must be negative';
  end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) < 8 or length(p_idempotency_key) > 200 then
    raise exception 'idempotency key must be 8-200 characters';
  end if;
  if p_entry_type = 'admin_adjustment' and p_reference_type is null then
    raise exception 'admin adjustment must include a reference type';
  end if;

  select id, balance into v_wallet_id, v_balance
    from public.wallets
    where user_id = p_user_id and asset_code = p_asset_code
    for update;
  if v_wallet_id is null then
    raise exception 'wallet not found';
  end if;
  -- Resolve an identical retry before checking the current balance. A prior debit
  -- may have reduced the balance, but retrying its key must still return the same row.
  select id into v_entry_id from public.nx_wallet_ledger
    where idempotency_key = p_idempotency_key;
  if v_entry_id is not null then
    if not exists (
      select 1 from public.nx_wallet_ledger
      where id = v_entry_id
        and wallet_id = v_wallet_id and user_id = p_user_id and asset_code = p_asset_code
        and amount = p_amount and entry_type = p_entry_type
        and reference_type is not distinct from p_reference_type
        and reference_id is not distinct from p_reference_id
    ) then
      raise exception 'idempotency key reused for a different operation';
    end if;
    return v_entry_id;
  end if;

  if v_balance + p_amount < 0 then
    raise exception 'insufficient balance';
  end if;

  insert into public.nx_wallet_ledger(
    wallet_id,user_id,asset_code,amount,entry_type,reference_type,reference_id,idempotency_key,metadata
  ) values (
    v_wallet_id,p_user_id,p_asset_code,p_amount,p_entry_type,p_reference_type,p_reference_id,
    p_idempotency_key,coalesce(p_metadata,'{}'::jsonb)
  )
  on conflict (idempotency_key) do nothing
  returning id into v_entry_id;

  if v_entry_id is null then
    select id into v_entry_id from public.nx_wallet_ledger
      where idempotency_key = p_idempotency_key
        and wallet_id = v_wallet_id and user_id = p_user_id and asset_code = p_asset_code
        and amount = p_amount and entry_type = p_entry_type
        and reference_type is not distinct from p_reference_type
        and reference_id is not distinct from p_reference_id;
    if v_entry_id is null then
      raise exception 'idempotency key reused for a different operation';
    end if;
    return v_entry_id;
  end if;

  update public.wallets
    set balance = balance + p_amount, updated_at = now()
    where id = v_wallet_id;
  return v_entry_id;
end;
$$;


revoke all on function public.nx_post_ledger_entry(uuid,text,numeric,text,text,text,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.nx_post_ledger_entry(uuid,text,numeric,text,text,text,uuid,jsonb) to service_role;
