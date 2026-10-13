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

- SakAccounts runs on the existing Hostinger VPS at `200.141.1.206` as the separate `sakaccounts` Linux user and `sakaccounts.service`. It binds to `127.0.0.1:4178`; Nginx serves `https://accounts.saksolution.com/` with HTTPS. Mizantra services and database remain separate.
- The current release is `/opt/sakaccounts/releases/workflows-20261013b`, selected by `/opt/sakaccounts/current`. The previous release remains available for rollback.
- The owner Auth login `sales@saksolution.com` and `qutubk` administrator login remain. Public signup is disabled.
- At the owner's direction, all SakAccounts financial records and imported legacy snapshots were cleared. The original external SQLite source files were not changed. Five empty entity configuration rows remain, with no verified opening balances.
- Migrations through `202610130017_split_guards.sql` are applied. `tests/accounting.sql` passes inside a rolled-back transaction, including RLS, duplicate staging, card and transfer invariants, adjustments, financing, and split expenses. Build and `npm audit` passed. The public HTTPS route and local health endpoint returned success.

## Health checks and rollback

Run `curl -fsS http://127.0.0.1:4178/healthz` on the VPS, open `https://accounts.saksolution.com/`, and check `systemctl status sakaccounts` and `journalctl -u sakaccounts`. Do not include environment values in shared logs.

For an application rollback, point `/opt/sakaccounts/current` to the prior release under `/opt/sakaccounts/releases`, restart `sakaccounts`, and repeat the health checks. SQL migrations are forward-only; database changes need reviewed forward migrations. Financial data must not be dropped as a rollback step.

## Application administrator

- `qutubk` signs in through the app's username field. Supabase Auth uses the internal identity `qutubk@accounts.saksolution.com`; this is an application login identifier, not a configured mailbox.
- The identity is allowlisted with `app_role=super_admin`. This role is stored in SakAccounts, without Supabase service-role or PostgreSQL administrator privileges. RLS grants the administrator access to owner records. Posting functions attribute entries to the owner of the selected account and require both sides of a transfer to have the same owner. New accounts created in the current single-owner dashboard are attributed to the existing owner.
- Rotate the administrator password through Supabase Auth when needed. Do not store it in this repository or the VPS environment file.
