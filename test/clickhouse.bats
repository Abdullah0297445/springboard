bats_require_minimum_version 1.5.0

setup_file() {
	export project=springboard-test
	export env_file="$BATS_FILE_TMPDIR/env"
	cat >"$env_file" <<'EOF'
CLICKHOUSE_PASSWORD=clickhouse-password
EOF
	compose down --volumes --remove-orphans
	compose up --detach --wait clickhouse
	compose up --detach clickhouse-dumper
}

teardown_file() {
	compose down --volumes --remove-orphans
}

compose() {
	COMPOSE_FILE=compose.yml:compose/clickhouse.yml docker compose --project-name "$project" --env-file "$env_file" "$@"
}

client() {
	docker run --rm --network "${project}_clickhouse" clickhouse/clickhouse-server:26.8 \
		clickhouse-client "$1" --multiquery --query "$2"
}

admin() {
	docker exec clickhouse clickhouse-client --query "$1"
}

printed() {
	sed -n "s/^  $1=//p" <<<"$output"
}

in_dumper() {
	docker exec clickhouse-dumper "$@"
}

newest_run() {
	in_dumper ls /backups/clickhouse | grep -x '[0-9]\{8\}T[0-9]\{6\}Z' | tail -n 1
}

@test "a database added on ClickHouse logs in with the printed DSN, its password line is for Infisical or .env, and its user works in it" {
	run --separate-stderr bin/add-database --clickhouse events
	[ "$status" -eq 0 ]
	url=$(printed CLICKHOUSE_URL)
	password=$(printed EVENTS_CLICKHOUSE_PASSWORD)
	[ "${#password}" -eq 32 ]
	[[ "$output" == *"For a product, put this line in Infisical, in the project springboard, environment prod.
On a host without Infisical, put it in .env instead:

  EVENTS_CLICKHOUSE_PASSWORD=$password"* ]]
	[[ "$output" != *"springboard's .env"* ]]
	[[ "$output" == *"the consumer's compose file declares the network ${project}_clickhouse external"* ]]
	[ "$url" = "clickhouse://events:$password@clickhouse:9000/events" ]
	run client "$url" "SELECT currentUser(), currentDatabase()"
	[ "$status" -eq 0 ]
	[ "$output" = "events	events" ]
	run client "$url" "CREATE TABLE t (id UInt8, n UInt8) ENGINE = MergeTree ORDER BY id; INSERT INTO t VALUES (1, 1); ALTER TABLE t UPDATE n = 2 WHERE id = 1 SETTINGS mutations_sync = 1; SELECT n FROM t"
	[ "$status" -eq 0 ]
	[ "$output" = "2" ]
	run client "$url" "SELECT sum(rows) FROM system.parts WHERE database = 'events' AND active"
	[ "$output" = "1" ]
	run client "$url" "SELECT count() FROM system.mutations WHERE database = 'events' AND is_done"
	[ "$output" = "1" ]
	run client "$url" "SELECT name FROM system.tables WHERE database = 'events'"
	[ "$output" = "t" ]
	run client "$url" "SELECT count() > 0 FROM system.processes"
	[ "$output" = "1" ]
}

@test "a ClickHouse user reads no other database, and makes no database and no user" {
	run --separate-stderr bin/add-database --clickhouse north
	[ "$status" -eq 0 ]
	north=$(printed CLICKHOUSE_URL)
	run --separate-stderr bin/add-database --clickhouse south
	[ "$status" -eq 0 ]
	south=$(printed CLICKHOUSE_URL)
	run client "$south" "CREATE TABLE t (id UInt8) ENGINE = MergeTree ORDER BY id"
	[ "$status" -eq 0 ]
	run client "$north" "SELECT * FROM south.t"
	[ "$status" -ne 0 ]
	[[ "$output" == *"ACCESS_DENIED"* ]]
	run client "$north" "CREATE DATABASE east"
	[ "$status" -ne 0 ]
	[[ "$output" == *"ACCESS_DENIED"* ]]
	run client "$north" "CREATE USER east IDENTIFIED BY 'east-password'"
	[ "$status" -ne 0 ]
	[[ "$output" == *"ACCESS_DENIED"* ]]
}

@test "on ClickHouse, a name twice, a user left behind, --session, --api and a bad name are refused, and change nothing" {
	run --separate-stderr bin/add-database --clickhouse twice
	[ "$status" -eq 0 ]
	url=$(printed CLICKHOUSE_URL)
	run --separate-stderr bin/add-database --clickhouse twice
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"the database twice already exists on ClickHouse. Nothing was changed."* ]]
	run client "$url" "SELECT currentUser()"
	[ "$output" = "twice" ]
	admin "CREATE USER half IDENTIFIED BY 'half-password'"
	run --separate-stderr bin/add-database --clickhouse half
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"its user remains from an earlier one"* ]]
	local option name long
	for option in --session --api; do
		run --separate-stderr bin/add-database --clickhouse "$option" other
		[ "$status" -eq 1 ]
		[[ "$stderr" == *"--clickhouse takes neither"* ]]
	done
	long=$(printf 'a%.0s' {1..64})
	for name in default system information_schema '' my-app MyApp 1app "$long" "my'app"; do
		run --separate-stderr bin/add-database --clickhouse "$name"
		[ "$status" -eq 1 ]
	done
	run admin "SELECT count() FROM system.databases WHERE name IN ('half', 'other')"
	[ "$output" = "0" ]
	run admin "SELECT count() FROM system.users WHERE name IN ('other', 'default')"
	[ "$output" = "1" ]
}

