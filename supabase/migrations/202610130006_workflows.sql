-- Fresh-start accounting model. Existing financial tables are retained for migration history.
create table sakaccounts.entities (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 code text not null check(code in ('amazon_india','fasteners_india','it','amazon_uae','personal')),
 name text not null, currency char(3) not null check(currency in ('INR','AED')),
 unique(owner_id,code), unique(id,owner_id)
);
create table sakaccounts.finance_accounts (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 entity_id uuid not null, name text not null check(length(trim(name)) between 1 and 120),
 kind text not null check(kind in ('bank','cash','credit_card')),
 currency char(3) not null check(currency in ('INR','AED')),
 issuing_bank text, last_four char(4) check(last_four ~ '^[0-9]{4}$'),
 credit_limit_minor bigint check(credit_limit_minor >= 0),
 opening_as_of date, created_at timestamptz not null default now(),
 foreign key(entity_id,owner_id) references sakaccounts.entities(id,owner_id),
 unique(owner_id,name), unique(id,owner_id)
);
create table sakaccounts.ledger_entries (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 entity_id uuid not null, kind text not null check(kind in ('expense','income','inventory_purchase','cogs','loan_received','loan_repayment','owner_contribution','owner_draw','interest','fee')),
 incurred_date date not null, amount_minor bigint not null check(amount_minor>0),
 currency char(3) not null check(currency in ('INR','AED')),
 category text not null, subcategory text, party text, description text not null,
 reference text, attachment_path text, created_at timestamptz not null default now(),
 foreign key(entity_id,owner_id) references sakaccounts.entities(id,owner_id), unique(id,owner_id)
);
create table sakaccounts.journal_batches (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 request_id uuid not null, action text not null, effective_date date not null,
 entry_id uuid references sakaccounts.ledger_entries(id), created_at timestamptz not null default now(),
 unique(owner_id,request_id)
);
create table sakaccounts.journal_lines (
 id bigint generated always as identity primary key, batch_id uuid not null references sakaccounts.journal_batches(id),
 owner_id uuid not null references auth.users(id), entity_id uuid not null references sakaccounts.entities(id),
 ledger_code text not null check(ledger_code in ('bank','cash','card_payable','supplier_payable','receivable','revenue','expense','inventory','cogs','loan_payable','owner_equity','intercompany_due','intercompany_receivable','opening_equity')),
 account_id uuid references sakaccounts.finance_accounts(id), currency char(3) not null,
 debit_minor bigint not null default 0 check(debit_minor>=0), credit_minor bigint not null default 0 check(credit_minor>=0),
 check ((debit_minor>0) <> (credit_minor>0))
);
create table sakaccounts.settlements (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 entry_id uuid not null, batch_id uuid not null references sakaccounts.journal_batches(id),
 amount_minor bigint not null check(amount_minor>0), method text not null check(method in ('bank','cash','card','amazon_deduction')),
 funding_account_id uuid references sakaccounts.finance_accounts(id), payment_date date not null,
 reference text, created_at timestamptz not null default now(),
 foreign key(entry_id,owner_id) references sakaccounts.ledger_entries(id,owner_id)
);
create table sakaccounts.card_statements (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 account_id uuid not null references sakaccounts.finance_accounts(id), period_start date not null, period_end date not null,
 statement_date date not null, due_date date, bill_amount_minor bigint not null check(bill_amount_minor>=0),
 currency char(3) not null, created_at timestamptz not null default now(), unique(account_id,statement_date)
);
create table sakaccounts.statement_imports (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 account_id uuid not null references sakaccounts.finance_accounts(id), file_name text not null,
 file_sha256 text not null check(length(file_sha256)=64), period_start date, period_end date,
 raw_text text, created_at timestamptz not null default now(), unique(account_id,file_sha256)
);
create table sakaccounts.statement_rows (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 import_id uuid not null references sakaccounts.statement_imports(id), row_ref text not null,
 posting_date date, purchase_date date, description text, amount_minor bigint, currency char(3), raw jsonb not null,
 match_status text not null default 'unmatched' check(match_status in ('unmatched','matched','ignored','needs_review')),
 matched_batch_id uuid references sakaccounts.journal_batches(id), created_at timestamptz not null default now(),
 unique(import_id,row_ref)
);
create table sakaccounts.budgets (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 entity_id uuid not null references sakaccounts.entities(id), month date not null,
 category text not null, amount_minor bigint not null check(amount_minor>=0), currency char(3) not null,
 unique(owner_id,entity_id,month,category)
);

