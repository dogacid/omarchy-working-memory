#include "gitstore.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QProcessEnvironment>
#include <QSaveFile>
#include <QSet>
#include <QStandardPaths>
#include <QStringList>
#include <QTextStream>

namespace {
constexpr auto kFileName = "working-memory.txt";
constexpr auto kErrorLogName = "error.log";
constexpr auto kFieldSep = "\x1f"; // unit separator: won't collide with real message text
constexpr auto kBranch = "main";
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
        setError(QStringLiteral("create data dir: ") + m_dir);
        return false;
    }

    if (!QDir(m_dir + QStringLiteral("/.git")).exists()) {
        if (!git({QStringLiteral("init"), QStringLiteral("-q")})) {
            setError(QStringLiteral("git init: ") + errorString());
            return false;
        }
        ensureIdentity();
        // Brand new repo: normalize onto "main" immediately, same as
        // always.
        ensureBranch(QLatin1String(kBranch));
    } else {
        // An existing repo, though: only rename if it's still sitting on
        // the pre-topics-feature default ("master") — never force an
        // established "main" or, critically, an active "topic/*" branch
        // back to main. Without this guard every launch would silently
        // discard whichever topic the user was last on.
        bool ok = false;
        const QString branch = currentBranch(&ok);
        if (ok && branch == QStringLiteral("master"))
            ensureBranch(QLatin1String(kBranch));
    }

    if (!QFile::exists(m_path)) {
        QFile f(m_path);
        if (!f.open(QIODevice::WriteOnly)) {
            setError(QStringLiteral("create note file: ") + f.errorString());
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

    // A union merge driver for the note: on any conflicting hunk, git keeps
    // *both* sides concatenated instead of leaving <<<<<<< markers to
    // resolve by hand. This is what makes syncing smooth rather than
    // error-prone — most importantly for the very first sync on a machine
    // that already had local history before a remote existed, which is
    // otherwise an "unrelated histories" merge that can conflict across
    // nearly the whole file. Nothing is ever lost this way, only
    // occasionally duplicated, which is the right trade for a mostly-append
    // scratchpad. Written on every open() (not just when missing) so an
    // existing install picks this up on upgrade without the user doing
    // anything.
    const QString gitattributes = m_dir + QStringLiteral("/.gitattributes");
    QFile attrFile(gitattributes);
    if (attrFile.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        attrFile.write(QByteArray(kFileName) + " merge=union\n");
    }

    return true;
}

QString GitStore::logPath() const {
    return m_dir + QLatin1Char('/') + QLatin1String(kErrorLogName);
}

QString GitStore::errorString() const {
    QMutexLocker locker(&m_errorMutex);
    return m_error;
}

void GitStore::setError(const QString &error) const {
    QMutexLocker locker(&m_errorMutex);
    m_error = error;
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
        setError(f.errorString());
        return false;
    }
    f.write(content.toUtf8());
    if (!f.commit()) {
        setError(f.errorString());
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
        setError(QStringLiteral("git add: ") + errorString());
        return false;
    }

    bool ok = false;
    const QString diff = gitOutput({QStringLiteral("diff"), QStringLiteral("--cached"), QStringLiteral("--name-only")}, &ok);
    if (!ok) {
        setError(QStringLiteral("git diff: ") + errorString());
        return false;
    }
    if (diff.trimmed().isEmpty())
        return true; // nothing to commit — not a failure

    if (!git({QStringLiteral("commit"), QStringLiteral("-q"), QStringLiteral("-m"), message})) {
        setError(QStringLiteral("git commit: ") + errorString());
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
        setError(QStringLiteral("git show: ") + errorString());
        return false;
    }
    if (!save(content))
        return false;

    const QString message = QStringLiteral("restore from ") + shortHash(hash) + QStringLiteral(" (")
        + at.toString(QStringLiteral("yyyy-MM-dd HH:mm")) + QStringLiteral("): ") + previewLine(content);
    return commitWithMessage(message, nullptr);
}

bool GitStore::localBranchExists(const QString &branch) const {
    return git({QStringLiteral("rev-parse"), QStringLiteral("--verify"), QStringLiteral("-q"),
                QStringLiteral("refs/heads/") + branch});
}

