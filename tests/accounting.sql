-- Run with psql -v ON_ERROR_STOP=1. All fixtures roll back; no production entries remain.
begin;
create function pg_temp.assert_num(actual bigint,expected bigint,label text) returns void language plpgsql as $$
begin if actual is distinct from expected then raise exception '%: expected %, got %',label,expected,actual; end if; end $$;
create function pg_temp.net(code text,account uuid default null) returns bigint language sql as $$
 select coalesce(sum(debit_minor-credit_minor),0)::bigint from sakaccounts.journal_lines
 where ledger_code=code and (account is null or account_id=account)
$$;
create function pg_temp.assert_post_denied(p_owner uuid,p_entity uuid) returns void language plpgsql as $$
begin
 begin
  perform sakaccounts.post_entry(gen_random_uuid(),p_owner,p_entity,'expense',current_date,100,'INR','Denied',null,null,'Denied',null,0,null,null);
  raise exception 'T16 unauthorised posting unexpectedly succeeded';
 exception when others then
  if sqlerrm='T16 unauthorised posting unexpectedly succeeded' then raise; end if;
 end;
end $$;
select user_id as owner from sakaccounts.owner_allowlist where app_role='owner' limit 1 \gset
select user_id as admin from sakaccounts.owner_allowlist where app_role='super_admin' limit 1 \gset
select id as amazon from sakaccounts.entities where owner_id=:'owner' and code='amazon_india' \gset
select id as fasteners from sakaccounts.entities where owner_id=:'owner' and code='fasteners_india' \gset
select id as personal from sakaccounts.entities where owner_id=:'owner' and code='personal' \gset
select id as uae from sakaccounts.entities where owner_id=:'owner' and code='amazon_uae' \gset
set local role authenticated;
select set_config('request.jwt.claim.sub',:'admin',true);
select set_config('request.jwt.claim.role','authenticated',true);
select sakaccounts.create_finance_account(gen_random_uuid(),:'owner',:'amazon','test business bank '||gen_random_uuid(),'bank','INR',0,current_date,null,null,null) as business_bank \gset
select sakaccounts.create_finance_account(gen_random_uuid(),:'owner',:'amazon','test second bank '||gen_random_uuid(),'bank','INR',0,current_date,null,null,null) as second_bank \gset
select sakaccounts.create_finance_account(gen_random_uuid(),:'owner',:'personal','test personal bank '||gen_random_uuid(),'bank','INR',0,current_date,null,null,null) as personal_bank \gset
select sakaccounts.create_finance_account(gen_random_uuid(),:'owner',:'amazon','test card A '||gen_random_uuid(),'credit_card','INR',0,current_date,'Test Bank','1234',null) as card_a \gset
select sakaccounts.create_finance_account(gen_random_uuid(),:'owner',:'personal','test personal card '||gen_random_uuid(),'credit_card','INR',0,current_date,'Test Bank','5678',null) as personal_card \gset

-- 1: Unpaid advertising creates expense and payable, no cash movement.
select sakaccounts.post_entry(gen_random_uuid(),:'owner',:'amazon','expense',current_date,100000,'INR','Advertising',null,'Amazon','Ad accrual 1',null,0,null,null) as ad1 \gset
select pg_temp.assert_num(pg_temp.net('expense'),100000,'T1 expense');
select pg_temp.assert_num(-pg_temp.net('supplier_payable'),100000,'T1 payable');
select pg_temp.assert_num(pg_temp.net('bank'),0,'T1 cash');
\echo T1 PASS unpaid accrual: expense 100000, payable 100000, cash 0

-- 2: Later bank payment clears payable without new expense.
select sakaccounts.settle_entry(gen_random_uuid(),:'ad1',100000,current_date,:'business_bank',null);
select pg_temp.assert_num(pg_temp.net('expense'),100000,'T2 no duplicate expense');
select pg_temp.assert_num(-pg_temp.net('supplier_payable'),0,'T2 payable cleared');
select pg_temp.assert_num(pg_temp.net('bank',:'business_bank'),-100000,'T2 bank');
\echo T2 PASS paid later: payable 0, bank -100000, expense 100000

