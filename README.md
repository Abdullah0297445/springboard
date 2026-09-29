# userland

One host, one compose project, and products you switch on and off. Clone it, write one
`.env`, and run `docker compose up`. On a host you keep, that `.env` lives in Infisical, and
`bin/up` writes it and brings the host up. The host then runs a reverse proxy, a set of shared
datastores, and whichever applications you switched on, each behind TLS.

There is no application code here. userland is the ground your own projects stand on,
and it is deliberately not one of them.

> **This repo is being built in the open.** userland now runs on docker compose alone. Every
> product has its compose file, every database is made by a helper, and every database is
> archived and taken off the host. Infisical keeps userland's `.env`: `bin/up` writes the file
> from it and brings the host up, and `bin/up --rebuild` brings a new host back from the bucket.
> The design is published as issues on this repo as it is settled.

`userland` is the part of a running system that is not the kernel: everything the machine
runs *for you*. This repo is that layer, for one host.

## What you can switch on

| Product | File | Containers |
|---|---|---|
| **traefik** | `compose.yml` | traefik. Always on. It terminates TLS for everything else. |
| **postgres** | `compose/postgres.yml` | `postgres-18`, its two doors, `pgbouncer-transaction` and `pgbouncer-session`, and `postgres-dumper`, which archives every database on it. |
| **pgadmin** | `compose/pgadmin.yml` | pgadmin, the browser UI for Postgres. |
| **clickhouse** | `compose/clickhouse.yml` | clickhouse, and `clickhouse-dumper`, which archives every database on it. |
| **metabase** | `compose/metabase.yml` | metabase. |
| **n8n** | `compose/n8n.yml` | n8n and n8n-runners. |
| **langfuse** | `compose/langfuse.yml` | langfuse-web, langfuse-worker and langfuse-redis. |
| **twenty** | `compose/twenty.yml` | twenty-server, twenty-worker and twenty-redis. |
| **archivist** | `compose/archivist.yml` | archivist. It takes every archive the dumpers write off the host, into a bucket of its own, as [restic](https://restic.net) snapshots under a master key that never touches the host. |
| **infisical** | `compose/infisical.yml` | infisical and infisical-redis. It keeps the real copy of userland's `.env`, which `bin/up` writes from it. |

neo4j is planned.

There is one Postgres and one ClickHouse for the whole host, never one per application. Each
application gets its own database on them, owned by a user of the same name. Redis is the
exception: a product that needs it runs its own, inside the product, and nothing else is
pointed at it.

Two things are pointed at rather than run. One is an S3-compatible object store you bring:
the archivist, Langfuse and Twenty each need a bucket of it. The other is a secret store you
own, which holds two master keys: the archivist's and Infisical's. userland makes neither: you
make them, and *Object store* and *Secret store* say how. Each bucket is reached by an access
key of its own. The archivist's may delete under `locks/` and nowhere else, so a compromised
host cannot erase its own archives. Langfuse's may delete, because its Data Retention feature
does, and so may Twenty's, because it moves a file by copying it and deleting the original.
Nothing may ever expire in the archivist's, and *Object store* says why.

## The shape

- **One compose project, one file per product.** `compose.yml` at the root is traefik.
  Every other product is `compose/<product>.yml`. `COMPOSE_FILE` in `.env` lists the ones you
  switch on, and compose reads nothing else.
- **One `.env`.** It names the products and holds every variable they read. Compose refuses
  to start while a required one is missing. On a host you keep, its real copy is in Infisical.
- **You switch on products, not containers.** A product's containers are always on together:
  langfuse is its web, its worker and its Redis. pgadmin is a product of its own, so Postgres
  without pgadmin is a valid choice.
- **Upstream, not a copy you edit.** You never edit a tracked file, so `git pull` keeps
  working, and it is how the next product reaches you.

[ADR 0001](docs/adr/0001-compose-alone.md) says why userland runs on compose alone.

## Two visibilities

**local**: plain HTTP on `*.localhost`. No DNS record, no certificate, no domain to buy.
This is how you find out whether you want it. Only this machine resolves those names, but
traefik listens on every interface, so anyone on a network you share who sends the name
reaches what is on.

**public**: real hostnames, with TLS issued over a DNS-01 challenge.

Both go through traefik. Public is local plus two changes:

1. `compose/public.yml` at the end of `COMPOSE_FILE`. It changes traefik alone: it opens 443,
   gets certificates, and redirects plain HTTP to 443.
2. Three variables in `.env`, which every product reads:

| Variable | local | public | Meaning |
|---|---|---|---|
| `DOMAIN` | `localhost` | your domain | Every hostname is a name under it, such as `n8n.${DOMAIN}`. |
| `SCHEME` | `http` | `https` | The scheme in every link a product writes. |
| `SECURE_COOKIES` | `false` | `true` | Whether n8n, pgadmin and Infisical mark their cookies secure. A secure cookie over plain HTTP is a login that never completes. |

All three are required. A public host that forgot one would serve `http` links, so compose
refuses instead.

## Running it

```sh
git clone https://github.com/Abdullah0297445/userland
cd userland
```

There are two ways to run it. **To try it out**, you write `.env` by hand and run compose.
**On a host you keep**, `.env` lives in Infisical, and `bin/up` writes it and brings the host up.

### Trying it out

Write `.env` at the root. It names the products and holds what they read. Start with
Postgres:

```sh
COMPOSE_FILE=compose.yml:compose/postgres.yml
DOMAIN=localhost
SCHEME=http
SECURE_COOKIES=false
POSTGRES_PASSWORD=...
PGBOUNCER_AUTH_PASSWORD=...
```

Then bring it up:

```sh
docker compose up -d --remove-orphans
```

A product with a database needs it made first, under *Provisioning*. For metabase:

```sh
bin/add-database --postgres metabase
```

It prints `METABASE_DB_PASSWORD=...`. Paste that line into `.env`, add metabase to
`COMPOSE_FILE` with the rest of what it reads, and run the same `up` again:

```sh
COMPOSE_FILE=compose.yml:compose/postgres.yml:compose/metabase.yml
METABASE_DB_PASSWORD=...
MB_ENCRYPTION_SECRET_KEY=...
```

- **`compose.yml` always comes first.** Compose reads every relative path, such as
  `./config/pgadmin-servers.json`, from the first file's folder. With no `COMPOSE_FILE`
  at all, `docker compose up` runs traefik alone.
- **A product listed without one it needs is refused**, for example
  `service "metabase" depends on undefined service "pgbouncer-transaction"`. So is a missing
  required variable: `required variable POSTGRES_PASSWORD is missing a value`.
- **`docker compose config --variables`** lists every variable the listed products read,
  whether it is required, and its default. Each product's section below says what each one
  means.
- **To switch a product off**, take it out of `COMPOSE_FILE` and run the same command.
  `--remove-orphans` removes its containers. Its volumes stay, and so does its database. To
  drop a volume too, `docker volume rm` it by hand. To drop its database,
  `bin/remove-database` it, under *Provisioning*.
- **`docker compose down`** stops everything and keeps every volume. The next `up` brings it
  back.

This way runs no archivist and no Infisical, so nothing ever leaves the host. It is for local
visibility, to find out whether you want userland. `postgres-dumper` shows as unhealthy here:
it waits for its intent, under *The archivist*, and with no archivist there is nowhere for its
archives to go. Leave it waiting.

### A host you keep

On a host you keep, the real copy of `.env` is in Infisical, in the project `userland`, in its
environment `prod`. You never edit the file. You change a line in Infisical's web UI, and run:

```sh
bin/up
```

It does this, in order. A step that fails stops it, changes nothing, and says what to do next.

1. It starts Postgres from the `.env` on the host. A Postgres that holds no database is a new
   host, so it refuses and names `bin/up --rebuild`.
2. It starts Infisical, if Infisical is not running.
3. It logs in to Infisical once, as the helper's login, `INFISICAL_CLIENT_ID` and
   `INFISICAL_CLIENT_SECRET`. It never tries twice: three wrong secrets within 30 seconds lock
   a login for 5 minutes.
4. It writes the new `.env` into a temporary file, with Infisical's CLI and our template,
   [`config/env.tmpl`](config/env.tmpl). Each line is `KEY="value"`, with `\`, `"`, `$` and a
   newline escaped, so any value reaches its container unchanged. A project with no line in
   `prod` is refused.
5. Compose reads the new file first. It is refused if compose refuses it, or if its
   `COMPOSE_FILE` leaves out `compose/postgres.yml`, `compose/archivist.yml` or
   `compose/infisical.yml`. Without Infisical, `bin/up` could not run again. Without the
   archivist, a lost host loses every line.
6. It swaps the new file in, readable only by you.
7. It runs `docker compose up -d --remove-orphans`.
8. It names each dumper that is not healthy, and why. On a new host, that is each one that
   waits for its intent.

A second run changes nothing: the file is the same, and compose recreates no container.

- **Where this README says to put a line in `.env` and run `docker compose up`**, on a host you
  keep you put the line in Infisical and run `bin/up`. That holds for `COMPOSE_FILE` too.
- **`bin/up` makes nothing a product needs.** It makes no database and no secret, and runs no
  step that is one product's. Those are yours, with the helpers under *Provisioning* and each
  product's section.
- **It writes the file compose reads**: `.env` at the root, or the one `COMPOSE_ENV_FILES`
  names. The tests name one of their own, so they never touch yours.
- *Infisical* says how the first host is set up. *Bringing a host back* says how a new host
  comes back, with `bin/up --rebuild`.

**Values in `.env`.** In a `.env` you write by hand, each value fits on one line, without `$`,
`#`, quotes or a backtick, and without a space at either end. Compose reads it unquoted, and
Infisical's upload reads it the same way, cutting a value at a `#`. A value set in Infisical's
web UI may hold anything, because `bin/up` escapes it. A password that travels inside a URL may
hold only letters, digits, `-`, `.`, `_` and `~`. That is every Postgres and ClickHouse
password, and twenty's and Infisical's Redis passwords. `bin/random-secret` makes a secret that
fits everywhere: 64 random hex characters, or as many as you ask for. That covers langfuse's
64-character key and Infisical's master key of exactly 32:

```sh
bin/random-secret
bin/random-secret 32
```

**Memory limits.** Every container reads `<CONTAINER>_MEM_LIMIT`: its name in capitals, with
`-` made `_`, such as `LANGFUSE_WEB_MEM_LIMIT=2g`. Unset or `0` means no limit. Each product's
table lists its own.

## Provisioning

**A database is made by hand, once**, before the product or consumer that uses it first
starts. A product's database is made the same way as a consumer's. Nothing makes one on its
own, and nothing changes one afterwards: a new password is given by hand too. On a new host,
the databases come back from the archive, under *Bringing a host back*, so none is made there.

Three helpers in `bin/` do it. They run on the host, from the root of the repo. They need only
docker, and `postgres-18` or `clickhouse` up.

```sh
bin/add-database --postgres myapp
bin/add-database --postgres --session myapp
bin/add-database --postgres --api myapp
bin/add-database --clickhouse myapp
bin/new-password --postgres myapp
bin/remove-database --postgres myapp
```

Each names its datastore, `--postgres` or `--clickhouse`: one of them, always, as `bin/restore`
and `bin/rebuild` do. Without one, or with both, it is refused and changes nothing.

**No helper writes into Infisical.** These three never reach it at all. Each prints every line
it makes once, and you put it where it goes. A helper cannot tell a product's database from a
consumer's, so it prints both lines, and you take the one you need:

- **A consumer's DSN** goes to the consumer's admin, for the consumer's own `.env`.
- **A product's line**, such as `METABASE_DB_PASSWORD`, goes in Infisical, in the project
  `userland`, environment `prod`. On a host without Infisical, it goes in `.env` instead. That
  is *Trying it out*, and the first host before Infisical runs.

**Before a product with a database first starts**, make its database, and put its line where
it goes. Compose refuses a product whose variable is missing, so the product goes into
`COMPOSE_FILE` after its database is made.

| Product | Run | Line |
|---|---|---|
| metabase | `bin/add-database --postgres metabase` | `METABASE_DB_PASSWORD` |
| n8n | `bin/add-database --postgres n8n`, then the one line under *n8n* | `N8N_DB_PASSWORD` |
| langfuse | `bin/add-database --postgres langfuse` and `bin/add-database --clickhouse langfuse` | `LANGFUSE_DB_PASSWORD` and `LANGFUSE_CLICKHOUSE_PASSWORD` |
| twenty | `bin/add-database --postgres twenty` | `TWENTY_DB_PASSWORD` |
| infisical | `bin/add-database --postgres infisical` | `INFISICAL_DB_PASSWORD` |

### Making a database

**`bin/add-database --postgres NAME`** makes the database `NAME` on Postgres, and a user of the
same name that owns it. It prints two lines, once: a DSN for a consumer, and `NAME_DB_PASSWORD`
for a product, in capitals.

- `CONNECT` on the database is revoked from everyone else, and so is `CREATE` on `public`.
- The `vector` extension is installed. It is not a trusted extension, so the database's user
  could not install it later without the superuser. Doing it now costs nothing.
- The DSN names the transaction door. With `--session`, it names the session door.
- A name is `a-z`, `0-9` and `_`, starts with a letter, and is at most 63 characters.
- A name that exists is refused, and nothing is changed. So is a name with a role left from an
  earlier database: `bin/remove-database --postgres NAME` drops it. So a consumer can never
  take a product's name once the product has it, nor a product a consumer's.
- Postgres keeps no copy of the password you can read back. A consumer's DSN goes to the
  consumer's admin, for the consumer's own `.env`.

**`--api`** adds the recipe for [PostgREST](https://postgrest.org), which a consumer runs in
its own repo. A name is then at most 49 characters, so that `NAME_authenticator` fits in 63.

- A schema `api`, owned by the database's user.
- The authenticator, `NAME_authenticator`: the one role PostgREST logs in as. It holds no table
  rights, and it is `NOINHERIT`, so it inherits none either. Without `NOINHERIT` it would carry
  the anon role's rights on every connection, before PostgREST has taken a role.
- The anon role, `NAME_anon`, which cannot log in and may use `api`. Grant it what it may read.
- An event trigger that tells PostgREST to reload its schema cache after each migration. Only
  the superuser may make an event trigger, which is why the helper makes it and not the
  consumer.

It also prints `PGRST_DB_URI`, a DSN for PostgREST, with `PGRST_DB_SCHEMAS` and
`PGRST_DB_ANON_ROLE`.
`PGRST_DB_URI` names the session door, whichever door the first DSN names. PostgREST hears
the reload on a `LISTEN`, and the transaction door drops a `LISTEN` without a word.

**`--clickhouse`** makes the database `NAME` on ClickHouse instead, and a user of the same name
with the grants under *ClickHouse*. It prints a DSN,
`CLICKHOUSE_URL=clickhouse://NAME:...@clickhouse:9000/NAME`, and `NAME_CLICKHOUSE_PASSWORD`.
It takes neither `--session` nor `--api`. `default`, `system` and `information_schema` belong
to ClickHouse and are refused.

### A new password

**`bin/new-password --postgres NAME`** gives one user a new random password, and prints its
lines once, as `bin/add-database` does. Put a product's line in Infisical and run `bin/up`, or,
on a host without Infisical, in `.env` and run `docker compose up -d`. Either way, compose
restarts every container whose line changed.

- `NAME` is a database's user, PostgREST's authenticator `NAME_authenticator`, or
  `pgbouncer_auth`. With `--clickhouse`, it is a database's user on ClickHouse. With
  `--session`, the DSN names the session door.
- The old password stops working at once. A product fails its logins until `up` restarts it
  with the new line.
- For `pgbouncer_auth`, the line is `PGBOUNCER_AUTH_PASSWORD`. Until `up` recreates both doors,
  they may refuse new logins. `postgres-18` is recreated too, because it holds the same line.
  It is a recovery key, so change your copy off the host too.
- **The superusers are changed by hand.** For Postgres, set the new password on Postgres, then
  change `POSTGRES_PASSWORD` in `.env` and run `up`. pgadmin keeps its own saved copy, so
  change it there too:

  ```sh
  docker exec -it postgres-18 psql -U postgres -c '\password postgres'
  ```

  For ClickHouse, change `CLICKHOUSE_PASSWORD` in `.env` and run `up`. ClickHouse reads it at
  every start.

### Dropping a database

**`bin/remove-database --postgres NAME`** drops the database `NAME`, its user, and PostgREST's
two roles, whichever of them exist. With `--clickhouse`, it drops the database and its user on
ClickHouse. It names what it will drop, and drops it only if you type the name. Every row in it
is lost. A product's database is dropped the same way, once the product is switched off. Then
it says to delete the product's line, `NAME_DB_PASSWORD` or `NAME_CLICKHOUSE_PASSWORD`, from
Infisical, or from `.env` on a host without Infisical.

- On Postgres the drop is `WITH (FORCE)`, because the doors keep pooled connections open to
  the database.
- On ClickHouse the drop is `SYNC`, so the name can be used again at once.

### The doors' auth user

It is made by [`initdb/door-auth.sh`](initdb/door-auth.sh). Postgres runs it at its first
start, against an empty volume, and never again. It makes `pgbouncer_auth`, the user the doors
look passwords up with, and its lookup function, `public.pgbouncer_get_auth`, in the
`postgres` database.

- The function is `SECURITY DEFINER`, so `pgbouncer_auth` needs no right to read the
  catalog itself. It hands a door the SCRAM verifier Postgres keeps, salt and iteration
  count included. That is what lets a door pass a client's SCRAM login through to Postgres.
- `pgbouncer_auth` is no superuser, holds no table rights, and inherits nothing. It reaches no
  database a product or a consumer owns, since `CONNECT` on each is revoked from everyone else.
- Its password is `PGBOUNCER_AUTH_PASSWORD`, and Postgres reads it at that first start only.
  To change it later, use `bin/new-password --postgres pgbouncer_auth`. Changing the line in
  `.env` alone breaks both doors: they then fail every login.

## Object store

userland never runs an object store, and it makes no bucket and no key: you make them. A
product that needs a bucket reads five variables under one prefix: `_BUCKET`, `_REGION`,
`_ENDPOINT`, `_ACCESS_KEY_ID` and `_SECRET_ACCESS_KEY`. `ARCHIVIST_S3`, `LANGFUSE_S3` and
`TWENTY_S3` are the three. The region is what your provider calls it, which is `auto` on
Cloudflare R2. The endpoint is a scheme and a host, with no path and no trailing `/`, because
the bucket's name is its own variable. On AWS it is `https://s3.<region>.amazonaws.com`.

**The keys, and what each may do.** Every key reaches its one bucket and nothing else. It lists
the bucket, gets and puts objects, and aborts a multipart upload, since a killed upload leaves
parts behind and abort can never remove a finished object. What else it may remove differs.
By default, nothing, so a compromised host cannot erase its own archives. Langfuse's and
twenty's may delete any object in their bucket, because langfuse's Data Retention feature
deletes and twenty moves a file by copying it and deleting the original. The archivist's may
delete under `locks/` and nowhere else, so a backup can clear the lock file it just wrote and
cannot touch the archive. Nothing in userland reads whether versioning is on, so no key may.
This is the policy for the archivist's key. Leave out the third statement for a key that may
delete nothing; for langfuse's and twenty's, add `s3:DeleteObject` to the second instead:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::BUCKET"},
    {"Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"], "Resource": "arn:aws:s3:::BUCKET/*"},
    {"Effect": "Allow", "Action": ["s3:DeleteObject"], "Resource": "arn:aws:s3:::BUCKET/locks/*"}
  ]
}
```

**Retention is yours, except where nothing may expire.** Nothing in userland deletes from a
bucket whose key cannot, and userland never writes a lifecycle rule: any rule is set by you, at
your provider. Without a rule, a bucket grows. The archivist's bucket is the exception, and it
is not a preference. What it holds is one repository whose parts point at each other, so an
object removed by age takes with it every later part that pointed at it. Set no rule at all
there. S3 performs an expiration itself, so no bucket policy can stop one you set by mistake.
Turn versioning on for it: *The archivist* says why.

**By hand, at any provider.**

- **AWS.** Bucket, then user, then the inline policy above, then an access key. New buckets
  block public access, disable ACLs and encrypt at rest by default, so nothing else is set.
  Retention is a lifecycle rule, where a bucket allows one. **No rule of any kind on the
  archivist's bucket**, not even a noncurrent-version expiration. An older version outside
  `locks/` is either restic sending an upload twice, or the evidence and the way back. Under
  `locks/`, every restic command leaves one, under a delete marker. *The archivist* says how to
  tell them apart, and how to remove the ones under `locks/` by hand. AWS also recommends a
  rule that aborts incomplete multipart uploads after a few days; that one is yours too, and it
  never fires for the archivist, whose objects are far below one part.
- **Backblaze B2.** An application key restricted to the one bucket with `listFiles`,
  `readFiles` and `writeFiles`, adding `deleteFiles` only for langfuse's and twenty's.
  `writeFiles` without `deleteFiles` is the no-delete key. A B2 key carries one capability list
  for the whole key, so **delete cannot be scoped to a prefix here**: the archivist's key either
  deletes everywhere or nowhere, and *The archivist* says what each costs. Every B2 bucket keeps
  versions, so the overwrite guard is there by default. Keep it that way and ignore restic's
  own advice to add a "keep only the last version" rule, which is for repositories that prune
  and would throw the guard away. Retention is B2's lifecycle rules; through the S3 API an
  expiration rule is paired with a delete-marker rule, and neither belongs on the archivist's
  bucket. Endpoint `https://s3.<region>.backblazeb2.com`, region as in the endpoint. **This is
  the provider to pick without an AWS account.**
