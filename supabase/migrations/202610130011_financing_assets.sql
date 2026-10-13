-- Add nonoperating assets and financing without changing the earlier migrations.
alter table sakaccounts.ledger_entries drop constraint ledger_entries_kind_check;
alter table sakaccounts.ledger_entries add constraint ledger_entries_kind_check
 check(kind in ('expense','income','inventory_purchase','cogs','loan_received','loan_repayment','owner_contribution','owner_draw','interest','fee','prepaid','deposit','fixed_asset'));
alter table sakaccounts.journal_lines drop constraint journal_lines_ledger_code_check;
alter table sakaccounts.journal_lines add constraint journal_lines_ledger_code_check
 check(ledger_code in ('bank','cash','card_payable','supplier_payable','receivable','revenue','expense','inventory','cogs','loan_payable','owner_equity','intercompany_due','intercompany_receivable','opening_equity','prepaid','deposit','fixed_asset'));
create or replace function sakaccounts.post_entry(p_request_id uuid,p_owner uuid,p_entity uuid,p_kind text,p_date date,p_amount bigint,p_currency char(3),p_category text,p_subcategory text,p_party text,p_description text,p_reference text,p_payment_amount bigint default 0,p_payment_date date default null,p_funding_account uuid default null)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare v_entry uuid; v_batch uuid; v_code text; begin
 if not sakaccounts.can_manage(p_owner) then raise exception 'Access denied'; end if;
 select entry_id into v_entry from sakaccounts.journal_batches where owner_id=p_owner and request_id=p_request_id;
 if found then return v_entry; end if;
 if p_kind not in ('expense','income','inventory_purchase','cogs','prepaid','deposit','fixed_asset','interest','fee') or p_amount<=0 or p_payment_amount<0 or p_payment_amount>p_amount
 or p_date is null or p_currency not in ('INR','AED') or nullif(trim(p_description),'') is null
 or nullif(trim(p_category),'') is null or not exists(select 1 from sakaccounts.entities where id=p_entity and owner_id=p_owner and currency=p_currency)
 then raise exception 'Invalid entry'; end if;
 if p_kind='cogs' and p_payment_amount<>0 then raise exception 'COGS has no supplier settlement'; end if;
 if p_payment_amount>0 and (p_payment_date is null or p_funding_account is null) then raise exception 'Payment details required'; end if;
 insert into sakaccounts.ledger_entries(owner_id,entity_id,kind,incurred_date,amount_minor,currency,category,subcategory,party,description,reference)
 values(p_owner,p_entity,p_kind,p_date,p_amount,p_currency,trim(p_category),nullif(trim(p_subcategory),''),nullif(trim(p_party),''),trim(p_description),p_reference) returning id into v_entry;
 insert into sakaccounts.journal_batches(owner_id,request_id,action,effective_date,entry_id)
 values(p_owner,p_request_id,'post_'||p_kind,p_date,v_entry) returning id into v_batch;
 if p_kind in ('expense','interest','fee') then
  perform sakaccounts.line(v_batch,p_owner,p_entity,'expense',null,p_currency,p_amount,0);
  perform sakaccounts.line(v_batch,p_owner,p_entity,'supplier_payable',null,p_currency,0,p_amount);
 elsif p_kind='income' then
  perform sakaccounts.line(v_batch,p_owner,p_entity,'receivable',null,p_currency,p_amount,0);
  perform sakaccounts.line(v_batch,p_owner,p_entity,'revenue',null,p_currency,0,p_amount);
 elsif p_kind in ('inventory_purchase','prepaid','deposit','fixed_asset') then
  perform sakaccounts.line(v_batch,p_owner,p_entity,case when p_kind='inventory_purchase' then 'inventory' else p_kind end,null,p_currency,p_amount,0);
  perform sakaccounts.line(v_batch,p_owner,p_entity,'supplier_payable',null,p_currency,0,p_amount);
 else
  perform sakaccounts.line(v_batch,p_owner,p_entity,'cogs',null,p_currency,p_amount,0);
  perform sakaccounts.line(v_batch,p_owner,p_entity,'inventory',null,p_currency,0,p_amount);
 end if;
 if p_payment_amount>0 then
  perform sakaccounts.post_settlement_lines(v_batch,p_owner,p_entity,case when p_kind='income' then 'income' else 'expense' end,p_payment_amount,p_currency,p_funding_account);
  insert into sakaccounts.settlements(owner_id,entry_id,batch_id,amount_minor,method,funding_account_id,payment_date)
  select p_owner,v_entry,v_batch,p_payment_amount,case when kind='credit_card' then 'card' else kind end,p_funding_account,p_payment_date
  from sakaccounts.finance_accounts where id=p_funding_account;
 end if;
 return v_entry;
end $$;

