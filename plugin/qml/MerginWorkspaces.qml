import QtQuick

import "../js/merginutils.js" as MerginUtils

// Workspaces of the signed-in user, as in Mergin Maps mobile. Community Edition servers have a single workspace;
// app.merginmaps.com and Enterprise Edition users can belong to several and switch between them.
// The active workspace filters the "Projects" tab (only_namespace=<workspace name>).
QtObject {
  id: ws

  property MerginClient client

  // [{ id, name, role, diskUsage, storage, projectCount }]
  property var workspaces: []
  property int activeId: -1
  readonly property var active: {
    for (let i = 0; i < workspaces.length; i++) {
      if (workspaces[i].id === activeId) return workspaces[i];
    }
    return null;
  }
  readonly property string activeName: active ? active.name : ""
  property bool loading: false
  property string error: ""

  // Profile details shown on the account page
  property string fullName: ""

  signal workspaceSwitched()

  // last used workspace is remembered per server and user
  function lastUsedKey() {
    return client.settingsPrefix + "lastWorkspace/" + encodeURIComponent(client.serverUrl + "|" + client.username);
  }

  function clear() {
    workspaces = [];
    activeId = -1;
    fullName = "";
    error = "";
  }

  // Loads the profile (preferred workspace, name) and the workspace list, then picks the active workspace.
  function refresh(callback) {
    loading = true;
    error = "";
    client.authRequest("GET", "v1/user/profile", undefined, function (profile) {
      const preferred = profile && profile.preferred_workspace !== undefined && profile.preferred_workspace !== null ? Number(profile.preferred_workspace) : -1;
      fullName = profile && profile.name ? String(profile.name) : "";
      client.authRequest("GET", "v1/workspaces", undefined, function (list) {
        loading = false;
        workspaces = MerginUtils.toArray(list).map(function (w) {
          return {
            id: Number(w.id), name: String(w.name), role: String(w.role || ""),
            diskUsage: Number(w.disk_usage || 0), storage: Number(w.storage || 0), projectCount: Number(w.project_count || 0)
          };
        }).sort(function (a, b) { return a.name.localeCompare(b.name); });
        const lastUsed = client.store ? Number(client.store.value(lastUsedKey(), -1)) : -1;
        const chosen = MerginUtils.chooseWorkspace(workspaces, lastUsed, preferred);
        client.log(workspaces.length + " workspace(s), active " + chosen);
        if (chosen !== activeId) {
          activeId = chosen;
          workspaceSwitched();
        }
        if (callback) callback(true, "");
      }, function (message) {
        loading = false;
        error = message;
        if (callback) callback(false, message);
      });
    }, function (message) {
      loading = false;
      error = message;
      if (callback) callback(false, message);
    });
  }

  function setActive(id) {
    if (!workspaces.some(function (w) { return w.id === id; })) return;
    if (client.store) client.store.setValue(lastUsedKey(), id);
    if (id !== activeId) {
      activeId = id;
      client.log("Switched to workspace " + activeName + " (" + id + ")");
      workspaceSwitched();
    }
  }
}
