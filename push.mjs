import { createClient } from '@supabase/supabase-js'
import webpush from 'web-push'
import WebSocket from 'ws'

const url = process.env.SUPABASE_URL
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY
const publicKey = process.env.VAPID_PUBLIC_KEY
const privateKey = process.env.VAPID_PRIVATE_KEY

export function startPushWorker() {
  if (!url || !serviceKey || !publicKey || !privateKey) {
    console.log('SakAccounts background alerts are not configured')
    return
  }
  const db = createClient(url, serviceKey, { db: { schema: 'sakaccounts' }, auth: { persistSession: false, autoRefreshToken: false }, realtime: { transport: WebSocket } })
  webpush.setVapidDetails('mailto:sales@saksolution.com', publicKey, privateKey)
  let running = false

  async function all(table, ownerId) {
    const records = []
    for (let offset = 0; ; offset += 1000) {
      let query = db.from(table).select('*').range(offset, offset + 999)
      if (ownerId) query = query.eq('owner_id', ownerId)
      const { data, error } = await query
      if (error) throw error
      records.push(...data)
      if (data.length < 1000) return records
    }
  }

  async function run() {
    if (running) return
    running = true
    try {
      const subscriptions = await all('push_subscriptions')
      const owners = [...new Set(subscriptions.map(s => s.owner_id))]
      for (const ownerId of owners) {
        const [accounts, lines, entries, settlements, adjustments, preferences] = await Promise.all([
          all('finance_accounts', ownerId), all('journal_lines', ownerId), all('ledger_entries', ownerId),
          all('settlements', ownerId), all('accounting_adjustments', ownerId), all('owner_preferences', ownerId),
        ])
        const timezone = preferences[0]?.reporting_timezone || 'Asia/Kolkata'
        const now = new Date()
        const today = new Intl.DateTimeFormat('en-CA', { timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(now)
        const hour = Number(new Intl.DateTimeFormat('en-GB', { timeZone: timezone, hour: '2-digit', hourCycle: 'h23' }).format(now))
        const paid = new Map()
        for (const payment of settlements) paid.set(payment.entry_id, (paid.get(payment.entry_id) || 0) + Number(payment.amount_minor))
        const credits = new Map()
        for (const adjustment of adjustments.filter(a => a.kind === 'expense_refund' && !a.account_id)) credits.set(adjustment.source_entry_id, (credits.get(adjustment.source_entry_id) || 0) + Number(adjustment.amount_minor))
        const urgent = []
        for (const account of accounts.filter(a => a.kind !== 'credit_card')) {
          const balance = lines.filter(l => l.account_id === account.id).reduce((value, l) => value + Number(l.debit_minor) - Number(l.credit_minor), 0)
          if (balance < 0) urgent.push(`negative-${account.id}`)
        }
        for (const entry of entries.filter(e => e.due_date && e.due_date < today && ['expense','inventory_purchase','prepaid','deposit','fixed_asset','interest','fee'].includes(e.kind))) {
          if (Number(entry.amount_minor) - (paid.get(entry.id) || 0) - (credits.get(entry.id) || 0) > 0) urgent.push(`overdue-${entry.id}`)
        }
        const fingerprint = urgent.sort().join('|')
        for (const subscription of subscriptions.filter(s => s.owner_id === ownerId)) {
          const newUrgent = fingerprint && fingerprint !== subscription.last_fingerprint
          const dailyReminder = hour === 9 && subscription.last_sent_date !== today
          if (!newUrgent && !dailyReminder) {
            if (!fingerprint && subscription.last_fingerprint) await db.from('push_subscriptions').update({ last_fingerprint: '' }).eq('id', subscription.id)
            continue
          }
          const payload = JSON.stringify({ title: newUrgent ? 'SakAccounts needs your attention' : 'Your SakAccounts daily review', body: newUrgent ? `${urgent.length} urgent item${urgent.length === 1 ? '' : 's'} to review. Open your business pulse.` : 'Record today\'s activity and check your balances and commitments.', url: '/' })
          try {
            await webpush.sendNotification(subscription.subscription, payload)
            await db.from('push_subscriptions').update({ last_fingerprint: fingerprint, last_sent_date: today, updated_at: new Date().toISOString() }).eq('id', subscription.id)
          } catch (error) {
            if (error.statusCode === 404 || error.statusCode === 410) await db.from('push_subscriptions').delete().eq('id', subscription.id)
            else console.error('SakAccounts push delivery failed:', error.statusCode || error.message)
          }
        }
      }
    } catch (error) {
      console.error('SakAccounts push worker failed:', error.message)
    } finally {
      running = false
    }
  }

  void run()
  setInterval(() => void run(), 15 * 60 * 1000).unref()
}