bool GitStore::remoteBranchExists(const QString &branch) const {
    return git({QStringLiteral("rev-parse"), QStringLiteral("--verify"), QStringLiteral("-q"),
                QStringLiteral("refs/remotes/origin/") + branch});
}

QString GitStore::slugify(const QString &name) {
    const QString lower = name.trimmed().toLower();
    QString out;
    bool lastWasDash = true; // starts true so a leading run of junk doesn't produce a leading "-"
    for (const QChar &c : lower) {
        if (c.isLetterOrNumber()) {
            out += c;
            lastWasDash = false;
        } else if (!lastWasDash) {
            out += QLatin1Char('-');
            lastWasDash = true;
        }
    }
    while (out.endsWith(QLatin1Char('-')))
        out.chop(1);
    return out;
}

QStringList GitStore::topicBranches() const {
    bool ok = false;
    const QString out = gitOutput({
        QStringLiteral("for-each-ref"), QStringLiteral("--format=%(refname)"),
        QStringLiteral("refs/heads/main"), QStringLiteral("refs/heads/topic/*"),
        QStringLiteral("refs/remotes/origin/main"), QStringLiteral("refs/remotes/origin/topic/*")
    }, &ok);
    if (!ok)
        return {};

    QSet<QString> names;
    for (const QString &line : out.split(QLatin1Char('\n'), Qt::SkipEmptyParts)) {
        if (line.startsWith(QStringLiteral("refs/heads/")))
            names.insert(line.mid(11));
        else if (line.startsWith(QStringLiteral("refs/remotes/origin/")))
            names.insert(line.mid(20));
    }

    QStringList list(names.begin(), names.end());
    list.sort();
    if (list.removeOne(QStringLiteral("main")))
        list.prepend(QStringLiteral("main")); // always first, if it exists at all
    return list;
}

QString GitStore::currentTopic() const {
    bool ok = false;
    const QString branch = currentBranch(&ok);
    if (!ok)
        return QString();
    if (branch.startsWith(QStringLiteral("topic/")))
        return branch.mid(6);
    return branch;
}

bool GitStore::checkoutBranch(const QString &branch) {
    if (localBranchExists(branch)) {
        if (!git({QStringLiteral("checkout"), QStringLiteral("-q"), branch})) {
            setError(QStringLiteral("git checkout: ") + errorString());
            return false;
        }
        return true;
    }
    if (remoteBranchExists(branch)) {
        // Known only from a fetch so far (created on another machine) —
        // create the local branch tracking it, rather than requiring the
        // caller to know the difference.
        if (!git({QStringLiteral("checkout"), QStringLiteral("-q"), QStringLiteral("-b"), branch,
                   QStringLiteral("--track"), QStringLiteral("origin/") + branch})) {
            setError(QStringLiteral("git checkout: ") + errorString());
            return false;
        }
        return true;
    }
    setError(QStringLiteral("no such topic: ") + branch);
    return false;
}

QString GitStore::createTopicBranch(const QString &name) {
    const QString slug = slugify(name);
    if (slug.isEmpty())
        return QStringLiteral("enter a name for the topic");
    const QString branch = QStringLiteral("topic/") + slug;

    // "Create" should mean create — a name collision is reported back
    // rather than silently switching to the existing topic of that name;
    // Ctrl+T already covers "switch to an existing one".
    if (localBranchExists(branch) || remoteBranchExists(branch))
        return QStringLiteral("a topic named \"") + slug + QStringLiteral("\" already exists");

    if (!git({QStringLiteral("checkout"), QStringLiteral("-q"), QStringLiteral("-b"), branch}))
        return QStringLiteral("git checkout -b: ") + errorString();

    // Blank slate: clear the note and commit that as the topic's own
    // starting point, independent of whatever main (or wherever this was
    // branched from) currently says. A no-op, harmlessly, if the source
    // content was already empty — commitWithMessage() already treats "no
    // diff" as success, not a failure.
    if (!save(QString()))
        return QStringLiteral("create topic file: ") + errorString();
    if (!commitWithMessage(QStringLiteral("Start topic: ") + slug, nullptr))
        return QStringLiteral("git commit: ") + errorString();

    return QString();
}