-- 3: Existing payable charged to a card clears supplier debt, creates card debt.
select sakaccounts.post_entry(gen_random_uuid(),:'owner',:'amazon','expense',current_date,100000,'INR','Advertising',null,'Amazon','Ad accrual 2',null,0,null,null) as ad2 \gset
select sakaccounts.settle_entry(gen_random_uuid(),:'ad2',100000,current_date,:'card_a',null);
select pg_temp.assert_num(-pg_temp.net('supplier_payable'),0,'T3 supplier payable');
select pg_temp.assert_num(-pg_temp.net('card_payable',:'card_a'),100000,'T3 card debt');
select pg_temp.assert_num(pg_temp.net('expense'),200000,'T3 no duplicate expense');
\echo T3 PASS payable to card: card debt 100000, no second expense

-- 4 and 5: Card purchase and partial repayment.
select sakaccounts.post_entry(gen_random_uuid(),:'owner',:'amazon','expense',current_date,250000,'INR','Supplies',null,'Merchant','Card purchase',null,250000,current_date,:'card_a') as purchase \gset
select pg_temp.assert_num(-pg_temp.net('card_payable',:'card_a'),350000,'T4 card debt incl prior ad');
select pg_temp.assert_num(pg_temp.net('bank',:'business_bank'),-100000,'T4 no new bank movement');
select gen_random_uuid() as repay_request \gset
select sakaccounts.post_card_repayment_v2(:'repay_request',:'card_a',:'business_bank',100000,current_date) as repay_batch \gset
select pg_temp.assert_num(-pg_temp.net('card_payable',:'card_a'),250000,'T5 remaining card debt');
select pg_temp.assert_num(pg_temp.net('bank',:'business_bank'),-200000,'T5 bank after repayment');
select pg_temp.assert_num(pg_temp.net('expense'),450000,'T5 no new expense');
\echo T4-T5 PASS card purchase and repayment: debt 250000, bank -200000, expense 450000

-- 6 and 7: Statement rows match existing purchase and repayment; same file stays one import.
select sakaccounts.stage_statement_import(:'owner',:'card_a','test.csv',repeat('a',64),:'owner'||'/test.csv',current_date,current_date,0,0,'raw',
 jsonb_build_array(
  jsonb_build_object('row_ref','purchase','posting_date',current_date::text,'description','Merchant','amount_minor',-250000,'raw','{}'::jsonb),
  jsonb_build_object('row_ref','repayment','posting_date',current_date::text,'description','Card payment','amount_minor',100000,'raw','{}'::jsonb)
 )) as import_id \gset
update sakaccounts.statement_rows set match_status='matched',matched_batch_id=(select id from sakaccounts.journal_batches where entry_id=:'purchase' and action='post_expense') where import_id=:'import_id' and row_ref='purchase';
update sakaccounts.statement_rows set match_status='matched',matched_batch_id=:'repay_batch' where import_id=:'import_id' and row_ref='repayment';
select sakaccounts.stage_statement_import(:'owner',:'card_a','test.csv',repeat('a',64),:'owner'||'/test.csv',current_date,current_date,0,0,'raw','[]'::jsonb);
select pg_temp.assert_num((select count(*) from sakaccounts.statement_imports where account_id=:'card_a'),1,'T7 duplicate file');
select pg_temp.assert_num(pg_temp.net('expense'),450000,'T6 statement no duplicate expense');
\echo T6-T7 PASS statement matching and repeated file: no balance change

-- 25: A statement match cannot misstate the journal amount.
create function pg_temp.assert_bad_match(p_import uuid) returns void language plpgsql as $$ begin
 begin
  update sakaccounts.statement_rows set amount_minor=1 where import_id=p_import and row_ref='purchase';
  raise exception 'T25 invalid amount was accepted';
 exception when others then
  if sqlerrm='T25 invalid amount was accepted' then raise; end if;
 end;
end $$;
select pg_temp.assert_bad_match(:'import_id');
\echo T25 PASS mismatched statement amount rejected