create or replace function sakaccounts.can_manage(p_owner uuid) returns boolean
language sql stable security definer set search_path=sakaccounts,auth,pg_temp as $$
 select exists(select 1 from sakaccounts.owner_allowlist o where o.user_id=p_owner)
 and (p_owner=auth.uid() or sakaccounts.is_super_admin())
$$;
revoke all on function sakaccounts.can_manage(uuid) from public,anon;
grant execute on function sakaccounts.can_manage(uuid) to authenticated;

do $$ declare t text; begin
 foreach t in array array['entities','finance_accounts','ledger_entries','journal_batches','journal_lines','settlements','card_statements','statement_imports','statement_rows','budgets'] loop
  execute format('alter table sakaccounts.%I enable row level security',t);
  execute format('create policy authorised_read on sakaccounts.%I for select to authenticated using (sakaccounts.can_manage(owner_id))',t);
  execute format('grant select on sakaccounts.%I to authenticated',t);
 end loop;
end $$;
create policy entity_manage on sakaccounts.entities for all to authenticated using (sakaccounts.can_manage(owner_id)) with check (sakaccounts.can_manage(owner_id));
create policy account_manage on sakaccounts.finance_accounts for all to authenticated using (sakaccounts.can_manage(owner_id)) with check (sakaccounts.can_manage(owner_id));
create policy statement_manage on sakaccounts.card_statements for all to authenticated using (sakaccounts.can_manage(owner_id)) with check (sakaccounts.can_manage(owner_id));
create policy import_manage on sakaccounts.statement_imports for all to authenticated using (sakaccounts.can_manage(owner_id)) with check (sakaccounts.can_manage(owner_id));
create policy row_manage on sakaccounts.statement_rows for all to authenticated using (sakaccounts.can_manage(owner_id)) with check (sakaccounts.can_manage(owner_id));
create policy budget_manage on sakaccounts.budgets for all to authenticated using (sakaccounts.can_manage(owner_id)) with check (sakaccounts.can_manage(owner_id));
grant insert,update on sakaccounts.entities,sakaccounts.finance_accounts,sakaccounts.card_statements,sakaccounts.statement_imports,sakaccounts.statement_rows,sakaccounts.budgets to authenticated;

create or replace function sakaccounts.check_journal_balance() returns trigger language plpgsql as $$
begin
 if exists(select 1 from sakaccounts.journal_lines where batch_id=new.batch_id group by entity_id,currency having sum(debit_minor)<>sum(credit_minor))
 then raise exception 'Unbalanced journal'; end if;
 return null;
end $$;
create constraint trigger journal_balanced after insert or update on sakaccounts.journal_lines
 deferrable initially deferred for each row execute function sakaccounts.check_journal_balance();

create or replace function sakaccounts.line(p_batch uuid,p_owner uuid,p_entity uuid,p_code text,p_account uuid,p_currency char(3),p_debit bigint,p_credit bigint)
returns void language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
begin
 insert into sakaccounts.journal_lines(batch_id,owner_id,entity_id,ledger_code,account_id,currency,debit_minor,credit_minor)
 values(p_batch,p_owner,p_entity,p_code,p_account,p_currency,p_debit,p_credit);
end $$;
revoke all on function sakaccounts.line(uuid,uuid,uuid,text,uuid,char,bigint,bigint) from public,anon,authenticated;

create or replace function sakaccounts.post_settlement_lines(p_batch uuid,p_owner uuid,p_entity uuid,p_kind text,p_amount bigint,p_currency char(3),p_account uuid)
returns void language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare a sakaccounts.finance_accounts%rowtype; v_code text; begin
 select * into a from sakaccounts.finance_accounts where id=p_account and owner_id=p_owner;
 if not found or a.currency<>p_currency or a.kind not in ('bank','cash','credit_card') then raise exception 'Invalid funding account or currency'; end if;
 v_code:=case a.kind when 'credit_card' then 'card_payable' else a.kind end;
 if p_kind='expense' then
  perform sakaccounts.line(p_batch,p_owner,p_entity,'supplier_payable',null,p_currency,p_amount,0);
  if a.entity_id=p_entity then perform sakaccounts.line(p_batch,p_owner,p_entity,v_code,p_account,p_currency,0,p_amount);
  else
   perform sakaccounts.line(p_batch,p_owner,p_entity,'intercompany_due',null,p_currency,0,p_amount);
   perform sakaccounts.line(p_batch,p_owner,a.entity_id,'intercompany_receivable',null,p_currency,p_amount,0);
   perform sakaccounts.line(p_batch,p_owner,a.entity_id,v_code,p_account,p_currency,0,p_amount);
  end if;
 elsif p_kind='income' then
  if a.kind='credit_card' then raise exception 'Income cannot be collected to a card'; end if;
  if a.entity_id=p_entity then
   perform sakaccounts.line(p_batch,p_owner,p_entity,v_code,p_account,p_currency,p_amount,0);
   perform sakaccounts.line(p_batch,p_owner,p_entity,'receivable',null,p_currency,0,p_amount);
  else
   perform sakaccounts.line(p_batch,p_owner,a.entity_id,v_code,p_account,p_currency,p_amount,0);
   perform sakaccounts.line(p_batch,p_owner,a.entity_id,'intercompany_due',null,p_currency,0,p_amount);
   perform sakaccounts.line(p_batch,p_owner,p_entity,'intercompany_receivable',null,p_currency,p_amount,0);
   perform sakaccounts.line(p_batch,p_owner,p_entity,'receivable',null,p_currency,0,p_amount);
  end if;
 else raise exception 'Entry cannot be settled by this method'; end if;
