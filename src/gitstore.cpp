#include "gitstore.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QSaveFile>
#include <QStandardPaths>
#include <QStringList>
#include <QTextStream>

namespace {
constexpr auto kFileName = "working-memory.txt";
constexpr auto kErrorLogName = "error.log";
constexpr auto kFieldSep = "\x1f"; // unit separator: won't collide with real message text
}

GitStore::GitStore(QObject *parent) : QObject(parent) {}

bool GitStore::open() {
    const QString override = qEnvironmentVariable("OMARCHY_WORKING_MEMORY_DIR");
    if (!override.isEmpty()) {
        m_dir = override;
    } else {
        QString base = qEnvironmentVariable("XDG_DATA_HOME");
        if (base.isEmpty())
            base = QDir::homePath() + QStringLiteral("/.local/share");
        m_dir = base + QStringLiteral("/omarchy-working-memory");
    }
    m_path = m_dir + QLatin1Char('/') + QLatin1String(kFileName);

    if (!QDir().mkpath(m_dir)) {
        m_error = QStringLiteral("create data dir: ") + m_dir;
        return false;
    }

    if (!QDir(m_dir + QStringLiteral("/.git")).exists()) {
        if (!git({QStringLiteral("init"), QStringLiteral("-q")})) {
            m_error = QStringLiteral("git init: ") + m_error;
            return false;
        }
        ensureIdentity();
    }

    if (!QFile::exists(m_path)) {
        QFile f(m_path);
        if (!f.open(QIODevice::WriteOnly)) {
            m_error = QStringLiteral("create note file: ") + f.errorString();
            return false;
        }
        f.close();
    }

    // So the error log and the atomic-save tmp file never show up as
    // untracked cruft in this repo's own git status.
    const QString gitignore = m_dir + QStringLiteral("/.gitignore");
    if (!QFile::exists(gitignore)) {
        QFile f(gitignore);
        if (f.open(QIODevice::WriteOnly)) {
            f.write(QByteArray(kErrorLogName) + "\n*.tmp\n");
        }
    }

    return true;
}

QString GitStore::logPath() const {
    return m_dir + QLatin1Char('/') + QLatin1String(kErrorLogName);
}

QString GitStore::load(bool *ok) const {
    QFile f(m_path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        if (ok) *ok = false;
        return QString();
    }
    const QString content = QString::fromUtf8(f.readAll());
    if (ok) *ok = true;
    return content;
}

bool GitStore::save(const QString &content) {
    // Atomic write: QSaveFile writes to a temp file alongside the target
    // and renames it into place on commit(), so a crash mid-write never
    // leaves a truncated note file.
    QSaveFile f(m_path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Text)) {
        m_error = f.errorString();
        return false;
    }
    f.write(content.toUtf8());
    if (!f.commit()) {
        m_error = f.errorString();
        return false;
    }
    return true;
}

bool GitStore::commit(bool *committed) {
    const QString content = load();
    const QString msg = previewLine(content) + QStringLiteral("  (")
        + QDateTime::currentDateTime().toString(QStringLiteral("yyyy-MM-dd HH:mm")) + QLatin1Char(')');
    return commitWithMessage(msg, committed);
}

bool GitStore::commitWithMessage(const QString &message, bool *committed) {
    if (committed) *committed = false;

    if (!git({QStringLiteral("add"), QLatin1String(kFileName)})) {
        m_error = QStringLiteral("git add: ") + m_error;
        return false;
    }

    bool ok = false;
    const QString diff = gitOutput({QStringLiteral("diff"), QStringLiteral("--cached"), QStringLiteral("--name-only")}, &ok);
    if (!ok) {
        m_error = QStringLiteral("git diff: ") + m_error;
        return false;
    }
    if (diff.trimmed().isEmpty())
        return true; // nothing to commit — not a failure

    if (!git({QStringLiteral("commit"), QStringLiteral("-q"), QStringLiteral("-m"), message})) {
        m_error = QStringLiteral("git commit: ") + m_error;
        return false;
    }
    if (committed) *committed = true;
    return true;
}