bool GitStore::hasRemote() const {
    bool ok = false;
    const QString out = gitOutput({QStringLiteral("remote")}, &ok);
    if (!ok)
        return false;
    const QStringList remotes = out.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    return remotes.contains(QStringLiteral("origin"));
}

GitStore::SyncOutcome GitStore::syncWithRemote() {
    SyncOutcome outcome;
    if (!hasRemote())
        return outcome; // ranSync stays false: no remote configured, nothing to do
    outcome.ranSync = true;

    // Fetch every branch, not just the current one — this is the only
    // place network I/O already happens on a schedule, so it's the natural
    // place to keep remote-tracking refs for *other* topic branches fresh
    // too (so one created on another machine shows up in topicBranches()
    // here without ever having been checked out). Best-effort: a failure
    // here isn't surfaced on its own — the branch-specific pull below will
    // fail for the same underlying reason (offline, etc.) and that's what
    // gets reported.
    if (!syncCancelled())
        git({QStringLiteral("fetch"), QStringLiteral("origin")}, /*network=*/true);

    bool conflict = false;
    if (!pullFromRemote(&conflict)) {
        outcome.conflict = conflict;
        outcome.error = errorString();
        return outcome;
    }
    if (!pushToRemote()) {
        outcome.error = errorString();
        return outcome;
    }
    outcome.ok = true;
    return outcome;
}

void GitStore::requestCancelSync() {
    m_cancelSync.store(true, std::memory_order_relaxed);
}

bool GitStore::syncCancelled() const {
    if (!m_cancelSync.load(std::memory_order_relaxed))
        return false;
    setError(QStringLiteral("sync cancelled"));
    return true;
}

bool GitStore::pullFromRemote(bool *conflict) {
    if (conflict) *conflict = false;
    if (!hasRemote())
        return true; // no remote configured: silent no-op

    bool branchOk = false;
    const QString branch = currentBranch(&branchOk);
    if (!branchOk) {
        setError(QStringLiteral("git branch: ") + errorString());
        return false;
    }

    if (syncCancelled())
        return false;

    // A remote that's reachable but doesn't have this branch yet (a brand
    // new/empty remote — true for every machine's very first sync) isn't a
    // failure: there's simply nothing to pull. Checking this separately,
    // rather than just trying `pull` and treating "couldn't find remote
    // ref" as routine, matters because the caller only pushes after a
    // successful pull — without this check the first machine to ever sync
    // could never actually publish anything.
    bool lsRemoteOk = false;
    const QString refs = gitOutput({QStringLiteral("ls-remote"), QStringLiteral("origin"), branch}, &lsRemoteOk, /*network=*/true);
    if (!lsRemoteOk) {
        setError(QStringLiteral("git ls-remote: ") + errorString());
        return false;
    }
    if (refs.trimmed().isEmpty())
        return true; // nothing on the remote yet — nothing to pull

    if (syncCancelled())
        return false;

    // open() creates working-memory.txt directly on disk, outside git, so on
    // a repo with no commits yet it always exists but untracked — and git
    // refuses to pull anything that would overwrite an untracked file. Since
    // zero local commits means that file can't hold anything the user has
    // ever saved, it's safe to clear it so the incoming history lands
    // cleanly (a plain fast-forward, not a real merge, in this case).
    if (!hasCommits())
        QFile::remove(m_path);

    // --allow-unrelated-histories is required, not optional: every machine
    // creates its own independent init history in open() before origin is
    // ever added, so a second machine's very first pull is always
    // reconciling unrelated roots by construction. --no-rebase is equally
    // required, not just a default worth stating: without it, a user with
    // `pull.rebase = true` in their global git config (common, and true on
    // the machine this was built on) silently gets a rebase instead of a
    // merge, which on conflict leaves the repo mid-rebase — a state
    // commitWithMessage()'s plain add+commit cannot resume, unlike the
    // normal "unmerged paths" state a real merge conflict leaves. Confirmed
    // directly: without this flag, a conflict test here left the repo stuck
    // in `rebase-merge` instead of resolving via the ordinary save/commit
    // flow.
    if (git({QStringLiteral("pull"), QStringLiteral("--no-edit"), QStringLiteral("--no-rebase"),
             QStringLiteral("--allow-unrelated-histories"),
             QStringLiteral("origin"), branch}, /*network=*/true))
        return true;

    bool unmergedOk = false;
    const QString unmerged = gitOutput({QStringLiteral("ls-files"), QStringLiteral("-u")}, &unmergedOk);
    if (unmergedOk && !unmerged.trimmed().isEmpty()) {
        if (conflict) *conflict = true;
        setError(QStringLiteral("sync conflict — resolve the markers in the note and save: ") + errorString());
    } else {
        setError(QStringLiteral("git pull: ") + errorString());
    }
    return false;
}

