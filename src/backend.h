#pragma once

#include <QObject>
#include <QString>
#include <QTimer>
#include <QFileSystemWatcher>
#include <QFutureWatcher>
#include <QJsonObject>
#include <QLocalServer>
#include <QVariantList>

#include "gitstore.h"

#include <optional>

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
    // Empty while editing the topic's note, else the open index card's ID.
    Q_PROPERTY(QString currentCard READ currentCard NOTIFY currentCardChanged)
    // True from launch until the first sync has finished (or ~6s have
    // passed): the editor holds off applying typing until it has the
    // latest text, so opening the app and typing straight away never
    // races days of changes arriving from another machine.
    Q_PROPERTY(bool syncLocked READ syncLocked NOTIFY syncLockedChanged)
    // Captures waiting in the inbox (see GitStore's inbox), for the footer.
    Q_PROPERTY(int inboxCount READ inboxCount NOTIFY inboxChanged)

public:
    explicit Backend(QObject *parent = nullptr);
    // Gives an in-flight sync — normally the one the closing save() just
    // started — up to ~10s to finish pushing, so this machine's last edits
    // reach the remote now rather than at its next launch; then blocks
    // until it has finished — required, not just tidy: main.cpp holds Backend as a stack
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
    QString currentCard() const { return m_store.activeCard(); }
    bool syncLocked() const { return m_syncLocked; }
    int inboxCount() const { return m_inboxCount; }

    Q_INVOKABLE QString initialText() const;
    Q_INVOKABLE void noteEdited(const QString &text);
    Q_INVOKABLE void save();
    // macOS only, where closing the window hides it but the app keeps
    // running (see macos.h): reopening it runs the same locked sync as a
    // fresh launch does on Linux (see syncLocked), so text edited on
    // another machine meanwhile is in before you type.
    Q_INVOKABLE void windowReopened();
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
    // Ctrl+S) then dispatches the actual branch switch onto a background
    // thread — see the .cpp for why the checkout itself can't run on the
    // UI thread. Result (empty string on success, else a message fit to
    // show inline in the switcher) arrives via topicOpFinished(). A no-op
    // if an operation is already in flight.
    Q_INVOKABLE void requestTopicSwitch(const QString &branch);
    // Same flush-first, then-background behavior; result fit to show
    // inline in the creation prompt.
    Q_INVOKABLE void requestTopicCreate(const QString &name);

    // --- Index cards (see cards.h / gitstore.h) ------------------------
    // {id, title, time, depth, current} per entry for the Ctrl+I picker:
    // the topic note first (id ""), then every card in slip-box order.
    Q_INVOKABLE QVariantList cardList() const;
    // A card's (or, for "", the note's) text, for the picker's preview —
    // from another topic too, when topic names one other than the current.
    Q_INVOKABLE QString cardContent(const QString &id, const QString &topic = QString()) const;
    // Full-text search across every topic's note and cards (see
    // GitStore::search()): {id, topic, title, time, depth, current, other}
    // per match, title being the line that matched. The current topic's
    // matches come first, then the other topics', alphabetically; each
    // topic's in slip-box order, its note first.
    Q_INVOKABLE QVariantList searchCards(const QString &query) const;
    // The text inserted by the picker's "l": [[<topic>:<id>]], always
    // naming the topic so the link still resolves once copied elsewhere.
    Q_INVOKABLE QString cardLink(const QString &id) const;
    // All three below flush the open document first (save + commit, like
    // Ctrl+S), then switch the editor to the target. They return an empty
    // string on success, else a message fit to show the user.
    //
    // Opens a card in the current topic ("" = the topic note).
    Q_INVOKABLE QString openCard(const QString &id);
    // Creates a card relative to fromId and opens it: "continue" files it
    // after fromId (next sibling, or a branch if that number's taken),
    // "branch" always makes it a child. From the note (fromId ""), either
    // way it's the next top-level number.
    Q_INVOKABLE QString newCard(const QString &fromId, const QString &how, const QString &text = QString());
    // Opens the card a [[topic:id]] link points at. Within the current
    // topic that's immediate; another topic needs a branch switch first,
    // which runs in the background like Ctrl+T's — then this returns
    // "switching" and the outcome arrives via topicOpFinished().
    Q_INVOKABLE QString followLink(const QString &link);

    // --- Inbox ----------------------------------------------------------
    // {name, time, title, snippet, text} per capture, oldest first.
    Q_INVOKABLE QVariantList inboxList() const;
    Q_INVOKABLE QString discardInboxItem(const QString &name);
    // Saves an edit to a capture before it's filed. "" on success, else an
    // error.
    Q_INVOKABLE QString updateInboxItem(const QString &name, const QString &text);
    // Files a capture as a new card placed relative to fromId in topic
    // (continue or branch, as newCard()), removes it from the inbox and
    // opens the card. In another topic this switches topic first, in the
    // background like followLink(): returns "switching", and the card is
    // created once the switch lands. Else "" on success, or an error.
    Q_INVOKABLE QString fileInboxItem(const QString &name, const QString &topic,
                                      const QString &fromId, const QString &how);
    // The number a new card would get — for showing before you commit to
    // a place. Works for any topic, current or not.
    Q_INVOKABLE QString predictNewCard(const QString &topic, const QString &fromId, const QString &how) const;
    // The picker's entries for any topic (note first, then cards in
    // slip-box order), read from its branch when it isn't the current one.
    Q_INVOKABLE QVariantList cardListFor(const QString &topic) const;

