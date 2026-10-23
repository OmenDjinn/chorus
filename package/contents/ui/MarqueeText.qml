import QtQuick
import "../code/lrc.js" as Lrc

Item {
    id: root

    property string text: ""
    property string fontCss: ""
    property string family: ""
    property real pixelSize: 12
    property int weight: Font.Normal
    property bool italic: false
    property color color: "white"
    property real textOpacity: 1.0
    property bool scrolling: true
    // the "Pixel" text style (see PanelText): pixel font, whole-number magnification
    property bool pixel: false
    property int pixelFactor: 1

    implicitHeight: label.implicitHeight
    clip: true

    readonly property bool overflows: label.implicitWidth > width + 1

    PanelText {
        id: label
        textFormat: root.fontCss !== "" ? Text.RichText : Text.PlainText
        // whole pixels, so magnified pixel text isn't resampled between them
        y: Math.round((root.height - height) / 2)
        text: Lrc.fontSpan(root.text, root.fontCss)
        color: root.color
        family: root.family
        pixelSize: root.pixelSize
        weight: root.weight
        italic: root.italic
        pixel: root.pixel
        factor: root.pixelFactor
        opacity: root.textOpacity
        x: root.overflows ? 0 : Math.round((root.width - implicitWidth) / 2)
    }

    SequentialAnimation {
        id: anim
        loops: Animation.Infinite
        PauseAnimation { duration: 2000 }
        NumberAnimation {
            target: label; property: "x"
            to: Math.min(0, root.width - label.implicitWidth)
            duration: Math.max(1000, (label.implicitWidth - root.width) * 35)
        }
        PauseAnimation { duration: 2000 }
        NumberAnimation { target: label; property: "x"; to: 0; duration: 600 }
    }

    function restart() {
        anim.stop();
        if (overflows && scrolling && visible) {
            label.x = 0;
            anim.start();
        } else {
            label.x = Qt.binding(function () {
                return root.overflows ? 0 : Math.round((root.width - label.implicitWidth) / 2);
            });
        }
    }

    onTextChanged: restart()
    onWidthChanged: restart()
    onOverflowsChanged: restart()
    onVisibleChanged: restart()
    onScrollingChanged: restart()
    Component.onCompleted: restart()
}