end $$;
revoke all on function sakaccounts.post_settlement_lines(uuid,uuid,uuid,text,bigint,char,uuid) from public,anon,authenticated;

create or replace function sakaccounts.post_entry(p_request_id uuid,p_owner uuid,p_entity uuid,p_kind text,p_date date,p_amount bigint,p_currency char(3),p_category text,p_subcategory text,p_party text,p_description text,p_reference text,p_payment_amount bigint default 0,p_payment_date date default null,p_funding_account uuid default null)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare v_entry uuid; v_batch uuid; v_code text; begin
 if not sakaccounts.can_manage(p_owner) then raise exception 'Access denied'; end if;
 select entry_id into v_entry from sakaccounts.journal_batches where owner_id=p_owner and request_id=p_request_id;
 if found then return v_entry; end if;
 if p_kind not in ('expense','income','inventory_purchase','cogs') or p_amount<=0 or p_payment_amount<0 or p_payment_amount>p_amount
 or p_date is null or p_currency not in ('INR','AED') or nullif(trim(p_description),'') is null
 or nullif(trim(p_category),'') is null or not exists(select 1 from sakaccounts.entities where id=p_entity and owner_id=p_owner and currency=p_currency)
 then raise exception 'Invalid entry'; end if;
 if p_kind in ('inventory_purchase','cogs') and p_payment_amount<>0 then raise exception 'Settle inventory or COGS separately'; end if;
 if p_payment_amount>0 and (p_payment_date is null or p_funding_account is null) then raise exception 'Payment details required'; end if;
 insert into sakaccounts.ledger_entries(owner_id,entity_id,kind,incurred_date,amount_minor,currency,category,subcategory,party,description,reference)
 values(p_owner,p_entity,p_kind,p_date,p_amount,p_currency,trim(p_category),nullif(trim(p_subcategory),''),nullif(trim(p_party),''),trim(p_description),p_reference) returning id into v_entry;
 insert into sakaccounts.journal_batches(owner_id,request_id,action,effective_date,entry_id)
 values(p_owner,p_request_id,'post_'||p_kind,p_date,v_entry) returning id into v_batch;
 if p_kind='expense' then
  perform sakaccounts.line(v_batch,p_owner,p_entity,'expense',null,p_currency,p_amount,0);
  perform sakaccounts.line(v_batch,p_owner,p_entity,'supplier_payable',null,p_currency,0,p_amount);
 elsif p_kind='income' then
  perform sakaccounts.line(v_batch,p_owner,p_entity,'receivable',null,p_currency,p_amount,0);
  perform sakaccounts.line(v_batch,p_owner,p_entity,'revenue',null,p_currency,0,p_amount);
 elsif p_kind='inventory_purchase' then
  perform sakaccounts.line(v_batch,p_owner,p_entity,'inventory',null,p_currency,p_amount,0);
  perform sakaccounts.line(v_batch,p_owner,p_entity,'supplier_payable',null,p_currency,0,p_amount);
 else
  perform sakaccounts.line(v_batch,p_owner,p_entity,'cogs',null,p_currency,p_amount,0);
  perform sakaccounts.line(v_batch,p_owner,p_entity,'inventory',null,p_currency,0,p_amount);
 end if;
 if p_payment_amount>0 then
  perform sakaccounts.post_settlement_lines(v_batch,p_owner,p_entity,p_kind,p_payment_amount,p_currency,p_funding_account);
  insert into sakaccounts.settlements(owner_id,entry_id,batch_id,amount_minor,method,funding_account_id,payment_date)
  select p_owner,v_entry,v_batch,p_payment_amount,case when kind='credit_card' then 'card' else kind end,p_funding_account,p_payment_date
  from sakaccounts.finance_accounts where id=p_funding_account;
 end if;
 return v_entry;
