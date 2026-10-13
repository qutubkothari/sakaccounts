-- SakAccounts isolated schema. Review existing project tables and policies before applying.
-- No existing tables are altered or dropped by this migration.
create schema if not exists sakaccounts;
revoke all on schema sakaccounts from public, anon, authenticated;
grant usage on schema sakaccounts to anon, authenticated;

create table if not exists sakaccounts.owner_allowlist (
  user_id uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);
create table if not exists sakaccounts.accounts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id),
  name text not null check (length(trim(name)) between 1 and 120),
  kind text not null check (kind in ('cash','bank','credit_card','receivable','payable','equity','other')),
  currency char(3) not null default 'INR',
  opening_balance_minor bigint not null default 0,
  created_at timestamptz not null default now(),
  unique(owner_id, name)
);
create table if not exists sakaccounts.financial_events (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id),
  request_id uuid not null,
  kind text not null check (kind in ('income','expense','transfer','invoice_settlement','card_repayment')),
  amount_minor bigint not null check (amount_minor > 0),
  currency char(3) not null,
  description text not null check (length(trim(description)) between 1 and 240),
  source_account_id uuid references sakaccounts.accounts(id),
  destination_account_id uuid references sakaccounts.accounts(id),
  created_at timestamptz not null default now(),
  unique(owner_id, request_id),
  check (source_account_id is null or destination_account_id is null or source_account_id <> destination_account_id)
);
create table if not exists sakaccounts.accounting_flags (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id),
  flag_key text not null,
  description text not null,
  status text not null default 'unresolved' check (status in ('unresolved','resolved')),
  source_reference text,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  unique(owner_id, flag_key)
);
create table if not exists sakaccounts.opening_balance_imports (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id),
  account_id uuid not null references sakaccounts.accounts(id) on delete cascade,
  as_of_date date not null,
  amount_minor bigint not null,
  currency char(3) not null,
  source_reference text,
  verified boolean not null default false,
  created_at timestamptz not null default now(),
  unique(owner_id, account_id, as_of_date)
);

grant usage on schema sakaccounts to anon, authenticated;
grant select on sakaccounts.accounts, sakaccounts.financial_events, sakaccounts.accounting_flags, sakaccounts.opening_balance_imports, sakaccounts.owner_allowlist to authenticated;
grant insert, update, delete on sakaccounts.accounts, sakaccounts.accounting_flags, sakaccounts.opening_balance_imports to authenticated;

alter table sakaccounts.owner_allowlist enable row level security;
alter table sakaccounts.accounts enable row level security;
alter table sakaccounts.financial_events enable row level security;
alter table sakaccounts.accounting_flags enable row level security;
alter table sakaccounts.opening_balance_imports enable row level security;
create policy owner_allowlist_read on sakaccounts.owner_allowlist for select to authenticated using (user_id = auth.uid());
create policy accounts_owner_all on sakaccounts.accounts for all to authenticated using (owner_id = auth.uid() and exists(select 1 from sakaccounts.owner_allowlist where user_id = auth.uid())) with check (owner_id = auth.uid() and exists(select 1 from sakaccounts.owner_allowlist where user_id = auth.uid()));
create policy events_owner_select on sakaccounts.financial_events for select to authenticated using (owner_id = auth.uid() and exists(select 1 from sakaccounts.owner_allowlist where user_id = auth.uid()));
create policy flags_owner_all on sakaccounts.accounting_flags for all to authenticated using (owner_id = auth.uid() and exists(select 1 from sakaccounts.owner_allowlist where user_id = auth.uid())) with check (owner_id = auth.uid() and exists(select 1 from sakaccounts.owner_allowlist where user_id = auth.uid()));
create policy opening_owner_all on sakaccounts.opening_balance_imports for all to authenticated using (owner_id = auth.uid() and exists(select 1 from sakaccounts.owner_allowlist where user_id = auth.uid())) with check (owner_id = auth.uid() and exists(select 1 from sakaccounts.owner_allowlist where user_id = auth.uid()));

