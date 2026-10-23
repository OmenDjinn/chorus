import QtQuick
import "../package/contents/code/glyphs.js" as Glyphs

// Renders every button style (rows) and glyph (columns) to glyph-sheet.png, then quits.
Rectangle {
    id: sheet
    readonly property var styles: ["classic", "outline", "disc", "capsule", "neon", "pixel", "sketch", "vinyl", "equalizer"]
    readonly property var kinds: ["prev", "play", "pause", "next"]
    readonly property int cell: 56
    width: 110 + kinds.length * cell + 20
    height: styles.length * cell + 10
    color: "#1e1f24"

    Column {
        x: 10; y: 5
        Repeater {
            model: sheet.styles
            Row {
                id: styleRow
                readonly property string style: modelData
                height: sheet.cell
                Text { width: 100; height: sheet.cell; verticalAlignment: Text.AlignVCenter; color: "#bbb"; text: styleRow.style; font.pixelSize: 13 }
                Repeater {
                    model: sheet.kinds
                    Canvas {
                        width: sheet.cell; height: sheet.cell
                        readonly property string seg: modelData === "prev" ? "left" : modelData === "next" ? "right" : "middle"
                        onPaint: Glyphs.draw(getContext("2d"), modelData, styleRow.style, width, height, 46, "#ffffff", seg)
                    }
                }
            }
        }
    }
    Timer {
        interval: 800; running: true
        onTriggered: sheet.grabToImage(function (r) { r.saveToFile("glyph-sheet.png"); Qt.quit(); })
    }
}
