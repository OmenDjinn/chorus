import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.plasma.plasma5support as P5Support

KCM.SimpleKCM {
    id: page

    property string cfg_appMode
    property string cfg_searchMode
    property alias cfg_playerMatch: matchField.text
    property alias cfg_preferSongs: preferSongsCheck.checked
    property alias cfg_apiUrl: apiUrlField.text
    property alias cfg_extraQueue: extraQueueSpin.value
    property alias cfg_launchCmd: launchField.text
    property alias cfg_closeCmd: closeField.text
    property bool cfg_pearHideAppButton: false
    property alias cfg_spotifyClientId: spotifyIdField.text
    property alias cfg_spotifyClientSecret: spotifySecretField.text
    property alias cfg_spotifyLaunchCmd: spotifyLaunchField.text
    property alias cfg_spotifyCloseCmd: spotifyCloseField.text
    property bool cfg_spotifyHideAppButton: false
    property string legacyAppMode: ""

    readonly property var appModes: ["universal", "custom", "soloist"]
    readonly property var searchModes: ["none", "auto", "pear", "spotify"]
    readonly property bool soloistMode: appModeCombo.currentIndex === 2
    readonly property bool autoSearch: searchCombo.currentIndex === 1
    readonly property bool pearSearch: searchCombo.currentIndex === 2
    readonly property bool spotifySearch: searchCombo.currentIndex === 3
    readonly property bool showPear: pearSearch || autoSearch
    // Soloist mode needs the client ID too, for the playlist list
    readonly property bool showSpotify: spotifySearch || autoSearch || soloistMode
    readonly property int fieldWidth: Kirigami.Units.gridUnit * 22

    // ---- Spotify Soloist setup (runs code/soloist/soloist-setup.sh) ----------------

    readonly property string script: "'" + Qt.resolvedUrl("../code/soloist/soloist-setup.sh")
        .toString().replace(/^file:\/\//, "") + "'"

    property var st: null
    property string savedKey: ""
    property string busy: ""
    property string result: ""
    property bool resultIsError: false

    readonly property bool installed: st !== null && st.installed
    readonly property bool hasKey: st !== null && st.key
    readonly property bool running: st !== null && st.running
    readonly property bool paired: st !== null && st.bridge.logged_in
    readonly property bool signedIn: st !== null && st.webapi

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        property var callbacks: ({})
        onNewData: function (sourceName, data) {
            disconnectSource(sourceName);
            var cb = callbacks[sourceName];
            if (cb) {
                delete callbacks[sourceName];
                cb(data["stdout"] || "");
            }
        }
        function run(cmd, cb) {
            callbacks[cmd] = cb;
            connectSource(cmd);
        }
    }

    function refresh() {
        exec.run(script + " status", function (out) {
            try { page.st = JSON.parse(out); } catch (e) {}
        });
    }

    function loadKey() {
        exec.run(script + " get-key", function (out) {
            var key = out.trim();
            // don't overwrite something the user is in the middle of typing
            if (keyField.text.trim() === "" || keyField.text.trim() === page.savedKey)
                keyField.text = key;
            page.savedKey = key;
        });
    }

    // runs a setup command; onDone(ok) is called once it has finished
    function action(name, args, label, onDone) {
        if (busy !== "") return;
        busy = label;
        result = "";
        exec.run(script + " " + name + (args ? " " + args : ""), function (out) {
            var lines = out.trim().split("\n");
            var last = lines[lines.length - 1] || "";
            var ok = last.indexOf("done:") === 0;
            page.resultIsError = !ok;
            page.result = last.replace(/^(done|error): */, "");
            page.busy = "";
            page.refresh();
            if (onDone) onDone(ok);
        });
    }

    function saveKey() {
        var key = keyField.text.trim();
        if (!/^[A-Za-z0-9._~+\/=-]+$/.test(key)) {
            resultIsError = true;
            result = i18n("That doesn't look like an API key");
            return;
        }
        action("set-key", "'" + key + "'", i18n("Saving key…"), function (ok) {
            if (ok) page.savedKey = key;
        });
    }

    function signIn() {
        // use the client ID as typed, so signing in works before the settings are applied
        var id = spotifyIdField.text.trim();
        if (!/^[0-9a-f]{32}$/.test(id)) {
            resultIsError = true;
            result = i18n("Enter your Spotify app's client ID below first");
            return;
        }
        action("sign-in", id, i18n("Waiting for you to sign in in the browser…"));
    }

    onSoloistModeChanged: if (soloistMode) { refresh(); loadKey(); }
    Timer {
        interval: 2000
        repeat: true
        running: page.visible && page.soloistMode
        onTriggered: page.refresh()
    }

    component StatusRow: RowLayout {
        property bool ok: false
        property string text: ""
        spacing: Kirigami.Units.smallSpacing
        Kirigami.Icon {
            source: parent.ok ? "dialog-ok-apply" : "dialog-information"
            opacity: parent.ok ? 1 : 0.5
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
        }
        QQC2.Label {
            text: parent.text
            wrapMode: Text.WordWrap
            Layout.maximumWidth: page.fieldWidth
        }
    }

    component Hint: QQC2.Label {
        font: Kirigami.Theme.smallFont
        opacity: 0.7
        wrapMode: Text.WordWrap
        Layout.maximumWidth: page.fieldWidth
    }

    Kirigami.FormLayout {

        QQC2.ComboBox {
            id: appModeCombo
            Kirigami.FormData.label: i18n("Music app:")
            model: [
                i18n("All media players"),
                i18n("Only specific apps"),
                i18n("Spotify Soloist")
            ]
            onActivated: page.cfg_appMode = page.appModes[currentIndex]
            Component.onCompleted: {
                page.legacyAppMode = page.cfg_appMode;
                var i = page.appModes.indexOf(page.cfg_appMode);
                if (i < 0) { i = 0; page.cfg_appMode = page.appModes[0]; }
                currentIndex = i;
            }
        }
        QQC2.TextField {
            id: matchField
            Kirigami.FormData.label: i18n("App name or class:")
            visible: appModeCombo.currentIndex === 1
            placeholderText: i18n("e.g. spotify, org.kde.elisa. Separate several with commas")
            Layout.maximumWidth: page.fieldWidth
        }
        Hint {
            visible: page.soloistMode
            text: i18n("Spotify's own lightweight player: plays on this computer without the Spotify app, shows up as a speaker in Spotify Connect, and adds your playlists to the popup. The widget then follows only Soloist. Requires Spotify Premium.")
        }

        // ---- Spotify Soloist ----

        StatusRow {
            visible: page.soloistMode
            Kirigami.FormData.label: i18n("Status:")
            ok: page.installed
            text: page.st === null ? i18n("Checking…")
                : page.installed ? i18n("Installed (version %1, updates itself weekly)", page.st.version)
                : i18n("Not installed")
        }
        Hint {
            // builds expire after 90 days and the weekly update normally replaces them long before
            visible: page.soloistMode && page.installed && page.st.days_left >= 0 && page.st.days_left < 14
            color: Kirigami.Theme.negativeTextColor
            opacity: 1
            text: i18np("This Soloist build stops working in %1 day and hasn't updated itself. Click Update below.",
                        "This Soloist build stops working in %1 days and hasn't updated itself. Click Update below.",
                        page.installed ? page.st.days_left : 0)
        }
        StatusRow {
            visible: page.soloistMode && page.installed
            ok: page.hasKey
            text: page.hasKey ? i18n("API key saved") : i18n("API key missing")
        }
        StatusRow {
            visible: page.soloistMode && page.installed && page.hasKey
            ok: page.running && page.paired
            text: !page.running ? i18n("Player not running")
                : page.paired ? i18n("Playing as \"%1\"", page.st.device)
                : i18n("Waiting to be paired")
        }
        Hint {
            // e.g. a rejected API key; the player's last log line says why it stopped
            visible: page.soloistMode && page.installed && page.hasKey && !page.running && page.st.log !== ""
            text: i18n("Last message: %1", page.installed ? page.st.log : "")
        }
        StatusRow {
            visible: page.soloistMode && page.installed
            ok: page.signedIn
            text: page.signedIn ? i18n("Signed in for playlists") : i18n("Not signed in for playlists")
        }
        Hint {
            visible: page.soloistMode && page.st !== null && page.st.missing !== ""
            color: Kirigami.Theme.negativeTextColor
            opacity: 1
            text: i18n("Missing: %1. Install them with: sudo pacman -S --needed %1", page.st ? page.st.missing.trim() : "")
        }
        QQC2.Button {
            visible: page.soloistMode
            text: page.installed ? i18n("Update Spotify Soloist") : i18n("Get Spotify Soloist")
            icon.name: page.installed ? "view-refresh" : "download"
            enabled: page.busy === "" && page.st !== null && page.st.missing === ""
            onClicked: page.action("install", "", i18n("Downloading and installing…"))
        }

        RowLayout {
            visible: page.soloistMode && page.installed
            Kirigami.FormData.label: i18n("Soloist API key:")
            Layout.maximumWidth: page.fieldWidth
            // hidden by default, the eye button in the field shows the saved key
            Kirigami.PasswordField {
                id: keyField
                Layout.fillWidth: true
                placeholderText: i18n("Paste your key here")
                onAccepted: page.saveKey()
            }
            QQC2.Button {
                text: i18n("Save")
                icon.name: "document-save"
                enabled: keyField.text.trim() !== "" && keyField.text.trim() !== page.savedKey
                         && page.busy === ""
                onClicked: page.saveKey()
            }
        }
        RowLayout {
            visible: page.soloistMode && page.installed
            spacing: Kirigami.Units.smallSpacing
            QQC2.Button {
                text: i18n("Get a key")
                icon.name: "internet-services"
                onClicked: Qt.openUrlExternally("https://developer.spotify.com/dashboard/soloist")
            }
            Hint {
                Layout.fillWidth: true
                text: i18n("Accept the terms there and generate a key, then paste it above.")
            }
        }
        Hint {
            visible: page.soloistMode && page.installed && page.hasKey && page.running && !page.paired
            Kirigami.FormData.label: i18n("Pairing:")
            opacity: 1
            text: i18n("Open the Spotify app on this computer or your phone, open the devices menu and pick \"%1\". This is needed only once. The web player can't pair new devices.", page.st ? page.st.device : "")
        }
        RowLayout {
            visible: page.soloistMode && page.installed
            Kirigami.FormData.label: i18n("Playlists:")
            spacing: Kirigami.Units.smallSpacing
            QQC2.Button {
                text: page.signedIn ? i18n("Sign in again") : i18n("Sign in with Spotify")
                icon.name: "im-user"
                enabled: page.busy === ""
                onClicked: page.signIn()
            }
            Hint {
                Layout.fillWidth: true
                text: i18n("Uses the Spotify app below. Add http://127.0.0.1:8989/login as a redirect URI in its settings on developer.spotify.com.")
            }
        }
        QQC2.BusyIndicator {
            visible: page.soloistMode && page.busy !== ""
            running: visible
            Kirigami.FormData.label: page.busy
        }
        Hint {
            visible: page.soloistMode && page.busy === "" && page.result !== ""
            opacity: 1
            color: page.resultIsError ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.positiveTextColor
            text: page.result.charAt(0).toUpperCase() + page.result.slice(1)
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.ComboBox {
            id: searchCombo
            Kirigami.FormData.label: i18n("Search bar:")
            model: [
                i18n("None"),
                i18n("Automatic (follow what's playing)"),
                i18n("Pear Desktop (YouTube Music)"),
                i18n("Spotify (requires Premium)")
            ]
            onActivated: page.cfg_searchMode = page.searchModes[currentIndex]
            Component.onCompleted: {
                var m = page.cfg_searchMode;
                if (page.searchModes.indexOf(m) < 0) {
                    m = (page.legacyAppMode === "pear" || page.legacyAppMode === "spotify")
                        ? page.legacyAppMode : "none";
                    page.cfg_searchMode = m;
                }
                currentIndex = Math.max(0, page.searchModes.indexOf(m));
            }
        }
        QQC2.Label {
            visible: page.autoSearch
            text: i18n("Uses Spotify or YouTube Music search while that app is playing; players without a search API (Elisa, VLC...) get no search bar.")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
            Layout.maximumWidth: page.fieldWidth
        }
        Hint {
            visible: page.soloistMode && !page.spotifySearch && !page.autoSearch
            text: i18n("Choose Spotify to search and play songs on Soloist from the popup.")
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Spotify")
            visible: page.showSpotify
        }
        QQC2.TextField {
            id: spotifyIdField
            visible: page.showSpotify
            Kirigami.FormData.label: i18n("Client ID:")
            Layout.maximumWidth: page.fieldWidth
        }
        QQC2.TextField {
            id: spotifySecretField
            visible: page.showSpotify
            Kirigami.FormData.label: i18n("Client secret:")
            echoMode: TextInput.Password
            Layout.maximumWidth: page.fieldWidth
        }
        QQC2.Label {
            visible: page.showSpotify
            text: spotifyIdField.text.trim() !== "" && spotifySecretField.text.trim() !== ""
                  ? (page.soloistMode ? i18n("Used for search and for listing your playlists.")
                                      : i18n("Results show in the widget and play in the Spotify app."))
                  : page.soloistMode
                  ? i18n("Create an app at developer.spotify.com and paste its client ID here to list your playlists, and its secret too for search.")
                  : i18n("Required for search: create an app at developer.spotify.com and paste its client ID and secret here (Spotify requires Premium for Web API access).")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
            Layout.maximumWidth: page.fieldWidth
        }
        QQC2.CheckBox {
            id: spotifyHideBtnCheck
            visible: page.spotifySearch
            Kirigami.FormData.label: i18n("Start/Stop button:")
            text: i18n("Hidden in popup")
            checked: page.cfg_spotifyHideAppButton
            onToggled: page.cfg_spotifyHideAppButton = checked
        }
        // Soloist mode starts and stops the Soloist service itself
        QQC2.TextField {
            id: spotifyLaunchField
            visible: page.showSpotify && !page.soloistMode
            Kirigami.FormData.label: i18n("Start command:")
            placeholderText: "gtk-launch com.spotify.Client"
            Layout.maximumWidth: page.fieldWidth
        }
        QQC2.TextField {
            id: spotifyCloseField
            visible: page.showSpotify && !page.soloistMode
            Kirigami.FormData.label: i18n("Close command:")
            placeholderText: "pkill -9 -f spotify"
            Layout.maximumWidth: page.fieldWidth
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Pear Desktop")
            visible: page.showPear
        }
        QQC2.CheckBox {
            id: preferSongsCheck
            visible: page.showPear
            Kirigami.FormData.label: i18n("Results:")
            text: i18n("Prefer songs over videos")
        }
        QQC2.TextField {
            id: apiUrlField
            visible: page.showPear
            Kirigami.FormData.label: i18n("API server URL:")
            placeholderText: "http://127.0.0.1:26538"
            Layout.maximumWidth: page.fieldWidth
        }
        QQC2.Label {
            visible: page.showPear
            text: i18n("Requires the API Server plugin enabled inside Pear Desktop.")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
            Layout.maximumWidth: page.fieldWidth
        }
        QQC2.SpinBox {
            id: extraQueueSpin
            visible: page.showPear
            Kirigami.FormData.label: i18n("Extra songs queued on cold start:")
            from: 0; to: 15
            value: 5
        }
        QQC2.CheckBox {
            id: pearHideBtnCheck
            visible: page.pearSearch
            Kirigami.FormData.label: i18n("Start/Stop button:")
            text: i18n("Hidden in popup")
            checked: page.cfg_pearHideAppButton
            onToggled: page.cfg_pearHideAppButton = checked
        }
        QQC2.TextField {
            id: launchField
            visible: page.showPear
            Kirigami.FormData.label: i18n("Start command:")
            placeholderText: "youtube-music"
            Layout.maximumWidth: page.fieldWidth
        }
        QQC2.TextField {
            id: closeField
            visible: page.showPear
            Kirigami.FormData.label: i18n("Force-close command:")
            placeholderText: "pkill -9 -f youtube-music"
            Layout.maximumWidth: page.fieldWidth
        }

        Item { Kirigami.FormData.isSection: true; visible: page.autoSearch }
        QQC2.CheckBox {
            id: autoHideBtnCheck
            visible: page.autoSearch
            Kirigami.FormData.label: i18n("Start/Stop button:")
            text: i18n("Hidden in popup")
            checked: page.cfg_pearHideAppButton && page.cfg_spotifyHideAppButton
            onToggled: {
                page.cfg_pearHideAppButton = checked;
                page.cfg_spotifyHideAppButton = checked;
            }
        }
    }
}
