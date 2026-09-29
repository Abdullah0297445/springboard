bats_require_minimum_version 1.5.0

products=(postgres pgadmin clickhouse metabase n8n langfuse twenty windmill litellm archivist infisical)

setup() {
	env_file="$BATS_TEST_TMPDIR/env"
	cat >"$env_file" <<'EOF'
DOMAIN=example.test
SCHEME=https
SECURE_COOKIES=true
CERT_EMAIL=admin@example.test
DNS_PROVIDER=route53
POSTGRES_PASSWORD=postgres-password
PGBOUNCER_AUTH_PASSWORD=pgbouncer-auth-password
PGADMIN_DEFAULT_EMAIL=admin@example.test
PGADMIN_DEFAULT_PASSWORD=pgadmin-password
CLICKHOUSE_PASSWORD=clickhouse-password
METABASE_DB_PASSWORD=metabase-db-password
MB_ENCRYPTION_SECRET_KEY=metabase-encryption-key
N8N_DB_PASSWORD=n8n-db-password
N8N_ENCRYPTION_KEY=n8n-encryption-key
N8N_RUNNERS_AUTH_TOKEN=n8n-runners-auth-token
LANGFUSE_DB_PASSWORD=langfuse-db-password
LANGFUSE_CLICKHOUSE_PASSWORD=langfuse-clickhouse-password
LANGFUSE_SALT=langfuse-salt
LANGFUSE_ENCRYPTION_KEY=0000000000000000000000000000000000000000000000000000000000000000
LANGFUSE_NEXTAUTH_SECRET=langfuse-nextauth-secret
LANGFUSE_REDIS_PASSWORD=langfuse-redis-password
LANGFUSE_INIT_USER_EMAIL=admin@example.test
LANGFUSE_INIT_USER_PASSWORD=langfuse-password
LANGFUSE_S3_BUCKET=langfuse-bucket
LANGFUSE_S3_REGION=region-1
LANGFUSE_S3_ENDPOINT=https://s3.example.test
LANGFUSE_S3_ACCESS_KEY_ID=langfuse-s3-key
LANGFUSE_S3_SECRET_ACCESS_KEY=langfuse-s3-secret
TWENTY_DB_PASSWORD=twenty-db-password
TWENTY_REDIS_PASSWORD=twenty-redis-password
TWENTY_ENCRYPTION_KEY=twenty-encryption-key
TWENTY_S3_BUCKET=twenty-bucket
TWENTY_S3_REGION=region-1
TWENTY_S3_ENDPOINT=https://s3.example.test
TWENTY_S3_ACCESS_KEY_ID=twenty-s3-key
TWENTY_S3_SECRET_ACCESS_KEY=twenty-s3-secret
WINDMILL_DB_PASSWORD=windmill-db-password
LITELLM_DB_PASSWORD=litellm-db-password
LITELLM_MASTER_KEY=sk-litellm-master-key
LITELLM_SALT_KEY=litellm-salt-key
ARCHIVIST_S3_BUCKET=archivist-bucket
ARCHIVIST_S3_REGION=region-1
ARCHIVIST_S3_ENDPOINT=https://s3.example.test
ARCHIVIST_S3_ACCESS_KEY_ID=archivist-s3-key
ARCHIVIST_S3_SECRET_ACCESS_KEY=archivist-s3-secret
ARCHIVIST_KEY_PROVIDER=ssm
ARCHIVIST_KEY_NAME=/userland/archivist-key
ARCHIVIST_KEY_REGION=region-1
ARCHIVIST_KEY_ACCESS_KEY_ID=archivist-key-key
ARCHIVIST_KEY_SECRET_ACCESS_KEY=archivist-key-secret
INFISICAL_DB_PASSWORD=infisical-db-password
INFISICAL_ENCRYPTION_KEY=0123456789abcdef0123456789abcdef
INFISICAL_REDIS_PASSWORD=infisical-redis-password
INFISICAL_AUTH_SECRET=infisical-auth-secret
EOF
}

files() {
	local list=compose.yml product
	for product in "$@"; do
		list="$list:compose/$product.yml"
	done
	printf '%s' "$list"
}

compose() {
	docker compose --env-file "$env_file" "$@"
}

config_of() {
	COMPOSE_FILE=$(files "$@") compose config --format json
}

services() {
	jq -r '.services | keys | join(" ")' <<<"$output"
}

without() {
	sed -i "/^$1=/d" "$env_file"
}

published() {
	jq -r '[.services | to_entries[] | .key as $service | .value.ports // [] | .[] | "\($service) \(.host_ip // "*"):\(.published)->\(.target)"] | join(", ")' <<<"$output"
}

waited_on_without_healthcheck() {
	jq -r '.services as $all | [$all[] | .depends_on // {} | to_entries[] | select(.value.condition == "service_healthy") | .key] | unique | map(select($all[.].healthcheck.test == null)) | join(" ")' <<<"$output"
}

on_network() {
	jq -r --arg network "$1" '[.services | to_entries[] | select(.value.networks | has($network)) | .key] | join(" ")' <<<"$output"
}

