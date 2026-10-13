create table sakaccounts.accounting_adjustments (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id),
 source_entry_id uuid not null references sakaccounts.ledger_entries(id),
 batch_id uuid not null unique references sakaccounts.journal_batches(id),
 kind text not null check(kind in ('expense_refund','prepaid_release','fixed_asset_depreciation','deposit_return')),
 amount_minor bigint not null check(amount_minor>0), effective_date date not null,
 account_id uuid references sakaccounts.finance_accounts(id),
 created_at timestamptz not null default now()
);
alter table sakaccounts.accounting_adjustments enable row level security;
create policy adjustment_read on sakaccounts.accounting_adjustments for select to authenticated using(sakaccounts.can_manage(owner_id));
grant select on sakaccounts.accounting_adjustments to authenticated;

create or replace function sakaccounts.post_adjustment(p_request_id uuid,p_source uuid,p_action text,p_amount bigint,p_date date,p_account uuid default null)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare e sakaccounts.ledger_entries%rowtype; a sakaccounts.finance_accounts%rowtype; v_batch uuid; v_prior bigint; v_paid bigint; v_code text; begin
 select * into e from sakaccounts.ledger_entries where id=p_source;
 if e.id is null or not sakaccounts.can_manage(e.owner_id) or p_amount<=0 or p_date is null then raise exception 'Invalid adjustment'; end if;
 select id into v_batch from sakaccounts.journal_batches where owner_id=e.owner_id and request_id=p_request_id;
 if found then return v_batch; end if;
 if p_action='expense_refund' and e.kind not in ('expense','interest','fee') then raise exception 'Refund needs an expense'; end if;
 if p_action='prepaid_release' and e.kind<>'prepaid' then raise exception 'Release needs prepaid asset'; end if;
 if p_action='fixed_asset_depreciation' and e.kind<>'fixed_asset' then raise exception 'Depreciation needs fixed asset'; end if;
 if p_action='deposit_return' and e.kind<>'deposit' then raise exception 'Return needs deposit'; end if;
 if p_action not in ('expense_refund','prepaid_release','fixed_asset_depreciation','deposit_return') then raise exception 'Unknown adjustment'; end if;
 select coalesce(sum(amount_minor),0) into v_prior from sakaccounts.accounting_adjustments where source_entry_id=e.id;
 if v_prior+p_amount>e.amount_minor then raise exception 'Adjustment exceeds original amount'; end if;
 if p_account is not null then
  select * into a from sakaccounts.finance_accounts where id=p_account;
  if a.id is null or a.owner_id<>e.owner_id or a.entity_id<>e.entity_id or a.currency<>e.currency then raise exception 'Adjustment account mismatch'; end if;
 end if;
 if p_action='deposit_return' and (a.id is null or a.kind not in ('bank','cash')) then raise exception 'Deposit return needs bank or cash'; end if;
 if p_action in ('prepaid_release','fixed_asset_depreciation') and p_account is not null then raise exception 'Asset release has no payment account'; end if;
 if p_action='expense_refund' and p_account is null then
  select coalesce(sum(amount_minor),0) into v_paid from sakaccounts.settlements where entry_id=e.id;
  if v_paid+v_prior+p_amount>e.amount_minor then raise exception 'Unpaid credit exceeds remaining supplier payable'; end if;
 end if;
 insert into sakaccounts.journal_batches(owner_id,request_id,action,effective_date,entry_id)
 values(e.owner_id,p_request_id,p_action,p_date,e.id) returning id into v_batch;
 if p_action='expense_refund' then
  v_code:=case when a.id is null then 'supplier_payable' when a.kind='credit_card' then 'card_payable' else a.kind end;
  perform sakaccounts.line(v_batch,e.owner_id,e.entity_id,v_code,a.id,e.currency,p_amount,0);
  perform sakaccounts.line(v_batch,e.owner_id,e.entity_id,'expense',null,e.currency,0,p_amount);
 elsif p_action in ('prepaid_release','fixed_asset_depreciation') then
  perform sakaccounts.line(v_batch,e.owner_id,e.entity_id,'expense',null,e.currency,p_amount,0);
  perform sakaccounts.line(v_batch,e.owner_id,e.entity_id,case when p_action='prepaid_release' then 'prepaid' else 'fixed_asset' end,null,e.currency,0,p_amount);
 else
  perform sakaccounts.line(v_batch,e.owner_id,e.entity_id,a.kind,a.id,e.currency,p_amount,0);
  perform sakaccounts.line(v_batch,e.owner_id,e.entity_id,'deposit',null,e.currency,0,p_amount);
 end if;
 insert into sakaccounts.accounting_adjustments(owner_id,source_entry_id,batch_id,kind,amount_minor,effective_date,account_id)
 values(e.owner_id,e.id,v_batch,p_action,p_amount,p_date,p_account);
 return v_batch;
end $$;
revoke all on function sakaccounts.post_adjustment(uuid,uuid,text,bigint,date,uuid) from public,anon;
grant execute on function sakaccounts.post_adjustment(uuid,uuid,text,bigint,date,uuid) to authenticated;
notify pgrst,'reload schema';
