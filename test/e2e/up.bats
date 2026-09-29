bats_require_minimum_version 1.5.0

setup_file() {
	export project=userland-test
	export COMPOSE_PROJECT_NAME=$project
	export COMPOSE_ENV_FILES="$BATS_FILE_TMPDIR/env"
	export stand_in="$BATS_FILE_TMPDIR/stand-in.yml"
	export archivist_stand_in="$BATS_FILE_TMPDIR/archivist-stand-in.yml"
	export product="$BATS_FILE_TMPDIR/product.yml"
	export floor="compose.yml:compose/postgres.yml:compose/archivist.yml:$archivist_stand_in:$stand_in"
	export full="$floor:compose/infisical.yml:compose/clickhouse.yml:$product"
	cat >"$stand_in" <<'EOF'
services:
  moto:
    image: motoserver/moto:5.2.3
    container_name: moto
EOF
	cat >"$archivist_stand_in" <<'EOF'
services:
  archivist:
    environment:
      AWS_ENDPOINT_URL_SSM: http://moto:5000
EOF
	cat >"$product" <<'EOF'
services:
  stand-in:
    image: alpine:3.22
    container_name: stand-in
    command: ["tail", "-f", "/dev/null"]
    environment:
      STAND_IN_VALUE: ${STAND_IN_VALUE:-}
EOF
	cat >"$BATS_FILE_TMPDIR/recovery-keys" <<'EOF'
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
POSTGRES_PASSWORD=postgres-password
PGBOUNCER_AUTH_PASSWORD=pgbouncer-auth-password
INFISICAL_REDIS_PASSWORD=infisical-redis-password
INFISICAL_AUTH_SECRET=infisical-auth-secret
EOF
	cat >"$BATS_FILE_TMPDIR/settings" <<'EOF'
DOMAIN=localhost
SCHEME=http
SECURE_COOKIES=false
INFISICAL_ENCRYPTION_KEY=0123456789abcdef0123456789abcdef
EOF
	{
		cat "$BATS_FILE_TMPDIR/recovery-keys" "$BATS_FILE_TMPDIR/settings"
		echo "INFISICAL_DB_PASSWORD=unused"
		echo "CLICKHOUSE_PASSWORD=unused"
	} >"$BATS_FILE_TMPDIR/every.env"
	every down --volumes --remove-orphans

	{
		echo "COMPOSE_FILE=$floor"
		cat "$BATS_FILE_TMPDIR/recovery-keys" "$BATS_FILE_TMPDIR/settings"
	} >"$COMPOSE_ENV_FILES"
	docker compose up --detach moto
	local waited=0
	until aws 's3.list_buckets()' >/dev/null 2>&1 || [ "$waited" -ge 30 ]; do
		sleep 1
		waited=$((waited + 1))
	done
	aws 's3.create_bucket(Bucket="archivist-test")'
	aws "ssm.put_parameter(Name='/userland/archivist-key', Value='0123456789abcdef0123456789abcdef', Type='SecureString')"
	docker compose run --rm archivist init
	docker compose up --detach --wait --wait-timeout 120 postgres-18 pgbouncer-transaction
	local made
	made=$(bin/add-database --postgres infisical)
	echo "INFISICAL_DB_PASSWORD=$(sed -n 's/^  INFISICAL_DB_PASSWORD=//p' <<<"$made")" >>"$COMPOSE_ENV_FILES"
	sed -i "s|^COMPOSE_FILE=.*|COMPOSE_FILE=$floor:compose/infisical.yml|" "$COMPOSE_ENV_FILES"
	docker compose up --detach --wait --wait-timeout 300 infisical

	local admin organization project_id identity_id
	admin=$(cli bootstrap --email admin@example.test --password admin-password-0123456789 --organization userland)
	jq -r .identity.credentials.token <<<"$admin" >"$BATS_FILE_TMPDIR/admin-token"
	organization=$(jq -r .organization.id <<<"$admin")
	project_id=$(as_admin POST /api/v1/projects '{"projectName":"userland","slug":"userland","type":"secret-manager"}' | jq -r .project.id)
	echo "$project_id" >"$BATS_FILE_TMPDIR/project-id"
	identity_id=$(as_admin POST /api/v1/identities "{\"name\":\"userland-helper\",\"organizationId\":\"$organization\",\"role\":\"member\"}" | jq -r .identity.id)
	as_admin POST "/api/v1/projects/$project_id/memberships/identities/$identity_id" '{"role":"member"}' >/dev/null
	{
		echo "INFISICAL_CLIENT_ID=$(as_admin POST "/api/v1/auth/universal-auth/identities/$identity_id" '{}' | jq -r .identityUniversalAuth.clientId)"
		echo "INFISICAL_CLIENT_SECRET=$(as_admin POST "/api/v1/auth/universal-auth/identities/$identity_id/client-secrets" '{}' | jq -r .clientSecret)"
	} | tee -a "$COMPOSE_ENV_FILES" >"$BATS_FILE_TMPDIR/login"
}