- **Cloudflare R2.** A token of *Object Read & Write* scoped to the bucket. There is no level
  that writes without deleting, so on R2 the archivist's key can delete anywhere in its bucket,
  and a compromised host could erase its own archives there. R2 has no versioning either, so
  the overwrite guard is absent as well; the archivist's own history is unaffected, because it
  never lived in versions. Both of those are R2's floor, not a setting: R2 is the weakest of
  the three for the archivist. Lifecycle rules exist and are prefix-scoped, and none belongs on
  the archivist's bucket. Endpoint `https://<account id>.r2.cloudflarestorage.com`, region
  `auto`. Virtual-hosted requests are accepted, so no path-style setting is needed.

## Secret store

The archivist's master key lives in a secret store you own, never on the host. userland reads
it and never writes it. Five variables reach it: `ARCHIVIST_KEY_PROVIDER` (`ssm`, AWS
Parameter Store, the one there is), `ARCHIVIST_KEY_NAME`, `ARCHIVIST_KEY_REGION`,
`ARCHIVIST_KEY_ACCESS_KEY_ID` and `ARCHIVIST_KEY_SECRET_ACCESS_KEY`.

Make these, in this order:

1. A `SecureString` parameter holding 32 random bytes. **Never overwrite it**: a replaced
   master key makes every archive the archivist ever wrote unreadable.
2. A user for it.
3. This policy on the user. `NAME` is the parameter's name without its leading slash, and
   `KEY-ID` is the account's `aws/ssm` key, which `kms describe-key --key-id alias/aws/ssm`
   returns; a `SecureString` written without a key of your own is encrypted under it.
