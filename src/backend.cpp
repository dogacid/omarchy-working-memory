#include "backend.h"

#include "cards.h"

#include <QClipboard>
#include <QColor>
#include <QDir>
#include <QFile>
#include <QElapsedTimer>
#include <QGuiApplication>
#include <QRegularExpression>
#include <QTextStream>
#include <QThread>
#include <QVariantMap>
#include <QtConcurrent>

#include <algorithm>

namespace {
constexpr int kSaveDebounceMs = 1000;
constexpr int kCommitDebounceMs = 20000;
// How often an otherwise-idle window checks for cross-machine changes —
// the debounced-commit/Ctrl+S sync only ever runs off your *own* edits, so
// without this, a window left open but untouched would never learn about
// another machine's changes. 5 minutes balances staying reasonably current
// against not chattering the remote needlessly.
constexpr int kPeriodicSyncMs = 5 * 60 * 1000;
// The most the editor stays locked at launch waiting for the first sync —
// past this it unlocks anyway, and a late pull is merged in instead.
constexpr int kStartupLockMs = 8000;
// The most a closed window's process lingers to finish its push.
constexpr int kCloseSyncWaitMs = 10000;
}

Backend::Backend(QObject *parent) : QObject(parent) {
    m_saveTimer.setSingleShot(true);
    m_commitTimer.setSingleShot(true);
    m_periodicSyncTimer.setInterval(kPeriodicSyncMs);
    connect(&m_saveTimer, &QTimer::timeout, this, &Backend::onSaveTimeout);
    connect(&m_commitTimer, &QTimer::timeout, this, &Backend::onCommitTimeout);
    connect(&m_periodicSyncTimer, &QTimer::timeout, this, &Backend::periodicCheck);
    m_unlockTimer.setSingleShot(true);
    connect(&m_unlockTimer, &QTimer::timeout, this, &Backend::unlockAfterStartup);
    // Queued: emitted on the sync's worker thread.
    connect(&m_store, &GitStore::pulled, this, &Backend::onPulled, Qt::QueuedConnection);
    connect(&m_syncWatcher, &QFutureWatcher<GitStore::SyncOutcome>::finished, this, &Backend::onSyncFinished);
    connect(&m_topicWatcher, &QFutureWatcher<QString>::finished, this, &Backend::onTopicOpFinished);
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
    //
    // A topic switch/create (see requestTopicSwitch()/requestTopicCreate())
    // runs on its own worker thread too, and it does its own waiting on
    // m_syncWatcher internally — so waiting for it first, then for
    // m_syncWatcher, covers both without double-cancelling anything.
    if (m_topicWatcher.isRunning()) {
        m_store.requestCancelSync();
        m_topicWatcher.waitForFinished();
    }
    if (m_syncWatcher.isRunning()) {
        // The window is already gone, so waiting here costs the user
        // nothing visible: let the sync the closing save() started finish
        // its push, within a bound, before cancelling whatever's left.
        QElapsedTimer waited;
        waited.start();
        while (m_syncWatcher.isRunning() && waited.elapsed() < kCloseSyncWaitMs)
            QThread::msleep(50);
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
    m_diskText = m_pendingText;

    loadOmarchyTheme();
    watchOmarchyTheme();
    setStatus(QStringLiteral("synced"));

    // The window opens immediately with whatever's on disk, but locked
    // (see syncLocked) until this first sync lands — it may bring days of
    // another machine's changes, and typing into the stale text meanwhile
    // is exactly the experience to avoid. No remote, no lock.
    m_periodicSyncTimer.start();
    triggerSync();
    if (m_syncWatcher.isRunning()) {
        m_syncLocked = true;
        m_unlockTimer.start(kStartupLockMs);
    }
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
    // Never write the file while a sync's pull may still be landing in
    // that very file. The edit stays in m_pendingText; onPulled() (or
    // processSyncOutcome(), if the pull never happened) restarts this
    // debounce afterwards.
    if (m_syncWatcher.isRunning() && !m_syncPulled)
        return;
    if (!m_store.save(m_pendingText)) {
        fail(QStringLiteral("save"), m_store.errorString());
        return;
    }
    m_diskText = m_pendingText;
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
    settleSync();

    if (!m_store.save(m_pendingText)) {
        fail(QStringLiteral("save"), m_store.errorString());
        return;
    }
    m_diskText = m_pendingText;
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
    // Clearing this unconditionally (not just inside the `if (committed)`
    // branch below) matters: a commit() call that succeeds but finds
    // nothing staged means there's genuinely nothing pending, whether or
    // not m_uncommitted already agreed — so don't leave it stuck true.
    m_uncommitted = false;
    if (committed)
        setStatus(QStringLiteral("synced"));
    // Always worth a sync attempt here, even when nothing was just
    // committed: this is what makes Ctrl+S double as a manual "check for
    // updates now" — pressing it with nothing new to save still forces a
    // pull, for when you know something's waiting on the remote and don't
    // want to wait for the next debounce/periodic cycle.
    triggerSync();
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
    m_syncSettled = false;
    m_syncPulled = false;
    m_syncWatcher.setFuture(QtConcurrent::run([this] { return m_store.syncWithRemote(); }));
}

void Backend::periodicCheck() {
    if (m_unsaved)
        return; // mid-edit — leave it alone, the save/commit chain owns this
    if (m_uncommitted) {
        // Self-heal: whatever kept this from committing on its own (a
        // missed timer, a suspend/resume gap, anything), retry it here
        // rather than leaving triggerSync() permanently blocked by
        // m_uncommitted — attemptCommit() calls triggerSync() itself once
        // it actually succeeds, so this still ends in a sync when it works.
        attemptCommit();
        return;
    }
    triggerSync();
}

void Backend::settleSync() {
    if (!m_syncWatcher.isRunning())
        return;
    m_store.requestCancelSync();
    m_syncWatcher.waitForFinished();
    m_syncSettled = true;
    processSyncOutcome(m_syncWatcher.result());
}

void Backend::onSyncFinished() {
    if (m_syncSettled) {
        m_syncSettled = false;
        return;
    }
    processSyncOutcome(m_syncWatcher.result());
}

void Backend::onPulled() {
    // Late delivery for a sync settleSync() already wrapped up: its outcome
    // (merge included) has been applied.
    if (m_syncSettled || !m_syncWatcher.isRunning())
        return;
    m_syncPulled = true;
    reloadIfChanged();
    unlockAfterStartup();
    if (m_unsaved)
        m_saveTimer.start(kSaveDebounceMs);
}

void Backend::unlockAfterStartup() {
    m_unlockTimer.stop();
    if (!m_syncLocked)
        return;
    m_syncLocked = false;
    emit syncLockedChanged();
}

void Backend::processSyncOutcome(const GitStore::SyncOutcome &outcome) {
    // Whatever happened, the first sync is over: let the editor go. A
    // guard, so it runs on every return path and after reloadIfChanged()
    // below — the merged text must reach the editor before the typing held
    // during the lock is applied on top of it.
    struct Unlock { Backend *b; ~Unlock() { b->unlockAfterStartup(); } } unlock{this};
    // Saves were held while the sync ran (see onSaveTimeout()).
    struct Resave { Backend *b; ~Resave() { if (b->m_unsaved) b->m_saveTimer.start(kSaveDebounceMs); } } resave{this};

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
        // Cut short by settleSync() — not a connectivity problem, and the
        // save/commit that asked for it starts a fresh sync right after.
        if (outcome.error == QStringLiteral("sync cancelled"))
            return;
        m_store.logError(outcome.error);
        setStatus(QStringLiteral("offline"));
        return;
    }
    setStatus(m_unsaved ? QStringLiteral("editing…") : QStringLiteral("synced"));
}

