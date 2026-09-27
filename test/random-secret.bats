bats_require_minimum_version 1.5.0

@test "a secret is 64 hex characters unless told" {
	run --separate-stderr bin/random-secret
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9a-f]{64}$ ]]
}

@test "a secret is exactly as long as told, odd lengths included" {
	run --separate-stderr bin/random-secret 32
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9a-f]{32}$ ]]
	run --separate-stderr bin/random-secret 7
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9a-f]{7}$ ]]
}

@test "a length that is not a whole number is refused, and nothing is printed" {
	local length
	for length in 0 -3 abc 3.5 "" 08; do
		run --separate-stderr bin/random-secret "$length"
		[ "$status" -eq 1 ]
		[ -z "$output" ]
		[[ "$stderr" == *"usage: bin/random-secret [LENGTH]"* ]]
	done
	run --separate-stderr bin/random-secret 32 64
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}
