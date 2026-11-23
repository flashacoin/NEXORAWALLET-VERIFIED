-- NEXORA V2: enforce TRON USDT's six-decimal token precision for new submissions.
-- Existing rows are intentionally preserved; this NOT VALID constraint checks new/changed rows.
-- This migration does not settle deposits, change balances, or write ledger entries.

alter table public.nx_deposit_submissions
  add constraint nx_deposit_submissions_usdt_six_decimals
  check (amount = round(amount, 6)) not valid;

create or replace function public.nx_submit_deposit(
  p_user_id uuid, p_amount numeric, p_network_code text, p_tx_hash text
) returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'not authorized'; end if;
  if p_user_id is null or p_amount is null or p_amount <= 0 or p_amount <> round(p_amount,6) then raise exception 'invalid amount'; end if;
  if p_network_code <> 'TRON-TRC20' then raise exception 'unsupported network'; end if;
  if p_tx_hash is null or p_tx_hash !~ '^[A-Fa-f0-9]{64}$' then raise exception 'invalid transaction hash'; end if;
  insert into public.nx_deposit_submissions(user_id,asset_code,network_code,amount,tx_hash,status)
    values(p_user_id,'USDT',p_network_code,p_amount,lower(p_tx_hash),'submitted')
    on conflict(network_code,tx_hash) do nothing returning id into v_id;
  if v_id is null then raise exception 'transaction hash already submitted'; end if;
  return v_id;
end $$;

revoke all on function public.nx_submit_deposit(uuid,numeric,text,text) from public, anon, authenticated;
grant execute on function public.nx_submit_deposit(uuid,numeric,text,text) to service_role;
