-- Keep the card's settlement currency in the journal while retaining the merchant's original amount.
alter table sakaccounts.ledger_entries
 add column expense_country char(2) check (expense_country in ('IN','AE')),
 add column merchant_currency char(3) check (merchant_currency in ('INR','AED')),
 add column merchant_amount_minor bigint check (merchant_amount_minor > 0);

alter table sakaccounts.ledger_entries add constraint merchant_amount_pair
 check ((merchant_currency is null) = (merchant_amount_minor is null));

create or replace function sakaccounts.post_entry_with_origin(
 p_request_id uuid,p_owner uuid,p_entity uuid,p_kind text,p_date date,p_amount bigint,p_currency char(3),
 p_category text,p_subcategory text,p_party text,p_description text,p_reference text,
 p_payment_amount bigint,p_payment_date date,p_funding_account uuid,p_due_date date,
 p_expense_country char(2),p_merchant_currency char(3),p_merchant_amount bigint
) returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare v_id uuid; begin
 if p_expense_country not in ('IN','AE') or p_expense_country is null
 or (p_merchant_currency is null) <> (p_merchant_amount is null)
 or (p_merchant_currency is not null and (p_merchant_currency not in ('INR','AED') or p_merchant_amount <= 0))
 then raise exception 'Invalid merchant currency or expense location'; end if;
 if p_merchant_currency is not null and p_merchant_currency is distinct from p_currency and (p_kind not in ('expense','fee','interest') or p_payment_amount <> p_amount or p_funding_account is null)
 then raise exception 'Foreign merchant amounts require a fully paid expense and a funding account'; end if;
 v_id:=sakaccounts.post_entry_with_due(p_request_id,p_owner,p_entity,p_kind,p_date,p_amount,p_currency,
   p_category,p_subcategory,p_party,p_description,p_reference,p_payment_amount,p_payment_date,p_funding_account,p_due_date);
 update sakaccounts.ledger_entries set expense_country=p_expense_country,
   merchant_currency=p_merchant_currency,merchant_amount_minor=p_merchant_amount
 where id=v_id and owner_id=p_owner
 and (expense_country is null or
   (expense_country=p_expense_country and merchant_currency is not distinct from p_merchant_currency
    and merchant_amount_minor is not distinct from p_merchant_amount));
 if not found then raise exception 'Repeated request has different merchant details'; end if;
 return v_id;
end $$;
revoke all on function sakaccounts.post_entry_with_origin(uuid,uuid,uuid,text,date,bigint,char,text,text,text,text,text,bigint,date,uuid,date,char,char,bigint) from public,anon;
grant execute on function sakaccounts.post_entry_with_origin(uuid,uuid,uuid,text,date,bigint,char,text,text,text,text,text,bigint,date,uuid,date,char,char,bigint) to authenticated;
notify pgrst,'reload schema';
