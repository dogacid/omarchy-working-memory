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
    title: backend.currentTopic === "main" ? "Working memory" : "Working memory — " + backend.currentTopic
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

    // Same idea, but live-editable: "insert" (normal typing, the default)
    // | "normal" (vim Normal mode, entered via Esc) | "visual" (v) |
    // "visualLine" (V). editorAnchor is the fixed end of a visual
    // selection, mirroring previewAnchor/previewSelMode above.
    property string editorMode: "insert"
    property int editorAnchor: 0
    // True right after a single "d" in Normal mode, waiting to see if the
    // next key completes "dd" — reset on any other key or mode change.
    property bool pendingD: false
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

    onClosing: backend.save()

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
    }
    function enterEditorInsertMode() {
        win.editorMode = "insert";
        win.pendingD = false;
        editor.deselect();
    }
    function enterEditorVisual(kind) {
        win.editorMode = kind;
        win.editorAnchor = editor.cursorPosition;
        win.pendingD = false;
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
        if (topicResults.currentIndex < 0 || topicResults.currentIndex >= win.filteredTopics.length) return;
        const err = backend.switchTopic(win.filteredTopics[topicResults.currentIndex].branch);
        if (err) { win.topicSwitchError = err; return; }
        win.showTopicSwitcher = false;
        editor.forceActiveFocus();
    }
    function closeTopicSwitcher() {
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
        const err = backend.createTopic(topicNameField.text);
        if (err) { win.topicCreateError = err; return; }
        win.showTopicCreator = false;
        editor.forceActiveFocus();
    }
    function closeTopicCreator() {
        win.showTopicCreator = false;
        editor.forceActiveFocus();
    }

    // Global shortcuts. Ctrl+E (drop to a real editor for selection) is
    // gone entirely now that the editor is a native QQuickTextArea with
    // real shift-arrow/word/mouse selection built in.
    Shortcut { sequence: "Ctrl+S"; enabled: win.mode === "edit"; onActivated: backend.save() }
    Shortcut { sequence: "Ctrl+R"; onActivated: win.mode === "edit" ? win.openHistory() : win.backToEdit() }
    Shortcut { sequence: "Alt+D"; enabled: win.mode === "edit"; onActivated: win.insertDate() }
    Shortcut { sequence: "Alt+T"; enabled: win.mode === "edit"; onActivated: win.insertDateTime() }
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
        enabled: win.mode === "edit" && !win.showHelp && !win.showTopicCreator && backend.lastError === ""
        onActivated: win.openTopicSwitcher()
    }
    Shortcut {
        sequence: "Ctrl+Shift+T"
        enabled: win.mode === "edit" && !win.showHelp && !win.showTopicSwitcher && backend.lastError === ""
        onActivated: win.openTopicCreator()
    }
    // Disabled while visual-selecting: Esc there means "cancel the
    // selection" (handled in previewArea's own Keys.onPressed below), not
    // "leave history" — a second Esc after that falls through to this one.
    Shortcut { sequence: "Escape"; enabled: win.mode !== "edit" && win.previewSelMode === "none"; onActivated: win.backToEdit() }
    // Esc from Insert mode enters vim Normal mode. Once editorMode has left
    // "insert", the editor's own Keys.onPressed (below) handles Esc itself
    // (cancel visual / already-normal no-op) — this Shortcut is disabled at
    // that point so the two never race for the same keypress.
    Shortcut { sequence: "Escape"; enabled: win.mode === "edit" && win.editorMode === "insert"; onActivated: win.enterEditorNormalMode() }

    Connections {
        target: backend
        function onTextReloaded(text) {
            editor.text = text;
            editor.cursorPosition = text.length;
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
                font.family: "monospace"
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
                Keys.onPressed: function (event) {
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

                    if (event.key === Qt.Key_Escape) {
                        editor.deselect();
                        win.enterEditorNormalMode();
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
                    if (event.text === "?") { win.showHelp = true; win.pendingD = false; return; }
                    if (event.text === "i") { win.enterEditorInsertMode(); return; }
                    if (event.text === "v") { win.enterEditorVisual("visual"); return; }
                    if (event.text === "V") { win.enterEditorVisual("visualLine"); return; }
                    if (event.text === "D") { win.deleteToEndOfLine(); win.pendingD = false; return; }
                    if (event.text === "d") {
                        if (win.pendingD) { win.deleteCurrentLine(); win.pendingD = false; }
                        else win.pendingD = true;
                        return;
                    }
                    if (event.key === Qt.Key_Left || event.text === "h") editor.cursorPosition = Math.max(0, editor.cursorPosition - 1);
                    else if (event.key === Qt.Key_Right || event.text === "l") editor.cursorPosition = Math.min(editor.text.length, editor.cursorPosition + 1);
                    else if (event.key === Qt.Key_Down || event.text === "j") { const r = editor.cursorRectangle; editor.cursorPosition = editor.positionAt(r.x, r.y + r.height * 1.5); }
                    else if (event.key === Qt.Key_Up || event.text === "k") { const r = editor.cursorRectangle; editor.cursorPosition = editor.positionAt(r.x, r.y - r.height * 0.5); }
                    win.pendingD = false; // any key other than the first "d" cancels a pending dd
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
                        font.family: "monospace"
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

                            let handled = true;
                            if (event.key === Qt.Key_Escape) {
                                win.exitVisualMode();
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
                            if (win.editorMode === "insert")
                                return "esc vim mode · ctrl+s save · ? help";
                            const label = win.editorMode === "visualLine" ? "VISUAL LINE"
                                : win.editorMode === "visual" ? "VISUAL" : "NORMAL";
                            return "-- " + label + " --" + (win.pendingD ? "  d" : "") + "   ?  help";
                        }
                        if (win.previewSelMode !== "none")
                            return "h/j/k/l move · y/ctrl+c/super+c yank · esc cancel selection";
                        return "j/k/↑/↓ move · / search · v/V visual select · enter restore · esc back";
                    }
                }
                Text {
                    color: backend.themeAccent
                    font.pixelSize: 12
                    text: win.mode === "edit" ? backend.status : ""
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
                    font.family: "monospace"
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
                    text: "select + ctrl+c/super+c to copy · esc/enter dismiss · also logged to " + backend.logPath
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
                        model: [
                            { title: "General", items: [
                                { key: "Ctrl+S", desc: "Save + commit immediately (forces a sync too)" },
                                { key: "Ctrl+R", desc: "Open history (time machine)" },
                                { key: "Alt+D", desc: "Insert today's date" },
                                { key: "Alt+T", desc: "Insert date + time" },
                                { key: "Ctrl+1..9", desc: "Jump to the Nth heading" },
                                { key: "Ctrl+T", desc: "Switch topic" },
                                { key: "Ctrl+Shift+T", desc: "Create a new topic" },
                                { key: "Esc", desc: "Enter vim Normal mode" }
                            ]},
                            { title: "Normal mode", items: [
                                { key: "i", desc: "Back to Insert mode (resume typing)" },
                                { key: "h j k l", desc: "Move the cursor (arrows too)" },
                                { key: "v", desc: "Visual mode (character)" },
                                { key: "V", desc: "Visual line mode" },
                                { key: "dd", desc: "Delete the line (copied to clipboard)" },
                                { key: "D", desc: "Delete to end of line (copied to clipboard)" },
                                { key: "?", desc: "Toggle this help" }
                            ]},
                            { title: "Visual mode", items: [
                                { key: "h j k l", desc: "Extend the selection" },
                                { key: "y", desc: "Yank selection to clipboard" },
                                { key: "d / x", desc: "Delete selection (copied to clipboard)" },
                                { key: "Esc", desc: "Cancel, back to Normal mode" }
                            ]}
                        ]
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
                                        text: modelData.key
                                        color: backend.themeForeground
                                        font.family: "monospace"
                                        font.bold: true
                                        width: 90
                                    }
                                    Text {
                                        text: modelData.desc
                                        color: backend.themeMuted
                                        width: parent.width - 102
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
                    visible: win.topicSwitchError !== ""
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

        Shortcut { sequence: "Escape"; enabled: win.showTopicSwitcher; onActivated: win.closeTopicSwitcher() }
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
                    text: "Starts as its own blank note, branched off — switch back any time with Ctrl+T."
                    color: backend.themeMuted
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }

                TextField {
                    id: topicNameField
                    Layout.fillWidth: true
                    placeholderText: "Topic name…"
                    color: backend.themeForeground
                    placeholderTextColor: backend.themeMuted
                    background: Rectangle { color: backend.themeSelection }
                    Keys.onReturnPressed: win.confirmTopicCreate()
                    Keys.onEnterPressed: win.confirmTopicCreate()
                }

                Text {
                    visible: win.topicCreateError !== ""
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

        Shortcut { sequence: "Escape"; enabled: win.showTopicCreator; onActivated: win.closeTopicCreator() }
    }
}