4. An access key for the user.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["ssm:GetParameter"], "Resource": "arn:aws:ssm:REGION:ACCOUNT:parameter/NAME"},
    {"Effect": "Allow", "Action": ["kms:Decrypt"], "Resource": "arn:aws:kms:REGION:ACCOUNT:key/KEY-ID"}
  ]
}
```

The key may only read that one parameter, and nothing it holds writes.

**Infisical's master key** is the second parameter there: a `SecureString` of exactly 32
characters, such as `openssl rand -hex 16` makes. userland never reads it, so it needs no user
and no access key. You copy it into `.env` by hand, as `INFISICAL_ENCRYPTION_KEY`, because
Infisical reads it only as a setting when it starts, and compose hands a container a setting only
from `.env`. So, unlike the archivist's, it sits on the host while Infisical runs. Infisical keeps
a copy of it too, so the `.env` that `bin/up` writes has it. It gives away nothing more there:
every `.env` is on the host in plain text anyway, and no `.env` is ever archived. **Never overwrite it either**: Infisical will not start with another key, and every
archive of its database needs the key it was taken with.

The secret store holds these two master keys and nothing else. The access key that reads the
archivist's is a recovery key, and you keep it yourself, under *Bringing a host back*.

## traefik

traefik is the one container that publishes a port: 80, and 443 in public visibility, where
the `websecure` entrypoint listens. Every HTTP container is reached through it by four labels,
the same in both visibilities, and none holds a certificate or a redirect of its own. traefik
reads its settings from `TRAEFIK_*` variables, not flags, because compose merges `environment`
by key: `compose/public.yml` adds its settings to the local ones rather than repeating them.

**In public, TLS sits on the entrypoint.** Every router attached to `websecure` gets a
certificate for the names in its `Host` rule, and `web` sends every plain-HTTP request to
`websecure` before any router is matched. That is why a router needs no TLS label and no
entrypoint label: a router with no entrypoint attaches to every one.

**Certificates come over a DNS-01 challenge**, from Let's Encrypt, through the provider
`DNS_PROVIDER` names. A certificate can therefore be issued before the hostname has a public
DNS record, but nothing answers on the hostname until it does. The propagation check asks the
public resolvers `1.1.1.1` and `8.8.8.8` rather than the host's own, and on Route 53 no
`AWS_HOSTED_ZONE_ID` is passed, so the zone of each hostname is found for it; both are what let
one host hold certificates in more than one DNS zone.

**It logs at `INFO`**, not traefik's default of `ERROR`, so every certificate issued or renewed
is a line in `docker logs traefik`. At `ERROR` a renewal that succeeded logs nothing, and you
cannot tell it apart from one that never ran.

| Variable | Needed | Meaning |
|---|---|---|
| `CERT_EMAIL` | required in public | Email for the ACME account. |
| `DNS_PROVIDER` | required in public | DNS-01 provider: `route53` or `cloudflare`. |
| `AWS_ACCESS_KEY_ID` | with `route53` | Access key that may write TXT records in the zone. |
| `AWS_SECRET_ACCESS_KEY` | with `route53` | Its secret. |
| `AWS_REGION` | default `us-east-1` | Region for Route 53 calls. |
| `CF_DNS_API_TOKEN` | with `cloudflare` | Cloudflare token that may edit DNS in the zone. |
| `TRAEFIK_MEM_LIMIT` | default no limit | Memory limit of `traefik`. |

## Postgres

Three containers, always on together. `postgres-18` is the server: one Postgres for the whole
host, with a database per product and per consumer, each owned by a user of the same name.
`pgbouncer-transaction` and `pgbouncer-session` are the two doors, under *For a consumer*.
`postgres-dumper` archives every database on it, under *The archivist*.

**Nothing reaches Postgres but through a door, except the dumper and pgadmin.** It is a
wall, not a habit: `postgres-18` sits on a private network, `postgres-server`, that only the
doors, the dumper and pgadmin join. Consumers and products join `userland_postgres`, where
only the doors are. The dumper names `postgres-18:5432` so that it archives every database
whichever door is on. pgadmin does because its Query Tool's stop button cancels by the process
id its connection was handed at the start, and through a door that id is the door's own, so the
button reports the query complete while it runs on.

| Variable | Needed | Meaning |
|---|---|---|
| `POSTGRES_PASSWORD` | required | Password of the Postgres superuser, `postgres`. |
| `PGBOUNCER_AUTH_PASSWORD` | required | Password of `pgbouncer_auth`, the user the doors look passwords up with. Postgres reads it at its first start only, and *Provisioning* says how to change it. |
| `POSTGRES_DUMPER_HOURS` | default `24` | Hours between two runs of `postgres-dumper`, counted from 00:00 UTC: 1, 2, 3, 4, 6, 8, 12 or 24. |
| `POSTGRES_18_MEM_LIMIT` | default no limit | Memory limit of `postgres-18`. |
| `PGBOUNCER_TRANSACTION_MEM_LIMIT` | default no limit | Memory limit of `pgbouncer-transaction`. |
| `PGBOUNCER_SESSION_MEM_LIMIT` | default no limit | Memory limit of `pgbouncer-session`. |
| `POSTGRES_DUMPER_MEM_LIMIT` | default no limit | Memory limit of `postgres-dumper`. |

## pgadmin

pgadmin is a product of its own, and it needs postgres. It registers exactly one server,
`postgres-18`, from [`config/pgadmin-servers.json`](config/pgadmin-servers.json), loaded into
an empty `pgadmin_data` volume at the first start and never again.
`PGADMIN_REPLACE_SERVERS_ON_STARTUP` is deliberately not set: it deletes every server row
and re-imports at each start, and a password saved in the browser is part of the row it
deletes. The trade is that editing that file does not reach a pgadmin that has already
run. Change the server in the browser too, or re-seed: take pgadmin out of `COMPOSE_FILE`,
`docker volume rm userland_pgadmin_data`, and put it back.

That server connects as the superuser, and its password is not in the file: paste
`POSTGRES_PASSWORD` from `.env` the first time, and pgadmin keeps an encrypted copy in its
volume if you tick *Save password*.

**Its own login is the only lock**, and it stands in front of the superuser of every
database on this host. That is why it is its own product: on a public host you may want it
off while Postgres stays on. The email and password in `.env` are what you sign in with;
nothing else is in the way, in either visibility. The container is created with them only
when its volume is empty, so changing either line afterwards does not change the login of a
pgadmin that has already started. Re-seed it as above, which costs one server row and a
saved password. The image floats on `latest` on purpose, so security fixes arrive without
review, and its volume needs no backup for the same reason.

Its session cookie follows `SECURE_COOKIES`: secure in public, where there is TLS for it to
ride; not in local, where a secure cookie is a login that never completes. It is told there is
exactly one proxy in front of it, traefik.

| Variable | Needed | Meaning |
|---|---|---|
| `PGADMIN_DEFAULT_EMAIL` | required | Email address you sign in to pgadmin with. |
| `PGADMIN_DEFAULT_PASSWORD` | required | Password you sign in to pgadmin with. |
| `PGADMIN_MEM_LIMIT` | default no limit | Memory limit of `pgadmin`. |

## ClickHouse

userland runs ClickHouse as one container. langfuse calls that development-only, because one
box has no redundancy. Every event langfuse ingests is written to your bucket first, and
Postgres holds everything you configure; ClickHouse holds what you see in the UI.
`clickhouse-dumper` archives every database on it, under *The archivist*.

The image is `clickhouse/clickhouse-server:26.8`, the long-term-support line after the 26.4
that langfuse recommends, and it moves within that line. The container runs at ClickHouse's
own defaults, in UTC, which langfuse requires, with the one setting the image documents,
`nofile 262144`. `CLICKHOUSE_PASSWORD` is the admin user `default`, which provisioning and
the dumper use and no product does; the image turns on access management for it, so it may
create users.

**Every product or consumer gets its own database and user on ClickHouse, exactly as on
Postgres**, made by `bin/add-database --clickhouse`, under *Provisioning*. The
compose file holds nothing product-specific, and the image's `CLICKHOUSE_DB` is not used: it
acts only on a first start with an empty volume, and would put a product's name in the shared
file. The user is named as its database and holds, on that database alone, what langfuse
documents its user needs: `SELECT`, `INSERT`, `ALTER UPDATE`, `ALTER DELETE`, `CREATE`,
`DROP TABLE`, `DROP VIEW`, the column, index and view `ALTER`s, `SYSTEM SYNC REPLICA`,
`SYSTEM MERGES` and `ALTER SETTINGS`; and `SELECT` on the columns of `system.parts`,
`system.mutations` and `system.tables` it reads, on `system.processes` and on
`system.query_log*`. It cannot read another database, make one, or make a user. Every user
on ClickHouse gets the same grants, whoever it is for.

**ClickHouse is the heaviest container here.** `CLICKHOUSE_MEM_LIMIT` is where a cap goes:
ClickHouse reads the cgroup limit and keeps its own ceiling at nine tenths of it, so a compose
limit is one it respects rather than one it dies against. No number is written here.

ClickHouse logs at trace level to files inside the container, in `/var/log/clickhouse-server`,
rotated by the image; `docker logs clickhouse` shows only the entrypoint. Nothing is published
on the host: products reach it on `userland_clickhouse`, ports 8123 for HTTP and 9000 for the
native protocol, and you reach it with `docker exec clickhouse clickhouse-client`.

Its backup directory, `/var/lib/clickhouse/backups`, is the backup folder, `backups`, which
the dumpers and the archivist mount too. ClickHouse writes its archives into `clickhouse/`
there.

| Variable | Needed | Meaning |
|---|---|---|
| `CLICKHOUSE_PASSWORD` | required | Password of the ClickHouse admin user, `default`. |
| `CLICKHOUSE_DUMPER_HOURS` | default `24` | Hours between two runs of `clickhouse-dumper`, counted from 00:00 UTC: 1, 2, 3, 4, 6, 8, 12 or 24. |
| `CLICKHOUSE_MEM_LIMIT` | default no limit | Memory limit of `clickhouse`. |
| `CLICKHOUSE_DUMPER_MEM_LIMIT` | default no limit | Memory limit of `clickhouse-dumper`. |

## n8n

n8n is two containers, always on together. `n8n` is the editor, the webhooks and the
schedules, and it runs every workflow itself. `n8n-runners` runs every Code node, in a
container of its own with its own user, and reaches nothing but n8n's task broker on port 5679,
which nothing routes. n8n calls running Code nodes inside n8n itself internal mode, and does
not recommend it for an instance that holds credentials, so the runners are part of the
product. The two images come from two registries, and that is not a mistake: `docker.n8n.io`
mirrors `n8nio/n8n` alone and answers `NAME_UNKNOWN` for the runners image, so that one comes
from Docker Hub. **The two tags are one version**, and every upgrade moves both.

**Its database is reached through the transaction door**, and two facts follow from that
door alone. n8n applies its query time limit by sending `SET statement_timeout` on every
connection it opens, and the transaction door discards a `SET`. So n8n is told to send none
(`DB_POSTGRESDB_STATEMENT_TIMEOUT: 0`), and the same limit, n8n's own five minutes, belongs on
the `n8n` user instead, where Postgres applies it as each connection starts and the door cannot
touch it. For the same reason **the schema stays `public`**: any other name is set by a
`SET search_path` the door discards just the same, and n8n would read and write `public`
regardless. `public` is n8n's default, so nothing names it.

**Put the time limit on the `n8n` user once**, after `bin/add-database --postgres n8n`. The
archive of the globals keeps it, so a restore brings it back:

```sh
docker exec postgres-18 psql -U postgres -c "ALTER ROLE n8n SET statement_timeout = '5min'"
```

**`N8N_ENCRYPTION_KEY` is a one-way door.** Every saved credential is encrypted with it; it is
not in the database and cannot be derived, so losing it loses every credential for good. Put it
in `.env` before the first start, because n8n otherwise writes one of its own into the volume
where you would have to go and find it. Keep a copy off the machine.

**The volume needs no backup.** Postgres holds the workflows, the credentials and every
execution, so the archive of Postgres covers them. `n8n_data` holds only what n8n rebuilds: the
binary data of an execution, which n8n prunes together with the execution that owns it; the
settings file, which comes back from `.env` because the key is pinned there; the node cache;
and any community node, which `N8N_REINSTALL_MISSING_PACKAGES` reinstalls from n8n's own
database record at start. A file a workflow must keep is the workflow's job: write it to
durable storage from the workflow itself, because n8n deletes from that volume on its own
schedule. Binary data stays on the filesystem, n8n's default in this mode, and that is a
one-way door too: a later change of mode does not move the old files.

**Behind traefik**, n8n is told there is exactly one proxy (`N8N_PROXY_HOPS: 1`), so it trusts
one forwarded address and no more; a larger number would let a client forge its own. In local
visibility `SECURE_COOKIES=false` turns off the secure flag on n8n's cookie, because n8n
refuses to serve its editor over plain HTTP from any hostname but `localhost` or `127.0.0.1`,
and `n8n.localhost` is not exempt; Safari refuses regardless of hostname.

**Time.** The clock runs in UTC, the image's own default. `GENERIC_TIMEZONE` sets what a
schedule means by 03:00, and defaults to `UTC` here rather than n8n's `America/New_York`; add
the line to `.env` to change it for the instance, and any workflow may set its own.

**Health.** The healthcheck asks `/healthz/readiness`, which answers 200 only once the
database is connected, the migrations are done and the start has finished; `/healthz` answers
ok at all times and says nothing about the database. It runs `node`, the one binary the image
is certain to carry, rather than `curl`. `n8n-runners` waits for it.

**Upgrading.** An upgrade runs the new version's migrations at start; a failure is fatal, and
many migrations have no way back, so an upgrade is an irreversible change to the database and
never runs by itself: both tags are exact. Before moving them, read every breaking-changes
entry between the two versions and take a fresh dump of the `n8n` database. A downgrade is a
restore from that dump.

**One thing only you can enforce.** A Postgres Trigger node holds its own credential and uses
`LISTEN`, which the transaction door drops silently: point that credential at
`pgbouncer-session:5432`, never at the door n8n itself uses.

n8n runs in n8n's regular mode: no queue, no worker, no Redis. Pruning, the pool and every
other number run at n8n's defaults.

| Variable | Needed | Meaning |
|---|---|---|
| `N8N_DB_PASSWORD` | required | Password of the `n8n` user on Postgres, which owns the `n8n` database. |
| `N8N_ENCRYPTION_KEY` | required | Key n8n encrypts saved credentials with. Keep a copy off the machine. |
| `N8N_RUNNERS_AUTH_TOKEN` | required | Shared secret between n8n and its runners. |
| `GENERIC_TIMEZONE` | default `UTC` | What a schedule's times mean. |
| `N8N_MEM_LIMIT` | default no limit | Memory limit of `n8n`. |
| `N8N_RUNNERS_MEM_LIMIT` | default no limit | Memory limit of `n8n-runners`. |

## Metabase

Metabase is one container and one JVM: the web UI, the query engine, the scheduler, and the
MCP server at `/api/metabase-mcp`. Its database, `metabase` on Postgres, holds every
dashboard, question, user and setting, and the credentials of every data source you connect.

**Its database is reached through the transaction door.** Nothing Metabase does against its
own database needs the session door: it takes no advisory lock there, and an upgrade from
v0.50 to v0.63 ran 833 migrations through the transaction door without a warning from the
door.

**A data source is a credential of your own, and so is its door.** A database you connect in
Metabase's Admin is reached by a connection Metabase makes with the host and port you type
there, and nothing in `.env` reaches it. Metabase's Postgres driver sends `SET SESSION
TIMEZONE` before a query when a report timezone is set, and `SET ROLE` when impersonation is
on, and the transaction door discards both. Point a data source that uses either at
`pgbouncer-session:5432`; one that uses neither may take the transaction door like anything
else.

**`MB_ENCRYPTION_SECRET_KEY` is a one-way door.** It encrypts the secret columns of Metabase's
database, the data-source credentials above all; without it they sit in clear in the database
and in every archive of it. Put it in `.env` before the first start, so the database is
encrypted from its first boot. Metabase's five cases, as observed on v0.63.15:

| Its database | The key | What happens |
|---|---|---|
| unencrypted | none | starts, and logs that encryption is disabled |
| unencrypted | a new one | starts, and encrypts the database in place on that start |
| encrypted | the right one | starts |
| encrypted | a wrong one | exits 1 before any migration runs |
| encrypted | none | exits 1 before any migration runs |

The last two restart forever, and behind traefik they read as a 404 rather than an error,
because traefik routes no container whose health is still `starting`. `remove-encryption` and
`rotate-encryption-key` both need the key you lost, so the only way back is a dump taken
before encryption was on, and for a database encrypted from its first boot there is none:
every dashboard and question is rebuilt by hand. Keep a copy of the key off the machine, and
apart from the Postgres archives; an archive and the key that opens it in one place are one
loss, not two.

**Set the Site URL at install.** Admin → Settings → General → Site URL, to the address you
reach it on: `https://metabase.DOMAIN` in public, `http://metabase.localhost` in local. It is a
row in Metabase's database, and nothing here sets it. Metabase builds more than its email links
from it: the OAuth discovery of its MCP server, every endpoint that server advertises and its
`WWW-Authenticate` challenge all derive from it, so a client registered against one address
stops matching when it changes, and registering again is the only fix. Set it before any MCP
client registers, and again after changing `DOMAIN`. Behind traefik, Metabase sees traefik's
plain-HTTP hop, so an address it guesses for itself can read `http://` in public visibility.

