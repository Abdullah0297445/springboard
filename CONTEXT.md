# userland

One host, one compose project, and products you switch on and off. This file is the
glossary. It holds no implementation detail.

## Language

**userland**:
This repo, and everything it runs on one host as one compose project. The word covers both
what you clone and what ends up running.
_Avoid_: platform, stack, engine, system, installation

**Product**:
What you switch on: a set of containers that are always on together, such as langfuse's web,
worker and Redis. One product is one compose file. pgadmin is a product of its own, so
Postgres without pgadmin is a valid choice.
_Avoid_: stack, bundle, service, module, app

**Container**:
One compose service. Every container belongs to exactly one product, and is switched on and
off with it, never alone.
_Avoid_: service, unit, component, module, profile

**Selection**:
The set of products switched on.
_Avoid_: enabled set, profile set, configuration

**Datastore**:
A container that stores structured data, such as Postgres, Redis or ClickHouse.
_Avoid_: store, database (for the whole thing), engine

**Object store**:
An S3-compatible store for objects. userland points at one and never runs one, so it is
always an external dependency.
_Avoid_: file store, blob store, bucket (for the store), S3 (as the category), datastore

**Dependency**:
Something a product needs in order to run. Every dependency has a severity, required or
optional, and a type, internal or external.
_Avoid_: prerequisite, link, requirement

**Required**:
A dependency without which the product cannot run. A selection missing one is refused.
_Avoid_: must-have, hard, mandatory

**Optional**:
A dependency without which the product runs, but degraded.
_Avoid_: soft, nice-to-have, recommended

**Internal**:
The type of a dependency on another product.
_Avoid_: local, built-in, bundled

**External**:
The type of a dependency on something userland never runs, such as an object store. You
make it; userland is only told where it is and given the access key that reaches it.
_Avoid_: bring-your-own, third-party, remote, cloud

**Blocked by**:
A required dependency, read from the product that has it. langfuse is blocked by postgres.
_Avoid_: depends on, downstream of

**Blocking**:
A required dependency, read from the product that is depended on. postgres is blocking
langfuse, and cannot be switched off while it is.
_Avoid_: dependents, upstream of, parent

**Visibility**:
Whether userland answers to names only this machine resolves, or to real hostnames on the
internet. It is **local** (`*.localhost`, no domain, no certificate; reachable by anyone on a
network it shares who sends the name) or **public** (real hostnames, TLS), chosen once for the
whole of userland and never per product.
_Avoid_: mode, environment, stage, dev/prod, exposure

**Consumer**:
A project of your own that uses userland and is not part of it. It may have a database on
Postgres or ClickHouse, and it may sit behind traefik; userland never runs it. Its `.env` is its
own admin's: it may live in Infisical, in a project of its own, but no helper reads or writes it.
_Avoid_: tenant, client, app, application

**Provisioning**:
Making the user, the database and any role a product or a consumer needs, before it first
runs. It is done once, by hand, with a helper, and the same way for both. Nothing changes a
database or its user on its own afterwards: a new password is given by hand too.
_Avoid_: seeding, bootstrapping, init, setup, migration, converging

**Helper**:
A small POSIX sh script you run on the host, to do what compose can't. It needs only docker. It
is generic: it never makes what one product needs, nor runs a step that is one product's.
_Avoid_: tool, CLI, command, wrapper

**Infisical**:
The product that keeps the real copy of userland's `.env`, and of any consumer's whose admin
keeps it there, each in a project of its own. It runs on the host, keeps what it holds in a database of its own on Postgres, and encrypts it under
its master key. It is not the secret store.
_Avoid_: secret store, vault, secret manager

**Access key**:
A key pair that reaches one bucket, or one master key, and nothing else. Two buckets
means two access keys, never shared. The archivist's bucket and its master key are
reached by two.
_Avoid_: identity, IAM user, credentials, service account, token

**Recovery keys**:
Every secret the host needs before Infisical is running, other than the master keys: the
access keys to the archivist's bucket and to its master key, the helper's login to Infisical,
and the passwords Postgres and Infisical start with. A new host is handed them, because nothing on it can give them back. You
keep them off the host, userland never says where, and Infisical keeps a copy. Every other
secret comes only from Infisical.
_Avoid_: seed, bootstrap secrets, break-glass keys

## Postgres and ClickHouse

**Database**:
One database on Postgres or ClickHouse, made by provisioning for one product or one
consumer, and owned by a user of the same name. Every container that
connects as that user shares it. A database that serves customers of its own is still one
database. Nothing on Redis is a database in this sense: a product that needs Redis runs its
own, inside the product, and nothing else is ever pointed at it.
_Avoid_: tenant, schema (for the whole thing), account, workspace

**User**:
The one login a database is reached through. It carries the database's name, owns it, and
reaches no other database. Postgres calls a user that can log in a role; here it is a user.
_Avoid_: tenant, role (for this), account, owner (as its name)

**Role**:
A Postgres role that cannot log in, held by a user or by another role. It belongs to the whole
of Postgres, not to one database. A product that needs one has it made by provisioning, as its
database is. PostgREST's anon role is one.
_Avoid_: group, group role, user (for this)

