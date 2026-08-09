import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

ColumnLayout {
    id: page

    // Plasma binds `cfg_<entry>` to the entry of the same name in main.xml.
    property alias cfg_curlCommand: curlField.text

    spacing: Kirigami.Units.largeSpacing

    Kirigami.InlineMessage {
        Layout.fillWidth: true
        visible: true
        type: Kirigami.MessageType.Information
        text: "opencode has no usage API, so the widget replays a request the web console makes."
    }

    QQC2.Label {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: "1.  Open the opencode console, then DevTools → Network.\n" +
              "2.  Refresh until a request to _server appears.\n" +
              "3.  Right-click it → Copy → Copy as cURL (bash).\n" +
              "4.  Paste it below."
    }

    QQC2.ScrollView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumHeight: Kirigami.Units.gridUnit * 10

        QQC2.TextArea {
            id: curlField
            wrapMode: TextEdit.WrapAnywhere
            placeholderText: "curl 'https://opencode.ai/_server?...' -H '...' ..."
            font.family: "monospace"
        }
    }

    RowLayout {
        Layout.fillWidth: true

        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: "Saved to ~/.config/opencode-usage/curl.txt (mode 600). This " +
                  "includes a live session cookie — when it expires, or when " +
                  "opencode redeploys, paste a fresh curl here."
        }

        QQC2.Button {
            text: "Clear"
            icon.name: "edit-clear"
            enabled: curlField.text !== ""
            onClicked: curlField.text = ""
        }
    }
}