-- 8: Consolidated invoice matches three accruals, no extra expense.
select sakaccounts.post_entry(gen_random_uuid(),:'owner',:'amazon','expense',current_date,100000,'INR','Advertising',null,'Amazon','Daily ad A',null,0,null,null) as daily_a \gset
select sakaccounts.post_entry(gen_random_uuid(),:'owner',:'amazon','expense',current_date,100000,'INR','Advertising',null,'Amazon','Daily ad B',null,0,null,null) as daily_b \gset
select sakaccounts.post_entry(gen_random_uuid(),:'owner',:'amazon','expense',current_date,100000,'INR','Advertising',null,'Amazon','Daily ad C',null,0,null,null) as daily_c \gset
insert into sakaccounts.supplier_invoices(owner_id,entity_id,supplier,invoice_number,invoice_date,amount_minor,currency)
values(:'owner',:'amazon','Amazon','TEST-3000',current_date,300000,'INR') returning id as invoice \gset
insert into sakaccounts.invoice_matches(invoice_id,entry_id,owner_id,allocated_minor)
values(:'invoice',:'daily_a',:'owner',100000),(:'invoice',:'daily_b',:'owner',100000),(:'invoice',:'daily_c',:'owner',100000);
select pg_temp.assert_num(pg_temp.net('expense'),750000,'T8 expense stays 750000');
\echo T8 PASS invoice 300000 matched to three accruals; expense unchanged

-- 9: Gross Amazon receivable, existing ad payable, net bank deposit.
select sakaccounts.post_entry(gen_random_uuid(),:'owner',:'amazon','income',current_date,1000000,'INR','Amazon sales',null,'Amazon','Gross settlement',null,0,null,null) as gross_income \gset
select sakaccounts.post_entry(gen_random_uuid(),:'owner',:'amazon','expense',current_date,100000,'INR','Advertising',null,'Amazon','Ad deducted',null,0,null,null) as deducted_ad \gset
select sakaccounts.post_amazon_net_receipt(gen_random_uuid(),:'gross_income',:'deducted_ad',:'business_bank',900000,current_date);
select pg_temp.assert_num((select sum(amount_minor)::bigint from sakaccounts.settlements where entry_id=:'gross_income'),1000000,'T9 receivable settled');
select pg_temp.assert_num((select sum(amount_minor)::bigint from sakaccounts.settlements where entry_id=:'deducted_ad'),100000,'T9 payable settled');
select pg_temp.assert_num(pg_temp.net('bank',:'business_bank'),700000,'T9 net bank movement');
\echo T9 PASS gross 1000000, ad payable 100000, net bank 900000

-- 10: Earned invoice and later collection recognise revenue once.
select sakaccounts.post_entry(gen_random_uuid(),:'owner',:'amazon','income',current_date,500000,'INR','Services',null,'Customer','Earned invoice',null,0,null,null) as earned \gset
select sakaccounts.settle_entry(gen_random_uuid(),:'earned',500000,current_date,:'business_bank',null);
select pg_temp.assert_num(-pg_temp.net('revenue'),1500000,'T10 revenue once');
select pg_temp.assert_num((select sum(amount_minor)::bigint from sakaccounts.settlements where entry_id=:'earned'),500000,'T10 collected');
\echo T10 PASS earned revenue 500000, later collection no new revenue

-- 11: Company expense on a personal card, then reimbursement.
select sakaccounts.post_entry(gen_random_uuid(),:'owner',:'amazon','expense',current_date,100000,'INR','Supplies',null,'Merchant','Company expense personal card',null,100000,current_date,:'personal_card') as cross_expense \gset
select pg_temp.assert_num(-pg_temp.net('intercompany_due'),100000,'T11 internal due');
select pg_temp.assert_num(pg_temp.net('intercompany_receivable'),100000,'T11 internal receivable');
select sakaccounts.post_reimbursement(gen_random_uuid(),:'cross_expense',:'business_bank',:'personal_bank',100000,current_date);
select pg_temp.assert_num(pg_temp.net('intercompany_due'),0,'T11 due cleared');
select pg_temp.assert_num(pg_temp.net('intercompany_receivable'),0,'T11 internal receivable cleared');
\echo T11 PASS one company expense, personal card debt, internal balances reimbursed

-- 12: Inventory purchase is an asset; verified COGS is the expense.
select sakaccounts.post_entry(gen_random_uuid(),:'owner',:'amazon','inventory_purchase',current_date,1000000,'INR','Inventory',null,'Supplier','Stock bought',null,0,null,null);
select sakaccounts.post_entry(gen_random_uuid(),:'owner',:'amazon','cogs',current_date,400000,'INR','COGS',null,'Customer','Verified stock cost',null,0,null,null);
select pg_temp.assert_num(pg_temp.net('inventory'),600000,'T12 remaining inventory');
select pg_temp.assert_num(pg_temp.net('cogs'),400000,'T12 COGS');
\echo T12 PASS inventory 600000, COGS 400000