@test "remove on ClickHouse drops nothing without --clickhouse or unless the name is typed, then drops the database and its user, says to delete a product's line, and the name can be added again" {
	run --separate-stderr bin/add-database --clickhouse gone
	[ "$status" -eq 0 ]
	url=$(printed CLICKHOUSE_URL)
	run client "$url" "CREATE TABLE t (id UInt8) ENGINE = MergeTree ORDER BY id"
	[ "$status" -eq 0 ]
	run --separate-stderr bin/remove-database gone <<<"gone"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"name the datastore, --postgres or --clickhouse."* ]]
	run --separate-stderr bin/remove-database --clickhouse gone <<<"y"
	[ "$status" -eq 1 ]
	[[ "$output" == *"This drops the database gone on ClickHouse."* ]]
	[[ "$output" == *"Nothing was dropped."* ]]
	run client "$url" "SELECT currentUser()"
	[ "$output" = "gone" ]

	run --separate-stderr bin/remove-database --clickhouse gone <<<"gone"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Dropped the database gone on ClickHouse."* ]]
	[[ "$output" == *"Dropped the user gone on ClickHouse.

For a product, delete GONE_CLICKHOUSE_PASSWORD from Infisical, in the project springboard, environment prod.
On a host without Infisical, delete it from .env instead." ]]
	run admin "SELECT count() FROM system.databases WHERE name = 'gone'"
	[ "$output" = "0" ]
	run admin "SELECT count() FROM system.users WHERE name = 'gone'"
	[ "$output" = "0" ]

	run --separate-stderr bin/add-database --clickhouse gone
	[ "$status" -eq 0 ]
	run client "$(printed CLICKHOUSE_URL)" "CREATE TABLE t (id UInt8) ENGINE = MergeTree ORDER BY id"
	[ "$status" -eq 0 ]
}

@test "remove on ClickHouse of a name that is not there drops nothing, and a bad name is refused" {
	run --separate-stderr bin/remove-database --clickhouse ghost </dev/null
	[ "$status" -eq 0 ]
	[ "$output" = "There is no database ghost on ClickHouse, and no user of that name. Nothing was dropped." ]
	local name
	for name in default system information_schema '' my-app MyApp "my'app"; do
		run --separate-stderr bin/remove-database --clickhouse "$name" <<<"$name"
		[ "$status" -eq 1 ]
	done
	run admin "SELECT count() FROM system.databases WHERE name IN ('default', 'system', 'information_schema')"
	[ "$output" = "3" ]
}

@test "a ClickHouse user gets a new password, and the old one no longer logs in" {
	run --separate-stderr bin/add-database --clickhouse turn
	[ "$status" -eq 0 ]
	old=$(printed CLICKHOUSE_URL)
	run client "$old" "SELECT 1"
	[ "$status" -eq 0 ]
	run --separate-stderr bin/new-password --clickhouse turn
	[ "$status" -eq 0 ]
	new=$(printed CLICKHOUSE_URL)
	password=$(printed TURN_CLICKHOUSE_PASSWORD)
	[ "${#password}" -eq 32 ]
	[[ "$output" == *"For a product, put this line in Infisical, in the project springboard, environment prod, and run bin/up.
On a host without Infisical, put it in .env instead, and run docker compose up -d:

  TURN_CLICKHOUSE_PASSWORD=$password"* ]]
	[ "$new" = "clickhouse://turn:$password@clickhouse:9000/turn" ]
	run client "$new" "SELECT currentUser()"
	[ "$status" -eq 0 ]
	[ "$output" = "turn" ]
	run client "$old" "SELECT 1"
	[ "$status" -ne 0 ]
	[[ "$output" == *"AUTHENTICATION_FAILED"* ]]
}

@test "new-password on ClickHouse refuses default, a name with no database, --session and a bad name" {
	admin "CREATE USER stray IDENTIFIED BY 'stray-password'"
	local name
	for name in default stray ghost '' my-app "my'app"; do
		run --separate-stderr bin/new-password --clickhouse "$name"
		[ "$status" -eq 1 ]
	done
	run --separate-stderr bin/new-password --clickhouse default
	[[ "$stderr" == *"default is a superuser"* ]]
	run --separate-stderr bin/add-database --clickhouse kept
	[ "$status" -eq 0 ]
	url=$(printed CLICKHOUSE_URL)
	run --separate-stderr bin/new-password --clickhouse --session kept
	[ "$status" -eq 1 ]
	run client "$url" "SELECT currentUser()"
	[ "$output" = "kept" ]
	run admin "SELECT 1"
	[ "$output" = "1" ]
}

@test "a run on ClickHouse archives the users and every database, and a database added later is archived without being named" {
	run --separate-stderr bin/add-database --clickhouse ledger
	[ "$status" -eq 0 ]
	run --separate-stderr in_dumper dumper now
	[ "$status" -eq 0 ]
	first=$(newest_run)
	[ -n "$first" ]
	in_dumper sh -c "tar -xOf /backups/clickhouse/$first/globals.tar | grep -aq 'USER ledger'"
	in_dumper tar -tf "/backups/clickhouse/$first/databases/ledger.tar" .backup >/dev/null
	run in_dumper test -e "/backups/clickhouse/$first/databases/system.tar"
	[ "$status" -ne 0 ]

	run --separate-stderr bin/add-database --clickhouse later
	[ "$status" -eq 0 ]
	run --separate-stderr in_dumper dumper now
	[ "$status" -eq 0 ]
	second=$(newest_run)
	[ "$second" != "$first" ]
	in_dumper tar -tf "/backups/clickhouse/$second/databases/later.tar" .backup >/dev/null
	run in_dumper test -e "/backups/clickhouse/$first/databases/later.tar"
	[ "$status" -ne 0 ]
}
