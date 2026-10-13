create table sakaccounts.entry_allocations (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 entry_id uuid not null references sakaccounts.ledger_entries(id), entity_id uuid not null references sakaccounts.entities(id),
 category text not null, amount_minor bigint not null check(amount_minor>0), created_at timestamptz not null default now()
);
create table sakaccounts.settlement_allocations (
 settlement_id uuid not null references sakaccounts.settlements(id), allocation_id uuid not null references sakaccounts.entry_allocations(id),
 owner_id uuid not null references auth.users(id), amount_minor bigint not null check(amount_minor>0),
 primary key(settlement_id,allocation_id)
);
alter table sakaccounts.entry_allocations enable row level security;
alter table sakaccounts.settlement_allocations enable row level security;
create policy entry_allocation_read on sakaccounts.entry_allocations for select to authenticated using(sakaccounts.can_manage(owner_id));
create policy settlement_allocation_read on sakaccounts.settlement_allocations for select to authenticated using(sakaccounts.can_manage(owner_id));
grant select on sakaccounts.entry_allocations,sakaccounts.settlement_allocations to authenticated;

create or replace function sakaccounts.post_split_expense(p_request_id uuid,p_owner uuid,p_date date,p_currency char(3),p_party text,p_description text,p_reference text,p_due_date date,p_allocations jsonb)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare v_entry uuid; v_batch uuid; v_row jsonb; v_entity uuid; v_category text; v_amount bigint; v_total bigint:=0; v_first uuid; begin
 if not sakaccounts.can_manage(p_owner) or p_date is null or p_currency not in ('INR','AED')
 or nullif(trim(p_description),'') is null or jsonb_typeof(p_allocations)<>'array' or jsonb_array_length(p_allocations) not between 2 and 20
 then raise exception 'Invalid split expense'; end if;
 select entry_id into v_entry from sakaccounts.journal_batches where owner_id=p_owner and request_id=p_request_id;
 if found then return v_entry; end if;
 for v_row in select value from jsonb_array_elements(p_allocations) loop
  v_entity:=(v_row->>'entity_id')::uuid; v_category:=nullif(trim(v_row->>'category'),''); v_amount:=(v_row->>'amount_minor')::bigint;
  if v_category is null or v_amount<=0 or not exists(select 1 from sakaccounts.entities where id=v_entity and owner_id=p_owner and currency=p_currency)
  then raise exception 'Invalid split allocation'; end if;
  if v_first is null then v_first:=v_entity; end if;
  v_total:=v_total+v_amount;
 end loop;
 insert into sakaccounts.ledger_entries(owner_id,entity_id,kind,incurred_date,due_date,amount_minor,currency,category,party,description,reference)
 values(p_owner,v_first,'expense',p_date,p_due_date,v_total,p_currency,'Split allocation',nullif(trim(p_party),''),trim(p_description),p_reference)
 returning id into v_entry;
 insert into sakaccounts.journal_batches(owner_id,request_id,action,effective_date,entry_id)
 values(p_owner,p_request_id,'post_split_expense',p_date,v_entry) returning id into v_batch;
 for v_row in select value from jsonb_array_elements(p_allocations) loop
  v_entity:=(v_row->>'entity_id')::uuid;v_category:=trim(v_row->>'category');v_amount:=(v_row->>'amount_minor')::bigint;
  insert into sakaccounts.entry_allocations(owner_id,entry_id,entity_id,category,amount_minor)
  values(p_owner,v_entry,v_entity,v_category,v_amount);
  perform sakaccounts.line(v_batch,p_owner,v_entity,'expense',null,p_currency,v_amount,0);
  perform sakaccounts.line(v_batch,p_owner,v_entity,'supplier_payable',null,p_currency,0,v_amount);
 end loop;
 return v_entry;
end $$;

create or replace function sakaccounts.settle_split_expense(p_request_id uuid,p_entry uuid,p_date date,p_funding_account uuid,p_allocations jsonb)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare e sakaccounts.ledger_entries%rowtype; a sakaccounts.entry_allocations%rowtype; f sakaccounts.finance_accounts%rowtype; v_row jsonb; v_amount bigint; v_total bigint:=0; v_batch uuid; v_settlement uuid; v_prior bigint; begin
 select * into e from sakaccounts.ledger_entries where id=p_entry;
 select * into f from sakaccounts.finance_accounts where id=p_funding_account;
 if e.id is null or not sakaccounts.can_manage(e.owner_id) or f.id is null or f.owner_id<>e.owner_id or f.currency<>e.currency
 or p_date is null or jsonb_typeof(p_allocations)<>'array' or jsonb_array_length(p_allocations)<1 then raise exception 'Invalid split settlement'; end if;
 select id into v_batch from sakaccounts.journal_batches where owner_id=e.owner_id and request_id=p_request_id;
 if found then return v_batch; end if;
 if not exists(select 1 from sakaccounts.entry_allocations where entry_id=e.id) then raise exception 'Entry has no split allocations'; end if;
 insert into sakaccounts.journal_batches(owner_id,request_id,action,effective_date,entry_id)
 values(e.owner_id,p_request_id,'settle_split_expense',p_date,e.id) returning id into v_batch;
 for v_row in select value from jsonb_array_elements(p_allocations) loop
  select * into a from sakaccounts.entry_allocations where id=(v_row->>'allocation_id')::uuid and entry_id=e.id;
  v_amount:=(v_row->>'amount_minor')::bigint;
  if a.id is null or v_amount<=0 then raise exception 'Invalid split settlement line'; end if;
  select coalesce(sum(amount_minor),0) into v_prior from sakaccounts.settlement_allocations where allocation_id=a.id;
  if v_prior+v_amount>a.amount_minor then raise exception 'Split settlement exceeds allocation remainder'; end if;
  v_total:=v_total+v_amount;
  perform sakaccounts.post_settlement_lines(v_batch,e.owner_id,a.entity_id,'expense',v_amount,e.currency,f.id);
 end loop;
 if v_total<=0 or v_total>(e.amount_minor-(select coalesce(sum(amount_minor),0) from sakaccounts.settlements where entry_id=e.id)) then raise exception 'Split settlement exceeds expense remainder'; end if;
 insert into sakaccounts.settlements(owner_id,entry_id,batch_id,amount_minor,method,funding_account_id,payment_date)
 values(e.owner_id,e.id,v_batch,v_total,case when f.kind='credit_card' then 'card' else f.kind end,f.id,p_date)
 returning id into v_settlement;
 for v_row in select value from jsonb_array_elements(p_allocations) loop
  insert into sakaccounts.settlement_allocations(settlement_id,allocation_id,owner_id,amount_minor)
  values(v_settlement,(v_row->>'allocation_id')::uuid,e.owner_id,(v_row->>'amount_minor')::bigint);
 end loop;
 return v_batch;
end $$;
revoke all on function sakaccounts.post_split_expense(uuid,uuid,date,char,text,text,text,date,jsonb),sakaccounts.settle_split_expense(uuid,uuid,date,uuid,jsonb) from public,anon;
grant execute on function sakaccounts.post_split_expense(uuid,uuid,date,char,text,text,text,date,jsonb),sakaccounts.settle_split_expense(uuid,uuid,date,uuid,jsonb) to authenticated;
notify pgrst,'reload schema';