**The MCP server** is part of the application, on every edition. A client signs in over OAuth
2.0 against a server Metabase embeds, and its token carries the permissions of the account
that authorised it, so a connection is per person rather than a shared key. It is governed in
Admin, not here.

**Leave Metabase's own Redirect to HTTPS off.** In public visibility traefik's entrypoint
already redirects, so the setting adds nothing, and it turns into a redirect loop if
`X-Forwarded-Proto` ever stops arriving.

**Upgrading.** The tag is exact and moves only when this repo moves it, so a `git pull` that
moves it in `compose/metabase.yml` is an upgrade, and it runs at the next `docker compose up`.
Metabase runs the new version's migrations at start, a failure is fatal, and a downgrade is not
the way back: `migrate down` moves one major per run, from the newer binary, and cannot undo
what happens at start rather than in a migration, so Metabase's own advice is to restore a
dump. Before that `up`:

1. Read every release note between the two versions. What bites is rarely in the migrations:
   a major can move the sample database's engine, break the driver plugin API so a
   third-party driver needs rebuilding, or move the bundled JVM.
2. Take a fresh archive with `docker exec postgres-dumper dumper now`. Last night's is not
   one minute ago, and this one is the rollback.
3. Rehearse on another machine: restore that archive into a throwaway Postgres, start the new
   tag against it, and compare the counts of dashboards, questions and users, `/api/health`,
   and the schema version in the log. The rehearsal needs the key, since an encrypted
   database does not start without it, so that machine holds production data and the key to
   its credentials: give it no route to your data sources, and destroy it afterwards.

**Health.** The healthcheck asks `/api/health`, which answers 200 once the application has
started and its database is reachable; `start_period` is 120 seconds, the JVM's start plus a
first boot's migrations. `/dev/urandom` is mounted over `/dev/random`, because the JVM blocks
on a starved entropy pool, and that shows as a start that hangs rather than one that fails.

**The volume needs no backup.** Metabase downloads its own driver JARs into
`metabase_plugins` at start. A third-party driver you put there by hand is the one thing that
would not come back: keep your own copy, and expect to rebuild it after a major upgrade. The
database is on Postgres, so `postgres-dumper` archives it with everything else.

Both connection pools and every other number run at Metabase's defaults.

| Variable | Needed | Meaning |
|---|---|---|
| `METABASE_DB_PASSWORD` | required | Password of the `metabase` user on Postgres, which owns the `metabase` database. |
| `MB_ENCRYPTION_SECRET_KEY` | required | Key Metabase encrypts saved data-source credentials with. Keep a copy off the machine. |
| `MB_AGGREGATED_QUERY_ROW_LIMIT` | default `10000` | Most rows an aggregated query returns. |
| `MB_UNAGGREGATED_QUERY_ROW_LIMIT` | default `2000` | Most rows an unaggregated query returns. |
| `METABASE_MEM_LIMIT` | default no limit | Memory limit of `metabase`. |

## Langfuse

Langfuse is three containers, always on together. `langfuse-web` is the UI and the API your
SDKs send traces to, and it runs every migration. `langfuse-worker` takes what was ingested
off the queue and writes it to ClickHouse, and runs exports and Data Retention; without it the
UI stays empty. `langfuse-redis` is that queue: langfuse's own Redis, which nothing else is
ever pointed at. The web and worker images are **one version**, and every upgrade moves both.
The worker starts only once the web is healthy, which is once both migrations are done.

**Where everything lives.** Postgres holds what you configure: users, projects, prompts, API
keys. ClickHouse holds what you see: traces, observations, scores, each in langfuse's own
database and user. Every event is written to your bucket first, under `events/`, and media and
batch exports go to the same bucket under `media/` and `exports/`. The Redis volume holds only
the queue, with append-only persistence on, so a restart loses no job, and `noeviction`,
because langfuse requires it: an evicted key is a lost job. The two dumpers archive the two
databases; the queue is not archived, since its jobs are minutes old and their events are in
the bucket. ClickHouse runs as one container, which langfuse calls development-only, and
*ClickHouse* says why userland accepts that.

**Browsers and SDKs read and write media straight in your bucket through short-lived signed
links, so the bucket must be reachable from wherever you use langfuse. A cloud bucket is.**
Nothing is routed through traefik for it, and no CORS rule is needed: the UI shows an image
with a signed link, not a script. Path-style requests are off, which AWS, Backblaze B2 and
Cloudflare R2 all accept.

**langfuse's access key may delete objects, because Data Retention deletes old traces and
media nightly once you turn it on. It reaches langfuse's bucket and nothing else.** Retention
is set per project, three days at least, and never touches exports: a lifecycle rule on
`exports/` is the only thing that trims those, and like every rule it is yours. On a bucket
with versioning on, Data Retention leaves delete markers and old versions behind, and a rule
for those is yours too.

**The databases.** `DATABASE_URL` goes through the transaction door. The migrations go through
the session door, as `DIRECT_URL`, because Prisma holds a session-level advisory lock for the
whole of a migration, which the transaction door cannot keep; `langfuse-web` waits for both
doors for that reason, and the worker only the first. On ClickHouse, the migrations make every
table in langfuse's database. Langfuse requires both stores to run in UTC, which they do, and
ClickHouse at 25.12 or later, which 26.8 is. Lightweight updates stay off, langfuse's default,
so nothing is set on its ClickHouse user.

**Accounts.** Sign-up is off in both visibilities. langfuse makes one account from
`LANGFUSE_INIT_USER_EMAIL` and `LANGFUSE_INIT_USER_PASSWORD` when it starts, the owner of an
organization called `userland`; the password must be at least eight characters. Sign-up is
off even in local because traefik listens on every interface, so on a network you share,
anyone who sends `langfuse.localhost` to this machine would reach langfuse and could sign up.
Nobody else can make an account while sign-up is off, including someone you invite, so a
teammate joins like this: add `LANGFUSE_AUTH_DISABLE_SIGNUP=false` to `.env`, run
`docker compose up -d`, invite them and let them sign up, then remove the line and run it
again. langfuse sends no email here, so a forgotten password cannot be reset from the sign-in
page: langfuse's own way back is to rename the account in the database, sign up again, and
move its memberships across. The first account is made once: changing the two lines later
makes nothing and changes no password.

**The keys.** `LANGFUSE_ENCRYPTION_KEY` encrypts the LLM API keys and integration credentials
you save in langfuse, and it is a one-way door: losing it loses them, so keep a copy off the
machine. langfuse reads it as exactly 64 hexadecimal characters. `LANGFUSE_SALT` hashes API
keys, and a new one costs nothing: langfuse checks a key the slow way once and re-hashes it with
the new salt. A new `LANGFUSE_NEXTAUTH_SECRET` signs everyone out. The variables carry
langfuse's name because `.env` is shared by every container, and `SALT` alone would claim a
name any product might want; the compose file hands each to langfuse under its own name.

**Health.** The web's healthcheck asks `/api/public/health` and the worker's `/api/health`.
Both containers are told to listen on `0.0.0.0`: Docker sets `HOSTNAME` to the container's id,
and langfuse listens on whatever `HOSTNAME` resolves to, so without it nothing answers on the
container's loopback and the healthcheck fails. The web's `start_period` is five minutes, room
for the first start's migrations; a fresh install took under half a minute.

**Upgrading.** Both tags are exact. The web runs the new version's migrations when it starts,
on Postgres and on ClickHouse, and langfuse documents which releases need more than that.
Read the release notes between the two versions, take a fresh archive with
`docker exec postgres-dumper dumper now` and `docker exec clickhouse-dumper dumper now`, then
move both tags together.

Everything else, telemetry included, runs at langfuse's defaults.