create or replace function sakaccounts.post_financing(p_request_id uuid,p_owner uuid,p_entity uuid,p_kind text,p_date date,p_amount bigint,p_currency char(3),p_bank uuid,p_description text)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare a sakaccounts.finance_accounts%rowtype; v_entry uuid; v_batch uuid; v_liability bigint; begin
 if not sakaccounts.can_manage(p_owner) then raise exception 'Access denied'; end if;
 select entry_id into v_entry from sakaccounts.journal_batches where owner_id=p_owner and request_id=p_request_id;
 if found then return v_entry; end if;
 select * into a from sakaccounts.finance_accounts where id=p_bank;
 if a.id is null or a.owner_id<>p_owner or a.entity_id<>p_entity or a.currency<>p_currency or a.kind not in ('bank','cash')
 or p_kind not in ('loan_received','loan_repayment','owner_contribution','owner_draw') or p_amount<=0 or p_date is null or nullif(trim(p_description),'') is null
 then raise exception 'Invalid financing entry'; end if;
 if p_kind='loan_repayment' then
  select coalesce(sum(credit_minor-debit_minor),0) into v_liability from sakaccounts.journal_lines
   where owner_id=p_owner and entity_id=p_entity and currency=p_currency and ledger_code='loan_payable';
  if p_amount>v_liability then raise exception 'Loan repayment exceeds recorded principal'; end if;
 end if;
 insert into sakaccounts.ledger_entries(owner_id,entity_id,kind,incurred_date,amount_minor,currency,category,description)
 values(p_owner,p_entity,p_kind,p_date,p_amount,p_currency,'Financing',trim(p_description)) returning id into v_entry;
 insert into sakaccounts.journal_batches(owner_id,request_id,action,effective_date,entry_id)
 values(p_owner,p_request_id,p_kind,p_date,v_entry) returning id into v_batch;
 if p_kind='loan_received' then
  perform sakaccounts.line(v_batch,p_owner,p_entity,a.kind,a.id,p_currency,p_amount,0);
  perform sakaccounts.line(v_batch,p_owner,p_entity,'loan_payable',null,p_currency,0,p_amount);
 elsif p_kind='loan_repayment' then
  perform sakaccounts.line(v_batch,p_owner,p_entity,'loan_payable',null,p_currency,p_amount,0);
  perform sakaccounts.line(v_batch,p_owner,p_entity,a.kind,a.id,p_currency,0,p_amount);
 elsif p_kind='owner_contribution' then
  perform sakaccounts.line(v_batch,p_owner,p_entity,a.kind,a.id,p_currency,p_amount,0);
  perform sakaccounts.line(v_batch,p_owner,p_entity,'owner_equity',null,p_currency,0,p_amount);
 else
  perform sakaccounts.line(v_batch,p_owner,p_entity,'owner_equity',null,p_currency,p_amount,0);
  perform sakaccounts.line(v_batch,p_owner,p_entity,a.kind,a.id,p_currency,0,p_amount);
 end if;
 return v_entry;
end $$;
revoke all on function sakaccounts.post_financing(uuid,uuid,uuid,text,date,bigint,char,uuid,text) from public,anon;
grant execute on function sakaccounts.post_financing(uuid,uuid,uuid,text,date,bigint,char,uuid,text) to authenticated;

create or replace function sakaccounts.settle_entry(p_request_id uuid,p_entry uuid,p_amount bigint,p_payment_date date,p_funding_account uuid,p_reference text default null)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare e sakaccounts.ledger_entries%rowtype; a sakaccounts.finance_accounts%rowtype; v_batch uuid; v_paid bigint; begin
 select * into e from sakaccounts.ledger_entries where id=p_entry;
 if not found or not sakaccounts.can_manage(e.owner_id) then raise exception 'Access denied'; end if;
 select id into v_batch from sakaccounts.journal_batches where owner_id=e.owner_id and request_id=p_request_id;
 if found then return v_batch; end if;
 select coalesce(sum(amount_minor),0) into v_paid from sakaccounts.settlements where entry_id=p_entry;
 if e.kind not in ('expense','income','inventory_purchase','prepaid','deposit','fixed_asset','interest','fee') or p_amount<=0 or v_paid+p_amount>e.amount_minor or p_payment_date is null then raise exception 'Invalid or excessive settlement'; end if;
 select * into a from sakaccounts.finance_accounts where id=p_funding_account and owner_id=e.owner_id;
 if not found then raise exception 'Funding account not found'; end if;
 insert into sakaccounts.journal_batches(owner_id,request_id,action,effective_date,entry_id)
 values(e.owner_id,p_request_id,'settle_'||e.kind,p_payment_date,p_entry) returning id into v_batch;
 perform sakaccounts.post_settlement_lines(v_batch,e.owner_id,e.entity_id,case when e.kind='income' then 'income' else 'expense' end,p_amount,e.currency,p_funding_account);
 insert into sakaccounts.settlements(owner_id,entry_id,batch_id,amount_minor,method,funding_account_id,payment_date,reference)
 values(e.owner_id,p_entry,v_batch,p_amount,case when a.kind='credit_card' then 'card' else a.kind end,p_funding_account,p_payment_date,p_reference);
 return v_batch;
end $$;
notify pgrst,'reload schema';