void Backend::reloadIfChanged() {
    bool ok = false;
    const QString disk = m_store.load(&ok);
    if (!ok || disk == m_diskText)
        return; // the sync didn't touch the open document

    // The pull changed it. Typing that hasn't reached disk yet — a sync
    // takes seconds against a real remote, and the user may have typed the
    // whole time — is merged with the pulled text rather than either side
    // replacing the other: base is what both started from (m_diskText).
    QString merged = disk;
    if (m_pendingText != m_diskText) {
        bool mergeOk = false;
        merged = m_store.mergeText(m_diskText, m_pendingText, disk, &mergeOk);
        if (!mergeOk) {
            // Can't merge (no temp dir, git missing): keep the typing, the
            // one thing that exists nowhere else; the pulled version is
            // still in history.
            m_store.logError(QStringLiteral("sync: couldn't merge a remote change with your typing (")
                + m_store.errorString() + QStringLiteral("); kept your text, the remote version is in history"));
            merged = m_pendingText;
        }
    }
    m_diskText = disk;
    m_unsaved = (merged != disk);
    if (merged == m_pendingText)
        return;
    m_pendingText = merged;
    emit textMerged(merged);
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
    m_diskText = content;
    m_unsaved = false;
    m_uncommitted = false;
    m_saveTimer.stop();
    m_commitTimer.stop();
    setStatus(QStringLiteral("restored ") + at.toString(QStringLiteral("MMM d HH:mm")));
    emit textReloaded(content);
}

