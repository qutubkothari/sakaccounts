alter table sakaccounts.statement_imports add column file_path text;
alter table sakaccounts.statement_imports add column opening_balance_minor bigint;
alter table sakaccounts.statement_imports add column closing_balance_minor bigint;

create or replace function sakaccounts.stage_statement_import(p_owner uuid,p_account uuid,p_file_name text,p_file_sha256 text,p_file_path text,p_period_start date,p_period_end date,p_opening bigint,p_closing bigint,p_raw_text text,p_rows jsonb)
returns uuid language plpgsql security definer set search_path=sakaccounts,auth,pg_temp as $$
declare a sakaccounts.finance_accounts%rowtype; v_id uuid; v_row jsonb; v_ref text; begin
 select * into a from sakaccounts.finance_accounts where id=p_account;
 if a.id is null or a.owner_id<>p_owner or not sakaccounts.can_manage(p_owner)
 or length(p_file_sha256)<>64 or p_file_sha256 !~ '^[0-9a-f]{64}$'
 or p_rows is null or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)>10000
 or nullif(trim(p_file_name),'') is null or p_file_path not like p_owner::text||'/%'
 then raise exception 'Invalid statement import'; end if;
 select id into v_id from sakaccounts.statement_imports where account_id=p_account and file_sha256=p_file_sha256;
 if found then return v_id; end if;
 insert into sakaccounts.statement_imports(owner_id,account_id,file_name,file_sha256,file_path,period_start,period_end,opening_balance_minor,closing_balance_minor,raw_text)
 values(p_owner,p_account,p_file_name,p_file_sha256,p_file_path,p_period_start,p_period_end,p_opening,p_closing,p_raw_text)
 returning id into v_id;
 for v_row in select value from jsonb_array_elements(p_rows) loop
  v_ref:=v_row->>'row_ref';
  if nullif(v_ref,'') is null then raise exception 'Statement row reference missing'; end if;
  insert into sakaccounts.statement_rows(owner_id,import_id,row_ref,posting_date,purchase_date,description,amount_minor,currency,raw,match_status)
  values(p_owner,v_id,v_ref,nullif(v_row->>'posting_date','')::date,nullif(v_row->>'purchase_date','')::date,
    v_row->>'description',nullif(v_row->>'amount_minor','')::bigint,a.currency,coalesce(v_row->'raw','{}'::jsonb),
    case when nullif(v_row->>'posting_date','') is not null and nullif(v_row->>'amount_minor','') is not null then 'unmatched' else 'needs_review' end);
 end loop;
 return v_id;
end $$;
revoke all on function sakaccounts.stage_statement_import(uuid,uuid,text,text,text,date,date,bigint,bigint,text,jsonb) from public,anon;
grant execute on function sakaccounts.stage_statement_import(uuid,uuid,text,text,text,date,date,bigint,bigint,text,jsonb) to authenticated;
notify pgrst,'reload schema';
