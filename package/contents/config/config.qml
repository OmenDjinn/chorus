import QtQuick
import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: i18n("Look & Feel")
        icon: "color-management"
        source: "configCosmetics.qml"
    }
    ConfigCategory {
        name: i18n("Music App")
        icon: "audio-speakers-symbolic"
        source: "configMusicApp.qml"
    }
}
