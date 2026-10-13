# SakAccounts deployment

## Separation and configuration

Use its own `/opt/sakaccounts` directory, `sakaccounts` Linux user, `/etc/sakaccounts/sakaccounts.env`, systemd unit, and internal port `4178`. The example service binds the app to loopback. It uses the hosted Supabase project for persistence and Auth; do not copy Mizantra database configuration or secrets.

Create the server environment file with restrictive permissions. Runtime values are `PORT=4178` and `HOST=127.0.0.1`. The `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` values must be available at build time. Store no Supabase service key or database password in Git or frontend assets. Keep any migration-only credentials in an operator shell or secret manager.

## Host installation

1. Confirm the VPS distribution, free disk/RAM, current firewall, systemd, Nginx/Caddy, DNS, occupied ports, and Mizantra service layout. Select a hostname assigned to SakAccounts and point its DNS A/AAAA records to the VPS.
2. Install a supported Node.js LTS and create the dedicated user and directories. Copy the repository into `/opt/sakaccounts/releases/<git-sha>`, install with `npm ci`, inject build configuration, and run `npm run build`. Point `/opt/sakaccounts/current` to the release.
3. Install `deploy/sakaccounts.service.example` as `/etc/systemd/system/sakaccounts.service`; install a root-owned mode-600 environment file at `/etc/sakaccounts/sakaccounts.env`. Enable and start the service.
4. Copy `deploy/nginx.sakaccounts.example`, replace `SAK_HOSTNAME`, validate it, and reload Nginx. Request a Let's Encrypt certificate for this hostname, then validate and reload the HTTPS configuration. Add only this host route; preserve Mizantra's virtual hosts and services.

## Health checks

- Local: `curl -fsS http://127.0.0.1:4178/healthz` should return `{"status":"ok","service":"sakaccounts"}`.
- Public: `curl -I https://<SAK_HOSTNAME>/` should return a successful HTTPS response and the browser should show the owner sign-in screen.
- Sign in as the allowlisted owner, create a test transaction, reload, and verify persistence. Verify non-owner denial and duplicate/retry idempotency in Supabase before entering real financial records.
- Inspect `systemctl status sakaccounts`, `journalctl -u sakaccounts`, and Nginx logs. Do not include environment values when sharing logs.

## Rollback

Keep each release directory. To roll back, repoint `/opt/sakaccounts/current` to the previous release and restart `sakaccounts`. The migration is additive and uses its own schema; app rollback does not reverse it. Do not drop the schema as a rollback step because that would delete financial data. Database rollback must use a reviewed forward migration.

## Installation state on 13 October 2026

- The Hostinger VPS is `200.141.1.206`. SakAccounts runs as user `sakaccounts`, service `sakaccounts.service`, loopback port `4178`, with releases under `/opt/sakaccounts/releases` and environment file `/etc/sakaccounts/sakaccounts.env`. The service and its local health endpoint are active.
- Nginx has its own `accounts.saksolution.com.conf` route on port 80. A host-header health check reaches SakAccounts. No prior mapping for this host was found in VPS Nginx configuration.
- The Supabase schema was inspected before migration: it had no application tables or Auth users. Three version-controlled migrations are applied. The owner Auth account for `sales@saksolution.com` exists and is allowlisted. The installation password was discarded. A recovery link was opened in the user's browser for the owner to set a password.
- Live RLS checks showed anonymous allowlist access rejected, owner access allowed, non-owner reads empty, and non-owner inserts denied. All four posting operations and duplicate retry behavior were exercised with temporary records, then those records were deleted. The financial tables are empty and one owner is allowlisted.
- `accounts.saksolution.com` resolves to `200.141.1.206`. Its Nginx route has a Let's Encrypt certificate and redirects HTTP to HTTPS. The public health endpoint and sign-in page load over HTTPS.
- Public signup is disabled. Supabase Auth Site URL and the sole redirect URL point to `https://accounts.saksolution.com/`.
- Two earlier SQLite databases were found in the separate local `SAK-Accounts` folder and its former VPS. Both snapshots were imported into `sakaccounts.legacy_snapshot_records` with source labels and checksums. The former VPS snapshot is the selected primary source, available in read-only views. A divergence flag remains open because the local snapshot contains additional and changed records. The temporary transfer files were removed; original source databases remain untouched.

## Remaining data inputs

- Reconcile the local-only and changed legacy records against the primary VPS snapshot before mapping legacy transactions into the new posting model. Opening balances remain in the owner-only archive and are intentionally not counted as final in the new ledger until reconciliation.
- The earlier app included vendors, inventory, imports, document capture, business P&L, and other workflows. Those are preserved as raw records but are not yet implemented in the new owner dashboard. See `ACCOUNTING_MIGRATION.md`.
