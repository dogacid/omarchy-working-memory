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
    title: "Working memory"
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

    // Global shortcuts. Ctrl+E (drop to a real editor for selection) is
    // gone entirely now that the editor is a native QQuickTextArea with
    // real shift-arrow/word/mouse selection built in.
    Shortcut { sequence: "Ctrl+S"; enabled: win.mode === "edit"; onActivated: backend.save() }
    Shortcut { sequence: "Ctrl+R"; onActivated: win.mode === "edit" ? win.openHistory() : win.backToEdit() }
    Shortcut { sequence: "Alt+D"; enabled: win.mode === "edit"; onActivated: win.insertDate() }
    Shortcut { sequence: "Alt+T"; enabled: win.mode === "edit"; onActivated: win.insertDateTime() }
    // Disabled while visual-selecting: Esc there means "cancel the
    // selection" (handled in previewArea's own Keys.onPressed below), not
    // "leave history" — a second Esc after that falls through to this one.
    Shortcut { sequence: "Escape"; enabled: win.mode !== "edit" && win.previewSelMode === "none"; onActivated: win.backToEdit() }

    Connections {
        target: backend
        function onTextReloaded(text) {
            editor.text = text;
            editor.cursorPosition = text.length;
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
                        if (win.mode === "edit")
                            return "ctrl+r history · ctrl+s save · alt+d date · alt+t date+time · select text + ctrl+c/super+c to copy";
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
}
