# springboard runs on docker compose alone

springboard used to be a Go CLI. It asked questions, kept a manifest of what every container
depends on, and rendered one `compose.yml` from templates. It is now plain compose files, one
per product, and `COMPOSE_FILE` in `.env` picks them. Compose already does what the CLI did
for itself: a file that is not listed is not read, a dependency on a product that is not
listed is refused, `${VAR:?}` refuses a missing variable, and dropping a file then running
`up --remove-orphans` removes its containers and keeps their volumes. What compose can't do is
either given up or left to a small POSIX sh helper. The host needs only docker.

## Considered options

- **Profiles, to pick containers.** Rejected. A container whose profile is dropped keeps
  running after `up --remove-orphans`, and `down` misses it. A `${VAR:?}` in a container
  whose profile is off still breaks every command, `down` included.
- **One file per container.** Rejected for one file per product. A Redis or a worker is
  useless without the product it serves, and one file lets a product share its settings
  through a YAML anchor. Where a container really should be optional, as pgadmin is next to
  Postgres, it is a product of its own.
- **Local and public as two sets of files.** Rejected. Only traefik differs in shape, so
  `compose/public.yml` changes traefik alone. Every other product differs only by value:
  `DOMAIN`, `SCHEME` and `SECURE_COOKIES`, which are required so a public host cannot quietly
  serve `http` links.

## Consequences

- There is no interview, no apply, no printed Contract, and no offer to make external
  dependencies. `.env` is written by hand, or by a helper.
- Nothing publishes a port but traefik. A consumer joins a network or comes through traefik.
- The tests read `docker compose config`, so they hold compose's view of the files, not a
  copy of it.