@test "traefik runs alone" {
	run --separate-stderr config_of
	[ "$status" -eq 0 ]
	[ "$(services)" = "traefik" ]
}

@test "postgres runs with nothing else" {
	run --separate-stderr config_of postgres
	[ "$status" -eq 0 ]
	[ "$(services)" = "pgbouncer-session pgbouncer-transaction postgres-18 postgres-dumper traefik" ]
}

@test "pgadmin runs with postgres, and is refused without it" {
	run --separate-stderr config_of postgres pgadmin
	[ "$status" -eq 0 ]
	run config_of pgadmin
	[ "$status" -ne 0 ]
	[[ "$output" == *'service "pgadmin" depends on undefined service "postgres-18"'* ]]
}

@test "clickhouse runs with nothing else" {
	run --separate-stderr config_of clickhouse
	[ "$status" -eq 0 ]
	[ "$(services)" = "clickhouse clickhouse-dumper traefik" ]
}

@test "metabase runs with postgres, and is refused without it" {
	run --separate-stderr config_of postgres metabase
	[ "$status" -eq 0 ]
	run config_of metabase
	[ "$status" -ne 0 ]
	[[ "$output" == *'service "metabase" depends on undefined service "pgbouncer-transaction"'* ]]
}

@test "n8n runs with postgres, and is refused without it" {
	run --separate-stderr config_of postgres n8n
	[ "$status" -eq 0 ]
	run config_of n8n
	[ "$status" -ne 0 ]
	[[ "$output" == *'service "n8n" depends on undefined service "pgbouncer-transaction"'* ]]
}

@test "langfuse runs with postgres and clickhouse, and is refused without either" {
	run --separate-stderr config_of postgres clickhouse langfuse
	[ "$status" -eq 0 ]
	run config_of clickhouse langfuse
	[ "$status" -ne 0 ]
	[[ "$output" == *'depends on undefined service "pgbouncer-'* ]]
	run config_of postgres langfuse
	[ "$status" -ne 0 ]
	[[ "$output" == *'depends on undefined service "clickhouse"'* ]]
}

@test "twenty runs with postgres, and is refused without it" {
	run --separate-stderr config_of postgres twenty
	[ "$status" -eq 0 ]
	run config_of twenty
	[ "$status" -ne 0 ]
	[[ "$output" == *'depends on undefined service "pgbouncer-session"'* ]]
}

@test "windmill runs with postgres, and is refused without it" {
	run --separate-stderr config_of postgres windmill
	[ "$status" -eq 0 ]
	[ "$(services)" = "pgbouncer-session pgbouncer-transaction postgres-18 postgres-dumper traefik windmill-lsp windmill-server windmill-worker" ]
	[ "$(jq -r '.services["windmill-worker"].deploy.replicas' <<<"$output")" = 2 ]
	echo "WINDMILL_WORKER_REPLICAS=3" >>"$env_file"
	run --separate-stderr config_of postgres windmill
	[ "$(jq -r '.services["windmill-worker"].deploy.replicas' <<<"$output")" = 3 ]
	run config_of windmill
	[ "$status" -ne 0 ]
	[[ "$output" == *'depends on undefined service "pgbouncer-session"'* ]]
}

@test "litellm runs with postgres, and is refused without it" {
	run --separate-stderr config_of postgres litellm
	[ "$status" -eq 0 ]
	[ "$(services)" = "litellm pgbouncer-session pgbouncer-transaction postgres-18 postgres-dumper traefik" ]
	run config_of litellm
	[ "$status" -ne 0 ]
	[[ "$output" == *'service "litellm" depends on undefined service "pgbouncer-session"'* ]]
}

@test "infisical runs with postgres, and is refused without it" {
	run --separate-stderr config_of postgres infisical
	[ "$status" -eq 0 ]
	run config_of infisical
	[ "$status" -ne 0 ]
	[[ "$output" == *'service "infisical" depends on undefined service "pgbouncer-transaction"'* ]]
}

