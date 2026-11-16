#include <Interpreters/ServerBranch.h>

#include <Common/ErrnoException.h>
#include <Common/Exception.h>
#include <Common/logger_useful.h>
#include <Common/quoteString.h>
#include <Core/UUID.h>
#include <Databases/DatabaseCopy.h>
#include <IO/WriteHelpers.h>
#include <Databases/IDatabase.h>
#include <Disks/IDisk.h>
#include <Interpreters/Context.h>
#include <Interpreters/DatabaseCatalog.h>

#include <array>
#include <filesystem>
#include <mutex>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>


namespace fs = std::filesystem;

namespace DB
{

namespace ErrorCodes
{
    extern const int BAD_ARGUMENTS;
    extern const int CANNOT_CLOSE_FILE;
    extern const int CANNOT_FSYNC;
    extern const int CANNOT_STAT;
    extern const int FILE_ALREADY_EXISTS;
    extern const int NOT_IMPLEMENTED;
}

namespace
{

/// The directories of the data directory that a branch copies as they are, besides the databases: users, roles and
/// the other access entities, SQL user-defined functions, and named collections.
constexpr std::array copied_server_directories{"access", "user_defined", "named_collections"};

/// The directories of the data directory the target must not be in.
constexpr std::array server_directories{"store", "metadata", "data", "access", "user_defined", "named_collections", "shadow", "tmp"};

/// A branch is assembled in a directory of the data directory with this prefix, and moved to the target when it is
/// complete. One left by a branch that failed is removed by the next.
constexpr std::string_view staging_directory_prefix = "tmp_branch_";

bool isInDirectory(const fs::path & path, const fs::path & directory)
{
    auto [directory_end, path_it] = std::mismatch(directory.begin(), directory.end(), path.begin(), path.end());
    return directory_end == directory.end();
}

dev_t getDevice(const fs::path & path)
{
    struct stat st;
    if (::stat(path.c_str(), &st) != 0)
        throw ErrnoException(ErrorCodes::CANNOT_STAT, "Cannot stat {}", path.string());
    return st.st_dev;
}

void fsyncDirectory(const fs::path & path)
{
    int fd = ::open(path.c_str(), O_RDONLY | O_DIRECTORY);
    if (fd < 0)
        throw ErrnoException(ErrorCodes::CANNOT_FSYNC, "Cannot open directory {} to fsync it", path.string());
    if (::fsync(fd) != 0)
    {
        int saved_errno = errno;
        [[maybe_unused]] int close_res = ::close(fd);
        errno = saved_errno;
        throw ErrnoException(ErrorCodes::CANNOT_FSYNC, "Cannot fsync directory {}", path.string());
    }
    if (::close(fd) != 0)
        throw ErrnoException(ErrorCodes::CANNOT_CLOSE_FILE, "Cannot close directory {}", path.string());
}

}


void branchServer(const String & target_str, const ContextPtr & context)
{
    /// One branch at a time: each removes what failed branches left behind.
    static std::mutex branch_mutex;
    std::lock_guard branch_lock(branch_mutex);

    const auto log = getLogger("ServerBranch");
    const fs::path server_path = fs::canonical(context->getPath());

    fs::path target = fs::path(target_str).lexically_normal();
    if (!target.is_absolute())
        throw Exception(ErrorCodes::BAD_ARGUMENTS, "The target of SYSTEM BRANCH must be an absolute path, got {}", quoteString(target_str));
    if (!target.has_filename())
        target = target.parent_path();
    if (fs::exists(fs::symlink_status(target)))
        throw Exception(ErrorCodes::FILE_ALREADY_EXISTS, "The target of SYSTEM BRANCH {} already exists", quoteString(target.string()));
    if (!fs::is_directory(target.parent_path()))
        throw Exception(ErrorCodes::BAD_ARGUMENTS, "The directory {} of the target of SYSTEM BRANCH does not exist", quoteString(target.parent_path().string()));
    target = fs::canonical(target.parent_path()) / target.filename();

    for (const auto * directory : server_directories)
    {
        if (isInDirectory(target, server_path / directory))
            throw Exception(ErrorCodes::BAD_ARGUMENTS,
                "The target of SYSTEM BRANCH {} is in the directory {} that the server keeps", quoteString(target.string()),
                quoteString((server_path / directory).string()));
    }
    if (std::string_view(target.filename().native()).starts_with(staging_directory_prefix) && target.parent_path() == server_path)
        throw Exception(ErrorCodes::BAD_ARGUMENTS, "The name of the target of SYSTEM BRANCH {} is reserved", quoteString(target.string()));

    /// The tables' files are linked, and the branch is moved into place by renaming it.
    if (getDevice(server_path) != getDevice(target.parent_path()))
        throw Exception(ErrorCodes::BAD_ARGUMENTS,
            "The target of SYSTEM BRANCH {} must be on the same file system as the data directory {}",
            quoteString(target.string()), quoteString(server_path.string()));

    for (const auto & entry : fs::directory_iterator(server_path))
    {
        if (entry.is_directory() && std::string_view(entry.path().filename().native()).starts_with(staging_directory_prefix))
        {
            LOG_INFO(log, "Removing {}, left by a SYSTEM BRANCH that failed", entry.path().string());
            fs::remove_all(entry.path());
        }
    }

    const String staging_directory = String(staging_directory_prefix) + toString(UUIDHelpers::generateV4());
    const fs::path staging_path = server_path / staging_directory;

    try
    {
        fs::create_directories(staging_path / DatabaseCatalog::getMetadataDirPath());
        fs::create_directories(staging_path / DatabaseCatalog::getStoreDirPath());

        for (const auto & [database_name, database] : DatabaseCatalog::instance().getDatabases(GetDatabasesOptions{.with_datalake_catalogs = false, .with_remote_databases = false}))
        {
            /// The server creates these when it starts.
            if (DatabaseCatalog::isPredefinedDatabase(database_name))
                continue;

            if (database->getEngineName() != "Atomic")
                throw Exception(ErrorCodes::NOT_IMPLEMENTED,
                    "Cannot branch the server: the engine of database {} is {}, and only Atomic databases can be branched",
                    backQuoteIfNeed(database_name), database->getEngineName());

            const auto db_disk = database->getDisk();
            if (db_disk->isRemote() || fs::canonical(db_disk->getPath()) != server_path)
                throw Exception(ErrorCodes::NOT_IMPLEMENTED,
                    "Cannot branch the server: the metadata of database {} is on the disk {}, outside the data directory",
                    backQuoteIfNeed(database_name), db_disk->getName());

            const auto metadata_file_path = DatabaseCatalog::getMetadataFilePath(database_name);
            fs::copy_file(server_path / metadata_file_path, staging_path / metadata_file_path);

            /// The tables keep their UUIDs, so that the copied definition of the database finds them.
            copyDatabaseTables(
                database,
                DatabaseCopyTarget{
                    .database_name = database_name,
                    .new_uuids = false,
                    .metadata_path = fs::path(staging_directory) / DatabaseCatalog::getStoreDirPath(database->getUUID()) / "",
                    .data_path_prefix = staging_directory,
                    .required_data_root = (server_path / "").string(),
                },
                context);

            LOG_DEBUG(log, "Branched database {}", backQuoteIfNeed(database_name));
        }

        for (const auto * directory : copied_server_directories)
        {
            if (fs::is_directory(server_path / directory))
                fs::copy(server_path / directory, staging_path / directory, fs::copy_options::recursive);
        }

        fs::rename(staging_path, target);
        fsyncDirectory(target.parent_path());
    }
    catch (...)
    {
        std::error_code ec;
        fs::remove_all(staging_path, ec);
        if (ec)
            LOG_WARNING(log, "Cannot remove {} after a failed SYSTEM BRANCH: {}", staging_path.string(), ec.message());
        throw;
    }

    LOG_INFO(log, "Branched the server into {}", target.string());
}

}