teardown_file() {
	every down --volumes --remove-orphans
}

every() {
	COMPOSE_ENV_FILES="$BATS_FILE_TMPDIR/every.env" COMPOSE_FILE="$full" docker compose "$@"
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

cli() {
	docker run --rm --network container:infisical -e INFISICAL_TOKEN \
		infisical/cli:0.43.136 "$@" --domain http://127.0.0.1:8080 --silent
}

as_admin() {
	docker exec infisical curl -sS -X "$1" -H "Content-Type: application/json" \
		-H "Authorization: Bearer $(cat "$BATS_FILE_TMPDIR/admin-token")" --data "$3" "http://127.0.0.1:8080$2"
}

upload() {
	INFISICAL_TOKEN=$(cat "$BATS_FILE_TMPDIR/admin-token") docker run --rm -i --network container:infisical -e INFISICAL_TOKEN \
		--entrypoint sh infisical/cli:0.43.136 -c "cat >/tmp/lines && exec infisical secrets set --file /tmp/lines \
		--projectId $(cat "$BATS_FILE_TMPDIR/project-id") --env prod --domain http://127.0.0.1:8080 --silent" >/dev/null
}

change() {
	as_admin PATCH "/api/v4/secrets/$1" "$(jq -n --arg project "$(cat "$BATS_FILE_TMPDIR/project-id")" --arg value "$2" \
		'{projectId: $project, environment: "prod", secretPath: "/", secretValue: $value}')" >/dev/null
}

printed() {
	sed -n "s/^  $1=//p" <<<"$output"
}

connect() {
	docker run --rm --network "${project}_postgres" pgvector/pgvector:pg18-trixie \
		psql "$1" -v ON_ERROR_STOP=1 -X -q -tA -c "$2"
}

client() {
	docker run --rm --network "${project}_clickhouse" clickhouse/clickhouse-server:26.8 \
		clickhouse-client "$1" --query "$2"
}

databases() {
	docker exec postgres-18 psql -X -tA -U postgres -d postgres -c "SELECT count(*) FROM pg_database WHERE datname NOT IN ('postgres', 'template0', 'template1')"
}

fingerprint() {
	sha256sum "$COMPOSE_ENV_FILES" | cut -d ' ' -f 1
}

containers() {
	docker ps --all --quiet --filter "label=com.docker.compose.project=$project" |
		xargs docker inspect --format '{{.Name}} {{.Id}} {{.State.StartedAt}}' | sort
}

@test "it runs from the root of userland, on one .env, and says what to do without one" {
	COMPOSE_ENV_FILES="$BATS_FILE_TMPDIR/none" run --separate-stderr bin/up
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"there is no $BATS_FILE_TMPDIR/none. On a new host, write the first one, and run bin/up --rebuild."* ]]
	COMPOSE_ENV_FILES="$COMPOSE_ENV_FILES,$BATS_FILE_TMPDIR/other" run --separate-stderr bin/up
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"COMPOSE_ENV_FILES names more than one file"* ]]
	cd test
	run --separate-stderr ../bin/up
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"run bin/up from the root of userland"* ]]
}

@test "an empty project stops it, and nothing is changed" {
	local before
	before=$(fingerprint)
	run --separate-stderr bin/up
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"the project userland holds no line in its environment prod"* ]]
	[ "$(fingerprint)" = "$before" ]
	[ -z "$(docker ps --quiet --filter name=^archivist\$)" ]
}

