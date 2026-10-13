create table sakaccounts.reimbursements (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 expense_id uuid not null references sakaccounts.ledger_entries(id), batch_id uuid not null references sakaccounts.journal_batches(id),
 amount_minor bigint not null check(amount_minor>0), reimbursement_date date not null
);
alter table sakaccounts.reimbursements enable row level security;
create policy reimbursement_read on sakaccounts.reimbursements for select to authenticated using(sakaccounts.can_manage(owner_id));
grant select on sakaccounts.reimbursements to authenticated;

create or replace function sakaccounts.post_reimbursement(p_request_id uuid,p_expense uuid,p_from_bank uuid,p_to_bank uuid,p_amount bigint,p_date date)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare e sakaccounts.ledger_entries%rowtype; f sakaccounts.finance_accounts%rowtype; t sakaccounts.finance_accounts%rowtype; v_batch uuid; v_cross bigint; v_reimbursed bigint; begin
 select * into e from sakaccounts.ledger_entries where id=p_expense;
 select * into f from sakaccounts.finance_accounts where id=p_from_bank;
 select * into t from sakaccounts.finance_accounts where id=p_to_bank;
 if e.id is null or f.id is null or t.id is null or not sakaccounts.can_manage(e.owner_id) or e.kind<>'expense' or f.owner_id<>e.owner_id or t.owner_id<>e.owner_id
 or f.entity_id<>e.entity_id or t.entity_id=e.entity_id or f.kind not in ('bank','cash') or t.kind not in ('bank','cash')
 or f.currency<>e.currency or t.currency<>e.currency or p_amount<=0 or p_date is null then raise exception 'Invalid reimbursement'; end if;
 select id into v_batch from sakaccounts.journal_batches where owner_id=e.owner_id and request_id=p_request_id;
 if found then return v_batch; end if;
 select coalesce(sum(s.amount_minor),0) into v_cross from sakaccounts.settlements s
 join sakaccounts.finance_accounts a on a.id=s.funding_account_id
 where s.entry_id=e.id and a.entity_id=t.entity_id;
 select coalesce(sum(amount_minor),0) into v_reimbursed from sakaccounts.reimbursements where expense_id=e.id;
 if p_amount+v_reimbursed>v_cross then raise exception 'Reimbursement exceeds cross-entity funding'; end if;
 insert into sakaccounts.journal_batches(owner_id,request_id,action,effective_date,entry_id)
 values(e.owner_id,p_request_id,'reimbursement',p_date,e.id) returning id into v_batch;
 perform sakaccounts.line(v_batch,e.owner_id,e.entity_id,'intercompany_due',null,e.currency,p_amount,0);
 perform sakaccounts.line(v_batch,e.owner_id,e.entity_id,f.kind,f.id,e.currency,0,p_amount);
 perform sakaccounts.line(v_batch,e.owner_id,t.entity_id,t.kind,t.id,e.currency,p_amount,0);
 perform sakaccounts.line(v_batch,e.owner_id,t.entity_id,'intercompany_receivable',null,e.currency,0,p_amount);
 insert into sakaccounts.reimbursements(owner_id,expense_id,batch_id,amount_minor,reimbursement_date)
 values(e.owner_id,e.id,v_batch,p_amount,p_date);
 return v_batch;
end $$;
revoke all on function sakaccounts.post_reimbursement(uuid,uuid,uuid,uuid,bigint,date) from public,anon;
grant execute on function sakaccounts.post_reimbursement(uuid,uuid,uuid,uuid,bigint,date) to authenticated;
notify pgrst,'reload schema';
