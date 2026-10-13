-- Allow owners to attach or replace invoice documents after creating the invoice.
create policy invoice_attachment_update on sakaccounts.supplier_invoices
for update to authenticated
using (sakaccounts.can_manage(owner_id))
with check (sakaccounts.can_manage(owner_id));
grant update(attachment_path) on sakaccounts.supplier_invoices to authenticated;

-- Let the uploader remove a file if recording its database reference fails.
create policy sakaccounts_document_delete on storage.objects
for delete to authenticated
using (bucket_id='sakaccounts-private' and sakaccounts.can_manage((storage.foldername(name))[1]::uuid));

notify pgrst,'reload schema';
