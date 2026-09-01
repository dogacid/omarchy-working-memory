#pragma once

#include <QObject>
#include <QString>
#include <QTimer>
#include <QFileSystemWatcher>
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

public:
    explicit Backend(QObject *parent = nullptr);

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

    Q_INVOKABLE QString initialText() const;
    Q_INVOKABLE void noteEdited(const QString &text);
    Q_INVOKABLE void save();
    Q_INVOKABLE void dismissError();

    Q_INVOKABLE QVariantList historyEntries() const;
    Q_INVOKABLE QString showAt(const QString &hash) const;
    Q_INVOKABLE void restoreAt(const QString &hash, const QString &isoTime);
    Q_INVOKABLE void copyToClipboard(const QString &text) const;

signals:
    void statusChanged();
    void lastErrorChanged();
    void themeChanged();
    // Emitted after a restore so the live editor picks up the new text —
    // the editor's text is otherwise never pushed to it from C++, only read
    // from it via noteEdited(), to avoid a binding feedback loop.
    void textReloaded(const QString &text);

private slots:
    void onSaveTimeout();
    void onCommitTimeout();

private:
    void setStatus(const QString &status);
    void fail(const QString &context, const QString &detail);
    void loadOmarchyTheme();
    void watchOmarchyTheme();
    // Best-effort pull-then-push against origin, piggybacked on the
    // existing save/commit debounce points — a silent no-op with no remote
    // configured. Reloads the editor if a pull changed the file on disk (see
    // reloadIfChanged()) so a background merge/conflict is never silently
    // clobbered by the next autosave.
    void syncAfterCommit();
    void reloadIfChanged();

    GitStore m_store;
    QString m_pendingText;
    bool m_unsaved = false;
    bool m_uncommitted = false;
    QString m_status;
    QString m_lastError;
    QTimer m_saveTimer;
    QTimer m_commitTimer;

    bool m_darkMode = true;
    QString m_themeBackground;
    QString m_themeForeground;
    QString m_themeAccent;
    QString m_themeSelection;
    QString m_themeMuted;
    QFileSystemWatcher m_themeWatcher;
};
