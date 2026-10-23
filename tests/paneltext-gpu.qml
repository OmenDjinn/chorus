import QtQuick
import QtQuick.Window
import "../package/contents/ui" as Chorus

// The widget's own PanelText, with main.qml's snapping rules, at the user's settings.
Window {
    id: win
    width: 900; height: 300; visible: true
    title: "chorus pixel test"
    color: "#15161a"
    readonly property real thick: 44
    readonly property string dir: Qt.resolvedUrl("../package/contents/fonts/")
    readonly property var fonts: [
        { file: "Micro5-Regular.ttf", grid: 11, looks: 0.8 },
        { file: "PressStart2P-Regular.ttf", grid: 8, looks: 1.25 },
        { file: "Silkscreen-Regular.ttf", grid: 8, looks: 1 },
        { file: "Jacquard12-Regular.ttf", grid: 21, looks: 1 }
    ]
    Column {
        x: 10; y: 10; spacing: 14
        Repeater {
            model: win.fonts
            Rectangle {
                id: strip
                readonly property var info: modelData
                function factor(px) { return Math.max(1, Math.round(px / (info.grid * info.looks))); }
                function snap(px) { return info.grid * factor(px); }
                readonly property int lyricRaw: Math.max(10, Math.round(win.thick * 0.46 * 0.85))
                width: 880; height: win.thick; color: "#24262d"; radius: 6
                FontLoader { id: fl; source: win.dir + strip.info.file }
                Row {
                    x: 8; spacing: 10; anchors.verticalCenter: parent.verticalCenter
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        Chorus.PanelText {
                            readonly property int base: Math.round(win.thick * 0.46 * 0.78 * 0.6)
                            text: "Danza Kuduro"; color: "white"; family: fl.name; pixel: true
                            factor: strip.factor(base); pixelSize: strip.snap(base)
                        }
                        Chorus.PanelText {
                            readonly property int base: Math.round(win.thick * 0.46 * 0.66)
                            text: "Don Omar"; color: "#aaa"; family: fl.name; pixel: true
                            factor: strip.factor(base); pixelSize: strip.snap(base)
                        }
                    }
                    Rectangle { width: 1; height: win.thick * 0.55; color: "#555"; anchors.verticalCenter: parent.verticalCenter }
                    Chorus.PanelText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "When the music plays ♪ La la la"; color: "white"; family: fl.name; pixel: true
                        factor: strip.factor(strip.lyricRaw); pixelSize: strip.snap(strip.lyricRaw)
                    }
                }
            }
        }
    }
    Timer { interval: 4500; running: true; onTriggered: Qt.quit() }
}
