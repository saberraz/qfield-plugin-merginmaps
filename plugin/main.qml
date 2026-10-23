import QtQuick
import QtQuick.Controls

import org.qfield
import Theme

import "qml"
import "js/style.js" as MMStyle

// Entry point loaded by QField's plugin manager.
Item {
  id: plugin

  property var mainWindow: iface.mainWindow()

  MerginClient {
    id: merginClient
  }

  MerginWorkspaces {
    id: merginWorkspaces
    client: merginClient
  }

  MerginProjects {
    id: merginProjects
    client: merginClient
    workspace: merginWorkspaces.activeName
  }

  MerginSync {
    id: merginSync
    client: merginClient
    projects: merginProjects
  }

  MerginPanel {
    id: merginPanel
    parent: plugin.mainWindow.contentItem
    client: merginClient
    projects: merginProjects
    sync: merginSync
    workspaces: merginWorkspaces
  }

  QfToolButton {
    id: merginButton
    // Lets tests find the live instance by searching the visual children of QField's "pluginsToolbar".
    objectName: "merginPluginButton"
    property alias panel: merginPanel
    property alias syncEngine: merginSync
    property alias workspaces: merginWorkspaces
    iconSource: Qt.resolvedUrl("icon.svg")
    iconColor: Theme.mainColor
    bgcolor: Theme.darkGray
    round: true

    onClicked: merginPanel.open()
  }

  // Sync button, as on the Mergin Maps mobile map screen: only for Mergin projects, spins while syncing.
  QfToolButton {
    id: syncButton
    objectName: "merginSyncButton"
    visible: merginSync.currentFullName !== ""
    iconSource: Qt.resolvedUrl("icons/Sync.svg")
    iconColor: MMStyle.polar
    bgcolor: MMStyle.forest
    round: true
    enabled: !merginSync.syncing

    onClicked: merginSync.syncCurrent()

    RotationAnimation on rotation {
      running: merginSync.syncing
      from: 0
      to: 720
      duration: 1000
      loops: Animation.Infinite
      easing.type: Easing.InOutSine
      onRunningChanged: if (!running) syncButton.rotation = 0
    }
  }

  // While syncing, the project is swapped for the empty home stub (to release its files): keep showing the map.
  Rectangle {
    parent: plugin.mainWindow.contentItem
    anchors.fill: parent
    visible: merginSync.syncing
    z: 999
    color: MMStyle.lightGreen
    Image {
      anchors.fill: parent
      source: merginSync.snapshot ? merginSync.snapshot.url : ""
      fillMode: Image.PreserveAspectCrop
      opacity: 0.85
    }
    MouseArea { anchors.fill: parent }   // the map is not usable during sync
  }

  // Progress card while syncing (Mergin Maps mobile style: polar card, grass progress bar).
  Rectangle {
    id: syncBanner
    objectName: "merginSyncBanner"
    parent: plugin.mainWindow.contentItem
    visible: merginSync.syncing && !merginPanel.opened
    z: 1001
    anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
    y: 64
    width: Math.min(parent ? parent.width - 32 : 300, 420)
    height: bannerColumn.implicitHeight + 24
    radius: MMStyle.radius
    color: MMStyle.polar
    border.color: MMStyle.lightGreen

    Column {
      id: bannerColumn
      anchors.fill: parent
      anchors.margins: 12
      spacing: 8

      Text {
        width: parent.width
        font.pixelSize: 14
        font.weight: Font.DemiBold
        color: MMStyle.forest
        elide: Text.ElideRight
        text: qsTr("Synchronising project changes")
      }

      Rectangle {
        width: parent.width
        height: 12
        radius: 6
        color: MMStyle.lightGreen
        Rectangle {
          width: parent.width * Math.max(0.03, merginSync.progress)
          height: parent.height
          radius: 6
          color: MMStyle.grass
          Behavior on width { NumberAnimation { duration: 150 } }
        }
      }

      Text {
        width: parent.width
        font.pixelSize: 12
        color: MMStyle.night
        elide: Text.ElideMiddle
        text: merginSync.statusText + " · " + qsTr("Please don't close the app.")
      }
    }
  }

  Connections {
    target: merginClient

    // Raised by background work (e.g. sync) when the session expired and no password is remembered.
    function onAuthRequired(message) {
      if (!merginPanel.opened) {
        plugin.mainWindow.displayToast(message, "warning", qsTr("Log in"), function () { merginPanel.open(); });
      }
    }
  }

  Connections {
    target: merginSync

    function onSyncFinished(ok, message) {
      if (ok) {
        plugin.mainWindow.displayToast(message, "info");
      } else {
        plugin.mainWindow.displayToast(qsTr("Failed to synchronise your changes") + ": " + message, "error");
      }
    }
  }

  Component.onCompleted: {
    iface.addItemToPluginsToolbar(merginButton);
    iface.addItemToPluginsToolbar(syncButton);
    merginClient.log("Plugin loaded, server " + merginClient.serverUrl + (merginClient.loggedIn ? ", signed in as " + merginClient.username : ""));
  }
}
