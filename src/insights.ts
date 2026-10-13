import type { Account, Budget, Entry, StatementImport, StatementRow } from './finance'
import { balanceFor, money, remainingFor, sum } from './finance'
import type { Adjustment, Line, Settlement } from './finance'

export type Insight = {
  id: string
  level: 'urgent' | 'review' | 'setup'
  title: string
  detail: string
  destination: 'Bank & cash' | 'Expenses & bills' | 'All entries' | 'Reconciliation' | 'Budgets'
  recordId?: string
}

export type ExpenseSlice = { currency: string; date: string; entity_id: string; category: string; amount_minor: number }

export function buildInsights(input: {
  today: string; accounts: Account[]; entries: Entry[]; settlements: Settlement[]
  adjustments: Adjustment[]; lines: Line[]; budgets: Budget[]; expenseSlices: ExpenseSlice[]
  imports: StatementImport[]; rows: StatementRow[]
}): Insight[] {
  const { today, accounts, entries, settlements, adjustments, lines, budgets, expenseSlices, imports, rows } = input
  const out: Insight[] = []
  if (!accounts.length) out.push({ id: 'setup-account', level: 'setup', title: 'Add your first bank or cash account', detail: 'Balances and cash alerts need an opening balance to be useful.', destination: 'Bank & cash' })

  for (const account of accounts.filter(a => a.kind !== 'credit_card')) {
    const balance = balanceFor(account, lines)
    if (balance < 0) out.push({ id: `negative-${account.id}`, level: 'urgent', title: `${account.name} is below zero`, detail: `${money(balance, account.currency)} recorded balance. Check the opening balance and missing deposits.`, destination: 'Bank & cash' })
  }

  for (const entry of entries) {
    const remaining = remainingFor(entry, settlements, adjustments)
    if (remaining > 0 && entry.due_date && entry.due_date < today && ['expense','inventory_purchase','prepaid','deposit','fixed_asset','interest','fee'].includes(entry.kind)) {
      out.push({ id: `overdue-${entry.id}`, level: 'urgent', title: `Overdue: ${entry.party || entry.description}`, detail: `${money(remaining, entry.currency)} was due ${entry.due_date}.`, destination: 'Expenses & bills', recordId: entry.id })
    }
    if (entry.kind === 'expense' && !entry.attachment_path && entry.amount_minor >= (entry.currency === 'AED' ? 20000 : 500000)) {
      out.push({ id: `receipt-${entry.id}`, level: 'review', title: `Receipt missing: ${entry.party || entry.description}`, detail: `${money(entry.amount_minor, entry.currency)} expense has no document.`, destination: 'Expenses & bills', recordId: entry.id })
    }
  }

  const seen = new Map<string, Entry>()
  for (const entry of entries.filter(e => e.kind === 'expense')) {
    const key = [entry.entity_id, entry.incurred_date, entry.amount_minor, (entry.party || entry.description).trim().toLowerCase()].join('|')
    const first = seen.get(key)
    if (first) out.push({ id: `duplicate-${entry.id}`, level: 'review', title: `Possible repeated expense: ${entry.party || entry.description}`, detail: `${money(entry.amount_minor, entry.currency)} appears twice on ${entry.incurred_date}. Review both before deciding.`, destination: 'All entries', recordId: entry.id })
    else seen.set(key, entry)
  }

  const month = today.slice(0, 7)
  for (const budget of budgets.filter(b => b.month.startsWith(month))) {
    const spent = sum(expenseSlices.filter(e => e.entity_id === budget.entity_id && e.currency === budget.currency && e.date.startsWith(month) && (budget.category.toUpperCase() === 'ALL' || e.category.toLowerCase() === budget.category.toLowerCase())).map(e => e.amount_minor))
    if (spent > budget.amount_minor) out.push({ id: `budget-${budget.id}`, level: 'review', title: `${budget.category} budget exceeded`, detail: `${money(spent - budget.amount_minor, budget.currency)} over the monthly allowance.`, destination: 'Budgets' })
  }

  const openRows = rows.filter(r => r.match_status === 'needs_review' || r.match_status === 'unmatched')
  if (openRows.length) out.push({ id: 'reconcile-open', level: 'review', title: `${openRows.length} bank or card rows need review`, detail: 'Match statement activity to entries or investigate a missing transaction.', destination: 'Reconciliation' })
  else if (!imports.length && entries.length) out.push({ id: 'reconcile-setup', level: 'setup', title: 'Reconcile your first statement', detail: 'Statement matching helps reveal missing or repeated cash movements.', destination: 'Reconciliation' })

  return out.sort((a, b) => ({ urgent: 0, review: 1, setup: 2 })[a.level] - ({ urgent: 0, review: 1, setup: 2 })[b.level])
}

export function monthlyCategoryChanges(expenseSlices: ExpenseSlice[], month: string) {
  const previous = new Date(`${month}-01T00:00:00Z`)
  previous.setUTCMonth(previous.getUTCMonth() - 1)
  const priorMonth = previous.toISOString().slice(0, 7)
  const grouped = new Map<string, { currency: string; category: string; current: number; previous: number }>()
  for (const slice of expenseSlices.filter(e => e.date.startsWith(month) || e.date.startsWith(priorMonth))) {
    const key = `${slice.currency}|${slice.category.trim().toLowerCase()}`
    const value = grouped.get(key) ?? { currency: slice.currency, category: slice.category || 'Uncategorised', current: 0, previous: 0 }
    if (slice.date.startsWith(month)) value.current += slice.amount_minor
    else value.previous += slice.amount_minor
    grouped.set(key, value)
  }
  return [...grouped.values()].filter(x => x.current !== x.previous).sort((a, b) => Math.abs(b.current - b.previous) - Math.abs(a.current - a.previous))
}
