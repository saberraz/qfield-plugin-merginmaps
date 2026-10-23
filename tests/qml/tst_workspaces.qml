import QtQuick
import QtTest

import "../../plugin/qml"
import "../../plugin/js/merginutils.js" as MerginUtils
import "XhrShim.js" as XhrShim

// Workspace selection and switching.
//  - MerginUtils.chooseWorkspace: same rule as Mergin Maps mobile
//  - MerginWorkspaces against the mock multi-workspace server (tests/server/mock_multi_workspace.py, port 5055)
//  - MerginWorkspaces against the local Community Edition server (single workspace "mergin", port 5000)
TestCase {
  id: tc
  name: "Workspaces"

  function test_chooseWorkspace() {
    const many = [{ id: 1, name: "a" }, { id: 2, name: "b" }, { id: 3, name: "c" }];
    compare(MerginUtils.chooseWorkspace([], 2, 2), -1, "no workspace");
    compare(MerginUtils.chooseWorkspace([{ id: 7, name: "only" }], 2, 3), 7, "single workspace always wins");
    compare(MerginUtils.chooseWorkspace(many, 3, 2), 3, "last used beats preferred");
    compare(MerginUtils.chooseWorkspace(many, 9, 2), 2, "stale last used falls back to preferred");
    compare(MerginUtils.chooseWorkspace(many, -1, 9), 1, "unknown preferred falls back to first");
  }

  function test_initials_and_search() {
    compare(MerginUtils.initials("Sarah Okoro", "sarah"), "SO");
    compare(MerginUtils.initials("", "fielduser"), "FI");
    compare(MerginUtils.initials("Madonna", "x"), "M");
    verify(MerginUtils.matchesSearch("", "ns", "anything"));
    verify(MerginUtils.matchesSearch("RIVER", "my-team", "A walk along the river"));
    verify(MerginUtils.matchesSearch("my-team/a w", "my-team", "A walk along the river"));
    verify(!MerginUtils.matchesSearch("hedges", "my-team", "A walk along the river"));
  }

  Component {
    id: clientComponent
    MerginClient {
      createRequest: XhrShim.create
      store: MockSettings {}
    }
  }
  Component {
    id: workspacesComponent
    MerginWorkspaces {}
  }
  SignalSpy { id: loginSpy; signalName: "loginFinished" }

  function login(url, user, pass) {
    const c = createTemporaryObject(clientComponent, tc);
    c.setServerUrl(url);
    loginSpy.clear();
    loginSpy.target = c;
    c.login(user, pass, false);
    loginSpy.wait(10000);
    verify(c.loggedIn, "logged in to " + url);
    return c;
  }

  function refreshed(w) {
    let done = null;
    w.refresh(function (ok, message) { done = { ok: ok, message: message }; });
    tryVerify(function () { return done !== null; }, 10000);
    verify(done.ok, done.message);
  }

  function listProjects(c, workspace) {
    let result = null;
    c.authRequest("GET", "v1/project/paginated?page=1&per_page=100&only_namespace=" + encodeURIComponent(workspace), undefined,
                  function (r) { result = r.projects.map(function (p) { return p.namespace + "/" + p.name; }); },
                  function (m) { result = "error " + m; });
    tryVerify(function () { return result !== null; }, 10000);
    return result;
  }

  function test_multi_workspace_account() {
    const c = login("http://127.0.0.1:5055", "sarah", "Sarah-Pass-123");
    const w = createTemporaryObject(workspacesComponent, tc, { client: c });
    refreshed(w);
    compare(w.workspaces.map(function (x) { return x.name; }), ["documentation", "my-team", "sarah"]);
    compare(w.activeName, "my-team", "server's preferred workspace on first use");
    compare(w.active.role, "owner");
    compare(w.fullName, "Sarah Okoro");
    compare(listProjects(c, w.activeName), ["my-team/A walk along the river", "my-team/trees-and-hedges", "my-team/street-lights"]);

    w.setActive(1);
    compare(w.activeName, "documentation");
    compare(listProjects(c, w.activeName), ["documentation/survey-template", "documentation/land-use-demo"]);

    // the choice survives a restart (new object, same settings)
    const w2 = createTemporaryObject(workspacesComponent, tc, { client: c });
    refreshed(w2);
    compare(w2.activeName, "documentation", "last used workspace restored");
  }

  function test_community_edition_single_workspace() {
    const c = login("http://127.0.0.1:5000", "fielduser", "Field-Pass-123");
    const w = createTemporaryObject(workspacesComponent, tc, { client: c });
    refreshed(w);
    compare(w.workspaces.length, 1);
    compare(w.activeName, "mergin");
    verify(listProjects(c, "mergin").length >= 4);
  }
}
