# Supabase setup

1. In Supabase Dashboard, inspect the existing project schema, policies, API-exposed schemas, Auth settings, and existing data before applying anything. This migration creates only objects in a dedicated `sakaccounts` schema; it does not modify or delete existing objects.
2. Add `sakaccounts` to the API's exposed schemas. Keep `public` and unrelated schemas untouched.
3. Apply `migrations/202610130001_sakaccounts_core.sql` through the Supabase SQL editor or PostgreSQL after schema review. This was applied to the specified project on 13 October 2026.
4. Create the authorised owner's Supabase Auth user. Add that exact user's UUID to `sakaccounts.owner_allowlist` using a secure dashboard session. Public signup should be disabled in Supabase Auth settings. The user must be authenticated before they can read the allowlist row; all app table policies additionally require allowlisting. The specified owner is already created and allowlisted.
5. Configure app `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` at build time. A publishable key is designed for client use; never place a service role/secret key or database password in frontend configuration.
6. The prior SakAccounts data was found in two separate SQLite snapshots. Both are preserved in `legacy_snapshot_records` by migration `202610130002_legacy_snapshots.sql` and the one-time `scripts/export_legacy_snapshots.py` export. The former VPS snapshot is primary; local differences remain flagged. Load opening figures into live `accounts` only after reconciling the snapshots.

The financial event RPCs insert a single immutable event in one PostgreSQL transaction. The `(owner_id, request_id)` unique constraint makes retries idempotent. Transfers, invoice settlements, and card repayments each post as one event with both account IDs, so they cannot be half applied. Balances are derived from opening-balance imports and events in application logic; do not edit historic events to correct a record—post a correcting transaction instead.

Live installation checks exercised owner and non-owner RLS, all four posting RPCs, and duplicate request IDs with temporary records. The temporary records and test user were removed. Re-run these checks after any migration changes.
