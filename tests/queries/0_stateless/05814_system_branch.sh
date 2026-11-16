#!/usr/bin/env bash
# Tags: no-parallel, no-replicated-database, no-object-storage
# Tag no-parallel: SYSTEM BRANCH copies every database of the server, and refuses those it can't copy
# Tag no-replicated-database: SYSTEM BRANCH copies Atomic databases only
# Tag no-object-storage: SYSTEM BRANCH copies the data of MergeTree tables on local disks only

# `SYSTEM BRANCH TO` copies the running server into a new data directory. A server started on it, here
# `clickhouse-local`, has the tables as they were, and the two are independent afterwards.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

target="${CLICKHOUSE_USER_FILES}/branch_${CLICKHOUSE_TEST_UNIQUE_NAME}"
rm -rf "$target"

$CLICKHOUSE_CLIENT -q "SELECT formatQuery('SYSTEM BRANCH TO \'/some/path\'')"
$CLICKHOUSE_CLIENT -q "SELECT formatQueryFromJSON(parseQueryToJSON('SYSTEM BRANCH TO \'/some/path\''))"

$CLICKHOUSE_CLIENT -m -q "
    CREATE TABLE t (k UInt64) ENGINE = MergeTree ORDER BY k;
    INSERT INTO t SELECT number FROM numbers(100);
    CREATE MATERIALIZED VIEW mv ENGINE = SummingMergeTree ORDER BY tuple() AS SELECT count() AS c FROM t;
    INSERT INTO t VALUES (1000);
    CREATE TABLE l (x UInt8) ENGINE = Log;
    INSERT INTO l VALUES (1);
"

$CLICKHOUSE_CLIENT -q "SYSTEM BRANCH TO '$target'"

echo "the target must not exist, and must be absolute"
$CLICKHOUSE_CLIENT -q "SYSTEM BRANCH TO '$target'" 2>&1 | grep -o -m1 FILE_ALREADY_EXISTS
$CLICKHOUSE_CLIENT -q "SYSTEM BRANCH TO 'relative/path'" 2>&1 | grep -o -m1 BAD_ARGUMENTS

echo "the source carries on"
$CLICKHOUSE_CLIENT -q "INSERT INTO t VALUES (2000)"
$CLICKHOUSE_CLIENT -q "OPTIMIZE TABLE t FINAL"
$CLICKHOUSE_CLIENT -q "SELECT count(), sum(k) FROM t"

echo "the branch has the tables as they were, with the same UUIDs"
$CLICKHOUSE_LOCAL --path "$target" -m -q "
    SELECT count(), sum(k) FROM ${CLICKHOUSE_DATABASE}.t;
    SELECT sum(c) FROM ${CLICKHOUSE_DATABASE}.mv;
    SELECT * FROM ${CLICKHOUSE_DATABASE}.l;
    INSERT INTO ${CLICKHOUSE_DATABASE}.t VALUES (3000);
    SELECT count(), sum(k) FROM ${CLICKHOUSE_DATABASE}.t;
"
source_uuid=$($CLICKHOUSE_CLIENT -q "SELECT uuid FROM system.tables WHERE database = currentDatabase() AND name = 't'")
branch_uuid=$($CLICKHOUSE_LOCAL --path "$target" -q "SELECT uuid FROM system.tables WHERE database = '${CLICKHOUSE_DATABASE}' AND name = 't'")
[ "$source_uuid" = "$branch_uuid" ] && echo "same UUID"

echo "writes to the branch stay in the branch"
$CLICKHOUSE_CLIENT -q "SELECT count(), sum(k) FROM t"

rm -rf "$target"
