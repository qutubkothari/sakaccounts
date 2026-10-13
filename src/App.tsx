import { useEffect, useRef, useState } from 'react'
import type { FormEvent } from 'react'
import type { Session } from '@supabase/supabase-js'
import { configured, supabase } from './lib/supabase'

type Account = { id: string; name: string; kind: string; currency: string; opening_balance_minor: number; balance_minor: number }
type Entry = { id: string; kind: string; amount_minor: number; currency: string; description: string; created_at: string; source_account_id: string | null; destination_account_id: string | null }
type Flag = { flag_key: string; description: string; status: string }
type LegacyEntry = { legacy_id: string; transaction_date: string; business: string; transaction_type: string; description: string; amount: number }
const money = (value: number, currency: string) => new Intl.NumberFormat(undefined, { style: 'currency', currency }).format(value)

export default function App() {
  const [session, setSession] = useState<Session | null>(null)
  const [authorised, setAuthorised] = useState<boolean | null>(null)
  const [loading, setLoading] = useState(true)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [recovery, setRecovery] = useState(() => window.location.hash.includes('type=recovery') || window.location.search.includes('type=recovery'))
  const [newPassword, setNewPassword] = useState('')
  const [confirmPassword, setConfirmPassword] = useState('')
  const [accounts, setAccounts] = useState<Account[]>([])
  const [entries, setEntries] = useState<Entry[]>([])
  const [flags, setFlags] = useState<Flag[]>([])
  const [legacyEntries, setLegacyEntries] = useState<LegacyEntry[]>([])
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [action, setAction] = useState<'income' | 'expense' | 'transfer' | 'settlement' | 'repayment'>('expense')
  const [amount, setAmount] = useState('')
  const [description, setDescription] = useState('')
  const [source, setSource] = useState('')
  const [destination, setDestination] = useState('')
  const [newAccountName, setNewAccountName] = useState('')
  const [newAccountKind, setNewAccountKind] = useState('bank')
  const postingRef = useRef(false)
  const requestRef = useRef<{ signature: string; id: string } | null>(null)
  const [posting, setPosting] = useState(false)

  useEffect(() => {
    if (!supabase) { setLoading(false); return }
    void supabase.auth.getSession().then(({ data }) => { setSession(data.session); setLoading(false) })
    const { data: listener } = supabase.auth.onAuthStateChange((authEvent, next) => { setSession(next); if (authEvent === 'PASSWORD_RECOVERY') setRecovery(true) })
    return () => listener.subscription.unsubscribe()
  }, [])

  async function refresh() {
    if (!supabase) return
    const [a, e, f, l] = await Promise.all([supabase.from('account_balances').select('id,name,kind,currency,opening_balance_minor,balance_minor').order('name'), supabase.from('financial_events').select('id,kind,amount_minor,currency,description,created_at,source_account_id,destination_account_id').order('created_at', { ascending: false }).limit(100), supabase.from('accounting_flags').select('flag_key,description,status').eq('status','unresolved'), supabase.from('legacy_primary_transactions').select('legacy_id,transaction_date,business,transaction_type,description,amount').order('transaction_date',{ascending:false}).limit(20)])
    if (a.error || e.error || f.error || l.error) { setError(a.error?.message ?? e.error?.message ?? f.error?.message ?? l.error?.message ?? 'Could not load ledger'); return }
    setAccounts(a.data ?? []); setEntries(e.data ?? []); setFlags(f.data ?? []); setLegacyEntries(l.data ?? [])
    if (!source && a.data?.[0]) setSource(a.data[0].id)
    if (!destination && a.data?.[1]) setDestination(a.data[1].id)
  }
  useEffect(() => {
    if (!session || !supabase) { setAuthorised(null); return }
    void supabase.from('owner_allowlist').select('user_id').eq('user_id', session.user.id).maybeSingle().then(({ data, error: accessError }) => {
      if (accessError || !data) { setAuthorised(false); return }
      setAuthorised(true); void refresh()
    })
  }, [session])

  async function signIn(event: FormEvent) {
    event.preventDefault(); setError('');
    if (!supabase) return
    const { error: e } = await supabase.auth.signInWithPassword({ email, password })
    if (e) setError(e.message)
  }
  async function setOwnerPassword(event: FormEvent) {
    event.preventDefault(); setError('')
    if (!supabase) return
    if (newPassword.length < 12 || newPassword !== confirmPassword) { setError('Use at least 12 characters and confirm the same password.'); return }
    const { error: updateError } = await supabase.auth.updateUser({ password: newPassword })
    if (updateError) { setError(updateError.message); return }
    setNewPassword(''); setConfirmPassword(''); setRecovery(false)
    window.history.replaceState({}, '', window.location.pathname)
  }
  async function submitEntry(event: FormEvent) {
    event.preventDefault(); setError(''); setNotice('')
    if (postingRef.current) return
    if (!supabase) return
    const cents = Math.round(Number(amount) * 100)
    if (!Number.isSafeInteger(cents) || cents <= 0) { setError('Enter an amount greater than zero.'); return }
    if (!description.trim()) { setError('Add a description for this entry.'); return }
    if ((action === 'transfer' || action === 'settlement' || action === 'repayment') && (!source || !destination || source === destination)) { setError('Choose two different accounts.'); return }
    const signature = JSON.stringify({ action, cents, description: description.trim(), source, destination })
    if (!requestRef.current || requestRef.current.signature !== signature) requestRef.current = { signature, id: crypto.randomUUID() }
    const args = { p_request_id: requestRef.current.id, p_amount_minor: cents, p_currency: accounts.find(a => a.id === source)?.currency ?? 'INR', p_description: description.trim() }
    postingRef.current = true; setPosting(true)
    let result
    try {
      if (action === 'transfer') result = await supabase.rpc('post_transfer', { ...args, p_source_account: source, p_destination_account: destination })
      else if (action === 'settlement') result = await supabase.rpc('post_invoice_settlement', { ...args, p_source_account: source, p_destination_account: destination })
      else if (action === 'repayment') result = await supabase.rpc('post_card_repayment', { ...args, p_source_account: source, p_destination_account: destination })
      else result = await supabase.rpc('post_simple_entry', { ...args, p_account: source, p_kind: action })
      if (result.error) { setError(result.error.message); return }
      requestRef.current = null
      setNotice('Entry recorded.'); setAmount(''); setDescription(''); await refresh()
    } catch (e) { setError(e instanceof Error ? e.message : 'Could not save entry. Retry safely.') }
    finally { postingRef.current = false; setPosting(false) }
  }

  async function addAccount(event: FormEvent) {
    event.preventDefault(); setError(''); setNotice('')
    if (!supabase || !newAccountName.trim()) return
    const { error: accountError } = await supabase.from('accounts').insert({ name: newAccountName.trim(), kind: newAccountKind, currency: 'INR' })
    if (accountError) { setError(accountError.message); return }
    setNewAccountName(''); setNotice('Account created. Opening balance is zero until verified figures are imported.'); await refresh()
  }

  if (!configured) return <main className="setup"><div className="brand">SA<span>·</span></div><p className="eyebrow">SAKACCOUNTS · PRIVATE FINANCE</p><h1>Connect your ledger.</h1><p className="subtle">Add the Supabase project URL and publishable key to the app environment to enable owner sign-in.</p><div className="setup-card"><b>Required configuration</b><code>VITE_SUPABASE_URL</code><code>VITE_SUPABASE_PUBLISHABLE_KEY</code><span>Service role keys and database passwords stay on the server.</span></div></main>
  if (loading) return <main className="setup"><div className="brand">SA<span>·</span></div><p className="subtle">Connecting securely…</p></main>
  if (!session) return <main className="login"><div className="login-brand"><div className="brand">SA<span>·</span></div><p className="eyebrow">SAKACCOUNTS · PRIVATE FINANCE</p><h1>Your books,<br/>in balance.</h1><p className="subtle">A clear view of every account and every movement.</p><div className="login-foot">OWNER ACCESS ONLY <i/> ENCRYPTED LEDGER</div></div><form className="login-card" onSubmit={signIn}><p className="eyebrow">WELCOME BACK</p><h2>Sign in</h2><p className="subtle">Use the authorised owner account.</p><label>Email address<input type="email" autoComplete="username" required value={email} onChange={e => setEmail(e.target.value)} placeholder="you@example.com"/></label><label>Password<input type="password" autoComplete="current-password" required value={password} onChange={e => setPassword(e.target.value)} placeholder="Enter your password"/></label>{error && <p className="error">{error}</p>}<button className="primary">Sign in <span>→</span></button><div className="secure">● &nbsp;Protected by Supabase Auth</div></form></main>

  if (authorised === null) return <main className="setup"><div className="brand">SA</div><p className="subtle">Checking owner access...</p></main>
  if (!authorised) return <main className="setup"><div className="brand">SA</div><h1>Access restricted</h1><p className="subtle">This account is not authorised for SakAccounts.</p><button className="outline" onClick={() => void supabase?.auth.signOut()}>Sign out</button></main>

  if (recovery) return <main className="setup"><div className="brand">SA</div><form className="login-card" onSubmit={setOwnerPassword}><p className="eyebrow">OWNER SETUP</p><h2>Set your password</h2><p className="subtle">Choose a new password for SakAccounts.</p><label>New password<input type="password" autoComplete="new-password" minLength={12} required value={newPassword} onChange={e => setNewPassword(e.target.value)}/></label><label>Confirm password<input type="password" autoComplete="new-password" minLength={12} required value={confirmPassword} onChange={e => setConfirmPassword(e.target.value)}/></label>{error && <p className="error">{error}</p>}<button className="primary">Save password</button></form></main>

  const cashAccounts = accounts.filter(a => a.kind === 'cash' || a.kind === 'bank')
  const total = cashAccounts.reduce((sum, a) => sum + Number(a.balance_minor), 0)
  const currency = accounts[0]?.currency ?? 'INR'
  return <main className="app"><header><div className="brand small">SA<span>·</span></div><nav><a className="active">Overview</a><a>Transactions</a><a>Accounts</a></nav><div className="user-pill"><span className="avatar">{session.user.email?.[0]?.toUpperCase() ?? 'O'}</span><span>{session.user.email}</span><button onClick={() => void supabase?.auth.signOut()}>Sign out</button></div></header><section className="welcome"><div><p className="eyebrow">{new Date().toLocaleDateString("en-IN", { weekday: "long", day: "numeric", month: "long", year: "numeric" }).toUpperCase()}</p><h1>Good to see you.</h1><p className="subtle">Here’s the latest across your accounts.</p></div><button className="outline" onClick={() => void refresh()}>↻ &nbsp;Refresh</button></section>{flags.length > 0 && <section className="flag-banner"><b>Opening figures need reconciliation</b><p>Earlier SakAccounts records are preserved in Supabase. Review the local and former VPS snapshots before treating balances as final.</p></section>}<section className="summary"><div className="balance"><div className="card-top"><span>Cash &amp; bank balance</span><span className="dots">•••</span></div><strong>{flags.length > 0 ? 'Pending reconciliation' : money(total / 100, currency)}</strong><div className="balance-bottom"><span>Across {cashAccounts.length} cash and bank accounts</span><span className="balance-icon">↗</span></div></div><div className="stat"><span>Accounts</span><strong>{accounts.length}</strong><small>In your ledger</small></div><div className="stat"><span>Recent entries</span><strong>{entries.length}</strong><small>Latest 100 records</small></div></section><section className="account-setup"><div><h2>Accounts</h2><p className="subtle">Add a bank, cash, card, or receivable account before recording movements.</p></div><form onSubmit={addAccount}><input aria-label="Account name" required maxLength={120} value={newAccountName} onChange={e => setNewAccountName(e.target.value)} placeholder="New account name"/><select aria-label="Account type" value={newAccountKind} onChange={e => setNewAccountKind(e.target.value)}><option value="bank">Bank</option><option value="cash">Cash</option><option value="credit_card">Credit card</option><option value="receivable">Receivable</option><option value="payable">Payable</option><option value="other">Other</option></select><button type="submit">Add account</button></form></section><section className="columns"><div className="panel"><div className="panel-head"><div><h2>Recent activity</h2><p className="subtle">Your latest financial movements</p></div><button className="link-button" onClick={() => void refresh()}>View all <span>→</span></button></div>{entries.length === 0 ? <div className="empty"><div>↗</div><b>Your ledger is ready</b><p>Record your first movement to get started.</p></div> : <div className="activity">{entries.slice(0,8).map(e => <div className="entry" key={e.id}><span className={`entry-icon ${e.kind}`}>{e.kind === 'income' || e.kind === 'invoice_settlement' ? '↓' : e.kind === 'transfer' ? '⇄' : '↑'}</span><div className="entry-name"><b>{e.description}</b><small>{e.kind.replaceAll('_',' ')} · {new Date(e.created_at).toLocaleDateString()}</small></div><strong>{e.kind === 'income' || e.kind === 'invoice_settlement' ? '+' : '−'}{money(Number(e.amount_minor)/100,e.currency)}</strong></div>)}</div>}</div><div className="panel form-panel"><div className="panel-head"><div><h2>Record movement</h2><p className="subtle">Post a ledger entry</p></div><span className="plus">＋</span></div><form onSubmit={submitEntry}><label>Movement type<select value={action} onChange={e => setAction(e.target.value as typeof action)}><option value="expense">Expense</option><option value="income">Income</option><option value="transfer">Transfer</option><option value="settlement">Invoice settlement</option><option value="repayment">Card repayment</option></select></label><div className="two"><label>Amount<input inputMode="decimal" type="number" min="0.01" step="0.01" required value={amount} onChange={e => setAmount(e.target.value)} placeholder="0.00"/></label><label>Currency<select value={accounts.find(a => a.id === source)?.currency ?? 'INR'} disabled><option>{accounts.find(a => a.id === source)?.currency ?? 'INR'}</option></select></label></div><label>{action === 'income' ? 'Deposit account' : 'From account'}<select required value={source} onChange={e => setSource(e.target.value)}><option value="">Choose account</option>{accounts.map(a => <option key={a.id} value={a.id}>{a.name} · {a.kind}</option>)}</select></label>{['transfer','settlement','repayment'].includes(action) && <label>{action === 'settlement' ? 'Invoice / receiving account' : action === 'repayment' ? 'Card account' : 'To account'}<select required value={destination} onChange={e => setDestination(e.target.value)}><option value="">Choose account</option>{accounts.filter(a => a.id !== source).map(a => <option key={a.id} value={a.id}>{a.name} · {a.kind}</option>)}</select></label>}<label>Description<input required maxLength={240} value={description} onChange={e => setDescription(e.target.value)} placeholder="What was this for?"/></label>{error && <p className="error">{error}</p>}{notice && <p className="notice">{notice}</p>}<button className="primary" disabled={posting}>Save entry <span>→</span></button></form></div></section><section className="panel legacy-panel"><div className="panel-head"><div><h2>Earlier SakAccounts records</h2><p className="subtle">Read-only records from the former VPS snapshot. Latest 20 of 4,691 transactions.</p></div></div><div className="activity">{legacyEntries.map(e => <div className="entry" key={e.legacy_id}><span className="entry-icon transfer">{e.transaction_type?.slice(0,1).toUpperCase()}</span><div className="entry-name"><b>{e.description || e.transaction_type}</b><small>{e.transaction_date} | {e.business} | {e.transaction_type}</small></div><strong>{money(Number(e.amount), 'INR')}</strong></div>)}</div></section><footer>SAKACCOUNTS <i/> PRIVATE OWNER LEDGER <span>SECURED WITH SUPABASE</span></footer></main>
}
