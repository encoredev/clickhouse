#!/usr/bin/env bash
# Tags: no-replicated-database, no-object-storage, memory-engine
# Tag no-replicated-database: CLONE AS copies Atomic databases only
# Tag no-object-storage: CLONE AS copies the data of MergeTree tables on local disks only

# `CREATE DATABASE ... CLONE AS` copies a database: its tables, views and dictionaries, and their data. The copies
# share the files of MergeTree tables with the source until either writes, and are independent of it.
# The names are substituted here rather than passed as query parameters, which `CLONE AS` does not take.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

DB1="${CLICKHOUSE_DATABASE}_1"
DB2="${CLICKHOUSE_DATABASE}_2"

$CLICKHOUSE_CLIENT -m <<EOF
SELECT formatQuery('CREATE DATABASE b CLONE AS a');
SELECT formatQuery('CREATE DATABASE IF NOT EXISTS b CLONE AS \`a-b\`');
SELECT formatQueryFromJSON(parseQueryToJSON('CREATE DATABASE b CLONE AS a'));
SELECT formatQuery('ATTACH DATABASE b CLONE AS a'); -- { serverError SYNTAX_ERROR }
SELECT formatQuery('CREATE DATABASE b CLONE AS a ENGINE = Atomic'); -- { serverError SYNTAX_ERROR }

DROP DATABASE IF EXISTS ${DB1};
DROP DATABASE IF EXISTS ${DB2};

CREATE TABLE mt (k UInt64, v String) ENGINE = MergeTree ORDER BY k;
INSERT INTO mt SELECT number, toString(number) FROM numbers(10);
INSERT INTO mt SELECT number + 10, toString(number + 10) FROM numbers(10);

