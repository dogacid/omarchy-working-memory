#include "backend.h"

#include <QClipboard>
#include <QColor>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QTextStream>
#include <QVariantMap>

namespace {
constexpr int kSaveDebounceMs = 1000;
constexpr int kCommitDebounceMs = 20000;
}

Backend::Backend(QObject *parent) : QObject(parent) {
    m_saveTimer.setSingleShot(true);
    m_commitTimer.setSingleShot(true);
    connect(&m_saveTimer, &QTimer::timeout, this, &Backend::onSaveTimeout);
    connect(&m_commitTimer, &QTimer::timeout, this, &Backend::onCommitTimeout);
    connect(&m_themeWatcher, &QFileSystemWatcher::fileChanged, this, [this](const QString &) {
        loadOmarchyTheme();
        watchOmarchyTheme();
    });
    connect(&m_themeWatcher, &QFileSystemWatcher::directoryChanged, this, [this](const QString &) {
        loadOmarchyTheme();
        watchOmarchyTheme();
    });
}

bool Backend::start() {
    if (!m_store.open()) {
        fail(QStringLiteral("start"), m_store.errorString());
        return false;
    }

    // Pull-only at startup — there's nothing local to publish yet — so the
    // very first thing the editor shows is the freshest cross-machine
    // content, conflict markers included if a real conflict is waiting.
    bool conflict = false;
    if (!m_store.pullFromRemote(&conflict)) {
        if (conflict)
            fail(QStringLiteral("sync"), m_store.errorString());
        else
            m_store.logError(m_store.errorString());
    }

    bool ok = false;
    m_pendingText = m_store.load(&ok);
    if (!ok) {
        fail(QStringLiteral("load"), m_store.errorString());
        return false;
    }

    loadOmarchyTheme();
    watchOmarchyTheme();
    setStatus(QStringLiteral("synced"));
    return true;
}

QString Backend::initialText() const {
    return m_pendingText;
}

void Backend::noteEdited(const QString &text) {
    m_pendingText = text;
    m_unsaved = true;
    setStatus(QStringLiteral("editing…"));
    m_saveTimer.start(kSaveDebounceMs);
}

void Backend::onSaveTimeout() {
    if (!m_unsaved)
        return;
    if (!m_store.save(m_pendingText)) {
        fail(QStringLiteral("save"), m_store.errorString());
        return;
    }
    m_unsaved = false;
    m_uncommitted = true;
    setStatus(QStringLiteral("saved"));
    m_commitTimer.start(kCommitDebounceMs);
}

void Backend::onCommitTimeout() {
    if (!m_uncommitted || m_unsaved)
        return;
    bool committed = false;
    if (!m_store.commit(&committed)) {
        fail(QStringLiteral("commit"), m_store.errorString());
        return;
    }
    if (committed) {
        m_uncommitted = false;
        setStatus(QStringLiteral("synced"));
        syncAfterCommit();
    }
}

void Backend::save() {
    m_saveTimer.stop();
    m_commitTimer.stop();

    if (!m_store.save(m_pendingText)) {
        fail(QStringLiteral("save"), m_store.errorString());
        return;
    }
    m_unsaved = false;
    m_uncommitted = true;

    bool committed = false;
    if (!m_store.commit(&committed)) {
        fail(QStringLiteral("commit"), m_store.errorString());
        return;
    }
    m_uncommitted = false;
    setStatus(QStringLiteral("saved"));
    syncAfterCommit();
}

void Backend::syncAfterCommit() {
    if (!m_store.hasRemote())
        return;

    bool conflict = false;
    const bool pullOk = m_store.pullFromRemote(&conflict);
    // Reload regardless of outcome: a pull can change the file on disk even
    // when it fails midway (a merge conflict included) or partially — the
    // in-memory buffer must never silently overwrite that on the next
    // autosave.
    reloadIfChanged();

    if (!pullOk) {
        if (conflict) {
            fail(QStringLiteral("sync"), m_store.errorString());
        } else {
            m_store.logError(m_store.errorString());
            setStatus(QStringLiteral("offline"));
        }
        return;
    }

    if (!m_store.pushToRemote()) {
        m_store.logError(m_store.errorString());
        setStatus(QStringLiteral("offline"));
        return;
    }

    setStatus(QStringLiteral("synced"));
}

void Backend::reloadIfChanged() {
    bool ok = false;
    const QString content = m_store.load(&ok);
    if (!ok || content == m_pendingText)
        return;

    m_pendingText = content;
    m_unsaved = false;
    m_uncommitted = false;
    emit textReloaded(content);
}

void Backend::dismissError() {
    m_lastError.clear();
    emit lastErrorChanged();
    // Restore the retry safety net: if the failure happened mid-debounce,
    // pick the cycle back up rather than silently stalling until the next
    // keystroke.
    if (m_unsaved)
        m_saveTimer.start(kSaveDebounceMs);
    else if (m_uncommitted)
        m_commitTimer.start(kCommitDebounceMs);
}