QVariantList Backend::topicList() const {
    const QString current = m_store.currentTopic();
    QVariantList out;
    for (const QString &branch : m_store.topicBranches()) {
        const QString label = branch == QStringLiteral("main") ? branch : branch.mid(6); // strip "topic/"
        QVariantMap m;
        m[QStringLiteral("branch")] = branch;
        m[QStringLiteral("label")] = label;
        m[QStringLiteral("current")] = (label == current);
        out.append(m);
    }
    return out;
}

void Backend::requestTopicSwitch(const QString &branch) {
    if (m_topicWatcher.isRunning())
        return; // one at a time — the switcher/creator UI disables itself meanwhile
    save();
    if (m_unsaved || m_uncommitted) {
        emit topicOpFinished(QStringLiteral("still saving — try again in a moment"));
        return;
    }
    setStatus(QStringLiteral("switching…"));
    m_topicWatcher.setFuture(QtConcurrent::run([this, branch] {
        waitForSyncToStop();
        if (!m_store.checkoutBranch(branch))
            return m_store.errorString();
        return QString();
    }));
}

void Backend::requestTopicCreate(const QString &name) {
    if (m_topicWatcher.isRunning())
        return;
    save();
    if (m_unsaved || m_uncommitted) {
        emit topicOpFinished(QStringLiteral("still saving — try again in a moment"));
        return;
    }
    setStatus(QStringLiteral("switching…"));
    m_topicWatcher.setFuture(QtConcurrent::run([this, name] {
        waitForSyncToStop();
        return m_store.createTopicBranch(name);
    }));
}

void Backend::onTopicOpFinished() {
    const QString err = m_topicWatcher.result();
    if (!err.isEmpty()) {
        // A switch started by followLink() has no overlay of its own to
        // show the error in, so it goes in the status line instead.
        setStatus(m_cardAfterSwitch.isEmpty() ? QStringLiteral("synced") : QStringLiteral("link: ") + err);
        m_cardAfterSwitch.clear();
        emit topicOpFinished(err);
        return;
    }
    applyTopicSwitch();
    emit topicOpFinished(QString());
}

void Backend::waitForSyncToStop() {
    if (!m_syncWatcher.isRunning())
        return;
    m_store.requestCancelSync();
    m_syncWatcher.waitForFinished();
}

void Backend::applyTopicSwitch() {
    // Every switch lands on the new topic's note, unless followLink() asked
    // for one of its cards — and that card actually exists over there.
    const QString card = m_store.cardExists(m_cardAfterSwitch) ? m_cardAfterSwitch : QString();
    if (!m_cardAfterSwitch.isEmpty() && card.isEmpty())
        m_store.logError(QStringLiteral("link: no card ") + m_cardAfterSwitch + QStringLiteral(" in this topic"));
    m_cardAfterSwitch.clear();
    m_store.setActiveCard(card);
    emit currentCardChanged();

    bool ok = false;
    const QString content = m_store.load(&ok);
    if (!ok) {
        fail(QStringLiteral("load"), m_store.errorString());
        return;
    }
    m_pendingText = content;
    m_diskText = content;
    m_unsaved = false;
    m_uncommitted = false;
    m_saveTimer.stop();
    m_commitTimer.stop();
    setStatus(QStringLiteral("synced"));
    emit currentTopicChanged();
    emit textReloaded(content);
    // Pull-then-push for the topic just switched into, same as opening the
    // app fresh — it may have changes waiting from another machine.
    triggerSync();
}

namespace {
QString firstLine(const QString &content) {
    for (const QString &line : content.split(QLatin1Char('\n'))) {
        const QString t = line.trimmed();
        if (!t.isEmpty())
            return t;
    }
    return QString();
}
}