| Variable | Needed | Meaning |
|---|---|---|
| `LANGFUSE_DB_PASSWORD` | required | Password of the `langfuse` user on Postgres, which owns the `langfuse` database. |
| `LANGFUSE_CLICKHOUSE_PASSWORD` | required | Password of the `langfuse` user on ClickHouse, which reaches the `langfuse` database and nothing else. |
| `LANGFUSE_ENCRYPTION_KEY` | required | 64 hex characters. Key langfuse encrypts saved LLM and integration credentials with. Keep a copy off the machine. |
| `LANGFUSE_SALT` | required | Salt langfuse hashes API keys with. |
| `LANGFUSE_NEXTAUTH_SECRET` | required | Secret langfuse signs sign-in sessions with. |
| `LANGFUSE_REDIS_PASSWORD` | required | Password of langfuse's own Redis. |
| `LANGFUSE_INIT_USER_EMAIL` | required | Email address of the first account. |
| `LANGFUSE_INIT_USER_PASSWORD` | required | Password of the first account, eight characters or more. |
| `LANGFUSE_AUTH_DISABLE_SIGNUP` | default `true` | `false` opens sign-up while a teammate joins. |
| `LANGFUSE_S3_BUCKET` | required | Name of langfuse's bucket. |
| `LANGFUSE_S3_REGION` | required | Region of the bucket, as the provider names it. |
| `LANGFUSE_S3_ENDPOINT` | required | Scheme and host the bucket is reached at, with no path. |
| `LANGFUSE_S3_ACCESS_KEY_ID` | required | Access key that reaches this bucket and nothing else. It may list the bucket and get, put and delete objects. |
| `LANGFUSE_S3_SECRET_ACCESS_KEY` | required | Its secret. |
| `LANGFUSE_WEB_MEM_LIMIT` | default no limit | Memory limit of `langfuse-web`. |
| `LANGFUSE_WORKER_MEM_LIMIT` | default no limit | Memory limit of `langfuse-worker`. |
| `LANGFUSE_REDIS_MEM_LIMIT` | default no limit | Memory limit of `langfuse-redis`. |

## Twenty

Twenty is three containers, always on together. `twenty-server` is the UI and the API, and it
runs every migration when it starts. `twenty-worker` runs the background jobs: imports,
workflows, mail and calendar sync, and the scheduled jobs the server registers each time it
starts; without it nothing imports and no workflow fires. `twenty-redis` holds the queue and the
cache: twenty's own Redis, which nothing else is ever pointed at, so its pub/sub is heard by
nothing else either. It runs `noeviction`, because an evicted key is a lost job, with
append-only persistence, so a restart loses no queued job. The server and worker run one image
at **one version**, and every upgrade moves both. The worker starts only once the server is
healthy, which is once its migrations are done.

**The session door, and why.** twenty holds a session-scoped advisory lock across a callback,
in workspace deletion and in the job that cleans up suspended workspaces. On the transaction
door that lock leaks, because the door hands the connection to someone else between
transactions: two workers enter the section the lock guards, and the unlock raises. So both
containers name `pgbouncer-session`. twenty keeps pools of its own, of up to 10 connections
each, and holds an idle connection for ten minutes; a fresh install with one person signed in
held 22. That is why the session door lends as many connections as Postgres accepts. At
pgbouncer's default of 20 per database, twenty filled the door within a minute of starting,
its requests waited in line, and twenty gave up on each after ten seconds with
`Query read timeout`. No pool size is set for twenty.

**The extensions.** twenty creates `uuid-ossp`, `unaccent` and `citext` in its database on
its first start. All three are trusted extensions that ship with Postgres, so the database's
own user installs them, and no superuser is involved. **twenty swallows database errors**: its
setup catches a failed statement and carries on, so a refused extension does not stop the
start. It surfaces later as a broken `searchVector` column, which is how twenty searches
records. So verify what twenty made rather than trusting a clean start: once a workspace
exists, every object in its schema has a generated `searchVector` column, and a saved
record's is filled in.

```sh
docker exec postgres-18 psql -U postgres -d twenty -c "SELECT count(*) FROM information_schema.columns WHERE column_name = 'searchVector' AND is_generated = 'ALWAYS'"
```

**The first start.** On an empty database twenty's entrypoint sets up the schema, migrates,
upgrades, flushes its cache and registers its scheduled jobs, and only then starts the
server; a fresh install was healthy in about 40 seconds. Before the first migration it looks
for tables that do not exist yet, so a first start logs `relation "core.…" does not exist` a
few times, and that is expected. The setup script has been reported never to close its
connection against a Postgres of your own, so the process never exits and the migrations
never run ([twentyhq/twenty#23786](https://github.com/twentyhq/twenty/issues/23786)). The
report is closed and the script unchanged, and here it exited behind the session door; a
first start that stops after `create immutable unaccent wrapper function` is that, and it is
the first thing to look at. The healthcheck's `start_period` is five minutes.

**Files go to your bucket.** Attachments, pictures, logos and everything else twenty stores as
a file go to `TWENTY_S3`, and nothing is kept on the host. twenty also keeps the app
marketplace's images there, which the worker copies in on a schedule, about 18 MB on a fresh
install, and each workspace's generated client code. Creating a workspace writes to the
bucket, so it fails with *An error occurred* while the bucket cannot be reached. Downloads go
through twenty rather than to the bucket directly, so no CORS rule is needed and the bucket
need not be reachable from your browser. Path-style requests are always on in twenty, and
AWS, Backblaze B2 and Cloudflare R2 all accept them.

**twenty's access key may delete anything in its bucket**, because twenty moves a file by
copying it and deleting the original, and deletes a file when you delete its attachment. It
reaches twenty's bucket and nothing else. `postgres-dumper` archives twenty's database, not the
bucket, so a file you delete in twenty is gone even while an older snapshot of the database
still names it.

**Accounts.** The first person to sign up creates the workspace and becomes twenty's server
admin. After that nobody signs up without an invitation, since twenty lets only a server admin
make another workspace. In local visibility only this machine resolves `twenty.localhost`,
but traefik listens on every interface, so on a network you share, anyone who sends that name
to this machine reaches twenty. **In public visibility, sign up the moment twenty is
healthy.** Until the first account exists, anyone who reaches `twenty.` under your domain
becomes the server admin, and traefik's certificate for that name appears in public
certificate logs within minutes of switching twenty on. twenty sends no email here: its mail
driver writes each message to its log instead, so a password reset or an invitation is in
`docker logs twenty-server`.

**The keys.** `TWENTY_ENCRYPTION_KEY` encrypts the keys twenty signs sessions with and every
credential you save in it, such as a connected mail account, and it is a one-way door: losing
it loses them and signs everyone out, so keep a copy off the machine. twenty reads it as
`ENCRYPTION_KEY`; the variable carries twenty's name because `.env` is shared by every
container. twenty's older `APP_SECRET` is read only by an instance that predates that key, so
it is not set. To change the key, twenty's own rotation reads the old one from
`FALLBACK_ENCRYPTION_KEY`. `TWENTY_REDIS_PASSWORD` travels inside `REDIS_URL`, the only way
twenty takes its Redis, so it may hold only URL-safe characters.

**Health.** The server's healthcheck asks `/healthz` with the image's `curl`. The worker serves
nothing over HTTP and nothing waits for it, so it has no healthcheck.

**Upgrading.** The tag is exact, never `latest`. Each time the server starts it runs twenty's
upgrade before it serves, which migrates the core schema and every workspace, and it starts
anyway, with a warning in its log, when a workspace fails to migrate. Read the release notes
between the two versions, take a fresh archive with `docker exec postgres-dumper dumper now`,
then move the tag, which moves both containers.

Everything else, telemetry and the marketplace's catalogue included, runs at twenty's defaults.

| Variable | Needed | Meaning |
|---|---|---|
| `TWENTY_DB_PASSWORD` | required | Password of the `twenty` user on Postgres, which owns the `twenty` database. |
| `TWENTY_ENCRYPTION_KEY` | required | Key twenty encrypts its signing keys and saved credentials with. Keep a copy off the machine. |
| `TWENTY_REDIS_PASSWORD` | required | Password of twenty's own Redis. URL-safe characters only. |
| `TWENTY_S3_BUCKET` | required | Name of twenty's bucket. |
| `TWENTY_S3_REGION` | required | Region of the bucket, as the provider names it. |
| `TWENTY_S3_ENDPOINT` | required | Scheme and host the bucket is reached at, with no path. |
| `TWENTY_S3_ACCESS_KEY_ID` | required | Access key that reaches this bucket and nothing else. It may list the bucket and get, put and delete objects. |
| `TWENTY_S3_SECRET_ACCESS_KEY` | required | Its secret. |
| `TWENTY_SERVER_MEM_LIMIT` | default no limit | Memory limit of `twenty-server`. |
| `TWENTY_WORKER_MEM_LIMIT` | default no limit | Memory limit of `twenty-worker`. |
| `TWENTY_REDIS_MEM_LIMIT` | default no limit | Memory limit of `twenty-redis`. |

## The archivist

The archivist keeps off this host what you cannot lose with it: every database on Postgres and
ClickHouse. Three containers share the work, and none of them waits on another:

- **`postgres-dumper` and `clickhouse-dumper`** archive every database on their datastore into
  the **backup folder**, the volume `backups`, on a schedule of their own. Each is part of its
  datastore's product, so it is on whenever that datastore is.
- **The archivist** takes every archive it finds in the backup folder off the host, into a
  bucket of its own, and deletes the local copy once it is up. It knows no datastore: it joins
  no datastore's network and reads no datastore's password.

An archive still in the backup folder sits on the same disk as the database it came from, so it
is not yet a backup.

**The dumpers.**

- A dumper runs every `POSTGRES_DUMPER_HOURS` or `CLICKHOUSE_DUMPER_HOURS` hours, counted from
  00:00 UTC. The default, 24, is every day at midnight UTC; 6 is 00:00, 06:00, 12:00 and 18:00.
  It is a shell loop, [`scripts/dumper`](scripts/dumper), run in the server's own image, so its
  client always matches the server.
- **It archives nothing until it has its intent**: your word that this host is the one that
  writes to the bucket. You give it once to each dumper, by hand, with its first `dumper now`,
  below. From then on its slots run. Until then it says so in `docker logs`, it is unhealthy, and
  `bin/up` names it. No helper ever gives it, because a drill runs the same helpers on a
  throwaway, and a throwaway must never write to the bucket. *Bringing a host back* says why.
- It writes the time of its last finished run into `last-run`, in its folder. That file is its
  intent. After a restart, a run that fell due while it was down runs at once, and only once.
- It looks at the clock at least once a minute. `sleep` does not count the time a host is
  suspended, as a laptop is every night and a server's VM may be, so a dumper never sleeps
  longer than that. A slot that fell due while the host was suspended runs within a minute of
  the host waking, and only once.
- A slot that finds its datastore down tries again every minute, and runs as soon as it can.
- Every run archives every database it finds, so **no database is ever named**: one is
  archived from the first run after it exists, and one that is dropped stops appearing. Every
  run also archives the **globals**: the users and their passwords, which live outside every
  database.
- A run writes into a folder named by its start time, such as `postgres/20260925T000000Z/`.
  The folder ends in `.writing` until the whole run is done. Nothing is ever replaced. While
  the archivist is away, runs pile up there, and the disk has to hold them.
- `docker exec postgres-dumper dumper now` runs one now, whatever the schedule, and so does
  `docker exec clickhouse-dumper dumper now`. The archivist takes it off the host within a
  minute. The first one gives the dumper its intent, and says when its next slot is. One that
  archives nothing gives none.

**Postgres.** A run holds `globals.sql`, from `pg_dumpall --globals-only`, and
`databases/NAME.dump` for every database but `postgres`, each a `pg_dump` in custom format. The
dump is left uncompressed, because restic compresses what it stores and finds far more to
deduplicate in a dump that is not already compressed. The dumper connects as the superuser, to
`postgres-18:5432` directly. The globals file is there because a user is a **cluster** object:
it lives outside every database, so `pg_dump` does not carry it, and a database restored into a
Postgres that holds no users fails on the first `ALTER TABLE … OWNER TO`. That one file carries
the stored password verifier of every user on the server, so it is as sensitive as the data.

**ClickHouse.** A run holds `globals.tar`, from `BACKUP TABLE system.users`: every user made by
SQL, with its password hash and its grants. `default` is not among them, because it comes from
`CLICKHOUSE_PASSWORD`. The run also holds `databases/NAME.tar` for every database but
ClickHouse's own three, `system`, `information_schema` and `INFORMATION_SCHEMA`; `default` is
included. Each is a `BACKUP DATABASE … TO File(…)`: one uncompressed tar, written by ClickHouse
itself into the backup folder, which it mounts as its backup directory. The dumper hands
`clickhouse/` to uid 101, the ClickHouse image's own user, because a volume Docker creates
belongs to root. ClickHouse can write a backup to S3 by itself, and userland does not use that:
a backup to S3 deletes its own lock file when it finishes, so a key that may not delete fails
every one, and ClickHouse cannot encrypt an archive it writes to S3 at all.

**Uploading.**

- Every minute the archivist looks in the backup folder. It uploads each finished run, oldest
  first, and skips a run still `.writing`, each `last-run`, and `restore/`. With nothing
  there, it does nothing: it reads no key and sends no request.
- Each archive becomes one snapshot, tagged `postgres` or `clickhouse`, at a path such as
  `/postgres/databases/shop.dump`. It is dated when the dumper made it, not when it left the
  host.
- Each archive is deleted from the folder once it is up. An upload that fails keeps it, stops
  that pass, and is tried again the next minute.
- `docker exec archivist archivist upload` uploads now.

**The repository.** restic keeps every archive in one repository, inside the bucket. It is not
the bucket. You make it once, by hand, after you make the bucket:

```sh
docker compose run --rm archivist init
```

The archivist never makes one on its own, for two reasons. `restic init` makes a missing bucket
whenever the key allows it, and restic cannot tell a missing bucket from a missing repository.
And a repository that has vanished is an alarm, not a fresh start. So at every start the
archivist reads the master key and opens the repository, waiting up to two minutes. If there
is no repository, or the key does not open it, or the secret store or the bucket cannot be
reached, it writes nothing. It says which in `docker logs archivist` and exits, and docker
starts it again, waiting longer each time. On a new host the repository is already in the
bucket, so never run `init` there.

**What is in the bucket.** restic snapshots, and nothing you can read without the master key.
Each object is named after the hash of its own contents, so nothing is ever overwritten and
nothing is ever a file path; every upload adds snapshots, and the list of snapshots is the
history. `docker exec archivist restic snapshots` lists them, and
`--path /postgres/databases/shop.dump` lists one database's. There is no `.gpg` next to a
familiar name to grab, and equally no way to get anything back except through restic with the
key.

**The master key is the repository password**, read out of your secret store by
`scripts/archivist-key` each time restic runs, held in memory, and written nowhere: not in
`.env`, not on disk, not in the bucket, which holds it only as ciphertext that the password
unlocks. So **replacing the parameter's value does not re-key anything; it locks the archivist
out of its own repository.** Never overwrite it.

**Retention: never prune, nothing expires.** The archivist only ever adds. Every archive is a
full backup of one database, so each snapshot restores alone, but restic stores only the chunks
it has not seen before, so an archive adds roughly what changed since the last one. A large
database that did not change adds almost nothing. A small one is stored whole again whenever it
changes at all, because it is only a chunk or two, and the globals change on every run. **The
repository keeps everything, including what you delete**: a row dropped from a database, a
trace langfuse's own Data Retention removes: every earlier snapshot still holds it. `forget` and
`prune`, which are how restic reclaims space, need delete rights the key does not have, and so
do `unlock --remove-all`, `rewrite` and `tag`: if you ever want them, restic's own guidance is a
separate, well-secured machine with a delete-capable key, never this host. And **set no
lifecycle rule on this bucket**: see *Object store*.

**Versioning guards against overwrite, not loss.** Outside `locks/`, the archivist's key can put
an object but not delete one, and a put overwrites. A host that has been broken into can
therefore write garbage over any object under its own name, using the archivist's key, and
restic sends nothing that would stop it. With versioning on, the original is still there as an
older version and you put it back by hand with an identity of your own. restic itself never
changes an object, because each is named after the hash of its own bytes. It does send one
again when the answer to an upload is lost on the way back. That leaves an older version with
the same bytes, and so the same ETag, as the one on top. So **outside `locks/`, an older version
whose ETag differs from the current one means something other than restic wrote there.** One
with the same ETag is an upload sent twice. `restic check` will tell you the repository is
damaged, because an object's contents no longer match its name, but it cannot repair what it
does not have.

**Under `locks/`, older versions are restic's own, and they mean nothing.** Every restic command
writes a lock there as it starts, and deletes it as it ends. In a versioned bucket, a delete
keeps the lock as an older version, under a delete marker. So every command leaves one pair
behind, and a long one a pair more for every five minutes it runs. The archivist runs one
command per archive, so a run of ten databases leaves eleven pairs. Nothing removes them. A pair
is about 220 bytes, so the space is nothing. The time may not be: restic lists `locks/` twice in
every command, S3 steps over every delete marker there, and AWS warns that thousands of them can
make a list time out.

**If restic ever gets slow to start, remove them by hand.** Stop the archivist first. Then every
lock under `locks/` is left over, so everything there can go, even a lock that a killed command
never deleted. With the archivist running, it is not safe: a delete marker removed before its
older version brings the old lock back as a current one. Make an access key of your own for
this, with only this policy, and delete it afterwards:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["s3:ListBucketVersions"], "Resource": "arn:aws:s3:::BUCKET"},
    {"Effect": "Allow", "Action": ["s3:DeleteObjectVersion"], "Resource": "arn:aws:s3:::BUCKET/locks/*"}
  ]
}
```

Export its two variables and `AWS_DEFAULT_REGION` in your shell. This removes every version and
every delete marker under `locks/`, 500 at a time, and nothing else:

```sh
docker compose stop archivist
s3api() {
	docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
		amazon/aws-cli:2.37.4 s3api "$@"
}
while :; do
	objects=$(s3api list-object-versions --bucket BUCKET --prefix locks/ --max-keys 500 \
		--no-paginate --query '[Versions, DeleteMarkers][].{Key: Key, VersionId: VersionId}')
	[ "$objects" != "[]" ] || break
	s3api delete-objects --bucket BUCKET --delete "{\"Objects\": $objects, \"Quiet\": true}"
