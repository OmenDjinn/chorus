import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: page
    property bool ready: false

    // text
    property string cfg_fontMode
    property bool cfg_useCustomFont
    property string cfg_systemFont
    property alias cfg_fontPath: fontPathField.text
    property var cfg_fontFallbacks: []
    property double cfg_fontScale
    property int cfg_fontWeight
    property int cfg_lyricsOffsetMs
    property alias cfg_lyricsOffsetX: lyricsXSpin.value
    property alias cfg_lyricsOffsetY: lyricsYSpin.value
    property string cfg_lyricsAnimation
    property string cfg_textStyle
    property string cfg_pixelFont
    property alias cfg_marquee: marqueeCheck.checked
    // cover and title
    property alias cfg_showCover: showCoverCheck.checked
    property alias cfg_coverScale: coverScaleSpin.value
    property alias cfg_coverOffsetX: coverXSpin.value
    property alias cfg_coverOffsetY: coverYSpin.value
    property string cfg_coverShape
    property alias cfg_showTitle: showTitleCheck.checked
    property alias cfg_showTitleArtist: titleArtistCheck.checked
    property alias cfg_titleScale: titleScaleSpin.value
    property alias cfg_artistScale: artistScaleSpin.value
    property alias cfg_titleAutoSize: titleAutoCheck.checked
    property alias cfg_artistAutoSize: artistAutoCheck.checked
    property alias cfg_lyricsWidth: lyricsWidthSpin.value
    // buttons
    property string cfg_buttonStyle
    property alias cfg_buttonScale: buttonScaleSpin.value
    property string cfg_buttonsShown
    // layout and color
    property double cfg_minFrac
    property double cfg_maxFrac
    property alias cfg_showDividers: dividersCheck.checked
    property alias cfg_showButtonDivider: buttonDividerCheck.checked
    property alias cfg_hideWhenIdle: hideIdleCheck.checked
    property string cfg_activeColor
    property alias cfg_showVolumeBar: volumeCheck.checked

    property var fontDialog: null
    property var colorButton: null

    readonly property int fieldWidth: Kirigami.Units.gridUnit * 18
    readonly property bool pixelStyle: cfg_textStyle === "pixel"
    // keep in sync with pixelFonts in main.qml
    readonly property var pixelFonts: ({
        micro5: { file: "Micro5-Regular.ttf", grid: 11 },
        press: { file: "PressStart2P-Regular.ttf", grid: 8 },
        silkscreen: { file: "Silkscreen-Regular.ttf", grid: 8 },
        jacquard: { file: "Jacquard12-Regular.ttf", grid: 21 }
    })
    readonly property string pixelFontKey: pixelFonts[cfg_pixelFont] ? cfg_pixelFont : "micro5"
    readonly property var pixelFontInfo: pixelFonts[pixelFontKey]
    readonly property int maxFallbacks: 5
    property var fontDialogField: null
    property int nextUid: 1

    // same rule as the widget: configs from before fontMode only have useCustomFont
    readonly property string effectiveFontMode:
        ["default", "system", "file"].indexOf(cfg_fontMode) >= 0 ? cfg_fontMode
        : cfg_useCustomFont ? "file" : "default"

    ListModel { id: fallbackModel }

    function loadFallbacks() {
        fallbackModel.clear();
        var stored = page.cfg_fontFallbacks || [];
        for (var i = 0; i < stored.length && i < page.maxFallbacks; i++) {
            var p = String(stored[i] || "").trim();
            if (p !== "") fallbackModel.append({ path: p, uid: page.nextUid++ });
        }
    }
    onCfg_fontFallbacksChanged: if (!page.ready) page.loadFallbacks()

    function rowForUid(uid) {
        for (var i = 0; i < fallbackModel.count; i++)
            if (fallbackModel.get(i).uid === uid) return i;
        return -1;
    }
    function addFallback() {
        if (fallbackModel.count >= page.maxFallbacks) return;
        fallbackModel.append({ path: "", uid: page.nextUid++ });
    }
    function setFallbackPath(uid, path) {
        var i = page.rowForUid(uid);
        if (i < 0) return;
        fallbackModel.setProperty(i, "path", String(path));
        page.syncFallbacks();
    }
    function removeFallback(uid) {
        var i = page.rowForUid(uid);
        if (i < 0) return;
        fallbackModel.remove(i);
        page.syncFallbacks();
    }

    function syncFallbacks() {
        var out = [];
        for (var i = 0; i < fallbackModel.count; i++) {
            var p = String(fallbackModel.get(i).path || "").trim();
            if (p !== "") out.push(p);
        }
        page.cfg_fontFallbacks = out;
    }

    function setFontMode(mode) {
        page.cfg_fontMode = mode;
        page.cfg_useCustomFont = mode === "file";
    }

    // the file dialog is created on first use, it's slow to set up and rarely needed
    function openFontDialog(field) {
        if (fontDialog === null) {
            try {
                fontDialog = Qt.createQmlObject(
                    'import QtQuick.Dialogs; FileDialog { }', page, "fontDialog");
                fontDialog.title = i18n("Choose a font file");
                fontDialog.nameFilters = [i18n("Font files (*.ttf *.otf *.ttc)"),
                                          i18n("All files (*)")];
                fontDialog.accepted.connect(function () {
                    var f = fontDialog.selectedFile.toString();
                    if (page.fontDialogField === null) {
                        fontPathField.text = f;
                    } else {
                        page.fontDialogField.text = f;
                        page.setFallbackPath(page.fontDialogField.uid, f);
                    }
                });
            } catch (e) { return; }
        }
        fontDialogField = field;
        fontDialog.open();
    }

    Component.onCompleted: {
        page.loadFallbacks();

        try {
            colorButton = Qt.createQmlObject(
                'import org.kde.kquickcontrols as KQuickControls; KQuickControls.ColorButton { showAlphaChannel: true }',
                colorSlot, "colorButton");
            colorButton.color = page.cfg_activeColor || "#FFFFFF";
            colorButton.colorChanged.connect(function () {
                if (page.ready) {
                    page.cfg_activeColor = String(colorButton.color);
                    hexField.text = String(colorButton.color);
                }
            });
        } catch (e) { colorButton = null; }

        hexField.text = page.cfg_activeColor || "#FFFFFF";
        Qt.callLater(function () { page.ready = true; });
    }

    // a combo box over fixed option values, stored as strings
    component Choice: QQC2.ComboBox {
        property var values: []
        property string value
        signal picked(string choice)
        currentIndex: Math.max(0, values.indexOf(value))
        onActivated: picked(values[currentIndex])
    }

    component Hint: QQC2.Label {
        font: Kirigami.Theme.smallFont
        opacity: 0.7
        wrapMode: Text.WordWrap
        Layout.maximumWidth: page.fieldWidth
    }

    // pixel offset for something on the panel, negative moves left/up
    component OffsetSpin: QQC2.SpinBox {
        from: -100; to: 100; stepSize: 1
        editable: true
        textFromValue: function (v) { return (v > 0 ? "+" : "") + v + " px"; }
        valueFromText: function (t) { return parseInt(t) || 0; }
    }

    Kirigami.FormLayout {

        // ---- text ----

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Text")
        }
        Choice {
            Kirigami.FormData.label: i18n("Text style:")
            values: ["normal", "pixel"]
            model: [i18n("Normal"), i18n("Pixel (8-bit)")]
            value: page.cfg_textStyle || "normal"
            onPicked: (choice) => page.cfg_textStyle = choice
        }
        Choice {
            Kirigami.FormData.label: i18n("Pixel font:")
            visible: page.pixelStyle
            values: ["micro5", "press", "silkscreen", "jacquard"]
            model: [i18n("Micro 5 (easy to read)"), i18n("Press Start 2P (arcade)"),
                    i18n("Silkscreen (capitals)"), i18n("Jacquard 12 (gothic)")]
            value: page.pixelFontKey
            onPicked: (choice) => page.cfg_pixelFont = choice
        }
        // drawn exactly the way the panel draws it
        PanelText {
            Kirigami.FormData.label: i18n("Preview:")
            visible: page.pixelStyle && pixelPreviewFont.status === FontLoader.Ready
            text: i18n("When the music plays ♪")
            color: Kirigami.Theme.textColor
            family: pixelPreviewFont.name
            pixel: true
            factor: page.pixelFontInfo.grid >= 16 ? 1 : 2
            pixelSize: page.pixelFontInfo.grid * factor
            FontLoader {
                id: pixelPreviewFont
                source: page.pixelStyle ? Qt.resolvedUrl("../fonts/" + page.pixelFontInfo.file) : ""
            }
        }
        Hint {
            visible: page.pixelStyle
            text: i18n("Applies to the lyrics, song and artist on the panel and in the popup. Sizes snap to whole pixels, so the font scale changes in steps.")
        }
        Choice {
            Kirigami.FormData.label: i18n("Font:")
            visible: !page.pixelStyle
            values: ["default", "system", "file"]
            model: [i18n("Default (system theme)"), i18n("Installed font"), i18n("Font file")]
            value: page.effectiveFontMode
            onPicked: (choice) => page.setFontMode(choice)
        }
        // built only while "Installed font" is selected: listing ~700 families takes a moment
        Loader {
            Kirigami.FormData.label: i18n("Installed font:")
            active: page.effectiveFontMode === "system" && !page.pixelStyle
            visible: active
            Layout.preferredWidth: page.fieldWidth
            sourceComponent: ColumnLayout {
                spacing: Kirigami.Units.smallSpacing
                readonly property var families: Qt.fontFamilies()
                readonly property var shown: {
                    var q = search.text.trim().toLowerCase();
                    if (q === "") return families;
                    return families.filter(function (f) { return f.toLowerCase().indexOf(q) >= 0; });
                }
                Kirigami.SearchField {
                    id: search
                    Layout.fillWidth: true
                    placeholderText: i18n("Search %1 fonts…", families.length)
                }
                QQC2.Frame {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 9
                    padding: 1
                    ListView {
                        id: fontList
                        anchors.fill: parent
                        clip: true
                        model: shown
                        // rows use the normal font: loading hundreds of fonts to draw
                        // their own names made scrolling stall
                        delegate: QQC2.ItemDelegate {
                            width: fontList.width
                            text: modelData
                            highlighted: modelData === page.cfg_systemFont
                            onClicked: page.cfg_systemFont = modelData
                        }
                        QQC2.ScrollBar.vertical: QQC2.ScrollBar {}
                        Component.onCompleted: {
                            var i = families.indexOf(page.cfg_systemFont);
                            if (i >= 0) positionViewAtIndex(i, ListView.Center);
                        }
                    }
                }
                QQC2.Label {
                    Layout.fillWidth: true
                    visible: page.cfg_systemFont !== ""
                    text: page.cfg_systemFont + " — " + i18n("When the music plays ♪")
                    elide: Text.ElideRight
                    font.family: page.cfg_systemFont
                    font.weight: page.cfg_fontWeight
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.3
                }
            }
        }
        RowLayout {
            Kirigami.FormData.label: i18n("Font file:")
            visible: page.effectiveFontMode === "file" && !page.pixelStyle
            spacing: Kirigami.Units.smallSpacing
            QQC2.TextField {
                id: fontPathField
                Layout.fillWidth: true
            }
            QQC2.Button {
                icon.name: "document-open"
                QQC2.ToolTip.text: i18n("Browse for a font file")
                QQC2.ToolTip.visible: hovered
                onClicked: page.openFontDialog(null)
            }
            QQC2.Button {
                icon.name: "list-add"
                enabled: fallbackModel.count < page.maxFallbacks
                QQC2.ToolTip.text: i18n("Add a fallback font")
                QQC2.ToolTip.visible: hovered
                onClicked: page.addFallback()
            }
        }

        ColumnLayout {
            Kirigami.FormData.label: i18n("Fallback fonts:")
            visible: page.effectiveFontMode === "file" && !page.pixelStyle && fallbackModel.count > 0
            spacing: Kirigami.Units.smallSpacing
            Repeater {
                model: fallbackModel
                delegate: RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    QQC2.Label {
                        text: i18n("%1.", index + 2)
                        opacity: 0.7
                    }
                    QQC2.TextField {
                        id: fallbackField
                        readonly property int uid: model.uid
                        Layout.fillWidth: true
                        Component.onCompleted: text = model.path
                        onTextEdited: page.setFallbackPath(fallbackField.uid, text)
                    }
                    QQC2.Button {
                        icon.name: "document-open"
                        QQC2.ToolTip.text: i18n("Browse for a font file")
                        QQC2.ToolTip.visible: hovered
                        onClicked: page.openFontDialog(fallbackField)
                    }
                    QQC2.Button {
                        icon.name: "list-remove"
                        QQC2.ToolTip.text: i18n("Remove this fallback font")
                        QQC2.ToolTip.visible: hovered
                        onClicked: {
                            if (page.fontDialogField === fallbackField) page.fontDialogField = null;
                            page.removeFallback(fallbackField.uid);
                        }
                    }
                }
            }
        }

        QQC2.SpinBox {
            id: fontScaleSpin
            Kirigami.FormData.label: i18n("Lyrics font scale (%):")
            from: 50; to: 200; stepSize: 5
            value: 100
            Component.onCompleted: value = Math.round(page.cfg_fontScale ? page.cfg_fontScale * 100 : 100)
        }
        Choice {
            Kirigami.FormData.label: i18n("Font weight:")
            // the pixel fonts come in one weight
            visible: !page.pixelStyle
            values: ["300", "400", "500", "600", "700", "800"]
            model: [i18n("Light"), i18n("Regular"), i18n("Medium"), i18n("Semi-bold"), i18n("Bold"), i18n("Extra bold")]
            value: String(page.cfg_fontWeight || 600)
            onPicked: (choice) => page.cfg_fontWeight = parseInt(choice)
        }
        RowLayout {
            Kirigami.FormData.label: i18n("Lyrics position:")
            spacing: Kirigami.Units.smallSpacing
            QQC2.Label { text: i18n("Horizontal") }
            OffsetSpin { id: lyricsXSpin }
            QQC2.Label { text: i18n("Vertical") }
            OffsetSpin { id: lyricsYSpin }
        }
        QQC2.SpinBox {
            id: lyricsOffsetSpin
            Kirigami.FormData.label: i18n("Lyrics timing (ms):")
            from: -3000; to: 3000; stepSize: 50
            value: 0
            editable: true
            Component.onCompleted: value = page.cfg_lyricsOffsetMs || 0
        }
        Hint {
            text: i18n("Positive values show lines earlier.")
        }
        QQC2.SpinBox {
            id: lyricsWidthSpin
            Kirigami.FormData.label: i18n("Lyrics area width:")
            from: 0; to: 80; stepSize: 1
            editable: true
            textFromValue: function (v) { return v === 0 ? i18n("Automatic") : i18n("%1% of screen", v); }
            valueFromText: function (t) { return parseInt(t) || 0; }
        }
        Hint {
            text: i18n("How wide lyrics may get before they're cut off or scroll. Automatic uses what the max width leaves after the cover, song name and buttons.")
        }
        Choice {
            Kirigami.FormData.label: i18n("Line change:")
            values: ["slide", "fade", "none"]
            model: [i18n("Slide up"), i18n("Fade"), i18n("Instant")]
            value: page.cfg_lyricsAnimation || "slide"
            onPicked: (choice) => page.cfg_lyricsAnimation = choice
        }
        QQC2.CheckBox {
            id: marqueeCheck
            text: i18n("Scroll lines that don't fit")
        }

        // ---- cover and title ----

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Cover")
        }
        QQC2.CheckBox {
            id: showCoverCheck
            Kirigami.FormData.label: i18n("Album cover:")
            text: i18n("Show on the panel")
        }
        QQC2.SpinBox {
            id: coverScaleSpin
            Kirigami.FormData.label: i18n("Size (% of panel):")
            enabled: showCoverCheck.checked
            from: 20; to: 100; stepSize: 5
        }
        RowLayout {
            Kirigami.FormData.label: i18n("Position:")
            enabled: showCoverCheck.checked
            spacing: Kirigami.Units.smallSpacing
            QQC2.Label { text: i18n("Horizontal") }
            OffsetSpin { id: coverXSpin }
            QQC2.Label { text: i18n("Vertical") }
            OffsetSpin { id: coverYSpin }
        }
        Choice {
            Kirigami.FormData.label: i18n("Shape:")
            enabled: showCoverCheck.checked
            values: ["rounded", "square", "circle"]
            model: [i18n("Rounded"), i18n("Square"), i18n("Circle")]
            value: page.cfg_coverShape || "rounded"
            onPicked: (choice) => page.cfg_coverShape = choice
        }
        QQC2.CheckBox {
            id: showTitleCheck
            Kirigami.FormData.label: i18n("Song name:")
            text: i18n("Show next to the cover")
        }
        QQC2.CheckBox {
            id: titleArtistCheck
            enabled: showTitleCheck.checked
            text: i18n("With the artist below it")
        }
        RowLayout {
            Kirigami.FormData.label: i18n("Song name size (%):")
            enabled: showTitleCheck.checked
            spacing: Kirigami.Units.smallSpacing
            QQC2.SpinBox {
                id: titleScaleSpin
                enabled: !titleAutoCheck.checked
                from: 50; to: 200; stepSize: 5
            }
            QQC2.CheckBox {
                id: titleAutoCheck
                text: i18n("Automatic")
            }
        }
        RowLayout {
            Kirigami.FormData.label: i18n("Artist size (%):")
            enabled: showTitleCheck.checked && titleArtistCheck.checked
            spacing: Kirigami.Units.smallSpacing
            QQC2.SpinBox {
                id: artistScaleSpin
                enabled: !artistAutoCheck.checked
                from: 50; to: 200; stepSize: 5
            }
            QQC2.CheckBox {
                id: artistAutoCheck
                text: i18n("Automatic")
            }
        }
        Hint {
            visible: titleAutoCheck.checked || artistAutoCheck.checked
            text: i18n("Automatic uses the normal size and shrinks long names until they fit, down to half size; only longer ones get cut off.")
        }

        // ---- buttons ----

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Buttons")
        }
        RowLayout {
            Kirigami.FormData.label: i18n("Style:")
            spacing: Kirigami.Units.largeSpacing
            Choice {
                id: styleChoice
                values: ["classic", "outline", "disc", "capsule", "neon", "pixel", "sketch", "vinyl", "equalizer", "icons"]
                model: [i18n("Classic"), i18n("Outline"), i18n("Disc"), i18n("Capsule"), i18n("Neon"),
                        i18n("Pixel"), i18n("Sketch"), i18n("Vinyl"), i18n("Equalizer"), i18n("Theme icons")]
                // older configs: "rounded" is now classic, "circle" is disc
                value: page.cfg_buttonStyle === "circle" ? "disc"
                     : values.indexOf(page.cfg_buttonStyle) >= 0 ? page.cfg_buttonStyle : "classic"
                onPicked: (choice) => page.cfg_buttonStyle = choice
            }
            // live preview of the chosen style
            Rectangle {
                Layout.preferredHeight: Kirigami.Units.gridUnit * 2
                Layout.preferredWidth: previewRow.implicitWidth + Kirigami.Units.largeSpacing * 2
                radius: Kirigami.Units.cornerRadius
                color: Qt.rgba(0, 0, 0, 0.55)
                RowLayout {
                    id: previewRow
                    anchors.centerIn: parent
                    spacing: 0
                    SkipButton {
                        forward: false; segment: "left"; size: Kirigami.Units.gridUnit * 1.7
                        style: page.cfg_buttonStyle || "classic"; glyphColor: page.cfg_activeColor || "#FFFFFF"
                    }
                    // click to see the pause state too
                    PlayButton {
                        onClicked: playing = !playing
                        segment: "middle"; size: Kirigami.Units.gridUnit * 1.7
                        style: page.cfg_buttonStyle || "classic"; glyphColor: page.cfg_activeColor || "#FFFFFF"
                    }
                    SkipButton {
                        forward: true; segment: "right"; size: Kirigami.Units.gridUnit * 1.7
                        style: page.cfg_buttonStyle || "classic"; glyphColor: page.cfg_activeColor || "#FFFFFF"
                    }
                }
            }
        }
        Choice {
            Kirigami.FormData.label: i18n("On the panel:")
            values: ["all", "play", "none"]
            model: [i18n("Previous, play/pause and next"), i18n("Play/pause only"), i18n("No buttons")]
            value: page.cfg_buttonsShown || "all"
            onPicked: (choice) => page.cfg_buttonsShown = choice
        }
        QQC2.SpinBox {
            id: buttonScaleSpin
            Kirigami.FormData.label: i18n("Size (% of panel):")
            from: 30; to: 100; stepSize: 5
        }

        // ---- layout ----

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Layout")
        }
        QQC2.SpinBox {
            id: minFracSpin
            Kirigami.FormData.label: i18n("Min width (% of screen):")
            from: 0; to: 80; stepSize: 5
            value: 35
            Component.onCompleted: value = Math.round((page.cfg_minFrac || 0.35) * 100)
        }
        QQC2.SpinBox {
            id: maxFracSpin
            Kirigami.FormData.label: i18n("Max width (% of screen):")
            from: 10; to: 90; stepSize: 5
            value: 50
            Component.onCompleted: value = Math.round((page.cfg_maxFrac || 0.5) * 100)
        }
        QQC2.CheckBox {
            id: dividersCheck
            Kirigami.FormData.label: i18n("Dividers:")
            text: i18n("Between the cover or song name and the lyrics")
        }
        QQC2.CheckBox {
            id: buttonDividerCheck
            text: i18n("Before the buttons")
        }
        QQC2.CheckBox {
            id: hideIdleCheck
            Kirigami.FormData.label: i18n("When nothing is playing:")
            text: i18n("Collapse widget to zero width")
        }

        // ---- color and popup ----

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Color and popup")
        }
        RowLayout {
            Kirigami.FormData.label: i18n("Color:")
            spacing: Kirigami.Units.smallSpacing
            Item {
                id: colorSlot
                visible: page.colorButton !== null
                Layout.preferredWidth: page.colorButton ? page.colorButton.implicitWidth : 0
                Layout.preferredHeight: page.colorButton ? page.colorButton.implicitHeight : 0
            }
            QQC2.TextField {
                id: hexField
                visible: page.colorButton === null
                placeholderText: "#FFFFFF"
                onTextEdited: if (page.ready
                        && /^#([0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(text))
                    page.cfg_activeColor = text
            }
        }
        QQC2.CheckBox {
            id: volumeCheck
            Kirigami.FormData.label: i18n("Volume:")
            text: i18n("Show volume slider in popup")
        }
        Hint {
            text: i18n("Tip: you can also scroll on the panel widget or the album cover in the popup to adjust the volume.")
        }
    }

    Connections {
        target: fontScaleSpin
        function onValueChanged() { if (page.ready) page.cfg_fontScale = fontScaleSpin.value / 100; }
    }
    Connections {
        target: minFracSpin
        function onValueChanged() { if (page.ready) page.cfg_minFrac = minFracSpin.value / 100; }
    }
    Connections {
        target: maxFracSpin
        function onValueChanged() { if (page.ready) page.cfg_maxFrac = maxFracSpin.value / 100; }
    }
    Connections {
        target: lyricsOffsetSpin
        function onValueChanged() { if (page.ready) page.cfg_lyricsOffsetMs = lyricsOffsetSpin.value; }
    }
}