create view sakaccounts.account_balances with (security_invoker=true) as
select a.id, a.name, a.kind, a.currency, a.opening_balance_minor,
  a.opening_balance_minor + coalesce(sum(case when e.destination_account_id=a.id then e.amount_minor when e.source_account_id=a.id then -e.amount_minor else 0 end),0)::bigint as balance_minor
from sakaccounts.accounts a
left join sakaccounts.financial_events e on e.source_account_id=a.id or e.destination_account_id=a.id
group by a.id;
grant select on sakaccounts.account_balances to authenticated;
create or replace function sakaccounts.is_owner_account(p_account uuid)
returns boolean language sql stable security definer set search_path = sakaccounts, auth, pg_temp as $$
  select exists(select 1 from sakaccounts.accounts a join sakaccounts.owner_allowlist o on o.user_id = a.owner_id where a.id = p_account and a.owner_id = auth.uid() and o.user_id = auth.uid())
$$;

create or replace function sakaccounts.post_simple_entry(p_request_id uuid, p_amount_minor bigint, p_currency char(3), p_description text, p_account uuid, p_kind text)
returns uuid language plpgsql security definer set search_path = sakaccounts, auth, pg_temp as $$
declare v_id uuid;
begin
  if p_kind not in ('income','expense') or p_amount_minor <= 0 or p_description is null or length(trim(p_description)) not between 1 and 240 or not sakaccounts.is_owner_account(p_account) or not exists(select 1 from sakaccounts.accounts where id=p_account and currency=p_currency) then raise exception 'Invalid entry or account access'; end if;
  insert into sakaccounts.financial_events(owner_id,request_id,kind,amount_minor,currency,description,source_account_id,destination_account_id)
  values(auth.uid(),p_request_id,p_kind,p_amount_minor,p_currency,trim(p_description),case when p_kind='expense' then p_account end,case when p_kind='income' then p_account end)
  on conflict(owner_id,request_id) do update set request_id=excluded.request_id
    where financial_events.kind=excluded.kind and financial_events.amount_minor=excluded.amount_minor and financial_events.currency=excluded.currency and financial_events.description=excluded.description and financial_events.source_account_id is not distinct from excluded.source_account_id and financial_events.destination_account_id is not distinct from excluded.destination_account_id
    returning id into v_id;
  if v_id is null then raise exception 'Request ID already used with different entry details'; end if;
  return v_id;
end $$;

create or replace function sakaccounts.post_transfer(p_request_id uuid, p_amount_minor bigint, p_currency char(3), p_description text, p_source_account uuid, p_destination_account uuid)
returns uuid language plpgsql security definer set search_path = sakaccounts, auth, pg_temp as $$
declare v_id uuid;
begin
  if p_amount_minor <= 0 or p_description is null or length(trim(p_description)) not between 1 and 240 or p_source_account=p_destination_account or not sakaccounts.is_owner_account(p_source_account) or not sakaccounts.is_owner_account(p_destination_account) or (select currency from sakaccounts.accounts where id=p_source_account) <> p_currency or (select currency from sakaccounts.accounts where id=p_destination_account) <> p_currency then raise exception 'Invalid transfer or account access'; end if;
  insert into sakaccounts.financial_events(owner_id,request_id,kind,amount_minor,currency,description,source_account_id,destination_account_id) values(auth.uid(),p_request_id,'transfer',p_amount_minor,p_currency,trim(p_description),p_source_account,p_destination_account)
  on conflict(owner_id,request_id) do update set request_id=excluded.request_id
    where financial_events.kind=excluded.kind and financial_events.amount_minor=excluded.amount_minor and financial_events.currency=excluded.currency and financial_events.description=excluded.description and financial_events.source_account_id is not distinct from excluded.source_account_id and financial_events.destination_account_id is not distinct from excluded.destination_account_id
    returning id into v_id;
  if v_id is null then raise exception 'Request ID already used with different entry details'; end if;
  return v_id;
