# Cloning databases and branching the server

Two statements copy what a ClickHouse server holds in about the same time
whatever its size, while it keeps running and taking writes:

- `CREATE DATABASE new CLONE AS source` copies a database into a new one on
  the same server.
- `SYSTEM BRANCH TO '/path'` copies the whole server into a new data
  directory, for another server to run on.

The copies share the files of their tables with the original until either
side writes, and are independent of it from the start. They were built for
Encore's local development: giving every test its own copy of a migrated
database, and forking a developer's whole server for a new namespace, the
same things the page store does for Encore's Postgres.

This is a fork of ClickHouse `master`. See [Limitations](#limitations) before
relying on it.

- [Cloning a database](#cloning-a-database)
- [Snapshots and restores of a database](#snapshots-and-restores-of-a-database)
- [Branching the server](#branching-the-server)
- [What is copied](#what-is-copied)
- [How it works](#how-it-works)
- [Performance](#performance)
- [Limitations](#limitations)
- [Building and testing](#building-and-testing)

## Cloning a database

```sql
CREATE DATABASE test_1 CLONE AS app_template;
```

The new database is an `Atomic` database with a copy of each of the source's
tables, views and dictionaries, and their data. References to the source
database in their definitions are changed to the new one, so a materialized
view in the clone writes to the clone's tables, a view reads them, and a
dictionary loads from them. The tables get new UUIDs.

- **The source stays in use.** Inserts and reads carry on while it is cloned.
  Only `CREATE`, `DROP`, `RENAME` and `ALTER` of its tables wait.
- **Each table is copied as of a moment of its own**, while it is locked
  against `ALTER`: the clone is as consistent as the source would be after a
  restart of the server. ClickHouse has no transactions across tables, so a
  materialized view's target may lack the last rows of its source, as after
  a restart.
- **Changes still being applied**, `ALTER UPDATE`, `ALTER DELETE` and
  lightweight updates, are copied with the table, and the clone finishes
  them.
- **The new database is visible all at once**: until its metadata file is in
  place it does not exist, and a clone that fails leaves nothing behind.
- **Requires** `CREATE DATABASE`, and `CREATE TABLE`, `CREATE VIEW` and
  `CREATE DICTIONARY` on the new database, and `SELECT`, `SHOW TABLES` and
  `SHOW DICTIONARIES` on the source. `ON CLUSTER` is not supported.

**Prepare templates with `OPTIMIZE TABLE ... FINAL`.** A clone links each
part of each table. A table merged into one part per partition links fewer
files, and its clones have no merges to do, which would write their own copy
of the data.

## Snapshots and restores of a database

A snapshot is a clone; a restore is a clone of the snapshot under the
original's name. Neither disconnects anyone:

```sql
-- snapshot
CREATE DATABASE app_snap CLONE AS app;

-- restore
DROP DATABASE app SYNC;
CREATE DATABASE app CLONE AS app_snap;
```

Between the two statements of a restore, `app` does not exist.

## Branching the server

```sql
SYSTEM BRANCH TO '/path/to/branch';
```

```sh
clickhouse server -- --path=/path/to/branch/ --http_port=8124 --tcp_port=9001
```

The target becomes a data directory with every database of the server, as
`CREATE DATABASE ... CLONE AS` copies them but keeping their names and UUIDs,
and the users, roles, quotas and the other access entities, SQL user-defined
functions and named collections kept in the data directory. A server started
on it has them as after a restart. Give it ports of its own.

- **The target** must be an absolute path on the same file system as the data
  directory, must not exist yet, and must not be inside the directories the
  server keeps there (`store`, `metadata`, `data`, `access`, ...).
- **Every database** but the system ones must use the `Atomic` engine, and
  keep its tables' data on disks in the data directory.
- **Not copied:** the `system` database (logs), which the new server creates
  again; the data of `Memory` tables; files in `user_files`, and anything
  configured outside the data directory.
- The branch is assembled in a directory `tmp_branch_<uuid>` of the data
  directory and renamed to the target when it is complete. One left by a
  branch that failed is removed by the next `SYSTEM BRANCH`.
- **Requires** the `SYSTEM BRANCH` privilege.

## What is copied

| Engine | How |
|---|---|
| `MergeTree` family, not replicated | Each active part, including the patch parts of lightweight updates, is hard-linked as `ALTER TABLE ... FREEZE` links it, with the pending mutations. The deduplication log is not copied. |
| `Log`, `TinyLog`, `StripeLog` | The files are copied, while no insert runs: inserts append to them in place. |
| `Set`, `Join` | The files are hard-linked: each insert writes a file of its own. |
| `Memory` | The clone shares the source's blocks. A branch's `Memory` tables are empty, as after a restart. |
| `View`, `MaterializedView`, `Dictionary`, `Merge`, `Null`, `GenerateRandom` | The definition. A materialized view's inner table is copied as a table. |
| Anything else | Refused: replicated tables, engines that read from or write to something outside the server (`Kafka`, `S3Queue`, `Distributed`, `Buffer`, `URL`, ...), `TimeSeries`, tables with a `UNIQUE KEY`, and tables on remote disks. |

## How it works

MergeTree tables never change a part once it is written: an insert writes a
new part, and merges and mutations write new parts that replace old ones. So
a part can be shared by hard link, which is how `ALTER TABLE ... FREEZE`,
`ATTACH PARTITION ... FROM` and `CREATE TABLE ... CLONE AS` already copy them.
Linking makes the part's files read-only, so that nothing writes to them in
place. Deleting a part removes its names; the space comes back when the last
name of each file is gone.

Both statements go through `copyDatabaseTables` (`src/Databases/DatabaseCopy.cpp`):

1. It takes the source's exclusive DDL guard, so that no table is created,
   dropped, renamed or exchanged meanwhile, and lists its tables.
2. For each table, under its alter lock, it reads the table's definition from
   its metadata file, gives it its new UUID (and its inner tables' new UUIDs
   and names), renames references to the source database with the
   `DDLRenamingVisitor` that `RESTORE ... AS` uses, and writes it into the new
   database's metadata directory.
3. It copies the table's data with `IStorage::cloneDataToPath`, into the
   directory the new table will have: `store/<xxx>/<uuid>/`.

`CREATE DATABASE ... CLONE AS` then creates the database as any `CREATE
DATABASE`, and loads its tables as the server loads a database when it starts.
Its metadata file is written last: until it is in place, nothing refers to the
copied files, and after a crash the store cleanup removes them.

`SYSTEM BRANCH` (`src/Interpreters/ServerBranch.cpp`) copies each database
into the staging directory the same way, keeping UUIDs, copies the databases'
metadata files and the server's access, user-defined function and named
collection directories, and renames the staging directory to the target.

## Performance

Release build, macOS on Apple Silicon (APFS), measured with the client's
`--time`, five runs each. The database: one `MergeTree` table merged into
3 parts, a materialized view with an inner table, and 20 small `MergeTree`
tables, 25 parts in all.

| Data | `CREATE DATABASE ... CLONE AS` |
|---|---|
| 91 MiB | 83 to 88 ms |
| 1.09 GiB | 85 to 143 ms (median 88 ms) |

`SYSTEM BRANCH` of that server (eight databases, 1.1 GiB) took 0.20 to
0.37 s. Three branches of it took 780 KiB of disk beyond the original.

Fifteen clones taken while inserts ran into the source all succeeded, with
the row counts of the moment each was taken, and no errors in the server log.


- **Prototype.** It has run on macOS (APFS) only.
- **Space.** After a merge or a mutation on either side, the merged data is
  stored twice: once for each side.
- **Linking costs per file.** A clone links every file of every part, and
  fsyncs each part's directory; wide parts have two files per column, so the
  time grows with the number of parts and columns rather than the data.
  Templates merged with `OPTIMIZE TABLE ... FINAL` keep this small.
- **Replicated databases and tables** are refused, as are the other engines
  listed in [What is copied](#what-is-copied).
- **Durability.** The parts' directories are synced before the clone's
  metadata is written; the small files copied with them (mutations,
  `format_version.txt`) are not.
- **Detached tables** are not copied.

## Building and testing

Build as ClickHouse usually builds. The tests:

```sh
tests/clickhouse-test 05813_create_database_clone_as 05814_system_branch
```

- `05813_create_database_clone_as`: cloning every supported engine, pending
  mutations and lightweight updates, materialized views and dictionaries in
  the clone, independence of writes, clones of clones, and refusals. It is a
  shell test because `CLONE AS` takes the source's name, not a query
  parameter.
- `05814_system_branch`: branching a running server and reading the branch
  with `clickhouse-local`.
