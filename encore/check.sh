#!/usr/bin/env bash
# Check a build of encore/dist.sh on the platform it was built for:
#
#   encore/check.sh <output dir of encore/dist.sh>
#
# A copy of the build, in another directory, starts a server on a new data
# directory, as Encore runs it, on 127.0.0.1 and a free port. It creates a
# database with a table and a materialized view, clones the database with
# CREATE DATABASE ... CLONE AS, writes to the clone, and branches the server
# with SYSTEM BRANCH; `clickhouse local` then reads the branch.
#
# Needs python3, to find a free port.
set -euo pipefail

usage() {
	sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
	exit 2
}

[ $# -eq 1 ] || usage
dist=$1
[ -x "$dist/bin/clickhouse" ] || { echo "$dist/bin/clickhouse is not an executable" >&2; exit 1; }

tmp=$(mktemp -d)
server_pid=
cleanup() {
	if [ -n "$server_pid" ]; then
		kill "$server_pid" 2>/dev/null || true
		wait "$server_pid" 2>/dev/null || true
	fi
	rm -rf "$tmp"
}
trap cleanup EXIT

# From a copy, so that the build doesn't depend on where it was made
cp -R "$dist" "$tmp/dist"
clickhouse="$tmp/dist/bin/clickhouse"

# Every clickhouse gets an empty stdin: given one that stays open, an INSERT
# waits on it for data.
"$clickhouse" local --version </dev/null

port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
mkdir -p "$tmp/data"
cat > "$tmp/config.xml" <<EOF
<clickhouse>
    <logger><level>information</level><log>$tmp/server.log</log><errorlog>$tmp/server.err.log</errorlog><console>0</console></logger>
    <path>$tmp/data/</path>
    <tmp_path>$tmp/data/tmp/</tmp_path>
    <user_files_path>$tmp/data/user_files/</user_files_path>
    <listen_host>127.0.0.1</listen_host>
    <tcp_port>$port</tcp_port>
    <mark_cache_size>268435456</mark_cache_size>
    <user_directories>
        <users_xml><path>$tmp/users.xml</path></users_xml>
        <local_directory><path>$tmp/data/access/</path></local_directory>
    </user_directories>
</clickhouse>
EOF
cat > "$tmp/users.xml" <<EOF
<clickhouse>
    <profiles><default></default></profiles>
    <users><default><password></password><networks><ip>127.0.0.1</ip></networks><profile>default</profile><quota>default</quota></default></users>
    <quotas><default></default></quotas>
</clickhouse>
EOF

# Without the watchdog, which forks: on macOS, a fork of a process that has
# started threads may be killed.
CLICKHOUSE_WATCHDOG_ENABLE=0 "$clickhouse" server --config-file="$tmp/config.xml" </dev/null >"$tmp/server.out" 2>&1 &
server_pid=$!

query() {
	"$clickhouse" client --port "$port" -m -q "$1" </dev/null
}

for _ in $(seq 1 60); do
	query "SELECT 1" >/dev/null 2>&1 && break
	if ! kill -0 "$server_pid" 2>/dev/null; then
		echo "the server exited:" >&2
		cat "$tmp/server.out" "$tmp/server.err.log" >&2 2>/dev/null || true
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
	SYSTEM BRANCH TO '$tmp/branch';
	INSERT INTO app.t VALUES (2000);
")
expect "CREATE DATABASE ... CLONE AS" "$(printf 'app\t1001\t500500\t1\nclone\t1002\t501501\t2')" "$got"

kill "$server_pid"
wait "$server_pid" || true
server_pid=

got=$("$clickhouse" local --path "$tmp/branch" -m -q "
	SELECT 'app', count(), sum(k) FROM app.t;
	SELECT 'clone', count(), sum(k) FROM clone.t;
" </dev/null)
expect "SYSTEM BRANCH" "$(printf 'app\t1001\t500500\nclone\t1002\t501501')" "$got"

echo "checked $dist"
