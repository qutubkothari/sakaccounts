-- Journal-producing account setup must use create_finance_account.
revoke insert,update on sakaccounts.finance_accounts from authenticated;
grant update(name,issuing_bank,last_four,credit_limit_minor) on sakaccounts.finance_accounts to authenticated;
revoke insert,update on sakaccounts.entities from authenticated;
grant update(name) on sakaccounts.entities to authenticated;

-- Statement source rows are inserted only by the atomic staging RPC.
revoke insert,update on sakaccounts.statement_imports from authenticated;
revoke insert on sakaccounts.statement_rows from authenticated;
revoke update on sakaccounts.card_statements from authenticated;

create or replace function sakaccounts.validate_card_statement() returns trigger language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare a sakaccounts.finance_accounts%rowtype; begin
 select * into a from sakaccounts.finance_accounts where id=new.account_id;
 if a.id is null or a.owner_id<>new.owner_id or a.kind<>'credit_card' or a.currency<>new.currency
 or new.period_start>new.period_end or new.statement_date<new.period_end then raise exception 'Invalid card statement'; end if;
 return new;
end $$;
create trigger card_statement_check before insert on sakaccounts.card_statements for each row execute function sakaccounts.validate_card_statement();

create or replace function sakaccounts.prevent_card_overpayment() returns trigger language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare v_due bigint; begin
 if new.ledger_code='card_payable' and new.debit_minor>0 then
  select coalesce(sum(credit_minor-debit_minor),0) into v_due from sakaccounts.journal_lines
   where account_id=new.account_id and ledger_code='card_payable' and owner_id=new.owner_id;
  if new.debit_minor>v_due then raise exception 'Card repayment or refund exceeds recorded outstanding'; end if;
 end if;
 return new;
end $$;
create trigger card_overpayment_check before insert on sakaccounts.journal_lines for each row execute function sakaccounts.prevent_card_overpayment();
notify pgrst,'reload schema';
