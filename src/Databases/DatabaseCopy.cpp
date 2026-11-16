#include <Databases/DatabaseCopy.h>

#include <Common/escapeForFileName.h>
#include <Common/logger_useful.h>
#include <Common/quoteString.h>
#include <Core/Settings.h>
#include <Databases/DDLRenamingVisitor.h>
#include <Databases/DatabaseOnDisk.h>
#include <Databases/DatabasesCommon.h>
#include <Databases/IDatabase.h>
#include <Disks/IDisk.h>
#include <IO/ReadHelpers.h>
#include <Interpreters/Context.h>
#include <Parsers/ASTCreateQuery.h>
#include <Parsers/CreateQueryUUIDs.h>
#include <Storages/IStorage.h>

#include <filesystem>
#include <unordered_map>
#include <unordered_set>


namespace fs = std::filesystem;

namespace DB
{

namespace Setting
{
    extern const SettingsBool fsync_metadata;
    extern const SettingsSeconds lock_acquire_timeout;
}

namespace ErrorCodes
{
    extern const int NOT_IMPLEMENTED;
    extern const int LOGICAL_ERROR;
}

namespace
{

enum class TableCopyKind : uint8_t
{
    /// The definition only: the engine keeps no data of its own.
    Definition,
    /// The definition, and the data, with `IStorage::cloneDataToPath`.
    Data,
    /// The definition, and the data once the copy is attached: `Memory` keeps it in memory.
    Memory,
};

std::optional<TableCopyKind> getTableCopyKind(const IStorage & table)
{
    if (table.supportsCloneData())
        return TableCopyKind::Data;

    const String engine = table.getName();
    if (engine == "Memory")
        return TableCopyKind::Memory;

    /// Engines that keep no data of their own and whose definitions refer to nothing outside the server but tables,
    /// which the copy refers to by their new names. A materialized view's inner table is a table of the database
    /// like any other, and is copied as one.
    static const std::unordered_set<String> definition_only{"View", "MaterializedView", "Dictionary", "Merge", "Null", "GenerateRandom"};
    if (definition_only.contains(engine))
        return TableCopyKind::Definition;

    return {};
}

/// An inner table is named after the table it belongs to: `.inner_id.<uuid>` for the target of a materialized view.
/// The copy of the view has a new UUID, so the copy of its inner table has a new name.
String getInnerTableNameInCopy(const String & name, const std::unordered_map<UUID, UUID> & new_uuids)
{
    static constexpr std::string_view prefix = ".inner_id.";
    static constexpr size_t uuid_length = 36;
    if (!name.starts_with(prefix) || name.size() < prefix.size() + uuid_length)
        return name;

    UUID owner_uuid;
    if (!tryParse(owner_uuid, name.substr(name.size() - uuid_length)))
        return name;

    auto it = new_uuids.find(owner_uuid);
    if (it == new_uuids.end())
        return name;

    return name.substr(0, name.size() - uuid_length) + toString(it->second);
}

}


void CopiedDatabaseTables::removeData(const ContextPtr & context) const
{
    for (const auto & [disk_name, disk] : context->getDisksMap())
    {
        if (disk->isRemote() || disk->isReadOnly())
            continue;

        for (const auto & data_path : data_paths)
        {
            if (disk->existsDirectory(data_path))
                disk->removeRecursive(data_path);
        }
    }
}


CopiedDatabaseTables copyDatabaseTables(const DatabasePtr & source, const DatabaseCopyTarget & target, const ContextPtr & context)
{
    const String source_name = source->getDatabaseName();
    if (source->getEngineName() != "Atomic")
        throw Exception(ErrorCodes::NOT_IMPLEMENTED,
            "Cannot copy database {}: its engine is {}, and only Atomic databases can be copied",
            backQuoteIfNeed(source_name), source->getEngineName());

    source->waitDatabaseStarted();

    /// No table is created, dropped, renamed or exchanged in the source while it is copied.
    auto ddl_guard = DatabaseCatalog::instance().getExclusiveDDLGuardForDatabase(source_name);

    const auto & settings = context->getSettingsRef();
    const auto lock_timeout = settings[Setting::lock_acquire_timeout];
    const auto db_disk = source->getDisk();
    const auto log = getLogger("DatabaseCopy");

    std::vector<std::pair<String, StoragePtr>> tables;
    for (auto it = source->getTablesIterator(context, /* filter_by_table_name= */ {}, /* skip_not_loaded= */ false); it->isValid(); it->next())
        tables.emplace_back(it->name(), it->table());

    std::unordered_map<UUID, UUID> new_uuids;
    for (const auto & [name, table] : tables)
    {
        const UUID uuid = table->getStorageID().uuid;
        new_uuids.emplace(uuid, target.new_uuids ? UUIDHelpers::generateV4() : uuid);
    }

    CopiedDatabaseTables copied;
    try
    {
        db_disk->createDirectories(target.metadata_path);

        for (const auto & [name, table] : tables)
        {
            const auto kind = getTableCopyKind(*table);
            if (!kind)
                throw Exception(ErrorCodes::NOT_IMPLEMENTED,
                    "Cannot copy table {}.{}: copying tables with the engine {} is not supported",
                    backQuoteIfNeed(source_name), backQuoteIfNeed(name), table->getName());

            /// The definition and the data are taken under the alter lock, so that they agree. The shared lock
            /// keeps the table from being truncated meanwhile.
            auto table_lock = table->lockForShare(context->getCurrentQueryId(), lock_timeout);
            auto alter_lock = table->lockForAlter(lock_timeout);

            ASTPtr ast = DatabaseOnDisk::parseQueryFromMetadata(log, context, db_disk, source->getObjectMetadataPath(name));
            auto & create = ast->as<ASTCreateQuery &>();

            const UUID new_uuid = new_uuids.at(table->getStorageID().uuid);
            String name_in_copy = name;
            if (target.new_uuids)
            {
                CreateQueryUUIDs uuids(create);
                uuids.uuid = new_uuid;
                for (auto & [target_kind, inner_uuid] : uuids.targets_inner_uuids)
                {
                    if (inner_uuid == UUIDHelpers::Nil)
                        continue;
                    auto it = new_uuids.find(inner_uuid);
                    if (it == new_uuids.end())
                        throw Exception(ErrorCodes::LOGICAL_ERROR,
                            "Cannot copy table {}.{}: its inner table with UUID {} is not in the database",
                            backQuoteIfNeed(source_name), backQuoteIfNeed(name), inner_uuid);
                    inner_uuid = it->second;
                }
                uuids.copyToQuery(create);
                name_in_copy = getInnerTableNameInCopy(name, new_uuids);
                copied.uuid_locks.emplace_back(new_uuid);
            }

            if (target.database_name != source_name)
            {
                DDLRenamingMap renaming_map;
                renaming_map.setNewDatabaseName(source_name, target.database_name);
                renameDatabaseAndTableNameInCreateQuery(ast, renaming_map, context->getGlobalContext());
            }

            if (*kind == TableCopyKind::Data)
            {
                if (!target.required_data_root.empty())
                {
                    for (const auto & table_data_path : table->getDataPaths())
                    {
                        if (!fs::path(table_data_path).lexically_normal().string().starts_with(target.required_data_root))
                            throw Exception(ErrorCodes::NOT_IMPLEMENTED,
                                "Cannot copy table {}.{}: its data at {} is outside the server's data directory {}",
                                backQuoteIfNeed(source_name), backQuoteIfNeed(name), table_data_path, target.required_data_root);
                    }
                }

                const String data_path = fs::path(target.data_path_prefix) / DatabaseCatalog::getStoreDirPath() / DatabaseCatalog::getPathForUUID(new_uuid);
                copied.data_paths.push_back(data_path);
                table->cloneDataToPath(data_path, context);
            }
            else if (*kind == TableCopyKind::Memory)
            {
                copied.memory_tables.emplace_back(name_in_copy, table);
            }

            writeMetadataFile(
                db_disk,
                fs::path(target.metadata_path) / (escapeForFileName(name_in_copy) + ".sql"),
                getObjectDefinitionFromCreateQuery(ast),
                settings[Setting::fsync_metadata]);

            LOG_DEBUG(log, "Copied table {}.{} as {}", backQuoteIfNeed(source_name), backQuoteIfNeed(name), backQuoteIfNeed(name_in_copy));
        }
    }
    catch (...)
    {
        copied.removeData(context);
        if (db_disk->existsDirectory(target.metadata_path))
            db_disk->removeRecursive(target.metadata_path);
        throw;
    }

    return copied;
}

}
