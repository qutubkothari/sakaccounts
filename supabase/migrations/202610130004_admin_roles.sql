-- Application roles remain separate from Supabase service_role and database privileges.
alter table sakaccounts.owner_allowlist
  add column if not exists app_role text not null default 'owner'
  check (app_role in ('owner', 'super_admin'));
notify pgrst, 'reload schema';