QList<GitStore::Commit> GitStore::log(bool *ok) const {
    bool queryOk = false;
    const QString out = gitOutput({
        QStringLiteral("log"),
        QStringLiteral("--format=%H") + QLatin1String(kFieldSep) + QStringLiteral("%cI") + QLatin1String(kFieldSep) + QStringLiteral("%s"),
        QStringLiteral("--"), QLatin1String(kFileName)
    }, &queryOk);

    QList<Commit> commits;
    if (!queryOk) {
        // A brand new repo with no commits yet exits non-zero here; that's
        // an empty history, not a failure.
        if (out.trimmed().isEmpty()) {
            if (ok) *ok = true;
            return commits;
        }
        if (ok) *ok = false;
        return commits;
    }

    const QStringList lines = out.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    for (const QString &line : lines) {
        const QStringList parts = line.split(QLatin1String(kFieldSep));
        if (parts.size() != 3)
            continue;
        const QDateTime t = QDateTime::fromString(parts.at(1), Qt::ISODate);
        if (!t.isValid())
            continue;
        commits.append({parts.at(0), t, parts.at(2)});
    }
    if (ok) *ok = true;
    return commits;
}

QString GitStore::showAt(const QString &hash, bool *ok) const {
    bool queryOk = false;
    const QString out = gitOutput({QStringLiteral("show"), hash + QLatin1Char(':') + QLatin1String(kFileName)}, &queryOk);
    if (ok) *ok = queryOk;
    return out;
}

bool GitStore::restoreAt(const QString &hash, const QDateTime &at) {
    bool ok = false;
    const QString content = showAt(hash, &ok);
    if (!ok) {
        m_error = QStringLiteral("git show: ") + m_error;
        return false;
    }
    if (!save(content))
        return false;

    const QString message = QStringLiteral("restore from ") + shortHash(hash) + QStringLiteral(" (")
        + at.toString(QStringLiteral("yyyy-MM-dd HH:mm")) + QStringLiteral("): ") + previewLine(content);
    return commitWithMessage(message, nullptr);
}

void GitStore::logError(const QString &message) const {
    QFile f(logPath());
    if (!f.open(QIODevice::Append | QIODevice::Text))
        return;
    QTextStream out(&f);
    out << QDateTime::currentDateTime().toString(Qt::ISODate) << '\t' << message << '\n';
}

// previewLine picks a short, human-recognizable snippet for the commit
// message — the point is browsability: scanning history for "that thing
// about the car insurance" only works if the message carries actual
// content, not just a timestamp.
QString GitStore::previewLine(const QString &content) {
    const QStringList lines = content.split(QLatin1Char('\n'));
    for (QString line : lines) {
        line = line.trimmed();
        if (line.isEmpty())
            continue;
        constexpr int maxChars = 60;
        if (line.size() > maxChars)
            return line.left(maxChars) + QStringLiteral("…");
        return line;
    }
    return QStringLiteral("(empty)");
}

QString GitStore::shortHash(const QString &hash) {
    return hash.left(8);
}

void GitStore::ensureIdentity() {
    // Only set a local commit identity when the user has none configured at
    // all (global or system) — never override one they already have.
    if (git({QStringLiteral("config"), QStringLiteral("user.name")}))
        return;
    git({QStringLiteral("config"), QStringLiteral("user.name"), QStringLiteral("Omarchy Working Memory")});
    git({QStringLiteral("config"), QStringLiteral("user.email"), QStringLiteral("working-memory@localhost")});
}

bool GitStore::git(const QStringList &args) const {
    QProcess proc;
    proc.setWorkingDirectory(m_dir);
    proc.start(QStringLiteral("git"), args);
    if (!proc.waitForFinished(10000)) {
        m_error = QStringLiteral("git ") + args.join(QLatin1Char(' ')) + QStringLiteral(" timed out");
        return false;
    }
    if (proc.exitStatus() != QProcess::NormalExit || proc.exitCode() != 0) {
        m_error = QString::fromUtf8(proc.readAllStandardError()).trimmed();
        return false;
    }
    return true;
}

QString GitStore::gitOutput(const QStringList &args, bool *ok) const {
    QProcess proc;
    proc.setWorkingDirectory(m_dir);
    proc.start(QStringLiteral("git"), args);
    if (!proc.waitForFinished(10000)) {
        m_error = QStringLiteral("git ") + args.join(QLatin1Char(' ')) + QStringLiteral(" timed out");
        if (ok) *ok = false;
        return QString();
    }
    const QString out = QString::fromUtf8(proc.readAllStandardOutput());
    if (proc.exitStatus() != QProcess::NormalExit || proc.exitCode() != 0) {
        m_error = QString::fromUtf8(proc.readAllStandardError()).trimmed();
        if (ok) *ok = false;
        return out;
    }
    if (ok) *ok = true;
    return out;
}
