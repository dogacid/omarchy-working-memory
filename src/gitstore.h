#pragma once

#include <QObject>
#include <QString>
#include <QDateTime>
#include <QList>

// GitStore owns the working-memory text file and the git repo that versions
// it. Every operation shells out to the real `git` binary (via QProcess) —
// no library, no reimplemented diffing — so the file's history is just
// `git log`/`git show` away outside the app too.
class GitStore : public QObject {
    Q_OBJECT

public:
    struct Commit {
        QString hash;
        QDateTime time;
        QString message;
    };

    explicit GitStore(QObject *parent = nullptr);

    // Resolves the data directory ($OMARCHY_WORKING_MEMORY_DIR, else
    // $XDG_DATA_HOME or ~/.local/share, then /omarchy-working-memory) and
    // ensures the directory, git repo, and note file all exist. Returns
    // false (with errorString() set) if anything about that setup fails.
    bool open();

    QString path() const { return m_path; }
    QString dir() const { return m_dir; }
    QString logPath() const;
    QString errorString() const { return m_error; }

    QString load(bool *ok = nullptr) const;
    bool save(const QString &content);

    // Commits the note file if it has changes; returns false only on a real
    // git failure, true (with committed set) otherwise.
    bool commit(bool *committed = nullptr);

    QList<Commit> log(bool *ok = nullptr) const;
    QString showAt(const QString &hash, bool *ok = nullptr) const;
    bool restoreAt(const QString &hash, const QDateTime &at);

    void logError(const QString &message) const;

    // Cross-machine sync against a plain `git remote` — absent by default,
    // so every method here is a silent no-op until the user runs
    // `git remote add origin <url>` in the data dir themselves. No
    // credentials are ever managed here; network calls run non-interactive
    // and fail fast (see the `network` param on git()/gitOutput()).
    bool hasRemote() const;
    // On failure, *conflict distinguishes a real merge conflict (needs the
    // user) from a routine failure like being offline (doesn't).
    bool pullFromRemote(bool *conflict = nullptr);
    bool pushToRemote();

private:
    bool commitWithMessage(const QString &message, bool *committed);
    bool git(const QStringList &args, bool network = false) const;
    QString gitOutput(const QStringList &args, bool *ok, bool network = false) const;
    void ensureIdentity();
    // Normalizes onto a single, fixed branch name regardless of this
    // machine's `init.defaultBranch` — otherwise two machines with
    // different git defaults would push/pull different refs on the same
    // remote and silently never reconcile.
    void ensureBranch(const QString &name);
    QString currentBranch(bool *ok) const;
    bool hasCommits() const;
    static QString previewLine(const QString &content);
    static QString shortHash(const QString &hash);

    QString m_dir;
    QString m_path;
    mutable QString m_error;
};