done
docker compose start archivist
```

**The image is this repo's own**, the only one it builds. `pull_policy: build` makes every
`docker compose up` build it, which is quick when nothing changed, and recreates the container
only when the image did. It is `restic/restic:0.19.1` plus `ssmget`, a small Go program built in
a stage of its own that reads the one parameter through Amazon's own library, and two scripts:
[`scripts/archivist`](scripts/archivist), its loop and its commands, and `scripts/archivist-key`,
its password command. restic's version is written only in the Dockerfile. The dumpers build
nothing: each runs `scripts/dumper`, mounted into its server's image.

**Each container reports on itself**, through docker's healthcheck, so `docker compose ps`
shows it. A dumper is unhealthy while it waits for its intent, when its last run failed, or when
none has finished for two intervals. `bin/up` ends by naming each dumper that is not healthy,
and why. The archivist turns unhealthy when its last upload failed, and healthy again at the
next one that succeeds. **Nobody is told**: until userland runs something that watches,
`docker compose ps`, `docker logs` and the snapshot list are the evidence.

**A database comes back by hand, with `bin/restore`, and a restore nobody has rehearsed is not
a backup.** The archivist writes the archive into `restore/` in the backup folder, the dumper
restores it from there, and the copy is removed afterwards.

```sh
bin/restore --postgres shop --as drill
bin/restore --clickhouse events --as drill
bin/restore --postgres shop
bin/restore --postgres shop --snapshot 1a2b3c4d
```

- `--postgres` or `--clickhouse` is required: one of them, always.
- `--as OTHER` restores into a new database, OTHER, and touches nothing live. This is the
  drill. On Postgres the new database belongs to the superuser, because the archive's owner
  and grants are left out. `bin/remove-database` drops it when you are done, told the same
  datastore.
- Without `--as`, the live database is dropped, made again and restored, once you type its
  name. On Postgres it comes back with its owner, its grants and its settings. On ClickHouse
  its user's grants were never dropped. Every change since the archive is lost, so stop
  whatever uses the database first.
- A database whose user is gone is refused, because a restore never makes a user and a
  database's archive holds none. Make it with `bin/add-database`, which prints a new password,
  and then restore over it.
- It takes the newest archive of that one database. `--snapshot ID` takes an older one: the
  snapshot list above shows each one's ID.

The globals go back only into a datastore being rebuilt, and `bin/restore` never puts them
back. `bin/rebuild` does, under *Bringing a host back*.

| Variable | Needed | Meaning |
|---|---|---|
| `ARCHIVIST_S3_BUCKET` | required | Name of the archivist's bucket. Versioned, with no lifecycle rule. |
| `ARCHIVIST_S3_REGION` | required | Region of the bucket, as the provider names it. |
| `ARCHIVIST_S3_ENDPOINT` | required | Scheme and host the bucket is reached at, with no path. |
| `ARCHIVIST_S3_ACCESS_KEY_ID` | required | Access key that reaches this bucket and nothing else. It may list the bucket and get and put objects, and delete under `locks/` and nowhere else. |
| `ARCHIVIST_S3_SECRET_ACCESS_KEY` | required | Its secret. |
| `ARCHIVIST_KEY_PROVIDER` | required | Secret store the master key lives in: `ssm`, AWS Parameter Store, the one there is. |
| `ARCHIVIST_KEY_NAME` | required | Name of the `SecureString` parameter that holds the master key. |
| `ARCHIVIST_KEY_REGION` | required | Region of the parameter. |
| `ARCHIVIST_KEY_ACCESS_KEY_ID` | required | Access key that may read this one parameter and nothing else. |
| `ARCHIVIST_KEY_SECRET_ACCESS_KEY` | required | Its secret. |
| `ARCHIVIST_MEM_LIMIT` | default no limit | Memory limit of `archivist`. |

## Infisical

Infisical keeps the real copy of userland's `.env`, in the project `userland`, environment `prod`.
`bin/up` writes the file from it, under *Running it*. A consumer's admin may keep the consumer's
`.env` in Infisical too, in a project of its own, with a login of its own. No helper reads it.
[ADR 0002](docs/adr/0002-secrets-outside-infisical.md) says which secrets stay outside Infisical,
and why.

Two containers, always on together. `infisical` is the server and its web UI in one, at
`infisical.${DOMAIN}`. `infisical-redis` is its own Redis, which nothing else is pointed at. It
runs `noeviction` with append-only persistence, as langfuse's and twenty's do.

**Its database holds everything that lasts.** Users, projects, machine identities, and every
secret, encrypted. It is the `infisical` database on Postgres, reached through the transaction
door. So `postgres-dumper` archives it and the archivist takes it off the host, like every other
database, and nothing else of Infisical needs keeping. Redis holds only queues and caches, which
Infisical rebuilds. The container needs no volume.

**Its master key** encrypts every secret it keeps. It lives in the secret store, and you copy it
into `.env` by hand, as `INFISICAL_ENCRYPTION_KEY`. *Secret store* says why. Lose it, and every
secret in Infisical is lost. Started with another key, Infisical says so in
`docker logs infisical` and exits.

**The first host** is set up by hand, once. Nothing here makes a secret or a database for you.

1. Make what userland never makes: the archivist's bucket and its master key, under
   *Object store* and *Secret store*, and Infisical's master key.
2. Write `.env` by hand:
   - `COMPOSE_FILE=compose.yml:compose/postgres.yml:compose/archivist.yml`, with
     `compose/public.yml` at the end and traefik's lines if the host is public;
   - `DOMAIN`, `SCHEME` and `SECURE_COOKIES`;
   - the archivist's ten lines, under *The archivist*;
   - `INFISICAL_ENCRYPTION_KEY`, copied from the secret store;
   - `POSTGRES_PASSWORD`, `PGBOUNCER_AUTH_PASSWORD`, `INFISICAL_REDIS_PASSWORD` and
     `INFISICAL_AUTH_SECRET`, each from `bin/random-secret`.
3. Make the repository, under *The archivist*, with `docker compose run --rm archivist init`.
   Then run `docker compose up -d`.
4. Run `bin/add-database --postgres infisical`, and add the `INFISICAL_DB_PASSWORD` line it
   prints to `.env`. Add `compose/infisical.yml` to `COMPOSE_FILE`, and run
   `docker compose up -d`.
5. **Make the first admin at once.** Open `infisical.${DOMAIN}` and sign up. The first account
   becomes the admin of the whole of Infisical, and Infisical then closes sign-up by itself.
   **Until you do, whoever reaches it first becomes the admin.** In public, a new hostname is
   listed in public certificate logs within minutes of its certificate.
6. Make the helper's login. Under Administration, Access Control, Machine Identities, choose
   Create. Keep the role Member. On its page, open Universal Auth and copy the Client ID, then
   Add Client Secret and copy the secret, which is shown once. Put them in `.env` as
   `INFISICAL_CLIENT_ID` and `INFISICAL_CLIENT_SECRET`.
7. Make the project `userland`. Under its Settings, General, change its slug to `userland`: the
   web UI adds random letters to it. Under its Access Control, Machine Identities, add the
   helper's login to it as Member.
8. In the project's Production environment, `prod`, choose Add New, Upload Secrets, and pick
   `.env`. Every line now has its real copy in Infisical.
9. Run `bin/up`. From now on, change a line in Infisical, and run `bin/up` again.
10. Give `postgres-dumper` its intent, under *The archivist*:
    `docker exec postgres-dumper dumper now`. Do the same for `clickhouse-dumper` whenever
    ClickHouse is switched on. `bin/up` names each dumper that still waits.
11. Copy the recovery keys off the host, under *Bringing a host back*.

Its database password, its Redis password, its auth secret and the helper's login are recovery
keys. On a new host there is no admin, login or project to make: Infisical's database comes back
with all three in it.

**Upgrading.** The tag is exact, never `latest`, and it only ever goes up. A newer image
migrates the database as it starts. An older image may refuse a database a newer one has
migrated, and an archive restores only into the tag it was taken with, or a newer one. Take a
fresh archive with `docker exec postgres-dumper dumper now`, then move the tag. The image is
large: about 3 GB.

Everything else, telemetry and email included, runs at Infisical's defaults. With no email set,
there are no invites and no password reset by email.

| Variable | Needed | Meaning |
|---|---|---|
| `INFISICAL_ENCRYPTION_KEY` | required | Infisical's master key: exactly 32 characters. Its real copy is in the secret store. Never change it. |
| `INFISICAL_DB_PASSWORD` | required | Password of the `infisical` user on Postgres, which owns the `infisical` database. A recovery key. |
| `INFISICAL_REDIS_PASSWORD` | required | Password of Infisical's own Redis. URL-safe characters only. A recovery key. |
| `INFISICAL_AUTH_SECRET` | required | Signs Infisical's logins and tokens. A new one logs everyone out, and loses nothing else. A recovery key. |
| `INFISICAL_MEM_LIMIT` | default no limit | Memory limit of `infisical`. |
| `INFISICAL_REDIS_MEM_LIMIT` | default no limit | Memory limit of `infisical-redis`. |

## Bringing a host back

When a host is lost, a new one comes back from the bucket and your recovery keys alone. Every
database comes back from the archive, with every user and its old password. userland's `.env`
comes back from Infisical, whose own database is one of those databases.

**The recovery keys.** Infisical keeps every secret but two kinds. The master keys live in the
secret store. The recovery keys are every secret the host needs before Infisical is running,
because Infisical comes back only after Postgres does. You keep them off the host, wherever you
keep secrets, with the settings that go with them. Infisical keeps a copy too, so the `.env` it
writes is whole. When you change one, change your copy as well.

| What | Lines |
|---|---|
| The archivist's bucket, and the access key that reaches it | `ARCHIVIST_S3_BUCKET`, `ARCHIVIST_S3_REGION`, `ARCHIVIST_S3_ENDPOINT`, `ARCHIVIST_S3_ACCESS_KEY_ID`, `ARCHIVIST_S3_SECRET_ACCESS_KEY` |
| The archivist's master key, and the access key that reads it | `ARCHIVIST_KEY_PROVIDER`, `ARCHIVIST_KEY_NAME`, `ARCHIVIST_KEY_REGION`, `ARCHIVIST_KEY_ACCESS_KEY_ID`, `ARCHIVIST_KEY_SECRET_ACCESS_KEY` |
| The passwords of the Postgres superuser and of `pgbouncer_auth` | `POSTGRES_PASSWORD`, `PGBOUNCER_AUTH_PASSWORD` |
| Infisical's database password, its Redis password and its auth secret | `INFISICAL_DB_PASSWORD`, `INFISICAL_REDIS_PASSWORD`, `INFISICAL_AUTH_SECRET` |
| The helper's login to Infisical | `INFISICAL_CLIENT_ID`, `INFISICAL_CLIENT_SECRET` |

Infisical's master key is not among them: it comes from the secret store. Every other password
comes back with the globals, and every other line comes from Infisical.

**The order.**

1. Clone userland, and write the first `.env`: the recovery keys, `INFISICAL_ENCRYPTION_KEY`
   copied from the secret store, and `DOMAIN`, `SCHEME` and `SECURE_COOKIES`. Nothing else:
   every other line, `COMPOSE_FILE` included, comes from Infisical. **Never run
   `archivist init` here**: the repository is already in the bucket.
2. Run `bin/up --rebuild`. It first checks that each of those lines is there, and starts nothing
   while one is missing. Then:
   1. It starts Postgres, its dumper and the archivist.
   2. It runs `bin/rebuild --postgres`, if Postgres holds no database. Every user and every
      database comes back, Infisical's included.
   3. It starts Infisical on its old database, with its admin and the helper's login already in
      it, and writes `.env` from it, as `bin/up` does.
   4. If ClickHouse is in `COMPOSE_FILE`, it starts ClickHouse and its dumper alone, and runs
      `bin/rebuild --clickhouse` if ClickHouse holds no database.
   5. It runs `docker compose up -d --remove-orphans`. Every product starts on data that is
      already back.
   6. It names each dumper that waits for its intent, as `bin/up` does.
3. **Replace the archivist's bucket key.** Make a new access key with the same policy, under
   *Object store*. Put its two lines, `ARCHIVIST_S3_ACCESS_KEY_ID` and
   `ARCHIVIST_S3_SECRET_ACCESS_KEY`, in Infisical and in your copy of the recovery keys. Run
   `bin/up`, then delete the old key. If the lost host ever comes back, it can write nothing.
   Do it after the rebuild, not in the first `.env`: `bin/up --rebuild` writes `.env` from
   Infisical, which still holds the old key.
4. **Give each dumper its intent**: `docker exec postgres-dumper dumper now`, and
   `docker exec clickhouse-dumper dumper now` if ClickHouse is on. The key comes first, so the
   two hosts are never both able to write.
5. Start each consumer. It gets its `.env` its own way.

No product starts before its data is back. Infisical waits for Postgres's rebuild, so it never
meets a Postgres without its database. A step that fails stops it, and says why. Once that is
put right, run it again: each step skips what is done, so a second run changes nothing. If
ClickHouse held no data before the loss, the bucket holds no run of it, and the rebuild says so.
Then run `bin/up`, which starts ClickHouse empty.

If the first `.env` holds a `COMPOSE_FILE`, `bin/up --rebuild` starts Postgres, the archivist
and Infisical with it. The tests use this to add their stand-in for the bucket. A real host
needs none.

**One bucket, one running host.** Only one host at a time may write into the archivist's
bucket. Every snapshot says it came from `archivist`, whatever the host, so nothing tells two
hosts' archives apart. `bin/rebuild` takes the newest run, and `bin/restore` the newest archive,
whichever host wrote it. Two hosts that start a run in the same second give it two of each
archive, and `bin/rebuild` refuses it. A second apart, nothing fails: the later run is simply the
newest, even when its data is a day old. A second host appears in two ways:

- **A drill on a throwaway.** It does steps 1 and 2, and its checks, and never 3 or 4. A new
  key would shut out the real host, and an intent would write the throwaway's runs beside the
  real host's. Its dumpers wait, unhealthy, and nothing leaves it. Throw the machine away when
  you are done.
- **A lost host that comes back**, such as a VM its provider brings back after an outage. It
  already has its intent, and docker starts it again. Its dumper runs the slot it missed at
  once, so its old data becomes the newest run. Step 3 is what stops it: with its key deleted,
  it can write nothing.

**`bin/rebuild`** puts a whole datastore back from one **run**: one pass of a dumper, named by
the time it started, as its folder in the backup folder is.

```sh
bin/rebuild --postgres
bin/rebuild --clickhouse
bin/rebuild --postgres --run 20260925T000000Z
```

- `--postgres` or `--clickhouse` is required: one of them, always.
- It takes the newest run, and says which before it starts. The globals go back first, then
  every database in that run. Every archive comes from the one run, so every database comes
  back from the same moment, even if a dumper runs meanwhile.
- **Give the intent only after the rebuild.** A dumper on a new host archives nothing until
  then. One given its intent before the rebuild archives an empty datastore, and that run
  becomes the newest. So `bin/rebuild` refuses a newest run with no database in it, and lists
  the runs there are. `--run` names the one to take, and this lists every archive with its
  run: `docker exec archivist archivist runs postgres`.
- **It refuses a run that holds one archive twice**, the newest or one named with `--run`, and
  changes nothing. Two hosts wrote into the bucket in the same second, and it cannot tell whose
  archive is whose. Name another run with `--run`. *One bucket, one running host*, above, says
  how it happens.
- It refuses a datastore that is not empty, and changes nothing. Empty on Postgres is no
  database and no user but its own. On ClickHouse it is no database but its own, no table in
  `default`, and no user but `default`. So a rebuild can never reset the users of a live
  datastore. `bin/restore` brings one database back.
- The globals come back whole: every user with its old password, and on ClickHouse with its
  grants. ClickHouse's `default` is not among them, because it comes from `CLICKHOUSE_PASSWORD`
  at every start.
- Postgres makes its superuser and `pgbouncer_auth` at its first start, from `.env`. The
  globals then give them the passwords in the archive, so both lines must be the recovery keys.
  If either is not, the rebuild stops right after the globals, before any database, and says
  so.
- A rebuild that fails part way says how to start again on an empty datastore:
  `docker compose down`, then `docker volume rm` of the datastore's volume,
  `userland_postgres_data` or `userland_clickhouse_data`.

## For a consumer

A **consumer** is a project of your own that uses userland and is not part of it.

- **Its `.env` is its own.** Its admin may keep it in Infisical, in a project of its own, with a
  login of its own, both made in the web UI. No helper reads or writes it, and `bin/up` never
  starts a consumer.

- **Two networks**, `userland_postgres` and `userland_traefik`, which the consumer's compose
  file declares as `external: true` and joins. A consumer with a database on ClickHouse joins
  `userland_clickhouse` the same way.
- **Two doors to Postgres**, `pgbouncer-transaction:5432` and `pgbouncer-session:5432`, and
  the DSN names one. `pgbouncer-transaction` is the default, for a consumer that keeps no state
  on a connection between transactions. `pgbouncer-session` is for one that does, whether a
  `SET`, a `LISTEN`, a session-scoped advisory lock or a prepared statement it reuses; it pins
  one Postgres connection for as long as the consumer holds its own, so the consumer must
  release connections promptly. The session door lends up to 100 connections per database,
  Postgres's own limit, so there Postgres decides and not the door; the transaction door lends
  pgbouncer's 20. `postgres-18` itself is not on `userland_postgres`, so the doors are the only
  way in.
- **traefik** routes a consumer by the labels on its container. `NAME` and `PORT` are the
  consumer's own, and `DOMAIN` is `localhost` in local. The same four labels serve both
  visibilities. In public, the certificate comes by itself and plain HTTP is redirected,
  because TLS sits on traefik's entrypoint:

  ```yaml
  labels:
    - traefik.enable=true
    - traefik.http.routers.NAME.rule=Host(`NAME.DOMAIN`)
    - traefik.http.services.NAME.loadbalancer.server.port=PORT
    - traefik.docker.network=userland_traefik
  ```

### A consumer's database

A consumer's database is made, given a new password and dropped with the helpers under
*Provisioning*, the same way as a product's. The DSN goes to the consumer's admin, for the
consumer's own `.env`.

No Redis is offered to a consumer. A product that needs Redis runs its own, and so does a
consumer.

## Tests

The tests are [bats](https://github.com/bats-core/bats-core) files. They are split in two runs:

- **The quick check** is the files in `test/`: `compose.bats`, `postgres.bats`,
  `clickhouse.bats` and `random-secret.bats`. It takes about three minutes. It runs on every
  pull request and every push to `main`, with ShellCheck.
- **The end-to-end run** is the files in `test/e2e/`: `archivist.bats`, `dumper.bats`,
  `restore.bats`, `rebuild.bats`, `infisical.bats` and `up.bats`. It takes about half an hour. It runs nightly
  on `main`, and by hand. A pull request never waits for it.

`test/compose.bats` reads what compose makes of the files, `docker compose config`, and
asserts:

- traefik runs alone, and each product runs with only the products it needs;
- a product without one it needs is refused;
- every product runs together, in local and in public;
- `DOMAIN`, `SCHEME` and `SECURE_COOKIES` are required, and so are `CERT_EMAIL` and
  `DNS_PROVIDER` in public;
- Infisical's address and its secure cookies follow the visibility;
- no port is published but traefik's 80, and its 443 in public;
- every container another waits on has a healthcheck;
- consumers join `userland_postgres` and `userland_traefik`, and `postgres-18` is on neither;
- every container is named as its service, and takes its memory limit from its own variable;
- this README names every variable compose reports;
- every file in `compose/` is a product the tests know, or `public.yml`.

`test/postgres.bats` starts the real `postgres-18` and both doors, under the compose project
`userland-test`, and runs the helpers against them. It asserts:

- the doors look passwords up as `pgbouncer_auth`, which is no superuser and inherits nothing;
- a database added is reached with the printed DSN, through the door it names, as its own user;
- the printed `NAME_DB_PASSWORD` logs in as the user, for a product's database as for any other,
  and the helper says it goes in Infisical, or in `.env` on a host without Infisical;
- a database's user reaches no other database, and `vector` is installed;
- `--api` installs the recipe, and PostgREST's DSN names the session door;
- adding a name twice, or a name with roles left behind, is refused and changes nothing;
- a bad name is refused: empty, with a hyphen or a capital, a leading digit, too long, a quote;
- remove drops nothing unless the name is typed;
- remove drops the database while both doors hold it, its user and both roles, says to delete a
  product's line, and the name can be added again;
- a new password logs in through the door, and the old one no longer does, for a database's user
  and for PostgREST's authenticator;
- after `bin/new-password --postgres pgbouncer_auth` and an `up` with the printed line, both
  doors let users in, and the line is named a recovery key;
- new-password refuses the superuser, a user without its database, an anon role and a bad name;
- each helper names its datastore, one of the two, and without one, or with both, changes
  nothing;
- a run of `postgres-dumper` archives the globals and every database, and a database added
  later is archived without being named;
- a run keeps its temporary name until every database is archived;
- a run missed while the dumper was down is caught up after a restart, and only once.

`test/clickhouse.bats` starts the real `clickhouse` the same way, and asserts:

- a database added logs in with the printed DSN, its password line is for Infisical or `.env`,
  and its user creates, writes, updates and reads a table, and reads the `system` tables langfuse
  reads;
- that user reads no other database, and makes no database and no user;
- a name twice, a user left behind, `--session`, `--api` and a bad name are refused, and change
  nothing;
- remove drops nothing without `--clickhouse`, or unless the name is typed, then drops the
  database and its user, says to delete a product's line, and the name can be added again;
- a new password logs in, and the old one no longer does; `default` is refused;
- a run of `clickhouse-dumper` archives the users and every database, and a database added
  later is archived without being named.

`test/random-secret.bats` runs `bin/random-secret` alone, and asserts:

- a secret is 64 hex characters unless told, and exactly as long as told, odd lengths included;
- a length that is not a whole number is refused, and nothing is printed.

`test/e2e/archivist.bats` starts the archivist, with [moto](https://github.com/getmoto/moto)
standing in for both the bucket and the secret store, and puts run folders into the backup
folder by hand, as a dumper would. It asserts:

- with no repository, the archivist refuses to start and writes nothing, and after `init` by
  hand it starts;
- a foreign key is refused at start, and nothing is written;
- an archive becomes a snapshot dated when the dumper made it, and leaves the folder, while a
  run still writing and `last-run` stay;
- an archive whose upload fails stays in the folder, and the archivist is unhealthy until an
  upload succeeds.

`test/e2e/dumper.bats` starts Postgres and its dumper, with a stand-in for `date` that puts the
dumper's clock ahead by as many seconds as the test says. When a suspended host wakes, its clock
jumps ahead in the same way, and `sleep` does not notice. It asserts:

- on its first start, a dumper archives nothing, and is unhealthy until it has its intent;
- the first `dumper now` gives the intent: it archives at once, and the dumper is healthy;
- with the clock an hour short of a slot, nothing runs;
- after the clock jumps past the slot, the slot runs within a minute;
- the slot runs only once.

`test/e2e/restore.bats` starts Postgres, ClickHouse, both dumpers and the archivist, with moto,
and asserts, on Postgres and on ClickHouse:

- restore names its datastore, one of the two, and refuses a bad name;
- a database comes back under another name, and nothing live is touched;
- a database is replaced by its archive only once its name is typed, and its user still
  reaches it;
- an older archive is picked by its snapshot;
- a database whose user is gone is refused, and nothing is changed.

`test/e2e/rebuild.bats` starts the same containers. It stands in for a new host by removing a
datastore's volume and starting it again, empty, while the bucket stays. It asserts:

- rebuild names its datastore, one of the two;
- on a new host, Postgres comes back whole: every database with its rows, and every user with
  its old password, through the door;
- on a new host, ClickHouse comes back whole: every user with its password and grants, and every
  database, `default`'s tables included;
- a Postgres or a ClickHouse that is not empty is refused, and nothing is changed;
- the newest run is taken, a newest run with no database is refused, and `--run` takes an older
  one;
- a password in `.env` that is not the archive's stops the rebuild right after the globals, and
  says so;
- a run two hosts wrote in the same second is refused, newest or named, and nothing is changed.

`test/e2e/infisical.bats` starts Postgres, the transaction door, traefik and Infisical, on a
database made by `bin/add-database --postgres infisical`, and asserts:

- Infisical comes up healthy, and traefik answers for `infisical.localhost`;
- `bootstrap`, from Infisical's CLI image, makes the first admin without a browser, and sign-up
  is then closed;
- a machine identity logs in with its client ID and secret, and reads a secret the admin wrote.

`test/e2e/up.bats` sets up a first host, with moto for the bucket and the secret store: Postgres,
the archivist and Infisical, with the first admin, the helper's login and the project `userland`
made through Infisical's API, where you would use the browser. Its `.env` is a file of the
test's own, named by `COMPOSE_ENV_FILES`. It asserts:

- it runs from the root of userland, on one `.env`, and says what to do without one;
- an empty project stops `bin/up`, and nothing is changed;
- it writes `.env` from userland's project, readable only by you, and starts what its
  `COMPOSE_FILE` names;
- it ends by naming each dumper that waits for its intent;
- any value reaches a container unchanged: `$`, `"`, `\`, `#`, `'`, `${...}` and a newline;
- a second run changes nothing: the same file, and no container recreated;
- a `COMPOSE_FILE` without Postgres, the archivist or Infisical is refused, and nothing is
  changed;
