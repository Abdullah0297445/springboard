# Windmill: what it needs from Postgres, and which door it uses

Researched on 2026-09-29, against Windmill v1.819.0. That is the latest release. It came
out the same day. Code links point at that tag.

## Short answer

- **Door.** The session door. At every start, Windmill takes a session-level advisory lock
  and holds it across many statements. The transaction door breaks that.
- **Superuser.** Not needed. A user made by `bin/add-database --postgres --session windmill`
  can run it. The superuser must first do one step by hand, before Windmill's first `up`.
- **First admin.** `admin@windmill.dev` with the password `changeme`. No environment
  variable changes it. Change it in the browser straight after `up`.
- **Secrets.** Only `WINDMILL_DB_PASSWORD` goes in `.env`. Losing it loses no data.

## Postgres

Some words used here:

- A **role** is a Postgres user or group.
- **RLS** (row-level security) means Postgres hides the rows a role may not see.
- A role with **BYPASSRLS** sees all rows.

### The roles

- `windmill_user` is a group role with no login. RLS applies to it.
  ([init-db-as-superuser.sql](https://github.com/windmill-labs/windmill/blob/v1.819.0/init-db-as-superuser.sql))
- `windmill_admin` is a group role with BYPASSRLS. It is a member of `windmill_user`.
  (same file)
- On each request, Windmill runs `SET LOCAL ROLE windmill_admin` for an admin, and
  `SET LOCAL ROLE windmill_user` for anyone else. So the login user must be a member of both.
  ([set_session_context](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/migrations/20250412144540_improve_perf_api_role.up.sql#L2-L15))

Windmill's first migrations try to make these roles. If the login user cannot, the migration
catches the error and goes on.
([migrate_root](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/migrations/20220123221901_migrate_root.up.sql))
The user from `bin/add-database` is not a superuser, and it cannot make roles. So the roles
must exist before Windmill starts for the first time. Windmill's docs describe this setup in
"Run Windmill without using a Postgres superuser": make the database with a normal user as its
owner, run `init-db-as-superuser.sql` as a superuser, then grant both roles to that user.
([self-host docs](https://www.windmill.dev/docs/advanced/self_host))

### The step done by hand

Do this once, as `postgres`, in the database `windmill`. Do it after `bin/add-database` and
before Windmill's first `up`. The first eight statements are the ones in Windmill's
`init-db-as-superuser.sql`. The last two are the grants the docs name.

```sh
docker exec -i postgres-18 psql -v ON_ERROR_STOP=1 -U postgres -d windmill <<'SQL'
CREATE ROLE windmill_user;
CREATE ROLE windmill_admin WITH BYPASSRLS;
GRANT windmill_user TO windmill_admin;
GRANT USAGE ON SCHEMA public TO windmill_user, windmill_admin;
GRANT ALL ON ALL TABLES IN SCHEMA public TO windmill_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO windmill_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO windmill_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO windmill_user;
GRANT windmill_admin TO windmill;
GRANT windmill_user TO windmill;
SQL
```

Roles belong to the whole Postgres server, not to one database. So these two roles outlive
the `windmill` database. A dump of the `windmill` database alone does not hold them. Windmill's
own compose file warns about this.
([docker-compose.yml](https://github.com/windmill-labs/windmill/blob/v1.819.0/docker-compose.yml#L11-L17))

### What does not work without more rights

Some optional features make databases or roles of their own. Examples are DuckLake and
datatables kept on the instance's own Postgres, and Postgres triggers on them. Their
migrations try, catch the error and skip.
([ducklake](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/migrations/20250731132157_ducklake_instance_settings.up.sql),
[custom instance user](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/migrations/20251208123907_safety_custom_instance_db_user_pwd.up.sql),
[replication user](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/migrations/20260716152346_custom_instance_replication_user.up.sql))
So those features stay off. Scripts, flows, apps, schedules and the job queue need none of it.

Windmill's own compose file runs Postgres 18, which userland also runs.
([docker-compose.yml](https://github.com/windmill-labs/windmill/blob/v1.819.0/docker-compose.yml#L18-L22))

## Door

Some words used here:

- PgBouncer's **transaction mode** lends a Postgres connection for one transaction only.
- **Session mode** lends it for as long as the client stays connected.
- A **session-level advisory lock** is a lock Postgres ties to one connection.

What Windmill does:

- **Advisory locks: yes, and they break.** Every server and every worker takes
  `pg_try_advisory_lock` at start, before migrations. It holds the lock across many
  statements, then calls `pg_advisory_unlock`.
  ([db.rs](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/windmill-api/src/db.rs#L151-L213))
  In transaction mode, the lock and the unlock can land on different Postgres connections. The
  lock then stays held, and the next start waits on it, logging "a migration is in progress,
  rechecking in 5s". PgBouncer marks session-level advisory locks as "Never" in transaction
  mode. ([PgBouncer features](https://www.pgbouncer.org/features.html))
- **Session settings: yes, and they break.** On each new connection, Windmill runs
  `SET statement_timeout` and other `SET` commands.
  ([db_connect.rs](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/src/db_connect.rs#L155-L190))
  PgBouncer marks `SET` as "Never" in transaction mode. The setting would stick to a random
  Postgres connection. ([PgBouncer features](https://www.pgbouncer.org/features.html))
- **LISTEN/NOTIFY: no longer used.** Windmill replaced it with a table, `notify_event`, that
  it polls.
  ([migration](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/migrations/20260203172950_polling_based_events.up.sql#L1-L2))
- **Prepared statements: fine on their own.** Windmill's Postgres client, sqlx, keeps up to
  400 named prepared statements per connection.
  ([db_connect.rs](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/src/db_connect.rs#L198))
  PgBouncer handles those in transaction mode when `max_prepared_statements` is above 0. It
  is 200 by default. ([PgBouncer config](https://www.pgbouncer.org/config.html#max_prepared_statements))

So Windmill needs the session door: `bin/add-database --postgres --session windmill`.

The session door holds one Postgres connection for each connection Windmill opens. Windmill's
pools are 50 connections for the server and 5 for a worker.
([lib.rs](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/windmill-common/src/lib.rs#L152-L154),
[db_connect.rs](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/src/db_connect.rs#L57-L67))
One server and one worker make 55. That fits under the session door's pool of 100 for each
user and database (`DEFAULT_POOL_SIZE` in `compose/postgres.yml`). `DATABASE_CONNECTIONS` lowers
a pool if needed.

## First admin

- The first login is `admin@windmill.dev` with the password `changeme`. The first migration
  makes it.
  ([first.up.sql](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/migrations/20220123221903_first.up.sql#L257-L258),
  [self-host docs](https://www.windmill.dev/docs/advanced/self_host))
- No environment variable sets it. The server's list of variables has none for it.
  ([main.rs](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/src/main.rs#L677-L697))
  `SUPERADMIN_SECRET` is different: it is a token for the API that acts as a superadmin. It
  makes no login.
  ([auth.rs](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/windmill-api-auth/src/auth.rs#L719-L735))
- While that user still has the default password and no base URL is saved, the login page
  fills in `admin@windmill.dev` and `changeme` by itself. It then sends you to setup.
  ([Login.svelte](https://github.com/windmill-labs/windmill/blob/v1.819.0/frontend/src/lib/components/Login.svelte#L445-L449),
  [users.rs](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/windmill-api-users/src/users.rs#L343-L377))

So change the email and password in the browser straight after `up`, before anyone else
reaches the page. This matters most on public visibility.

## Containers

Pin Windmill **1.819.0** on all three containers, and keep them on one version. Windmill ships a
release almost every day. ([releases](https://github.com/windmill-labs/windmill/releases))

- The server and the worker use one image, `ghcr.io/windmill-labs/windmill:1.819.0`. `MODE`
  picks the job.
- The LSP is in `ghcr.io/windmill-labs/windmill-extra:1.819.0`. The LSP is the language server
  that gives the code editor its hints. Windmill's own compose file uses this image for it.
  The image also holds a multiplayer service and a debugger, and an environment variable
  switches each one on or off.
  ([docker-compose.yml](https://github.com/windmill-labs/windmill/blob/v1.819.0/docker-compose.yml#L179-L202))
  The older `ghcr.io/windmill-labs/windmill-lsp` has only the tags `latest` and `main`, with
  no version tags (checked on ghcr.io on 2026-09-29), though the docs still name it.

| | Server | Worker | LSP |
| --- | --- | --- | --- |
| Image | `windmill:1.819.0` | `windmill:1.819.0` | `windmill-extra:1.819.0` |
| Environment | `MODE=server` | `MODE=worker`, `WORKER_GROUP=default` | `ENABLE_LSP=true`, `ENABLE_MULTIPLAYER=false`, `ENABLE_DEBUGGER=false`, `ENABLE_GATEWAY=false` |
| Port | 8000 (web UI and API). Also 2525, for email triggers, which is not needed. | None by default: it binds a random port on 127.0.0.1. `PORT=8000` fixes it. | 3001 (WebSocket, under `/ws/`) |
| Health check | `curl -fsS http://127.0.0.1:8000/api/health/status` | Same, once `PORT=8000` is set | `curl -fsS http://127.0.0.1:3001/health` |
| Volume | logs, at `/tmp/windmill/logs` | cache, at `/tmp/windmill/cache`, and the same logs volume | LSP cache, at `/pyls/.cache` |

Sources for the table:

- Ports: server 8000 by default, and a worker binds a random port on 127.0.0.1 unless `PORT`
  is set.
  ([main.rs](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/src/main.rs#L162-L164),
  [main.rs](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/src/main.rs#L1210-L1220))
  The worker serves the same API routes as the server.
  ([main.rs](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/src/main.rs#L1404-L1418))
  The LSP listens on 3001.
  ([entrypoint-extra.sh](https://github.com/windmill-labs/windmill/blob/v1.819.0/docker/entrypoint-extra.sh#L146-L150))
- Health: `/api/health/status` needs no login. It answers 503 only when Windmill is unhealthy,
  for example when it cannot reach the database. It answers 200 when healthy or degraded.
  ([health.rs](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/windmill-api/src/health.rs#L509-L553),
  [self-host docs](https://www.windmill.dev/docs/advanced/self_host))
  The LSP answers on `/health`.
  ([pyls_launcher.py](https://github.com/windmill-labs/windmill/blob/v1.819.0/lsp/pyls_launcher.py#L205-L218))
  `curl` is in the Windmill image.
  ([Dockerfile](https://github.com/windmill-labs/windmill/blob/v1.819.0/Dockerfile#L173))
  The extra image runs `curl` on its base while it builds, so `curl` is there too.
  ([DockerfileExtra](https://github.com/windmill-labs/windmill/blob/v1.819.0/docker/DockerfileExtra#L30))
- Routing: the browser reaches the LSP on the same host, under `/ws/`. Everything else goes to
  the server.
  ([Caddyfile](https://github.com/windmill-labs/windmill/blob/v1.819.0/Caddyfile#L22-L30))
  With the gateway off, traefik sends `PathPrefix(/ws/)` straight to port 3001. The LSP serves
  `/ws/pyright` and its other paths itself, so nothing is stripped.
  ([gateway.mjs](https://github.com/windmill-labs/windmill/blob/v1.819.0/multiplayer/gateway.mjs#L33))
- Base URL: set `BASE_URL`. Windmill uses it while the base URL in its instance settings is
  empty.
  ([monitor.rs](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/src/monitor.rs#L5748-L5770))
- Worker isolation: Windmill's compose file runs the worker with `privileged: true` and
  `FAVOR_UNSHARE_PID=true`, to keep jobs apart from each other. Without `privileged`, the
  worker logs an error and runs jobs without that isolation. It does not stop.
  ([worker.rs](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/windmill-worker/src/worker.rs#L470-L500))

What each volume keeps:

- **Logs.** A worker writes the older part of a long job log to files here. The server reads
  them from the same path to show them, so server and worker share one volume.
  ([jobs.rs](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/windmill-api/src/jobs.rs#L2849-L2889))
  Losing it loses only those older parts of long logs.
- **Cache.** Packages that jobs download. It is safe to lose, and the next job downloads them
  again. ([Dockerfile](https://github.com/windmill-labs/windmill/blob/v1.819.0/Dockerfile#L273-L282))
- **LSP cache.** Editor hint data. It is safe to lose.
  ([DockerfileExtra](https://github.com/windmill-labs/windmill/blob/v1.819.0/docker/DockerfileExtra#L68))
- Everything that matters is in Postgres: scripts, flows, apps, resources, secret variables
  and the job queue. ([self-host docs](https://www.windmill.dev/docs/advanced/self_host))

## Secrets

- `WINDMILL_DB_PASSWORD` is the only one needed. `bin/add-database` prints it. If it is lost,
  no data is lost: `bin/new-password --postgres --session windmill` makes a new one.
- Windmill encrypts secret variables with one key per workspace. It keeps those keys in
  Postgres, in the table `workspace_key`.
  ([migration](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/migrations/20220428085013_private_key.up.sql#L5-L10),
  [variables.rs](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/windmill-common/src/variables.rs#L268-L272))
  So a Postgres backup is enough to read them again.
- Do not set `SECRET_SALT`. If set, it is mixed into every workspace key. Losing it would make
  every secret variable unreadable.
  ([variables.rs](https://github.com/windmill-labs/windmill/blob/v1.819.0/backend/windmill-common/src/variables.rs#L233-L237))
- `SUPERADMIN_SECRET` is not needed. If set, it is a full-power API token. Losing it loses no
  data.
- The first admin's password lives in Postgres, not in `.env`.
