ERPNext Docker stack
====================

Docker Compose stack for [ERPNext](https://erpnext.com) (open source ERP on
the Frappe framework: accounting, sales, purchasing, inventory, ...), usable
for local development and for simple production deployments (a single
server). Maintained by [BillMySales](https://www.billmysales.com).

| Component   | Image                             | Default version     |
|-------------|-----------------------------------|---------------------|
| Web server  | `caddy:<ver>-alpine`              | 2.11                |
| ERPNext     | `frappe/erpnext:<ver>` (official) | v16.36.0 (Frappe 16.35) |
| Database    | `mariadb`                         | 11.8 (LTS)          |
| Redis       | `redis:<ver>-alpine`              | 8.6                 |
| Mailpit     | `axllent/mailpit` (optional, dev) | v1.31               |

The ERPNext image is Frappe's official production image (the one
[frappe_docker](https://github.com/frappe/frappe_docker) builds, for amd64 and
arm64): Python, Node.js, nginx, wkhtmltopdf and the built assets. MariaDB and
Redis versions are the ones frappe_docker uses. Nothing is built locally.

Requirements
------------

- Docker Engine 24+ with the Compose v2 plugin (`docker compose`, 2.20+).
- About 3.5 GB of disk for the images; 2 GB of RAM or more.
- Development: ports 8109, 8409 and 8025 free on the host.
- Production: a server with ports 80 and 443 reachable, and a DNS record for
  the site's domain pointing to it.

Quick start (development)
-------------------------

```shell
cp .env.dev.example .env
docker compose up -d
docker compose logs -f setup   # wait for "==> Done" (about 1.5 minutes)
```

- ERPNext: http://erp.localhost:8109 (user `manager@example.com` or
  `Administrator`, password `admin12345`). Not `localhost`: see
  [PDFs](#pdfs-and-the-site-url). Not `admin@example.com`: Frappe's
  install unsubscribes it (and `guest@example.com`) from all emails, as the
  placeholder addresses of its Administrator and Guest users.
- Mailpit (every email ERPNext sends): http://localhost:8025

Production
----------

```shell
cp .env.prod.example .env
# Fill in ERPNEXT_URL, ERPNEXT_HOST, SITE_ADDRESS, DB_ROOT_PASSWORD,
# ERPNEXT_ADMIN_PASSWORD, ERPNEXT_ADMIN_EMAIL, the company values and the
# SMTP_* values.
docker compose up -d
```

- With `SITE_ADDRESS` set to the domain, Caddy gets a Let's Encrypt certificate
  and renews it automatically (certificates live in the `caddy_data` volume).
- Behind another TLS-terminating proxy, use `SITE_ADDRESS=:80`: the scheme
  and the client IP are passed on with `X-Forwarded-*` headers.
- Compose refuses to start while a required value is missing.
- Configure SMTP: without it ERPNext can't send any mail (documents, password
  resets, notifications).
