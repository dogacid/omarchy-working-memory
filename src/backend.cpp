#include "backend.h"

#include <QClipboard>
#include <QColor>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QTextStream>
#include <QVariantMap>
#include <QtConcurrent>

namespace {
constexpr int kSaveDebounceMs = 1000;
constexpr int kCommitDebounceMs = 20000;
// How often an otherwise-idle window checks for cross-machine changes —
// the debounced-commit/Ctrl+S sync only ever runs off your *own* edits, so
// without this, a window left open but untouched would never learn about
// another machine's changes. 5 minutes balances staying reasonably current
// against not chattering the remote needlessly.
constexpr int kPeriodicSyncMs = 5 * 60 * 1000;
}

Backend::Backend(QObject *parent) : QObject(parent) {
    m_saveTimer.setSingleShot(true);
    m_commitTimer.setSingleShot(true);
    m_periodicSyncTimer.setInterval(kPeriodicSyncMs);
    connect(&m_saveTimer, &QTimer::timeout, this, &Backend::onSaveTimeout);
    connect(&m_commitTimer, &QTimer::timeout, this, &Backend::onCommitTimeout);
    connect(&m_periodicSyncTimer, &QTimer::timeout, this, &Backend::triggerSync);
    connect(&m_syncWatcher, &QFutureWatcher<GitStore::SyncOutcome>::finished, this, &Backend::onSyncFinished);
    connect(&m_themeWatcher, &QFileSystemWatcher::fileChanged, this, [this](const QString &) {
        loadOmarchyTheme();
        watchOmarchyTheme();
    });
    connect(&m_themeWatcher, &QFileSystemWatcher::directoryChanged, this, [this](const QString &) {
        loadOmarchyTheme();
        watchOmarchyTheme();
    });
}

Backend::~Backend() {
    // main.cpp holds Backend as a plain stack variable in main(), destroyed
    // the moment app.exec() returns. A background sync (see triggerSync())
    // can still be in flight at that point — the debounced commit right
    // before close, an earlier commit's sync that hasn't finished against a
    // slow remote, or the 5-minute periodic check — and its QtConcurrent
    // worker thread's `[this]`-capturing lambda would go on touching
    // m_store after Backend itself is gone: a real, confirmed
    // use-after-free (glibc tcache corruption), not a theoretical one.
    //
    // requestCancelSync() first, so this doesn't sit through the sync's
    // full multi-call sequence (ls-remote, pull, push — up to ~15s against
    // an unreachable remote): it stops the sync from *starting* its next
    // network call, so the wait below is bounded by whichever single call
    // is already running (up to ~5s), not the whole sequence.
    if (m_syncWatcher.isRunning()) {
        m_store.requestCancelSync();
        m_syncWatcher.waitForFinished();
    }
}

bool Backend::start() {
    if (!m_store.open()) {
        fail(QStringLiteral("start"), m_store.errorString());
        return false;
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

    // The window opens immediately with whatever's on disk; any
    // cross-machine update pulled in behind it lands moments later via the
    // same textReloaded path history-restore already uses — never worth
    // delaying the window appearing for.
    m_periodicSyncTimer.start();
    triggerSync();
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
    attemptCommit();
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
    setStatus(QStringLiteral("saved"));
    attemptCommit();
}

void Backend::attemptCommit() {
    bool committed = false;
    if (!m_store.commit(&committed)) {
        // A background sync (see triggerSync()) runs its own git processes
        // on another thread now, so — unlike before this app had any
        // threading at all — a local `git add`/`git commit` here can
        // genuinely collide with an in-flight `git pull`'s index lock.
        // That's transient and self-resolving, not a real failure worth
        // alarming the user over: just retry shortly instead of raising
        // the error overlay for it.
        if (m_store.errorString().contains(QStringLiteral("index.lock"))) {
            m_commitTimer.start(2000);
            return;
        }
        fail(QStringLiteral("commit"), m_store.errorString());
        return;
    }
    if (committed) {
        m_uncommitted = false;
        setStatus(QStringLiteral("synced"));
        triggerSync();
    }
}

void Backend::triggerSync() {
    if (m_syncWatcher.isRunning())
        return; // already syncing — this cycle's changes ride along next time
    // Never risk a pull-triggered reload clobbering keystrokes that aren't
    // even saved to disk yet, or racing a commit that hasn't happened yet.
    if (m_unsaved || m_uncommitted)
        return;
    // hasRemote() is a fast, local, no-network git call — cheap enough to
    // check synchronously here so a no-remote setup shows literally no
    // status change, ever, exactly as before this existed.
    if (!m_store.hasRemote())
        return;
    setStatus(QStringLiteral("syncing…"));
    m_syncWatcher.setFuture(QtConcurrent::run([this] { return m_store.syncWithRemote(); }));
}

void Backend::onSyncFinished() {
    const GitStore::SyncOutcome outcome = m_syncWatcher.result();
    if (!outcome.ranSync)
        return; // no remote configured — matches pre-sync behavior exactly

    // Reload regardless of outcome: a pull can change the file on disk even
    // when it fails midway (a merge conflict included) or partially — the
    // in-memory buffer must never silently overwrite that on the next
    // autosave.
    reloadIfChanged();

    if (outcome.conflict) {
        fail(QStringLiteral("sync"), outcome.error);
        return;
    }
    if (!outcome.ok) {
        m_store.logError(outcome.error);
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
