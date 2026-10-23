import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami
import "../code/glyphs.js" as Glyphs

// Play / pause button, hand-drawn to match SkipButton (style set in Look & Feel)
PC3.ToolButton {
    id: btn

    property bool playing: false
    property real size: 24
    property color glyphColor: "white"
    property string style: Plasmoid.configuration.buttonStyle || "classic"
    // for the capsule style: "left", "middle", "right" or "single"
    property string segment: "single"
    readonly property string kind: playing ? "pause" : "play"

    Layout.preferredWidth: size
    Layout.preferredHeight: size

    contentItem: Item {
        implicitWidth: btn.size
        implicitHeight: btn.size
        opacity: btn.enabled ? 1.0 : 0.35

        Kirigami.Icon {
            anchors.centerIn: parent
            width: btn.size * 0.7
            height: width
            visible: btn.style === "icons"
            source: Glyphs.iconName(btn.kind)
            color: btn.glyphColor
            isMask: true
        }
        // covers the whole button, padding included, so discs aren't clipped at the
        // edges and capsule segments meet their neighbours
        Canvas {
            id: glyph
            x: -btn.leftPadding
            y: -btn.topPadding
            width: btn.width
            height: btn.height
            visible: btn.style !== "icons"
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: Glyphs.draw(getContext("2d"), btn.kind, btn.style, width, height, btn.size,
                                 btn.glyphColor, btn.segment)
            Connections {
                target: btn
                function onKindChanged() { glyph.requestPaint(); }
                function onStyleChanged() { glyph.requestPaint(); }
                function onGlyphColorChanged() { glyph.requestPaint(); }
                function onSizeChanged() { glyph.requestPaint(); }
                function onSegmentChanged() { glyph.requestPaint(); }
            }
        }
    }
}