signals:
    void statusChanged();
    void lastErrorChanged();
    void themeChanged();
    void currentTopicChanged();
    void currentCardChanged();
    void syncLockedChanged();
    // A sync changed the open document on disk: text is the new content,
    // already merged with anything typed meanwhile. Unlike textReloaded,
    // the editor should keep the cursor where it was.
    void textMerged(const QString &text);
    void inboxChanged();
    // A short message for the footer (e.g. "captured to inbox").
    void notice(const QString &message);
    // Emitted after a restore so the live editor picks up the new text —
    // the editor's text is otherwise never pushed to it from C++, only read
    // from it via noteEdited(), to avoid a binding feedback loop. Also used
    // after switching/creating a topic, for the same reason.
    void textReloaded(const QString &text);
    // Emitted once requestTopicSwitch()/requestTopicCreate() finishes:
    // empty string on success, else a message to show inline.
    void topicOpFinished(const QString &error);

private slots:
    void onSaveTimeout();
    void onCommitTimeout();
    void onSyncFinished();
    void onTopicOpFinished();

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
    // After a sync: if the pull changed the open document, three-way merge
    // that change with whatever's been typed since (see m_diskText) and
    // push the result to the editor via textMerged().
    void reloadIfChanged();
    void processSyncOutcome(const GitStore::SyncOutcome &outcome);
    // Brings an in-flight sync to an end right now (cancelling it at its
    // next network call, then waiting) and applies its outcome. Called
    // before anything writes the open document to disk outside the
    // autosave debounce (Ctrl+S, card/topic switches, close) — writing
    // while a pull is landing is how a stale buffer overwrites the pulled
    // text.
    void settleSync();
    void unlockAfterStartup();
    // GitStore::pulled(), delivered on the UI thread while the push is
    // still running: merge what arrived and release the launch lock now.
    void onPulled();
    // GitStore::cardsRenumbered(): if the open card was one of them, keep
    // editing it under its new number, and say what happened.
    void onCardsRenumbered(const QString &topic, const QVariantMap &renamed);
    void onCaptureConnection();
    QJsonObject handleCaptureRequest(const QJsonObject &request);
    void refreshInboxCount();
    // Creates the card a fileInboxItem() into another topic was waiting
    // on, once that topic's switch has landed.
    void finishPendingFiling();
    // Shared tail of requestTopicSwitch()/requestTopicCreate(), run on the
    // UI thread once the background checkout has finished: loads the
    // freshly checked-out branch's content into the live editor and resets
    // local state to match a just-opened note, then kicks off a sync for it.
    void applyTopicSwitch();
    // The branch switch/create itself must never run `git checkout`/
    // `checkout -b` while a background sync (triggerSync()) is concurrently
    // running `pull`/`push` against the very same working tree — that race
    // can leave the repo with a dirty tree checkoutBranch() can't get past,
    // or worse, merge a pull started against the old branch into the newly
    // checked-out one. This waits out any in-flight sync first (cancelling
    // it to bound the wait, same as the destructor does) — called from the
    // QtConcurrent worker thread in requestTopicSwitch()/requestTopicCreate(),
    // never the UI thread, precisely so this wait can never freeze the UI.
    void waitForSyncToStop();
    // save() and report whether the open document is now safely on disk —
    // the precondition for pointing the editor at a different one.
    bool flushForSwitch(QString *error);
    // Makes id ("" = note) the active document and loads it into the
    // editor. Assumes flushForSwitch() already succeeded.
    void activateDocument(const QString &id);

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
    QFutureWatcher<QString> m_topicWatcher;
    // Set by followLink() across topics: the card to open once the branch
    // switch it started has landed (see applyTopicSwitch()).
    QString m_cardAfterSwitch;
    // A fileInboxItem() into another topic, waiting on its topic switch.
    struct PendingFiling { QString name, fromId, how, text; };
    std::optional<PendingFiling> m_filingAfterSwitch;
    QLocalServer m_captureServer;
    int m_inboxCount = 0;
    // The open document's text as last read from or written to disk — the
    // common ancestor for merging a pull's change with the editor's
    // unsaved text in reloadIfChanged().
    QString m_diskText;
    // settleSync() already applied the outcome its waitForFinished() got;
    // the watcher's queued finished() for that same sync is then ignored.
    bool m_syncSettled = false;
    // The running sync's pull is done (see onPulled()): the file is safe
    // to write again even though the sync itself hasn't finished.
    bool m_syncPulled = false;
    bool m_syncLocked = false;
    QTimer m_unlockTimer;

    bool m_darkMode = true;
    QString m_themeBackground;
    QString m_themeForeground;
    QString m_themeAccent;
    QString m_themeSelection;
    QString m_themeMuted;
    QFileSystemWatcher m_themeWatcher;
};
