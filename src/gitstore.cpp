#include "gitstore.h"

#include "capture.h"
#include "cards.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLockFile>
#include <QMap>
#include <QProcess>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>
#include <QStandardPaths>
#include <QStringList>
#include <QSysInfo>
#include <QTemporaryDir>
#include <QTextStream>

#include <algorithm>

namespace {
constexpr auto kFileName = "working-memory.txt";
constexpr auto kErrorLogName = "error.log";
constexpr auto kFieldSep = "\x1f"; // unit separator: won't collide with real message text
constexpr auto kBranch = "main";
constexpr auto kCardsDir = "cards";
constexpr auto kInboxBranch = "inbox";
constexpr auto kInboxDir = "items";
constexpr auto kInboxTimeFormat = "yyyyMMdd-HHmmss-zzz";
}

GitStore::GitStore(QObject *parent) : QObject(parent) {}

GitStore::~GitStore() = default;

bool GitStore::open() {
    m_dir = Capture::dataDir();
    m_activeRel = QLatin1String(kFileName);
    m_path = notePath();

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

    // Inside .git, so the lock file is never something git could track.
    // Waits rather than failing outright: the usual holder is an instance
    // whose window just closed and which is finishing its push, which
    // takes seconds at most. A crashed holder is detected by its PID.
    m_instanceLock = std::make_unique<QLockFile>(m_dir + QStringLiteral("/.git/omarchy-working-memory.lock"));
    m_instanceLock->setStaleLockTime(0);
    if (!m_instanceLock->tryLock(15000)) {
        setError(QStringLiteral("another omarchy-working-memory is still running (or still finishing its sync) on ") + m_dir);
        return false;
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
        attrFile.write(QByteArray(kCardsDir) + "/*.txt merge=union\n");
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
    const QString prefix = m_activeCard.isEmpty() ? QString() : (QLatin1Char('[') + m_activeCard + QStringLiteral("] "));
    const QString msg = prefix + previewLine(content) + QStringLiteral("  (")
        + QDateTime::currentDateTime().toString(QStringLiteral("yyyy-MM-dd HH:mm")) + QLatin1Char(')');
    return commitWithMessage(msg, committed);
}

bool GitStore::commitWithMessage(const QString &message, bool *committed) {
    if (committed) *committed = false;

    // -A over the whole cards/ directory, not just the active file: a
    // commit can be deferred (an index.lock retry, see Backend) past a
    // switch to another card, and must still pick up the one left behind —
    // plus any card deleted outside the app. cards/ is only named when it
    // exists, since `git add` rejects a pathspec that matches nothing.
    QStringList addArgs{QStringLiteral("add"), QStringLiteral("-A"), QStringLiteral("--"), QLatin1String(kFileName)};
    if (QDir(m_dir + QLatin1Char('/') + QLatin1String(kCardsDir)).exists())
        addArgs.append(QLatin1String(kCardsDir));
    if (!git(addArgs)) {
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
        QStringLiteral("--"), m_activeRel
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
    const QString out = gitOutput({QStringLiteral("show"), hash + QLatin1Char(':') + m_activeRel}, &queryOk);
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

QString GitStore::notePath() const {
    return m_dir + QLatin1Char('/') + QLatin1String(kFileName);
}

QString GitStore::cardRelPath(const QString &id) const {
    return QLatin1String(kCardsDir) + QLatin1Char('/') + id + QStringLiteral(".txt");
}

void GitStore::setActiveCard(const QString &id) {
    m_activeCard = id;
    m_activeRel = id.isEmpty() ? QString(QLatin1String(kFileName)) : cardRelPath(id);
    m_path = m_dir + QLatin1Char('/') + m_activeRel;
}

QStringList GitStore::cardIds() const {
    QStringList ids;
    const QDir dir(m_dir + QLatin1Char('/') + QLatin1String(kCardsDir));
    for (const QString &name : dir.entryList({QStringLiteral("*.txt")}, QDir::Files)) {
        const QString id = name.chopped(4);
        if (Cards::isValidId(id))
            ids.append(id);
    }
    std::sort(ids.begin(), ids.end(), Cards::lessThan);
    return ids;
}

bool GitStore::cardExists(const QString &id) const {
    return Cards::isValidId(id) && QFile::exists(m_dir + QLatin1Char('/') + cardRelPath(id));
}

QString GitStore::readDocument(const QString &id) const {
    QFile f(id.isEmpty() ? notePath() : m_dir + QLatin1Char('/') + cardRelPath(id));
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return QString();
    return QString::fromUtf8(f.readAll());
}

QHash<QString, QDateTime> GitStore::cardCreatedTimes() const {
    // Newest first, so a card that was deleted and re-added keeps the time
    // of its latest creation: only the first sighting of each path counts.
    bool ok = false;
    const QString out = gitOutput({
        QStringLiteral("log"), QStringLiteral("--diff-filter=A"), QStringLiteral("--name-only"),
        QStringLiteral("--format=") + QLatin1String(kFieldSep) + QStringLiteral("%cI"),
        QStringLiteral("--"), QLatin1String(kCardsDir)
    }, &ok);
    QHash<QString, QDateTime> times;
    if (!ok)
        return times;
    QDateTime current;
    for (const QString &line : out.split(QLatin1Char('\n'), Qt::SkipEmptyParts)) {
        if (line.startsWith(QLatin1String(kFieldSep))) {
            current = QDateTime::fromString(line.mid(1), Qt::ISODate);
            continue;
        }
        const QString name = QFileInfo(line).fileName();
        if (!name.endsWith(QStringLiteral(".txt")) || !current.isValid())
            continue;
        const QString id = name.chopped(4);
        if (!times.contains(id))
            times.insert(id, current);
    }
    for (const QString &id : cardIds()) {
        if (!times.contains(id))
            times.insert(id, QFileInfo(m_dir + QLatin1Char('/') + cardRelPath(id)).lastModified());
    }
    return times;
}

namespace {
// Which document a repo path is: the note ("working-memory.txt" -> card
// "") or a card ("cards/1a.txt" -> "1a"). False for anything else.
bool documentCard(const QString &path, QString *card) {
    if (path == QLatin1String(kFileName)) {
        card->clear();
        return true;
    }
    const QString prefix = QLatin1String(kCardsDir) + QLatin1Char('/');
    if (!path.startsWith(prefix) || !path.endsWith(QStringLiteral(".txt")))
        return false;
    *card = path.mid(prefix.size()).chopped(4);
    return Cards::isValidId(*card);
}
}

QList<GitStore::SearchHit> GitStore::search(const QStringList &words) const {
    QList<SearchHit> hits;
    if (words.isEmpty())
        return hits;

    bool ok = false;
    const QString current = currentBranch(&ok);

    // Every other topic, by whichever ref has it: the local branch if
    // there is one, else the remote-tracking one.
    QStringList refs;
    QHash<QString, QString> branchOfRef;
    for (const QString &branch : topicBranches()) {
        if (branch == current)
            continue;
        const QString ref = localBranchExists(branch) ? branch : QStringLiteral("origin/") + branch;
        refs.append(ref);
        branchOfRef.insert(ref, branch);
    }

    QStringList patterns;
    for (const QString &w : words)
        patterns << QStringLiteral("-e") << w;
    const QStringList common{QStringLiteral("grep"), QStringLiteral("-I"), QStringLiteral("-i"), QStringLiteral("-F"),
                             QStringLiteral("--all-match"), QStringLiteral("--no-color")};
    const QStringList paths{QStringLiteral("--"), QLatin1String(kFileName), QLatin1String(kCardsDir)};

    // Output lines are "[<ref>:]<path>:<text>". Each document's first
    // matching line becomes its hit; later lines from it are skipped.
    QSet<QString> seen;
    auto collect = [&](const QString &out, bool withRef) {
        for (const QString &raw : out.split(QLatin1Char('\n'), Qt::SkipEmptyParts)) {
            QString rest = raw;
            QString branch = current;
            if (withRef) {
                const int c = rest.indexOf(QLatin1Char(':'));
                if (c < 0)
                    continue;
                branch = branchOfRef.value(rest.left(c));
                rest = rest.mid(c + 1);
                if (branch.isEmpty())
                    continue;
            }
            const int c = rest.indexOf(QLatin1Char(':'));
            if (c < 0)
                continue;
            QString card;
            if (!documentCard(rest.left(c), &card))
                continue;
            const QString key = branch + QLatin1Char('\x1f') + card;
            if (seen.contains(key))
                continue;
            seen.insert(key);
            hits.append({branch, card, rest.mid(c + 1)});
        }
    };

    // git grep exits 1 for "no matches" — not an error, just nothing to
    // collect, which an empty output already says.
    collect(gitOutput(common + patterns + paths, &ok), false);
    if (!refs.isEmpty())
        collect(gitOutput(common + patterns + refs + paths, &ok), true);
    return hits;
}

QString GitStore::mergeText(const QString &base, const QString &ours, const QString &theirs, bool *ok) const {
    *ok = false;
    QTemporaryDir tmp;
    if (!tmp.isValid()) {
        setError(QStringLiteral("merge: no temp dir"));
        return QString();
    }
    const QStringList names{QStringLiteral("ours"), QStringLiteral("base"), QStringLiteral("theirs")};
    const QStringList texts{ours, base, theirs};
    QStringList paths;
    for (int i = 0; i < 3; ++i) {
        QFile f(tmp.filePath(names.at(i)));
        if (!f.open(QIODevice::WriteOnly)) {
            setError(QStringLiteral("merge: ") + f.errorString());
            return QString();
        }
        f.write(texts.at(i).toUtf8());
        paths << f.fileName();
    }
    const QString out = gitOutput({QStringLiteral("merge-file"), QStringLiteral("-p"), QStringLiteral("--union"),
                                   paths.at(0), paths.at(1), paths.at(2)}, ok);
    return out;
}

bool GitStore::resolveCardClashes(const QString &branch) {
    const QString remoteRef = QStringLiteral("refs/remotes/origin/") + branch;
    bool ok = false;
    gitOutput({QStringLiteral("rev-parse"), QStringLiteral("--verify"), QStringLiteral("-q"), remoteRef}, &ok);
    if (!ok)
        return true; // nothing fetched for this branch yet: nothing to clash with

    auto idsAt = [&](const QString &ref) {
        QStringList ids;
        const QString out = gitOutput({QStringLiteral("ls-tree"), QStringLiteral("--name-only"), ref,
                                       QLatin1String(kCardsDir) + QLatin1Char('/')}, &ok);
        for (const QString &p : out.split(QLatin1Char('\n'), Qt::SkipEmptyParts)) {
            QString card;
            if (documentCard(p, &card) && !card.isEmpty())
                ids << card;
        }
        return ids;
    };
    // Cards added on one side since the two histories last met. With no
    // common ancestor (a machine's first sync onto a populated remote),
    // every card on each side counts as added.
    const QString base = gitOutput({QStringLiteral("merge-base"), QStringLiteral("HEAD"), remoteRef}, &ok).trimmed();
    const bool haveBase = ok && !base.isEmpty();
    auto addedOn = [&](const QString &ref) {
        if (!haveBase)
            return idsAt(ref);
        QStringList ids;
        const QString out = gitOutput({QStringLiteral("diff"), QStringLiteral("--name-only"), QStringLiteral("--diff-filter=A"),
                                       QStringLiteral("--no-renames"), base, ref, QStringLiteral("--"),
                                       QLatin1String(kCardsDir) + QLatin1Char('/')}, &ok);
        for (const QString &p : out.split(QLatin1Char('\n'), Qt::SkipEmptyParts)) {
            QString card;
            if (documentCard(p, &card) && !card.isEmpty())
                ids << card;
        }
        return ids;
    };

    const QStringList localAdded = addedOn(QStringLiteral("HEAD"));
    if (localAdded.isEmpty())
        return true;
    const QStringList remoteAdded = addedOn(remoteRef);
    QStringList clashes;
    for (const QString &id : localAdded) {
        if (remoteAdded.contains(id))
            clashes << id;
    }
    if (clashes.isEmpty())
        return true;
    // Shallowest first, so a card that moves takes its branches with it
    // before they're considered on their own.
    std::sort(clashes.begin(), clashes.end(), [](const QString &a, const QString &b) {
        return Cards::depth(a) != Cards::depth(b) ? Cards::depth(a) < Cards::depth(b) : Cards::lessThan(a, b);
    });

    QSet<QString> taken;
    for (const QString &id : idsAt(QStringLiteral("HEAD")) + idsAt(remoteRef))
        taken.insert(id);
    QVariantMap renamed; // old → new
    for (const QString &root : clashes) {
        if (renamed.contains(root))
            continue;
        QStringList subtree;
        for (const QString &id : localAdded) {
            if (!renamed.contains(id) && !Cards::reroot(id, root, root).isEmpty())
                subtree << id;
        }
        // The next number along that's free for the card and every branch
        // moving with it.
        QString to = root;
        for (;;) {
            to = Cards::nextSibling(to);
            bool free = true;
            for (const QString &id : subtree) {
                if (taken.contains(Cards::reroot(id, root, to)))
                    free = false;
            }
            if (free)
                break;
        }
        for (const QString &id : subtree) {
            const QString moved = Cards::reroot(id, root, to);
            renamed.insert(id, moved);
            taken.insert(moved);
        }
    }

    for (auto it = renamed.cbegin(); it != renamed.cend(); ++it) {
        if (!git({QStringLiteral("mv"), cardRelPath(it.key()), cardRelPath(it.value().toString())})) {
            setError(QStringLiteral("renumbering clashing card ") + it.key() + QStringLiteral(": ") + errorString());
            return false;
        }
    }

    // Links to the moved cards from anything in this topic.
    const QString topic = currentTopic();
    QStringList docs{QLatin1String(kFileName)};
    for (const QString &id : cardIds())
        docs << cardRelPath(id);
    for (const QString &rel : docs) {
        QFile f(m_dir + QLatin1Char('/') + rel);
        if (!f.open(QIODevice::ReadOnly))
            continue;
        const QString before = QString::fromUtf8(f.readAll());
        f.close();
        QString after = before;
        static const QRegularExpression link(QStringLiteral("\\[\\[([^\\]:\\n]+):([0-9a-z]+)\\]\\]"));
        QRegularExpressionMatchIterator m = link.globalMatch(before);
        // Replace back to front so earlier offsets stay valid.
        QList<QRegularExpressionMatch> hits;
        while (m.hasNext())
            hits.prepend(m.next());
        for (const QRegularExpressionMatch &h : hits) {
            if (h.captured(1) == topic && renamed.contains(h.captured(2)))
                after.replace(h.capturedStart(), h.capturedLength(),
                              QStringLiteral("[[") + topic + QLatin1Char(':') + renamed.value(h.captured(2)).toString() + QStringLiteral("]]"));
        }
        if (after != before) {
            QSaveFile out(m_dir + QLatin1Char('/') + rel);
            if (out.open(QIODevice::WriteOnly)) {
                out.write(after.toUtf8());
                out.commit();
            }
        }
    }

    QStringList moves;
    for (auto it = renamed.cbegin(); it != renamed.cend(); ++it)
        moves << it.key() + QStringLiteral(" → ") + it.value().toString();
    if (!commitWithMessage(QStringLiteral("Renumber ") + moves.join(QStringLiteral(", "))
                               + QStringLiteral(" (also created on another machine)"), nullptr))
        return false;
    emit cardsRenumbered(topic, renamed);
    return true;
}

bool GitStore::commitToBranch(const QString &branch, const QString &message,
                              const std::function<bool(const QStringList &env)> &edit) {
    const QString ref = QStringLiteral("refs/heads/") + branch;
    bool ok = false;
    const QString parent = gitOutput({QStringLiteral("rev-parse"), QStringLiteral("--verify"), QStringLiteral("-q"), ref}, &ok).trimmed();
    const bool exists = ok && !parent.isEmpty();

    QTemporaryDir tmp;
    if (!tmp.isValid()) {
        setError(QStringLiteral("no temp dir for ") + branch);
        return false;
    }
    const QStringList env{QStringLiteral("GIT_INDEX_FILE=") + tmp.filePath(QStringLiteral("index"))};
    gitRun(exists ? QStringList{QStringLiteral("read-tree"), parent} : QStringList{QStringLiteral("read-tree"), QStringLiteral("--empty")},
           &ok, QByteArray(), env);
    if (!ok || !edit(env))
        return false;

    const QString tree = gitRun({QStringLiteral("write-tree")}, &ok, QByteArray(), env).trimmed();
    if (!ok)
        return false;
    QStringList commitArgs{QStringLiteral("commit-tree"), tree, QStringLiteral("-m"), message};
    if (exists)
        commitArgs << QStringLiteral("-p") << parent;
    const QString commit = gitOutput(commitArgs, &ok).trimmed();
    if (!ok)
        return false;
    // Compare-and-swap: an empty old value means "must not exist yet". If
    // a sync moved the branch in between, this fails and the caller retries
    // against the new tip.
    return git({QStringLiteral("update-ref"), QStringLiteral("-m"), message, ref, commit, exists ? parent : QString()});
}

QString GitStore::addInboxItem(const QString &text) {
    QString host;
    for (const QChar &c : QSysInfo::machineHostName().toLower()) {
        if (c.isLetterOrNumber())
            host += c;
    }
    const QString name = QDateTime::currentDateTime().toString(QLatin1String(kInboxTimeFormat))
        + QLatin1Char('-') + (host.isEmpty() ? QStringLiteral("host") : host) + QStringLiteral(".txt");
    return writeInboxItem(name, text, QStringLiteral("Capture: ") + previewLine(text)) ? name : QString();
}

bool GitStore::updateInboxItem(const QString &name, const QString &text) {
    if (name.isEmpty() || name.contains(QLatin1Char('/'))) {
        setError(QStringLiteral("not an inbox item: ") + name);
        return false;
    }
    return writeInboxItem(name, text, QStringLiteral("Edit: ") + name);
}

bool GitStore::writeInboxItem(const QString &name, const QString &text, const QString &message) {
    bool ok = false;
    const QString blob = gitRun({QStringLiteral("hash-object"), QStringLiteral("-w"), QStringLiteral("--stdin")}, &ok, text.toUtf8()).trimmed();
    if (!ok)
        return false;
    const QString path = QLatin1String(kInboxDir) + QLatin1Char('/') + name;
    for (int attempt = 0; attempt < 3; ++attempt) {
        const bool done = commitToBranch(QLatin1String(kInboxBranch), message,
            [&](const QStringList &env) {
                bool staged = false;
                gitRun({QStringLiteral("update-index"), QStringLiteral("--add"), QStringLiteral("--cacheinfo"),
                        QStringLiteral("100644,") + blob + QLatin1Char(',') + path}, &staged, QByteArray(), env);
                return staged;
            });
        if (done)
            return true;
    }
    return false;
}

bool GitStore::removeInboxItem(const QString &name) {
    const QString path = QLatin1String(kInboxDir) + QLatin1Char('/') + name;
    for (int attempt = 0; attempt < 3; ++attempt) {
        const bool done = commitToBranch(QLatin1String(kInboxBranch), QStringLiteral("Filed: ") + name,
            [&](const QStringList &env) {
                bool staged = false;
                gitRun({QStringLiteral("update-index"), QStringLiteral("--force-remove"), path}, &staged, QByteArray(), env);
                return staged;
            });
        if (done)
            return true;
    }
    return false;
}

QList<GitStore::InboxItem> GitStore::inboxItems() const {
    QList<InboxItem> items;
    bool ok = false;
    const QString ref = QStringLiteral("refs/heads/") + QLatin1String(kInboxBranch);
    const QString listing = gitOutput({QStringLiteral("ls-tree"), QStringLiteral("--name-only"), ref,
                                       QLatin1String(kInboxDir) + QLatin1Char('/')}, &ok);
    if (!ok)
        return items; // no inbox branch yet: an empty inbox
    QStringList paths = listing.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    paths.sort(); // names start with the capture time
    if (paths.isEmpty())
        return items;

    // One `git cat-file --batch` for every item, not a process per item.
    QByteArray request;
    for (const QString &p : paths)
        request += (ref + QLatin1Char(':') + p + QLatin1Char('\n')).toUtf8();
    QProcess proc;
    proc.setWorkingDirectory(m_dir);
    proc.start(QStringLiteral("git"), {QStringLiteral("cat-file"), QStringLiteral("--batch")});
    proc.write(request);
    proc.closeWriteChannel();
    if (!proc.waitForFinished(10000))
        return items;
    const QByteArray out = proc.readAllStandardOutput();

    int pos = 0;
    for (const QString &p : paths) {
        const int nl = out.indexOf('\n', pos);
        if (nl < 0)
            break;
        const QList<QByteArray> header = out.mid(pos, nl - pos).split(' ');
        pos = nl + 1;
        if (header.size() < 3)
            continue; // "<path> missing"
        const int size = header.at(2).toInt();
        const QString name = QFileInfo(p).fileName();
        items.append({name,
                      QDateTime::fromString(name.left(QString::fromLatin1(kInboxTimeFormat).size()), QLatin1String(kInboxTimeFormat)),
                      QString::fromUtf8(out.mid(pos, size))});
        pos += size + 1; // content, then its trailing newline
    }
    return items;
}

QStringList GitStore::cardIdsOn(const QString &branch) const {
    const QString ref = localBranchExists(branch) ? branch : QStringLiteral("origin/") + branch;
    bool ok = false;
    const QString listing = gitOutput({QStringLiteral("ls-tree"), QStringLiteral("--name-only"), ref,
                                       QLatin1String(kCardsDir) + QLatin1Char('/')}, &ok);
    QStringList ids;
    for (const QString &p : listing.split(QLatin1Char('\n'), Qt::SkipEmptyParts)) {
        QString card;
        if (documentCard(p, &card) && !card.isEmpty())
            ids.append(card);
    }
    std::sort(ids.begin(), ids.end(), Cards::lessThan);
    return ids;
}

void GitStore::syncInbox() {
    if (syncCancelled())
        return;
    const QString localRef = QStringLiteral("refs/heads/") + QLatin1String(kInboxBranch);
    const QString remoteRef = QStringLiteral("refs/remotes/origin/") + QLatin1String(kInboxBranch);
    bool ok = false;
    const QString local = gitOutput({QStringLiteral("rev-parse"), QStringLiteral("--verify"), QStringLiteral("-q"), localRef}, &ok).trimmed();
    const QString remote = gitOutput({QStringLiteral("rev-parse"), QStringLiteral("--verify"), QStringLiteral("-q"), remoteRef}, &ok).trimmed();
    if (local == remote)
        return; // in step, or no inbox anywhere yet

    auto push = [&] {
        if (!syncCancelled())
            git({QStringLiteral("push"), QStringLiteral("origin"), QLatin1String(kInboxBranch)}, /*network=*/true);
    };
    auto isAncestor = [&](const QString &a, const QString &b) {
        return git({QStringLiteral("merge-base"), QStringLiteral("--is-ancestor"), a, b});
    };

    if (remote.isEmpty()) {
        push(); // only this machine has an inbox so far
    } else if (local.isEmpty()) {
        git({QStringLiteral("update-ref"), localRef, remote, QString()});
    } else if (isAncestor(local, remote)) {
        git({QStringLiteral("update-ref"), localRef, remote, local});
    } else if (isAncestor(remote, local)) {
        push();
    } else {
        // Both machines changed the inbox since they last agreed: merge
        // item by item, without a working tree.
        const QString base = gitOutput({QStringLiteral("merge-base"), local, remote}, &ok).trimmed();
        const QString tree = mergeInboxTrees(ok ? base : QString(), local, remote);
        if (tree.isEmpty()) {
            logError(QStringLiteral("inbox: couldn't merge the two machines' inboxes: ") + errorString());
            return;
        }
        const QString commit = gitOutput({QStringLiteral("commit-tree"), tree, QStringLiteral("-p"), local,
                                          QStringLiteral("-p"), remote, QStringLiteral("-m"), QStringLiteral("Merge inbox")}, &ok).trimmed();
        if (ok && git({QStringLiteral("update-ref"), localRef, commit, local}))
            push();
    }
}

QString GitStore::mergeInboxTrees(const QString &base, const QString &local, const QString &remote) {
    // name → blob for each side's items/ (empty base: nothing in common).
    auto items = [&](const QString &commit) {
        QMap<QString, QString> out;
        if (commit.isEmpty())
            return out;
        bool ok = false;
        const QString listing = gitOutput({QStringLiteral("ls-tree"), commit, QLatin1String(kInboxDir) + QLatin1Char('/')}, &ok);
        for (const QString &line : listing.split(QLatin1Char('\n'), Qt::SkipEmptyParts)) {
            // "<mode> blob <sha>\t<path>"
            const int tab = line.indexOf(QLatin1Char('\t'));
            const QStringList meta = line.left(tab).split(QLatin1Char(' '));
            if (tab > 0 && meta.size() == 3 && meta.at(1) == QStringLiteral("blob"))
                out.insert(line.mid(tab + 1), meta.at(2));
        }
        return out;
    };
    auto content = [&](const QString &blob) {
        bool ok = false;
        return blob.isEmpty() ? QString() : gitOutput({QStringLiteral("cat-file"), QStringLiteral("blob"), blob}, &ok);
    };
    const QMap<QString, QString> b = items(base), l = items(local), r = items(remote);
    QSet<QString> paths;
    for (const auto *side : {&b, &l, &r}) {
        for (auto it = side->cbegin(); it != side->cend(); ++it)
            paths.insert(it.key());
    }

    QTemporaryDir tmp;
    if (!tmp.isValid()) {
        setError(QStringLiteral("no temp dir for the inbox merge"));
        return QString();
    }
    const QStringList env{QStringLiteral("GIT_INDEX_FILE=") + tmp.filePath(QStringLiteral("index"))};
    bool ok = false;
    gitRun({QStringLiteral("read-tree"), QStringLiteral("--empty")}, &ok, QByteArray(), env);
    if (!ok)
        return QString();
    QByteArray index; // update-index --index-info lines
    for (const QString &path : paths) {
        const QString bb = b.value(path), lb = l.value(path), rb = r.value(path);
        QString keep;
        if (lb == rb || rb == bb)
            keep = lb; // same on both, or only this side changed it
        else if (lb == bb)
            keep = rb; // only the other side changed it
        else if (lb.isEmpty() || rb.isEmpty())
            keep = lb.isEmpty() ? rb : lb; // edited on one, filed on the other: keep the edit
        else {
            bool merged = false;
            const QString text = mergeText(content(bb), content(lb), content(rb), &merged);
            if (!merged)
                return QString();
            keep = gitRun({QStringLiteral("hash-object"), QStringLiteral("-w"), QStringLiteral("--stdin")}, &ok, text.toUtf8()).trimmed();
            if (!ok)
                return QString();
        }
        if (!keep.isEmpty())
            index += (QStringLiteral("100644 ") + keep + QLatin1Char('\t') + path + QLatin1Char('\n')).toUtf8();
    }
    gitRun({QStringLiteral("update-index"), QStringLiteral("--index-info")}, &ok, index, env);
    if (!ok)
        return QString();
    const QString tree = gitRun({QStringLiteral("write-tree")}, &ok, QByteArray(), env).trimmed();
    return ok ? tree : QString();
}

QString GitStore::readDocumentOn(const QString &branch, const QString &card) const {
    const QString ref = localBranchExists(branch) ? branch : QStringLiteral("origin/") + branch;
    const QString path = card.isEmpty() ? QString(QLatin1String(kFileName)) : cardRelPath(card);
    bool ok = false;
    const QString out = gitOutput({QStringLiteral("show"), ref + QLatin1Char(':') + path}, &ok);
    return ok ? out : QString();
}

QString GitStore::formatCapture(const QString &text, const QString &title, const QString &url) {
    QStringList lines;
    for (const QString &line : text.trimmed().split(QLatin1Char('\n'))) {
        if (!text.trimmed().isEmpty())
            lines << QStringLiteral("> ") + line.trimmed();
    }
    if (!title.trimmed().isEmpty())
        lines << QStringLiteral("— ") + title.simplified();
    const QString stamp = QLatin1Char('[') + QDateTime::currentDateTime().toString(QStringLiteral("yyyy-MM-dd HH:mm")) + QLatin1Char(']');
    lines << QStringLiteral("  ") + (url.trimmed().isEmpty() ? stamp : url.trimmed() + QStringLiteral("   ") + stamp);
    return lines.join(QLatin1Char('\n')) + QLatin1Char('\n');
}

bool GitStore::createCard(const QString &id, const QString &text) {
    if (!Cards::isValidId(id)) {
        setError(QStringLiteral("invalid card number: ") + id);
        return false;
    }
    if (!QDir().mkpath(m_dir + QLatin1Char('/') + QLatin1String(kCardsDir))) {
        setError(QStringLiteral("create cards dir"));
        return false;
    }
    QFile f(m_dir + QLatin1Char('/') + cardRelPath(id));
    if (f.exists()) {
        setError(QStringLiteral("card ") + id + QStringLiteral(" already exists"));
        return false;
    }
    if (!f.open(QIODevice::WriteOnly)) {
        setError(QStringLiteral("create card: ") + f.errorString());
        return false;
    }
    f.write(text.toUtf8());
    f.close();
    return commitWithMessage(QStringLiteral("New card: ") + id, nullptr);
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

    // Blank slate: clear the note and drop any cards inherited from the
    // branch this was created off, then commit that as the topic's own
    // starting point, independent of whatever main (or wherever this was
    // branched from) currently says. A no-op, harmlessly, if the source
    // content was already empty — commitWithMessage() already treats "no
    // diff" as success, not a failure. The note is written by path rather
    // than through save(), which targets whichever card happens to be
    // active — Backend only resets that once the switch has landed.
    {
        QSaveFile f(notePath());
        if (!f.open(QIODevice::WriteOnly | QIODevice::Text) || !f.commit())
            return QStringLiteral("create topic file: ") + f.errorString();
    }
    if (!git({QStringLiteral("rm"), QStringLiteral("-r"), QStringLiteral("-q"), QStringLiteral("--ignore-unmatch"),
              QLatin1String(kCardsDir)}))
        return QStringLiteral("git rm cards: ") + errorString();
    QDir(m_dir + QLatin1Char('/') + QLatin1String(kCardsDir)).removeRecursively();
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
    // Clear any earlier cancellation before this run starts: a previous
    // caller (e.g. a topic switch) may have cancelled-and-waited for a prior
    // sync without ever wanting to disable every sync after it.
    m_cancelSync.store(false, std::memory_order_relaxed);
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
    emit pulled();
    // The inbox is its own branch with its own history: sync it whether or
    // not the current branch's push below succeeds.
    syncInbox();
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

    if (!resolveCardClashes(branch))
        return false;

    // open() creates working-memory.txt directly on disk, outside git, so on
    // a repo with no commits yet it always exists but untracked — and git
    // refuses to pull anything that would overwrite an untracked file. Since
    // zero local commits means that file can't hold anything the user has
    // ever saved, it's safe to clear it so the incoming history lands
    // cleanly (a plain fast-forward, not a real merge, in this case).
    if (!hasCommits())
        QFile::remove(notePath());

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
    bool ok = false;
    gitRun(args, &ok, QByteArray(), {}, network);
    return ok;
}

QString GitStore::gitOutput(const QStringList &args, bool *ok, bool network) const {
    return gitRun(args, ok, QByteArray(), {}, network);
}

QString GitStore::gitRun(const QStringList &args, bool *ok, const QByteArray &input,
                         const QStringList &extraEnv, bool network) const {
    QProcess proc;
    proc.setWorkingDirectory(m_dir);
    if (network || !extraEnv.isEmpty()) {
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        if (network) {
            env.insert(QStringLiteral("GIT_TERMINAL_PROMPT"), QStringLiteral("0"));
            env.insert(QStringLiteral("GIT_SSH_COMMAND"), QStringLiteral("ssh -o BatchMode=yes -o ConnectTimeout=5"));
        }
        for (const QString &kv : extraEnv) {
            const int eq = kv.indexOf(QLatin1Char('='));
            env.insert(kv.left(eq), kv.mid(eq + 1));
        }
        proc.setProcessEnvironment(env);
    }
    proc.start(QStringLiteral("git"), args);
    if (!input.isEmpty())
        proc.write(input);
    proc.closeWriteChannel();
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
