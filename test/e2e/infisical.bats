bats_require_minimum_version 1.5.0

setup_file() {
	export project=userland-test
	export env_file="$BATS_FILE_TMPDIR/env"
	export stand_in="$BATS_FILE_TMPDIR/stand-in.yml"
	cat >"$env_file" <<'EOF'
DOMAIN=localhost
SCHEME=http
SECURE_COOKIES=false
POSTGRES_PASSWORD=postgres-password
PGBOUNCER_AUTH_PASSWORD=pgbouncer-auth-password
INFISICAL_ENCRYPTION_KEY=0123456789abcdef0123456789abcdef
INFISICAL_REDIS_PASSWORD=infisical-redis-password
INFISICAL_AUTH_SECRET=infisical-auth-secret
EOF
	cat >"$stand_in" <<EOF
services:
  infisical:
    labels:
      - traefik.docker.network=${project}_traefik
EOF
	export files=compose.yml:compose/postgres.yml
	compose down --volumes --remove-orphans
	compose up --detach --wait postgres-18 pgbouncer-transaction
	local made
	made=$(bin/add-database --postgres infisical)
	echo "INFISICAL_DB_PASSWORD=$(sed -n 's/^  INFISICAL_DB_PASSWORD=//p' <<<"$made")" >>"$env_file"
	export files="$files:compose/infisical.yml:$stand_in"
}

teardown_file() {
	compose down --volumes --remove-orphans
}

compose() {
	COMPOSE_FILE=$files docker compose --project-name "$project" --env-file "$env_file" "$@"
}

through_traefik() {
	docker exec traefik wget -qO- --header "Host: infisical.localhost" "http://127.0.0.1$1"
}

admin_config() {
	through_traefik /api/v1/admin/config
}

cli() {
	docker run --rm --network "${project}_infisical" -e INFISICAL_TOKEN -e INFISICAL_UNIVERSAL_AUTH_CLIENT_ID -e INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET \
		infisical/cli:0.43.136 "$@" --domain http://infisical:8080 --silent
}

post() {
	local path=$1
	shift
	docker exec infisical curl -sS -X POST -H "Content-Type: application/json" "$@" "http://127.0.0.1:8080$path"
}

as_admin() {
	post "$1" -H "Authorization: Bearer $(cat "$BATS_FILE_TMPDIR/admin-token")" --data "$2"
}

@test "Infisical comes up healthy on a database of its own, and traefik answers for it" {
	run --separate-stderr compose up --detach --wait --wait-timeout 300 traefik infisical
	[ "$status" -eq 0 ]
	local waited=0
	until through_traefik /api/status 2>/dev/null | grep -q '"message":"Ok"'; do
		[ "$waited" -lt 60 ] || return 1
		sleep 1
		waited=$((waited + 1))
	done
}

@test "bootstrap makes the first admin without a browser, and sign-up is then closed" {
	[ "$(admin_config | jq -r .config.initialized)" = false ]
	[ "$(admin_config | jq -r .config.allowSignUp)" = true ]
	run --separate-stderr cli bootstrap --email admin@example.test --password admin-password-0123456789 --organization userland
	[ "$status" -eq 0 ]
	[ "$(jq -r .user.superAdmin <<<"$output")" = true ]
	jq -r .identity.credentials.token <<<"$output" >"$BATS_FILE_TMPDIR/admin-token"
	jq -r .organization.id <<<"$output" >"$BATS_FILE_TMPDIR/organization"
	[ "$(admin_config | jq -r .config.initialized)" = true ]
	[ "$(admin_config | jq -r .config.allowSignUp)" = false ]
	run post /api/v1/admin/bootstrap --data '{"email":"other@example.test","password":"other-password-0123456789","organization":"other"}'
	[[ "$output" == *'"message":"Instance has already been set up"'* ]]
}

@test "a machine identity logs in and reads a secret" {
	local project_id identity_id client_id client_secret token
	project_id=$(as_admin /api/v1/projects '{"projectName":"userland","slug":"userland","type":"secret-manager","shouldCreateDefaultEnvs":false}' | jq -r .project.id)
	as_admin "/api/v1/projects/$project_id/environments" '{"name":"Host","slug":"host"}' >/dev/null
	INFISICAL_TOKEN=$(cat "$BATS_FILE_TMPDIR/admin-token") cli secrets set GREETING=hello --projectId "$project_id" --env host >/dev/null
	identity_id=$(as_admin /api/v1/identities "{\"name\":\"reader\",\"organizationId\":\"$(cat "$BATS_FILE_TMPDIR/organization")\",\"role\":\"no-access\"}" | jq -r .identity.id)
	client_id=$(as_admin "/api/v1/auth/universal-auth/identities/$identity_id" '{}' | jq -r .identityUniversalAuth.clientId)
	client_secret=$(as_admin "/api/v1/auth/universal-auth/identities/$identity_id/client-secrets" '{}' | jq -r .clientSecret)
	as_admin "/api/v1/projects/$project_id/memberships/identities/$identity_id" '{"role":"viewer"}' >/dev/null
	token=$(INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=$client_id INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=$client_secret cli login --method=universal-auth --plain)
	INFISICAL_TOKEN=$token run --separate-stderr cli export --projectId "$project_id" --env host --format dotenv
	[ "$status" -eq 0 ]
	[ "$output" = "GREETING='hello'" ]
}
