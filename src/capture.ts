export type CaptureSuggestion = {
  amount?: string
  currency?: 'INR' | 'AED'
  date?: string
  merchant?: string
  reference?: string
  category?: string
  accountLastFour?: string
  paymentHint?: 'card' | 'bank'
  kind?: 'expense' | 'income'
  warnings: string[]
}

const amountPattern = '(?:₹|rs\\.?|inr|aed|dhs?\\.?|د\\.إ)?\\s*([0-9][0-9,]*(?:\\.[0-9]{1,2})?)'

function dateFromText(text: string): string | undefined {
  const numeric = text.match(/\b(\d{1,2})[\/-](\d{1,2})[\/-](\d{2,4})\b/)
  if (numeric) {
    const year = Number(numeric[3]) + (numeric[3].length === 2 ? 2000 : 0)
    const month = Number(numeric[2]), day = Number(numeric[1])
    const value = new Date(Date.UTC(year, month - 1, day))
    if (value.getUTCFullYear() === year && value.getUTCMonth() === month - 1 && value.getUTCDate() === day)
      return `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`
  }
  const named = text.match(/\b(\d{1,2})[\s-](Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*[\s,-]*(\d{2,4})\b/i)
  if (named) {
    const month = ['jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec'].indexOf(named[2].slice(0,3).toLowerCase()) + 1
    const year = Number(named[3]) + (named[3].length === 2 ? 2000 : 0)
    return `${year}-${String(month).padStart(2, '0')}-${String(named[1]).padStart(2, '0')}`
  }
  const iso = text.match(/\b(20\d{2})-(\d{2})-(\d{2})\b/)
  return iso?.[0]
}

function categoryFromText(text: string): string | undefined {
  const rules: [RegExp, string][] = [
    [/advertis|\bads?\b|meta ads|google ads/i, 'Advertising'],
    [/fuel|petrol|diesel|shell|hpcl|iocl/i, 'Fuel'],
    [/uber|ola|taxi|cab|parking|toll/i, 'Travel'],
    [/swiggy|zomato|restaurant|cafe|food/i, 'Meals'],
    [/internet|broadband|mobile bill|recharge/i, 'Internet & phone'],
    [/electricity|power bill|water bill/i, 'Utilities'],
    [/rent|lease/i, 'Rent'],
    [/courier|shipping|delivery charge/i, 'Shipping'],
  ]
  return rules.find(([pattern]) => pattern.test(text))?.[1]
}

export function extractExpenseText(source: string): CaptureSuggestion {
  const text = source.replace(/\u00a0/g, ' ').trim()
  const warnings: string[] = []
  if (!text) return { warnings: ['Paste a message or scan a readable photo first.'] }
  const total = text.match(new RegExp(`(?:grand\\s+total|amount\\s+paid|net\\s+amount|total|amount|spent|debited|charged|paid)\\s*(?::|is|of)?\\s*${amountPattern}`, 'i'))
  const currencyFirst = text.match(new RegExp(`(?:₹|rs\\.?|inr|aed|dhs?\\.?|د\\.إ)\\s*([0-9][0-9,]*(?:\\.[0-9]{1,2})?)`, 'i'))
  const amountRaw = total?.[1] ?? currencyFirst?.[1]
  const parsedAmount = amountRaw ? Number(amountRaw.replace(/,/g, '')) : NaN
  const amount = Number.isFinite(parsedAmount) && parsedAmount > 0 ? parsedAmount.toFixed(2) : undefined
  const currency = /\b(?:aed|dhs?)\b|د\.إ/i.test(text) ? 'AED' : /₹|\b(?:rs\.?|inr)\b/i.test(text) ? 'INR' : undefined
  const merchantMatch = text.match(/\b(?:at|to|merchant)\s+([a-z0-9][a-z0-9 .&'()-]{1,48}?)(?=\s+(?:on|dated|using|via|from|ref|txn|avl|available|bal|with)\b|[,;\n.]|$)/i)
  const firstLine = text.split(/\r?\n/).map(x => x.trim()).find(x => x && !/^(tax invoice|invoice|receipt|bill|date|total|amount|gst)/i.test(x))
  const merchant = (merchantMatch?.[1] ?? (text.includes('\n') ? firstLine : undefined))?.trim()
  const reference = text.match(/\b(?:ref(?:erence)?|txn(?:\s*id)?|utr|invoice\s*(?:no\.?|#))\s*[:#-]?\s*([a-z0-9-]{5,30})\b/i)?.[1]
  const card = /\b(?:credit\s*card|card|cc)\b/i.test(text)
  const bank = /\b(?:debited|upi|bank\s*account|a\/c|account|netbanking)\b/i.test(text)
  const accountLastFour = text.match(/(?:card|a\/c|account|ending|xx|x{2,}|\*{2,})[\s:*x#-]*(\d{4})\b/i)?.[1]
  const kind = /\b(?:credited|received|deposited|refund received)\b/i.test(text) && !/\b(?:debited|spent|paid|charged|purchase)\b/i.test(text) ? 'income' : 'expense'
  if (!amount) warnings.push('Amount was not clear; enter it manually.')
  if (!merchant) warnings.push('Merchant was not clear; check the name.')
  if (!dateFromText(text)) warnings.push('Date was not clear; the form keeps today until you change it.')
  if (!currency) warnings.push('Currency was not shown; check the selected entity.')
  if (kind === 'income') warnings.push('This looks like money received. Check that it is earned income before posting.')
  return { amount, currency, date: dateFromText(text), merchant, reference, category: categoryFromText(text), accountLastFour, paymentHint: card ? 'card' : bank ? 'bank' : undefined, kind, warnings }
}
