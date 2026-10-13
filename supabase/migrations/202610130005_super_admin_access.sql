-- Grant the app administrator access only through authenticated, allowlisted RLS paths.
create or replace function sakaccounts.is_super_admin()
returns boolean language sql stable security definer set search_path=sakaccounts,auth,pg_temp as $$
  select exists(select 1 from sakaccounts.owner_allowlist where user_id=auth.uid() and app_role='super_admin')
$$;
revoke all on function sakaccounts.is_super_admin() from public, anon;
grant execute on function sakaccounts.is_super_admin() to authenticated;

create or replace function sakaccounts.is_owner_account(p_account uuid)
returns boolean language sql stable security definer set search_path=sakaccounts,auth,pg_temp as $$
  select exists(select 1 from sakaccounts.accounts a join sakaccounts.owner_allowlist o on o.user_id=a.owner_id
    where a.id=p_account and (a.owner_id=auth.uid() or sakaccounts.is_super_admin()))
$$;

drop policy owner_allowlist_read on sakaccounts.owner_allowlist;
create policy owner_allowlist_read on sakaccounts.owner_allowlist for select to authenticated
  using (user_id=auth.uid() or sakaccounts.is_super_admin());
drop policy accounts_owner_all on sakaccounts.accounts;
create policy accounts_owner_all on sakaccounts.accounts for all to authenticated
  using ((owner_id=auth.uid() or sakaccounts.is_super_admin()) and exists(select 1 from sakaccounts.owner_allowlist where user_id=owner_id))
  with check ((owner_id=auth.uid() or sakaccounts.is_super_admin()) and exists(select 1 from sakaccounts.owner_allowlist where user_id=owner_id));
drop policy events_owner_select on sakaccounts.financial_events;
create policy events_owner_select on sakaccounts.financial_events for select to authenticated
  using ((owner_id=auth.uid() or sakaccounts.is_super_admin()) and exists(select 1 from sakaccounts.owner_allowlist where user_id=owner_id));
drop policy flags_owner_all on sakaccounts.accounting_flags;
create policy flags_owner_all on sakaccounts.accounting_flags for all to authenticated
  using ((owner_id=auth.uid() or sakaccounts.is_super_admin()) and exists(select 1 from sakaccounts.owner_allowlist where user_id=owner_id))
  with check ((owner_id=auth.uid() or sakaccounts.is_super_admin()) and exists(select 1 from sakaccounts.owner_allowlist where user_id=owner_id));
drop policy opening_owner_all on sakaccounts.opening_balance_imports;
create policy opening_owner_all on sakaccounts.opening_balance_imports for all to authenticated
  using ((owner_id=auth.uid() or sakaccounts.is_super_admin()) and exists(select 1 from sakaccounts.owner_allowlist where user_id=owner_id))
  with check ((owner_id=auth.uid() or sakaccounts.is_super_admin()) and exists(select 1 from sakaccounts.owner_allowlist where user_id=owner_id));
drop policy legacy_owner_read on sakaccounts.legacy_snapshot_records;
create policy legacy_owner_read on sakaccounts.legacy_snapshot_records for select to authenticated
  using ((owner_id=auth.uid() or sakaccounts.is_super_admin()) and exists(select 1 from sakaccounts.owner_allowlist where user_id=owner_id));
create or replace function sakaccounts.post_simple_entry(p_request_id uuid, p_amount_minor bigint, p_currency char(3), p_description text, p_account uuid, p_kind text)
returns uuid language plpgsql security definer set search_path = sakaccounts, auth, pg_temp as $$
declare v_id uuid;
begin
  if p_kind not in ('income','expense') or p_amount_minor <= 0 or p_description is null or length(trim(p_description)) not between 1 and 240 or not sakaccounts.is_owner_account(p_account) or not exists(select 1 from sakaccounts.accounts where id=p_account and currency=p_currency) then raise exception 'Invalid entry or account access'; end if;
  insert into sakaccounts.financial_events(owner_id,request_id,kind,amount_minor,currency,description,source_account_id,destination_account_id)
  values((select owner_id from sakaccounts.accounts where id=p_account),p_request_id,p_kind,p_amount_minor,p_currency,trim(p_description),case when p_kind='expense' then p_account end,case when p_kind='income' then p_account end)
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
  if p_amount_minor <= 0 or p_description is null or length(trim(p_description)) not between 1 and 240 or p_source_account=p_destination_account or not sakaccounts.is_owner_account(p_source_account) or not sakaccounts.is_owner_account(p_destination_account) or (select owner_id from sakaccounts.accounts where id=p_source_account) is distinct from (select owner_id from sakaccounts.accounts where id=p_destination_account) or (select currency from sakaccounts.accounts where id=p_source_account) <> p_currency or (select currency from sakaccounts.accounts where id=p_destination_account) <> p_currency then raise exception 'Invalid transfer or account access'; end if;
  insert into sakaccounts.financial_events(owner_id,request_id,kind,amount_minor,currency,description,source_account_id,destination_account_id) values((select owner_id from sakaccounts.accounts where id=p_source_account),p_request_id,'transfer',p_amount_minor,p_currency,trim(p_description),p_source_account,p_destination_account)
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
  if p_amount_minor <= 0 or p_description is null or length(trim(p_description)) not between 1 and 240 or p_source_account=p_destination_account or not sakaccounts.is_owner_account(p_source_account) or not sakaccounts.is_owner_account(p_destination_account) or (select owner_id from sakaccounts.accounts where id=p_source_account) is distinct from (select owner_id from sakaccounts.accounts where id=p_destination_account) or (select currency from sakaccounts.accounts where id=p_source_account) <> p_currency or (select currency from sakaccounts.accounts where id=p_destination_account) <> p_currency then raise exception 'Invalid settlement or account access'; end if;
  insert into sakaccounts.financial_events(owner_id,request_id,kind,amount_minor,currency,description,source_account_id,destination_account_id) values((select owner_id from sakaccounts.accounts where id=p_source_account),p_request_id,'invoice_settlement',p_amount_minor,p_currency,trim(p_description),p_source_account,p_destination_account)
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
  if p_amount_minor <= 0 or p_description is null or length(trim(p_description)) not between 1 and 240 or p_source_account=p_destination_account or not sakaccounts.is_owner_account(p_source_account) or not sakaccounts.is_owner_account(p_destination_account) or (select owner_id from sakaccounts.accounts where id=p_source_account) is distinct from (select owner_id from sakaccounts.accounts where id=p_destination_account) or (select currency from sakaccounts.accounts where id=p_source_account) <> p_currency or (select currency from sakaccounts.accounts where id=p_destination_account) <> p_currency or (select kind from sakaccounts.accounts where id=p_destination_account) <> 'credit_card' then raise exception 'Invalid repayment or account access'; end if;
  insert into sakaccounts.financial_events(owner_id,request_id,kind,amount_minor,currency,description,source_account_id,destination_account_id) values((select owner_id from sakaccounts.accounts where id=p_source_account),p_request_id,'card_repayment',p_amount_minor,p_currency,trim(p_description),p_source_account,p_destination_account)
  on conflict(owner_id,request_id) do update set request_id=excluded.request_id
    where financial_events.kind=excluded.kind and financial_events.amount_minor=excluded.amount_minor and financial_events.currency=excluded.currency and financial_events.description=excluded.description and financial_events.source_account_id is not distinct from excluded.source_account_id and financial_events.destination_account_id is not distinct from excluded.destination_account_id
    returning id into v_id;
  if v_id is null then raise exception 'Request ID already used with different entry details'; end if;
  return v_id;
end $$;


notify pgrst, 'reload schema';
