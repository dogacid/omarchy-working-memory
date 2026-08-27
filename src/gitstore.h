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

private:
    bool commitWithMessage(const QString &message, bool *committed);
    bool git(const QStringList &args) const;
    QString gitOutput(const QStringList &args, bool *ok) const;
    void ensureIdentity();
    static QString previewLine(const QString &content);
    static QString shortHash(const QString &hash);

    QString m_dir;
    QString m_path;
    mutable QString m_error;
};
