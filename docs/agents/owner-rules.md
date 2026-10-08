# Owner rules

## Designing a helper

- Name a helper that serves one datastore after it, as `bin/add-pg-role` does, and give it no datastore flag. The helpers that serve both keep `--postgres` and `--clickhouse`. Why: on a one-datastore helper the flag could only ever take one value.
- Put a product's own steps, such as its roles or an extra secret, in that product's README section, as hand steps that run the generic helpers. Windmill's section is the model. A helper knows only springboard's own parts: Postgres, ClickHouse, the archivist and Infisical. Why: a helper that serves one product's needs grows into a DSL.

## Connecting to Postgres

- Leave every pool size, connection ceiling and idle timeout in a product's compose file at upstream's default, `PG_POOL_*`, `DEFAULT_POOL_SIZE` and `MAX_CLIENT_CONN` included. README *Notes* names the doors' numbers, the only ones, and says why.
- When a product's connections queue at a door at the product's own defaults, raise the door's size to a number upstream owns. The session door's pool is Postgres's own `max_connections` for this reason. Why: a cap on the product is a guessed number, and a way around the door is a second way into Postgres.
- Besides the doors, only the dumper and pgadmin connect to `postgres-18` (README *Postgres*). To ask the owner for another exception, bring a breakage you measured through the door, as pgadmin's stop button was. Why: each exception was granted for a breakage the owner saw, never for a reason on paper.

## Choosing tests to run

- Name in the PR the bats files you ran. README *Tests* says what each file covers. Why: the end-to-end run is left to the nightly job, so the PR is the record of what was checked.

## Checking S3 or an AWS key

Pick the tool by the question.

- **What a real key, policy or bucket allows: real AWS.** Use the host's own `aws` CLI, in the account it is already set up for. Why: moto only approximates IAM, so it can say yes where AWS says no.
  - Give every throwaway bucket, AWS user, policy and access key a name that reads as a test. Delete them all when the check ends, and say so in the issue's resolution.
  - When the CLI's session has expired, ask the owner to run `! aws login`. Only the owner can.
  - A container that needs real access gets a throwaway user's access key, made with the host CLI. Auto mode refuses to export the owner's own session.
- **Everything else: moto.** Every bats test, and any local check of S3 behaviour moto models (versioning, `list-object-versions`, `delete-objects`, restic), runs against `motoserver/moto`, as `test/e2e/archivist.bats` does. Why: the tests and CI hold no AWS account, and MinIO's image no longer pulls.
  - moto ignores `Quiet` on `delete-objects`, and refuses very short bucket names.

## Writing commits, PRs and issues

- Use placeholders such as `BUCKET`, `DOMAIN` and `ACCOUNT` for every real value: the owner's account id, region, buckets, domain, hosts, email and company. README *Notes* asks the same of tracked files. Why: the repo is public, and written for a stranger.
