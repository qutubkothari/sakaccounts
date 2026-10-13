-- The private VPS worker uses the service role to read alert inputs and deliver
-- owner-authorised push subscriptions. No new client role gains access here.
grant usage on schema sakaccounts to service_role;
grant select on sakaccounts.push_subscriptions,
  sakaccounts.finance_accounts,
  sakaccounts.journal_lines,
  sakaccounts.ledger_entries,
  sakaccounts.settlements,
  sakaccounts.accounting_adjustments,
  sakaccounts.owner_preferences to service_role;
grant update(last_fingerprint, last_sent_date, updated_at), delete
  on sakaccounts.push_subscriptions to service_role;