QVariantList Backend::cardList() const {
    const QString current = m_store.activeCard();
    QVariantList out;

    QVariantMap note;
    note[QStringLiteral("id")] = QString();
    note[QStringLiteral("topic")] = m_store.currentTopic();
    note[QStringLiteral("title")] = firstLine(m_store.readDocument(QString()));
    note[QStringLiteral("time")] = QString();
    note[QStringLiteral("depth")] = 0;
    note[QStringLiteral("current")] = current.isEmpty();
    out.append(note);

    const QHash<QString, QDateTime> times = m_store.cardCreatedTimes();
    for (const QString &id : m_store.cardIds()) {
        QVariantMap m;
        m[QStringLiteral("id")] = id;
        m[QStringLiteral("topic")] = m_store.currentTopic();
        m[QStringLiteral("title")] = firstLine(m_store.readDocument(id));
        m[QStringLiteral("time")] = times.value(id).toString(QStringLiteral("yyyy-MM-dd HH:mm"));
        m[QStringLiteral("depth")] = Cards::depth(id);
        m[QStringLiteral("current")] = (id == current);
        out.append(m);
    }
    return out;
}

namespace {
QString topicBranch(const QString &topic) {
    return topic == QStringLiteral("main") ? topic : QStringLiteral("topic/") + topic;
}

bool containsAll(const QString &text, const QStringList &words) {
    for (const QString &w : words) {
        if (!text.contains(w, Qt::CaseInsensitive))
            return false;
    }
    return true;
}

// The matched line, trimmed and cut down to a window around the first
// word that appears in it, so the match itself is always visible in the
// picker's narrow list rather than elided off the end.
QString snippet(const QString &line, const QStringList &words) {
    const QString t = line.simplified();
    int at = -1;
    for (const QString &w : words) {
        const int i = t.indexOf(w, 0, Qt::CaseInsensitive);
        if (i >= 0 && (at < 0 || i < at))
            at = i;
    }
    constexpr int before = 24, total = 120;
    QString out = t;
    if (at > before)
        out = QStringLiteral("…") + t.mid(at - before);
    if (out.size() > total)
        out = out.left(total) + QStringLiteral("…");
    return out;
}

// First line of text that contains any of words.
QString matchingLine(const QString &text, const QStringList &words) {
    for (const QString &line : text.split(QLatin1Char('\n'))) {
        for (const QString &w : words) {
            if (line.contains(w, Qt::CaseInsensitive))
                return line;
        }
    }
    return QString();
}
}

QVariantList Backend::searchCards(const QString &query) const {
    const QStringList words = query.simplified().split(QLatin1Char(' '), Qt::SkipEmptyParts);
    if (words.isEmpty())
        return {};

    const QString currentTopic = m_store.currentTopic();
    const QString currentBranch = topicBranch(currentTopic);
    const QString active = m_store.activeCard();

    struct Row { QString topic; QString card; QString line; };
    QList<Row> rows;
    for (const GitStore::SearchHit &h : m_store.search(words)) {
        // The open document is judged on the editor's text below instead,
        // which can be ahead of what's on disk.
        if (h.branch == currentBranch && h.card == active)
            continue;
        const QString topic = h.branch == QStringLiteral("main") ? h.branch : h.branch.mid(6);
        rows.append({topic, h.card, h.line});
    }
    if (containsAll(m_pendingText, words))
        rows.append({currentTopic, active, matchingLine(m_pendingText, words)});

    std::sort(rows.begin(), rows.end(), [&](const Row &a, const Row &b) {
        if (a.topic != b.topic) {
            if (a.topic == currentTopic || b.topic == currentTopic)
                return a.topic == currentTopic;
            return a.topic < b.topic;
        }
        if (a.card.isEmpty() || b.card.isEmpty())
            return a.card.isEmpty() && !b.card.isEmpty();
        return Cards::lessThan(a.card, b.card);
    });

    QVariantList out;
    for (const Row &r : rows) {
        QVariantMap m;
        m[QStringLiteral("id")] = r.card;
        m[QStringLiteral("topic")] = r.topic;
        m[QStringLiteral("title")] = snippet(r.line, words);
        m[QStringLiteral("time")] = QString();
        m[QStringLiteral("depth")] = 0;
        m[QStringLiteral("current")] = (r.topic == currentTopic && r.card == active);
        m[QStringLiteral("other")] = (r.topic != currentTopic);
        out.append(m);
    }
    return out;
}

