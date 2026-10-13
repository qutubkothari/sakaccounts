# Supabase setup and fresh start

The dedicated `sakaccounts` schema was inspected before migration. Version-controlled migrations `202610130001` through `202610130020` have been applied in order to the hosted Supabase project. They do not change unrelated schemas. Review each future migration against the live schema before applying it.

The owner `sales@saksolution.com` and administrator `qutubk` remain in Supabase Auth and the SakAccounts allowlist. Public signup is disabled. RLS is enabled on financial tables; authenticated, allowlisted users use the reviewed posting functions for journals, accounts, and statement staging. Client code uses only the publishable key. Keep the service key, database password, and financial data out of Git and browser code.

At the owner's explicit direction on 13 October 2026, all SakAccounts financial records and imported legacy snapshots were cleared while retaining both logins and five empty entity configuration rows. Original external SQLite databases were not changed. There are no verified opening balances in the new ledger. See `../ACCOUNTING_MIGRATION.md`.

Posting functions create balanced journals in PostgreSQL transactions with request IDs for idempotent retries. `../tests/accounting.sql` exercises the accounting and access rules inside a transaction that always rolls back. After migration changes, run that script with `psql -v ON_ERROR_STOP=1` and confirm no financial test rows remain.
