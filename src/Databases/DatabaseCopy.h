#pragma once

#include <Core/Types.h>
#include <Interpreters/Context_fwd.h>
#include <Interpreters/DatabaseCatalog.h>
#include <Storages/IStorage_fwd.h>

#include <vector>


namespace DB
{

class IDatabase;
using DatabasePtr = std::shared_ptr<IDatabase>;

/// Where `copyDatabaseTables` writes its copy of a database's tables.
struct DatabaseCopyTarget
{
    /// The definitions in the copy refer to the source database by this name: the new database's for a clone,
    /// the source's own for a branch.
    String database_name;

    /// Give the tables new UUIDs, for a clone in the same server, or keep them, for a branch, which is another server.
    bool new_uuids = true;

    /// Where the tables' definitions are written on the database disk: the new database's store directory.
    String metadata_path;

    /// Prepended to the tables' data paths on the disks their data is on: empty for a clone, the staging directory
    /// for a branch.
    String data_path_prefix;

    /// If set, the data of every table copied with its data must be under this directory: a branch copies into a
    /// directory of the server's data directory, so the data must be on a disk there.
    String required_data_root;
};

/// What `copyDatabaseTables` wrote.
struct CopiedDatabaseTables
{
    /// The data paths of the copied tables, relative to their disks.
    Strings data_paths;

    /// Hold the new tables' UUIDs until the tables are attached, so that nothing else takes them and the store
    /// cleanup leaves their directories alone.
    std::vector<TemporaryLockForUUIDDirectory> uuid_locks;

    /// `Memory` tables keep their data in memory, so their copies are filled once they are attached:
    /// the name of the copy, and the source table.
    std::vector<std::pair<String, StoragePtr>> memory_tables;

    /// Removes the copied data from the disks, when the copy is abandoned.
    void removeData(const ContextPtr & context) const;
};

/// Copies the tables of an `Atomic` database, their definitions and their data, for `CREATE DATABASE ... CLONE AS`
/// and `SYSTEM BRANCH`. Loading a database whose metadata is at `target.metadata_path` then gives the tables as they
/// were. The data of each table is copied with `IStorage::cloneDataToPath`, which links what never changes, so the
/// copy takes about the same time whatever the size of the data. Each table is copied as of a moment of its own:
/// the copy is as consistent as the database after a restart of the server. No table is created, dropped or
/// altered in the source meanwhile; inserts carry on.
CopiedDatabaseTables copyDatabaseTables(const DatabasePtr & source, const DatabaseCopyTarget & target, const ContextPtr & context);

}
