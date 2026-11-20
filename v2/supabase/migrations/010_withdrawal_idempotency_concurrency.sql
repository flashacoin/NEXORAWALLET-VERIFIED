-- NEXORA V2: serialize concurrent withdrawal retries for a stable idempotency result.
-- Apply after 009. Staging first; this replaces the request RPC without changing existing rows.
-- NEXORA V2: atomic withdrawal request and reserve
-- Draft migration. Review and test on a non-production Supabase project first.

alter table public.nx_withdrawals
  add column if not exists idempotency_key text;
create unique index if not exists nx_withdrawals_idempotency_unique
  on public.nx_withdrawals(user_id,idempotency_key)
  where idempotency_key is not null;

create or replace function public.nx_request_withdrawal(
  p_user_id uuid,
  p_amount numeric,
  p_fee numeric,
  p_network_code text,
  p_destination_address text,
  p_idempotency_key text
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_debit_id uuid;
  v_existing public.nx_withdrawals%rowtype;
  v_total numeric;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'not authorized'; end if;
  if p_user_id is null then raise exception 'user required'; end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount,10) then raise exception 'invalid amount'; end if;
  if p_fee is null or p_fee < 0 or p_fee <> round(p_fee,10) then raise exception 'invalid fee'; end if;
  if p_network_code <> 'TRON-TRC20' then raise exception 'unsupported network'; end if;
  if p_destination_address is null or p_destination_address !~ '^T[1-9A-HJ-NP-Za-km-z]{33}$' then raise exception 'invalid TRON address format'; end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) < 8 or length(p_idempotency_key) > 200 then raise exception 'invalid idempotency key'; end if;
  v_total := p_amount + p_fee;

  -- Serialize concurrent retries for this user/key before checking for an existing request.
  -- The unique index remains the final database-level safeguard.
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text || ':' || p_idempotency_key, 0));

  select * into v_existing from public.nx_withdrawals
    where user_id=p_user_id and idempotency_key=p_idempotency_key;
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
    p_user_id,'USDT',-v_total,'withdrawal_debit',
    'withdrawal-reserve:'||v_id::text,'withdrawal',v_id,
    jsonb_build_object('withdrawal_id',v_id,'payout_amount',p_amount,'fee_amount',p_fee)
  );
  update public.nx_withdrawals set ledger_debit_id=v_debit_id, updated_at=now() where id=v_id;
  return v_id;
end;
$$;

revoke all on function public.nx_request_withdrawal(uuid,numeric,numeric,text,text,text) from public, anon, authenticated;
grant execute on function public.nx_request_withdrawal(uuid,numeric,numeric,text,text,text) to service_role;
revoke insert, update, delete on public.nx_withdrawals from anon, authenticated;
