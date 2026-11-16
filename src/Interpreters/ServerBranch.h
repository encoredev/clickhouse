#pragma once

#include <Core/Types.h>
#include <Interpreters/Context_fwd.h>


namespace DB
{

/// `SYSTEM BRANCH TO 'target'`: copies the server, as of now, into a new data directory `target`, while it keeps running
/// and taking writes. A server started with `target` as its data directory has the databases and tables of this one,
/// as after a restart, and its users and SQL user-defined functions. The tables share their files with this server's
/// until either writes to them, so branching takes about the same time whatever the size of the data.
///
/// `target` must be an absolute path on the same file system as the data directory, outside the directories the
/// server keeps there, and must not exist yet. All databases but the system ones must use the `Atomic` engine, and
/// keep their tables' data on disks in the data directory.
void branchServer(const String & target, const ContextPtr & context);

}
