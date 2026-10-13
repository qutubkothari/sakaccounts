# SakAccounts fresh start

On 13 October 2026 the owner directed us to clear all SakAccounts financial records and legacy snapshots in Supabase while retaining the owner and `qutubk` login accounts. This supersedes the earlier plan to preserve the VPS and local SQLite snapshots in Supabase. The original SQLite source files outside this Supabase project were not changed.

The five entity names remain as empty configuration: Amazon India, Fasteners India, IT, Amazon UAE, and Personal. No opening balance or historical transaction has been posted. Account balances therefore start at zero until the owner enters verified opening figures. Earlier source divergence and uncertain opening figures remain historical context only; no unverified figures are represented as current balances.

The current application records new events through PostgreSQL posting functions and balanced journal lines. It supports expense and income accruals, settlement, cards and repayments, transfers, cross entity reimbursement, inventory and verified cost of goods sold, financing, assets, adjustments, split expenses, statement staging/matching, invoice matching, budgets, and reports. There are no paid AI calls.

The original source data must be reviewed separately before any historical reimport. Reimport requires a new, explicitly approved migration and reconciliation plan so that old and new events are not duplicated.
