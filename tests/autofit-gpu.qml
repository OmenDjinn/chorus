import QtQuick
import QtQuick.Window
import "../package/contents/ui" as Chorus

// Auto-fit test with main.qml's sizeFor() rules and the real PanelText.
Window {
    id: win
    width: 760; height: 330; visible: true; visibility: Window.FullScreen
    title: "chorus pixel test"
    color: "#15161a"
    readonly property real maxW: Math.round(2560 * 0.12)
    readonly property real base: Math.round(44 * 0.46 * 0.78)
    FontLoader { id: micro; source: Qt.resolvedUrl("../package/contents/fonts/Micro5-Regular.ttf") }
    readonly property var info: ({ grid: 11, looks: 0.8 })
    function pixelFactor(px) { return Math.max(1, Math.round(px / (info.grid * info.looks))); }
    function sizeFor(b, pixel, metrics) {
        var w = metrics.advanceWidth + 2;
        if (pixel) {
            var k = Math.max(1, Math.min(pixelFactor(b), Math.floor(maxW / w)));
            return { px: info.grid * k, factor: k };
        }
        var px = b;
        if (w > maxW) px = Math.max(Math.round(b * 0.5), Math.floor(b * maxW / w));
        return { px: px, factor: 1 };
    }
    Column {
        x: 10; y: 10; spacing: 8
        Repeater {
            model: [
                { t: "Judas", pixel: false }, { t: "Cheap Thrills (feat. Sean Paul)", pixel: false },
                { t: "One Day (feat. Helena) - Radio Edit Extended Remix Version", pixel: false },
                { t: "Judas", pixel: true }, { t: "Cheap Thrills (feat. Sean Paul)", pixel: true },
                { t: "One Day (feat. Helena) - Radio Edit Extended Remix Version", pixel: true }
            ]
            Row {
                spacing: 10
                Text { width: 120; text: (modelData.pixel ? "pixel " : "normal ") + "fit"; color: "#888"; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
                // the box the song name gets on the panel
                Rectangle {
                    width: win.maxW; height: 36; color: "#24262d"; border.color: "#c0504d"; border.width: 1
                    Chorus.PanelText {
                        id: line
                        readonly property var fit: win.sizeFor(win.base, modelData.pixel, m)
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, win.maxW)
                        text: modelData.t; color: "white"; elide: Text.ElideRight
                        family: modelData.pixel ? micro.name : "Noto Sans"
                        weight: modelData.pixel ? Font.Normal : Font.Bold
                        pixel: modelData.pixel; pixelSize: fit.px; factor: fit.factor
                        TextMetrics { id: m; text: modelData.t; font.family: line.family; font.weight: line.weight; font.pixelSize: modelData.pixel ? 11 : win.base }
                    }
                }
                Text { text: line.fit.px + "px"; color: "#888"; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
            }
        }
    }
    Timer { interval: 4500; running: true; onTriggered: Qt.quit() }
}
