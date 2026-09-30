bats_require_minimum_version 1.5.0

setup_file() {
	export project=springboard-test
	export env_file="$BATS_FILE_TMPDIR/env"
	export stand_in="$BATS_FILE_TMPDIR/stand-in.yml"
	cat >"$env_file" <<'EOF'
POSTGRES_PASSWORD=postgres-password
PGBOUNCER_AUTH_PASSWORD=pgbouncer-auth-password
CLICKHOUSE_PASSWORD=clickhouse-password
ARCHIVIST_S3_BUCKET=archivist-test
ARCHIVIST_S3_REGION=us-east-1
ARCHIVIST_S3_ENDPOINT=http://moto:5000
ARCHIVIST_S3_ACCESS_KEY_ID=archivist-s3-key
ARCHIVIST_S3_SECRET_ACCESS_KEY=archivist-s3-secret
ARCHIVIST_KEY_PROVIDER=ssm
ARCHIVIST_KEY_NAME=/springboard/archivist-key
ARCHIVIST_KEY_REGION=us-east-1
ARCHIVIST_KEY_ACCESS_KEY_ID=archivist-key-key
ARCHIVIST_KEY_SECRET_ACCESS_KEY=archivist-key-secret
EOF
	cat >"$stand_in" <<'EOF'
services:
  moto:
    image: motoserver/moto:5.2.3
    container_name: moto
  archivist:
    environment:
      AWS_ENDPOINT_URL_SSM: http://moto:5000
EOF
	compose down --volumes --remove-orphans
	compose up --detach moto
	local waited=0
	until aws 's3.list_buckets()' >/dev/null 2>&1 || [ "$waited" -ge 30 ]; do
		sleep 1
		waited=$((waited + 1))
	done
	aws 's3.create_bucket(Bucket="archivist-test")'
	aws "ssm.put_parameter(Name='/springboard/archivist-key', Value='0123456789abcdef0123456789abcdef', Type='SecureString')"
	compose run --rm archivist init
	compose up --detach --wait --wait-timeout 120 postgres-18 pgbouncer-transaction pgbouncer-session clickhouse archivist
	compose up --detach postgres-dumper clickhouse-dumper
}

teardown_file() {
	compose down --volumes --remove-orphans
}

compose() {
	COMPOSE_FILE="compose.yml:compose/postgres.yml:compose/clickhouse.yml:compose/archivist.yml:$stand_in" docker compose --project-name "$project" --env-file "$env_file" "$@"
}

aws() {
	docker exec -i moto python3 - <<EOF
import boto3
reach = dict(endpoint_url="http://localhost:5000", region_name="us-east-1", aws_access_key_id="moto", aws_secret_access_key="moto")
s3 = boto3.client("s3", **reach)
ssm = boto3.client("ssm", **reach)
$1
EOF
}

printed() {
	sed -n "s/^  $1=//p" <<<"$output"
}

connect() {
	docker run --rm --network "${project}_postgres" pgvector/pgvector:pg18-trixie \
		psql "$1" -v ON_ERROR_STOP=1 -X -q -tA -c "$2"
}

admin() {
	docker exec clickhouse clickhouse-client --query "$1"
}

client() {
	docker run --rm --network "${project}_clickhouse" clickhouse/clickhouse-server:26.8 \
		clickhouse-client "$1" --query "$2"
}

archive_now() {
	docker exec "$1-dumper" dumper now | sed -n 's|^.* into /backups/[a-z]*/||p'
	docker exec archivist archivist upload >/dev/null
}

new_postgres() {
	compose rm --stop --force postgres-18 pgbouncer-transaction pgbouncer-session postgres-dumper
	docker volume rm "${project}_postgres_data"
	compose up --detach --wait --wait-timeout 120 postgres-18 pgbouncer-transaction pgbouncer-session
	compose up --detach postgres-dumper
}

new_clickhouse() {
	compose rm --stop --force clickhouse clickhouse-dumper
	docker volume rm "${project}_clickhouse_data"
	compose up --detach --wait --wait-timeout 120 clickhouse
	compose up --detach clickhouse-dumper
}

