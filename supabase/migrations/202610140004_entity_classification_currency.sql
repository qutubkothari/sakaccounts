-- Entities classify who owns an expense; transaction and card currencies are recorded
-- on journal lines. This permits, for example, an INR card expense assigned to Amazon UAE
-- while the original AED merchant amount remains on ledger_entries.
create or replace function sakaccounts.post_entry(
 p_request_id uuid,p_owner uuid,p_entity uuid,p_kind text,p_date date,p_amount bigint,p_currency char(3),
 p_category text,p_subcategory text,p_party text,p_description text,p_reference text,
 p_payment_amount bigint default 0,p_payment_date date default null,p_funding_account uuid default null
) returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare v_entry uuid; v_batch uuid; begin
 if not sakaccounts.can_manage(p_owner) then raise exception 'Access denied'; end if;
 select entry_id into v_entry from sakaccounts.journal_batches where owner_id=p_owner and request_id=p_request_id;
 if found then return v_entry; end if;
 if p_kind not in ('expense','income','inventory_purchase','cogs','prepaid','deposit','fixed_asset','interest','fee')
 or p_amount<=0 or p_payment_amount<0 or p_payment_amount>p_amount
 or p_date is null or p_currency not in ('INR','AED') or nullif(trim(p_description),'') is null
 or nullif(trim(p_category),'') is null
 or not exists(select 1 from sakaccounts.entities where id=p_entity and owner_id=p_owner)
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
revoke all on function sakaccounts.post_entry(uuid,uuid,uuid,text,date,bigint,char,text,text,text,text,text,bigint,date,uuid) from public,anon;
grant execute on function sakaccounts.post_entry(uuid,uuid,uuid,text,date,bigint,char,text,text,text,text,text,bigint,date,uuid) to authenticated;
notify pgrst,'reload schema';
