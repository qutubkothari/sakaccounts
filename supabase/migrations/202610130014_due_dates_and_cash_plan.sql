alter table sakaccounts.ledger_entries add column due_date date;
create policy due_date_update on sakaccounts.ledger_entries for update to authenticated
 using(sakaccounts.can_manage(owner_id)) with check(sakaccounts.can_manage(owner_id));
grant update(due_date) on sakaccounts.ledger_entries to authenticated;

create or replace function sakaccounts.post_entry_with_due(p_request_id uuid,p_owner uuid,p_entity uuid,p_kind text,p_date date,p_amount bigint,p_currency char(3),p_category text,p_subcategory text,p_party text,p_description text,p_reference text,p_payment_amount bigint,p_payment_date date,p_funding_account uuid,p_due_date date)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare v_id uuid; begin
 v_id:=sakaccounts.post_entry(p_request_id,p_owner,p_entity,p_kind,p_date,p_amount,p_currency,p_category,p_subcategory,p_party,p_description,p_reference,p_payment_amount,p_payment_date,p_funding_account);
 update sakaccounts.ledger_entries set due_date=p_due_date where id=v_id and owner_id=p_owner and due_date is distinct from p_due_date;
 return v_id;
end $$;
revoke all on function sakaccounts.post_entry_with_due(uuid,uuid,uuid,text,date,bigint,char,text,text,text,text,text,bigint,date,uuid,date) from public,anon;
grant execute on function sakaccounts.post_entry_with_due(uuid,uuid,uuid,text,date,bigint,char,text,text,text,text,text,bigint,date,uuid,date) to authenticated;

create table sakaccounts.cash_plan_settings (
 owner_id uuid not null references auth.users(id), currency char(3) not null check(currency in ('INR','AED')),
 reserve_minor bigint not null default 0 check(reserve_minor>=0),
 essential_costs_30d_minor bigint not null default 0 check(essential_costs_30d_minor>=0),
 confirmed_collections_30d_minor bigint not null default 0 check(confirmed_collections_30d_minor>=0),
 assumptions text, updated_at timestamptz not null default now(), primary key(owner_id,currency)
);
alter table sakaccounts.cash_plan_settings enable row level security;
create policy plan_read on sakaccounts.cash_plan_settings for select to authenticated using(sakaccounts.can_manage(owner_id));
create policy plan_write on sakaccounts.cash_plan_settings for insert to authenticated with check(sakaccounts.can_manage(owner_id));
create policy plan_update on sakaccounts.cash_plan_settings for update to authenticated using(sakaccounts.can_manage(owner_id)) with check(sakaccounts.can_manage(owner_id));
grant select,insert,update on sakaccounts.cash_plan_settings to authenticated;

create table sakaccounts.owner_preferences (
 owner_id uuid primary key references auth.users(id), reporting_timezone text not null default 'Asia/Kolkata',
 updated_at timestamptz not null default now()
);
alter table sakaccounts.owner_preferences enable row level security;
create policy preference_read on sakaccounts.owner_preferences for select to authenticated using(sakaccounts.can_manage(owner_id));
create policy preference_write on sakaccounts.owner_preferences for insert to authenticated with check(sakaccounts.can_manage(owner_id));
create policy preference_update on sakaccounts.owner_preferences for update to authenticated using(sakaccounts.can_manage(owner_id)) with check(sakaccounts.can_manage(owner_id));
grant select,insert,update on sakaccounts.owner_preferences to authenticated;
notify pgrst,'reload schema';