end $$;

create or replace function sakaccounts.settle_entry(p_request_id uuid,p_entry uuid,p_amount bigint,p_payment_date date,p_funding_account uuid,p_reference text default null)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare e sakaccounts.ledger_entries%rowtype; a sakaccounts.finance_accounts%rowtype; v_batch uuid; v_paid bigint; begin
 select * into e from sakaccounts.ledger_entries where id=p_entry;
 if not found or not sakaccounts.can_manage(e.owner_id) then raise exception 'Access denied'; end if;
 select id into v_batch from sakaccounts.journal_batches where owner_id=e.owner_id and request_id=p_request_id;
 if found then return v_batch; end if;
 select coalesce(sum(amount_minor),0) into v_paid from sakaccounts.settlements where entry_id=p_entry;
 if e.kind not in ('expense','income') or p_amount<=0 or v_paid+p_amount>e.amount_minor or p_payment_date is null then raise exception 'Invalid or excessive settlement'; end if;
 select * into a from sakaccounts.finance_accounts where id=p_funding_account and owner_id=e.owner_id;
 if not found then raise exception 'Funding account not found'; end if;
 insert into sakaccounts.journal_batches(owner_id,request_id,action,effective_date,entry_id)
 values(e.owner_id,p_request_id,'settle_'||e.kind,p_payment_date,p_entry) returning id into v_batch;
 perform sakaccounts.post_settlement_lines(v_batch,e.owner_id,e.entity_id,e.kind,p_amount,e.currency,p_funding_account);
 insert into sakaccounts.settlements(owner_id,entry_id,batch_id,amount_minor,method,funding_account_id,payment_date,reference)
 values(e.owner_id,p_entry,v_batch,p_amount,case when a.kind='credit_card' then 'card' else a.kind end,p_funding_account,p_payment_date,p_reference);
 return v_batch;
end $$;

create or replace function sakaccounts.post_card_repayment_v2(p_request_id uuid,p_card uuid,p_bank uuid,p_amount bigint,p_date date)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare c sakaccounts.finance_accounts%rowtype; b sakaccounts.finance_accounts%rowtype; v_batch uuid; begin
 select * into c from sakaccounts.finance_accounts where id=p_card;
 select * into b from sakaccounts.finance_accounts where id=p_bank;
 if not sakaccounts.can_manage(c.owner_id) or c.kind<>'credit_card' or b.kind not in ('bank','cash') or c.owner_id<>b.owner_id or c.currency<>b.currency or p_amount<=0 or p_date is null then raise exception 'Invalid repayment'; end if;
 select id into v_batch from sakaccounts.journal_batches where owner_id=c.owner_id and request_id=p_request_id;
 if found then return v_batch; end if;
 insert into sakaccounts.journal_batches(owner_id,request_id,action,effective_date) values(c.owner_id,p_request_id,'card_repayment',p_date) returning id into v_batch;
 if c.entity_id=b.entity_id then
  perform sakaccounts.line(v_batch,c.owner_id,c.entity_id,'card_payable',c.id,c.currency,p_amount,0);
  perform sakaccounts.line(v_batch,c.owner_id,b.entity_id,b.kind,b.id,b.currency,0,p_amount);
 else
  perform sakaccounts.line(v_batch,c.owner_id,c.entity_id,'card_payable',c.id,c.currency,p_amount,0);
  perform sakaccounts.line(v_batch,c.owner_id,c.entity_id,'intercompany_due',null,c.currency,0,p_amount);
  perform sakaccounts.line(v_batch,c.owner_id,b.entity_id,'intercompany_receivable',null,b.currency,p_amount,0);
  perform sakaccounts.line(v_batch,c.owner_id,b.entity_id,b.kind,b.id,b.currency,0,p_amount);
 end if;
 return v_batch;
end $$;

