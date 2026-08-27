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

    // "edit" | "history" | "historyView" — the error overlay is independent
    // of this and just layers on top whenever backend.lastError is set.
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
        historyList.forceActiveFocus();
    }

    function filterHistory(query) {
        if (!query) {
            filteredHistory = historyEntries;
            return;
        }
        const q = query.toLowerCase();
        filteredHistory = historyEntries.filter(function (e) {
            return e.message.toLowerCase().indexOf(q) !== -1;
        });
    }

    function openHistoryEntry(entry) {
        selectedEntry = entry;
        historyContent = backend.showAt(entry.hash);
        mode = "historyView";
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
    Shortcut { sequence: "Escape"; enabled: win.mode !== "edit"; onActivated: {
        if (win.mode === "historyView") { win.mode = "history"; historyList.forceActiveFocus(); }
        else win.backToEdit();
    }}

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

        // --- History list ---------------------------------------------
        ColumnLayout {
            visible: win.mode === "history"
            Layout.fillWidth: true
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
                currentIndex: count > 0 ? 0 : -1

                delegate: ItemDelegate {
                    width: historyList.width
                    highlighted: ListView.isCurrentItem
                    onClicked: { historyList.currentIndex = index; win.openHistoryEntry(modelData); }
                    background: Rectangle {
                        color: highlighted ? backend.themeSelection : "transparent"
                    }
                    contentItem: ColumnLayout {
                        spacing: 2
                        Text { text: modelData.time; color: backend.themeForeground; font.bold: true }
                        Text { text: modelData.message; color: backend.themeMuted; elide: Text.ElideRight; Layout.fillWidth: true }
                    }
                }

                Keys.onReturnPressed: if (currentItem) win.openHistoryEntry(filteredHistory[currentIndex])
                Keys.onEnterPressed: if (currentItem) win.openHistoryEntry(filteredHistory[currentIndex])
            }
        }

        // --- History preview (read-only) -------------------------------
        ScrollView {
            visible: win.mode === "historyView"
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
                background: null
                topPadding: 12
                leftPadding: 16
                rightPadding: 16
                bottomPadding: 12

                Keys.onPressed: function (event) {
                    if (event.key === Qt.Key_R && win.selectedEntry) {
                        backend.restoreAt(win.selectedEntry.hash, win.selectedEntry.isoTime);
                        win.backToEdit();
                        event.accepted = true;
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
                            return "ctrl+r history · ctrl+s save · select text + ctrl+c/super+c to copy";
                        if (win.mode === "history")
                            return "↑/↓ move · enter view · esc back";
                        return "r restore to present · esc back · ctrl+r editing";
                    }
                }
                Text {
                    color: backend.themeAccent
                    font.pixelSize: 12
                    text: win.mode === "edit" ? backend.status
                        : (win.mode === "historyView" && win.selectedEntry ? win.selectedEntry.time : "")
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
