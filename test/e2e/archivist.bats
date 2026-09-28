bats_require_minimum_version 1.5.0

setup_file() {
	export project=userland-test
	export env_file="$BATS_FILE_TMPDIR/env"
	export stand_in="$BATS_FILE_TMPDIR/stand-in.yml"
	export master_key=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
	cat >"$env_file" <<'EOF'
ARCHIVIST_S3_BUCKET=archivist-test
ARCHIVIST_S3_REGION=us-east-1
ARCHIVIST_S3_ENDPOINT=http://moto:5000
ARCHIVIST_S3_ACCESS_KEY_ID=archivist-s3-key
ARCHIVIST_S3_SECRET_ACCESS_KEY=archivist-s3-secret
ARCHIVIST_KEY_PROVIDER=ssm
ARCHIVIST_KEY_NAME=/userland/archivist-key
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
	set_key "$master_key"
}

teardown_file() {
	compose down --volumes --remove-orphans
}

compose() {
	COMPOSE_FILE="compose.yml:compose/archivist.yml:$stand_in" docker compose --project-name "$project" --env-file "$env_file" "$@"
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

set_key() {
	aws "ssm.put_parameter(Name='/userland/archivist-key', Value='$1', Type='SecureString', Overwrite=True)"
}

objects() {
	aws 'print(s3.list_objects_v2(Bucket="archivist-test").get("KeyCount", 0))'
}

in_archivist() {
	docker exec archivist "$@"
}

says() {
	local waited=0
	until docker logs archivist 2>&1 | grep -q "$1"; do
		[ "$waited" -lt 60 ] || return 1
		sleep 1
		waited=$((waited + 1))
	done
}

@test "with no repository, the archivist refuses to start and writes nothing, and after init by hand it starts" {
	compose up --detach archivist
	says "there is no repository in the bucket"
	[ "$(objects)" -eq 0 ]
	run --separate-stderr compose run --rm archivist init
	[ "$status" -eq 0 ]
	[ "$(objects)" -gt 0 ]
	compose up --detach --wait --wait-timeout 90 --force-recreate archivist
	says "uploads what the dumpers leave"
}

@test "a foreign key is refused at start, and nothing is written" {
	before=$(objects)
	set_key fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
	compose up --detach --force-recreate archivist
	says "the master key does not open the repository"
	[ "$(objects)" -eq "$before" ]
	set_key "$master_key"
	compose up --detach --wait --wait-timeout 90 --force-recreate archivist
}

@test "an archive in the backup folder becomes a snapshot dated when the dumper made it, and leaves the folder" {
	in_archivist sh -c '
		mkdir -p /backups/postgres/20260101T030405Z/databases /backups/postgres/20260102T000000Z.writing
		echo shop >/backups/postgres/20260101T030405Z/databases/shop.dump
		echo globals >/backups/postgres/20260101T030405Z/globals.sql
		echo still >/backups/postgres/20260102T000000Z.writing/globals.sql
		echo "1 ok" >/backups/postgres/last-run'
	run --separate-stderr in_archivist archivist upload
	[ "$status" -eq 0 ]
	run --separate-stderr in_archivist restic snapshots --json --path /postgres/databases/shop.dump
	[ "$status" -eq 0 ]
	[ "$(jq -r 'length' <<<"$output")" = 1 ]
	[[ "$(jq -r '.[0].time' <<<"$output")" == 2026-01-01T03:04:05* ]]
	[ "$(jq -r '.[0].tags | join(" ")' <<<"$output")" = postgres ]
	[ "$(in_archivist restic dump --path /postgres/databases/shop.dump latest /postgres/databases/shop.dump)" = shop ]
	[ "$(in_archivist restic dump --path /postgres/globals.sql latest /postgres/globals.sql)" = globals ]
	run in_archivist test -e /backups/postgres/20260101T030405Z
	[ "$status" -ne 0 ]
	in_archivist test -f /backups/postgres/20260102T000000Z.writing/globals.sql
	in_archivist test -f /backups/postgres/last-run
	in_archivist archivist health
}

@test "an archive whose upload fails stays in the folder, and the archivist is unhealthy until an upload succeeds" {
	set_key fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
	in_archivist sh -c '
		mkdir -p /backups/clickhouse/20260103T000000Z/databases
		echo events >/backups/clickhouse/20260103T000000Z/databases/events.tar'
	run --separate-stderr in_archivist archivist upload
	[ "$status" -ne 0 ]
	in_archivist test -f /backups/clickhouse/20260103T000000Z/databases/events.tar
	run in_archivist archivist health
	[ "$status" -ne 0 ]
	set_key "$master_key"
	run --separate-stderr in_archivist archivist upload
	[ "$status" -eq 0 ]
	run in_archivist test -e /backups/clickhouse/20260103T000000Z
	[ "$status" -ne 0 ]
	in_archivist archivist health
	[ "$(in_archivist restic dump --path /clickhouse/databases/events.tar latest /clickhouse/databases/events.tar)" = events ]
}