create or replace function sakaccounts.post_transfer_v2(p_request_id uuid,p_source uuid,p_destination uuid,p_amount bigint,p_date date)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare s sakaccounts.finance_accounts%rowtype; d sakaccounts.finance_accounts%rowtype; v_batch uuid; begin
 select * into s from sakaccounts.finance_accounts where id=p_source;
 select * into d from sakaccounts.finance_accounts where id=p_destination;
 if not sakaccounts.can_manage(s.owner_id) or s.kind not in ('bank','cash') or d.kind not in ('bank','cash') or s.owner_id<>d.owner_id or s.currency<>d.currency or s.id=d.id or p_amount<=0 or p_date is null then raise exception 'Invalid transfer'; end if;
 select id into v_batch from sakaccounts.journal_batches where owner_id=s.owner_id and request_id=p_request_id;
 if found then return v_batch; end if;
 insert into sakaccounts.journal_batches(owner_id,request_id,action,effective_date) values(s.owner_id,p_request_id,'transfer',p_date) returning id into v_batch;
 if s.entity_id=d.entity_id then
  perform sakaccounts.line(v_batch,s.owner_id,s.entity_id,d.kind,d.id,d.currency,p_amount,0);
  perform sakaccounts.line(v_batch,s.owner_id,s.entity_id,s.kind,s.id,s.currency,0,p_amount);
 else
  perform sakaccounts.line(v_batch,s.owner_id,d.entity_id,d.kind,d.id,d.currency,p_amount,0);
  perform sakaccounts.line(v_batch,s.owner_id,d.entity_id,'intercompany_due',null,d.currency,0,p_amount);
  perform sakaccounts.line(v_batch,s.owner_id,s.entity_id,'intercompany_receivable',null,s.currency,p_amount,0);
  perform sakaccounts.line(v_batch,s.owner_id,s.entity_id,s.kind,s.id,s.currency,0,p_amount);
 end if;
 return v_batch;
end $$;

create or replace function sakaccounts.post_amazon_net_receipt(p_request_id uuid,p_income uuid,p_expense uuid,p_bank uuid,p_net bigint,p_date date)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare i sakaccounts.ledger_entries%rowtype; e sakaccounts.ledger_entries%rowtype; b sakaccounts.finance_accounts%rowtype; v_due_income bigint; v_due_expense bigint; v_batch uuid; begin
 select * into i from sakaccounts.ledger_entries where id=p_income;
 select * into e from sakaccounts.ledger_entries where id=p_expense;
 select * into b from sakaccounts.finance_accounts where id=p_bank;
 if not sakaccounts.can_manage(i.owner_id) or i.kind<>'income' or e.kind<>'expense' or i.owner_id<>e.owner_id or i.entity_id<>e.entity_id or b.owner_id<>i.owner_id or b.entity_id<>i.entity_id or b.kind not in ('bank','cash') or i.currency<>e.currency or i.currency<>b.currency or p_net<0 or p_date is null then raise exception 'Invalid net settlement'; end if;
 select id into v_batch from sakaccounts.journal_batches where owner_id=i.owner_id and request_id=p_request_id;
 if found then return v_batch; end if;
 select i.amount_minor-coalesce(sum(amount_minor),0) into v_due_income from sakaccounts.settlements where entry_id=i.id;
 select e.amount_minor-coalesce(sum(amount_minor),0) into v_due_expense from sakaccounts.settlements where entry_id=e.id;
 if v_due_income<>p_net+v_due_expense or v_due_expense<=0 then raise exception 'Net receipt does not reconcile to receivable and payable'; end if;
 insert into sakaccounts.journal_batches(owner_id,request_id,action,effective_date) values(i.owner_id,p_request_id,'amazon_net_receipt',p_date) returning id into v_batch;
 perform sakaccounts.line(v_batch,i.owner_id,i.entity_id,b.kind,b.id,b.currency,p_net,0);
 perform sakaccounts.line(v_batch,i.owner_id,i.entity_id,'supplier_payable',null,i.currency,v_due_expense,0);
 perform sakaccounts.line(v_batch,i.owner_id,i.entity_id,'receivable',null,i.currency,0,v_due_income);
 insert into sakaccounts.settlements(owner_id,entry_id,batch_id,amount_minor,method,funding_account_id,payment_date)
 values(i.owner_id,i.id,v_batch,v_due_income,'amazon_deduction',b.id,p_date),
       (i.owner_id,e.id,v_batch,v_due_expense,'amazon_deduction',null,p_date);
 return v_batch;
end $$;

grant execute on function sakaccounts.post_entry(uuid,uuid,uuid,text,date,bigint,char,text,text,text,text,text,bigint,date,uuid),
 sakaccounts.settle_entry(uuid,uuid,bigint,date,uuid,text),sakaccounts.post_card_repayment_v2(uuid,uuid,uuid,bigint,date),
 sakaccounts.post_transfer_v2(uuid,uuid,uuid,bigint,date),sakaccounts.post_amazon_net_receipt(uuid,uuid,uuid,uuid,bigint,date) to authenticated;
revoke all on all functions in schema sakaccounts from anon;
notify pgrst,'reload schema';
