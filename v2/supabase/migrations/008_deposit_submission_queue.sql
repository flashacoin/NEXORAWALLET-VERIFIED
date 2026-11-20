-- NEXORA V2: deposit submission queue (does not credit balances).
-- Apply in staging first. A submitted TX hash is untrusted until verified on-chain.
create table if not exists public.nx_deposit_submissions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  asset_code text not null default 'USDT',
  network_code text not null check (network_code = 'TRON-TRC20'),
  amount numeric(30,8) not null check (amount > 0),
  tx_hash text not null check (tx_hash ~ '^[A-Fa-f0-9]{64}$'),
  status text not null default 'submitted' check (status in ('submitted','review','verified','rejected')),
  admin_note text,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(network_code, tx_hash)
);
alter table public.nx_deposit_submissions enable row level security;
revoke all on public.nx_deposit_submissions from anon, authenticated;
grant select on public.nx_deposit_submissions to authenticated;
drop policy if exists nx_deposit_submission_owner_read on public.nx_deposit_submissions;
create policy nx_deposit_submission_owner_read on public.nx_deposit_submissions for select to authenticated using (user_id = auth.uid());
create or replace function public.nx_submit_deposit(
  p_user_id uuid, p_amount numeric, p_network_code text, p_tx_hash text
) returns uuid
language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'not authorized'; end if;
  if p_user_id is null or p_amount is null or p_amount <= 0 or p_amount <> round(p_amount,8) then raise exception 'invalid amount'; end if;
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
