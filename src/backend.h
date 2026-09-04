#pragma once

#include <QObject>
#include <QString>
#include <QTimer>
#include <QFileSystemWatcher>
#include <QFutureWatcher>
#include <QVariantList>

#include "gitstore.h"

// Backend is the whole app's state machine, exposed to QML as a context
// property. It owns the git-backed store, the save/commit debounce timers,
// and Omarchy's live theme colors.
class Backend : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)
    Q_PROPERTY(QString logPath READ logPath CONSTANT)
    Q_PROPERTY(bool darkMode READ darkMode NOTIFY themeChanged)
    Q_PROPERTY(QString themeBackground READ themeBackground NOTIFY themeChanged)
    Q_PROPERTY(QString themeForeground READ themeForeground NOTIFY themeChanged)
    Q_PROPERTY(QString themeAccent READ themeAccent NOTIFY themeChanged)
    Q_PROPERTY(QString themeSelection READ themeSelection NOTIFY themeChanged)
    Q_PROPERTY(QString themeMuted READ themeMuted NOTIFY themeChanged)
    Q_PROPERTY(QString currentTopic READ currentTopic NOTIFY currentTopicChanged)

public:
    explicit Backend(QObject *parent = nullptr);
    // Blocks until any in-flight background sync (see triggerSync()) has
    // finished — required, not just tidy: main.cpp holds Backend as a stack
    // variable, and a sync's worker thread captures `this` in its lambda.
    // Without this, destroying Backend while that thread is still touching
    // m_store is a use-after-free — see the .cpp for how directly this was
    // hit (onClosing: backend.save() on every window close).
    ~Backend() override;

    // Returns false (with lastError already set) if the store couldn't be
    // opened at all — the caller should refuse to start the UI in that case.
    bool start();

    QString status() const { return m_status; }
    QString lastError() const { return m_lastError; }
    QString logPath() const { return m_store.logPath(); }
    bool darkMode() const { return m_darkMode; }
    QString themeBackground() const { return m_themeBackground; }
    QString themeForeground() const { return m_themeForeground; }
    QString themeAccent() const { return m_themeAccent; }
    QString themeSelection() const { return m_themeSelection; }
    QString themeMuted() const { return m_themeMuted; }
    QString currentTopic() const { return m_store.currentTopic(); }

    Q_INVOKABLE QString initialText() const;
    Q_INVOKABLE void noteEdited(const QString &text);
    Q_INVOKABLE void save();
    Q_INVOKABLE void dismissError();

    Q_INVOKABLE QVariantList historyEntries() const;
    Q_INVOKABLE QString showAt(const QString &hash) const;
    Q_INVOKABLE void restoreAt(const QString &hash, const QString &isoTime);
    Q_INVOKABLE void copyToClipboard(const QString &text) const;

    // --- Topics (see gitstore.h) -------------------------------------
    // {branch, label, current} per entry, "main" first — for the Ctrl+T
    // switcher list.
    Q_INVOKABLE QVariantList topicList() const;
    // Flushes the current topic (save + commit, synchronously — same as
    // Ctrl+S) before switching, so nothing from it is ever lost. Returns
    // an empty string on success, else a message fit to show inline in
    // the switcher (e.g. "still saving — try again in a moment").
    Q_INVOKABLE QString switchTopic(const QString &branch);
    // Same flush-first behavior; empty string on success, else a message
    // fit to show inline in the creation prompt.
    Q_INVOKABLE QString createTopic(const QString &name);

signals:
    void statusChanged();
    void lastErrorChanged();
    void themeChanged();
    void currentTopicChanged();
    // Emitted after a restore so the live editor picks up the new text —
    // the editor's text is otherwise never pushed to it from C++, only read
    // from it via noteEdited(), to avoid a binding feedback loop. Also used
    // after switching/creating a topic, for the same reason.
    void textReloaded(const QString &text);

private slots:
    void onSaveTimeout();
    void onCommitTimeout();
    void onSyncFinished();

private:
    void setStatus(const QString &status);
    void fail(const QString &context, const QString &detail);
    void loadOmarchyTheme();
    void watchOmarchyTheme();
    // Commits (git add + commit) and, once that succeeds, kicks off a sync.
    // Shared by the debounced autosave path and Ctrl+S so both handle a
    // transient index.lock collision with an in-flight background sync the
    // same way: retry shortly, never raise the error overlay for it — see
    // the .cpp for why that specific race can now happen at all.
    void attemptCommit();
    // Dispatches GitStore::syncWithRemote() onto a background thread (via
    // QtConcurrent) so a slow or unreachable remote never blocks the UI
    // thread — called after a local commit, periodically while idle, and
    // once at startup. A no-op if a sync is already in flight or there's
    // unsaved/uncommitted local work in progress (never risk clobbering
    // that — see reloadIfChanged()).
    void triggerSync();
    // The periodic timer's actual slot. m_uncommitted staying stuck true
    // (for any reason — a missed timer, a suspend/resume gap, anything)
    // would otherwise block triggerSync() forever, since it deliberately
    // refuses to sync over unsaved/uncommitted work; this is the self-heal
    // that notices and retries the commit instead of just trying to sync
    // around it, so nothing can stay stuck longer than one interval.
    void periodicCheck();
    void reloadIfChanged();
    // Shared tail of switchTopic()/createTopic(): loads the freshly
    // checked-out branch's content into the live editor and resets local
    // state to match a just-opened note, then kicks off a sync for it.
    void applyTopicSwitch();

    GitStore m_store;
    QString m_pendingText;
    bool m_unsaved = false;
    bool m_uncommitted = false;
    QString m_status;
    QString m_lastError;
    QTimer m_saveTimer;
    QTimer m_commitTimer;
    QTimer m_periodicSyncTimer;
    QFutureWatcher<GitStore::SyncOutcome> m_syncWatcher;

    bool m_darkMode = true;
    QString m_themeBackground;
    QString m_themeForeground;
    QString m_themeAccent;
    QString m_themeSelection;
    QString m_themeMuted;
    QFileSystemWatcher m_themeWatcher;
};
