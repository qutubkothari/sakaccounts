-- Preserve both earlier SakAccounts SQLite snapshots without selecting a winner.
-- Financial payloads are imported separately and are never stored in Git.
create table if not exists sakaccounts.legacy_snapshot_records (
  owner_id uuid not null references auth.users(id),
  source_snapshot text not null,
  source_table text not null,
  source_key text not null,
  payload jsonb not null,
  payload_sha256 text not null check (length(payload_sha256)=64),
  imported_at timestamptz not null default now(),
  primary key(owner_id,source_snapshot,source_table,source_key)
);
alter table sakaccounts.legacy_snapshot_records enable row level security;
create policy legacy_owner_read on sakaccounts.legacy_snapshot_records for select to authenticated
  using (owner_id=auth.uid() and exists(select 1 from sakaccounts.owner_allowlist where user_id=auth.uid()));
grant select on sakaccounts.legacy_snapshot_records to authenticated;
notify pgrst, 'reload schema';