-- A materialized view with an inner table, one with a target table, and a view, all of \`mt\`.
CREATE MATERIALIZED VIEW mv_inner ENGINE = SummingMergeTree ORDER BY tuple() AS SELECT count() AS c FROM mt;
CREATE TABLE mv_target (k UInt64) ENGINE = MergeTree ORDER BY k;
CREATE MATERIALIZED VIEW mv_to TO mv_target AS SELECT k FROM mt;
CREATE VIEW v AS SELECT count() AS c, sum(k) AS s FROM mt;
INSERT INTO mt VALUES (100, '100');

-- A pending mutation: the clone carries it and applies it, the source does not run it while its merges are stopped.
CREATE TABLE mut (k UInt64, v UInt64) ENGINE = MergeTree ORDER BY k;
INSERT INTO mut SELECT number, 0 FROM numbers(5);
SYSTEM STOP MERGES mut;
ALTER TABLE mut UPDATE v = 1 WHERE 1 SETTINGS mutations_sync = 0;

-- A lightweight update that is not applied yet: the clone carries its patch part.
CREATE TABLE upd (k UInt64, v UInt64) ENGINE = MergeTree ORDER BY k
SETTINGS enable_block_number_column = 1, enable_block_offset_column = 1;
INSERT INTO upd SELECT number, 0 FROM numbers(5);
UPDATE upd SET v = 2 WHERE k < 2 SETTINGS enable_lightweight_update = 1;

-- Engines whose files are written in place, and Memory.
CREATE TABLE log (x UInt8) ENGINE = Log;
CREATE TABLE tinylog (x UInt8) ENGINE = TinyLog;
CREATE TABLE stripelog (x UInt8) ENGINE = StripeLog;
CREATE TABLE s (x UInt8) ENGINE = Set;
CREATE TABLE j (k UInt8, v String) ENGINE = Join(ANY, LEFT, k);
CREATE TABLE mem (x UInt8) ENGINE = Memory;
INSERT INTO log VALUES (1), (2);
INSERT INTO log VALUES (3);
INSERT INTO tinylog VALUES (4);
INSERT INTO stripelog VALUES (5);
INSERT INTO s VALUES (6);
INSERT INTO j VALUES (7, 'seven');
INSERT INTO mem VALUES (8);

CREATE TABLE dict_source (k UInt64, v String) ENGINE = MergeTree ORDER BY k;
INSERT INTO dict_source VALUES (1, 'one');
CREATE DICTIONARY dict (k UInt64, v String) PRIMARY KEY k SOURCE(CLICKHOUSE(TABLE 'dict_source')) LIFETIME(0) LAYOUT(FLAT());

CREATE DATABASE ${DB1} CLONE AS ${CLICKHOUSE_DATABASE};
CREATE DATABASE ${DB1} CLONE AS ${CLICKHOUSE_DATABASE}; -- { serverError DATABASE_ALREADY_EXISTS }
CREATE DATABASE IF NOT EXISTS ${DB1} CLONE AS ${CLICKHOUSE_DATABASE};

SELECT 'the clone is an ordinary Atomic database';
SELECT engine, engine_full FROM system.databases WHERE name = '${DB1}';
SELECT name, engine FROM system.tables WHERE database = '${DB1}' AND NOT startsWith(name, '.inner') ORDER BY name;
SELECT count() FROM system.tables WHERE database = '${DB1}' AND startsWith(name, '.inner_id.');
SELECT count() FROM system.tables AS c, system.tables AS s
WHERE c.database = '${DB1}' AND s.database = '${CLICKHOUSE_DATABASE}' AND c.name = s.name AND c.uuid = s.uuid;

SELECT 'the data';
SELECT count(), sum(k) FROM ${DB1}.mt;
SELECT sum(c) FROM ${DB1}.mv_inner;
SELECT count() FROM ${DB1}.mv_target;
SELECT * FROM ${DB1}.v;
SELECT * FROM ${DB1}.log ORDER BY x;
SELECT * FROM ${DB1}.tinylog;
SELECT * FROM ${DB1}.stripelog;
SELECT 6 IN ${DB1}.s, 5 IN ${DB1}.s;
SELECT k, v FROM (SELECT toUInt8(7) AS k) AS l ANY LEFT JOIN ${DB1}.j AS r USING (k);
SELECT * FROM ${DB1}.mem;
SELECT dictGet('${DB1}' || '.dict', 'v', toUInt64(1));
SELECT k, v FROM ${DB1}.upd ORDER BY k;

SELECT 'the pending mutation is applied in the clone, not in the source';
ALTER TABLE ${DB1}.mut DELETE WHERE 0 SETTINGS mutations_sync = 2;
SELECT sum(v) FROM ${DB1}.mut;
SELECT sum(v) FROM mut;
SYSTEM START MERGES mut;

SELECT 'writes to the clone go to the clone';
INSERT INTO ${DB1}.mt VALUES (1000, '1000');
INSERT INTO ${DB1}.log VALUES (9);
INSERT INTO ${DB1}.dict_source VALUES (2, 'two');
SELECT count(), sum(k) FROM ${DB1}.mt;
SELECT sum(c) FROM ${DB1}.mv_inner;
SELECT count() FROM ${DB1}.mv_target;
SELECT * FROM ${DB1}.v;
SYSTEM RELOAD DICTIONARY ${DB1}.dict;
SELECT dictGet('${DB1}' || '.dict', 'v', toUInt64(2));
SELECT count(), sum(k) FROM mt;
SELECT sum(c) FROM mv_inner;
SELECT count() FROM mv_target;
SELECT count() FROM log;
SELECT dictGetOrDefault(currentDatabase() || '.dict', 'v', toUInt64(2), 'none');

SELECT 'writes to the source stay in the source, also after its parts merge';
INSERT INTO mt VALUES (2000, '2000');
OPTIMIZE TABLE mt FINAL;
ALTER TABLE mt DELETE WHERE k < 5 SETTINGS mutations_sync = 2;
SELECT count(), sum(k) FROM mt;
SELECT count(), sum(k) FROM ${DB1}.mt;

SELECT 'the clone is the same after it is detached and attached';
DETACH DATABASE ${DB1};
ATTACH DATABASE ${DB1};
SELECT count(), sum(k) FROM ${DB1}.mt;
SELECT sum(c) FROM ${DB1}.mv_inner;
SELECT * FROM ${DB1}.log ORDER BY x;

SELECT 'a clone of the clone';
CREATE DATABASE ${DB2} CLONE AS ${DB1};
SELECT count(), sum(k) FROM ${DB2}.mt;
INSERT INTO ${DB2}.mt VALUES (3000, '3000');
SELECT sum(c) FROM ${DB2}.mv_inner;
SELECT sum(c) FROM ${DB1}.mv_inner;
DROP DATABASE ${DB2} SYNC;

SELECT 'dropping the clone leaves the source';
DROP DATABASE ${DB1} SYNC;
SELECT count(), sum(k) FROM mt;
SELECT count() FROM log;

SELECT 'unsupported engines are refused, and leave nothing behind';
CREATE TABLE buf (x UInt8) ENGINE = Buffer(currentDatabase(), log, 1, 10, 100, 10000, 1000000, 10000000, 100000000);
CREATE DATABASE ${DB1} CLONE AS ${CLICKHOUSE_DATABASE}; -- { serverError NOT_IMPLEMENTED }
SELECT count() FROM system.databases WHERE name = '${DB1}';
DROP TABLE buf;

CREATE DATABASE ${DB2} ENGINE = Memory;
CREATE DATABASE ${DB1} CLONE AS ${DB2}; -- { serverError NOT_IMPLEMENTED }
DROP DATABASE ${DB2};
CREATE DATABASE ${DB1} CLONE AS ${DB2}; -- { serverError UNKNOWN_DATABASE }
EOF

$CLICKHOUSE_CLIENT -q "DROP DATABASE IF EXISTS ${DB1}; DROP DATABASE IF EXISTS ${DB2}"