**Superuser**:
The single Postgres superuser that provisions databases and that the dumper archives them
as. No other user holds it. On ClickHouse the same seat is the user `default`, which
provisioning and the dumper use.
_Avoid_: engine superuser, admin, root, postgres user

**Door**:
The container a connection to Postgres goes through. There are two, they differ only in how
long a connection may be held, and the DSN names one. A container is blocked by the door
its DSN names. pgadmin is not a door.
_Avoid_: pooler, pgbouncer (as the concept), endpoint, entrypoint

**Transaction door**:
The door for a container that keeps no state on the connection between transactions. It is
the default, and it lets many client connections share few Postgres connections.

**Session door**:
The door for a container that keeps state on the connection. It holds one Postgres
connection for as long as the container holds its own, so a container on this door must
release promptly.

**DSN**:
The connection string userland hands a consumer, or writes for a container. On Postgres,
it names a door.
_Avoid_: connection URL, database URL, credentials

**Archive**:
The backup of one database. One archive restores one database alone.
_Avoid_: dump, backup file, snapshot, copy

**Retention**:
How long objects stay in their bucket. A rule at your provider sets it, never userland,
which deletes nothing it has written. The archivist's bucket may carry no rule at all, so its
archives stay until someone removes them with restic, from a machine whose key may delete.
_Avoid_: expiry, lifecycle (for the concept), cleanup, pruning

**Globals**:
What a datastore holds outside every database: its users and their passwords, its roles
and who holds each, and on ClickHouse the users' grants too. One archive holds them for the
whole datastore. It is as sensitive as the data, and it goes only into a datastore being
rebuilt.
_Avoid_: users, roles file, cluster objects

**Drill**:
A rehearsal of a recovery, against a throwaway, to prove that the recovery works. A backup
that no drill has restored is not a backup. A throwaway never gets the intent, so it reads the
bucket and never writes to it.
_Avoid_: test, dry run

### Roles inside a database, for PostgREST

These exist only in a database that wants a REST API. PostgREST is not a userland
container; it runs in the consumer's own repo.

**Authenticator**:
The only role a PostgREST process logs in as. It holds no table rights and inherits none,
so it can do nothing until it takes another role.
_Avoid_: service account, api user

**Anon role**:
The role a PostgREST request takes when it carries no valid token. It cannot log in
directly.
_Avoid_: public role, guest

## The archivist

**Archivist**:
The product that takes every archive in the backup folder off this host, into a bucket of its
own, where only its master key opens it. It knows no datastore and no database, and nothing
it does depends on a dumper.
_Avoid_: fort, backup service, backup container

**Dumper**:
The container in a datastore product that archives each of its databases into the backup
folder, on a schedule of its own, and writes an archive back on a restore. It finds every
database by itself, so none is ever named. What it writes is an archive, never a dump. It
archives nothing until it has its intent.
_Avoid_: backup container, exporter, backup job

**Intent**:
An admin's word, given by hand to one dumper, that this host is the one that writes to the
bucket. It is the dumper's first run by hand, and from then on its slots run. Until then the
dumper archives nothing. It stays on the host, and no helper ever gives it.
_Avoid_: enable, activate, arm, claim

**Backup folder**:
The one place on the host where every dumper leaves its archives, each datastore in a folder
of its own, until the archivist has taken them off the host. An archive still in it is not
yet safe.
_Avoid_: staging area, spool, backups (for the concept)

**Master key**:
One of the two secrets that live in the secret store. The archivist's encrypts every archive
it keeps; the archivist reads it at each run, so it never touches the host. Infisical's encrypts
every secret Infisical keeps; you copy it onto the host by hand, because Infisical reads it only
as it starts. Lose one and all it encrypts is waste.
_Avoid_: passphrase, backup key, encryption key, secret

**Repository**:
What restic keeps inside the archivist's bucket: every archive, encrypted under the
archivist's master key. It is not the bucket. It is made once, by hand, after the bucket, and
never by the archivist on its own, so a repository that is missing is an alarm and not a fresh
start. One running host writes into it at a time. A second one's runs mix with the first's, and
nothing tells them apart.
_Avoid_: bucket (for this), repo, store, vault

**Secret store**:
A service you own, outside the host, that holds the two master keys and nothing else.
userland reads the archivist's and never writes it; Infisical's you copy by hand. An external dependency. Infisical is not one: it runs
on the host.
_Avoid_: vault, parameter store (as the category), key store, KMS

**Restore**:
Writing an archive back into the datastore it came from: into a new database of another
name, which touches nothing live, or over the database it came from, which it replaces
whole. It never makes a user, so the second needs the database's user to still exist.
Deliberate, by hand, never on a schedule.
_Avoid_: recover, pull, sync

**Run**:
One pass of a dumper over its datastore: the globals and every database, archived together
and named by the time the pass started.
_Avoid_: backup, snapshot, job, dump

**Slot**:
One of the times a dumper is due to run: every so many hours, counted from 00:00 UTC. A slot
missed while the dumper was down, or its host suspended, runs once, as soon as it can.
_Avoid_: tick, cron time, window

**Rebuild**:
Putting a whole datastore back on a new host from one run: its globals first, then every
database. It fills only an empty datastore, so it can never reset the users of a live one.
Deliberate, by hand, and only on a new host.
_Avoid_: restore (for this), recover, reseed, reset
