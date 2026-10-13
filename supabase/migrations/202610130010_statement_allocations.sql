create table sakaccounts.statement_repayment_allocations (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 statement_id uuid not null references sakaccounts.card_statements(id),
 repayment_batch_id uuid not null references sakaccounts.journal_batches(id),
 amount_minor bigint not null check(amount_minor>0), created_at timestamptz not null default now(),
 unique(statement_id,repayment_batch_id)
);
alter table sakaccounts.statement_repayment_allocations enable row level security;
create policy allocation_read on sakaccounts.statement_repayment_allocations for select to authenticated using(sakaccounts.can_manage(owner_id));
grant select on sakaccounts.statement_repayment_allocations to authenticated;

create or replace function sakaccounts.allocate_card_repayment(p_statement uuid,p_batch uuid,p_amount bigint)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare s sakaccounts.card_statements%rowtype; b sakaccounts.journal_batches%rowtype; v_used bigint; v_payment bigint; v_id uuid; begin
 select * into s from sakaccounts.card_statements where id=p_statement;
 select * into b from sakaccounts.journal_batches where id=p_batch;
 if s.id is null or b.id is null or not sakaccounts.can_manage(s.owner_id) or b.owner_id<>s.owner_id or b.action<>'card_repayment' or p_amount<=0
 or not exists(select 1 from sakaccounts.journal_lines where batch_id=b.id and account_id=s.account_id and ledger_code='card_payable')
 then raise exception 'Invalid card statement allocation'; end if;
 select coalesce(sum(amount_minor),0) into v_used from sakaccounts.statement_repayment_allocations where statement_id=s.id;
 if v_used+p_amount>s.bill_amount_minor then raise exception 'Allocation exceeds statement bill'; end if;
 select coalesce(sum(debit_minor),0) into v_payment from sakaccounts.journal_lines where batch_id=b.id and account_id=s.account_id and ledger_code='card_payable';
 select coalesce(sum(amount_minor),0) into v_used from sakaccounts.statement_repayment_allocations where repayment_batch_id=b.id;
 if v_used+p_amount>v_payment then raise exception 'Allocation exceeds repayment'; end if;
 insert into sakaccounts.statement_repayment_allocations(owner_id,statement_id,repayment_batch_id,amount_minor)
 values(s.owner_id,s.id,b.id,p_amount) returning id into v_id;
 return v_id;
end $$;
revoke all on function sakaccounts.allocate_card_repayment(uuid,uuid,bigint) from public,anon;
grant execute on function sakaccounts.allocate_card_repayment(uuid,uuid,bigint) to authenticated;

-- Imported source cells cannot be silently rewritten after staging.
revoke update on sakaccounts.statement_rows from authenticated;
grant update(match_status,matched_batch_id,posting_date,purchase_date,description,amount_minor) on sakaccounts.statement_rows to authenticated;

-- Restrict negative inventory when a cost-of-goods journal consumes stock.
create or replace function sakaccounts.inventory_available() returns trigger language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare v_balance bigint; begin
 if new.ledger_code='inventory' and new.credit_minor>0 then
  select coalesce(sum(debit_minor-credit_minor),0) into v_balance from sakaccounts.journal_lines
   where owner_id=new.owner_id and entity_id=new.entity_id and currency=new.currency and ledger_code='inventory';
  if v_balance<new.credit_minor then raise exception 'Cost of goods exceeds available inventory cost'; end if;
 end if;
 return new;
end $$;
create trigger inventory_cost_check before insert on sakaccounts.journal_lines for each row execute function sakaccounts.inventory_available();
notify pgrst,'reload schema';