@test "rebuild names its datastore, one of the two" {
	run --separate-stderr bin/rebuild
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"--postgres or --clickhouse"* ]]
	run --separate-stderr bin/rebuild --postgres --clickhouse
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"--postgres or --clickhouse"* ]]
	run --separate-stderr bin/rebuild --postgres shop
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"usage: bin/rebuild"* ]]
	run --separate-stderr bin/rebuild --postgres --run yesterday
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"is not the time of a run"* ]]
}

@test "on a new host, Postgres comes back whole: every database with its rows, and every user with its old password" {
	run --separate-stderr bin/add-database --postgres shop
	[ "$status" -eq 0 ]
	shop=$(printed DATABASE_URL)
	run --separate-stderr bin/add-database --postgres --session till
	[ "$status" -eq 0 ]
	till=$(printed DATABASE_URL)
	connect "$shop" "CREATE TABLE orders (id int); INSERT INTO orders VALUES (1)"
	connect "$till" "CREATE TABLE sales (id int); INSERT INTO sales VALUES (2)"
	taken=$(archive_now postgres)
	new_postgres
	run --separate-stderr bin/rebuild --postgres
	[ "$status" -eq 0 ]
	[[ "$output" == *"$taken"* ]]
	[[ "$output" == *"shop"* ]]
	[[ "$output" == *"till"* ]]
	[ "$(connect "$shop" "SELECT id FROM orders")" = "1" ]
	[ "$(connect "$till" "SELECT id FROM sales")" = "2" ]
}

@test "a Postgres that is not empty is refused, and nothing is changed" {
	run --separate-stderr bin/add-database --postgres kept
	[ "$status" -eq 0 ]
	kept=$(printed DATABASE_URL)
	connect "$kept" "CREATE TABLE notes (id int); INSERT INTO notes VALUES (1)"
	archive_now postgres
	connect "$kept" "INSERT INTO notes VALUES (2)"
	run --separate-stderr bin/rebuild --postgres
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"not empty"* ]]
	[[ "$stderr" == *"kept"* ]]
	[ "$(connect "$kept" "SELECT string_agg(id::text, ' ' ORDER BY id) FROM notes")" = "1 2" ]
}

@test "the newest run is taken, a newest run with no database is refused, and --run takes an older one" {
	run --separate-stderr bin/add-database --postgres ages
	[ "$status" -eq 0 ]
	ages=$(printed DATABASE_URL)
	connect "$ages" "CREATE TABLE era (n int); INSERT INTO era VALUES (1)"
	older=$(archive_now postgres)
	sleep 1
	connect "$ages" "INSERT INTO era VALUES (2)"
	newer=$(archive_now postgres)
	new_postgres
	empty=$(archive_now postgres)
	run --separate-stderr bin/rebuild --postgres
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"newest run, $empty, holds no database. If this host was given its intent before the rebuild, that run archived an empty postgres."* ]]
	[[ "$stderr" == *"$older"* ]]
	[[ "$stderr" == *"$newer"* ]]
	run --separate-stderr bin/rebuild --postgres --run 20000101T000000Z
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"no run 20000101T000000Z"* ]]
	run --separate-stderr bin/rebuild --postgres --run "$older"
	[ "$status" -eq 0 ]
	[[ "$output" == *"$older"* ]]
	[ "$(connect "$ages" "SELECT string_agg(n::text, ' ') FROM era")" = "1" ]
}

