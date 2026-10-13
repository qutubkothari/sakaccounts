insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('sakaccounts-private','sakaccounts-private',false,15728640,
 array['application/pdf','image/jpeg','image/png','text/csv','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
on conflict(id) do nothing;

create policy sakaccounts_document_read on storage.objects for select to authenticated
using(bucket_id='sakaccounts-private' and sakaccounts.can_manage((storage.foldername(name))[1]::uuid));
create policy sakaccounts_document_insert on storage.objects for insert to authenticated
with check(bucket_id='sakaccounts-private' and sakaccounts.can_manage((storage.foldername(name))[1]::uuid));

create policy entry_attachment_update on sakaccounts.ledger_entries for update to authenticated
 using(sakaccounts.can_manage(owner_id)) with check(sakaccounts.can_manage(owner_id));
grant update(attachment_path) on sakaccounts.ledger_entries to authenticated;

create or replace function sakaccounts.validate_statement_match() returns trigger language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare v_account uuid; v_owner uuid; begin
 if new.match_status='matched' then
  if new.matched_batch_id is null then raise exception 'Matched row needs a journal batch'; end if;
  select account_id,owner_id into v_account,v_owner from sakaccounts.statement_imports where id=new.import_id;
  if not exists(select 1 from sakaccounts.journal_lines l where l.batch_id=new.matched_batch_id and l.account_id=v_account and l.owner_id=v_owner)
  then raise exception 'Journal batch does not affect this statement account'; end if;
 end if;
 return new;
end $$;
create trigger statement_match_check before insert or update on sakaccounts.statement_rows
for each row execute function sakaccounts.validate_statement_match();

-- Statement row approval remains a review action. Imported rows never post journals automatically.
notify pgrst,'reload schema';
