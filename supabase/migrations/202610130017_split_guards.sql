-- Split entries must be settled through their allocation-aware function.
create or replace function sakaccounts.settle_entry(p_request_id uuid,p_entry uuid,p_amount bigint,p_payment_date date,p_funding_account uuid,p_reference text default null)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare e sakaccounts.ledger_entries%rowtype; a sakaccounts.finance_accounts%rowtype; v_batch uuid; v_paid bigint; begin
 select * into e from sakaccounts.ledger_entries where id=p_entry;
 if not found or not sakaccounts.can_manage(e.owner_id) then raise exception 'Access denied'; end if;
 if exists(select 1 from sakaccounts.entry_allocations where entry_id=e.id) then raise exception 'Use split settlement for this entry'; end if;
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
create or replace function sakaccounts.post_amazon_net_receipt(p_request_id uuid,p_income uuid,p_expense uuid,p_bank uuid,p_net bigint,p_date date)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare i sakaccounts.ledger_entries%rowtype; e sakaccounts.ledger_entries%rowtype; b sakaccounts.finance_accounts%rowtype; v_due_income bigint; v_due_expense bigint; v_batch uuid; begin
 select * into i from sakaccounts.ledger_entries where id=p_income;
 select * into e from sakaccounts.ledger_entries where id=p_expense;
 select * into b from sakaccounts.finance_accounts where id=p_bank;
 if exists(select 1 from sakaccounts.entry_allocations where entry_id=e.id) or not sakaccounts.can_manage(i.owner_id) or i.kind<>'income' or e.kind<>'expense' or i.owner_id<>e.owner_id or i.entity_id<>e.entity_id or b.owner_id<>i.owner_id or b.entity_id<>i.entity_id or b.kind not in ('bank','cash') or i.currency<>e.currency or i.currency<>b.currency or p_net<0 or p_date is null then raise exception 'Invalid net settlement'; end if;
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
notify pgrst,'reload schema';
