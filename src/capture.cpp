#include "capture.h"

#include "gitstore.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QLocalSocket>

#include <cstdint>
#include <cstdio>

namespace Capture {

QString dataDir() {
    const QString override = qEnvironmentVariable("OMARCHY_WORKING_MEMORY_DIR");
    if (!override.isEmpty())
        return override;
    QString base = qEnvironmentVariable("XDG_DATA_HOME");
    if (base.isEmpty())
        base = QDir::homePath() + QStringLiteral("/.local/share");
    return base + QStringLiteral("/omarchy-working-memory");
}

QString socketPath(const QString &dir) {
    QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
#ifdef Q_OS_MACOS
    // No XDG_RUNTIME_DIR, and $TMPDIR isn't guaranteed to reach a process
    // the browser starts, so the app and the native host could disagree:
    // use a fixed per-user directory both can work out from $HOME alone.
    if (runtime.isEmpty())
        runtime = QDir::homePath() + QStringLiteral("/Library/Caches");
#endif
    if (runtime.isEmpty())
        runtime = QDir::tempPath();
    const QByteArray hash = QCryptographicHash::hash(QDir(dir).absolutePath().toUtf8(), QCryptographicHash::Sha1).toHex().left(12);
    return runtime + QStringLiteral("/omarchy-working-memory-") + QString::fromLatin1(hash) + QStringLiteral(".sock");
}

QJsonObject captureReply(bool ok, const QString &error, int inboxCount) {
    QJsonObject reply{{QStringLiteral("ok"), ok}};
    if (ok)
        reply.insert(QStringLiteral("inbox"), inboxCount);
    else
        reply.insert(QStringLiteral("error"), error);
    return reply;
}

namespace {

// Native messaging framing: a 32-bit length in native byte order, then
// that many bytes of UTF-8 JSON — both directions.
bool readMessage(QJsonObject *out) {
    uint32_t len = 0;
    if (std::fread(&len, sizeof len, 1, stdin) != 1)
        return false; // the browser closed the pipe: done
    if (len > 4 * 1024 * 1024)
        return false;
    QByteArray buf(int(len), Qt::Uninitialized);
    if (len > 0 && std::fread(buf.data(), 1, len, stdin) != len)
        return false;
    *out = QJsonDocument::fromJson(buf).object();
    return true;
}

void writeMessage(const QJsonObject &msg) {
    const QByteArray json = QJsonDocument(msg).toJson(QJsonDocument::Compact);
    const uint32_t len = uint32_t(json.size());
    std::fwrite(&len, sizeof len, 1, stdout);
    std::fwrite(json.constData(), 1, json.size(), stdout);
    std::fflush(stdout);
}

// Ask the running app, if there is one. False if nothing's listening.
bool askApp(const QString &dir, const QJsonObject &request, QJsonObject *reply) {
    QLocalSocket sock;
    sock.connectToServer(socketPath(dir));
    if (!sock.waitForConnected(1000))
        return false;
    sock.write(QJsonDocument(request).toJson(QJsonDocument::Compact) + '\n');
    sock.flush();
    QByteArray line;
    while (!line.contains('\n')) {
        if (!sock.waitForReadyRead(15000))
            break;
        line += sock.readAll();
    }
    *reply = QJsonDocument::fromJson(line.trimmed()).object();
    if (reply->isEmpty())
        *reply = captureReply(false, QStringLiteral("no answer from the app"), 0);
    return true;
}

// No app running: write the item ourselves, under the repo's lock.
QJsonObject captureDirectly(const QJsonObject &request) {
    GitStore store;
    if (!store.open())
        return captureReply(false, store.errorString(), 0);
    const QString text = GitStore::formatCapture(request.value(QStringLiteral("text")).toString(),
                                                 request.value(QStringLiteral("title")).toString(),
                                                 request.value(QStringLiteral("url")).toString());
    if (store.addInboxItem(text).isEmpty())
        return captureReply(false, store.errorString(), 0);
    return captureReply(true, QString(), store.inboxItems().size());
}

}

int runNativeHost() {
    const QString dir = dataDir();
    QJsonObject request;
    while (readMessage(&request)) {
        const QString cmd = request.value(QStringLiteral("cmd")).toString();
        QJsonObject reply;
        if (cmd == QStringLiteral("capture")) {
            if (!askApp(dir, request, &reply))
                reply = captureDirectly(request);
        } else if (cmd == QStringLiteral("ping")) {
            reply = captureReply(true, QString(), 0);
        } else {
            reply = captureReply(false, QStringLiteral("unknown command: ") + cmd, 0);
        }
        writeMessage(reply);
    }
    return 0;
}

}
