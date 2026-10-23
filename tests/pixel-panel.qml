import QtQuick

// Mock of the panel strip in Pixel style, using main.qml's snapping rules.
Rectangle {
    id: sheet
    readonly property real thick: 44
    readonly property string dir: Qt.resolvedUrl("../package/contents/fonts/")
    readonly property var fonts: [
        { file: "PixelifySans.ttf", grid: 12, looks: 1, weights: true, label: "Pixelify Sans" },
        { file: "PressStart2P-Regular.ttf", grid: 8, looks: 1.25, weights: false, label: "Press Start 2P" },
        { file: "Silkscreen-Regular.ttf", grid: 8, looks: 1, weights: false, label: "Silkscreen" }
    ]
    width: 820; height: fonts.length * (thick + 14) + 10
    color: "#101114"
    Column {
        x: 10; y: 6; spacing: 14
        Repeater {
            model: sheet.fonts
            Rectangle {
                id: strip
                readonly property var info: modelData
                function factor(px) { return Math.max(1, Math.round(px / (info.grid * info.looks))); }
                function snap(px) { return info.grid * factor(px); }
                readonly property int lyricPx: snap(Math.round(sheet.thick * 0.46))
                width: 800; height: sheet.thick; radius: 6; color: "#2a2c33"
                FontLoader { id: fl; source: sheet.dir + strip.info.file }
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 8; spacing: 10
                    Rectangle { width: sheet.thick * 0.8; height: width; radius: 6; color: "#c0504d"; anchors.verticalCenter: parent.verticalCenter }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        Text {
                            readonly property int base: Math.round(strip.lyricPx * 0.78)
                            text: "Danza Kuduro"; color: "white"
                            font.family: fl.name; font.pixelSize: strip.snap(base)
                            font.weight: strip.info.weights ? Font.Bold : Font.Normal
                            layer.enabled: strip.factor(base) > 1; layer.smooth: false
                            layer.textureSize: Qt.size(Math.ceil(width / strip.factor(base)), Math.ceil(height / strip.factor(base)))
                        }
                        Text {
                            readonly property int base: Math.round(strip.lyricPx * 0.66)
                            text: "Don Omar"; color: "#aaa"
                            font.family: fl.name; font.pixelSize: strip.snap(base)
                            layer.enabled: strip.factor(base) > 1; layer.smooth: false
                            layer.textureSize: Qt.size(Math.ceil(width / strip.factor(base)), Math.ceil(height / strip.factor(base)))
                        }
                    }
                    Rectangle { width: 1; height: sheet.thick * 0.55; color: "#555"; anchors.verticalCenter: parent.verticalCenter }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "La la la la la la la ♪"; color: "white"
                        font.family: fl.name; font.pixelSize: strip.lyricPx
                        font.weight: strip.info.weights ? Font.DemiBold : Font.Normal
                        layer.enabled: strip.factor(strip.lyricPx) > 1; layer.smooth: false
                        layer.textureSize: Qt.size(Math.ceil(width / strip.factor(strip.lyricPx)), Math.ceil(height / strip.factor(strip.lyricPx)))
                    }
                    Text { anchors.verticalCenter: parent.verticalCenter; text: strip.info.label + "  (lyrics " + strip.lyricPx + "px)"; color: "#666"; font.pixelSize: 11 }
                }
            }
        }
    }
    Timer { interval: 900; running: true; onTriggered: sheet.grabToImage(function (r) { r.saveToFile("pixel-panel.png"); Qt.quit(); }) }
}
