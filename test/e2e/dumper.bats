bats_require_minimum_version 1.5.0

setup_file() {
	export project=userland-test
	export env_file="$BATS_FILE_TMPDIR/env"
	export stand_in="$BATS_FILE_TMPDIR/stand-in.yml"
	cat >"$env_file" <<'EOF'
POSTGRES_PASSWORD=postgres-password
PGBOUNCER_AUTH_PASSWORD=pgbouncer-auth-password
EOF
	cat >"$stand_in" <<'EOF'
services:
  postgres-dumper:
    volumes:
      - ./test/e2e/stand-in/date:/usr/local/bin/date:ro
EOF
	compose down --volumes --remove-orphans
	compose up --detach --wait postgres-18 postgres-dumper
	export day=86400
	slot=$((($(in_dumper /usr/bin/date +%s) / day + 10) * day))
	export slot
}

teardown_file() {
	compose down --volumes --remove-orphans
}

compose() {
	COMPOSE_FILE="compose.yml:compose/postgres.yml:$stand_in" docker compose --project-name "$project" --env-file "$env_file" "$@"
}

in_dumper() {
	docker exec postgres-dumper "$@"
}

clock_at() {
	in_dumper sh -c "echo \$(($1 - \$(/usr/bin/date +%s))) >/tmp/ahead"
}

runs() {
	in_dumper ls /backups/postgres | grep -x '[0-9]\{8\}T[0-9]\{6\}Z' || true
}

says() {
	local waited=0
	until docker logs postgres-dumper 2>&1 | grep -q "$1"; do
		[ "$waited" -lt 30 ] || return 1
		sleep 1
		waited=$((waited + 1))
	done
}

@test "with the clock an hour short of a slot, nothing runs" {
	clock_at $((slot - 3600))
	in_dumper sh -c "echo '$((slot - day)) ok' >/backups/postgres/last-run"
	docker restart postgres-dumper >/dev/null
	says "the next is at $(in_dumper /usr/bin/date -u -d "@$slot" '+%Y-%m-%d %H:%M UTC')"
	sleep 5
	[ "$(runs | wc -l)" -eq 0 ]
}

@test "after the clock jumps past the slot, as a suspended host's does when it wakes, the slot runs within a minute" {
	clock_at "$slot"
	local waited=0
	while [ "$(runs | wc -l)" -eq 0 ] && [ "$waited" -lt 90 ]; do
		sleep 1
		waited=$((waited + 1))
	done
	[ "$(runs | wc -l)" -eq 1 ]
}

@test "the slot runs only once" {
	before=$(runs)
	[ -n "$before" ]
	docker restart postgres-dumper >/dev/null
	sleep 5
	[ "$(runs)" = "$before" ]
}
