-- NEXORA V2: bind one verified Telegram identity to one authenticated wallet account.
-- The Telegram Web App initData signature is verified by the Edge Function before this RPC.
create table if not exists public.nx_telegram_account_links (
  user_id uuid primary key references auth.users(id) on delete cascade,
  telegram_user_id bigint not null unique check (telegram_user_id > 0),
  telegram_username text,
  telegram_first_name text,
  telegram_last_name text,
  linked_at timestamptz not null default now()
);

alter table public.nx_telegram_account_links enable row level security;
revoke all on public.nx_telegram_account_links from public, anon, authenticated, service_role;

create or replace function public.nx_link_telegram_account(
  p_user_id uuid,
  p_telegram_user_id bigint,
  p_username text default null,
  p_first_name text default null,
  p_last_name text default null
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_by_user public.nx_telegram_account_links%rowtype;
  v_by_telegram public.nx_telegram_account_links%rowtype;
begin
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception 'not authorized';
  end if;
  if p_user_id is null or p_telegram_user_id is null or p_telegram_user_id <= 0 then
    raise exception 'valid wallet user and Telegram user IDs are required';
  end if;

  select * into v_by_user from public.nx_telegram_account_links
    where user_id=p_user_id for update;
  if found then
    if v_by_user.telegram_user_id=p_telegram_user_id then
      return jsonb_build_object('linked',true,'already_linked',true,'linked_at',v_by_user.linked_at);
    end if;
    raise exception 'wallet account is already linked to a different Telegram account';
  end if;

  select * into v_by_telegram from public.nx_telegram_account_links
    where telegram_user_id=p_telegram_user_id;
  if found then
    raise exception 'Telegram account is already linked to another wallet account';
  end if;

  insert into public.nx_telegram_account_links(
    user_id,telegram_user_id,telegram_username,telegram_first_name,telegram_last_name
  ) values (
    p_user_id,p_telegram_user_id,
    nullif(left(coalesce(p_username,''),64),''),
    nullif(left(coalesce(p_first_name,''),128),''),
    nullif(left(coalesce(p_last_name,''),128),'')
  );

  return jsonb_build_object('linked',true,'already_linked',false);
end;
$$;

revoke all on function public.nx_link_telegram_account(uuid,bigint,text,text,text)
  from public,anon,authenticated;
grant execute on function public.nx_link_telegram_account(uuid,bigint,text,text,text)
  to service_role;
