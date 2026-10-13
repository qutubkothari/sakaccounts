export type Entity = { id: string; owner_id: string; code: string; name: string; currency: 'INR' | 'AED' }
export type Account = { id: string; owner_id: string; entity_id: string; name: string; kind: 'bank' | 'cash' | 'credit_card'; currency: 'INR' | 'AED'; issuing_bank: string | null; last_four: string | null; credit_limit_minor: number | null; opening_balance_minor: number; opening_as_of: string | null }
export type Entry = { id: string; owner_id: string; entity_id: string; kind: 'expense' | 'income' | 'inventory_purchase' | 'cogs' | 'prepaid' | 'deposit' | 'fixed_asset' | 'interest' | 'fee' | 'loan_received' | 'loan_repayment' | 'owner_contribution' | 'owner_draw'; incurred_date: string; due_date: string | null; amount_minor: number; currency: 'INR' | 'AED'; category: string; subcategory: string | null; party: string | null; description: string; reference: string | null; attachment_path: string | null; created_at: string }
export type Settlement = { id: string; entry_id: string; batch_id: string; amount_minor: number; method: string; funding_account_id: string | null; payment_date: string; reference: string | null }
export type Batch = { id: string; action: string; effective_date: string; entry_id: string | null }
export type Line = { id: number; batch_id: string; owner_id: string; entity_id: string; ledger_code: string; account_id: string | null; currency: 'INR' | 'AED'; debit_minor: number; credit_minor: number }
export type Statement = { id: string; account_id: string; period_start: string; period_end: string; statement_date: string; due_date: string | null; bill_amount_minor: number; currency: 'INR' | 'AED' }
export type StatementImport = { id: string; account_id: string; file_name: string; file_sha256: string; file_path: string | null; period_start: string | null; period_end: string | null; opening_balance_minor: number | null; closing_balance_minor: number | null; created_at: string }
export type StatementRow = { id: string; import_id: string; row_ref: string; posting_date: string | null; purchase_date: string | null; description: string | null; amount_minor: number | null; currency: string | null; raw: Record<string, unknown>; match_status: string; matched_batch_id: string | null }
export type Budget = { id: string; entity_id: string; month: string; category: string; amount_minor: number; currency: string }
export type Invoice = { id: string; entity_id: string; supplier: string; invoice_number: string; invoice_date: string; amount_minor: number; currency: string; attachment_path: string | null }
export type InvoiceMatch = { invoice_id: string; entry_id: string; allocated_minor: number }
export type Reimbursement = { id: string; expense_id: string; amount_minor: number; reimbursement_date: string; batch_id: string }
export type StatementAllocation = { id: string; statement_id: string; repayment_batch_id: string; amount_minor: number }
export type Adjustment = { id: string; source_entry_id: string; batch_id: string; kind: 'expense_refund' | 'prepaid_release' | 'fixed_asset_depreciation' | 'deposit_return'; amount_minor: number; effective_date: string; account_id: string | null }
export type CashPlan = { owner_id: string; currency: 'INR' | 'AED'; reserve_minor: number; essential_costs_30d_minor: number; confirmed_collections_30d_minor: number; assumptions: string | null }
export type OwnerPreference = { owner_id: string; reporting_timezone: string }
export type EntryAllocation = { id: string; entry_id: string; entity_id: string; category: string; amount_minor: number }
export type SettlementAllocation = { settlement_id: string; allocation_id: string; amount_minor: number }

export function minor(input: string): number {
  const value = input.trim()
  if (!/^\d+(\.\d{1,2})?$/.test(value)) throw new Error('Enter a positive amount with up to two decimal places.')
  const [whole, fractional = ''] = value.split('.')
  const result = Number(whole) * 100 + Number(fractional.padEnd(2, '0'))
  if (!Number.isSafeInteger(result) || result <= 0) throw new Error('Enter a valid amount greater than zero.')
  return result
}
export const money = (amount: number, currency: string) => new Intl.NumberFormat('en-IN', { style: 'currency', currency }).format(Number(amount) / 100)
export const todayIn = (timezone: string) => new Intl.DateTimeFormat('en-CA', { timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date())
export const today = () => todayIn('Asia/Kolkata')
export const sum = (values: number[]) => values.reduce((a, b) => a + Number(b), 0)
export const balanceFor = (account: Account, lines: Line[]) => {
  const net = sum(lines.filter(line => line.account_id === account.id).map(line => Number(line.debit_minor) - Number(line.credit_minor)))
  return account.kind === 'credit_card' ? -net : net
}
export const paidFor = (entry: Entry, settlements: Settlement[]) => sum(settlements.filter(s => s.entry_id === entry.id).map(s => s.amount_minor))
export const remainingFor = (entry: Entry, settlements: Settlement[], adjustments: Adjustment[]) => {
  const unpaidCredits = sum(adjustments.filter(a => a.source_entry_id === entry.id && a.kind === 'expense_refund' && !a.account_id).map(a => a.amount_minor))
  return Math.max(0, entry.amount_minor - paidFor(entry, settlements) - unpaidCredits)
}
export const statusFor = (entry: Entry, settlements: Settlement[], adjustments: Adjustment[] = []) => {
  if (['cogs','loan_received','loan_repayment','owner_contribution','owner_draw'].includes(entry.kind)) return 'Posted'
  const paid = paidFor(entry, settlements)
  const remaining = remainingFor(entry,settlements,adjustments)
  return remaining <= 0 ? 'Paid' : paid <= 0 ? 'Unpaid' : 'Partially paid'
}
