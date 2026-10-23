import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami
import "../code/lrc.js" as Lrc

// Popup playlist picker for Spotify Soloist: the soloist-mpris bridge lists the
// library (org.chorus.Soloist.GetPlaylists) and starts one with PlayUri
ColumnLayout {
    id: box
    spacing: Kirigami.Units.smallSpacing

    property bool open: false
    property bool loading: false
    property var playlists: []

    readonly property string bridge:
        "org.mpris.MediaPlayer2.soloist /org/mpris/MediaPlayer2 org.chorus.Soloist"

    function refresh() {
        if (loading) return;
        loading = true;
        root.runCmdWatch("busctl --user --json=short --timeout=20 call " + bridge + " GetPlaylists",
                         function (out) {
            box.loading = false;
            // on a failed fetch keep the last list; the section hides anyway while Soloist is gone
            try {
                box.playlists = JSON.parse(JSON.parse(out).data[0]);
            } catch (e) {}
        });
    }

    function play(item) {
        if (!/^spotify:[A-Za-z0-9:._-]+$/.test(item.uri || "")) return;
        root.runCmd("busctl --user call " + bridge + " PlayUri s " + item.uri);
        box.open = false;
    }

    function subtitle(item) {
        var parts = [];
        if (item.owner) parts.push(i18n("by %1", item.owner));
        if (item.tracks >= 0) parts.push(i18np("%1 song", "%1 songs", item.tracks));
        return parts.join(" • ");
    }

    // refresh in the background each time the popup opens, the last list stays visible meanwhile
    Connections {
        target: root
        function onExpandedChanged() {
            if (root.expanded) box.refresh();
            else box.open = false;
        }
    }
    Component.onCompleted: refresh()

    // appRunning() re-evaluates as MPRIS players come and go
    visible: playlists.length > 0 && root.appRunning("soloist")

    PC3.ItemDelegate {
        Layout.fillWidth: true
        onClicked: box.open = !box.open
        contentItem: RowLayout {
            spacing: Kirigami.Units.smallSpacing
            Kirigami.Icon {
                source: "view-media-playlist"
                color: root.cActive
                opacity: 0.75
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
            }
            PC3.Label {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: i18n("Playlists")
                color: root.cActive
                font.family: root.cfgFont
            }
            // hand-drawn spinner: the themed BusyIndicator ignores the configured color
            Canvas {
                id: spinner
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                visible: box.loading
                onPaint: {
                    var ctx = getContext("2d");
                    ctx.reset();
                    ctx.strokeStyle = root.cActive;
                    ctx.lineWidth = Math.max(2, width * 0.11);
                    ctx.lineCap = "round";
                    var r = (Math.min(width, height) - ctx.lineWidth) / 2;
                    ctx.beginPath();
                    ctx.arc(width / 2, height / 2, r, 0, Math.PI * 1.5);
                    ctx.stroke();
                }
                Connections {
                    target: root
                    function onCActiveChanged() { spinner.requestPaint(); }
                }
                RotationAnimator on rotation {
                    from: 0; to: 360
                    duration: 900
                    loops: Animation.Infinite
                    running: spinner.visible
                }
            }
            Kirigami.Icon {
                source: box.open ? "arrow-up" : "arrow-down"
                color: root.cActive
                opacity: 0.6
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
            }
        }
    }

    ListView {
        id: list
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(count, 5) * (Kirigami.Units.gridUnit * 2.4)
        visible: box.open && count > 0
        clip: true
        model: box.playlists
        PC3.ScrollBar.vertical: PC3.ScrollBar {}
        delegate: PC3.ItemDelegate {
            width: list.width
            height: Kirigami.Units.gridUnit * 2.4
            contentItem: RowLayout {
                spacing: Kirigami.Units.smallSpacing * 2
                Item {
                    readonly property bool liked: modelData.liked === true
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 1.8
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 1.8
                    CoverImage {
                        id: thumb
                        anchors.fill: parent
                        src: modelData.image || ""
                        px: 96
                        radius: 4
                        visible: modelData.image !== "" && !thumb.failed
                    }
                    Kirigami.Icon {
                        anchors.fill: parent
                        anchors.margins: parent.width * 0.12
                        source: parent.liked ? "emblem-favorite" : "view-media-playlist"
                        color: root.cActive
                        opacity: 0.5
                        visible: !thumb.visible
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    PC3.Label {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        text: Lrc.normalize(modelData.name)
                        color: root.cActive
                        font.family: root.cfgFont
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }
                    PC3.Label {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        text: box.subtitle(modelData)
                        visible: text !== ""
                        color: root.cActive
                        opacity: 0.6
                        font.family: root.cfgFont
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }
                }
            }
            onClicked: box.play(modelData)
        }
    }
}
