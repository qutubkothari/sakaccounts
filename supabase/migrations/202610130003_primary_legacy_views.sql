-- Read-only owner views over the selected former VPS snapshot.
create view sakaccounts.legacy_primary_transactions with (security_invoker=true) as
select owner_id, source_key as legacy_id,
  payload->>'date' as transaction_date,
  payload->>'business' as business,
  payload->>'type' as transaction_type,
  payload->>'description' as description,
  (payload->>'amount')::numeric as amount,
  payload->>'currency' as currency
from sakaccounts.legacy_snapshot_records
where source_snapshot='vps_20260422' and source_table='transactions';

create view sakaccounts.legacy_primary_accounts with (security_invoker=true) as
select owner_id, source_key as legacy_id,
  payload->>'business' as business,
  payload->>'name' as name,
  payload->>'account_type' as account_type,
  payload->>'currency_code' as currency,
  (payload->>'opening_balance')::numeric as opening_balance
from sakaccounts.legacy_snapshot_records
where source_snapshot='vps_20260422' and source_table='bank_accounts';

grant select on sakaccounts.legacy_primary_transactions, sakaccounts.legacy_primary_accounts to authenticated;
notify pgrst, 'reload schema';