@test "it writes .env from userland's project, readable only by you, and starts what its COMPOSE_FILE names" {
	sed "s|^COMPOSE_FILE=.*|COMPOSE_FILE=$full|" "$COMPOSE_ENV_FILES" >"$BATS_FILE_TMPDIR/uploaded"
	printf 'CLICKHOUSE_PASSWORD=clickhouse-password\nSTAND_IN_VALUE=plain\n' >>"$BATS_FILE_TMPDIR/uploaded"
	upload <"$BATS_FILE_TMPDIR/uploaded"
	run --separate-stderr bin/up
	[ "$status" -eq 0 ]
	[ "$(cut -d = -f 1 "$COMPOSE_ENV_FILES")" = "$(cut -d = -f 1 "$BATS_FILE_TMPDIR/uploaded" | sort)" ]
	grep -qx "COMPOSE_FILE=\"$full\"" "$COMPOSE_ENV_FILES"
	grep -qx 'STAND_IN_VALUE="plain"' "$COMPOSE_ENV_FILES"
	[ "$(stat -c %a "$COMPOSE_ENV_FILES")" = 600 ]
	[ "$(docker exec stand-in printenv STAND_IN_VALUE)" = plain ]
	[ "$(docker inspect --format '{{.State.Status}}' archivist clickhouse)" = "running
running" ]
}

@test "it ends by naming each dumper that waits for its intent" {
	docker exec clickhouse-dumper dumper now >/dev/null
	run --separate-stderr bin/up
	[ "$status" -eq 0 ]
	[[ "$output" == *"postgres-dumper: waits for its intent. On the host that writes to the bucket, run docker exec postgres-dumper dumper now."* ]]
	[[ "$output" != *"clickhouse-dumper:"* ]]
}

@test "any value reaches a container unchanged" {
	local value
	value=$'a$b$$c"d\\e #f \'g ${DOMAIN}\nh'
	change STAND_IN_VALUE "$value"
	run --separate-stderr bin/up
	[ "$status" -eq 0 ]
	[ "$(docker exec stand-in printenv STAND_IN_VALUE)" = "$value" ]
}

@test "a second run changes nothing" {
	local file running
	file=$(fingerprint)
	running=$(containers)
	run --separate-stderr bin/up
	[ "$status" -eq 0 ]
	[ "$(fingerprint)" = "$file" ]
	[ "$(containers)" = "$running" ]
}

@test "a COMPOSE_FILE without Postgres, the archivist or Infisical is refused, and nothing is changed" {
	local before dropped files
	before=$(fingerprint)
	for dropped in postgres archivist infisical; do
		files=${full/":compose/$dropped.yml"/}
		change COMPOSE_FILE "${files/":$archivist_stand_in"/}"
		run --separate-stderr bin/up
		[ "$status" -eq 1 ]
		[[ "$stderr" == *"Nothing was changed."* ]]
		[ "$(fingerprint)" = "$before" ]
	done
	[[ "$stderr" == *"compose/infisical.yml"* ]]
	change COMPOSE_FILE "${full/":compose/archivist.yml:$archivist_stand_in"/}"
	run --separate-stderr bin/up
	[[ "$stderr" == *"compose/archivist.yml"* ]]
	change COMPOSE_FILE "$full"
}

@test "a wrong client secret stops it, and nothing is changed" {
	local before
	cp "$COMPOSE_ENV_FILES" "$BATS_FILE_TMPDIR/kept"
	sed -i 's/^INFISICAL_CLIENT_SECRET=.*/INFISICAL_CLIENT_SECRET="0000000000000000000000000000000000000000000000000000000000000000"/' "$COMPOSE_ENV_FILES"
	before=$(fingerprint)
	run --separate-stderr bin/up
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"could not log in to Infisical with INFISICAL_CLIENT_ID and INFISICAL_CLIENT_SECRET"* ]]
	[ "$(fingerprint)" = "$before" ]
	cp "$BATS_FILE_TMPDIR/kept" "$COMPOSE_ENV_FILES"
}

