-- Five entity choices are configuration, not financial transactions.
insert into sakaccounts.entities(owner_id,code,name,currency)
select o.user_id,v.code,v.name,v.currency from sakaccounts.owner_allowlist o
cross join (values
 ('amazon_india','Amazon India','INR'),('fasteners_india','Fasteners India','INR'),
 ('it','IT','INR'),('amazon_uae','Amazon UAE','AED'),('personal','Personal','INR')
) v(code,name,currency) where o.app_role='owner'
on conflict(owner_id,code) do nothing;

alter table sakaccounts.finance_accounts add column opening_balance_minor bigint not null default 0;
alter table sakaccounts.finance_accounts add column create_request_id uuid unique;

create or replace function sakaccounts.create_finance_account(p_request_id uuid,p_owner uuid,p_entity uuid,p_name text,p_kind text,p_currency char(3),p_opening bigint,p_as_of date,p_issuer text default null,p_last_four char(4) default null,p_limit bigint default null)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare v_id uuid; v_batch uuid; begin
 if not sakaccounts.can_manage(p_owner) or p_kind not in ('bank','cash','credit_card') or p_currency not in ('INR','AED')
 or nullif(trim(p_name),'') is null or p_opening<0 or p_as_of is null
 or not exists(select 1 from sakaccounts.entities where id=p_entity and owner_id=p_owner and currency=p_currency)
 or (p_kind='credit_card' and (nullif(trim(p_issuer),'') is null or p_last_four !~ '^[0-9]{4}$'))
 then raise exception 'Invalid account setup'; end if;
 select id into v_id from sakaccounts.finance_accounts where create_request_id=p_request_id and owner_id=p_owner;
 if found then return v_id; end if;
 insert into sakaccounts.finance_accounts(owner_id,entity_id,name,kind,currency,issuing_bank,last_four,credit_limit_minor,opening_as_of,opening_balance_minor,create_request_id)
 values(p_owner,p_entity,trim(p_name),p_kind,p_currency,p_issuer,p_last_four,p_limit,p_as_of,p_opening,p_request_id) returning id into v_id;
 if p_opening>0 then
  insert into sakaccounts.journal_batches(owner_id,request_id,action,effective_date)
  values(p_owner,p_request_id,'opening_balance',p_as_of) returning id into v_batch;
  if p_kind='credit_card' then
   perform sakaccounts.line(v_batch,p_owner,p_entity,'opening_equity',null,p_currency,p_opening,0);
   perform sakaccounts.line(v_batch,p_owner,p_entity,'card_payable',v_id,p_currency,0,p_opening);
  else
   perform sakaccounts.line(v_batch,p_owner,p_entity,p_kind,v_id,p_currency,p_opening,0);
   perform sakaccounts.line(v_batch,p_owner,p_entity,'opening_equity',null,p_currency,0,p_opening);
  end if;
 end if;
 return v_id;
end $$;
grant execute on function sakaccounts.create_finance_account(uuid,uuid,uuid,text,text,char,bigint,date,text,char,bigint) to authenticated;
revoke all on function sakaccounts.create_finance_account(uuid,uuid,uuid,text,text,char,bigint,date,text,char,bigint) from public,anon;

-- Inventory purchases remain payable until settled; they never become operating expense on purchase.
create or replace function sakaccounts.settle_entry(p_request_id uuid,p_entry uuid,p_amount bigint,p_payment_date date,p_funding_account uuid,p_reference text default null)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare e sakaccounts.ledger_entries%rowtype; a sakaccounts.finance_accounts%rowtype; v_batch uuid; v_paid bigint; begin
 select * into e from sakaccounts.ledger_entries where id=p_entry;
 if not found or not sakaccounts.can_manage(e.owner_id) then raise exception 'Access denied'; end if;
 select id into v_batch from sakaccounts.journal_batches where owner_id=e.owner_id and request_id=p_request_id;
 if found then return v_batch; end if;
 select coalesce(sum(amount_minor),0) into v_paid from sakaccounts.settlements where entry_id=p_entry;
 if e.kind not in ('expense','income','inventory_purchase') or p_amount<=0 or v_paid+p_amount>e.amount_minor or p_payment_date is null then raise exception 'Invalid or excessive settlement'; end if;
 select * into a from sakaccounts.finance_accounts where id=p_funding_account and owner_id=e.owner_id;
 if not found then raise exception 'Funding account not found'; end if;
 insert into sakaccounts.journal_batches(owner_id,request_id,action,effective_date,entry_id)
 values(e.owner_id,p_request_id,'settle_'||e.kind,p_payment_date,p_entry) returning id into v_batch;
 perform sakaccounts.post_settlement_lines(v_batch,e.owner_id,e.entity_id,case when e.kind='inventory_purchase' then 'expense' else e.kind end,p_amount,e.currency,p_funding_account);
 insert into sakaccounts.settlements(owner_id,entry_id,batch_id,amount_minor,method,funding_account_id,payment_date,reference)
 values(e.owner_id,p_entry,v_batch,p_amount,case when a.kind='credit_card' then 'card' else a.kind end,p_funding_account,p_payment_date,p_reference);
 return v_batch;
end $$;

create table sakaccounts.supplier_invoices (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 entity_id uuid not null references sakaccounts.entities(id), supplier text not null,
 invoice_number text not null, invoice_date date not null, amount_minor bigint not null check(amount_minor>0),
 currency char(3) not null, attachment_path text, created_at timestamptz not null default now(),
 unique(owner_id,entity_id,supplier,invoice_number)
);
create table sakaccounts.invoice_matches (
 invoice_id uuid not null references sakaccounts.supplier_invoices(id), entry_id uuid not null references sakaccounts.ledger_entries(id),
 owner_id uuid not null references auth.users(id), allocated_minor bigint not null check(allocated_minor>0),
 primary key(invoice_id,entry_id)
);
alter table sakaccounts.supplier_invoices enable row level security;
alter table sakaccounts.invoice_matches enable row level security;
create policy invoice_read on sakaccounts.supplier_invoices for select to authenticated using(sakaccounts.can_manage(owner_id));
create policy invoice_write on sakaccounts.supplier_invoices for insert to authenticated with check(sakaccounts.can_manage(owner_id));
create policy match_read on sakaccounts.invoice_matches for select to authenticated using(sakaccounts.can_manage(owner_id));
create policy match_write on sakaccounts.invoice_matches for insert to authenticated with check(sakaccounts.can_manage(owner_id));
grant select,insert on sakaccounts.supplier_invoices,sakaccounts.invoice_matches to authenticated;

create or replace function sakaccounts.validate_invoice_match() returns trigger language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare i sakaccounts.supplier_invoices%rowtype; e sakaccounts.ledger_entries%rowtype; begin
 select * into i from sakaccounts.supplier_invoices where id=new.invoice_id;
 select * into e from sakaccounts.ledger_entries where id=new.entry_id;
 if i.owner_id<>new.owner_id or e.owner_id<>new.owner_id or i.entity_id<>e.entity_id or i.currency<>e.currency or e.kind<>'expense'
 or (select coalesce(sum(allocated_minor),0) from sakaccounts.invoice_matches where invoice_id=new.invoice_id)+new.allocated_minor>i.amount_minor
 or (select coalesce(sum(allocated_minor),0) from sakaccounts.invoice_matches where entry_id=new.entry_id)+new.allocated_minor>e.amount_minor
 then raise exception 'Invoice allocation exceeds a matching invoice or expense'; end if;
 return new;
end $$;
create trigger invoice_match_check before insert on sakaccounts.invoice_matches for each row execute function sakaccounts.validate_invoice_match();
notify pgrst,'reload schema';