QVariantList Backend::historyEntries() const {
    bool ok = false;
    const QList<GitStore::Commit> commits = m_store.log(&ok);
    if (!ok) {
        const_cast<Backend *>(this)->fail(QStringLiteral("history"), m_store.errorString());
        return {};
    }

    QVariantList entries;
    entries.reserve(commits.size());
    for (const GitStore::Commit &c : commits) {
        QVariantMap m;
        m[QStringLiteral("hash")] = c.hash;
        m[QStringLiteral("isoTime")] = c.time.toString(Qt::ISODate);
        m[QStringLiteral("time")] = c.time.toString(QStringLiteral("ddd MMM d  HH:mm"));
        m[QStringLiteral("message")] = c.message;
        entries.append(m);
    }
    return entries;
}

QString Backend::showAt(const QString &hash) const {
    bool ok = false;
    const QString content = m_store.showAt(hash, &ok);
    if (!ok) {
        const_cast<Backend *>(this)->fail(QStringLiteral("history"), m_store.errorString());
        return {};
    }
    return content;
}

void Backend::restoreAt(const QString &hash, const QString &isoTime) {
    const QDateTime at = QDateTime::fromString(isoTime, Qt::ISODate);
    if (!m_store.restoreAt(hash, at)) {
        fail(QStringLiteral("restore"), m_store.errorString());
        return;
    }

    bool ok = false;
    const QString content = m_store.load(&ok);
    if (!ok) {
        fail(QStringLiteral("load"), m_store.errorString());
        return;
    }

    m_pendingText = content;
    m_unsaved = false;
    m_uncommitted = false;
    m_saveTimer.stop();
    m_commitTimer.stop();
    setStatus(QStringLiteral("restored ") + at.toString(QStringLiteral("MMM d HH:mm")));
    emit textReloaded(content);
}

void Backend::copyToClipboard(const QString &text) const {
    if (auto *clipboard = QGuiApplication::clipboard())
        clipboard->setText(text);
}

void Backend::setStatus(const QString &status) {
    if (m_status == status)
        return;
    m_status = status;
    emit statusChanged();
}

void Backend::fail(const QString &context, const QString &detail) {
    m_saveTimer.stop();
    m_commitTimer.stop();
    m_lastError = detail.isEmpty() ? context : (context + QStringLiteral(": ") + detail);
    m_store.logError(m_lastError);
    emit lastErrorChanged();
}

// Reads Omarchy's live theme colors so the app matches the desktop instead
// of guessing at a fixed palette. Falls back to a reasonable dark palette
// (and a luminance-based light/dark guess) when colors.toml is missing —
// e.g. when running outside Omarchy.
void Backend::loadOmarchyTheme() {
    m_themeBackground = QStringLiteral("#1a1b26");
    m_themeForeground = QStringLiteral("#a9b1d6");
    m_themeAccent = QStringLiteral("#7aa2f7");
    m_themeSelection = QStringLiteral("#292e42");
    m_themeMuted = QStringLiteral("#414868");

    const QString colorsPath = QDir::homePath()
        + QStringLiteral("/.local/state/omarchy/current/theme/colors.toml");
    QString mode;
    QFile file(colorsPath);
    if (file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        QTextStream in(&file);
        while (!in.atEnd()) {
            const QString line = in.readLine().trimmed();
            if (line.isEmpty() || line.startsWith(QLatin1Char('#')))
                continue;

            const int eq = line.indexOf(QLatin1Char('='));
            if (eq < 0)
                continue;

            const QString key = line.left(eq).trimmed();
            QString value = line.mid(eq + 1).trimmed();
            if (value.size() >= 2
                && ((value.front() == QLatin1Char('"') && value.back() == QLatin1Char('"'))
                    || (value.front() == QLatin1Char('\'') && value.back() == QLatin1Char('\''))))
                value = value.mid(1, value.size() - 2);

            if (key == QStringLiteral("mode")) mode = value;
            else if (key == QStringLiteral("background")) m_themeBackground = value;
            else if (key == QStringLiteral("foreground")) m_themeForeground = value;
            else if (key == QStringLiteral("accent")) m_themeAccent = value;
            else if (key == QStringLiteral("selection")) m_themeSelection = value;
            else if (key == QStringLiteral("muted")) m_themeMuted = value;
        }
    }

    if (mode == QStringLiteral("dark")) {
        m_darkMode = true;
    } else if (mode == QStringLiteral("light")) {
        m_darkMode = false;
    } else {
        const QColor bg(m_themeBackground);
        if (bg.isValid()) {
            const double luminance = 0.299 * bg.redF() + 0.587 * bg.greenF() + 0.114 * bg.blueF();
            m_darkMode = luminance < 0.5;
        }
    }

    emit themeChanged();
}

void Backend::watchOmarchyTheme() {
    const QStringList watched = m_themeWatcher.files() + m_themeWatcher.directories();
    if (!watched.isEmpty())
        m_themeWatcher.removePaths(watched);

    const QString currentDir = QDir::homePath() + QStringLiteral("/.local/state/omarchy/current");
    const QString themeDir = currentDir + QStringLiteral("/theme");
    const QString colorsPath = themeDir + QStringLiteral("/colors.toml");

    if (QDir(currentDir).exists())
        m_themeWatcher.addPath(currentDir);
    if (QDir(themeDir).exists())
        m_themeWatcher.addPath(themeDir);
    if (QFile::exists(colorsPath))
        m_themeWatcher.addPath(colorsPath);
}
