#!/usr/bin/env bash
# Check an image built from encore/docker/Dockerfile:
#
#   encore/docker/check.sh <image>
#
# The image runs as a server, with the official image's entrypoint, and must
# report the version in its VERSION file, so that it runs Encore's build and
# not the official one. In it, a database with a table and a materialized
# view is cloned with CREATE DATABASE ... CLONE AS, the server is branched
# with SYSTEM BRANCH into its data volume, and `clickhouse local` reads the
# branch.
set -euo pipefail

usage() {
	sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
	exit 2
}

[ $# -eq 1 ] || usage
image=$1

container=$(docker run --detach --ulimit nofile=262144:262144 "$image")
cleanup() {
	docker rm --force "$container" >/dev/null
}
trap cleanup EXIT

# As the server's user, which owns the data: clickhouse local refuses data
# that belongs to another user.
in_container() {
	docker exec --user clickhouse "$container" "$@" </dev/null
}

query() {
	in_container clickhouse-client --multiquery --query "$1"
}

for _ in $(seq 1 60); do
	query "SELECT 1" >/dev/null 2>&1 && break
	if [ "$(docker inspect --format '{{.State.Running}}' "$container")" != true ]; then
		echo "the server exited:" >&2
		docker logs "$container" >&2
		exit 1
	fi
	sleep 1
done
query "SELECT 1" >/dev/null

expect() {
	local what=$1 want=$2 got=$3
	if [ "$got" != "$want" ]; then
		printf 'check failed: %s\nwant:\n%s\ngot:\n%s\n' "$what" "$want" "$got" >&2
		exit 1
	fi
}

want_version=$(in_container sed -n 's/^clickhouse_version=//p' /usr/share/doc/clickhouse-encore/VERSION)
expect "the server's version" "$want_version" "$(query "SELECT version()")"

got=$(query "
	CREATE DATABASE app;
	CREATE TABLE app.t (k UInt64) ENGINE = MergeTree ORDER BY k;
	INSERT INTO app.t SELECT number FROM numbers(1000);
	CREATE MATERIALIZED VIEW app.mv ENGINE = SummingMergeTree ORDER BY tuple() AS SELECT count() AS c FROM app.t;
	INSERT INTO app.t VALUES (1000);
	CREATE DATABASE clone CLONE AS app;
	INSERT INTO clone.t VALUES (1001);
	SELECT 'app', count(), sum(k), (SELECT sum(c) FROM app.mv) FROM app.t;
	SELECT 'clone', count(), sum(k), (SELECT sum(c) FROM clone.mv) FROM clone.t;
	SYSTEM BRANCH TO '/var/lib/clickhouse/user_files/branch';
	INSERT INTO app.t VALUES (2000);
")
expect "CREATE DATABASE ... CLONE AS" "$(printf 'app\t1001\t500500\t1\nclone\t1002\t501501\t2')" "$got"

# The target is in the data volume: SYSTEM BRANCH links the server's files,
# so it must be on the same file system.
got=$(in_container clickhouse-local --path /var/lib/clickhouse/user_files/branch --multiquery --query "
	SELECT 'app', count(), sum(k) FROM app.t;
	SELECT 'clone', count(), sum(k) FROM clone.t;
")
expect "SYSTEM BRANCH" "$(printf 'app\t1001\t500500\nclone\t1002\t501501')" "$got"

echo "checked $image, ClickHouse $want_version"
