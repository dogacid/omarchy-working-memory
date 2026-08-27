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

    // Global shortcuts. Ctrl+E (drop to a real editor for selection) is
    // gone entirely now that the editor is a native QQuickTextArea with
    // real shift-arrow/word/mouse selection built in.
    Shortcut { sequence: "Ctrl+S"; enabled: win.mode === "edit"; onActivated: backend.save() }
    Shortcut { sequence: "Ctrl+R"; onActivated: win.mode === "edit" ? win.openHistory() : win.backToEdit() }
    Shortcut { sequence: "Escape"; enabled: win.mode !== "edit"; onActivated: win.backToEdit() }

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
                Layout.preferredWidth: 300
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

                    delegate: ItemDelegate {
                        width: historyList.width
                        highlighted: ListView.isCurrentItem
                        onClicked: historyList.currentIndex = index
                        background: Rectangle {
                            color: highlighted ? backend.themeSelection : "transparent"
                        }
                        contentItem: ColumnLayout {
                            spacing: 2
                            Text { text: modelData.time; color: backend.themeForeground; font.bold: true }
                            Text { text: modelData.message; color: backend.themeMuted; elide: Text.ElideRight; Layout.fillWidth: true }
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
                    text: win.mode === "edit"
                        ? "ctrl+r history · ctrl+s save · select text + ctrl+c/super+c to copy"
                        : "type to search · ↑/↓ move · enter restore · esc back to editing"
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
