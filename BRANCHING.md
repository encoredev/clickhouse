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

**Prepare templates with `OPTIMIZE TABLE ... FINAL`.** A clone copies each
part of each table. A table merged into one part per partition copies fewer
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
| `MergeTree` family, not replicated | Each active part, including the patch parts of lightweight updates, is cloned with `clonefile` on APFS, and elsewhere hard-linked as `ALTER TABLE ... FREEZE` links it, with the pending mutations. The deduplication log is not copied. |
| `Log`, `TinyLog`, `StripeLog` | The files are copied, while no insert runs: inserts append to them in place. |
| `Set`, `Join` | The files are hard-linked: each insert writes a file of its own. |
| `Memory` | The clone shares the source's blocks. A branch's `Memory` tables are empty, as after a restart. |
| `View`, `MaterializedView`, `Dictionary`, `Merge`, `Null`, `GenerateRandom` | The definition. A materialized view's inner table is copied as a table. |
| Anything else | Refused: replicated tables, engines that read from or write to something outside the server (`Kafka`, `S3Queue`, `Distributed`, `Buffer`, `URL`, ...), `TimeSeries`, tables with a `UNIQUE KEY`, and tables on remote disks. |

## How it works

MergeTree tables never change a part once it is written: an insert writes a
new part, and merges and mutations write new parts that replace old ones. So
a part can be shared rather than copied:

- **On APFS (macOS)**, a part's directory is cloned with one call to
  `clonefile`. The clone's files share their data with the originals until
  either is written, and are independent files from the start.
- **Elsewhere**, a part's files are hard-linked, which is how `ALTER TABLE ...
  FREEZE`, `ATTACH PARTITION ... FROM` and `CREATE TABLE ... CLONE AS` already
  copy them. Linking makes the part's files read-only, so that nothing writes
  to them in place. Deleting a part removes its names; the space comes back
  when the last name of each file is gone.

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

Tables that can't be copied are refused before anything is written. The
tables are then copied in parallel, on up to `max_threads` threads.

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
`--time` on a machine with other load, medians of 30 runs (12 for the
branch) over three rounds that alternate server restarts.

The templates:

- **Freshly migrated:** 20 `MergeTree` tables and 2 materialized views, all
  empty, as a template is right after its migrations: no parts.
- **Seeded:** the same, with 1,000 rows in each table: 22 parts.
- **1.09 GiB:** one `MergeTree` table of 50 million rows merged into a few
  parts, a materialized view, and 20 small tables: 26 parts.

| | Hard links, one table at a time | Hard links, parallel | `clonefile`, one table at a time | `clonefile`, parallel |
|---|---|---|---|---|
| Clone the freshly migrated template | 12.5 ms | 11.5 ms | 12.0 ms | 10.0 ms |
| Clone the seeded template | 83.5 ms | 47.5 ms | 21.0 ms | 16.5 ms |
| Clone the 1.09 GiB database | 113.5 ms | 81.5 ms | 22.0 ms | 17.5 ms |
| `SYSTEM BRANCH` of the server (1.1 GiB) | 213.5 ms | 105.5 ms | 40.5 ms | 27.0 ms |

The last column is what macOS gets; Linux gets the second. A clone's time
grows with the number of parts, and with hard links with the number of
files in them, not with the size of the data. With hard links, each file
costs about 0.2 ms on macOS.

Syncing the cloned parts' directories costs about 10% of a clone with hard
links; `fsync_metadata`, which syncs the copied definitions, costs nothing
measurable.

Three branches of the 1.1 GiB server took 780 KiB of disk beyond the
original. Fifteen clones taken while inserts ran into the source all
succeeded, with the row counts of the moment each was taken, and no errors
in the server log.

## Limitations

- **Prototype.** It has run on macOS (APFS) only.
- **Space.** After a merge or a mutation on either side, the merged data is
  stored twice: once for each side. On APFS, `du` counts a cloned part's
  files in full, though they share their data with the original until
  written.
- **The cost of a clone grows with the number of parts**, and with hard
  links with the number of files in them: wide parts have two files per
  column. Templates merged with `OPTIMIZE TABLE ... FINAL` keep this small.
- **Replicated databases and tables** are refused, as are the other engines
  listed in [What is copied](#what-is-copied).
- **Durability.** The parts' directories are synced before the clone's
  metadata is written; the small files copied with them (mutations,
  `format_version.txt`) are not.
- **Detached tables** are not copied.
- **`clickhouse local` can't branch.** Its `default` database is an
  `Overlay` of an `Atomic` database and the file system, which `SYSTEM BRANCH`
  refuses. It reads a branch fine.

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

### The build Encore bundles

`encore/dist.sh --target <os>-<arch> <output dir>` builds the binary Encore
runs, for `linux-amd64`, `linux-arm64`, `darwin-amd64` or `darwin-arm64`:

- **Linux** builds in Docker, on a host of the target's architecture, in
  ClickHouse's own CI image, `clickhouse/binary-builder`, at the tag
  ClickHouse's CI computes for the checkout, with the options of ClickHouse's
  single-binary builds: its pinned clang, and the sysroot that makes the
  binary run on old versions of glibc.
- **macOS** builds on a Mac, with Homebrew's LLVM, against the Mac's own SDK:
  `darwin-amd64` is cross-compiled on Apple Silicon with ClickHouse's
  toolchain file. Apple's SDK may only be used on Apple hardware, so unlike
  ClickHouse's own macOS builds, these aren't cross-compiled on Linux.

The submodules must be checked out (`contrib/update-submodules.sh`). The
output holds `bin/clickhouse` (stripped, not self-extracting), `LICENSE`, and
a `VERSION` file, whose `version=` line is the ClickHouse version and 12
characters of the commit.

`encore/check.sh <output dir>` checks a build where it runs: a server on a
copy of it clones a database and branches, and `clickhouse local` reads the
branch. `dist.sh` runs it when the host can run the build: `darwin-amd64` on Apple
Silicon where Rosetta is installed.

Encore's releaser builds the four platforms in GitHub Actions and publishes
them to `encore-releases2` as `encore-clickhouse/<version>/<os>-<arch>.tar.gz`,
as `cmd/clickhouse` and `.github/workflows/clickhouse.yml` in
`encoredev/releaser` describe.