QString Backend::cardContent(const QString &id, const QString &topic) const {
    if (!topic.isEmpty() && topic != m_store.currentTopic())
        return m_store.readDocumentOn(topicBranch(topic), id);
    // The open document's freshest text is in memory, not necessarily on
    // disk yet (the save debounce may not have fired).
    if (id == m_store.activeCard())
        return m_pendingText;
    return m_store.readDocument(id);
}

QString Backend::cardLink(const QString &id) const {
    return QStringLiteral("[[") + m_store.currentTopic() + QLatin1Char(':') + id + QStringLiteral("]]");
}

bool Backend::flushForSwitch(QString *error) {
    save();
    // Only m_unsaved blocks a switch: once the text is on disk, a commit
    // that's merely pending (an index.lock retry) is harmless, since
    // GitStore::commit() stages every card, not just the active one.
    if (m_unsaved || !m_lastError.isEmpty()) {
        *error = QStringLiteral("still saving — try again in a moment");
        return false;
    }
    return true;
}

void Backend::activateDocument(const QString &id) {
    m_store.setActiveCard(id);
    bool ok = false;
    const QString content = m_store.load(&ok);
    if (!ok) {
        fail(QStringLiteral("load"), m_store.errorString());
        return;
    }
    m_pendingText = content;
    m_diskText = content;
    m_unsaved = false;
    m_saveTimer.stop();
    emit currentCardChanged();
    emit textReloaded(content);
}

QString Backend::openCard(const QString &id) {
    if (m_topicWatcher.isRunning())
        return QStringLiteral("switching topics — try again in a moment");
    if (!id.isEmpty() && !m_store.cardExists(id))
        return QStringLiteral("no card ") + id + QStringLiteral(" in this topic");
    if (id == m_store.activeCard())
        return QString();
    QString err;
    if (!flushForSwitch(&err))
        return err;
    activateDocument(id);
    return QString();
}

QString Backend::newCard(const QString &fromId, const QString &how) {
    if (m_topicWatcher.isRunning())
        return QStringLiteral("switching topics — try again in a moment");
    QString err;
    if (!flushForSwitch(&err))
        return err;

    const QStringList existing = m_store.cardIds();
    QString id;
    if (fromId.isEmpty())
        id = Cards::nextTopLevel(existing);
    else if (how == QStringLiteral("branch"))
        id = Cards::branchFrom(fromId, existing);
    else
        id = Cards::continueAfter(fromId, existing);

    if (!m_store.createCard(id)) {
        // The file itself was made, only its commit collided with a
        // background sync's index lock — same transient case as
        // attemptCommit(): carry on, and let the retry commit it.
        if (m_store.cardExists(id) && m_store.errorString().contains(QStringLiteral("index.lock"))) {
            m_uncommitted = true;
            m_commitTimer.start(2000);
        } else {
            return m_store.errorString();
        }
    }
    activateDocument(id);
    setStatus(QStringLiteral("new card ") + id);
    return QString();
}

QString Backend::followLink(const QString &link) {
    static const QRegularExpression re(QStringLiteral("^\\[\\[([^\\]:]+):([0-9a-z]+)\\]\\]$"));
    const QRegularExpressionMatch m = re.match(link.trimmed());
    if (!m.hasMatch())
        return QStringLiteral("not a card link: ") + link;
    const QString topic = m.captured(1);
    const QString id = m.captured(2);

    if (topic == m_store.currentTopic())
        return openCard(id);

    if (m_topicWatcher.isRunning())
        return QStringLiteral("switching topics — try again in a moment");
    const QString branch = topicBranch(topic);
    if (!m_store.topicBranches().contains(branch))
        return QStringLiteral("no topic named ") + topic;
    m_cardAfterSwitch = id;
    requestTopicSwitch(branch);
    // requestTopicSwitch() can refuse synchronously (still saving) — it
    // emits topicOpFinished itself in that case, without starting a switch.
    if (!m_topicWatcher.isRunning()) {
        m_cardAfterSwitch.clear();
        return QStringLiteral("still saving — try again in a moment");
    }
    return QStringLiteral("switching");
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