- a wrong client secret stops it, and nothing is changed;
- on a new host, an empty Postgres is refused, and `--rebuild` is named;
- `--rebuild` refuses a first `.env` without a recovery key, and starts nothing;
- `--rebuild` brings a new host back from the first `.env` alone: a row on Postgres, a table on
  ClickHouse, and every line in Infisical, while each dumper waits for its intent;
- a second `--rebuild` changes nothing.

Their container names are the real ones, so they cannot run on a host where userland is up.
There their first `up` fails, and the running userland is not touched.

They run from docker, as CI runs them. The repo is mounted at its own path, because a test that
starts a container hands bind-mount paths to the host's docker. The quick check:

```sh
docker run --rm --volume /var/run/docker.sock:/var/run/docker.sock --volume "$PWD":"$PWD" --workdir "$PWD" docker:29-cli sh -c 'apk add --quiet --no-cache bats jq && bats test'
```

`bats test` does not look in `test/e2e/`. The end-to-end run names it:

```sh
docker run --rm --volume /var/run/docker.sock:/var/run/docker.sock --volume "$PWD":"$PWD" --workdir "$PWD" docker:29-cli sh -c 'apk add --quiet --no-cache bats jq && bats test/e2e'
```

A change needs only the files that cover it. Name them in place of the folder, as in
`bats test/postgres.bats test/e2e/restore.bats`.