- The `backup` profile is enabled by default in the production template.
- Behind an existing Traefik (no host ports), use `overrides/traefik.yaml`
  (see [Overrides](#overrides)).

Services
--------

| Service       | Profile   | Role                                                          |
|---------------|-----------|---------------------------------------------------------------|
| `db`          |           | MariaDB, data in the `db_data` volume.                        |
| `redis-cache` |           | Cache (in memory only).                                       |
| `redis-queue` |           | Job queue and real-time events (persisted).                   |
| `setup`       |           | One-shot job (`scripts/setup.sh`), runs on every `up`.        |
| `backend`     |           | Gunicorn (the Python app), internal.                          |
| `websocket`   |           | Socket.IO server (real-time updates), internal.               |
| `frontend`    |           | The image's nginx: assets, files, routing; internal.          |
| `queue-short` |           | Background job worker (short and default queues).             |
| `queue-long`  |           | Background job worker (long queue: reports, imports).         |
| `scheduler`   |           | Scheduled jobs (email queue, recurring documents, ...).       |
| `caddy`       |           | TLS and public address, the only published ports (80, 443).   |
| `backup`      | `backup`  | Site backup (database, files, config) on a schedule.          |
| `mailpit`     | `mailpit` | Development SMTP server that catches all mail.                |
| `bench`       | `tools`   | `bench` commands for the site, not started by `up`.           |

Optional services are enabled with `COMPOSE_PROFILES` in `.env`, e.g.
`COMPOSE_PROFILES=backup`.

Caddy forwards everything to the image's own nginx, as frappe_docker does:
the assets (JS/CSS) are built into the image and linked into the `sites`
volume when each container starts, so they always match the running version.

### What `setup` does

- Writes the bench configuration (database, Redis, Socket.IO).
- No site yet: creates it (`bench new-site`, site name `ERPNEXT_SITE`) with
  ERPNext and the `Administrator` password, and the key used to encrypt
  stored passwords. Then, only once, the setup wizard: company
  (`ERPNEXT_COMPANY_NAME`, `ERPNEXT_COMPANY_ABBR`), country
  (`ERPNEXT_COUNTRY`), currency (`ERPNEXT_CURRENCY`), time zone, language
  (`ERPNEXT_LANG`), chart of accounts, fiscal year (starting this year on
  `ERPNEXT_FISCAL_YEAR_START`) and the first user (`ERPNEXT_ADMIN_EMAIL`, a
  System Manager). It also makes amounts use each currency's number format
  (CLP: `$ 12.345`, no decimals) and starts the scheduled jobs from the
  current time. Later changes made in ERPNext are kept.
- New image (`ERPNEXT_VERSION` changed): empties the Redis cache and runs
  `bench migrate` (Frappe's upgrade path, also between major versions, see
  [Upgrades](#upgrades)). An image older than the site is refused.
- On every run: the site URL (`host_name`, used in emails and background jobs)
  and the default mail server, from the environment.

Common commands
---------------

```shell
docker compose ps                         # status: every service "healthy", setup "Exited (0)"
docker compose logs -f backend frontend   # app and nginx logs
docker compose run --rm bench console     # Python console with the site loaded
docker compose run --rm bench list-apps   # any `bench --site <site>` command
docker compose exec db mariadb -u root -p # SQL shell
docker compose down                       # stop, keep data
docker compose down -v                    # stop and DELETE all data
```

Don't run `bench build`, `bench get-app` or `pip install` in the containers:
the code and assets come from the image (see [Custom apps](#custom-apps)).

Point of sale
-------------

The point of sale is part of ERPNext (Selling > Point of Sale,
`/app/point-of-sale`), but it needs a POS Profile before it can be used:

1. Give the payment methods an account: Accounting > Mode of Payment >
   `Cash` > Accounts: the company and its cash account (e.g. `Efectivo - MC`).
   Without it, sales fail with "Account is required". Same for any other
   method used (e.g. `Credit Card` with a bank account).
2. Create a POS Profile (Selling > POS Profile): company, warehouse, currency
   (CLP), price list (`Standard Selling`), write-off account and cost center,
   and the payment methods (one of them default).
3. Open Point of Sale: it asks for an opening entry (cash on hand) for the
   profile, then sells. In ERPNext 16 each sale is a Sales Invoice (POS
   settings' "Sales Invoice mode"); close the day with a POS Closing Entry.

Backups
-------

With the `backup` profile, the `backup` service runs `bench backup
--with-files` at start and then every `BACKUP_INTERVAL_HOURS`, into
`/backups/<timestamp>/` in the `backups` volume (or `./data/backups` with
`overrides/local-dirs.yaml`): database dump, public files, private files and
the site config (with the encryption key of stored passwords). Backups older
than `BACKUP_KEEP_DAYS` are deleted. Files are readable by their owner only.

```shell
docker compose run --rm --no-deps backup now                  # back up now
docker compose run --rm --no-deps backup list                 # list timestamps
docker compose stop backend websocket frontend queue-short queue-long scheduler
docker compose run --rm --no-deps backup restore <timestamp>  # database, files, encryption key
docker compose up -d
```

`--no-deps` keeps the command from starting `setup` first (with damaged
data `setup` fails and the restore would never run); the database and
Redis must be running (`docker compose up -d db redis-cache redis-queue`
if the stack is down).

A restore replaces the database and the files, puts back the backup's
encryption key and runs `bench migrate` (the backup may come from an older
version). It also works on a new server with a fresh install of this stack,
and with a backup taken on an older ERPNext (a v15 backup restores into v16).

Upgrades
--------

Back up first, then change `ERPNEXT_VERSION` in `.env` and run
`docker compose up -d`: `setup` empties the Redis cache and runs
`bench migrate`, then the app services start on the new image. Minor
versions take about a minute; v15 → v16 took under two minutes on a small
site (91 patches). The site is down (`502`) while `setup` migrates.

If the migration fails, the app services don't start: fix the cause and run
`docker compose up -d` again (`bench migrate` resumes), or go back with the
previous `ERPNEXT_VERSION` and `backup restore <timestamp>` of the backup
taken before the upgrade.

Overrides
---------

Optional compose files in `overrides/`, enabled with `COMPOSE_FILE` in `.env`
(several are combined with `:`). Each file documents its variables.

```shell
COMPOSE_FILE=compose.yaml:overrides/traefik.yaml:overrides/local-dirs.yaml
```

| File                        | Purpose                                                            |
|-----------------------------|--------------------------------------------------------------------|
| `overrides/traefik.yaml`    | Publish through an existing Traefik on a shared external network:  |
|                             | no host ports, Traefik terminates TLS (`TRAEFIK_HOST`, ...).       |
| `overrides/local-dirs.yaml` | Database, sites, logs, Redis queue, Caddy and backups in local     |
|                             | directories (`DATA_DIR`, default `./data`) instead of volumes.     |

A local `compose.override.yaml` (gitignored) is also loaded automatically by
Docker Compose, for changes specific to one machine.

Custom apps
-----------

Frappe apps (like ERPNext itself) are Python packages with built assets, so
they are part of the image. To add apps, build an image with frappe_docker's
"layered" build (`images/layered/Containerfile` and an `apps.json` listing
the apps), push it, and set `ERPNEXT_IMAGE` and `ERPNEXT_VERSION` to it; then
install the app on the site:

```shell
docker compose up -d
docker compose run --rm bench install-app <app>
```

Configuration
-------------

Every variable is documented in `.env.prod.example`. Main groups:

- **Site and network**: `ERPNEXT_URL`, `ERPNEXT_HOST`, `SITE_ADDRESS`,
  `HTTP_BIND`, `HTTP_PORT`, `HTTPS_PORT`, `ERPNEXT_SITE`.
- **Credentials**: `DB_ROOT_PASSWORD`, `ERPNEXT_ADMIN_PASSWORD`,
  `ERPNEXT_ADMIN_EMAIL` (required).
- **Company** (first install only): `ERPNEXT_COMPANY_NAME`,
  `ERPNEXT_COMPANY_ABBR`, `ERPNEXT_COUNTRY`, `ERPNEXT_CURRENCY`,
  `ERPNEXT_TIMEZONE`, `ERPNEXT_LANG`, `ERPNEXT_CHART_OF_ACCOUNTS`,
  `ERPNEXT_FISCAL_YEAR_START`.
- **Versions**: `ERPNEXT_VERSION`, `ERPNEXT_IMAGE`, `MARIADB_VERSION`,
  `REDIS_VERSION`, `CADDY_VERSION`, ...
- **Server**: `GUNICORN_WORKERS`, `GUNICORN_THREADS`, `ERPNEXT_TIMEOUT`,
  `UPLOAD_MAX_SIZE` (nginx and Caddy).
- **Mail**: `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`, `SMTP_USER`,
  `SMTP_PASSWORD`, `SMTP_FROM`, `SMTP_FROM_NAME`.
- **Resources and logs**: `*_MEMORY_LIMIT` per service, `LOG_MAX_SIZE`,
  `LOG_MAX_FILE` (Docker log rotation).

### PDFs and the site URL

ERPNext renders PDFs (print formats, email attachments) with wkhtmltopdf,
which loads the page's CSS and images through the public `ERPNEXT_URL`. So
the containers that render them (`backend`, the workers, `scheduler`) resolve
`ERPNEXT_HOST` (the URL's host name) to the Docker host, where Caddy (or
Traefik) publishes the site. This works without depending on the server
reaching its own public address, and on local URLs, as long as the URL's port
is published on the host. The development URL is `erp.localhost` because
`localhost` can't be redirected (inside a container it's the container
itself); `*.localhost` names resolve to your machine in browsers and on
macOS. On Linux with `HTTP_BIND=127.0.0.1`, the Docker host doesn't accept
connections from containers on that port: use `HTTP_BIND=0.0.0.0` in
development (or a firewall).

Notes:

- The SMTP settings are the site's default outgoing mail server (Frappe's
  `mail_server` site config), used unless an Email Account in ERPNext is the
  default outgoing one. It supports STARTTLS (`SMTP_SECURE=tls`, port 587),
  not SMTPS (port 465); for that, add an Email Account. Mail is sent by the
  scheduler's email queue, every 4 minutes.
- ERPNext 16 creates its master data (item groups, units of measure) with
  English names also in `es-CL` (v15 translated them): e.g. `Services`,
  `Nos`.
- Chile has no verified chart of accounts in ERPNext (its template is
  "unverified", not offered by the wizard): the default is `Standard`.
- `ERPNEXT_SITE` is the internal site name (a directory and a database); the
  public address can be anything and can change. It can't be the name of an
  app (e.g. `erpnext`).
- The image's nginx sends `Strict-Transport-Security` with
  `includeSubDomains; preload`: browsers ignore it over plain HTTP, but on
  HTTPS it applies to every subdomain of the site's domain.
- From inside the containers, the host machine is reachable as
  `host.docker.internal` (`backend`).

Security
--------

- No default secrets: compose fails if the required passwords are missing. The
  development template uses public passwords; never use it on a server.
- ERPNext gets the real client IP (e.g. in its activity log) also behind
  Traefik.
- Only Caddy (and Mailpit in development) publishes ports; the app, database
  and Redis are internal. `HTTP_BIND` defaults to `127.0.0.1`.
- Not included: a web application firewall or off-site backup copies.

Validation
----------

What was checked for this stack (2026-09-24):

- Clean start (`down -v` + `up -d`) in about 85 s: every service `healthy`,
  `setup` `Exited (0)`; a second run makes no changes.
- Login (API), the desk (`/desk`) with all its CSS/JS and their fonts and
  images (`200`), Socket.IO (polling and websocket `101`).
- Company in Chile with CLP (`$`, no decimals), fiscal year 2026, `es-CL`,
  `America/Santiago`, scheduler enabled; users `Administrator` and the admin
  email.
- Mail through SMTP to Mailpit with the configured sender (email queue).
- Settings changed in ERPNext survive `setup`; `ERPNEXT_URL` change; upgrade
  v16.35.0 → v16.36.0 (`bench migrate`) and refusal of an older image.
- Upgrade v15.121.4 → v16.36.0 of a site with data (customer, item, a
  submitted sales invoice with its ledger entries, a private file, an API
  key): same records after the upgrade, API key and private file still
  working, invoice PDF correct. The first attempt failed on a stale Redis
  cache (hence the cache flush); a failed migration resumes with `up -d`.
- Restore of the v15 backup into the v16 stack (migrated on restore).
- Invoice PDF with its print styles and CLP amounts (`$ 29.970`), through
  `ERPNEXT_HOST`; the image's nginx is restarted when compose recreates the
  backend (otherwise it keeps the old address and answers `502`).
- Backup and restore (database, private files, encryption key: an API key
  created before the backup still works; data created after it is gone).
- HTTPS with `SITE_ADDRESS=localhost` (Caddy internal CA, HTTP/2, websocket,
  no `http://` links).
- Overrides: Traefik v3.6 routing with no host ports (HTTPS, websocket, real
  client IP in ERPNext's activity log), local directories (including backups;
  database in a volume on macOS, see the override).
- Not tested: issuing a real Let's Encrypt certificate (needs a public
  domain).

Resource usage
--------------

Idle, after a few requests: the whole stack ~780 MiB (Gunicorn ~280 MiB,
MariaDB ~250 MiB, workers and scheduler ~50 MiB each, Socket.IO ~35 MiB,
Redis ~25 MiB, Caddy and nginx ~20 MiB).

License
-------

[MIT](LICENSE).
