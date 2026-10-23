import QtQuick
import QtQuick.Controls
import QtQuick.Controls.impl
import QtQuick.Layouts

import org.qfield
import Theme

import "../js/merginutils.js" as MerginUtils
import "../js/style.js" as MMStyle

// Main Mergin Maps panel, laid out like the Mergin Maps mobile project screens
// (https://merginmaps.com/docs/field/mobile-app-ui/#home):
//  - signed out: login (Mergin Maps mobile's MMLoginPage: sign in, forgot password, sign up, change server)
//  - "Home": projects on this device ("Currently open", "Downloaded projects")
//  - "Projects": projects of the active workspace on the server
//  - account page (avatar in the header): workspace, manage account, storage, sign out
//  - "Select workspace": switch between the workspaces the user belongs to
QfPopup {
  id: panel

  property MerginClient client
  property MerginProjects projects
  property MerginSync sync
  property MerginWorkspaces workspaces

  // home | projects | account | workspaces
  property string page: "home"
  readonly property bool busy: projects.downloading || sync.syncing

  width: Math.min(parent.width - Theme.popupScreenEdgeHorizontalMargin * 2, 480)
  height: parent.height - Theme.popupScreenEdgeVerticalMargin * 2
  x: (parent.width - width) / 2
  y: (parent.height - height) / 2
  padding: 0
  modal: true
  closePolicy: busy ? Popup.NoAutoClose : Popup.CloseOnEscape | Popup.CloseOnPressOutside

  background: Rectangle {
    radius: MMStyle.radius
    color: MMStyle.lightGreen
  }

  property bool statusIsError: false

  function showStatus(message, isError) {
    statusIsError = isError;
    statusLabel.text = message;
    statusLabel.color = isError ? Theme.errorColor : MMStyle.night;
  }

  function formatSize(bytes) {
    return QfFileUtils.representFileSize(bytes);
  }

  function showPage(name) {
    page = name;
    searchField.text = "";
    showStatus("", false);
  }

  // Workspaces first (the project list is filtered by the active workspace), then the server project list.
  function refreshAll() {
    workspaces.refresh(function (ok, message) {
      if (ok) {
        projects.refresh();
      } else {
        panel.showStatus(message, true);
      }
    });
  }

  function remoteFor(namespace, name) {
    const list = projects.remoteProjects;
    for (let i = 0; i < list.length; i++) {
      if (list[i].namespace === namespace && list[i].name === name) return list[i];
    }
    return null;
  }

  // OnServer / UpToDate / NeedsSync, as in Mergin Maps mobile
  function projectState(downloaded, localVersion, serverVersion) {
    if (!downloaded) return "OnServer";
    return serverVersion !== "" && localVersion !== serverVersion ? "NeedsSync" : "UpToDate";
  }

  function openProject(namespace, name, then) {
    panel.close();
    projects.openLocal(namespace, name, then);
  }

  function synchronise(namespace, name) {
    if (sync.currentFullName === MerginUtils.projectFullName(namespace, name)) {
      sync.syncCurrent();
    } else {
      // sync works on the open project: open it first
      openProject(namespace, name, function () { sync.syncCurrent(); });
    }
  }

  // Home: projects on this device, the open one first
  readonly property var homeModel: {
    const open = sync.currentFullName;
    const query = searchField.text;
    return projects.localProjects.filter(function (p) {
      return p.version !== "" && MerginUtils.matchesSearch(query, p.namespace, p.name);   // "" = download not finished
    }).map(function (p) {
      const fullName = MerginUtils.projectFullName(p.namespace, p.name);
      return { namespace: p.namespace, name: p.name, version: p.version, size: p.size, updated: p.updated,
               opened: fullName === open, group: fullName === open ? qsTr("Currently open") : qsTr("Downloaded projects") };
    }).sort(function (a, b) { return (b.opened ? 1 : 0) - (a.opened ? 1 : 0); });
  }

  readonly property var projectsModel: {
    const query = searchField.text;
    return projects.remoteProjects.filter(function (p) { return MerginUtils.matchesSearch(query, p.namespace, p.name); });
  }

  readonly property var workspacesModel: {
    const query = searchField.text.trim().toLowerCase();
    return workspaces.workspaces.filter(function (w) { return query === "" || w.name.toLowerCase().indexOf(query) >= 0; });
  }

  onOpened: {
    serverField.text = client.serverUrl;
    loginField.text = client.loginName;
    passwordField.text = "";
    rememberCheck.checked = client.rememberPassword;
    showStatus("", false);
    if (client.loggedIn) {
      if (page !== "home" && page !== "projects") page = "home";
      if (page === "home" && homeModel.length === 0) page = "projects";
      client.validateSession(function (ok, message) {
        if (ok) {
          panel.refreshAll();
        } else {
          panel.showStatus(message, true);
        }
      });
    } else {
      client.checkServer();
    }
  }

  // ---- building blocks (Mergin Maps mobile components) ----

  // Round icon button (MMRoundButton)
  component RoundIconButton: RoundButton {
    property color bgColor: MMStyle.polar
    implicitWidth: 40
    implicitHeight: 40
    padding: 8
    icon.color: MMStyle.forest
    icon.width: 24
    icon.height: 24
    background: Rectangle { radius: 20; color: parent.bgColor }
  }

  // MMButton: primary (grass), secondary (forest outline), tertiary (text only); pill shaped
  component MMButton: Button {
    id: mmButton
    property string kind: "primary"
    property string iconSource: ""
    property color textColor: MMStyle.forest
    implicitHeight: kind === "tertiary" ? 40 : 52
    font.pixelSize: 16
    font.weight: Font.DemiBold
    contentItem: Row {
      spacing: 8
      Item {
        width: Math.max(0, (mmButton.availableWidth - buttonIcon.width * (buttonIcon.visible ? 1 : 0) - buttonText.implicitWidth - 8) / 2)
        height: 1
      }
      IconImage {
        id: buttonIcon
        anchors.verticalCenter: parent.verticalCenter
        visible: mmButton.iconSource !== ""
        width: 20
        height: 20
        sourceSize: Qt.size(20, 20)
        source: mmButton.iconSource
        color: mmButton.textColor
      }
      Text {
        id: buttonText
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, mmButton.availableWidth - (buttonIcon.visible ? 28 : 0))
        elide: Text.ElideMiddle
        font: mmButton.font
        color: mmButton.enabled ? mmButton.textColor : MMStyle.darkGreen
        text: mmButton.text
      }
    }
    background: Rectangle {
      radius: height / 2
      color: mmButton.kind === "primary" ? (mmButton.enabled ? (mmButton.down ? MMStyle.forest : MMStyle.grass) : MMStyle.mediumGreen)
             : mmButton.down ? MMStyle.mediumGreen : "transparent"
      border.width: mmButton.kind === "secondary" ? 2 : 0
      border.color: mmButton.enabled ? MMStyle.forest : MMStyle.mediumGreen
    }
  }

  // MMTextInput: polar rounded field
  component MMTextField: TextField {
    implicitHeight: 52
    leftPadding: 16
    rightPadding: 16
    font.pixelSize: 16
    color: MMStyle.night
    placeholderTextColor: MMStyle.darkGrey
    background: Rectangle {
      radius: MMStyle.radius
      color: MMStyle.polar
      border.width: parent.activeFocus ? 2 : 0
      border.color: MMStyle.grass
    }
  }

  component FieldTitle: Label {
    font.pixelSize: 14
    color: MMStyle.night
    Layout.bottomMargin: -6
  }

  // Section title above a group of items
  component SectionTitle: Label {
    font.pixelSize: 12
    color: MMStyle.night
    topPadding: 12
    bottomPadding: 8
  }

  // Row on the account page: icon, title, optional description, arrow
  component AccountRow: ItemDelegate {
    id: row
    property string iconSource
    property string title
    property string description
    Layout.fillWidth: true
    implicitHeight: 64
    background: Rectangle { color: row.pressed ? MMStyle.lightGreen : "transparent" }
    contentItem: RowLayout {
      spacing: 12
      Rectangle {
        Layout.preferredWidth: 40
        Layout.preferredHeight: 40
        radius: 20
        color: MMStyle.lightGreen
        IconImage { anchors.centerIn: parent; width: 24; height: 24; sourceSize: Qt.size(24, 24); source: row.iconSource; color: MMStyle.forest }
      }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: 2
        Label { Layout.fillWidth: true; elide: Text.ElideRight; font.pixelSize: 14; font.weight: Font.DemiBold; color: MMStyle.night; text: row.title }
        Label { Layout.fillWidth: true; visible: row.description !== ""; elide: Text.ElideRight; font.pixelSize: 12; color: MMStyle.darkGrey; text: row.description }
      }
      IconImage { Layout.preferredWidth: 24; Layout.preferredHeight: 24; sourceSize: Qt.size(24, 24); source: "../icons/ArrowLinkRight.svg"; color: MMStyle.forest }
    }
  }

  // Project card (MMProjectItem); "opened" uses the forest colour
  component ProjectCard: Rectangle {
    id: card
    property string namespace
    property string name
    property bool showNamespace: false
    property bool downloaded: true
    property string localVersion
    property string serverVersion
    property string updated
    property real size: 0
    property bool opened: false
    property string objectPrefix
    readonly property string fullName: MerginUtils.projectFullName(namespace, name)
    readonly property bool busy: (projects.downloading && projects.activeProject === fullName) || (sync.syncing && opened)
    readonly property string state_: panel.projectState(downloaded, localVersion, serverVersion)

    width: ListView.view ? ListView.view.width - 40 : 300
    height: cardLayout.implicitHeight + 32
    radius: MMStyle.radius
    color: opened ? MMStyle.forest : MMStyle.polar

    MouseArea {
      anchors.fill: parent
      enabled: card.downloaded && !card.opened && !panel.busy
      onClicked: panel.openProject(card.namespace, card.name)
    }

    ColumnLayout {
      id: cardLayout
      anchors.fill: parent
      anchors.margins: 16
      spacing: 10

      RowLayout {
        Layout.fillWidth: true
        spacing: 8

        ColumnLayout {
          Layout.fillWidth: true
          spacing: 4

          Label {
            Layout.fillWidth: true
            elide: Text.ElideLeft
            font.pixelSize: 14
            font.weight: Font.DemiBold
            color: card.opened ? MMStyle.polar : MMStyle.night
            text: card.showNamespace ? card.fullName : card.name
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: 4

            IconImage {
              Layout.preferredWidth: 16
              Layout.preferredHeight: 16
              sourceSize: Qt.size(16, 16)
              source: card.state_ === "OnServer" ? "../icons/Cloud.svg" : card.state_ === "UpToDate" ? "../icons/DoneCircle.svg" : "../icons/ErrorCircle.svg"
              color: card.state_ === "OnServer" ? MMStyle.informative : card.state_ === "UpToDate" ? MMStyle.positive : MMStyle.warning
            }

            Label {
              Layout.fillWidth: true
              elide: Text.ElideRight
              font.pixelSize: 12
              color: card.opened ? MMStyle.polar : MMStyle.night
              text: card.busy ? (projects.downloading ? qsTr("Downloading project") : qsTr("Synchronising project changes"))
                    : card.state_ === "NeedsSync" ? qsTr("Pending changes to synchronise")
                    : card.updated !== "" ? qsTr("Updated %1").arg(MerginUtils.relativeTime(card.updated, Date.now()))
                    : card.localVersion
            }
          }
        }

        // download (on server only) or "More options" (on this device)
        RoundIconButton {
          objectName: card.objectPrefix + (card.downloaded ? "More_" : "Button_") + card.name
          enabled: !panel.busy
          bgColor: card.opened ? MMStyle.polar : MMStyle.lightGreen
          icon.source: card.downloaded ? "../icons/MoreVertical.svg" : "../icons/Download.svg"
          onClicked: {
            panel.showStatus("", false);
            if (card.downloaded) {
              moreOptions.show(card.namespace, card.name);
            } else {
              projects.download(card.namespace, card.name);
            }
          }
        }
      }

      // MMProgressBar: 12 px, rounded, lightGreen track, grass fill
      Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 12
        visible: card.busy
        radius: 6
        color: MMStyle.lightGreen
        Rectangle {
          width: parent.width * Math.max(0.03, projects.downloading ? projects.progress : sync.progress)
          height: parent.height
          radius: 6
          color: MMStyle.grass
          Behavior on width { NumberAnimation { duration: 150 } }
        }
      }

      Label {
        Layout.fillWidth: true
        visible: card.busy
        elide: Text.ElideMiddle
        font.pixelSize: 12
        color: card.opened ? MMStyle.polar : MMStyle.night
        text: (projects.downloading ? projects.progressText : sync.statusText) + " · " + qsTr("Please don't close the app.")
      }
    }
  }

  // Message in the middle of an empty list
  component EmptyLabel: Label {
    anchors.centerIn: parent
    width: parent.width - 48
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    font.pixelSize: 14
    color: MMStyle.night
  }

  ColumnLayout {
    id: contentLayout
    anchors.fill: parent
    spacing: 0

    // ---- signed out: Mergin Maps mobile's login page (MMLoginPage) ----
    Item {
      Layout.fillWidth: true
      Layout.preferredHeight: 64
      visible: !client.loggedIn

      RoundIconButton {
        anchors.left: parent.left
        anchors.leftMargin: 20
        anchors.verticalCenter: parent.verticalCenter
        icon.source: "../icons/Back.svg"
        onClicked: panel.close()
      }

      Label {
        anchors.centerIn: parent
        font.pixelSize: 20
        font.weight: Font.DemiBold
        color: MMStyle.forest
        text: qsTr("Log in")
      }

      BusyIndicator {
        anchors.right: parent.right
        anchors.rightMargin: 20
        anchors.verticalCenter: parent.verticalCenter
        width: 32
        height: 32
        running: client.busy && !client.loggedIn
        visible: running
      }
    }

    Flickable {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: !client.loggedIn
      clip: true
      contentHeight: loginColumn.implicitHeight + 16
      boundsBehavior: Flickable.StopAtBounds

    ColumnLayout {
      id: loginColumn
      x: 20
      width: parent.width - 40
      spacing: 12

      // MMInfoBox: server check and login messages
      Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: infoText.implicitHeight + 24
        visible: statusLabel.text !== ""
        radius: MMStyle.radius
        color: panel.statusIsError ? MMStyle.negative : MMStyle.positive
        Label {
          id: infoText
          anchors.fill: parent
          anchors.margins: 12
          verticalAlignment: Text.AlignVCenter
          wrapMode: Text.WordWrap
          font.pixelSize: 14
          color: MMStyle.night
          text: statusLabel.text
        }
      }

      FieldTitle { text: qsTr("Email or username") }
      MMTextField {
        id: loginField
        objectName: "merginLoginField"
        Layout.fillWidth: true
        inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText | Qt.ImhEmailCharactersOnly
        onAccepted: passwordField.forceActiveFocus()
      }

      FieldTitle { text: qsTr("Password") }
      MMTextField {
        id: passwordField
        objectName: "merginPasswordField"
        property bool reveal: false
        Layout.fillWidth: true
        rightPadding: 52
        echoMode: reveal ? TextInput.Normal : TextInput.Password
        inputMethodHints: Qt.ImhHiddenText | Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText | Qt.ImhSensitiveData
        onAccepted: loginButton.clicked()

        RoundIconButton {
          anchors.right: parent.right
          anchors.rightMargin: 4
          anchors.verticalCenter: parent.verticalCenter
          bgColor: "transparent"
          icon.source: passwordField.reveal ? "../icons/Hide.svg" : "../icons/Show.svg"
          onClicked: passwordField.reveal = !passwordField.reveal
        }
      }

      CheckBox {
        id: rememberCheck
        Layout.fillWidth: true
        text: qsTr("Remember password on this device")
        font.pixelSize: 14
      }

      Label {
        Layout.fillWidth: true
        visible: rememberCheck.checked
        wrapMode: Text.WordWrap
        font.pixelSize: 12
        color: MMStyle.darkGrey
        text: qsTr("Keeps you signed in when the session expires (every 12 hours by default). The password is stored unencrypted in QField's settings.")
      }

      MMButton {
        objectName: "merginForgotPasswordButton"
        Layout.fillWidth: true
        kind: "tertiary"
        text: qsTr("Forgot password?")
        onClicked: Qt.openUrlExternally(MerginUtils.resetPasswordUrl(client.serverUrl))
      }

      MMButton {
        id: loginButton
        objectName: "merginLoginButton"
        Layout.fillWidth: true
        text: qsTr("Sign in")
        enabled: !client.busy && loginField.text.trim() !== "" && passwordField.text !== ""
        onClicked: {
          client.login(loginField.text, passwordField.text, rememberCheck.checked);
        }
      }

      Label {
        Layout.fillWidth: true
        visible: client.serverSsoEnabled
        wrapMode: Text.WordWrap
        font.pixelSize: 12
        color: MMStyle.darkGrey
        text: qsTr("This server also offers single sign-on (SSO). SSO accounts are not supported by this plugin yet; please use an account with a password.")
      }

      // MMHlineText + "Sign up": hosted and Enterprise servers that allow self-registration
      RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 8
        visible: client.signUpUrl !== ""
        spacing: 12
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: MMStyle.mediumGreen }
        Label { font.pixelSize: 12; color: MMStyle.night; text: qsTr("Don't have an account?") }
        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: MMStyle.mediumGreen }
      }

      MMButton {
        objectName: "merginSignUpButton"
        Layout.fillWidth: true
        visible: client.signUpUrl !== ""
        kind: "secondary"
        text: qsTr("Sign up")
        onClicked: {
          client.log("Opening sign-up page " + client.signUpUrl);
          Qt.openUrlExternally(client.signUpUrl);
          panel.showStatus(qsTr("Create your account in the browser, then come back here to sign in."), false);
        }
      }

      // server in the footer; tapping it opens "Change server"
      MMButton {
        objectName: "merginServerButton"
        Layout.fillWidth: true
        Layout.topMargin: 16
        kind: "tertiary"
        iconSource: "../icons/Globe.svg"
        textColor: MMStyle.night
        text: client.serverUrl
        onClicked: {
          serverField.text = client.serverUrl;
          changeServer.open();
        }
      }
    }
    }

    // ---- signed in: header (back, title, avatar) ----
    Item {
      Layout.fillWidth: true
      Layout.preferredHeight: 64
      visible: client.loggedIn

      RoundIconButton {
        objectName: "merginBackButton"
        anchors.left: parent.left
        anchors.leftMargin: 20
        anchors.verticalCenter: parent.verticalCenter
        enabled: !panel.busy || panel.page === "account" || panel.page === "workspaces"
        icon.source: "../icons/Back.svg"
        onClicked: {
          if (panel.page === "workspaces") panel.showPage("account");
          else if (panel.page === "account") panel.showPage("home");
          else panel.close();
        }
      }

      Label {
        objectName: "merginPageTitle"
        anchors.centerIn: parent
        width: parent.width - 160
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        font.pixelSize: 18
        font.weight: Font.DemiBold
        color: MMStyle.forest
        text: panel.page === "home" ? qsTr("Home")
              : panel.page === "projects" ? (workspaces.activeName !== "" ? workspaces.activeName : qsTr("Projects"))
              : panel.page === "workspaces" ? qsTr("Select workspace") : ""
      }

      BusyIndicator {
        anchors.right: avatar.left
        anchors.rightMargin: 4
        anchors.verticalCenter: parent.verticalCenter
        width: 32
        height: 32
        running: client.busy || projects.listing || workspaces.loading
        visible: running
      }

      // avatar with initials, opens the account page
      Rectangle {
        id: avatar
        objectName: "merginAvatar"
        anchors.right: parent.right
        anchors.rightMargin: 20
        anchors.verticalCenter: parent.verticalCenter
        width: 40
        height: 40
        radius: 20
        visible: panel.page === "home" || panel.page === "projects"
        color: MMStyle.positive
        Label {
          anchors.centerIn: parent
          font.pixelSize: 14
          font.weight: Font.DemiBold
          color: MMStyle.forest
          text: MerginUtils.initials(workspaces.fullName, client.username)
        }
        MouseArea {
          anchors.fill: parent
          onClicked: panel.showPage("account")
        }
      }
    }

    // ---- signed in: search ----
    Rectangle {
      Layout.fillWidth: true
      Layout.leftMargin: 20
      Layout.rightMargin: 20
      Layout.bottomMargin: 8
      Layout.preferredHeight: 48
      visible: client.loggedIn && panel.page !== "account"
      radius: MMStyle.radius
      color: MMStyle.polar

      IconImage {
        id: searchIcon
        anchors.left: parent.left
        anchors.leftMargin: 16
        anchors.verticalCenter: parent.verticalCenter
        width: 24
        height: 24
        sourceSize: Qt.size(24, 24)
        source: "../icons/Search.svg"
        color: MMStyle.night
      }

      TextField {
        id: searchField
        objectName: "merginSearchField"
        anchors.left: searchIcon.right
        anchors.right: clearSearch.left
        anchors.verticalCenter: parent.verticalCenter
        font.pixelSize: 14
        color: MMStyle.night
        placeholderText: panel.page === "workspaces" ? qsTr("Search…") : qsTr("Search for projects…")
        placeholderTextColor: MMStyle.darkGrey
        inputMethodHints: Qt.ImhNoPredictiveText
        background: Item {}
      }

      RoundIconButton {
        id: clearSearch
        anchors.right: parent.right
        anchors.rightMargin: 4
        anchors.verticalCenter: parent.verticalCenter
        visible: searchField.text !== ""
        bgColor: "transparent"
        icon.source: "../icons/Close.svg"
        onClicked: searchField.text = ""
      }
    }

    // ---- signed in: pages ----
    StackLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: client.loggedIn
      currentIndex: ["home", "projects", "account", "workspaces"].indexOf(panel.page)

      // Home: projects on this device
      ListView {
        id: homeList
        leftMargin: 20
        rightMargin: 20
        objectName: "merginHomeList"
        clip: true
        spacing: 12
        model: panel.homeModel
        section.property: "group"
        section.delegate: SectionTitle {
          required property string section
          text: section
        }
        footer: Item { height: 12 }

        EmptyLabel {
          visible: homeList.count === 0
          text: searchField.text !== "" ? qsTr("No projects found") : qsTr("No projects on this device yet. Download one from Projects.")
        }

        delegate: ProjectCard {
          required property var modelData
          objectPrefix: "merginHome"
          namespace: modelData.namespace
          name: modelData.name
          showNamespace: true
          downloaded: true
          localVersion: modelData.version
          serverVersion: { const r = panel.remoteFor(modelData.namespace, modelData.name); return r ? r.version : ""; }
          updated: modelData.updated
          size: modelData.size
          opened: modelData.opened
        }
      }

      // Projects: the active workspace's projects on the server
      ListView {
        id: projectList
        leftMargin: 20
        rightMargin: 20
        objectName: "merginProjectList"
        clip: true
        spacing: 12
        model: panel.projectsModel
        header: Item { height: 4 }
        footer: Item { height: 12 }

        EmptyLabel {
          visible: projectList.count === 0
          color: projects.listError !== "" ? Theme.errorColor : MMStyle.night
          text: projects.listing ? qsTr("Loading projects…")
                : projects.listError !== "" ? projects.listError
                : searchField.text !== "" ? qsTr("No projects found")
                : qsTr("There are no projects in the workspace %1.").arg(workspaces.activeName)
        }

        delegate: ProjectCard {
          required property var modelData
          objectPrefix: "merginProject"
          namespace: modelData.namespace
          name: modelData.name
          downloaded: modelData.downloaded
          localVersion: modelData.localVersion
          serverVersion: modelData.version
          updated: modelData.updated
          size: modelData.size
          opened: sync.currentFullName === MerginUtils.projectFullName(modelData.namespace, modelData.name)
        }
      }

      // Account
      Flickable {
        clip: true
        contentHeight: accountLayout.implicitHeight + 24
        ColumnLayout {
          id: accountLayout
          x: 20
          width: parent.width - 40
          spacing: 4

          Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 80
            Layout.preferredHeight: 80
            radius: 40
            color: MMStyle.positive
            Label {
              anchors.centerIn: parent
              font.pixelSize: 28
              font.weight: Font.DemiBold
              color: MMStyle.forest
              text: MerginUtils.initials(workspaces.fullName, client.username)
            }
          }
          Label {
            Layout.alignment: Qt.AlignHCenter
            font.pixelSize: 18
            font.weight: Font.DemiBold
            color: MMStyle.forest
            text: (workspaces.fullName !== "" ? workspaces.fullName + " " : "") + "(" + client.username + ")"
          }
          Label {
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideMiddle
            font.pixelSize: 14
            color: MMStyle.night
            text: client.email
          }
          Label {
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideMiddle
            font.pixelSize: 12
            color: MMStyle.darkGrey
            text: client.serverUrl
          }

          SectionTitle { text: workspaces.workspaces.length > 1 ? qsTr("Workspaces") : qsTr("Workspace"); topPadding: 20 }

          AccountRow {
            objectName: "merginWorkspaceRow"
            iconSource: "../icons/Workspaces.svg"
            title: workspaces.activeName !== "" ? workspaces.activeName : qsTr("No workspace")
            description: workspaces.active ? workspaces.active.role : ""
            onClicked: panel.showPage("workspaces")
          }

          AccountRow {
            iconSource: "../icons/Settings.svg"
            title: qsTr("Manage Account")
            onClicked: Qt.openUrlExternally(client.serverUrl + "/dashboard/profile")
          }

          RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 16
            visible: workspaces.active !== null && workspaces.active.storage > 0
            Label { Layout.fillWidth: true; font.pixelSize: 12; color: MMStyle.night; text: qsTr("Storage") }
            Label {
              font.pixelSize: 12
              font.weight: Font.DemiBold
              color: MMStyle.night
              text: workspaces.active ? panel.formatSize(workspaces.active.diskUsage) + "/" + panel.formatSize(workspaces.active.storage) : ""
            }
          }
          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 12
            visible: workspaces.active !== null && workspaces.active.storage > 0
            radius: 6
            color: MMStyle.polar
            Rectangle {
              width: workspaces.active && workspaces.active.storage > 0 ? parent.width * Math.min(1, Math.max(0.02, workspaces.active.diskUsage / workspaces.active.storage)) : 0
              height: parent.height
              radius: 6
              color: workspaces.active && workspaces.active.diskUsage >= workspaces.active.storage ? MMStyle.negative : MMStyle.grass
            }
          }

          SectionTitle { text: qsTr("General"); topPadding: 20 }

          AccountRow {
            objectName: "merginSignOutRow"
            iconSource: "../icons/SignOut.svg"
            title: qsTr("Sign out")
            enabled: !client.busy && !panel.busy
            onClicked: {
              client.logout();
              passwordField.text = "";
              projects.remoteProjects = [];
              workspaces.clear();
              panel.page = "home";
              panel.showStatus(qsTr("Logged out"), false);
            }
          }
        }
      }

      // Select workspace
      ListView {
        id: workspaceList
        leftMargin: 20
        rightMargin: 20
        objectName: "merginWorkspaceList"
        clip: true
        spacing: 12
        model: panel.workspacesModel
        header: SectionTitle { text: qsTr("Your workspaces") }
        footer: Item { height: 12 }

        EmptyLabel {
          visible: workspaceList.count === 0
          text: workspaces.loading ? qsTr("Loading workspaces…") : workspaces.error !== "" ? workspaces.error : qsTr("No workspaces found")
        }

        delegate: Rectangle {
          id: wsItem
          required property var modelData
          readonly property bool current: modelData.id === workspaces.activeId
          objectName: "merginWorkspace_" + modelData.name
          width: workspaceList.width - 40
          height: 64
          radius: MMStyle.radius
          color: current ? MMStyle.forest : MMStyle.polar

          Label {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 20
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            font.pixelSize: 16
            font.weight: Font.DemiBold
            color: wsItem.current ? MMStyle.polar : MMStyle.night
            text: wsItem.modelData.name
          }
          MouseArea {
            anchors.fill: parent
            enabled: !panel.busy
            onClicked: {
              const changed = wsItem.modelData.id !== workspaces.activeId;
              workspaces.setActive(wsItem.modelData.id);
              panel.showPage("projects");
              if (changed) projects.refresh();
            }
          }
        }
      }
    }

    Label {
      id: statusLabel
      Layout.fillWidth: true
      Layout.leftMargin: 20
      Layout.rightMargin: 20
      Layout.topMargin: 4
      Layout.bottomMargin: 4
      visible: text !== "" && client.loggedIn   // signed out: shown in the login page's info box
      wrapMode: Text.WordWrap
      font: Theme.tipFont
      color: MMStyle.night
    }

    // ---- signed in: bottom navigation (Home / Projects) ----
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: 64
      visible: client.loggedIn && (panel.page === "home" || panel.page === "projects")
      color: MMStyle.forest
      // square top corners, rounded bottom corners like the popup
      bottomLeftRadius: MMStyle.radius
      bottomRightRadius: MMStyle.radius

      RowLayout {
        anchors.fill: parent
        spacing: 0

        Repeater {
          model: [
            { page: "home", label: qsTr("Home"), icon: "Home" },
            { page: "projects", label: qsTr("Projects"), icon: "Projects" }
          ]
          delegate: Item {
            id: tab
            required property var modelData
            readonly property bool current: panel.page === modelData.page
            objectName: "merginTab_" + modelData.page
            Layout.fillWidth: true
            Layout.fillHeight: true
            signal clicked()
            onClicked: panel.showPage(modelData.page)

            Column {
              anchors.centerIn: parent
              spacing: 2
              IconImage {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 24
                height: 24
                sourceSize: Qt.size(24, 24)
                source: "../icons/" + tab.modelData.icon + (tab.current ? "Filled" : "") + ".svg"
                color: tab.current ? MMStyle.polar : MMStyle.mediumGreen
              }
              Label {
                anchors.horizontalCenter: parent.horizontalCenter
                font.pixelSize: 11
                font.weight: tab.current ? Font.DemiBold : Font.Normal
                color: tab.current ? MMStyle.polar : MMStyle.mediumGreen
                text: tab.modelData.label
              }
            }
            MouseArea {
              anchors.fill: parent
              onClicked: tab.clicked()
            }
          }
        }
      }
    }
  }

  // "Change server" drawer (MMLoginPage's changeServerDrawer)
  Popup {
    id: changeServer
    objectName: "merginChangeServer"
    parent: panel.contentItem
    width: parent ? parent.width : 300
    x: 0
    y: parent ? parent.height - height : 0
    padding: 20
    modal: true
    background: Rectangle { color: MMStyle.polar; topLeftRadius: 20; topRightRadius: 20; bottomLeftRadius: MMStyle.radius; bottomRightRadius: MMStyle.radius }

    function confirm() {
      client.setServerUrl(serverField.text);
      serverField.text = client.serverUrl;
      panel.showStatus("", false);
      client.checkServer();
      close();
    }

    contentItem: ColumnLayout {
      spacing: 12

      Item {
        Layout.fillWidth: true
        Layout.preferredHeight: 48
        Label {
          anchors.centerIn: parent
          font.pixelSize: 16
          font.weight: Font.DemiBold
          color: MMStyle.forest
          text: qsTr("Change server")
        }
        RoundIconButton {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          bgColor: MMStyle.lightGreen
          icon.source: "../icons/Close.svg"
          onClicked: changeServer.close()
        }
      }

      MMTextField {
        id: serverField
        objectName: "merginServerField"
        Layout.fillWidth: true
        inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText
        background: Rectangle {
          radius: MMStyle.radius
          color: MMStyle.lightGreen
          border.width: serverField.activeFocus ? 2 : 0
          border.color: MMStyle.grass
        }
        onAccepted: changeServer.confirm()
      }

      MMButton {
        objectName: "merginServerConfirm"
        Layout.fillWidth: true
        text: qsTr("Confirm")
        onClicked: changeServer.confirm()
      }

      MMButton {
        Layout.fillWidth: true
        kind: "tertiary"
        visible: client.serverUrl !== MerginUtils.DEFAULT_SERVER_URL
        text: qsTr("Use %1").arg(MerginUtils.DEFAULT_SERVER_URL)
        onClicked: {
          serverField.text = MerginUtils.DEFAULT_SERVER_URL;
          changeServer.confirm();
        }
      }
    }
  }

  // "More options" drawer for a project on this device (MMProjectActionsDrawer)
  Popup {
    id: moreOptions
    objectName: "merginMoreOptions"
    property string namespace
    property string name
    property bool confirmRemove: false

    function show(ns, n) {
      namespace = ns;
      name = n;
      confirmRemove = false;
      open();
    }

    parent: panel.contentItem
    width: parent ? parent.width : 300
    x: 0
    y: parent ? parent.height - height : 0
    padding: 20
    modal: true
    background: Rectangle { color: MMStyle.polar; topLeftRadius: 20; topRightRadius: 20; bottomLeftRadius: MMStyle.radius; bottomRightRadius: MMStyle.radius }

    contentItem: ColumnLayout {
      spacing: 0

      Item {
        Layout.fillWidth: true
        Layout.preferredHeight: 48
        Label {
          anchors.centerIn: parent
          font.pixelSize: 16
          font.weight: Font.DemiBold
          color: MMStyle.forest
          text: moreOptions.confirmRemove ? qsTr("Remove project?") : qsTr("More options")
        }
        RoundIconButton {
          objectName: "merginMoreOptionsClose"
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          bgColor: MMStyle.lightGreen
          icon.source: "../icons/Close.svg"
          onClicked: moreOptions.close()
        }
      }

      // actions
      Repeater {
        model: moreOptions.confirmRemove ? [] : [
          { id: "sync", label: qsTr("Synchronise project"), icon: "Sync" },
          { id: "remove", label: qsTr("Remove from device"), icon: "Delete" }
        ]
        delegate: ItemDelegate {
          id: action
          required property var modelData
          required property int index
          objectName: "merginAction_" + modelData.id
          Layout.fillWidth: true
          implicitHeight: 56
          background: Rectangle {
            color: action.pressed ? MMStyle.lightGreen : "transparent"
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: MMStyle.grey; visible: action.index === 0 }
          }
          contentItem: RowLayout {
            spacing: 12
            IconImage { Layout.preferredWidth: 24; Layout.preferredHeight: 24; sourceSize: Qt.size(24, 24); source: "../icons/" + action.modelData.icon + ".svg"; color: MMStyle.night }
            Label { Layout.fillWidth: true; font.pixelSize: 14; color: MMStyle.night; text: action.modelData.label }
          }
          onClicked: {
            if (modelData.id === "sync") {
              moreOptions.close();
              panel.synchronise(moreOptions.namespace, moreOptions.name);
            } else {
              moreOptions.confirmRemove = true;
            }
          }
        }
      }

      // confirmation (as Mergin Maps mobile, removing never touches the server copy)
      Label {
        Layout.fillWidth: true
        Layout.topMargin: 8
        visible: moreOptions.confirmRemove
        wrapMode: Text.WordWrap
        font.pixelSize: 14
        color: MMStyle.night
        text: qsTr("Any unsynchronised changes to %1 will be lost. The project stays on the server and can be downloaded again.").arg(moreOptions.name)
      }

      QfButton {
        objectName: "merginConfirmRemove"
        Layout.fillWidth: true
        Layout.topMargin: 16
        visible: moreOptions.confirmRemove
        text: qsTr("Remove from device")
        bgcolor: MMStyle.negative
        color: MMStyle.night
        onClicked: {
          const ns = moreOptions.namespace, n = moreOptions.name;
          moreOptions.close();
          projects.removeFromDevice(ns, n, function (ok, message) {
            panel.showStatus(message, !ok);
          });
        }
      }
    }
  }

  Connections {
    target: client

    // like mobile, only problems are shown
    function onServerChecked(ok, message) {
      panel.showStatus(ok ? "" : message, !ok);
    }

    function onLoginFinished(ok, message) {
      // Errors are shown inline (no toast while the panel is open).
      panel.showStatus(ok ? "" : message, !ok);
      if (ok) {
        passwordField.text = "";
        panel.page = panel.homeModel.length > 0 ? "home" : "projects";
        panel.refreshAll();
      }
    }

    function onAuthRequired(message) {
      panel.showStatus(message, true);
    }
  }

  Connections {
    target: workspaces

    // the new list is requested by refreshAll() or by the "Select workspace" page
    function onWorkspaceSwitched() {
      projects.remoteProjects = [];
    }
  }

  Connections {
    target: projects

    function onDownloadFinished(ok, fullName, message) {
      if (ok) {
        panel.page = "home";   // the downloaded project is now "Currently open"
        panel.close();
        iface.mainWindow().displayToast(message, "info");
      } else {
        panel.showStatus(message, true);
      }
    }
  }
}
