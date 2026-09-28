bats_require_minimum_version 1.5.0

setup_file() {
	export project=userland-test
	export env_file="$BATS_FILE_TMPDIR/env"
	cat >"$env_file" <<'EOF'
POSTGRES_PASSWORD=postgres-password
PGBOUNCER_AUTH_PASSWORD=pgbouncer-auth-password
EOF
	compose down --volumes --remove-orphans
	compose up --detach --wait postgres-18 pgbouncer-transaction pgbouncer-session postgres-dumper
}

teardown_file() {
	compose down --volumes --remove-orphans
}

compose() {
	COMPOSE_FILE=compose.yml:compose/postgres.yml docker compose --project-name "$project" --env-file "$env_file" "$@"
}

connect() {
	docker run --rm --network "${project}_postgres" pgvector/pgvector:pg18-trixie \
		psql "$1" -v ON_ERROR_STOP=1 -X -q -tA -c "$2"
}

superuser() {
	docker exec postgres-18 psql -v ON_ERROR_STOP=1 -X -q -tA -U postgres -d postgres -c "$1"
}

printed() {
	sed -n "s/^  $1=//p" <<<"$output"
}

in_dumper() {
	docker exec postgres-dumper "$@"
}

runs() {
	in_dumper ls /backups/postgres | grep -x '[0-9]\{8\}T[0-9]\{6\}Z' || true
}

newest_run() {
	runs | tail -n 1
}

@test "the doors look passwords up as pgbouncer_auth, which is no superuser and inherits nothing" {
	run superuser "SELECT rolsuper, rolinherit FROM pg_roles WHERE rolname = 'pgbouncer_auth'"
	[ "$output" = "f|f" ]
	run superuser "SELECT prosecdef FROM pg_proc WHERE proname = 'pgbouncer_get_auth'"
	[ "$output" = "t" ]
}

