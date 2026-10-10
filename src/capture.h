#pragma once

#include <QJsonObject>
#include <QString>

// Getting captures from the browser into the inbox.
//
//   browser extension
//     → Chromium's native messaging: it starts this binary with
//       --native-host and exchanges length-prefixed JSON on stdin/stdout
//     → runNativeHost(): hands each request to the running app over a
//       local socket (one JSON object per line each way), so the app — the
//       one process that owns the repo — does the write and updates its
//       UI; with no app running, takes the repo's instance lock itself and
//       writes the inbox item directly (it never touches the working tree,
//       so there's nothing to coordinate with).
namespace Capture {

// The data directory: $OMARCHY_WORKING_MEMORY_DIR, else $XDG_DATA_HOME
// (or ~/.local/share) + /omarchy-working-memory.
QString dataDir();
// The running app's local socket for dir — in $XDG_RUNTIME_DIR, named per
// data directory so separate data dirs (tests, say) never cross wires.
QString socketPath(const QString &dir);

// The request as the app answers it: {"ok":true,"inbox":<count>} or
// {"ok":false,"error":"…"}. Also what runNativeHost() replies with when
// it has to write the item itself.
QJsonObject captureReply(bool ok, const QString &error, int inboxCount);

// The --native-host mode: serves requests until the browser closes stdin.
int runNativeHost();

}
