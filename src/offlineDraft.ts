import { del, get, set } from 'idb-keyval'

export type EntryDraft = {
  kind: 'expense' | 'income'
  amount: string
  entity: string
  date: string
  category: string
  party: string
  description: string
  reference: string
  entryDue: string
  payment: string
  paidAmount: string
  paymentDate: string
  funding: string
  sourceText: string
  attachment: File | null
  savedAt: string
}

const key = (userId: string) => `sakaccounts-entry-draft:${userId}`
export const saveEntryDraft = (userId: string, draft: EntryDraft) => set(key(userId), draft)
export const loadEntryDraft = (userId: string) => get<EntryDraft>(key(userId))
export const clearEntryDraft = (userId: string) => del(key(userId))