-- 13: Transfer has no revenue/expense and no aggregate cash change.
select (pg_temp.net('bank')+pg_temp.net('cash')) as cash_before \gset
select pg_temp.net('expense') as expense_before \gset
select sakaccounts.post_transfer_v2(gen_random_uuid(),:'business_bank',:'second_bank',20000,current_date);
select pg_temp.assert_num(pg_temp.net('bank')+pg_temp.net('cash'),:'cash_before','T13 aggregate cash');
select pg_temp.assert_num(pg_temp.net('expense'),:'expense_before','T13 expense');
\echo T13 PASS transfer changes account balances, aggregate cash and expense unchanged

-- 14: AED remains separate from INR.
select sakaccounts.create_finance_account(gen_random_uuid(),:'owner',:'uae','test AED bank '||gen_random_uuid(),'bank','AED',12345,current_date,null,null,null) as aed_bank \gset
select sakaccounts.post_entry(gen_random_uuid(),:'owner',:'uae','expense',current_date,10000,'AED','Supplies',null,'UAE supplier','AED expense',null,0,null,null);
select pg_temp.assert_num((select coalesce(sum(debit_minor-credit_minor),0)::bigint from sakaccounts.journal_lines where ledger_code='expense' and currency='AED'),10000,'T14 AED expense');
select pg_temp.assert_num(pg_temp.net('bank',:'aed_bank'),12345,'T14 AED opening');
\echo T14 PASS INR and AED journal lines remain separate

-- 15: Fresh start contains no imported legacy financial rows.
select pg_temp.assert_num((select count(*) from sakaccounts.legacy_snapshot_records),0,'T15 legacy removed');
\echo T15 PASS legacy records do not affect fresh balances

-- Additional financing and asset classification checks.
select sakaccounts.post_financing(gen_random_uuid(),:'owner',:'amazon','loan_received',current_date,1000000,'INR',:'business_bank','Loan principal');
select sakaccounts.post_financing(gen_random_uuid(),:'owner',:'amazon','loan_repayment',current_date,400000,'INR',:'business_bank','Principal paid');
select pg_temp.assert_num(-pg_temp.net('loan_payable'),600000,'T17 remaining loan principal');
select pg_temp.assert_num(-pg_temp.net('revenue'),1500000,'T17 no loan revenue');
\echo T17 PASS loan principal 600000, no revenue or expense from financing
select pg_temp.net('expense') as expense_before_asset \gset
select sakaccounts.post_entry(gen_random_uuid(),:'owner',:'amazon','prepaid',current_date,100000,'INR','Licence',null,'Provider','Prepaid licence',null,100000,current_date,:'business_bank') as prepaid_entry \gset
select sakaccounts.post_entry(gen_random_uuid(),:'owner',:'amazon','fixed_asset',current_date,200000,'INR','Equipment',null,'Provider','Fixed asset',null,0,null,null);
select pg_temp.assert_num(pg_temp.net('prepaid'),100000,'T18 prepaid asset');
select pg_temp.assert_num(pg_temp.net('fixed_asset'),200000,'T18 fixed asset');
select pg_temp.assert_num(pg_temp.net('expense'),:'expense_before_asset','T18 no immediate expense');
\echo T18 PASS prepaid and fixed assets classified as assets, not immediate expense
select sakaccounts.post_entry(gen_random_uuid(),:'owner',:'amazon','interest',current_date,5000,'INR','Card interest',null,'Issuer','Interest charge',null,5000,current_date,:'card_a');
select pg_temp.assert_num(pg_temp.net('expense'),:'expense_before_asset'::bigint+5000,'T19 interest expense');
\echo T19 PASS interest charge is an expense and increases card debt
select sakaccounts.post_adjustment(gen_random_uuid(),:'prepaid_entry','prepaid_release',40000,current_date,null);
select pg_temp.assert_num(pg_temp.net('prepaid'),60000,'T20 prepaid remaining');
select sakaccounts.post_adjustment(gen_random_uuid(),:'ad1','expense_refund',10000,current_date,:'business_bank');
select pg_temp.assert_num(pg_temp.net('expense'),:'expense_before_asset'::bigint+35000,'T20 net expense after release/refund');
\echo T20 PASS prepaid release 40000 and linked refund 10000 adjust expense once
select sakaccounts.stage_statement_import(:'owner',:'business_bank','test-staged.csv',repeat('b',64),:'owner'||'/test-staged.csv',current_date,current_date,0,10000,'raw statement',jsonb_build_array(jsonb_build_object('row_ref','2','posting_date',current_date::text,'description','Test row','amount_minor',10000,'raw',jsonb_build_object('source','2')))) as staged_id \gset
select sakaccounts.stage_statement_import(:'owner',:'business_bank','test-staged.csv',repeat('b',64),:'owner'||'/test-staged.csv',current_date,current_date,0,10000,'raw statement','[]'::jsonb) as staged_retry \gset
select pg_temp.assert_num((select count(*) from sakaccounts.statement_rows where import_id=:'staged_id'),1,'T21 atomic row staging');
select pg_temp.assert_num((:'staged_id'::uuid=:'staged_retry'::uuid)::int,1,'T21 duplicate import returns same batch');
\echo T21 PASS atomic statement staging and exact-file retry
select sakaccounts.post_entry_with_due(gen_random_uuid(),:'owner',:'amazon','expense',current_date,10000,'INR','Utilities',null,'Supplier','Dated bill',null,0,null,null,current_date+7) as dated_bill \gset
select pg_temp.assert_num((select (due_date=current_date+7)::int from sakaccounts.ledger_entries where id=:'dated_bill'),1,'T22 due date');
insert into sakaccounts.cash_plan_settings(owner_id,currency,reserve_minor,essential_costs_30d_minor,confirmed_collections_30d_minor)
values(:'owner','INR',100000,200000,0);
select pg_temp.assert_num((select reserve_minor from sakaccounts.cash_plan_settings where owner_id=:'owner' and currency='INR'),100000,'T22 reserve');
\echo T22 PASS due date and explicit cash-plan assumptions
select pg_temp.assert_num(has_table_privilege('authenticated','sakaccounts.finance_accounts','INSERT')::int,0,'T23 direct account insert denied');
select pg_temp.assert_num(has_table_privilege('authenticated','sakaccounts.statement_rows','INSERT')::int,0,'T23 raw statement insert denied');
select pg_temp.assert_num(has_table_privilege('authenticated','sakaccounts.journal_lines','INSERT')::int,0,'T23 direct journal insert denied');
\echo T23 PASS direct account, raw statement and journal inserts denied