@test "on a new host, ClickHouse comes back whole: every user with its password and grants, and every database" {
	run --separate-stderr bin/add-database --clickhouse events
	[ "$status" -eq 0 ]
	events=$(printed CLICKHOUSE_URL)
	client "$events" "CREATE TABLE hits (id UInt8) ENGINE = MergeTree ORDER BY id"
	client "$events" "INSERT INTO hits VALUES (1)"
	admin "CREATE TABLE default.notes (id UInt8) ENGINE = MergeTree ORDER BY id"
	admin "INSERT INTO default.notes VALUES (7)"
	taken=$(archive_now clickhouse)
	new_clickhouse
	run --separate-stderr bin/rebuild --clickhouse
	[ "$status" -eq 0 ]
	[[ "$output" == *"$taken"* ]]
	[[ "$output" == *"events"* ]]
	client "$events" "INSERT INTO hits VALUES (2)"
	[ "$(client "$events" "SELECT groupArray(id) FROM (SELECT id FROM hits ORDER BY id)")" = "[1,2]" ]
	[ "$(admin "SELECT groupArray(id) FROM default.notes")" = "[7]" ]
}

@test "a ClickHouse that is not empty is refused, and nothing is changed" {
	run --separate-stderr bin/add-database --clickhouse stays
	[ "$status" -eq 0 ]
	stays=$(printed CLICKHOUSE_URL)
	client "$stays" "CREATE TABLE rows (id UInt8) ENGINE = MergeTree ORDER BY id"
	client "$stays" "INSERT INTO rows VALUES (1)"
	admin "CREATE TABLE default.left (id UInt8) ENGINE = MergeTree ORDER BY id"
	archive_now clickhouse
	client "$stays" "INSERT INTO rows VALUES (2)"
	run --separate-stderr bin/rebuild --clickhouse
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"not empty"* ]]
	[[ "$stderr" == *"stays"* ]]
	[[ "$stderr" == *"default.left"* ]]
	[ "$(client "$stays" "SELECT count() FROM rows")" = "2" ]
}

@test "a password in .env that is not the archive's stops the rebuild right after the globals, and says so" {
	run --separate-stderr bin/add-database --postgres guard
	[ "$status" -eq 0 ]
	archive_now postgres
	POSTGRES_PASSWORD=mistyped new_postgres
	run --separate-stderr bin/rebuild --postgres
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"POSTGRES_PASSWORD"* ]]
	[[ "$stderr" == *"recovery key"* ]]
	[ "$(docker exec postgres-18 psql -X -tA -U postgres -c "SELECT count(*) FROM pg_database WHERE datname = 'guard'")" = "0" ]
	PGBOUNCER_AUTH_PASSWORD=mistyped new_postgres
	run --separate-stderr bin/rebuild --postgres
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"PGBOUNCER_AUTH_PASSWORD"* ]]
	[[ "$stderr" == *"recovery key"* ]]
	[ "$(docker exec postgres-18 psql -X -tA -U postgres -c "SELECT count(*) FROM pg_database WHERE datname = 'guard'")" = "0" ]
}

@test "a run two hosts wrote in the same second is refused, and nothing is changed" {
	run --separate-stderr bin/add-database --postgres twice
	[ "$status" -eq 0 ]
	taken=$(docker exec postgres-dumper dumper now | sed -n 's|^.* into /backups/[a-z]*/||p')
	docker exec postgres-dumper cp -r "/backups/postgres/$taken" /tmp/other-host
	docker exec archivist archivist upload >/dev/null
	docker exec postgres-dumper cp -r /tmp/other-host "/backups/postgres/$taken"
	docker exec archivist archivist upload >/dev/null
	new_postgres
	run --separate-stderr bin/rebuild --postgres
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"the run $taken holds two archives of /postgres/"* ]]
	[[ "$stderr" == *"two hosts wrote into this bucket in the same second. One bucket takes one running host. Nothing was changed. Name another run with --run."* ]]
	[[ "$stderr" == *"$taken"*"databases"* ]]
	run --separate-stderr bin/rebuild --postgres --run "$taken"
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"two hosts wrote into this bucket in the same second"* ]]
	[ "$(docker exec postgres-18 psql -X -tA -U postgres -c "SELECT count(*) FROM pg_database WHERE datname = 'twice'")" = "0" ]
	[ "$(docker exec postgres-18 psql -X -tA -U postgres -c "SELECT count(*) FROM pg_roles WHERE rolname = 'twice'")" = "0" ]
}
