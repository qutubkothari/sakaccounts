create table sakaccounts.statement_rules (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 account_id uuid not null references sakaccounts.finance_accounts(id),
 merchant_key text not null check(length(merchant_key) between 2 and 180),
 category text not null check(length(trim(category)) between 1 and 120),
 expense_country char(2) not null check(expense_country in ('IN','AE')),
 merchant_currency char(3) not null check(merchant_currency in ('INR','AED')),
 created_at timestamptz not null default now(),
 unique(owner_id,account_id,merchant_key)
);
alter table sakaccounts.statement_rules enable row level security;
create policy statement_rules_read on sakaccounts.statement_rules for select to authenticated
 using(sakaccounts.can_manage(owner_id));
grant select on sakaccounts.statement_rules to authenticated;

create or replace function sakaccounts.post_statement_expense(
 p_row uuid,p_category text,p_country char(2),p_merchant_currency char(3),
 p_merchant_amount bigint,p_save_rule boolean default true
) returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare r sakaccounts.statement_rows%rowtype; i sakaccounts.statement_imports%rowtype;
 a sakaccounts.finance_accounts%rowtype; v_entry uuid; v_batch uuid; v_key text; begin
 select * into r from sakaccounts.statement_rows where id=p_row for update;
 if not found or not sakaccounts.can_manage(r.owner_id) then raise exception 'Access denied'; end if;
 select * into i from sakaccounts.statement_imports where id=r.import_id and owner_id=r.owner_id;
 select * into a from sakaccounts.finance_accounts where id=i.account_id and owner_id=r.owner_id;
 if a.kind<>'credit_card' or r.amount_minor is null or r.amount_minor>=0
 or r.posting_date is null or r.currency<>a.currency or nullif(trim(r.description),'') is null
 or nullif(trim(p_category),'') is null or p_country not in ('IN','AE')
 or p_merchant_currency not in ('INR','AED') or p_country is null or p_merchant_currency is null
 or (p_merchant_currency<>a.currency and (p_merchant_amount is null or p_merchant_amount<=0))
 then raise exception 'Review the card charge, category, location and merchant amount first'; end if;
 if r.match_status='matched' then
  select entry_id into v_entry from sakaccounts.journal_batches where id=r.matched_batch_id;
  if v_entry is null then raise exception 'This row is already matched to a different posting'; end if;
  return v_entry;
 end if;
 if r.match_status='ignored' then raise exception 'Ignored row cannot be posted'; end if;
 v_entry:=sakaccounts.post_entry_with_origin(
  p_row,r.owner_id,a.entity_id,'expense',coalesce(r.purchase_date,r.posting_date),
  -r.amount_minor,a.currency,trim(p_category),null,null,trim(r.description),
  'Statement row '||r.id::text,-r.amount_minor,r.posting_date,a.id,null,
  p_country,case when p_merchant_currency=a.currency then null else p_merchant_currency end,
  case when p_merchant_currency=a.currency then null else p_merchant_amount end);
 select id into v_batch from sakaccounts.journal_batches
 where owner_id=r.owner_id and request_id=p_row and entry_id=v_entry;
 update sakaccounts.statement_rows set match_status='matched',matched_batch_id=v_batch where id=r.id;
 if coalesce(p_save_rule,false) then
  v_key:=lower(trim(regexp_replace(r.description,'[^[:alnum:]]+',' ','g')));
  if length(v_key) between 2 and 180 then
   insert into sakaccounts.statement_rules(owner_id,account_id,merchant_key,category,expense_country,merchant_currency)
   values(r.owner_id,a.id,v_key,trim(p_category),p_country,p_merchant_currency)
   on conflict(owner_id,account_id,merchant_key) do update
    set category=excluded.category,expense_country=excluded.expense_country,merchant_currency=excluded.merchant_currency;
  end if;
 end if;
 return v_entry;
end $$;
revoke all on function sakaccounts.post_statement_expense(uuid,text,char,char,bigint,boolean) from public,anon;
grant execute on function sakaccounts.post_statement_expense(uuid,text,char,char,bigint,boolean) to authenticated;
notify pgrst,'reload schema';
