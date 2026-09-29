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
	compose up --detach --wait postgres-18
	compose up --detach postgres-dumper
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

@test "on its first start, a dumper archives nothing, and is unhealthy until it has its intent" {
	clock_at $((slot - 3600))
	docker restart postgres-dumper >/dev/null
	says "postgres-dumper: waits for its intent. On the host that writes to the bucket, run docker exec postgres-dumper dumper now."
	sleep 5
	[ "$(runs | wc -l)" -eq 0 ]
	run in_dumper dumper health
	[ "$status" -eq 1 ]
	[ "$output" = "waits for its intent. On the host that writes to the bucket, run docker exec postgres-dumper dumper now." ]
}

@test "the first dumper now gives the intent: it archives at once, and the dumper is healthy" {
	run --separate-stderr in_dumper dumper now
	[ "$status" -eq 0 ]
	[ "$(runs | wc -l)" -eq 1 ]
	[[ "$output" == *"postgres-dumper: has its intent, so this host writes to the bucket. It runs every 24 hours from 00:00 UTC; the next is at $(in_dumper /usr/bin/date -u -d "@$slot" '+%Y-%m-%d %H:%M UTC')" ]]
	in_dumper dumper health
}

@test "with the clock an hour short of a slot, nothing runs" {
	docker restart postgres-dumper >/dev/null
	says "the next is at $(in_dumper /usr/bin/date -u -d "@$slot" '+%Y-%m-%d %H:%M UTC')"
	sleep 5
	[ "$(runs | wc -l)" -eq 1 ]
}

@test "after the clock jumps past the slot, as a suspended host's does when it wakes, the slot runs within a minute" {
	clock_at "$slot"
	local waited=0
	while [ "$(runs | wc -l)" -eq 1 ] && [ "$waited" -lt 90 ]; do
		sleep 1
		waited=$((waited + 1))
	done
	[ "$(runs | wc -l)" -eq 2 ]
}

@test "the slot runs only once" {
	before=$(runs)
	[ -n "$before" ]
	docker restart postgres-dumper >/dev/null
	sleep 5
	[ "$(runs)" = "$before" ]
}
