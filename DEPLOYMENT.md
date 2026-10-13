# SakAccounts deployment

## Separation and configuration

Use its own `/opt/sakaccounts` directory, `sakaccounts` Linux user, `/etc/sakaccounts/sakaccounts.env`, systemd unit, and internal port `4178`. The example service binds the app to loopback. It uses the hosted Supabase project for persistence and Auth; do not copy Mizantra database configuration or secrets.

Create the server environment file with restrictive permissions. Runtime values are `PORT=4178`, `HOST=127.0.0.1`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `VAPID_PUBLIC_KEY`, and `VAPID_PRIVATE_KEY`. The `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`, and public `VITE_VAPID_PUBLIC_KEY` values must be available at build time. Store no Supabase service key, VAPID private key, or database password in Git or frontend assets. Keep migration-only credentials in an operator shell or secret manager. The push worker reads owner-scoped subscriptions and runs every 15 minutes; it sends only a generic alert count and daily reminder.

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

- SakAccounts runs on the existing Hostinger VPS at `200.141.1.206` as the separate `sakaccounts` Linux user and `sakaccounts.service`. It binds to `127.0.0.1:4178`; Nginx serves `https://accounts.saksolution.com/` with HTTPS. Mizantra services and database remain separate.
- The current release is `/opt/sakaccounts/releases/pwa-20261013i`, selected by `/opt/sakaccounts/current`. Release `pwa-20261013g` remains the last healthy rollback. The dashboard shows daily priorities and actionable financial review signals. Reports include month over month and budget variance. The PWA reads invoice and expense photos/PDFs on the device and can send owner-enabled background push alerts.
- The owner Auth login `sales@saksolution.com` and `qutubk` administrator login remain. Public signup is disabled.
- At the owner's direction, all SakAccounts financial records and imported legacy snapshots were cleared. The original external SQLite source files were not changed. Five empty entity configuration rows remain, with no verified opening balances.
- Migrations through `202610130023_push_worker_grants.sql` are applied. `tests/accounting.sql` passed inside a rolled-back transaction on 13 October 2026, covering RLS, duplicate staging, card and transfer invariants, adjustments, financing, and split expenses. Live PDF invoice reading filled supplier, invoice number and amount from a synthetic file; photo receipt reading filled amount, merchant and category. Neither synthetic document was saved. The push worker starts without database permission errors; real delivery depends on the owner enabling alerts on a device. No test financial rows remain; both logins remain.

## Health checks and rollback

Run `curl -fsS http://127.0.0.1:4178/healthz` on the VPS, open `https://accounts.saksolution.com/`, and check `systemctl status sakaccounts` and `journalctl -u sakaccounts`. Do not include environment values in shared logs.

For an application rollback, point `/opt/sakaccounts/current` to the prior release under `/opt/sakaccounts/releases`, restart `sakaccounts`, and repeat the health checks. SQL migrations are forward-only; database changes need reviewed forward migrations. Financial data must not be dropped as a rollback step.

## Application administrator

The current statement import fix is `/opt/sakaccounts/releases/statement-fix-20261013-real`. It accepts CSV and XLSX source uploads and parses card `(Dr)` and `(Cr)` amounts. The previous healthy rollback is `/opt/sakaccounts/releases/pwa-20261013g`. The `pwa-20261013i` directory was touched during publication and must not be selected for rollback.

- `qutubk` signs in through the app's username field. Supabase Auth uses the internal identity `qutubk@accounts.saksolution.com`; this is an application login identifier, not a configured mailbox.
- The identity is allowlisted with `app_role=super_admin`. This role is stored in SakAccounts, without Supabase service-role or PostgreSQL administrator privileges. RLS grants the administrator access to owner records. Posting functions attribute entries to the owner of the selected account and require both sides of a transfer to have the same owner. New accounts created in the current single-owner dashboard are attributed to the existing owner.
- Rotate the administrator password through Supabase Auth when needed. Do not store it in this repository or the VPS environment file.

## Phone capture release

The 13 October 2026 PWA release adds a quick expense/income form, camera receipt capture, local OCR, SMS extraction, installable manifest and service worker, mobile bottom navigation, and local offline drafts. See [PWA.md](PWA.md) for usage and limits. The live browser check read a sample receipt photo and restored its saved draft after reload; the temporary local draft was discarded. No production financial row was posted in that check.