@test "a database added is reached through the transaction door, as the user that owns it" {
	run --separate-stderr bin/add-database --postgres shop
	[ "$status" -eq 0 ]
	url=$(printed DATABASE_URL)
	[[ "$url" == postgresql://shop:*@pgbouncer-transaction:5432/shop ]]
	[ -z "$(printed PGRST_DB_URI)" ]
	run connect "$url" "SELECT current_user || ' ' || current_database()"
	[ "$status" -eq 0 ]
	[ "$output" = "shop shop" ]
	run connect "$url" "SELECT extname FROM pg_extension WHERE extname = 'vector'"
	[ "$output" = "vector" ]
}

@test "a product's database is added the same way, and the printed password line logs in through the door" {
	run --separate-stderr bin/add-database --postgres metabase
	[ "$status" -eq 0 ]
	password=$(printed METABASE_DB_PASSWORD)
	[ "${#password}" -eq 32 ]
	run connect "postgresql://metabase:$password@pgbouncer-transaction:5432/metabase" "SELECT current_user || ' ' || current_database()"
	[ "$status" -eq 0 ]
	[ "$output" = "metabase metabase" ]
}

@test "with --session, the DSN names the session door" {
	run --separate-stderr bin/add-database --postgres --session diary
	[ "$status" -eq 0 ]
	url=$(printed DATABASE_URL)
	[[ "$url" == postgresql://diary:*@pgbouncer-session:5432/diary ]]
	run connect "$url" "SELECT current_user"
	[ "$status" -eq 0 ]
	[ "$output" = "diary" ]
}

@test "a database's user reaches no other database" {
	run --separate-stderr bin/add-database --postgres left
	[ "$status" -eq 0 ]
	left=$(printed DATABASE_URL)
	run --separate-stderr bin/add-database --postgres right
	[ "$status" -eq 0 ]
	run connect "${left%/left}/right" "SELECT 1"
	[ "$status" -ne 0 ]
	[[ "$output" == *"permission denied for database"* ]]
}

@test "with --api, the recipe is installed, and PostgREST's DSN names the session door" {
	run --separate-stderr bin/add-database --postgres --api notes
	[ "$status" -eq 0 ]
	url=$(printed DATABASE_URL)
	api=$(printed PGRST_DB_URI)
	[[ "$url" == postgresql://notes:*@pgbouncer-transaction:5432/notes ]]
	[[ "$api" == postgresql://notes_authenticator:*@pgbouncer-session:5432/notes ]]
	[ "$(printed PGRST_DB_SCHEMAS)" = api ]
	[ "$(printed PGRST_DB_ANON_ROLE)" = notes_anon ]
	run connect "$url" "CREATE TABLE api.items (id int); INSERT INTO api.items VALUES (1); GRANT SELECT ON api.items TO notes_anon"
	[ "$status" -eq 0 ]
	run connect "$api" "SELECT id FROM api.items"
	[ "$status" -ne 0 ]
	[[ "$output" == *"permission denied"* ]]
	run connect "$api" "SET ROLE notes_anon; SELECT id FROM api.items"
	[ "$status" -eq 0 ]
	[ "$output" = "1" ]
	run connect "$url" "SELECT evtname FROM pg_event_trigger"
	[ "$output" = "pgrst_watch" ]
}

@test "with --session and --api, both DSNs name the session door, and both connect" {
	run --separate-stderr bin/add-database --postgres --session --api board
	[ "$status" -eq 0 ]
	url=$(printed DATABASE_URL)
	api=$(printed PGRST_DB_URI)
	[[ "$url" == postgresql://board:*@pgbouncer-session:5432/board ]]
	[[ "$api" == postgresql://board_authenticator:*@pgbouncer-session:5432/board ]]
	run connect "$url" "SELECT current_user"
	[ "$output" = "board" ]
	run connect "$api" "SELECT current_user"
	[ "$output" = "board_authenticator" ]
}

@test "adding a name twice is refused, and changes nothing" {
	run --separate-stderr bin/add-database --postgres twice
	[ "$status" -eq 0 ]
	url=$(printed DATABASE_URL)
	run --separate-stderr bin/add-database --postgres twice
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"the database twice already exists. Nothing was changed."* ]]
	run connect "$url" "SELECT current_user"
	[ "$status" -eq 0 ]
	[ "$output" = "twice" ]
}

@test "a role left behind without its database stops an add, and remove clears it" {
	superuser "CREATE ROLE half_anon NOLOGIN"
	run --separate-stderr bin/add-database --postgres half
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"there is no database half, but these remain from an earlier one: half_anon."* ]]
	run superuser "SELECT count(*) FROM pg_roles WHERE rolname LIKE 'half%'"
	[ "$output" = "1" ]
	run --separate-stderr bin/remove-database --postgres half <<<"half"
	[ "$status" -eq 0 ]
	run --separate-stderr bin/add-database --postgres half
	[ "$status" -eq 0 ]
}

@test "a bad name is refused by both helpers, before anything is made" {
	local long name
	long=$(printf 'a%.0s' {1..64})
	for name in '' my-app MyApp 1app "$long" "my'app" 'my app' postgres template1 pgbouncer_auth pg_app; do
		run --separate-stderr bin/add-database --postgres "$name"
		[ "$status" -eq 1 ]
		run --separate-stderr bin/remove-database --postgres "$name"
		[ "$status" -eq 1 ]
	done
	run --separate-stderr bin/add-database --postgres --api "$(printf 'a%.0s' {1..50})"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"too long for --api"* ]]
	run superuser "SELECT count(*) FROM pg_database WHERE datname LIKE 'aaaaaaaa%'"
	[ "$output" = "0" ]
}

@test "a helper run with no name, or with two, prints its usage" {
	run --separate-stderr bin/add-database --postgres
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"usage: bin/add-database --postgres [--session] [--api] NAME, or bin/add-database --clickhouse NAME"* ]]
	run --separate-stderr bin/add-database --postgres one two
	[ "$status" -eq 1 ]
	run --separate-stderr bin/add-database --postgres --pool one
	[ "$status" -eq 1 ]
	run --separate-stderr bin/remove-database --postgres
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"usage: bin/remove-database --postgres|--clickhouse NAME"* ]]
}

@test "each helper names its datastore, one of the two, and without one changes nothing" {
	run --separate-stderr bin/add-database --postgres named
	[ "$status" -eq 0 ]
	url=$(printed DATABASE_URL)
	local helper
	for helper in add-database new-password remove-database; do
		run --separate-stderr "bin/$helper" named <<<"named"
		[ "$status" -eq 1 ]
		[[ "$stderr" == *"name the datastore, --postgres or --clickhouse."* ]]
		[ -z "$output" ]
		run --separate-stderr "bin/$helper" --postgres --clickhouse named <<<"named"
		[ "$status" -eq 1 ]
		[[ "$stderr" == *"name one datastore, --postgres or --clickhouse, not both."* ]]
		[ -z "$output" ]
	done
	run --separate-stderr bin/add-database fresh
	[ "$status" -eq 1 ]
	run superuser "SELECT count(*) FROM pg_database WHERE datname IN ('named', 'fresh')"
	[ "$output" = "1" ]
	run connect "$url" "SELECT current_user"
	[ "$status" -eq 0 ]
	[ "$output" = "named" ]
}

@test "remove asks first, and drops nothing unless the name is typed" {
	run --separate-stderr bin/add-database --postgres keep
	[ "$status" -eq 0 ]
	url=$(printed DATABASE_URL)
	run --separate-stderr bin/remove-database --postgres keep <<<"y"
	[ "$status" -eq 1 ]
	[[ "$output" == *"This drops the database keep."* ]]
	[[ "$output" == *"Nothing was dropped."* ]]
	run --separate-stderr bin/remove-database --postgres keep </dev/null
	[ "$status" -eq 1 ]
	run connect "$url" "SELECT current_user"
	[ "$output" = "keep" ]
}

@test "remove drops the database while both doors hold it, its user and both roles, and the name can be added again" {
	run --separate-stderr bin/add-database --postgres --api again
	[ "$status" -eq 0 ]
	url=$(printed DATABASE_URL)
	api=$(printed PGRST_DB_URI)
	run connect "$url" "SELECT 1"
	[ "$status" -eq 0 ]
	run connect "$api" "SELECT 1"
	[ "$status" -eq 0 ]
	run superuser "SELECT count(*) > 0 FROM pg_stat_activity WHERE datname = 'again'"
	[ "$output" = "t" ]

	run --separate-stderr bin/remove-database --postgres again <<<"again"
	[ "$status" -eq 0 ]
	[[ "$output" == *"This drops the database again."* ]]
	[[ "$output" == *"This drops the user again."* ]]
	[[ "$output" == *"This drops PostgREST's roles: again_anon, again_authenticator."* ]]
	[[ "$output" == *"Dropped the role again_authenticator."* ]]
	run superuser "SELECT count(*) FROM pg_database WHERE datname = 'again'"
	[ "$output" = "0" ]
	run superuser "SELECT count(*) FROM pg_roles WHERE rolname LIKE 'again%'"
	[ "$output" = "0" ]

	run --separate-stderr bin/add-database --postgres --session again
	[ "$status" -eq 0 ]
	url=$(printed DATABASE_URL)
	run connect "$url" "SELECT current_user"
	[ "$status" -eq 0 ]
	[ "$output" = "again" ]
	run connect "${url/pgbouncer-session/pgbouncer-transaction}" "SELECT current_user"
	[ "$status" -eq 0 ]
	[ "$output" = "again" ]
}

@test "a new password logs in through the door, and the old one no longer does" {
	run --separate-stderr bin/add-database --postgres renew
	[ "$status" -eq 0 ]
	old=$(printed DATABASE_URL)
	run connect "$old" "SELECT 1"
	[ "$status" -eq 0 ]
	run --separate-stderr bin/new-password --postgres renew
	[ "$status" -eq 0 ]
	new=$(printed DATABASE_URL)
	password=$(printed RENEW_DB_PASSWORD)
	[ "${#password}" -eq 32 ]
	[ "$new" = "postgresql://renew:$password@pgbouncer-transaction:5432/renew" ]
	[ "$new" != "$old" ]
	run connect "$new" "SELECT current_user"
	[ "$status" -eq 0 ]
	[ "$output" = "renew" ]
	run connect "$old" "SELECT 1"
	[ "$status" -ne 0 ]
	[[ "$output" == *"SASL authentication failed"* ]]
}

@test "with --session, the new password's DSN names the session door" {
	run --separate-stderr bin/add-database --postgres --session rotate
	[ "$status" -eq 0 ]
	run --separate-stderr bin/new-password --postgres --session rotate
	[ "$status" -eq 0 ]
	new=$(printed DATABASE_URL)
	[[ "$new" == postgresql://rotate:*@pgbouncer-session:5432/rotate ]]
	run connect "$new" "SELECT current_user"
	[ "$status" -eq 0 ]
	[ "$output" = "rotate" ]
}

@test "PostgREST's authenticator gets a new password, and only PGRST_DB_URI is printed" {
	run --separate-stderr bin/add-database --postgres --api feed
	[ "$status" -eq 0 ]
	old=$(printed PGRST_DB_URI)
	run connect "$old" "SELECT 1"
	[ "$status" -eq 0 ]
	run --separate-stderr bin/new-password --postgres feed_authenticator
	[ "$status" -eq 0 ]
	new=$(printed PGRST_DB_URI)
	[[ "$new" == postgresql://feed_authenticator:*@pgbouncer-session:5432/feed ]]
	[ -z "$(printed DATABASE_URL)" ]
	run connect "$new" "SELECT current_user"
	[ "$status" -eq 0 ]
	[ "$output" = "feed_authenticator" ]
	run connect "$old" "SELECT 1"
	[ "$status" -ne 0 ]
	[[ "$output" == *"SASL authentication failed"* ]]
}

@test "the doors' auth user gets a new password, and both doors let users in after up" {
	run --separate-stderr bin/add-database --postgres gate
	[ "$status" -eq 0 ]
	url=$(printed DATABASE_URL)
	run --separate-stderr bin/new-password --postgres pgbouncer_auth
	[ "$status" -eq 0 ]
	[ -z "$(printed DATABASE_URL)" ]
	password=$(printed PGBOUNCER_AUTH_PASSWORD)
	[ "${#password}" -eq 32 ]
	sed -i "s/^PGBOUNCER_AUTH_PASSWORD=.*/PGBOUNCER_AUTH_PASSWORD=$password/" "$env_file"
	compose up --detach --wait postgres-18 pgbouncer-transaction pgbouncer-session postgres-dumper
	run connect "$url" "SELECT current_user"
	[ "$status" -eq 0 ]
	[ "$output" = "gate" ]
	run connect "${url/pgbouncer-transaction/pgbouncer-session}" "SELECT current_user"
	[ "$status" -eq 0 ]
	[ "$output" = "gate" ]
}

@test "new-password refuses the superuser, a user without its database, an anon role and a bad name, and changes nothing" {
	run --separate-stderr bin/add-database --postgres --api spare
	[ "$status" -eq 0 ]
	url=$(printed DATABASE_URL)
	api=$(printed PGRST_DB_URI)
	superuser "CREATE ROLE lone LOGIN PASSWORD 'lone-password'"
	local long name
	long=$(printf 'a%.0s' {1..64})
	for name in postgres lone spare_anon ghost_authenticator ghost pg_monitor '' my-app MyApp 1app "$long" "my'app"; do
		run --separate-stderr bin/new-password --postgres "$name"
		[ "$status" -eq 1 ]
	done
	run --separate-stderr bin/new-password --postgres postgres
	[[ "$stderr" == *"postgres is a superuser"* ]]
	run --separate-stderr bin/new-password --postgres
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"usage: bin/new-password --postgres [--session] NAME"* ]]
	run --separate-stderr bin/new-password --postgres spare spare
	[ "$status" -eq 1 ]
	run --separate-stderr bin/new-password --postgres --api spare
	[ "$status" -eq 1 ]
	run connect "$url" "SELECT current_user"
	[ "$output" = "spare" ]
	run connect "$api" "SELECT current_user"
	[ "$output" = "spare_authenticator" ]
	run connect "postgresql://lone:lone-password@pgbouncer-transaction:5432/postgres" "SELECT current_user"
	[ "$output" = "lone" ]
	run connect "postgresql://postgres:postgres-password@pgbouncer-transaction:5432/postgres" "SELECT current_user"
	[ "$output" = "postgres" ]
}

@test "remove of a name that is not there drops nothing, and says so" {
	run --separate-stderr bin/remove-database --postgres ghost </dev/null
	[ "$status" -eq 0 ]
	[ "$output" = "There is no database ghost, and no user or role of that name. Nothing was dropped." ]
}

@test "a run archives the globals and every database, and a database added later is archived without being named" {
	run --separate-stderr bin/add-database --postgres ledger
	[ "$status" -eq 0 ]
	run --separate-stderr in_dumper dumper now
	[ "$status" -eq 0 ]
	first=$(newest_run)
	[ -n "$first" ]
	in_dumper grep -qx 'CREATE ROLE ledger;' "/backups/postgres/$first/globals.sql"
	in_dumper pg_restore --list "/backups/postgres/$first/databases/ledger.dump" >/dev/null
	run in_dumper test -e "/backups/postgres/$first/databases/postgres.dump"
	[ "$status" -ne 0 ]

	run --separate-stderr bin/add-database --postgres later
	[ "$status" -eq 0 ]
	run --separate-stderr in_dumper dumper now
	[ "$status" -eq 0 ]
	second=$(newest_run)
	[ "$second" != "$first" ]
	in_dumper pg_restore --list "/backups/postgres/$second/databases/later.dump" >/dev/null
	run in_dumper test -e "/backups/postgres/$first/databases/later.dump"
	[ "$status" -ne 0 ]
}

@test "a run keeps its temporary name until every database is archived" {
	run --separate-stderr bin/add-database --postgres slow
	[ "$status" -eq 0 ]
	docker exec postgres-18 psql -v ON_ERROR_STOP=1 -X -q -U postgres -d slow -c "CREATE TABLE held (id int)"
	docker exec postgres-18 psql -X -q -U postgres -d slow -c "BEGIN; LOCK TABLE held IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(8); COMMIT;" >/dev/null &
	sleep 2
	before=$(runs | wc -l)
	in_dumper dumper now >/dev/null 2>&1 &
	sleep 3
	run in_dumper sh -c 'ls -d /backups/postgres/*.writing'
	[ "$status" -eq 0 ]
	[ "$(runs | wc -l)" -eq "$before" ]
	wait
	[ "$(runs | wc -l)" -eq $((before + 1)) ]
	run in_dumper sh -c 'ls -d /backups/postgres/*.writing'
	[ "$status" -ne 0 ]
	in_dumper pg_restore --list "/backups/postgres/$(newest_run)/databases/slow.dump" >/dev/null
}

@test "a run missed while the dumper was down is caught up after a restart, once" {
	stale=$(($(date +%s) - 3 * 86400))
	in_dumper sh -c "echo '$stale ok' >/backups/postgres/last-run"
	before=$(runs | wc -l)
	docker restart postgres-dumper >/dev/null
	local waited=0
	while [ "$(runs | wc -l)" -eq "$before" ] && [ "$waited" -lt 60 ]; do
		sleep 1
		waited=$((waited + 1))
	done
	[ "$(runs | wc -l)" -eq $((before + 1)) ]
	docker restart postgres-dumper >/dev/null
	sleep 5
	[ "$(runs | wc -l)" -eq $((before + 1)) ]
}
