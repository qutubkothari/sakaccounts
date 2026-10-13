create or replace function sakaccounts.validate_statement_match() returns trigger language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare v_account uuid; v_owner uuid; v_currency char(3); v_effect bigint; begin
 if new.match_status='matched' then
  if new.matched_batch_id is null or new.amount_minor is null or new.amount_minor=0 or new.posting_date is null
  then raise exception 'A matched row needs a posting date, amount and journal batch'; end if;
  select account_id,owner_id into v_account,v_owner from sakaccounts.statement_imports where id=new.import_id;
  select currency into v_currency from sakaccounts.finance_accounts where id=v_account;
  select coalesce(sum(debit_minor-credit_minor),0) into v_effect
  from sakaccounts.journal_lines where batch_id=new.matched_batch_id and account_id=v_account and owner_id=v_owner and currency=v_currency;
  if v_effect=0 or abs(v_effect)<>abs(new.amount_minor) or new.currency<>v_currency
  then raise exception 'Statement row amount or currency differs from the account journal'; end if;
  if exists(select 1 from sakaccounts.statement_rows r join sakaccounts.statement_imports i on i.id=r.import_id
    where r.id<>new.id and r.match_status='matched' and r.matched_batch_id=new.matched_batch_id and i.account_id=v_account)
  then raise exception 'This account journal was already matched to another statement row'; end if;
 end if;
 return new;
end $$;
