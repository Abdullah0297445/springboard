# Only the master keys and the recovery keys live outside Infisical

userland's `.env` has its real copy in Infisical. `bin/up` writes the file from it just before
`docker compose up`, and nobody edits the file by hand. A consumer's `.env` is its own admin's,
who may keep it in Infisical too, in a project of its own; no helper reads it. Two kinds of
secret also live outside Infisical, and nothing else does:

- **The two master keys**, the archivist's and Infisical's, live in the secret store. Each one
  unlocks everything else: the archive, and every secret in Infisical. The archivist reads its
  own at each run, with an access key of its own, so it never touches the host. Infisical's is
  copied into `.env` by hand, because Infisical reads it only as a setting when it starts.
- **The recovery keys** live with you, off the host. They are every secret the host needs
  before Infisical is running: the access keys to the bucket and to the archivist's master
  key, the passwords Postgres and Infisical start with, and the helper's login to Infisical. Infisical
  keeps a copy too, so the file it writes is whole.

The line sits there because of a loop. Infisical keeps its data in Postgres, and on a new host
that data comes back only from the archive. So nothing Infisical holds can help bring back the
archivist, Postgres, or Infisical itself. Each of those takes its secrets from below: the
recovery keys and the master keys. With those, a new host comes back in a straight line.
Postgres starts with its old passwords, the globals bring every other user back with its own,
Infisical starts on its old database, and every other line comes from it. Nothing is made up
fresh, skipped or replaced.

The file is written from a template of ours, in Infisical's own template language. It writes
`KEY="value"` and escapes what compose would misread, so any value comes through unchanged. It
refuses to write an empty file.

## Considered options

- **The file as the real copy, pushed into Infisical.** Rejected. A push never deletes, so a
  line removed from the file stays in Infisical. A change nobody pushed is lost with the host.
- **A helper writing the lines it makes into Infisical itself.** Rejected. It would keep a
  password off the screen, and a missed paste could not lose it. But Infisical's web UI stays
  the one place a line is changed, and the helpers that make a line know nothing of Infisical.
  A missed paste costs one new password.
- **The Infisical Agent, writing every `.env` on a timer.** Rejected. A new `.env` does nothing
  until `up`, so the file and the running containers would differ until someone happened to
  run it. It also needs every consumer's folder mounted into its container.
- **Fresh passwords for Postgres's own users on a new host.** Rejected. The dumper and the
  doors need the superuser's and `pgbouncer_auth`'s passwords before Infisical is back. Making
  them fresh means the globals must skip those two users, and the new values must then replace
  the old ones in Infisical. That patches the loop instead of removing it.
- **A Postgres of Infisical's own.** Rejected. It removes the loop too, but costs a second
  Postgres and a third dumper, and breaks one Postgres for the whole host.
- **Infisical reading its master key from the secret store as it starts, through an image of
  our own.** Rejected. It costs a second image to build, and the key would still end up on the
  host, in Infisical's memory. Every `.env` is written onto the host in plain text anyway, so the
  key in `.env` gives a thief of the host nothing more, and no `.env` is ever archived. So
  Infisical has no access key of its own.
- **The helper's login in the secret store.** Rejected. The secret store would then hold more
  than master keys.

## Consequences

- You keep the recovery keys off the host, wherever you keep secrets. userland never says
  where. When you change one, you change your copy too.
- A new host needs only docker, this repo, the recovery keys, and Infisical's master key copied
  from the secret store.
- `bin/rebuild` puts back each datastore whole on a new host, globals included, from one run.
  It fills only an empty datastore, so it can never reset the users of a live one.
- A line a helper makes, such as a database's password, is printed once, and you put it in
  Infisical's web UI. No helper writes into Infisical; `bin/up` only reads from it.
