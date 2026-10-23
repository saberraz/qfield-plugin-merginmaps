import QtQuick
import org.qfield

// Home / Projects tabs, project actions and workspace switching, driven through the panel's controls.
//  - Community Edition (127.0.0.1:5000, one workspace): download, Home tab, More options, Remove from device
//  - mock multi-workspace server (127.0.0.1:5055, tests/server/mock_multi_workspace.py): account page, Select workspace
Item {
  id: d
  property var button: null
  property var panel: button ? button.panel : null
  property var client: panel ? panel.client : null
  property var projects: panel ? panel.projects : null
  property var workspaces: button ? button.workspaces : null
  property int step: 0
  property bool waiting: false
  property bool lastOk: false
  property int failures: 0

  function log(m) { console.warn("E2E " + m); }
  function check(cond, what) { if (!cond) failures++; log((cond ? "PASS " : "FAIL ") + what); }
  function shot(name) { log("SHOT " + name); }

  // visible items only: hidden pages hold items with the same objectName
  function findVisible(item, name) {
    if (!item || !item.visible) return null;
    if (item.objectName === name) return item;
    for (let i = 0; i < item.children.length; i++) {
      const found = findVisible(item.children[i], name);
      if (found) return found;
    }
    return null;
  }
  // popups (the panel, "More options") live in the window overlay: search from the window's root item
  function item(name) {
    let root = iface.mainWindow().contentItem;
    while (root.parent) root = root.parent;
    return findVisible(root, name);
  }
  function tap(name) {
    const it = item(name);
    check(it !== null, "tap " + name);
    if (it) it.clicked();
  }
  function title() { const t = item("merginPageTitle"); return t ? t.text : "<none>"; }
  function names(list) { return list.map(function (p) { return p.namespace + "/" + p.name; }); }

  Connections {
    target: d.client
    function onLoginFinished(ok, message) { d.log("loginFinished " + ok + " " + message); d.waiting = false; }
  }
  Connections {
    target: d.projects
    function onDownloadFinished(ok, fullName, message) { d.log("downloadFinished " + ok + " " + fullName + " " + message); d.lastOk = ok; d.waiting = false; }
  }

  Timer {
    interval: 1500; repeat: true; running: d.button !== null
    onTriggered: {
      if (d.waiting || d.projects.listing || d.workspaces.loading) return;
      try { d.tick(); } catch (e) { d.log("EXCEPTION at step " + d.step + ": " + e + " " + e.stack); Qt.quit(); }
    }
  }

  function tick() {
    switch (step) {
    case 0:
      iface.mainWindow().width = 420; iface.mainWindow().height = 760;
      client.setServerUrl("http://127.0.0.1:5000");
      panel.open();
      waiting = true;
      client.login("fielduser", "Field-Pass-123", false);
      break;
    case 1:
      check(panel.page === "projects", "fresh device opens on Projects (page " + panel.page + ")");
      check(workspaces.workspaces.length === 1 && workspaces.activeName === "mergin", "CE: single workspace " + workspaces.activeName);
      check(title() === "mergin", "Projects title is the workspace name: " + title());
      check(projects.remoteProjects.length === 4, "CE projects " + JSON.stringify(names(projects.remoteProjects)));
      shot("w1_ce_projects");
      waiting = true;
      tap("merginProjectButton_dummy-points");   // download
      break;
    case 2:
      check(lastOk, "downloaded dummy-points");
      panel.open();
      break;
    case 3:
      check(panel.page === "home", "Home tab once a project is on the device (page " + panel.page + ")");
      check(panel.homeModel.length === 1 && panel.homeModel[0].opened && panel.homeModel[0].group === "Currently open",
            "Home: dummy-points currently open " + JSON.stringify(panel.homeModel));
      check(projects.localProjects.length === 1 && projects.localProjects[0].version !== "", "registry " + JSON.stringify(projects.localProjects));
      shot("w2_home");
      tap("merginHomeMore_dummy-points");
      break;
    case 4:
      check(item("merginAction_sync") !== null && item("merginAction_remove") !== null, "More options: sync and remove");
      shot("w3_more_options");
      tap("merginAction_remove");
      break;
    case 5:
      shot("w4_confirm_remove");
      tap("merginConfirmRemove");
      break;
    case 6: {
      const dir = projects.localDir("mergin", "dummy-points");
      check(!QfFileUtils.fileExists(dir + "/.mergin/mergin.json") && !QfFileUtils.fileExists(dir + "/dummy-points.qgs"), "project files removed");
      check(projects.localProjects.length === 0, "registry empty");
      check(qgisProject.fileName === projects.homeProjectPath(), "home stub open after removal");
      const p = panel.projectsModel.filter(function (x) { return x.name === "dummy-points"; })[0];
      check(p && !p.downloaded, "Projects tab shows dummy-points as on the server again");
      if (!panel.opened) panel.open();
      shot("w5_removed");
      break;
    }
    case 7:
      panel.showPage("account");
      shot("w6_ce_account");
      tap("merginSignOutRow");
      check(!client.loggedIn && workspaces.workspaces.length === 0, "signed out, workspaces cleared");
      client.setServerUrl("http://127.0.0.1:5055");
      waiting = true;
      client.login("sarah", "Sarah-Pass-123", false);
      break;
    case 8:
      check(JSON.stringify(workspaces.workspaces.map(function (w) { return w.name; })) === '["documentation","my-team","sarah"]', "mock: three workspaces");
      check(workspaces.activeName === "my-team", "preferred workspace my-team: " + workspaces.activeName);
      check(title() === "my-team", "title " + title());
      check(JSON.stringify(names(projects.remoteProjects)) === '["my-team/A walk along the river","my-team/trees-and-hedges","my-team/street-lights"]',
            "my-team projects " + JSON.stringify(names(projects.remoteProjects)));
      shot("w7_my_team_projects");
      item("merginAvatar").children[1].clicked(null);   // MouseArea of the avatar
      break;
    case 9:
      check(panel.page === "account", "avatar opens the account page");
      shot("w8_account");
      tap("merginWorkspaceRow");
      break;
    case 10:
      check(panel.page === "workspaces" && title() === "Select workspace", "Select workspace page");
      check(item("merginWorkspace_my-team").current, "active workspace highlighted");
      shot("w9_select_workspace");
      item("merginWorkspace_documentation").children[1].clicked(null);
      break;
    case 11:
      check(workspaces.activeName === "documentation" && title() === "documentation", "switched to documentation");
      check(JSON.stringify(names(projects.remoteProjects)) === '["documentation/survey-template","documentation/land-use-demo"]',
            "documentation projects " + JSON.stringify(names(projects.remoteProjects)));
      shot("w10_documentation_projects");
      item("merginSearchField").text = "land";
      break;
    case 12:
      check(panel.projectsModel.length === 1 && panel.projectsModel[0].name === "land-use-demo", "search filters the list");
      shot("w11_search");
      item("merginSearchField").text = "";
      tap("merginTab_home");
      break;
    case 13:
      check(panel.page === "home", "Home tab");
      shot("w12_home_empty");
      log("RESULT failures=" + failures);
      log("DONE");
      Qt.quit();
      break;
    }
    step++;
  }
}
