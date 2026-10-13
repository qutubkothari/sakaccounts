import express from 'express'
import { existsSync } from 'node:fs'
import { resolve } from 'node:path'

const app = express()
const port = Number(process.env.PORT || 4178)
const host = process.env.HOST || '127.0.0.1'
const dist = resolve('dist')
app.get('/healthz', (_req, res) => res.json({ status: 'ok', service: 'sakaccounts' }))
if (!existsSync(dist)) throw new Error('dist/ is missing; run npm run build first')
app.use(express.static(dist, { maxAge: '1h', index: false }))
app.get('*splat', (_req, res) => res.sendFile(resolve(dist, 'index.html')))
app.listen(port, host, () => console.log(`SakAccounts listening on ${host}:${port}`))