ShellCheck reads every script and test, in both folders, from docker too:

```sh
docker run --rm --volume "$PWD":/mnt --workdir /mnt koalaman/shellcheck:stable scripts/* bin/* initdb/*.sh test/*.bats test/e2e/*.bats test/e2e/stand-in/*
```

In CI, ShellCheck and the quick check run on every pull request and every push to `main`
([`.github/workflows/check.yml`](.github/workflows/check.yml)). The end-to-end run runs
nightly on `main`, and by hand from the repo's Actions tab, or with `gh workflow run e2e`
([`.github/workflows/e2e.yml`](.github/workflows/e2e.yml)).

## Layout

| Path | What lives there |
|---|---|
| `compose.yml` | traefik, always on, and always first in `COMPOSE_FILE`. |
| `compose/` | One file per product, and `public.yml`, which turns traefik public. |
| `test/` | The bats tests of the quick check. `test/e2e/` holds the end-to-end run's, and `test/e2e/stand-in/` what they put in place of a real program. |
| `scripts/` | Shell that runs inside a container: the archivist's loop and commands, its password command, and the dumper both datastores run. Nothing here runs on the host. |
| `bin/` | Helpers that run on the host, in POSIX sh, needing only docker: `up`, `add-database`, `new-password`, `remove-database`, `restore`, `rebuild` and `random-secret`. |
| `Dockerfile` | The archivist's image, the only one this repo builds: restic, and a reader for the secret store. |
| `ssmget/` | That reader, a small Go module of its own. |
| `initdb/` | First-start initialisation for Postgres. Runs once, against an empty volume, and never again. `door-auth.sh` makes the doors' auth user. |
| `config/` | Configuration, checked in because it holds nothing secret: pgadmin's one server, and `env.tmpl`, the template `bin/up` writes `.env` with. |
| `docs/adr/` | Decisions that are hard to reverse, and why they were made. |

`.env` is yours and untracked. Support directories are grouped **by kind, at the root**:
`scripts/`, never `metabase/scripts/`.

## Adding a product

A product is one file, `compose/<product>.yml`. In it, every container:

- sets `container_name` to its service's name, and `restart: unless-stopped`;
- waits in `depends_on`, with `condition: service_healthy`, for every container it needs,
  even one in another product. Compose then refuses the product without that one;
- joins only the networks it talks on. A product gets a network of its own only when its
  containers talk to each other. An HTTP container joins `traefik` and carries the four labels
  under *For a consumer*, with `${DOMAIN:?}` in its rule;
- publishes no port;
- sets `mem_limit: ${<CONTAINER>_MEM_LIMIT:-0}`;
- reads a variable with no safe default as `${VAR:?}`, so compose refuses without it, and one
  with a default as `${VAR:-value}`;
- has a healthcheck, if anything waits for it. Postgres's must probe over TCP: over the socket
  it is green while the image's temporary first-start server is up.

Settings two containers of one product share go in a YAML anchor at the top of the file, as
the doors, langfuse and twenty do. Every network and named volume a container uses is declared
at the bottom of the file. Declaring one in two files is fine: compose merges them.

A product with a database reads its password as `<PRODUCT>_DB_PASSWORD`, or
`<PRODUCT>_CLICKHOUSE_PASSWORD` on ClickHouse, because those are the lines `bin/add-database`
prints. Give it a row in the table under *Provisioning*.

A new datastore gets a dumper of its own, as Postgres and ClickHouse do: a container on the
server's image that runs `scripts/dumper` and mounts `backups`. `scripts/dumper` then needs that
datastore's own way to list its databases, archive one, and restore one.

Then add the product to `products` in `test/compose.bats`, give it a test that it runs with
what it needs, and give it a section here with a table of its variables. The tests fail until
the table names every one.

## Notes

- **Every concrete value stays out of git.** Your domain, your cloud account, your bucket
  name and your host address all live in `.env`, which is gitignored, so this repo can be
  published without redaction. Never write a real domain, bucket name, host address, email
  or account identifier into a tracked file.
- **That one `.env` holds every secret of every product you switched on.** Confirm
  `.gitignore` excludes it before your first commit. On a host you keep, its real copy is in
  Infisical, whose database the archivist takes off the host, and the recovery keys are with
  you. Some of what it holds, the encryption keys a product writes data with, cannot be
  regenerated, and losing them loses the data. A `.env` written by hand, to try userland out,
  has no copy anywhere.
- **Postgres and the doors run at their images' defaults.** No pool size, connection
  ceiling or memory setting is written anywhere in this repo, beyond the two doors'
  client ceiling and the session door's pool, which is Postgres's own connection limit so
  that the door is never the tighter one. At pgbouncer's 20, Twenty alone filled the
  session door within a minute of starting, and its requests waited in line until Twenty
  gave up on them. Measure first; a number guessed in advance is worse than none. n8n's
  five-minute query limit is n8n's own default, moved onto its Postgres user because the
  door discards it where n8n sets it; it is not a number of ours.

See [CONTEXT.md](CONTEXT.md) for the language this repo uses.
