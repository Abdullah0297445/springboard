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

superuser() {
	docker exec postgres-18 psql -v ON_ERROR_STOP=1 -X -q -tA -U postgres -d "$1" -c "$2"
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
	docker exec "$1-dumper" dumper now >/dev/null
	docker exec archivist archivist upload >/dev/null
}

@test "restore names its datastore, one of the two, and refuses a bad name" {
	run --separate-stderr bin/restore shop
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"--postgres or --clickhouse"* ]]
	run --separate-stderr bin/restore --postgres --clickhouse shop
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"--postgres or --clickhouse"* ]]
	run --separate-stderr bin/restore --postgres Shop
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"is not a database name"* ]]
	run --separate-stderr bin/restore --postgres shop --as ""
	[ "$status" -ne 0 ]
}

@test "a Postgres database comes back under another name, and nothing live is touched" {
	run --separate-stderr bin/add-database --postgres shop
	[ "$status" -eq 0 ]
	superuser shop "CREATE TABLE orders (id int); INSERT INTO orders VALUES (1)"
	archive_now postgres
	superuser shop "INSERT INTO orders VALUES (2)"
	run --separate-stderr bin/restore --postgres shop --as drill </dev/null
	[ "$status" -eq 0 ]
	[[ "$output" == *"bin/remove-database --postgres drill drops it"* ]]
	[ "$(superuser drill "SELECT string_agg(id::text, ' ') FROM orders")" = "1" ]
	[ "$(superuser shop "SELECT string_agg(id::text, ' ' ORDER BY id) FROM orders")" = "1 2" ]
	run --separate-stderr bin/restore --postgres shop --as drill </dev/null
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"drill already exists"* ]]
}

@test "a Postgres database is replaced by its archive only once its name is typed, and its user still reaches it" {
	run --separate-stderr bin/add-database --postgres --session till
	[ "$status" -eq 0 ]
	url=$(printed DATABASE_URL)
	superuser till "CREATE TABLE sales (id int); INSERT INTO sales VALUES (1)"
	superuser till "GRANT SELECT ON sales TO till"
	archive_now postgres
	superuser till "DELETE FROM sales"
	run --separate-stderr bin/restore --postgres till <<<"no"
	[ "$status" -ne 0 ]
	[ "$(superuser till "SELECT count(*) FROM sales")" = "0" ]
	run --separate-stderr bin/restore --postgres till <<<"till"
	[ "$status" -eq 0 ]
	[ "$(superuser till "SELECT string_agg(id::text, ' ') FROM sales")" = "1" ]
	run connect "$url" "SELECT count(*) FROM sales"
	[ "$status" -eq 0 ]
	[ "$output" = "1" ]
	[ "$(superuser postgres "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = 'till'")" = "till" ]
}

@test "an older archive is picked by its snapshot" {
	run --separate-stderr bin/add-database --postgres ages
	[ "$status" -eq 0 ]
	superuser ages "CREATE TABLE era (n int); INSERT INTO era VALUES (1)"
	archive_now postgres
	sleep 1
	superuser ages "INSERT INTO era VALUES (2)"
	archive_now postgres
	older=$(docker exec archivist restic snapshots --json --path /postgres/databases/ages.dump | jq -r 'sort_by(.time) | .[0].short_id')
	run --separate-stderr bin/restore --postgres ages --as old --snapshot "$older" </dev/null
	[ "$status" -eq 0 ]
	[ "$(superuser old "SELECT string_agg(n::text, ' ') FROM era")" = "1" ]
}

@test "a Postgres database whose user is gone is refused, and nothing is changed" {
	run --separate-stderr bin/add-database --postgres lost
	[ "$status" -eq 0 ]
	archive_now postgres
	run --separate-stderr bin/remove-database --postgres lost <<<"lost"
	[ "$status" -eq 0 ]
	run --separate-stderr bin/restore --postgres lost <<<"lost"
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"bin/add-database --postgres lost"* ]]
	[ -z "$(superuser postgres "SELECT datname FROM pg_database WHERE datname = 'lost'")" ]
	run --separate-stderr bin/restore --postgres never --as drill_never </dev/null
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"no archive of never"* ]]
}

@test "a ClickHouse database comes back under another name, and nothing live is touched" {
	run --separate-stderr bin/add-database --clickhouse events
	[ "$status" -eq 0 ]
	admin "CREATE TABLE events.hits (id UInt8) ENGINE = MergeTree ORDER BY id"
	admin "INSERT INTO events.hits VALUES (1)"
	archive_now clickhouse
	admin "INSERT INTO events.hits VALUES (2)"
	run --separate-stderr bin/restore --clickhouse events --as drill </dev/null
	[ "$status" -eq 0 ]
	[[ "$output" == *"bin/remove-database --clickhouse drill drops it"* ]]
	[ "$(admin "SELECT groupArray(id) FROM drill.hits")" = "[1]" ]
	[ "$(admin "SELECT count() FROM events.hits")" = "2" ]
}

@test "a ClickHouse database is replaced by its archive only once its name is typed, and its user still reaches it" {
	run --separate-stderr bin/add-database --clickhouse clicks
	[ "$status" -eq 0 ]
	url=$(printed CLICKHOUSE_URL)
	admin "CREATE TABLE clicks.hits (id UInt8) ENGINE = MergeTree ORDER BY id"
	admin "INSERT INTO clicks.hits VALUES (1)"
	archive_now clickhouse
	admin "TRUNCATE TABLE clicks.hits"
	run --separate-stderr bin/restore --clickhouse clicks <<<"no"
	[ "$status" -ne 0 ]
	[ "$(admin "SELECT count() FROM clicks.hits")" = "0" ]
	run --separate-stderr bin/restore --clickhouse clicks <<<"clicks"
	[ "$status" -eq 0 ]
	[ "$(admin "SELECT groupArray(id) FROM clicks.hits")" = "[1]" ]
	run client "$url" "SELECT count() FROM hits"
	[ "$status" -eq 0 ]
	[ "$output" = "1" ]
}

@test "a ClickHouse database whose user is gone is refused, and nothing is changed" {
	run --separate-stderr bin/add-database --clickhouse gone
	[ "$status" -eq 0 ]
	archive_now clickhouse
	run --separate-stderr bin/remove-database --clickhouse gone <<<"gone"
	[ "$status" -eq 0 ]
	run --separate-stderr bin/restore --clickhouse gone <<<"gone"
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"bin/add-database --clickhouse gone"* ]]
	[ "$(admin "SELECT count() FROM system.databases WHERE name = 'gone'")" = "0" ]
}