@test "an empty Postgres is refused, and names --rebuild, and nothing is changed" {
	run --separate-stderr bin/add-database --postgres shop
	printed DATABASE_URL >"$BATS_FILE_TMPDIR/shop"
	connect "$(cat "$BATS_FILE_TMPDIR/shop")" "CREATE TABLE orders (id int); INSERT INTO orders VALUES (1)"
	run --separate-stderr bin/add-database --clickhouse events
	printed CLICKHOUSE_URL >"$BATS_FILE_TMPDIR/events"
	client "$(cat "$BATS_FILE_TMPDIR/events")" "CREATE TABLE hits (id UInt8) ENGINE = MergeTree ORDER BY id"
	client "$(cat "$BATS_FILE_TMPDIR/events")" "INSERT INTO hits VALUES (2)"
	docker exec postgres-dumper dumper now >/dev/null
	docker exec clickhouse-dumper dumper now >/dev/null
	docker exec archivist archivist upload >/dev/null

	every config --services | grep -vx moto | xargs docker compose rm --stop --force
	docker volume ls --quiet --filter "label=com.docker.compose.project=$project" | xargs docker volume rm
	{
		echo "COMPOSE_FILE=$floor:compose/infisical.yml"
		cat "$BATS_FILE_TMPDIR/recovery-keys" "$BATS_FILE_TMPDIR/settings" "$BATS_FILE_TMPDIR/login"
		grep '^INFISICAL_DB_PASSWORD=' "$BATS_FILE_TMPDIR/kept"
	} >"$COMPOSE_ENV_FILES"
	cp "$COMPOSE_ENV_FILES" "$BATS_FILE_TMPDIR/first"

	run --separate-stderr bin/up
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"bin/up --rebuild"* ]]
	[ "$(fingerprint)" = "$(sha256sum "$BATS_FILE_TMPDIR/first" | cut -d ' ' -f 1)" ]
	[ "$(databases)" = 0 ]
	[ -z "$(docker ps --quiet --filter name=^infisical\$)" ]
}

@test "--rebuild refuses a first .env without a recovery key, and starts nothing" {
	run --separate-stderr bin/up --clean
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"usage: bin/up [--rebuild]"* ]]
	grep -v '^POSTGRES_PASSWORD=\|^INFISICAL_CLIENT_SECRET=' "$BATS_FILE_TMPDIR/first" >"$COMPOSE_ENV_FILES"
	run --separate-stderr bin/up --rebuild
	cp "$BATS_FILE_TMPDIR/first" "$COMPOSE_ENV_FILES"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"POSTGRES_PASSWORD INFISICAL_CLIENT_SECRET"* ]]
	[ -z "$(docker ps --quiet --filter name=^archivist\$)" ]
	[ -z "$(docker ps --quiet --filter name=^infisical\$)" ]
	[ "$(databases)" = 0 ]
}

@test "--rebuild brings a new host back from the first .env alone" {
	run --separate-stderr bin/up --rebuild
	[ "$status" -eq 0 ]
	[[ "$output" == *"postgres-dumper: waits for its intent. On the host that writes to the bucket, run docker exec postgres-dumper dumper now."* ]]
	[[ "$output" == *"clickhouse-dumper: waits for its intent. On the host that writes to the bucket, run docker exec clickhouse-dumper dumper now."* ]]
	[ "$(connect "$(cat "$BATS_FILE_TMPDIR/shop")" "SELECT id FROM orders")" = 1 ]
	[ "$(client "$(cat "$BATS_FILE_TMPDIR/events")" "SELECT id FROM hits")" = 2 ]
	grep -qx "COMPOSE_FILE=\"$full\"" "$COMPOSE_ENV_FILES"
	[ "$(stat -c %a "$COMPOSE_ENV_FILES")" = 600 ]
	[ "$(docker exec stand-in printenv STAND_IN_VALUE)" = $'a$b$$c"d\\e #f \'g ${DOMAIN}\nh' ]
}

@test "a second --rebuild changes nothing" {
	local file running
	file=$(fingerprint)
	running=$(containers)
	run --separate-stderr bin/up --rebuild
	[ "$status" -eq 0 ]
	[ "$(fingerprint)" = "$file" ]
	[ "$(containers)" = "$running" ]
	[ "$(connect "$(cat "$BATS_FILE_TMPDIR/shop")" "SELECT count(*) FROM orders")" = 1 ]
}
