import QtQuick

// Text that can draw in the "Pixel" style: the pixel font is laid out at its native grid
// size without antialiasing, then magnified by a whole number with no smoothing, so every
// font pixel becomes a crisp square block. With pixel off it is an ordinary Text.
Item {
    id: pt

    property string text: ""
    property int textFormat: Text.PlainText
    property color color: "white"
    property string family: ""
    property real pixelSize: 12
    property int weight: Font.Normal
    property bool italic: false
    property int elide: Text.ElideNone
    property int maximumLineCount: 1
    property bool pixel: false
    // whole-number magnification; pixelSize is the size after magnifying
    property int factor: 1

    implicitWidth: label.implicitWidth * factor
    implicitHeight: label.implicitHeight * factor

    Text {
        id: label
        // eliding needs a width; otherwise the text keeps its natural width
        width: pt.elide !== Text.ElideNone ? Math.max(0, pt.width / pt.factor) : implicitWidth
        text: pt.text
        textFormat: pt.textFormat
        color: pt.color
        elide: pt.elide
        maximumLineCount: pt.maximumLineCount
        font.family: pt.family
        font.pixelSize: Math.max(1, pt.pixelSize / pt.factor)
        font.weight: pt.weight
        font.italic: pt.italic
        // antialiasing turns pixel edges grey, and only native rendering can switch it off
        antialiasing: !pt.pixel
        Binding on renderType {
            when: pt.pixel
            value: Text.NativeRendering
        }
        font.hintingPreference: pt.pixel ? Font.PreferNoHinting : Font.PreferDefaultHinting
        transformOrigin: Item.TopLeft
        scale: pt.factor
        layer.enabled: pt.factor > 1
        layer.smooth: false
    }
}