bool GitStore::pushToRemote() {
    if (!hasRemote())
        return true; // no remote configured: silent no-op

    bool branchOk = false;
    const QString branch = currentBranch(&branchOk);
    if (!branchOk) {
        setError(QStringLiteral("git branch: ") + errorString());
        return false;
    }

    if (syncCancelled())
        return false;

    if (!git({QStringLiteral("push"), QStringLiteral("origin"), branch}, /*network=*/true)) {
        setError(QStringLiteral("git push: ") + errorString());
        return false;
    }
    return true;
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

void GitStore::ensureBranch(const QString &name) {
    // A rename, not a checkout: safe on both a brand-new (even unborn,
    // commit-less) repo and one with existing history, and a no-op if
    // already on `name`. Best-effort — if it fails (e.g. no commits yet on
    // an older git without unborn-branch rename support), later sync calls
    // just won't find a remote worth talking to yet.
    git({QStringLiteral("branch"), QStringLiteral("-M"), name});
}

QString GitStore::currentBranch(bool *ok) const {
    const QString out = gitOutput({QStringLiteral("branch"), QStringLiteral("--show-current")}, ok);
    return out.trimmed();
}

bool GitStore::hasCommits() const {
    return git({QStringLiteral("rev-parse"), QStringLiteral("--verify"), QStringLiteral("-q"), QStringLiteral("HEAD")});
}

bool GitStore::git(const QStringList &args, bool network) const {
    QProcess proc;
    proc.setWorkingDirectory(m_dir);
    if (network) {
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert(QStringLiteral("GIT_TERMINAL_PROMPT"), QStringLiteral("0"));
        env.insert(QStringLiteral("GIT_SSH_COMMAND"), QStringLiteral("ssh -o BatchMode=yes -o ConnectTimeout=5"));
        proc.setProcessEnvironment(env);
    }
    proc.start(QStringLiteral("git"), args);
    const int timeoutMs = network ? 5000 : 10000;
    if (!proc.waitForFinished(timeoutMs)) {
        proc.kill();
        proc.waitForFinished();
        setError(QStringLiteral("git ") + args.join(QLatin1Char(' ')) + QStringLiteral(" timed out"));
        return false;
    }
    if (proc.exitStatus() != QProcess::NormalExit || proc.exitCode() != 0) {
        setError(QString::fromUtf8(proc.readAllStandardError()).trimmed());
        return false;
    }
    return true;
}

QString GitStore::gitOutput(const QStringList &args, bool *ok, bool network) const {
    QProcess proc;
    proc.setWorkingDirectory(m_dir);
    if (network) {
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert(QStringLiteral("GIT_TERMINAL_PROMPT"), QStringLiteral("0"));
        env.insert(QStringLiteral("GIT_SSH_COMMAND"), QStringLiteral("ssh -o BatchMode=yes -o ConnectTimeout=5"));
        proc.setProcessEnvironment(env);
    }
    proc.start(QStringLiteral("git"), args);
    const int timeoutMs = network ? 5000 : 10000;
    if (!proc.waitForFinished(timeoutMs)) {
        proc.kill();
        proc.waitForFinished();
        setError(QStringLiteral("git ") + args.join(QLatin1Char(' ')) + QStringLiteral(" timed out"));
        if (ok) *ok = false;
        return QString();
    }
    const QString out = QString::fromUtf8(proc.readAllStandardOutput());
    if (proc.exitStatus() != QProcess::NormalExit || proc.exitCode() != 0) {
        setError(QString::fromUtf8(proc.readAllStandardError()).trimmed());
        if (ok) *ok = false;
        return out;
    }
    if (ok) *ok = true;
    return out;
}
