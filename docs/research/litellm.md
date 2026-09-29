# What LiteLLM needs from Postgres, and which door it can use

Research for [#68](https://github.com/Abdullah0297445/userland/issues/68), a child of the map
[#66](https://github.com/Abdullah0297445/userland/issues/66). It was checked on 2026-09-29 against
the LiteLLM proxy `v1.103.0`, the newest stable release that day. It comes from LiteLLM's source
at that tag, LiteLLM's docs, and the Prisma, PgBouncer and Postgres docs. Nothing was run.

## The short answers

- **Postgres: a user from `bin/add-database --postgres` is enough.** The migrations make tables
  and indexes only. They need no superuser, no extension and no second database.
- **Door: the session door, for the one URL.** `DATABASE_URL` carries both the queries and the
  migrations. Migrations break on the transaction door. Set no `pgbouncer=true` and no
  `DIRECT_URL`.
- **Models in the database: `STORE_MODEL_IN_DB=True`.** Add `DATABASE_URL`, `LITELLM_MASTER_KEY`
  and `LITELLM_SALT_KEY`. No config file is needed.
- **Only `LITELLM_SALT_KEY` loses data if lost.** It encrypts the provider keys kept in the
  database. The master key is the admin password and can be replaced.
- **Container:** `ghcr.io/berriai/litellm:v1.103.0`, port `4000`, a health check with `python3`
  on `/health/liveliness`, and no volume.
- **Redis: not needed for one container.**

## Words used here

- **Prisma**: the database toolkit LiteLLM uses. *Prisma Client* runs the queries. *Prisma
  Migrate* applies the migrations.
- **Migration**: a change to the tables, applied when the proxy starts.
- **`prisma migrate deploy`**: the command that applies the migrations not yet applied.
- **Prepared statement**: a query sent once and run again later by name. A *named* one lives on
  the connection.
- **Advisory lock**: a lock a program takes in Postgres by number. A *session-level* one lasts as
  long as the connection.
- **Shadow database**: a scratch database Prisma makes to test migrations. Only development
  commands use it.
- **`pgbouncer=true`**: a flag on Prisma's URL. It stops Prisma using named prepared statements,
  for a transaction pooler.
- **Provider key**: the API key for an upstream model provider.
- **Virtual key**: an API key LiteLLM makes for its own callers.

## Postgres

- Migrations run on every start. The image runs `litellm --port 4000`
  ([Dockerfile](https://github.com/BerriAI/litellm/blob/v1.103.0/Dockerfile#L168-L169),
  [prod_entrypoint.sh](https://github.com/BerriAI/litellm/blob/v1.103.0/docker/prod_entrypoint.sh)).
  The CLI then calls `PrismaManager.setup_database(use_migrate=not use_prisma_db_push)`
  ([proxy_cli.py](https://github.com/BerriAI/litellm/blob/v1.103.0/litellm/proxy/proxy_cli.py#L1359-L1361)),
  which runs `prisma migrate deploy` by default. `DISABLE_SCHEMA_UPDATE=true` turns this off
  ([docs: production](https://docs.litellm.ai/docs/proxy/prod)).
- The migrations make tables and indexes. A search of LiteLLM's migration files found no
  `CREATE EXTENSION`, no `GRANT`, no `OWNER TO` and no role statement
  ([migrations folder](https://github.com/BerriAI/litellm/tree/v1.103.0/litellm-proxy-extras/litellm_proxy_extras/migrations);
  searched with GitHub code search on the default branch).
- `prisma migrate deploy` uses no shadow database, so it needs no `CREATEDB` right
  ([Prisma: shadow database](https://www.prisma.io/docs/orm/prisma-migrate/understanding-prisma-migrate/shadow-database)).
- `bin/add-database --postgres` makes a user that owns its database
  ([bin/add-database](../../bin/add-database) lines 128-129). Since Postgres 15 the `public` schema
  belongs to the database's owner, so the owner can make tables there
  ([Postgres 15 release notes](https://www.postgresql.org/docs/release/15.0/)). The script's
  `REVOKE CREATE ON SCHEMA public FROM PUBLIC` (line 138) does not touch the owner.

## Door

- The schema names one URL, `url = env("DATABASE_URL")`, and no `directUrl`
  ([schema.prisma](https://github.com/BerriAI/litellm/blob/v1.103.0/schema.prisma#L1-L4)). So
  queries and migrations both use `DATABASE_URL`. LiteLLM's source says so: "the schema
  DATABASE_URL names, the only URL Prisma migrates through"
  ([utils.py](https://github.com/BerriAI/litellm/blob/v1.103.0/litellm-proxy-extras/litellm_proxy_extras/utils.py#L784-L793)).
- Prisma's migration engine "is designed to use a single connection to the database, and does not
  support connection pooling with PgBouncer"
  ([Prisma: PgBouncer](https://www.prisma.io/docs/orm/prisma-client/setup-and-configuration/databases-connections/pgbouncer)).
  `migrate deploy` holds an advisory lock while it runs. LiteLLM retries when it times out
  "waiting for the advisory lock a concurrent migrate deploy holds"
  ([utils.py](https://github.com/BerriAI/litellm/blob/v1.103.0/litellm-proxy-extras/litellm_proxy_extras/utils.py#L1018-L1021)).
  The transaction door gives no connection for a whole session, so it cannot hold that lock.
- LiteLLM's own built-in pooler agrees. It pools the workers in transaction mode, but "Migrations
  and the schema diff run in the supervisor before the pooler is started, so they always go
  straight to Postgres"
  ([pgbouncer.py](https://github.com/BerriAI/litellm/blob/v1.103.0/litellm/proxy/db/pgbouncer.py#L8-L19)).
- A `DIRECT_URL` does not help, unlike langfuse. LiteLLM reads it only for the schema diff and an
  index repair, never for `migrate deploy`
  ([utils.py](https://github.com/BerriAI/litellm/blob/v1.103.0/litellm-proxy-extras/litellm_proxy_extras/utils.py#L449-L451)).
  Prisma ignores it, since the schema names no `directUrl`.
- The session door gives the client one Postgres connection for its whole session
  ([PgBouncer: features](https://www.pgbouncer.org/features.html)). Locks and prepared statements
  work as on a direct connection, so no `pgbouncer=true` is needed. That flag is for transaction
  mode (Prisma: PgBouncer, above). LiteLLM sets it only when `DATABASE_DISABLE_PREPARED_STATEMENTS`
  is on
  ([db_url_settings.py](https://github.com/BerriAI/litellm/blob/v1.103.0/litellm/proxy/db/db_url_settings.py#L595-L602)).
- The load is small. LiteLLM holds up to 10 connections per worker by default
  (`database_connection_pool_limit`, [docs: production](https://docs.litellm.ai/docs/proxy/prod)),
  and runs one worker by default
  ([proxy_cli.py](https://github.com/BerriAI/litellm/blob/v1.103.0/litellm/proxy/proxy_cli.py#L675-L684)).
  The session door's pool is 100 ([compose/postgres.yml](../../compose/postgres.yml) line 63).
- The transaction door could work only with a split: a one-off migration run on the session door,
  then the proxy on the transaction door with `DISABLE_SCHEMA_UPDATE=true` and `pgbouncer=true`.
  That is a second container and a second URL, for little gain on one host.

## Models in the database

- `STORE_MODEL_IN_DB=True` lets the admin add models in the web UI. LiteLLM's own compose sets it,
  "allows adding models to proxy via UI"
  ([docker-compose.yml](https://github.com/BerriAI/litellm/blob/v1.103.0/docker-compose.yml#L24)).
  The proxy reads it from the environment
  ([proxy_server.py](https://github.com/BerriAI/litellm/blob/v1.103.0/litellm/proxy/proxy_server.py#L10151)).
- It also needs `DATABASE_URL`, `LITELLM_MASTER_KEY` and `LITELLM_SALT_KEY`
  ([docs: deploy](https://docs.litellm.ai/docs/proxy/deploy)).
- No config file is needed. LiteLLM's compose starts the proxy without `--config` (those lines are
  commented out,
  [docker-compose.yml](https://github.com/BerriAI/litellm/blob/v1.103.0/docker-compose.yml#L8-L14)),
  and the image's command is only `--port 4000`
  ([Dockerfile](https://github.com/BerriAI/litellm/blob/v1.103.0/Dockerfile#L169)).
- Models go in `LiteLLM_ProxyModelTable` and shared provider keys in `LiteLLM_CredentialsTable`
  ([schema.prisma](https://github.com/BerriAI/litellm/blob/v1.103.0/schema.prisma#L42-L57)).

## Secrets

- **`LITELLM_MASTER_KEY`** is the admin credential. It "authenticates admin API calls and is the
  Admin UI login password". It must start with `sk-`
  ([docs: production](https://docs.litellm.ai/docs/proxy/prod),
  [docs: UI](https://docs.litellm.ai/docs/proxy/ui)).
- **`LITELLM_SALT_KEY`** encrypts the provider keys kept in the database. "Do not change it after
  adding a model; it encrypts your LLM API key credentials, and changing it makes them
  unreadable" ([docs: production](https://docs.litellm.ai/docs/proxy/prod)).
- **Only the salt key loses data if lost.** Every stored provider key must then be typed in again.
  The master key can be replaced: set a new one and restart. While the salt key is set, nothing is
  encrypted with the master key. If the salt key is not set, LiteLLM encrypts with the master key
  instead
  ([encrypt_decrypt_utils.py](https://github.com/BerriAI/litellm/blob/v1.103.0/litellm/proxy/common_utils/encrypt_decrypt_utils.py#L26-L34)).
  So the salt key must be set before the first start.
- **Login:** open `/ui`. The username is `UI_USERNAME`, `admin` by default. The password is
  `UI_PASSWORD`, or the master key when `UI_PASSWORD` is not set
  ([docs: UI](https://docs.litellm.ai/docs/proxy/ui),
  [login_utils.py](https://github.com/BerriAI/litellm/blob/v1.103.0/litellm/proxy/auth/login_utils.py#L80-L83)).
  The docs say "Environment credentials are for bootstrapping only". They suggest making a
  personal admin user, then turning this login off with `disable_env_credential_login: true`.
  The docs set that in `config.yaml`, which this setup does not have, so the login stays on.

## Container

- **Image:** `ghcr.io/berriai/litellm`. The docs say to use it "for monolithic deployments,
  including those with Postgres, since it bundles the Prisma toolchain"
  ([docs: deploy](https://docs.litellm.ai/docs/proxy/deploy)). `docker.litellm.ai/berriai/litellm`
  is a mirror of it.
- **Version:** `v1.103.0`, published 2026-09-28 and not marked pre-release
  ([release](https://github.com/BerriAI/litellm/releases/tag/v1.103.0)). LiteLLM names stable
  releases plain `1.x.x`. Tags with `-rc.N` or `-dev.N` are not stable. The docs say to pin "the
  latest stable `1.x.x` release"
  ([docs: release cycle](https://docs.litellm.ai/docs/proxy/release_cycle)). The tag is on ghcr.io
  as both `v1.103.0` and `1.103.0`.
- **Port:** `4000`
  ([Dockerfile](https://github.com/BerriAI/litellm/blob/v1.103.0/Dockerfile#L166),
  [proxy_cli.py](https://github.com/BerriAI/litellm/blob/v1.103.0/litellm/proxy/proxy_cli.py#L674)).
- **Health check:** the image has no `curl` or `wget`, but it has Python
  ([Dockerfile](https://github.com/BerriAI/litellm/blob/v1.103.0/Dockerfile#L129-L133)).
  LiteLLM's own compose checks with
  `python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:4000/health/liveliness')"`,
  with a 40 second start period
  ([docker-compose.yml](https://github.com/BerriAI/litellm/blob/v1.103.0/docker-compose.yml#L29-L36)).
  `urlopen` fails on an error status, so the check fails too. "liveliness" is LiteLLM's spelling.
  `/health/readiness` also exists. It confirms the proxy "is up and can reach its database"
  ([docs: deploy](https://docs.litellm.ai/docs/proxy/deploy)).
- **Volume:** none. LiteLLM's compose mounts none for the proxy
  ([docker-compose.yml](https://github.com/BerriAI/litellm/blob/v1.103.0/docker-compose.yml#L2-L36)).
  Its lasting state is in Postgres. The Prisma engines are built into the image, so a first start
  needs no download
  ([Dockerfile](https://github.com/BerriAI/litellm/blob/v1.103.0/Dockerfile#L152-L157)).

## Redis

- One container runs without Redis. The docs say Redis is "Required once you run more than one
  instance". With one, "rate limits, budgets, and router cooldowns are counted per gateway process
  rather than across the cluster" ([docs: deploy](https://docs.litellm.ai/docs/proxy/deploy)).
  LiteLLM's own compose runs no Redis
  ([docker-compose.yml](https://github.com/BerriAI/litellm/blob/v1.103.0/docker-compose.yml)).
- Counts are per worker process. The default is one worker, so one container counts right.

## Not checked

- Nothing was run. The build's first start will prove that the migrations pass as the
  `bin/add-database` user over the session door.