@test "infisical's address and cookies follow the visibility" {
	run --separate-stderr config_of postgres infisical public
	[ "$(jq -r '.services.infisical.environment.SITE_URL' <<<"$output")" = https://infisical.example.test ]
	[ "$(jq -r '.services.infisical.environment.HTTPS_ENABLED' <<<"$output")" = true ]
	sed -i 's/^DOMAIN=.*/DOMAIN=localhost/; s/^SCHEME=.*/SCHEME=http/; s/^SECURE_COOKIES=.*/SECURE_COOKIES=false/' "$env_file"
	run --separate-stderr config_of postgres infisical
	[ "$(jq -r '.services.infisical.environment.SITE_URL' <<<"$output")" = http://infisical.localhost ]
	[ "$(jq -r '.services.infisical.environment.HTTPS_ENABLED' <<<"$output")" = false ]
}

@test "the archivist runs with nothing else, and reads no datastore's password" {
	without POSTGRES_PASSWORD
	without CLICKHOUSE_PASSWORD
	run --separate-stderr config_of archivist
	[ "$status" -eq 0 ]
	[ "$(services)" = "archivist traefik" ]
}

@test "the archivist joins no datastore's network, and shares only the backup folder with the dumpers" {
	run --separate-stderr config_of "${products[@]}"
	[ "$(jq -r '.services.archivist.networks | keys | join(" ")' <<<"$output")" = "default" ]
	[ "$(jq -r '[.services | to_entries[] | select(any(.value.volumes[]?; .source == "backups")) | .key] | join(" ")' <<<"$output")" = "archivist clickhouse clickhouse-dumper postgres-dumper" ]
}

@test "every product runs together, in local" {
	run --separate-stderr config_of "${products[@]}"
	[ "$status" -eq 0 ]
}

@test "every product runs together, in public" {
	run --separate-stderr config_of "${products[@]}" public
	[ "$status" -eq 0 ]
}

@test "DOMAIN, SCHEME and SECURE_COOKIES are required" {
	local variable
	for variable in DOMAIN SCHEME SECURE_COOKIES; do
		setup
		without "$variable"
		run config_of "${products[@]}"
		[ "$status" -ne 0 ]
		[[ "$output" == *"required variable $variable is missing a value"* ]]
	done
}

@test "public needs CERT_EMAIL and DNS_PROVIDER" {
	local variable
	for variable in CERT_EMAIL DNS_PROVIDER; do
		setup
		without "$variable"
		run config_of public
		[ "$status" -ne 0 ]
		[[ "$output" == *"required variable $variable is missing a value"* ]]
	done
}

@test "in local, only traefik publishes a port, and only 80" {
	run --separate-stderr config_of "${products[@]}"
	[ "$(published)" = "traefik *:80->80" ]
}

@test "in public, only traefik publishes ports, 80 and 443" {
	run --separate-stderr config_of "${products[@]}" public
	[ "$(published)" = "traefik *:80->80, traefik *:443->443" ]
}

@test "only traefik mounts the docker socket, and no container is privileged" {
	run --separate-stderr config_of "${products[@]}" public
	[ "$status" -eq 0 ]
	[ "$(jq -r '[.services | to_entries[] | select(any(.value.volumes[]?; (.source // "") | endswith("docker.sock"))) | .key] | join(" ")' <<<"$output")" = "traefik" ]
	[ "$(jq -r '[.services | to_entries[] | select(.value.privileged == true) | .key] | join(" ")' <<<"$output")" = "" ]
}

@test "every container another waits on has a healthcheck" {
	run --separate-stderr config_of "${products[@]}"
	[ "$status" -eq 0 ]
	[ "$(waited_on_without_healthcheck)" = "" ]
}

@test "consumers join userland_postgres, userland_clickhouse and userland_traefik, and reach Postgres only through a door" {
	run --separate-stderr config_of "${products[@]}"
	[ "$(jq -r '.networks.postgres.name' <<<"$output")" = userland_postgres ]
	[ "$(jq -r '.networks.clickhouse.name' <<<"$output")" = userland_clickhouse ]
	[ "$(jq -r '.networks.traefik.name' <<<"$output")" = userland_traefik ]
	[ "$(on_network postgres-server)" = "pgadmin pgbouncer-session pgbouncer-transaction postgres-18 postgres-dumper" ]
	[[ " $(on_network postgres) " != *" postgres-18 "* ]]
}

@test "every container is named as its service, unless its service runs replicas, and takes a memory limit from its own variable" {
	run --separate-stderr config_of "${products[@]}" public
	local service
	for service in $(services); do
		local variable
		variable="$(tr 'a-z-' 'A-Z_' <<<"$service")_MEM_LIMIT"
		echo "$variable=64m" >>"$env_file"
	done
	run --separate-stderr config_of "${products[@]}" public
	[ "$status" -eq 0 ]
	[ "$(jq -r '[.services | to_entries[] | select(.value.deploy.replicas == null and .value.container_name != .key) | .key] | join(" ")' <<<"$output")" = "" ]
	[ "$(jq -r '[.services | to_entries[] | select(.value.mem_limit != "67108864") | .key] | join(" ")' <<<"$output")" = "" ]
}

@test "the README names every variable" {
	run --separate-stderr env COMPOSE_FILE="$(files "${products[@]}" public)" docker compose --env-file "$env_file" config --variables --format json
	[ "$status" -eq 0 ]
	local variable missing=""
	for variable in $(jq -r 'keys[]' <<<"$output"); do
		grep -q "\`$variable\`" README.md || missing="$missing $variable"
	done
	echo "not in the README:$missing"
	[ -z "$missing" ]
}

@test "every file in compose/ is a product the tests know, or public.yml" {
	local expected actual
	expected=$(printf '%s.yml\n' "${products[@]}" public | sort | tr '\n' ' ')
	actual=$(cd compose && printf '%s\n' *.yml | sort | tr '\n' ' ')
	[ "$actual" = "$expected" ]
}