end $$;
create or replace function sakaccounts.post_invoice_settlement(p_request_id uuid,p_amount_minor bigint,p_currency char(3),p_description text,p_source_account uuid,p_destination_account uuid)
returns uuid language plpgsql security definer set search_path = sakaccounts, auth, pg_temp as $$
declare v_id uuid;
begin
  if p_amount_minor <= 0 or p_description is null or length(trim(p_description)) not between 1 and 240 or p_source_account=p_destination_account or not sakaccounts.is_owner_account(p_source_account) or not sakaccounts.is_owner_account(p_destination_account) or (select currency from sakaccounts.accounts where id=p_source_account) <> p_currency or (select currency from sakaccounts.accounts where id=p_destination_account) <> p_currency then raise exception 'Invalid settlement or account access'; end if;
  insert into sakaccounts.financial_events(owner_id,request_id,kind,amount_minor,currency,description,source_account_id,destination_account_id) values(auth.uid(),p_request_id,'invoice_settlement',p_amount_minor,p_currency,trim(p_description),p_source_account,p_destination_account)
  on conflict(owner_id,request_id) do update set request_id=excluded.request_id
    where financial_events.kind=excluded.kind and financial_events.amount_minor=excluded.amount_minor and financial_events.currency=excluded.currency and financial_events.description=excluded.description and financial_events.source_account_id is not distinct from excluded.source_account_id and financial_events.destination_account_id is not distinct from excluded.destination_account_id
    returning id into v_id;
  if v_id is null then raise exception 'Request ID already used with different entry details'; end if;
  return v_id;
end $$;
create or replace function sakaccounts.post_card_repayment(p_request_id uuid,p_amount_minor bigint,p_currency char(3),p_description text,p_source_account uuid,p_destination_account uuid)
returns uuid language plpgsql security definer set search_path = sakaccounts, auth, pg_temp as $$
declare v_id uuid;
begin
  if p_amount_minor <= 0 or p_description is null or length(trim(p_description)) not between 1 and 240 or p_source_account=p_destination_account or not sakaccounts.is_owner_account(p_source_account) or not sakaccounts.is_owner_account(p_destination_account) or (select currency from sakaccounts.accounts where id=p_source_account) <> p_currency or (select currency from sakaccounts.accounts where id=p_destination_account) <> p_currency or (select kind from sakaccounts.accounts where id=p_destination_account) <> 'credit_card' then raise exception 'Invalid repayment or account access'; end if;
  insert into sakaccounts.financial_events(owner_id,request_id,kind,amount_minor,currency,description,source_account_id,destination_account_id) values(auth.uid(),p_request_id,'card_repayment',p_amount_minor,p_currency,trim(p_description),p_source_account,p_destination_account)
  on conflict(owner_id,request_id) do update set request_id=excluded.request_id
    where financial_events.kind=excluded.kind and financial_events.amount_minor=excluded.amount_minor and financial_events.currency=excluded.currency and financial_events.description=excluded.description and financial_events.source_account_id is not distinct from excluded.source_account_id and financial_events.destination_account_id is not distinct from excluded.destination_account_id
    returning id into v_id;
  if v_id is null then raise exception 'Request ID already used with different entry details'; end if;
  return v_id;
end $$;

grant execute on function sakaccounts.post_simple_entry(uuid,bigint,char,text,uuid,text), sakaccounts.post_transfer(uuid,bigint,char,text,uuid,uuid), sakaccounts.post_invoice_settlement(uuid,bigint,char,text,uuid,uuid), sakaccounts.post_card_repayment(uuid,bigint,char,text,uuid,uuid) to authenticated;
revoke all on all functions in schema sakaccounts from public, anon;
grant usage on schema sakaccounts to authenticated;

alter role authenticator set pgrst.db_schemas = 'public,sakaccounts';
notify pgrst, 'reload config';

-- Seed flags are created for the allowlisted user only after setup; values and balances are intentionally unset.