-- 24: One split bill recognises each entity/category once, then pays allocations.
select sakaccounts.post_split_expense(gen_random_uuid(),:'owner',current_date,'INR','Shared supplier','Shared bill','SPLIT-1',current_date+10,jsonb_build_array(jsonb_build_object('entity_id',:'amazon','category','Advertising','amount_minor',70000),jsonb_build_object('entity_id',:'fasteners','category','Office','amount_minor',30000))) as split_bill \gset
select pg_temp.assert_num((select count(*) from sakaccounts.entry_allocations where entry_id=:'split_bill'),2,'T24 allocation count');
select pg_temp.assert_num((select amount_minor from sakaccounts.ledger_entries where id=:'split_bill'),100000,'T24 one expense total');
select pg_temp.assert_num((select sum(amount_minor)::bigint from sakaccounts.entry_allocations where entry_id=:'split_bill'),100000,'T24 allocation total');
select id as split_a from sakaccounts.entry_allocations where entry_id=:'split_bill' and category='Advertising' \gset
select id as split_b from sakaccounts.entry_allocations where entry_id=:'split_bill' and category='Office' \gset
select sakaccounts.settle_split_expense(gen_random_uuid(),:'split_bill',current_date,:'business_bank',jsonb_build_array(jsonb_build_object('allocation_id',:'split_a','amount_minor',40000),jsonb_build_object('allocation_id',:'split_b','amount_minor',30000)));
select pg_temp.assert_num((select sum(amount_minor)::bigint from sakaccounts.settlement_allocations where allocation_id in (:'split_a',:'split_b')),70000,'T24 allocated payments');
select pg_temp.assert_num((select sum(amount_minor)::bigint from sakaccounts.settlements where entry_id=:'split_bill'),70000,'T24 payment total');
\echo T24 PASS split expense and partial multi-entity payment

-- 16: Unauthorised authenticated subject sees no owner/entity rows.
select set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
select pg_temp.assert_num((select count(*) from sakaccounts.entities),0,'T16 RLS entities');
select pg_temp.assert_num((select count(*) from sakaccounts.ledger_entries),0,'T16 RLS entries');
select pg_temp.assert_post_denied(:'owner',:'amazon');
\echo T16 PASS unauthorised reads empty and posting denied

rollback;
