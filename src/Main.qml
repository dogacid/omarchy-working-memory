import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window

ApplicationWindow {
    id: win
    width: 900
    height: 640
    minimumWidth: 420
    minimumHeight: 300
    visible: true
    title: (backend.currentTopic === "main" ? "Working memory" : "Working memory — " + backend.currentTopic)
           + (backend.currentCard ? " › " + backend.currentCard : "")
    color: backend.themeBackground

    // The error overlay is independent of this and just layers on top
    // whenever backend.lastError is set.
    property string mode: "edit"
    property var historyEntries: []
    property var filteredHistory: []
    property var selectedEntry: null
    property string historyContent: ""

    // Vim-style selection within the read-only preview: "none" | "char"
    // (v) | "line" (V). previewAnchor is the fixed end of the selection;
    // the preview TextArea's own cursorPosition is the moving end — same
    // anchor/cursor model vim's visual mode uses.
    property string previewSelMode: "none"
    property int previewAnchor: 0
    // First "g" of a "gg" in the preview — the editor's own pendingG (see
    // below) is kept separate so a half-typed gg in one never completes in
    // the other.
    property bool previewPendingG: false

    // Same idea, but live-editable: "insert" (normal typing, the default)
    // | "normal" (vim Normal mode, entered via Esc) | "visual" (v) |
    // "visualLine" (V). editorAnchor is the fixed end of a visual
    // selection, mirroring previewAnchor/previewSelMode above.
    property string editorMode: "insert"
    property int editorAnchor: 0
    // True right after a single "d" in Normal mode, waiting to see if the
    // next key completes "dd" — reset on any other key or mode change.
    property bool pendingD: false
    // Same, for the first "g" of a "gg" (jump to top). Separate from
    // pendingD because gg is a motion and works in Visual mode too, where
    // dd never applies.
    property bool pendingG: false
    property bool showHelp: false

    // --- Topics (Ctrl+T switch, Ctrl+Shift+T create) — see backend's
    // topicList()/switchTopic()/createTopic(), themselves thin wrappers
    // around GitStore's branch-based topics.
    property bool showTopicSwitcher: false
    property var topics: []
    property var filteredTopics: []
    property string topicSwitchError: ""
    property bool showTopicCreator: false
    property string topicCreateError: ""
    // True while requestTopicSwitch()/requestTopicCreate() is running on its
    // background thread — see backend.h for why that wait can be long
    // enough to matter. Disables the overlay's input and a second attempt
    // until topicOpFinished arrives.
    property bool topicBusy: false

    // --- Index cards (Ctrl+I picker, Ctrl+Shift+I new card) — see
    // backend's cardList()/openCard()/newCard()/followLink(), and cards.h
    // for the Luhmann numbering itself. The picker is a third full-window
    // mode beside "edit" and "history", laid out the same way as history.
    property var cardEntries: []
    property var filteredCards: []
    property var selectedCard: null
    property string cardPreview: ""
    // Vim-style jump list for Ctrl+O: where you were ({topic, card, pos})
    // each time a link or the picker took you somewhere else.
    property var jumpStack: []
    // Cursor position to restore on the next textReloaded — set right
    // before a jump back, since a reload otherwise lands at the end.
    property int pendingCursor: -1
    // A short message that takes over the footer's status slot for a few
    // seconds — card operations' errors have no overlay of their own.
    property string flashMessage: ""
    // Typed while backend.syncLocked held the editor at launch; applied at
    // the cursor the moment the lock lifts, on top of the synced text.
    property string heldInput: ""
    // The picker's search terms, once a search is running — highlighted in
    // the result list and the preview.
    property var searchWords: []

    // --- Inbox (Ctrl+B): browser captures waiting to be filed — see
    // backend.inboxList()/fileInboxItem(). Filing reuses the card picker
    // to choose the place: filingItem is the capture being placed while
    // the picker is open for it, null otherwise.
    property var inboxEntries: []
    property var selectedInbox: null
    property var filingItem: null
    property var filePrediction: ({ after: "", branch: "" })
    property bool pendingInboxD: false
    // e on a capture: its preview becomes editable until Esc (or focus
    // leaving it), which saves the edit back to the inbox.
    property bool inboxEditing: false

    // The ? overlay's contents, a section per place in the app.
    readonly property var helpSections: [
        { title: "General", items: [
            { key: "Ctrl+S", desc: "Save + commit immediately (forces a sync too)" },
            { key: "Ctrl+R", desc: "Open history (time machine)" },
            { key: "Alt+D", desc: "Insert today's date" },
            { key: "Alt+T", desc: "Insert date + time" },
            { key: "Ctrl+1..9", desc: "Jump to the Nth heading" },
            { key: "Ctrl+T", desc: "Switch topic" },
            { key: "Ctrl+Shift+T", desc: "Create a new topic" },
            { key: "Ctrl+I", desc: "Index cards in this topic (l there links one here)" },
            { key: "Ctrl+Shift+I", desc: "New card after the open one (Luhmann numbering)" },
            { key: "Ctrl+O", desc: "Jump back to where a link or card took you from" },
            { key: "Ctrl+B", desc: "Inbox: browser captures waiting to be filed" },
            { key: "Esc", desc: "Enter vim Normal mode" }
        ]},
        { title: "Normal mode", items: [
            { key: "i", desc: "Back to Insert mode (resume typing)" },
            { key: "h j k l", desc: "Move the cursor (arrows too)" },
            { key: "gg", desc: "Jump to the top of the note" },
            { key: "G", desc: "Jump to the bottom of the note" },
            { key: "v", desc: "Visual mode (character)" },
            { key: "V", desc: "Visual line mode" },
            { key: "dd", desc: "Delete the line (copied to clipboard)" },
            { key: "D", desc: "Delete to end of line (copied to clipboard)" },
            { key: "Enter / gd", desc: "Follow the [[topic:card]] link under the cursor" },
            { key: "?", desc: "Toggle this help" }
        ]},
        { title: "Visual mode", items: [
            { key: "h j k l", desc: "Extend the selection" },
            { key: "gg / G", desc: "Extend to the top / bottom of the note" },
            { key: "y", desc: "Yank selection to clipboard" },
            { key: "d / x", desc: "Delete selection (copied to clipboard)" },
            { key: "Esc", desc: "Cancel, back to Normal mode" }
        ]},
        { title: "Index cards (Ctrl+I)", items: [
            { key: "j / k", desc: "Move through the cards" },
            { key: "Enter", desc: "Open the card" },
            { key: "l", desc: "Insert a link to it where you were typing" },
            { key: "y", desc: "Copy a link to it" },
            { key: "c / b", desc: "New card after it / branching off it" },
            { key: "/", desc: "Search every topic (topic: lists a topic's cards)" }
        ]},
        { title: "Inbox (Ctrl+B)", items: [
            { key: "j / k", desc: "Move through the captures (oldest first)" },
            { key: "Enter / f", desc: "Place it: pick a card, then Enter files it after, b branches off it" },
            { key: "n", desc: "File it now as the next top-level card in this topic" },
            { key: "e", desc: "Edit it before filing (Esc saves)" },
            { key: "dd", desc: "Discard it" },
            { key: "y", desc: "Copy it to the clipboard" },
            { key: "Esc", desc: "Back to the editor" }
        ]}
    ]

    onClosing: { win.finishInboxEdit(false); backend.save(); }
    // macOS keeps the app running with the window hidden (see macos.h), so
    // reopening it lands here rather than in a fresh Component.onCompleted.
    onVisibleChanged: if (visible && mode === "edit") editor.forceActiveFocus()

    // On macOS Qt maps "Ctrl" in a shortcut sequence to Cmd, so the
    // Shortcuts below need no changes — only the labels that spell them out.
    readonly property bool isMac: Qt.platform.os === "osx"
    readonly property string monoFont: isMac ? "Menlo" : "monospace"
    function keyLabel(s) {
        if (!isMac) return s;
        return s.replace(/\/super\+c/g, "")
                .replace(/Ctrl\+Shift\+/g, "⇧⌘").replace(/ctrl\+shift\+/g, "⇧⌘")
                .replace(/Ctrl\+/g, "⌘").replace(/ctrl\+/g, "⌘")
                .replace(/Alt\+/g, "⌥");
    }

    function openHistory() {
        historyEntries = backend.historyEntries();
        filteredHistory = historyEntries;
        historySearch.text = "";
        mode = "history";
        historyList.currentIndex = historyEntries.length > 0 ? 0 : -1;
        showSelected();
        historyList.forceActiveFocus();
    }

    function filterHistory(query) {
        filteredHistory = query
            ? historyEntries.filter(function (e) { return e.message.toLowerCase().indexOf(query.toLowerCase()) !== -1; })
            : historyEntries;
        historyList.currentIndex = filteredHistory.length > 0 ? 0 : -1;
        showSelected();
    }

    // Following the list's current row live, not waiting for Enter, is the
    // point: skimming through many versions to find the right one reads as
    // one continuous motion instead of "select, view, back, select, view…".
    function showSelected() {
        const entry = historyList.currentIndex >= 0 ? filteredHistory[historyList.currentIndex] : null;
        selectedEntry = entry;
        historyContent = entry ? backend.showAt(entry.hash) : "";
    }

    function restoreSelected() {
        if (!win.selectedEntry) return;
        backend.restoreAt(win.selectedEntry.hash, win.selectedEntry.isoTime);
        win.backToEdit();
    }

    function backToEdit() {
        win.filingItem = null;
        mode = "edit";
        editor.forceActiveFocus();
    }

    // Alt+D / Alt+T: quick timestamp stamps into the note, bracketed so
    // they read as inline markers rather than blending into prose.
    function pad2(n) { return n < 10 ? "0" + n : "" + n; }
    function insertDate() {
        const d = new Date();
        editor.insert(editor.cursorPosition, "[" + d.getFullYear() + "-" + win.pad2(d.getMonth() + 1) + "-" + win.pad2(d.getDate()) + "]");
    }
    function insertDateTime() {
        const d = new Date();
        editor.insert(editor.cursorPosition, "[" + d.getFullYear() + "-" + win.pad2(d.getMonth() + 1) + "-" + win.pad2(d.getDate()) + " " + win.pad2(d.getHours()) + ":" + win.pad2(d.getMinutes()) + "]");
    }

    // Ctrl+1..9: jump to the Nth heading line, in document order. A heading
    // is any line starting with one or more "#" followed by a space —
    // standard markdown ATX heading syntax (# / ## / ### / ...), not
    // markdown rendering, just a plain-text convention chosen to match how
    // people already write headings rather than inventing a new marker.
    // Requiring the space is what keeps this from colliding with a hex
    // color, issue reference, or hashtag at the start of a line — none of
    // those have a space right after the "#". Computed on demand at jump
    // time since nothing else needs to track heading positions live.
    function headingPositions() {
        const lines = editor.text.split("\n");
        const positions = [];
        let offset = 0;
        for (const line of lines) {
            if (/^#+ /.test(line)) positions.push(offset);
            offset += line.length + 1;
        }
        return positions;
    }
    function jumpToHeading(n) {
        if (win.mode !== "edit") return;
        const positions = win.headingPositions();
        if (n > positions.length) return; // fewer headings than n: no-op
        editor.cursorPosition = positions[n - 1];
        editor.forceActiveFocus();
    }

    // --- Vim-style visual selection in the history preview ---------------
    // v/V starts it (anchored at the top of the text), h/j/k/l or the
    // arrow keys move the cursor and extend the selection, y or Ctrl+C/
    // Super+C yanks it to the clipboard, Esc cancels it — all scoped to
    // "one step back" the way real vim's Escape returns Visual to Normal
    // rather than closing the buffer: canceling out of visual mode lands
    // back on the list, not out of history entirely.
    function enterVisualMode(kind) {
        if (!win.selectedEntry) return;
        win.previewSelMode = kind;
        win.previewAnchor = 0;
        win.previewPendingG = false;
        previewArea.cursorPosition = 0;
        previewArea.forceActiveFocus();
        win.updatePreviewSelection();
    }

    function updatePreviewSelection() {
        if (win.previewSelMode === "none") return;
        const a = win.previewAnchor, c = previewArea.cursorPosition;
        if (win.previewSelMode === "line") {
            const text = win.historyContent;
            const lo = Math.min(a, c), hi = Math.max(a, c);
            const lineStart = text.lastIndexOf("\n", lo - 1) + 1;
            const nlAfter = text.indexOf("\n", hi);
            previewArea.select(lineStart, nlAfter === -1 ? text.length : nlAfter);
        } else {
            previewArea.select(Math.min(a, c), Math.max(a, c));
        }
    }

    function exitVisualMode() {
        win.previewSelMode = "none";
        win.previewPendingG = false;
        previewArea.deselect();
        historyList.forceActiveFocus();
    }

    function yankPreviewSelection() {
        if (win.previewSelMode === "none") return;
        if (previewArea.selectedText) backend.copyToClipboard(previewArea.selectedText);
        win.exitVisualMode();
    }

    // --- Vim-style Normal/Visual mode in the live editor ------------------
    // Esc (from Insert) enters Normal mode; i returns to Insert. Same
    // anchor/cursor selection model as the history preview above, just
    // against the editable buffer, so v/V/h/j/k/l/y all behave the same
    // way — plus dd and D, which the read-only preview has no need for.
    function enterEditorNormalMode() {
        win.editorMode = "normal";
        win.pendingD = false;
        win.pendingG = false;
    }
    function enterEditorInsertMode() {
        win.editorMode = "insert";
        win.pendingD = false;
        win.pendingG = false;
        editor.deselect();
    }
    function enterEditorVisual(kind) {
        win.editorMode = kind;
        win.editorAnchor = editor.cursorPosition;
        win.pendingD = false;
        win.pendingG = false;
        win.updateEditorSelection();
    }
    function updateEditorSelection() {
        const a = win.editorAnchor, c = editor.cursorPosition;
        if (win.editorMode === "visualLine") {
            const text = editor.text;
            const lo = Math.min(a, c), hi = Math.max(a, c);
            const lineStart = text.lastIndexOf("\n", lo - 1) + 1;
            const nlAfter = text.indexOf("\n", hi);
            editor.select(lineStart, nlAfter === -1 ? text.length : nlAfter);
        } else if (win.editorMode === "visual") {
            editor.select(Math.min(a, c), Math.max(a, c));
        }
    }
    function yankEditorSelection() {
        if (editor.selectedText) backend.copyToClipboard(editor.selectedText);
        editor.deselect();
        win.enterEditorNormalMode();
    }
    function deleteEditorSelection() {
        if (editor.selectedText) {
            backend.copyToClipboard(editor.selectedText);
            editor.remove(editor.selectionStart, editor.selectionEnd);
        }
        win.enterEditorNormalMode();
    }
    // dd: delete the whole current line (its trailing newline included, so
    // the document doesn't grow a blank line) and yank the line's text.
    // Deleting the last line also eats the *preceding* newline instead, so
    // it doesn't leave a dangling blank line at the end either.
    function deleteCurrentLine() {
        const text = editor.text;
        const pos = editor.cursorPosition;
        const lineStart = text.lastIndexOf("\n", pos - 1) + 1;
        const nlAfter = text.indexOf("\n", pos);
        let removeStart = lineStart, removeEnd, clip;
        if (nlAfter === -1) {
            clip = text.slice(lineStart);
            removeEnd = text.length;
            if (lineStart > 0) removeStart = lineStart - 1;
        } else {
            clip = text.slice(lineStart, nlAfter);
            removeEnd = nlAfter + 1;
        }
        if (clip) backend.copyToClipboard(clip);
        editor.remove(removeStart, removeEnd);
        editor.cursorPosition = Math.min(removeStart, editor.text.length);
    }
    // D: delete from the cursor to the end of the current line (not
    // including its newline) and yank what was removed.
    function deleteToEndOfLine() {
        const text = editor.text;
        const pos = editor.cursorPosition;
        let lineEnd = text.indexOf("\n", pos);
        if (lineEnd === -1) lineEnd = text.length;
        if (lineEnd > pos) {
            backend.copyToClipboard(text.slice(pos, lineEnd));
            editor.remove(pos, lineEnd);
        }
    }

    // --- Topics -------------------------------------------------------
    // Ctrl+T opens a searchable switcher (mirrors the history search/list
    // pattern below); Ctrl+Shift+T opens a one-field creation prompt. Both
    // flush the current topic (save+commit, synchronously) before acting —
    // see Backend::switchTopic()/createTopic() — so switching or creating
    // never risks losing an in-progress edit.
    function openTopicSwitcher() {
        win.topics = backend.topicList();
        win.filteredTopics = win.topics;
        win.topicSwitchError = "";
        topicSearch.text = "";
        win.showTopicSwitcher = true;
        topicResults.currentIndex = win.filteredTopics.length > 0 ? 0 : -1;
        topicSearch.forceActiveFocus();
    }
    function filterTopics(query) {
        win.filteredTopics = query
            ? win.topics.filter(function (t) { return t.label.toLowerCase().indexOf(query.toLowerCase()) !== -1; })
            : win.topics;
        topicResults.currentIndex = win.filteredTopics.length > 0 ? 0 : -1;
    }
    function confirmTopicSwitch() {
        if (win.topicBusy) return;
        if (topicResults.currentIndex < 0 || topicResults.currentIndex >= win.filteredTopics.length) return;
        win.topicSwitchError = "";
        win.topicBusy = true;
        backend.requestTopicSwitch(win.filteredTopics[topicResults.currentIndex].branch);
    }
    function closeTopicSwitcher() {
        if (win.topicBusy) return; // let the in-flight switch land first
        win.showTopicSwitcher = false;
        editor.forceActiveFocus();
    }

    function openTopicCreator() {
        win.topicCreateError = "";
        topicNameField.text = "";
        win.showTopicCreator = true;
        topicNameField.forceActiveFocus();
    }
    function confirmTopicCreate() {
        if (win.topicBusy) return;
        win.topicCreateError = "";
        win.topicBusy = true;
        backend.requestTopicCreate(topicNameField.text);
    }
    function closeTopicCreator() {
        if (win.topicBusy) return;
        win.showTopicCreator = false;
        editor.forceActiveFocus();
    }

    // --- Index cards ----------------------------------------------------
    function flash(msg) {
        win.flashMessage = msg;
        flashTimer.restart();
    }

    // --- Inbox ---------------------------------------------------------
    function openInbox(keepIndex) {
        win.inboxEntries = backend.inboxList();
        win.pendingInboxD = false;
        mode = "inbox";
        const i = keepIndex === undefined ? 0 : Math.min(keepIndex, win.inboxEntries.length - 1);
        inboxListView.currentIndex = win.inboxEntries.length > 0 ? Math.max(0, i) : -1;
        win.showSelectedInbox();
        inboxListView.forceActiveFocus();
    }
    // Re-reads the inbox (a capture arrived, or a sync brought some),
    // staying on the same capture where it still exists.
    function refreshInbox() {
        const name = win.selectedInbox ? win.selectedInbox.name : "";
        win.inboxEntries = backend.inboxList();
        let i = win.inboxEntries.findIndex(e => e.name === name);
        if (i < 0) i = Math.min(inboxListView.currentIndex, win.inboxEntries.length - 1);
        inboxListView.currentIndex = win.inboxEntries.length > 0 ? Math.max(0, i) : -1;
        win.showSelectedInbox();
    }
    function startInboxEdit() {
        if (!win.selectedInbox) return;
        win.inboxEditing = true;
        inboxPreview.forceActiveFocus();
        inboxPreview.cursorPosition = inboxPreview.length;
    }
    // Saves the edit, if anything changed. refocus: back to the list (not
    // when focus left for somewhere else, like Ctrl+B back to the editor).
    function finishInboxEdit(refocus) {
        if (!win.inboxEditing) return;
        win.inboxEditing = false;
        const item = win.selectedInbox;
        if (item && inboxPreview.text !== item.text) {
            const err = backend.updateInboxItem(item.name, inboxPreview.text);
            win.flash(err ? err : "edit saved");
            win.refreshInbox();
        }
        if (refocus) inboxListView.forceActiveFocus();
    }
    // n on a capture: file it now as the next top-level card in this topic
    // — for when it matters but its place in the slip box can wait (the
    // card can still be linked to and from later).
    function quickFileInbox() {
        if (!win.selectedInbox || win.topicBusy) return;
        win.pushJump();
        const err = backend.fileInboxItem(win.selectedInbox.name, backend.currentTopic, "", "continue");
        if (err) { win.jumpStack = win.jumpStack.slice(0, -1); win.flash(err); return; }
        win.backToEdit();
        win.flash("filed as card " + backend.currentCard);
    }
    function showSelectedInbox() {
        const i = inboxListView.currentIndex;
        win.selectedInbox = i >= 0 && i < win.inboxEntries.length ? win.inboxEntries[i] : null;
    }
    function discardSelectedInbox() {
        if (!win.selectedInbox) return;
        const err = backend.discardInboxItem(win.selectedInbox.name);
        if (err) { win.flash(err); return; }
        win.flash("discarded");
        win.openInbox(inboxListView.currentIndex);
    }
    // Enter on a capture: pick its place with the card picker, which then
    // reads Enter/c as "after this card" and b as "branch off it".
    function startFiling() {
        if (!win.selectedInbox) return;
        const item = win.selectedInbox;
        win.openCardPicker();
        win.filingItem = item;
        win.showSelectedCard(); // refresh the header with the predictions
    }
    function fileSelected(how) {
        const c = win.selectedCard;
        if (!c || !win.filingItem || win.topicBusy) return;
        win.pushJump();
        const err = backend.fileInboxItem(win.filingItem.name, c.topic, c.id, how);
        if (err === "switching") { win.topicBusy = true; win.backToEdit(); return; }
        if (err) { win.jumpStack = win.jumpStack.slice(0, -1); win.flash(err); return; }
        win.backToEdit();
    }
    // Esc from the picker while filing goes back to the inbox, not the
    // editor — one step back, the way Esc works everywhere else here.
    function escapeFromMode() {
        if (win.showHelp) { win.showHelp = false; return; }
        if (win.mode === "inbox" && win.inboxEditing) { win.finishInboxEdit(true); return; }
        if (win.mode === "cards" && win.filingItem) { win.filingItem = null; win.openInbox(); return; }
        win.backToEdit();
    }

    function openCardPicker() {
        win.cardEntries = backend.cardList();
        win.filteredCards = win.cardEntries;
        cardSearch.text = "";
        mode = "cards";
        // Start on the open document, so the picker reads as "you are here".
        let start = 0;
        for (let i = 0; i < win.filteredCards.length; i++)
            if (win.filteredCards[i].current) { start = i; break; }
        cardListView.currentIndex = win.filteredCards.length > 0 ? start : -1;
        win.showSelectedCard();
        cardListView.forceActiveFocus();
    }
    // Search: every word must appear somewhere in a card (or topic note),
    // in any topic — see backend.searchCards(). A word that's also the
    // start of a card number in this topic (e.g. "1a") lists those cards
    // too, ahead of the text matches. Runs shortly after typing pauses
    // (searchTimer), since each search shells out to git.
    function filterCards(query) {
        const q = query.trim().toLowerCase();
        const browse = q.match(/^([^\s:]+):\s*(.*)$/);
        if (!q) {
            win.searchWords = [];
            win.filteredCards = win.cardEntries;
        } else if (browse) {
            // "garden:" lists that topic's cards (to place or open something
            // in a topic you're not in); words after it filter them.
            const rest = browse[2];
            win.searchWords = rest ? rest.split(/\s+/) : [];
            win.filteredCards = backend.cardListFor(browse[1]).filter(function (c) {
                return !rest || c.id.indexOf(rest) === 0 || c.title.toLowerCase().indexOf(rest) !== -1;
            });
        } else {
            win.searchWords = q.split(/\s+/);
            const byNumber = win.cardEntries.filter(function (c) { return c.id !== "" && c.id.indexOf(q) === 0; });
            const seen = {};
            for (const c of byNumber) seen[c.topic + ":" + c.id] = true;
            win.filteredCards = byNumber.concat(backend.searchCards(q).filter(function (c) {
                return !seen[c.topic + ":" + c.id];
            }));
        }
        cardListView.currentIndex = win.filteredCards.length > 0 ? 0 : -1;
        win.showSelectedCard();
    }
    function showSelectedCard() {
        const c = cardListView.currentIndex >= 0 ? win.filteredCards[cardListView.currentIndex] : null;
        win.selectedCard = c;
        win.cardPreview = c ? backend.cardContent(c.id, c.topic) : "";
        if (c && win.filingItem)
            win.filePrediction = { after: backend.predictNewCard(c.topic, c.id, "continue"),
                                   branch: backend.predictNewCard(c.topic, c.id, "branch") };
        cardPreviewArea.deselect();
        cardPreviewArea.cursorPosition = 0;
        // Scroll the preview to the first hit and select it, so the match
        // is on screen even deep inside a long card.
        if (c && win.searchWords.length > 0) {
            const lower = win.cardPreview.toLowerCase();
            let at = -1, len = 0;
            for (const w of win.searchWords) {
                const i = lower.indexOf(w);
                if (i >= 0 && (at < 0 || i < at)) { at = i; len = w.length; }
            }
            if (at >= 0) cardPreviewArea.select(at, at + len);
        }
    }
    // Rich text for a result row: the row's text, HTML-escaped, with every
    // search word picked out in the accent colour.
    function highlightMatches(text) {
        const esc = function (t) { return t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); };
        const html = esc(text);
        if (win.searchWords.length === 0) return html;
        const pattern = win.searchWords.map(function (w) {
            return esc(w).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        }).join("|");
        return html.replace(new RegExp(pattern, "gi"), function (m) {
            return "<b><font color=\"" + backend.themeAccent + "\">" + m + "</font></b>";
        });
    }
    function cardLinkFor(c) {
        return "[[" + c.topic + ":" + c.id + "]]";
    }
    function pushJump() {
        const stack = win.jumpStack.slice();
        stack.push({ topic: backend.currentTopic, card: backend.currentCard, pos: editor.cursorPosition });
        if (stack.length > 50) stack.shift();
        win.jumpStack = stack;
    }
    function pickerOpenSelected() {
        if (!win.selectedCard) return;
        if (win.filingItem) { win.fileSelected("continue"); return; }
        const c = win.selectedCard;
        // A search hit from another topic: switch topic in the background
        // (like following a link), straight to the card or the note.
        if (c.other) {
            if (win.topicBusy) return;
            win.pushJump();
            win.topicBusy = true;
            if (c.id) {
                const err = backend.followLink(win.cardLinkFor(c));
                if (err !== "switching") {
                    win.topicBusy = false;
                    win.jumpStack = win.jumpStack.slice(0, -1);
                    if (err) win.flash(err);
                    return;
                }
            } else {
                backend.requestTopicSwitch(c.topic === "main" ? "main" : "topic/" + c.topic);
            }
            win.backToEdit();
            return;
        }
        if (win.selectedCard.id !== backend.currentCard) win.pushJump();
        const err = backend.openCard(win.selectedCard.id);
        if (err) { win.flash(err); return; }
        win.backToEdit();
    }
    // c / b in the picker, and Ctrl+Shift+I from the editor (always
    // "continue" from whatever's open).
    function newCardFrom(fromId, how) {
        if (win.topicBusy) return;
        if (win.mode === "cards" && win.selectedCard && win.selectedCard.other) {
            win.flash("that card is in " + win.selectedCard.topic + " — open it first, then add cards there");
            return;
        }
        win.pushJump();
        const err = backend.newCard(fromId, how);
        if (err) { win.flash(err); return; }
        win.backToEdit();
    }
    // l: drop a link to the highlighted card into the document you came
    // from, exactly where its cursor was, and go back to it.
    function pickerInsertLink() {
        if (!win.selectedCard || win.selectedCard.id === "") return;
        const link = win.cardLinkFor(win.selectedCard);
        const pos = editor.cursorPosition;
        editor.insert(pos, link);
        win.backToEdit();
        editor.cursorPosition = pos + link.length;
    }
    function pickerYankLink() {
        if (!win.selectedCard || win.selectedCard.id === "") return;
        backend.copyToClipboard(win.cardLinkFor(win.selectedCard));
        win.flash("copied " + win.cardLinkFor(win.selectedCard));
    }

    // The [[topic:id]] link the cursor is on, if any — the cursor counts as
    // "on" it anywhere from the first "[" to the last "]".
    function linkAtCursor() {
        const text = editor.text, pos = editor.cursorPosition;
        const lineStart = text.lastIndexOf("\n", pos - 1) + 1;
        let lineEnd = text.indexOf("\n", pos);
        if (lineEnd === -1) lineEnd = text.length;
        const line = text.slice(lineStart, lineEnd);
        const re = /\[\[[^\]:\n]+:[0-9a-z]+\]\]/g;
        let m;
        while ((m = re.exec(line)) !== null) {
            const start = lineStart + m.index, end = start + m[0].length;
            if (pos >= start && pos <= end) return m[0];
        }
        return "";
    }
    function followLinkAtCursor() {
        const link = win.linkAtCursor();
        if (!link) { win.flash("no card link under the cursor"); return; }
        if (win.topicBusy) return;
        win.pushJump();
        const err = backend.followLink(link);
        if (err === "switching") { win.topicBusy = true; return; }
        if (err) { win.jumpStack = win.jumpStack.slice(0, -1); win.flash(err); }
    }
    function jumpBack() {
        if (win.topicBusy || win.jumpStack.length === 0) return;
        const stack = win.jumpStack.slice();
        const j = stack.pop();
        win.jumpStack = stack;
        if (j.topic === backend.currentTopic) {
            if (j.card === backend.currentCard) {
                editor.cursorPosition = Math.min(j.pos, editor.text.length);
                return;
            }
            win.pendingCursor = j.pos;
            const err = backend.openCard(j.card);
            if (err) { win.pendingCursor = -1; win.flash(err); }
            return;
        }
        win.pendingCursor = j.pos;
        win.topicBusy = true;
        if (j.card) {
            const err = backend.followLink("[[" + j.topic + ":" + j.card + "]]");
            if (err !== "switching") { win.topicBusy = false; win.pendingCursor = -1; if (err) win.flash(err); }
        } else {
            backend.requestTopicSwitch(j.topic === "main" ? "main" : "topic/" + j.topic);
        }
    }

    Timer { id: flashTimer; interval: 4000; onTriggered: win.flashMessage = "" }

    // Run a search that's still waiting on its typing pause right now, so
    // Enter / ↓ straight after typing act on its results, not stale ones.
    function flushSearch() {
        if (!searchTimer.running) return;
        searchTimer.stop();
        win.filterCards(cardSearch.text);
    }

    // Global shortcuts. Ctrl+E (drop to a real editor for selection) is
    // gone entirely now that the editor is a native QQuickTextArea with
    // real shift-arrow/word/mouse selection built in.
    // While the launch sync holds the editor (backend.syncLocked), anything
    // that edits, saves or leaves the open document waits too: each of
    // those would cut that first sync short or write into stale text.
    // Linux closes the window from the compositor (Super+W); macOS needs the
    // app to do it.
    Shortcut { sequence: StandardKey.Close; enabled: win.isMac; onActivated: win.close() }
    Shortcut { sequence: "Ctrl+S"; enabled: win.mode === "edit" && !win.topicBusy && !backend.syncLocked; onActivated: backend.save() }
    Shortcut { sequence: "Ctrl+R"; enabled: !backend.syncLocked; onActivated: win.mode === "edit" ? win.openHistory() : win.backToEdit() }
    Shortcut { sequence: "Alt+D"; enabled: win.mode === "edit" && !backend.syncLocked; onActivated: win.insertDate() }
    Shortcut { sequence: "Alt+T"; enabled: win.mode === "edit" && !backend.syncLocked; onActivated: win.insertDateTime() }
    Shortcut { sequence: "Ctrl+1"; enabled: win.mode === "edit"; onActivated: win.jumpToHeading(1) }
    Shortcut { sequence: "Ctrl+2"; enabled: win.mode === "edit"; onActivated: win.jumpToHeading(2) }
    Shortcut { sequence: "Ctrl+3"; enabled: win.mode === "edit"; onActivated: win.jumpToHeading(3) }
    Shortcut { sequence: "Ctrl+4"; enabled: win.mode === "edit"; onActivated: win.jumpToHeading(4) }
    Shortcut { sequence: "Ctrl+5"; enabled: win.mode === "edit"; onActivated: win.jumpToHeading(5) }
    Shortcut { sequence: "Ctrl+6"; enabled: win.mode === "edit"; onActivated: win.jumpToHeading(6) }
    Shortcut { sequence: "Ctrl+7"; enabled: win.mode === "edit"; onActivated: win.jumpToHeading(7) }
    Shortcut { sequence: "Ctrl+8"; enabled: win.mode === "edit"; onActivated: win.jumpToHeading(8) }
    Shortcut { sequence: "Ctrl+9"; enabled: win.mode === "edit"; onActivated: win.jumpToHeading(9) }
    Shortcut {
        sequence: "Ctrl+T"
        enabled: win.mode === "edit" && !win.showHelp && !win.showTopicCreator && !win.topicBusy && !backend.syncLocked && backend.lastError === ""
        onActivated: win.openTopicSwitcher()
    }
    Shortcut {
        sequence: "Ctrl+I"
        enabled: (win.mode === "edit" || win.mode === "cards") && !win.showHelp && !win.showTopicSwitcher
                 && !win.showTopicCreator && !win.topicBusy && !backend.syncLocked && backend.lastError === ""
        onActivated: win.mode === "edit" ? win.openCardPicker() : win.backToEdit()
    }
    Shortcut {
        sequence: "Ctrl+Shift+I"
        enabled: win.mode === "edit" && !win.showHelp && !win.showTopicSwitcher
                 && !win.showTopicCreator && !win.topicBusy && !backend.syncLocked && backend.lastError === ""
        onActivated: win.newCardFrom(backend.currentCard, "continue")
    }
    Shortcut {
        sequence: "Ctrl+O"
        enabled: win.mode === "edit" && !win.showHelp && !win.showTopicSwitcher
                 && !win.showTopicCreator && !win.topicBusy && !backend.syncLocked && backend.lastError === ""
        onActivated: win.jumpBack()
    }
    Shortcut {
        sequence: "Ctrl+Shift+T"
        enabled: win.mode === "edit" && !win.showHelp && !win.showTopicSwitcher && !win.topicBusy && !backend.syncLocked && backend.lastError === ""
        onActivated: win.openTopicCreator()
    }
    // Disabled while visual-selecting: Esc there means "cancel the
    // selection" (handled in previewArea's own Keys.onPressed below), not
    // "leave history" — a second Esc after that falls through to this one.
    Shortcut { sequence: "Escape"; enabled: win.mode !== "edit" && win.previewSelMode === "none"; onActivated: win.escapeFromMode() }
    Shortcut {
        sequence: "Ctrl+B"
        enabled: (win.mode === "edit" || win.mode === "inbox") && !win.showHelp && !win.showTopicSwitcher
                 && !win.showTopicCreator && !win.topicBusy && !backend.syncLocked && backend.lastError === ""
        onActivated: win.mode === "edit" ? win.openInbox() : win.backToEdit()
    }
    // Esc from Insert mode enters vim Normal mode. Once editorMode has left
    // "insert", the editor's own Keys.onPressed (below) handles Esc itself
    // (cancel visual / already-normal no-op) — this Shortcut is disabled at
    // that point so the two never race for the same keypress. Also disabled
    // while an overlay owns Esc (topic switcher/creator, error banner): two
    // enabled Shortcuts on one sequence are ambiguous and Qt fires neither.
    Shortcut {
        sequence: "Escape"
        enabled: win.mode === "edit" && win.editorMode === "insert"
                 && !win.showTopicSwitcher && !win.showTopicCreator && backend.lastError === ""
        onActivated: win.enterEditorNormalMode()
    }

    Connections {
        target: backend
        function onNotice(message) { win.flash(message); }
        function onInboxChanged() { if (win.mode === "inbox" && !win.inboxEditing) win.refreshInbox(); }
        function onTopicOpFinished(error) {
            win.topicBusy = false;
            if (error) {
                if (win.showTopicSwitcher) win.topicSwitchError = error;
                else if (win.showTopicCreator) win.topicCreateError = error;
                else win.flash(error); // a link, a search hit, or Ctrl+O
                return;
            }
            win.showTopicSwitcher = false;
            win.showTopicCreator = false;
            editor.forceActiveFocus();
        }
    }

    Connections {
        target: backend
        // A sync changed the open document (already merged with whatever
        // was typed meanwhile, in the backend). Keep the cursor on the same
        // text: in the unchanged lead-in, same offset; in the unchanged
        // tail, shifted by however much the text grew or shrank.
        function onTextMerged(text) {
            const old = editor.text, pos = editor.cursorPosition;
            let pre = 0;
            while (pre < old.length && pre < text.length && old[pre] === text[pre]) pre++;
            let suf = 0;
            while (suf < old.length - pre && suf < text.length - pre
                   && old[old.length - 1 - suf] === text[text.length - 1 - suf]) suf++;
            // At the very end (where the app opens the note) stays at the
            // end, after anything the sync appended.
            const newPos = pos === old.length ? text.length
                : pos <= pre ? pos
                : pos >= old.length - suf ? pos + (text.length - old.length)
                : Math.min(pos, text.length);
            if (win.editorMode === "visual" || win.editorMode === "visualLine") {
                editor.deselect();
                win.enterEditorNormalMode();
            }
            editor.text = text;
            editor.cursorPosition = Math.max(0, Math.min(newPos, text.length));
        }
        function onSyncLockedChanged() {
            if (backend.syncLocked || !win.heldInput) return;
            editor.insert(editor.cursorPosition, win.heldInput);
            win.heldInput = "";
        }
        function onTextReloaded(text) {
            editor.text = text;
            editor.cursorPosition = win.pendingCursor >= 0 ? Math.min(win.pendingCursor, text.length) : text.length;
            win.pendingCursor = -1;
            // The content just got replaced wholesale (a restore, or a
            // background sync pulling in another machine's edit) — any
            // Normal/Visual-mode selection would now be pointing at
            // content that no longer exists, so drop back to Insert.
            win.enterEditorInsertMode();
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // --- Edit mode -----------------------------------------------
        ScrollView {
            visible: win.mode === "edit"
            Layout.fillWidth: true
            Layout.fillHeight: true

            TextArea {
                id: editor
                wrapMode: TextArea.Wrap
                selectByMouse: true
                persistentSelection: true
                font.family: win.monoFont
                font.pixelSize: 15
                color: backend.themeForeground
                selectionColor: backend.themeSelection
                selectedTextColor: backend.themeForeground
                background: null
                topPadding: 12
                leftPadding: 16
                rightPadding: 16
                bottomPadding: 12
                placeholderText: "Start typing. This is your working memory — jot it down, come back to it."
                placeholderTextColor: backend.themeMuted

                property bool loaded: false
                Component.onCompleted: {
                    text = backend.initialText();
                    cursorPosition = text.length;
                    loaded = true;
                    forceActiveFocus();
                }
                onTextChanged: if (loaded) backend.noteEdited(text)

                // Vim Normal/Visual mode — see the functions above for the
                // model this mirrors from the history preview. Only active
                // once editorMode leaves "insert" (Esc), so plain typing is
                // completely untouched the rest of the time. Every key here
                // is swallowed (event.accepted = true) once out of Insert
                // mode, recognized or not — an unmapped Normal-mode key
                // must never fall through and get typed as literal text.
                readOnly: backend.syncLocked
                opacity: backend.syncLocked ? 0.55 : 1
                Behavior on opacity { NumberAnimation { duration: 150 } }

                Keys.onPressed: function (event) {
                    // Launch sync still running: hold what's typed (the
                    // field is read-only meanwhile) rather than drop it, and
                    // apply it once the up-to-date text is in. Shortcuts
                    // (anything with Ctrl/Alt/Meta) fall through as usual.
                    if (backend.syncLocked) {
                        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return;
                        if (win.editorMode !== "insert") { if (event.key !== Qt.Key_Escape) event.accepted = true; return; }
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) win.heldInput += "\n";
                        else if (event.key === Qt.Key_Backspace) win.heldInput = win.heldInput.slice(0, -1);
                        else if (event.text && event.text.charCodeAt(0) >= 32 || event.text === "\t") win.heldInput += event.text;
                        else return;
                        event.accepted = true;
                        return;
                    }
                    if (win.editorMode === "insert") return;
                    // Every vim command here is a plain, unmodified key —
                    // so anything held with Ctrl/Alt/Meta is never one of
                    // them and must fall through to the window's global
                    // Shortcut items (Ctrl+S, Ctrl+R, Ctrl+T, Alt+D, ...),
                    // which would otherwise stop working the moment Esc
                    // leaves Insert mode.
                    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return;
                    event.accepted = true;

                    if (win.showHelp) {
                        if (event.key === Qt.Key_Escape || event.text === "?") win.showHelp = false;
                        return;
                    }

                    // A pending prefix ("d" of dd, "g" of gg) lives only
                    // until the very next key, vim-style — read it and
                    // clear it up front so no branch below can leave one
                    // stale and have it complete a sequence several keys later.
                    const hadD = win.pendingD, hadG = win.pendingG;
                    win.pendingD = false;
                    win.pendingG = false;

                    if (event.key === Qt.Key_Escape) {
                        editor.deselect();
                        win.enterEditorNormalMode();
                        return;
                    }

                    // gg / G — jump to the very top / very bottom of the
                    // note, the motion that matters most once a note has
                    // grown past a few screens. Handled before the mode
                    // split because it behaves identically in Normal and
                    // Visual mode: updateEditorSelection() does nothing in
                    // Normal and extends the selection to the new cursor
                    // position in Visual.
                    // gd / Enter: follow the [[topic:id]] card link under
                    // the cursor (Ctrl+O comes back), vim's go-to-definition.
                    if (hadG && event.text === "d") { win.followLinkAtCursor(); return; }
                    if (win.editorMode === "normal" && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                        win.followLinkAtCursor();
                        return;
                    }

                    if (event.text === "g") {
                        if (hadG) { editor.cursorPosition = 0; win.updateEditorSelection(); }
                        else win.pendingG = true;
                        return;
                    }
                    if (event.text === "G") {
                        editor.cursorPosition = editor.text.length;
                        win.updateEditorSelection();
                        return;
                    }

                    if (win.editorMode === "visual" || win.editorMode === "visualLine") {
                        if (event.text === "y") { win.yankEditorSelection(); return; }
                        if (event.text === "d" || event.text === "x") { win.deleteEditorSelection(); return; }
                        else if (event.key === Qt.Key_Left || event.text === "h") editor.cursorPosition = Math.max(0, editor.cursorPosition - 1);
                        else if (event.key === Qt.Key_Right || event.text === "l") editor.cursorPosition = Math.min(editor.text.length, editor.cursorPosition + 1);
                        else if (event.key === Qt.Key_Down || event.text === "j") { const r = editor.cursorRectangle; editor.cursorPosition = editor.positionAt(r.x, r.y + r.height * 1.5); }
                        else if (event.key === Qt.Key_Up || event.text === "k") { const r = editor.cursorRectangle; editor.cursorPosition = editor.positionAt(r.x, r.y - r.height * 0.5); }
                        else return;
                        win.updateEditorSelection();
                        return;
                    }

                    // Normal mode.
                    if (event.text === "?") { win.showHelp = true; return; }
                    if (event.text === "i") { win.enterEditorInsertMode(); return; }
                    if (event.text === "v") { win.enterEditorVisual("visual"); return; }
                    if (event.text === "V") { win.enterEditorVisual("visualLine"); return; }
                    if (event.text === "D") { win.deleteToEndOfLine(); return; }
                    if (event.text === "d") {
                        if (hadD) win.deleteCurrentLine();
                        else win.pendingD = true;
                        return;
                    }
                    if (event.key === Qt.Key_Left || event.text === "h") editor.cursorPosition = Math.max(0, editor.cursorPosition - 1);
                    else if (event.key === Qt.Key_Right || event.text === "l") editor.cursorPosition = Math.min(editor.text.length, editor.cursorPosition + 1);
                    else if (event.key === Qt.Key_Down || event.text === "j") { const r = editor.cursorRectangle; editor.cursorPosition = editor.positionAt(r.x, r.y + r.height * 1.5); }
                    else if (event.key === Qt.Key_Up || event.text === "k") { const r = editor.cursorRectangle; editor.cursorPosition = editor.positionAt(r.x, r.y - r.height * 0.5); }
                }
            }
        }

        // --- History: list on the left, live read-only preview on the
        // right. The preview follows the list selection directly (no
        // separate "open" step) since the point is skimming through many
        // versions quickly to find one, not reading each in turn.
        RowLayout {
            visible: win.mode === "history"
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            ColumnLayout {
                // min == max == preferred: genuinely fixed, not just a
                // suggestion RowLayout can override if a child's content
                // pushes back (that's what let long commit messages drag
                // this pane wider — see the delegate below).
                Layout.preferredWidth: 300
                Layout.minimumWidth: 300
                Layout.maximumWidth: 300
                Layout.fillHeight: true
                spacing: 0

                TextField {
                    id: historySearch
                    Layout.fillWidth: true
                    placeholderText: "Search history…"
                    color: backend.themeForeground
                    placeholderTextColor: backend.themeMuted
                    background: Rectangle { color: backend.themeSelection }
                    onTextChanged: win.filterHistory(text)
                    Keys.onDownPressed: historyList.forceActiveFocus()
                    Keys.onEscapePressed: historyList.forceActiveFocus()
                }

                ListView {
                    id: historyList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    model: win.filteredHistory
                    clip: true
                    keyNavigationEnabled: true
                    highlightMoveDuration: 60
                    onCurrentIndexChanged: win.showSelected()

                    // j/k mirror the arrow keys vim-style; / matches vim's
                    // own search-entry key (letters are otherwise reserved
                    // for navigation/visual-mode here, so "just start
                    // typing" would collide with v/V/y/j/k).
                    Keys.onPressed: function (event) {
                        if (event.text === "j") { historyList.currentIndex = Math.min(historyList.currentIndex + 1, historyList.count - 1); event.accepted = true; }
                        else if (event.text === "k") { historyList.currentIndex = Math.max(historyList.currentIndex - 1, 0); event.accepted = true; }
                        else if (event.key === Qt.Key_Slash) { historySearch.forceActiveFocus(); event.accepted = true; }
                        else if (event.text === "v") { win.enterVisualMode("char"); event.accepted = true; }
                        else if (event.text === "V") { win.enterVisualMode("line"); event.accepted = true; }
                    }

                    delegate: ItemDelegate {
                        width: historyList.width
                        highlighted: ListView.isCurrentItem
                        onClicked: historyList.currentIndex = index
                        // The current row holds keyboard focus and, being a
                        // button underneath, accepts Return itself — so the
                        // list's own Keys.onReturnPressed below never sees it.
                        Keys.onReturnPressed: win.restoreSelected()
                        Keys.onEnterPressed: win.restoreSelected()
                        background: Rectangle {
                            color: highlighted ? backend.themeSelection : "transparent"
                        }
                        // A plain Column with an explicit width, not a
                        // ColumnLayout, and each Text's width set directly
                        // rather than via Layout.fillWidth: a ColumnLayout
                        // used as a Control's contentItem doesn't reliably
                        // inherit the control's width, so elide had nothing
                        // to elide against — a long message rendered at
                        // full length, which widened this row's (and so
                        // the whole list's) implicit width, which is what
                        // was dragging the list/preview divider around
                        // depending on which row was selected.
                        contentItem: Column {
                            width: historyList.width - 24
                            spacing: 2
                            Text { text: modelData.time; color: backend.themeForeground; font.bold: true }
                            Text { text: modelData.message; color: backend.themeMuted; elide: Text.ElideRight; width: parent.width }
                        }
                    }

                    Keys.onReturnPressed: win.restoreSelected()
                    Keys.onEnterPressed: win.restoreSelected()
                }
            }

            Rectangle { Layout.fillHeight: true; width: 1; color: backend.themeMuted; opacity: 0.3 }

            // Right pane: a title strip naming exactly which version this is
            // (the clearest possible "you are not editing the live note"
            // cue) over the read-only content itself.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                Rectangle {
                    Layout.fillWidth: true
                    height: 36
                    color: backend.themeSelection
                    visible: win.selectedEntry !== null

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 16
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        color: backend.themeForeground
                        font.bold: true
                        elide: Text.ElideRight
                        text: win.selectedEntry ? ("Read-only — " + win.selectedEntry.time) : ""
                    }
                }

                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    TextArea {
                        id: previewArea
                        readOnly: true
                        selectByMouse: true
                        persistentSelection: true
                        wrapMode: TextArea.Wrap
                        text: win.historyContent
                        font.family: win.monoFont
                        font.pixelSize: 15
                        color: backend.themeForeground
                        selectionColor: backend.themeSelection
                        selectedTextColor: backend.themeForeground
                        // A faint tint (not a loud color change) is the
                        // secondary read-only cue — the title strip above
                        // and the list beside it already make the mode
                        // unambiguous, so this stays subtle.
                        background: Rectangle { color: Qt.darker(backend.themeBackground, 1.08) }
                        topPadding: 12
                        leftPadding: 16
                        rightPadding: 16
                        bottomPadding: 12

                        // Only meaningful once v/V (see historyList above)
                        // put us in visual mode — h/j/k/l (and the arrow
                        // keys) move the cursor and extend the selection
                        // from the anchor, vim-style. j/k move by logical
                        // line (found via the raw text's own newlines, not
                        // the wrapped display row) at roughly the same
                        // column, using the cursor's pixel position to
                        // land on the right row — QML has no "move by
                        // visual line" API to call directly.
                        Keys.onPressed: function (event) {
                            if (win.previewSelMode === "none") return;

                            const text = win.historyContent;
                            const lineStartOf = (pos) => text.lastIndexOf("\n", pos - 1) + 1;
                            const lineEndOf = (pos) => { const i = text.indexOf("\n", pos); return i === -1 ? text.length : i; };

                            // As in the editor, a pending "g" lives only
                            // until the very next key — read and clear it
                            // up front so no branch leaves one stale.
                            const hadG = win.previewPendingG;
                            win.previewPendingG = false;

                            let handled = true;
                            if (event.key === Qt.Key_Escape) {
                                win.exitVisualMode();
                            } else if (event.text === "g") {
                                // gg / G extend the selection to the very
                                // top / bottom of this version — the whole
                                // point of a visual selection in a note
                                // too long to scroll through by hand.
                                if (hadG) previewArea.cursorPosition = 0;
                                else win.previewPendingG = true;
                            } else if (event.text === "G") {
                                previewArea.cursorPosition = text.length;
                            } else if (event.text === "y" || (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier))) {
                                win.yankPreviewSelection();
                            } else if (event.key === Qt.Key_Left || event.text === "h") {
                                previewArea.cursorPosition = Math.max(0, previewArea.cursorPosition - 1);
                            } else if (event.key === Qt.Key_Right || event.text === "l") {
                                previewArea.cursorPosition = Math.min(text.length, previewArea.cursorPosition + 1);
                            } else if (event.key === Qt.Key_Down || event.text === "j") {
                                const r = previewArea.cursorRectangle;
                                previewArea.cursorPosition = previewArea.positionAt(r.x, r.y + r.height * 1.5);
                            } else if (event.key === Qt.Key_Up || event.text === "k") {
                                const r = previewArea.cursorRectangle;
                                previewArea.cursorPosition = previewArea.positionAt(r.x, r.y - r.height * 0.5);
                            } else {
                                handled = false;
                            }

                            if (handled) {
                                win.updatePreviewSelection();
                                event.accepted = true;
                            }
                        }
                    }
                }
            }
        }

        // --- Inbox: captures on the left (oldest first — the order to work
        // through them), the whole capture on the right.
        RowLayout {
            visible: win.mode === "inbox"
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            ColumnLayout {
                Layout.preferredWidth: 320
                Layout.minimumWidth: 320
                Layout.maximumWidth: 320
                Layout.fillHeight: true
                spacing: 0

                Rectangle {
                    Layout.fillWidth: true
                    height: 36
                    color: backend.themeSelection
                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Inbox · " + win.inboxEntries.length + (win.inboxEntries.length === 1 ? " capture" : " captures")
                        color: backend.themeForeground
                        font.bold: true
                    }
                }

                Text {
                    visible: win.inboxEntries.length === 0
                    Layout.fillWidth: true
                    Layout.margins: 16
                    wrapMode: Text.Wrap
                    color: backend.themeMuted
                    text: "Nothing waiting. Captures from the browser extension land here, to be filed into the slip box."
                }

                ListView {
                    id: inboxListView
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    model: win.inboxEntries
                    clip: true
                    keyNavigationEnabled: true
                    highlightMoveDuration: 60
                    onCurrentIndexChanged: win.showSelectedInbox()

                    Keys.onPressed: function (event) {
                        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return;
                        if (win.showHelp) { if (event.text === "?") win.showHelp = false; event.accepted = true; return; }
                        const hadD = win.pendingInboxD;
                        win.pendingInboxD = false;
                        let handled = true;
                        if (event.text === "j") inboxListView.currentIndex = Math.min(inboxListView.currentIndex + 1, inboxListView.count - 1);
                        else if (event.text === "k") inboxListView.currentIndex = Math.max(inboxListView.currentIndex - 1, 0);
                        else if (event.text === "d") { if (hadD) win.discardSelectedInbox(); else win.pendingInboxD = true; }
                        else if (event.text === "y") { if (win.selectedInbox) { backend.copyToClipboard(win.selectedInbox.text); win.flash("copied"); } }
                        else if (event.text === "e") win.startInboxEdit();
                        else if (event.text === "n") win.quickFileInbox();
                        else if (event.text === "?") win.showHelp = true;
                        else if (event.text === "f" || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) win.startFiling();
                        else handled = false;
                        if (handled) event.accepted = true;
                    }

                    delegate: ItemDelegate {
                        width: inboxListView.width
                        highlighted: ListView.isCurrentItem
                        onClicked: inboxListView.currentIndex = index
                        onDoubleClicked: { inboxListView.currentIndex = index; win.startFiling(); }
                        // Same reason as the card picker's rows: the
                        // focused row would swallow Return otherwise.
                        Keys.onReturnPressed: win.startFiling()
                        Keys.onEnterPressed: win.startFiling()
                        background: Rectangle { color: highlighted ? backend.themeSelection : "transparent" }
                        contentItem: Column {
                            width: inboxListView.width - 24
                            spacing: 2
                            Text { text: modelData.time; color: backend.themeMuted; font.pixelSize: 11 }
                            Text { text: modelData.title; color: backend.themeForeground; font.bold: true; elide: Text.ElideRight; width: parent.width }
                            Text { text: modelData.snippet; color: backend.themeMuted; elide: Text.ElideRight; width: parent.width; visible: text !== "" }
                        }
                    }
                }
            }

            Rectangle { Layout.fillHeight: true; width: 1; color: backend.themeMuted; opacity: 0.3 }

            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                TextArea {
                    id: inboxPreview
                    readOnly: !win.inboxEditing
                    selectByMouse: true
                    wrapMode: TextArea.Wrap
                    text: win.selectedInbox ? win.selectedInbox.text : ""
                    onActiveFocusChanged: if (!activeFocus) win.finishInboxEdit(false)
                    font.family: win.monoFont
                    font.pixelSize: 15
                    color: backend.themeForeground
                    selectionColor: backend.themeSelection
                    selectedTextColor: backend.themeForeground
                    background: Rectangle {
                        color: Qt.darker(backend.themeBackground, 1.08)
                        border.color: backend.themeAccent
                        border.width: win.inboxEditing ? 1 : 0
                    }
                    topPadding: 12
                    leftPadding: 16
                    rightPadding: 16
                    bottomPadding: 12
                }
            }
        }

        // --- Index cards: the same list-beside-preview layout as history,
        // the list in slip-box order and indented by branch depth so the
        // shape of each line of thought shows at a glance.
        RowLayout {
            visible: win.mode === "cards"
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            ColumnLayout {
                Layout.preferredWidth: 320
                Layout.minimumWidth: 320
                Layout.maximumWidth: 320
                Layout.fillHeight: true
                spacing: 0

                TextField {
                    id: cardSearch
                    Layout.fillWidth: true
                    placeholderText: "Search every topic (words, or a card number)…"
                    color: backend.themeForeground
                    placeholderTextColor: backend.themeMuted
                    background: Rectangle { color: backend.themeSelection }
                    onTextChanged: searchTimer.restart()
                    Keys.onDownPressed: { win.flushSearch(); cardListView.forceActiveFocus(); }
                    Keys.onEscapePressed: cardListView.forceActiveFocus()
                    // Enter opens the top (or highlighted) hit directly;
                    // ↓ moves into the list instead, for l / y on a hit.
                    Keys.onReturnPressed: { win.flushSearch(); win.pickerOpenSelected(); }
                    Keys.onEnterPressed: { win.flushSearch(); win.pickerOpenSelected(); }

                    Timer { id: searchTimer; interval: 150; onTriggered: win.filterCards(cardSearch.text) }
                }

                ListView {
                    id: cardListView
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    model: win.filteredCards
                    clip: true
                    keyNavigationEnabled: true
                    highlightMoveDuration: 60
                    onCurrentIndexChanged: win.showSelectedCard()

                    // Letters are commands here (as in history), so search
                    // sits behind "/" rather than "just start typing".
                    Keys.onPressed: function (event) {
                        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return;
                        let handled = true;
                        if (win.filingItem) {
                            // Placing a capture: Enter/c and b pick the spot;
                            // the link keys don't apply.
                            if (event.text === "c" || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { win.fileSelected("continue"); event.accepted = true; return; }
                            if (event.text === "b") { win.fileSelected("branch"); event.accepted = true; return; }
                            if (event.text === "l" || event.text === "y") { event.accepted = true; return; }
                        }
                        if (event.text === "j") cardListView.currentIndex = Math.min(cardListView.currentIndex + 1, cardListView.count - 1);
                        else if (event.text === "k") cardListView.currentIndex = Math.max(cardListView.currentIndex - 1, 0);
                        else if (event.text === "g") cardListView.currentIndex = 0;
                        else if (event.text === "G") cardListView.currentIndex = cardListView.count - 1;
                        else if (event.key === Qt.Key_Slash) cardSearch.forceActiveFocus();
                        else if (event.text === "l") win.pickerInsertLink();
                        else if (event.text === "y") win.pickerYankLink();
                        else if (event.text === "c" && win.selectedCard) win.newCardFrom(win.selectedCard.id, "continue");
                        else if (event.text === "b" && win.selectedCard) win.newCardFrom(win.selectedCard.id, "branch");
                        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) win.pickerOpenSelected();
                        else handled = false;
                        if (handled) event.accepted = true;
                    }

                    delegate: ItemDelegate {
                        width: cardListView.width
                        highlighted: ListView.isCurrentItem
                        onClicked: cardListView.currentIndex = index
                        onDoubleClicked: { cardListView.currentIndex = index; win.pickerOpenSelected(); }
                        // The ListView hands its current row keyboard focus,
                        // and the row (a button underneath) accepts Return
                        // itself, so it never bubbles up to the list's
                        // handler — catch it here instead.
                        Keys.onReturnPressed: win.pickerOpenSelected()
                        Keys.onEnterPressed: win.pickerOpenSelected()
                        background: Rectangle {
                            color: highlighted ? backend.themeSelection : "transparent"
                        }
                        // Plain Column with explicit widths, for the same
                        // reason as the history delegate: keeps a long
                        // title from widening the fixed-width list.
                        contentItem: Column {
                            width: cardListView.width - 24
                            leftPadding: modelData.depth * 14
                            spacing: 2
                            Row {
                                spacing: 8
                                Text {
                                    text: modelData.id === "" ? "note" : modelData.id
                                    color: modelData.id === "" ? backend.themeMuted : backend.themeAccent
                                    font.family: win.monoFont
                                    font.bold: true
                                    font.italic: modelData.id === ""
                                }
                                Text { text: modelData.time; color: backend.themeMuted; font.pixelSize: 11; visible: !modelData.other }
                                Text {
                                    visible: !!modelData.other
                                    text: "in " + modelData.topic
                                    color: backend.themeBackground
                                    font.pixelSize: 11
                                    font.bold: true
                                    leftPadding: 5; rightPadding: 5; topPadding: 1; bottomPadding: 1
                                    Rectangle { anchors.fill: parent; z: -1; radius: 3; color: backend.themeAccent }
                                }
                                Text { text: modelData.current ? "●" : ""; color: backend.themeAccent; font.pixelSize: 11 }
                            }
                            Text {
                                text: modelData.title ? win.highlightMatches(modelData.title) : "(empty)"
                                textFormat: Text.StyledText
                                color: modelData.title ? backend.themeForeground : backend.themeMuted
                                elide: Text.ElideRight
                                width: parent.width - parent.leftPadding
                            }
                        }
                    }
                }
            }

            Rectangle { Layout.fillHeight: true; width: 1; color: backend.themeMuted; opacity: 0.3 }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                Rectangle {
                    Layout.fillWidth: true
                    height: 36
                    color: backend.themeSelection
                    visible: win.selectedCard !== null

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 16
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        color: backend.themeForeground
                        font.bold: true
                        elide: Text.ElideRight
                        text: !win.selectedCard ? ""
                            : win.filingItem
                              ? (win.selectedCard.id === ""
                                 ? "File as new card " + win.filePrediction.after + " in " + win.selectedCard.topic
                                 : "File in " + win.selectedCard.topic + ":  enter → " + win.filePrediction.after
                                   + " (after " + win.selectedCard.id + ")   ·   b → " + win.filePrediction.branch + " (branch)")
                            : win.selectedCard.id === "" ? win.selectedCard.topic + " — topic note"
                            : "Card " + win.selectedCard.id
                              + (win.selectedCard.other ? "  ·  in " + win.selectedCard.topic
                                 : win.selectedCard.time ? "  ·  " + win.selectedCard.time : "")
                    }
                }

                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    TextArea {
                        id: cardPreviewArea
                        readOnly: true
                        selectByMouse: true
                        persistentSelection: true
                        wrapMode: TextArea.Wrap
                        text: win.cardPreview
                        font.family: win.monoFont
                        font.pixelSize: 15
                        color: backend.themeForeground
                        // Accent, not the usual subtle selection tint: the
                        // selection here is mostly the search hit.
                        selectionColor: backend.themeAccent
                        selectedTextColor: backend.themeBackground
                        background: Rectangle { color: Qt.darker(backend.themeBackground, 1.08) }
                        topPadding: 12
                        leftPadding: 16
                        rightPadding: 16
                        bottomPadding: 12
                    }
                }
            }
        }

        // --- Footer -----------------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            height: 28
            color: backend.themeSelection

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12

                Text {
                    Layout.fillWidth: true
                    color: backend.themeMuted
                    font.pixelSize: 12
                    elide: Text.ElideRight
                    text: {
                        if (win.mode === "edit") {
                            if (backend.syncLocked)
                                return "getting the latest from your other machines…"
                                    + (win.heldInput ? "  (" + win.heldInput.length + " typed, will appear in a moment)" : "");
                            if (win.editorMode === "insert")
                                return win.keyLabel("esc vim mode · ctrl+s save · ? help");
                            const label = win.editorMode === "visualLine" ? "VISUAL LINE"
                                : win.editorMode === "visual" ? "VISUAL" : "NORMAL";
                            const pending = win.pendingD ? "  d" : win.pendingG ? "  g" : "";
                            return "-- " + label + " --" + pending + "   ?  help";
                        }
                        if (win.mode === "inbox" && win.inboxEditing)
                            return "editing this capture · esc saves it";
                        if (win.mode === "inbox")
                            return win.pendingInboxD ? "d again to discard this capture · any other key cancels"
                                : "j/k move · enter place it · n file as next card · e edit · dd discard · y copy · ? help · esc back";
                        if (win.mode === "cards" && win.filingItem)
                            return "placing “" + win.filingItem.title + "” · enter after · b branch · topic: lists a topic · / search · esc back to inbox";
                        if (win.mode === "cards")
                            return "j/k move · enter open · l link here · y copy link · c new after · b branch · / search all topics · esc back";
                        if (win.previewSelMode !== "none")
                            return win.keyLabel("h/j/k/l move · gg/G top/bottom · y/ctrl+c/super+c yank · esc cancel")
                                + (win.previewPendingG ? "   g" : "");
                        return "j/k/↑/↓ move · / search · v/V visual select · enter restore · esc back";
                    }
                }
                Text {
                    color: backend.themeAccent
                    font.pixelSize: 12
                    text: win.flashMessage ? win.flashMessage
                        : win.mode === "edit" ? (backend.inboxCount > 0 ? "inbox " + backend.inboxCount + " · " : "")
                                                + (backend.currentCard ? "card " + backend.currentCard + " · " : "") + backend.status
                        : ""
                }
            }
        }
    }

    // --- Error overlay ----------------------------------------------------
    // Unlike a one-line status bar (which is exactly what silently
    // corrupted in the previous terminal version for a long error), this
    // is a full page: wrapped, scrollable, and its text is natively
    // mouse-selectable, so a real error is always fully readable and
    // copyable, however long it is.
    Rectangle {
        anchors.fill: parent
        visible: backend.lastError !== ""
        color: backend.themeBackground
        z: 10

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                TextArea {
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextArea.Wrap
                    text: backend.lastError
                    color: "#f7768e"
                    font.family: win.monoFont
                    font.pixelSize: 14
                    background: null
                    topPadding: 16
                    leftPadding: 16
                    rightPadding: 16
                }
            }

            Rectangle {
                Layout.fillWidth: true
                height: 28
                color: backend.themeSelection
                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 12
                    color: backend.themeMuted
                    font.pixelSize: 12
                    text: win.keyLabel("select + ctrl+c/super+c to copy · esc/enter dismiss · also logged to ") + backend.logPath
                }
            }
        }

        Shortcut { sequence: "Escape"; enabled: backend.lastError !== ""; onActivated: backend.dismissError() }
        Shortcut { sequence: "Return"; enabled: backend.lastError !== ""; onActivated: backend.dismissError() }
    }

    // --- Help overlay ("?" from vim Normal mode) ---------------------------
    // A quick reference, not a blocking error: a centered card over a
    // dimmed backdrop, dismissed the same way it's opened (? or Esc — see
    // the editor's Keys.onPressed). Everything that used to be spelled out
    // in the footer lives here now, so the footer itself can stay short.
    Rectangle {
        anchors.fill: parent
        visible: win.showHelp
        color: Qt.rgba(0, 0, 0, 0.5)
        z: 9

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(560, parent.width - 80)
            height: Math.min(helpColumn.implicitHeight + 40, parent.height - 80)
            color: backend.themeBackground
            border.color: backend.themeMuted
            border.width: 1
            radius: 6
            clip: true

            Flickable {
                anchors.fill: parent
                anchors.margins: 20
                contentHeight: helpColumn.implicitHeight
                clip: true

                Column {
                    id: helpColumn
                    width: parent.width
                    spacing: 10

                    Text {
                        text: "Keyboard shortcuts"
                        font.bold: true
                        font.pixelSize: 16
                        color: backend.themeForeground
                    }

                    Repeater {
                        // Opened from the inbox, its section comes first.
                        model: win.mode !== "inbox" ? win.helpSections
                            : win.helpSections.filter(s => s.title.startsWith("Inbox")).concat(win.helpSections.filter(s => !s.title.startsWith("Inbox")))
                        delegate: Column {
                            width: helpColumn.width
                            topPadding: index === 0 ? 0 : 10
                            spacing: 6

                            Text {
                                text: modelData.title
                                color: backend.themeAccent
                                font.bold: true
                                font.pixelSize: 13
                            }
                            Repeater {
                                model: modelData.items
                                delegate: Row {
                                    width: helpColumn.width
                                    spacing: 12
                                    Text {
                                        text: win.keyLabel(modelData.key)
                                        color: backend.themeForeground
                                        font.family: win.monoFont
                                        font.bold: true
                                        width: 110
                                    }
                                    Text {
                                        text: modelData.desc
                                        color: backend.themeMuted
                                        width: parent.width - 122
                                        wrapMode: Text.Wrap
                                    }
                                }
                            }
                        }
                    }

                    Text {
                        topPadding: 6
                        text: "esc or ? to close"
                        color: backend.themeMuted
                        font.pixelSize: 11
                        font.italic: true
                    }
                }
            }
        }
    }

    // --- Topic switcher (Ctrl+T) -------------------------------------------
    // Same search-as-you-type + list pattern as the history picker
    // (historySearch/historyList above), just against topics instead of
    // versions — a filter box up top since the list can grow without bound.
    Rectangle {
        anchors.fill: parent
        visible: win.showTopicSwitcher
        color: Qt.rgba(0, 0, 0, 0.5)
        z: 9

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(420, parent.width - 80)
            height: Math.min(380, parent.height - 80)
            color: backend.themeBackground
            border.color: backend.themeMuted
            border.width: 1
            radius: 6

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 8

                Text { text: "Switch topic"; font.bold: true; font.pixelSize: 16; color: backend.themeForeground }

                TextField {
                    id: topicSearch
                    Layout.fillWidth: true
                    enabled: !win.topicBusy
                    placeholderText: "Search topics…"
                    color: backend.themeForeground
                    placeholderTextColor: backend.themeMuted
                    background: Rectangle { color: backend.themeSelection }
                    onTextChanged: win.filterTopics(text)
                    Keys.onDownPressed: topicResults.forceActiveFocus()
                    Keys.onReturnPressed: win.confirmTopicSwitch()
                    Keys.onEnterPressed: win.confirmTopicSwitch()
                }

                ListView {
                    id: topicResults
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    enabled: !win.topicBusy
                    model: win.filteredTopics
                    clip: true
                    keyNavigationEnabled: true
                    highlightMoveDuration: 60

                    Keys.onReturnPressed: win.confirmTopicSwitch()
                    Keys.onEnterPressed: win.confirmTopicSwitch()
                    Keys.onEscapePressed: win.closeTopicSwitcher()

                    delegate: ItemDelegate {
                        width: topicResults.width
                        highlighted: ListView.isCurrentItem
                        onClicked: { topicResults.currentIndex = index; win.confirmTopicSwitch(); }
                        background: Rectangle { color: highlighted ? backend.themeSelection : "transparent" }
                        contentItem: Row {
                            spacing: 8
                            Text {
                                text: modelData.current ? "●" : ""
                                color: backend.themeAccent
                                width: 14
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: modelData.label
                                color: backend.themeForeground
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }
                }

                Text {
                    visible: win.topicBusy
                    text: "switching…"
                    color: backend.themeMuted
                    font.pixelSize: 12
                }

                Text {
                    visible: !win.topicBusy && win.topicSwitchError !== ""
                    text: win.topicSwitchError
                    color: "#f7768e"
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }

                Text {
                    text: "enter select · esc cancel"
                    color: backend.themeMuted
                    font.pixelSize: 11
                }
            }
        }

        Shortcut { sequence: "Escape"; enabled: win.showTopicSwitcher && !win.topicBusy; onActivated: win.closeTopicSwitcher() }
    }

    // --- Topic creator (Ctrl+Shift+T) ---------------------------------------
    Rectangle {
        anchors.fill: parent
        visible: win.showTopicCreator
        color: Qt.rgba(0, 0, 0, 0.5)
        z: 9

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(420, parent.width - 80)
            height: topicCreateColumn.implicitHeight + 32
            color: backend.themeBackground
            border.color: backend.themeMuted
            border.width: 1
            radius: 6

            ColumnLayout {
                id: topicCreateColumn
                anchors.fill: parent
                anchors.margins: 16
                spacing: 10

                Text { text: "New topic"; font.bold: true; font.pixelSize: 16; color: backend.themeForeground }
                Text {
                    text: win.keyLabel("Starts as its own blank note, branched off — switch back any time with Ctrl+T.")
                    color: backend.themeMuted
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }

                TextField {
                    id: topicNameField
                    Layout.fillWidth: true
                    enabled: !win.topicBusy
                    placeholderText: "Topic name…"
                    color: backend.themeForeground
                    placeholderTextColor: backend.themeMuted
                    background: Rectangle { color: backend.themeSelection }
                    Keys.onReturnPressed: win.confirmTopicCreate()
                    Keys.onEnterPressed: win.confirmTopicCreate()
                }

                Text {
                    visible: win.topicBusy
                    text: "creating…"
                    color: backend.themeMuted
                    font.pixelSize: 12
                }

                Text {
                    visible: !win.topicBusy && win.topicCreateError !== ""
                    text: win.topicCreateError
                    color: "#f7768e"
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }

                Text {
                    text: "enter create · esc cancel"
                    color: backend.themeMuted
                    font.pixelSize: 11
                }
            }
        }

        Shortcut { sequence: "Escape"; enabled: win.showTopicCreator && !win.topicBusy; onActivated: win.closeTopicCreator() }
    }
}
