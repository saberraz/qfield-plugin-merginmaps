# QField Mergin Maps Sync Plugin - AI Developer Instructions

## 1. Project Overview
You are an expert Qt/QML and JavaScript developer. Your task is to develop a third-party **QField app plugin** that lets Mergin Maps users use QField instead of Mergin Maps mobile for data collection and syncing.

The plugin will allow QField users to:
1. Connect to a Mergin Maps server (default: `https://app.merginmaps.com`, but must support custom server URLs).
2. Authenticate/Log in to their Mergin Maps account.
3. Browse and download Mergin Maps projects to their local device.
4. Synchronize local offline changes (edits made in QField) back and forth with the Mergin Maps server, interoperating with Mergin Maps mobile and the QGIS Mergin plugin.

## 2. Hard Constraints (verified against QField source, v4.3.6 and master)
* **QField plugins are QML/JavaScript only.** No C++ and no native libraries, so `geodiff` cannot be linked natively. Instead, geodiff is **compiled to plain JavaScript** (see 4B). Do not propose C++ plugin code or companion apps unless the user asks.
* **Qt's JS engine (V4) is ES2016 with no `WebAssembly`, `globalThis`, `performance`, `BigInt` or `TextDecoder`.** Any third-party JS must be transpiled (Babel) and shimmed.
* **One install, no QField fork.** This is the "least disruptive" route: an app plugin installed from a zip URL via QField Settings > Plugins.
* **File I/O sandbox:** `QfFileUtils.readFileContent()` / `writeFileContent()` and multipart `file://` uploads only work for paths **inside the currently open project's directory** (`isWithinProjectDirectory`). Anything the plugin must persist on disk (e.g. base copies of GeoPackages) lives in a hidden subfolder of the project, e.g. `<project>/.mergin/`.
* **Target:** QField >= 4.3 (4.3.6 ships Qt 6.10.3). Use `import org.qfield` and `import Theme`; they work on both 4.3.x and master. Singletons are available as `QfFileUtils`, `QfLayerUtils`, `QfProjectUtils`, `QfFeatureUtils` (legacy names without `Qf` also exist).
* **Check APIs against the release tag, not master.** For example, `QfFileUtils.fileSize()` exists only on master; in 4.3.6 use `getFileInfo(path).fileSize`.

## 3. QField APIs the plugin relies on
* `iface.createHttpRequest()`: `QfXmlHttpRequest`, an XHR-like object routed through QGIS's network manager (proxy aware). Supports custom headers, `QByteArray`/string/JSON bodies, multipart with `file://` values, progress callbacks, timeouts.
  * **Caveat: never pass a plain JS object to `send()`.** It arrives as a `QJSValue` and is sent as `{"value": null}`. Send `JSON.stringify(obj)` with an explicit `Content-Type: application/json`, as `MerginClient.rawRequest` does.
  * **Caveat:** it always decodes response bodies as UTF-8 (`response` is parsed JSON or text), so it **cannot download binary files**. For binary downloads use Qt's built-in QML `XMLHttpRequest` with `responseType = "arraybuffer"` and pass the `ArrayBuffer` to `QfFileUtils.writeFileContent()`.
* `iface.importUrl(url, title, loadOnImport)`: downloads and imports a zip/project. It **cannot set auth headers**.
* `iface.loadFile(path)`, `iface.reloadProject()`, `iface.clearProject()`: load, reload, and unload projects.
  * **Do not use `clearProject()` before file I/O.** With no open project, every `QfFileUtils` read/write is refused.
  * **To release GeoPackages, load an empty stub project stored in the same folder as the real project** (`<project>/sync-stub.qgs`, or similar). This merges and removes the `-wal` file and keeps the folder accessible. Reload the real project afterwards. Verified in QField 4.3.6.
* **GeoPackage WAL:** right after an edit, the change is only in `<file>.gpkg-wal`. QField's flusher merges it into the `.gpkg` a few seconds later. **Never read a `.gpkg` while its layers are loaded.**
* `QfFileUtils.readFileContent()` returns an `ArrayBuffer`; `writeFileContent(path, ArrayBuffer)` writes one. There is **no copy, move or rename**, so writes are not atomic.
* **Sandbox rules (QField 4.3, `qffileutils.cpp`):**
  * `readFileContent`, `writeFileContent`, `getFileInfo`, `fileChecksum`: only inside the open project's folder.
  * `fileExists`: anywhere, but **false for folders**.
  * `deleteFiles` (`isDeletable`): only **folders whose direct parent is `Created Projects`** (or Imported Projects/Datasets) and **media files** (pdf, png, jpg, jpeg, mp4, mp4a, mp3). Anything else is refused, with only a log warning. The plugin can therefore not delete a `.gpkg`, `.txt`, `.json`, … ; `MerginSync.remove()` truncates such files instead.
  * A proper fix would be an upstream QField change letting plugins delete files inside the open project's folder (the same rule as `writeFileContent`).
* JSON arrays parsed by `QfXmlHttpRequest` arrive as Qt sequence objects: `Array.isArray()` is false. Use `MerginUtils.toArray()`.
* `QfProjectUtils.createProject(options)`: creates `<appDir>/Created Projects/<title sanitised to [A-Za-z0-9_]>/<same>.qgz` (adds `_2`, `_3` if taken). The plugin uses it to create each Mergin project's folder (see A2).
* `QfLayerUtils.loadVectorLayer(uri)`, `createFeatureIterator*()`, `addFeature()`, `deleteFeature()`: row-level access to GeoPackage layers, used for diffing and patching.
* `settings` (`QfSettings`): persistent key/value storage for server URL, username and token. Note that it is plain QSettings, not a secure keystore.
* `mainWindow.displayToast(message, type)`: user-facing notifications. `iface.logMessage()` writes to the QField message log.

## 4. Architecture
All code is QML + JS inside `plugin/` (the zip root).

### A. Mergin client (`plugin/qml/MerginClient.qml`)
* Session state (server URL, login name, username, email, token, expiry) is persisted in `settings` under `qfield-mergin/`.
* All REST calls go through `iface.createHttpRequest()`. Never block the UI thread. `createRequest` and `store` are injectable so tests can run outside QField.
* **Auth (mirrors Mergin mobile):**
  * `POST /v1/auth/login {login, password}` returns `session: {token, expire}` (default lifetime 12 h). Send `Authorization: Bearer <token>`.
  * `ensureAuth()` renews the token 5 min before expiry by logging in again. Renewal is silent if the password is remembered; otherwise it emits `authRequired`. Concurrent callers share one renewal.
  * `authRequest()` retries once after a 401.
  * `GET /v1/user/profile` validates a restored session. `GET /config` gives the version and `sso_enabled`.
* **Password storage:** only when the user ticks "Remember password". A plugin has no keychain, so it is stored unencrypted in QField settings, and only after the server has accepted it. Logging out or changing server clears it.
* **Login page = mobile's `MMLoginPage`:** "Email or username", "Password" (show/hide), "Forgot password?" (opens `<server>/login/reset`), "Sign in", then "Don't have an account?" + "Sign up", and the server in the footer, which opens a "Change server" drawer. The default server is `https://app.merginmaps.com`.
  * "Sign up" follows mobile's `canSignUp`: only when `/config` has `server_type` `saas` or `ee` **and** `user_self_registration: true` (app.merginmaps.com: yes; CE: never). Before `/config` answers it is shown only for the default server.
  * Target (`MerginUtils.signUpUrl`): SaaS → `<server>/register` (mobile signs up in-app; the plugin opens the dashboard's page in the browser); EE → the server root, as mobile does.
  * Verified by `tests/qfield/login_e2e` (needs internet for app.merginmaps.com's `/config`; "Sign up" is not clicked because it opens a browser).
* **SSO is not supported** (issue #2). Mobile uses OAuth2 auth code + PKCE via `/v2/sso/config`, `/v2/sso/connections`, `/v2/sso/authorize`, `/v2/sso/token`, redirecting to the `https://hello.merginmaps.com/mobile/sso-redirect` app link (owned by the Mergin Maps app) or a localhost:10042 listener on desktop; neither can reach a QField plugin.
  * Feasible route on Android/iOS: QField registers `qfield://` and emits incoming URLs as the `iface.executeAction(url)` signal, so a plugin can receive `qfield://merginmaps-sso?code=…` (QField itself only handles types `local`/`cloud`). Needs the Mergin server to allow that redirect URI. Desktop QField does not register the scheme: needs a server device-code (RFC 8628) or "copy this code" flow.
  * Open problem: V4 has no secure random source for the PKCE verifier/state.
* Mergin REST reference: https://github.com/MerginMaps/server (API spec) and the mobile app's `merginapi.cpp` (https://github.com/MerginMaps/mobile).

### A1. Workspaces (`plugin/qml/MerginWorkspaces.qml`)
* `GET /v1/user/profile` (`preferred_workspace`, `name`) then `GET /v1/workspaces` (`[{id, name, role, disk_usage, storage, project_count}]`).
* Active workspace = mobile's rule (`MerginUtils.chooseWorkspace`): the only one; else the last used (settings `qfield-mergin/lastWorkspace/<server|user>`) if still listed; else the server's preferred; else the first.
* Community Edition always has exactly one workspace; app.merginmaps.com and Enterprise Edition users can belong to several.
* `setActive(id)` persists the choice and emits `workspaceSwitched`; the Projects tab lists only `only_namespace=<active name>`.
* `tests/server/mock_multi_workspace.py` mocks a 3-workspace account (port 5055, `sarah` / `Sarah-Pass-123`), since the local CE server cannot have several.

### A2. Projects (`plugin/qml/MerginProjects.qml`)
* **Storage (since 0.5):** one top-level folder per Mergin project, so it can be deleted (see the sandbox rules in section 3):
  `<QField>/Created Projects/mm_<workspace>_<project>/` made by `QfProjectUtils.createProject({title: "mm <ws> <name>", basemap: "blank"})`.
  * The folder's own stub `mm_<ws>_<name>.qgz` is never synchronised (sync skips it; a server file with that path aborts the download).
  * Loading the stub (`withProjectReleased`) makes the folder writable and releases its GeoPackages; used by download, open and sync.
  * A separate "home" stub (`Created Projects/Mergin_Maps/Mergin_Maps.qgz`, settings `qfield-mergin/homeProject`) is loaded while a project folder is deleted.
  * 0.4 downloads (`Mergin_Maps/projects/<ws>/<name>/`) are still found, opened and synced, but cannot be removed.
* **Registry** (settings `qfield-mergin/localProjects`, JSON): `[{server, namespace, name, dir, stub, version, size, updated}]`. It drives the Home tab and is the source of truth for completeness: `version` is cleared when a download starts and set after `mergin.json` is written. (The marker file cannot be deleted, and `getFileInfo` is sandboxed.)
* **Remove from device:** load the home stub, then `deleteFiles([dir])`; drop the registry entry and `localVersion` key. Server copy untouched.
* **List:** `GET /v1/project/paginated?page=1&per_page=100&order_params=namespace_asc,name_asc&only_namespace=<workspace>`. Stale responses after a workspace switch are dropped.
* **Download (mirrors mobile):**
  1. `GET /v1/project/<ns>/<name>` (files with path, size, sha1 `checksum`, version).
  2. Create the project folder if needed, mark the registry entry incomplete, load the folder's stub.
  3. Fetch each file with `GET /v1/project/raw/<ns>/<name>?file=<urlencoded>&version=vN` in 10 MB `Range` chunks, using Qt `XMLHttpRequest` for binary.
  4. Assemble the file in memory and write it once, because QfFileUtils has no append. Very large files are memory bound.
  5. Verify the SHA-1 with `QfFileUtils.fileChecksum(path, 2)` and retry once.
  6. Write a base copy of every `.gpkg` to `.mergin/<path>`.
  7. Write `.mergin/mergin.json` (project info, same format as mergin-client and mobile) **last**, then record the version in the registry.
  8. Load the project's root `.qgs`/`.qgz`.
* **Safety:** server file paths are rejected unless `isSafeRelativePath` holds (no `..`, absolute paths or empty segments), and workspace/project names must pass `isSafeName`.
* **For Phase 5 sync:**
  * QField writes a `<project>.qgz.png` thumbnail next to every project it opens. Sync must **ignore** it, along with the `.mergin/` folder (the server blacklists that).
  * The server rejects files without an extension ("Unsupported file type", e.g. `DCIM/LICENSE`).

### B. Sync engine (real geodiff compiled to JS)
* **Engine:** geodiff + SQLite, compiled with Emscripten `-sWASM=0` (wasm2js), transpiled to ES2016 with Babel, and wrapped as a QML JS library.
  * **Built, tested and released in the separate repo https://github.com/saberraz/geodiff-js** (build script, pinned toolchain, geodiff's C++ suite in Qt, differential fuzzing vs pygeodiff, QML robustness tests, daily release CI). The plugin only vendors `plugin/js/geodiff_inc.js` from a release; `plugin/js/geodiff_inc.json` records the release, versions and checksums. `.github/workflows/update-geodiff.yml` opens a PR when a new geodiff-js release appears.
  * The fallback, if `-sWASM=0` is removed upstream, is geodiff-js's `build_fallback.sh`: a normal wasm build, binaryen lowering, and standalone `wasm2js` loaded through `instantiateWasm`.
  * SQLite needs `SQLITE_ENABLE_RTREE` and `SQLITE_MUTEX_NOOP`. geodiff needs geodiff-js's `patches/0001-build-with-emscripten.patch` (the commit of the upstream draft PR MerginMaps/geodiff#271) until upstream merges it.
  * **Upstream rule:** no changes (PRs, issues, comments) on MerginMaps/geodiff without the user's explicit permission each time; code changes go as PRs to the fork saberraz/geodiff.
  * Known upstream bug: `GEODIFF_changesCount` lets a `GeoDiffException` escape on a truncated changeset (MerginMaps/geodiff#272; native callers abort). In JS it is a catchable exception; `geodiffworker.js` turns it into an error result via the exported `getExceptionMessage`.
  * **Use `-sWASMFS=1 -sENVIRONMENT=web`, never the default MEMFS.**
    * MEMFS directories are JS objects with constant property delete/re-add, which triggers a V4 segfault (QTBUG-147153). QField only patches that from 4.3.0, so **QField >= 4.3.0 is a hard minimum**.
    * `web` is needed so randomness uses the shimmed `crypto.getRandomValues`.
  * Pin emsdk, Babel and SQLite. Ship the built artefact with a checksum.
* **Usage:** write bytes into Emscripten's in-memory FS (`FS.writeFile`), call the normal geodiff C API through `ccall` (`GEODIFF_createChangeset`, `applyChangeset`, `rebase`, ...), then read the results back with `FS.readFile`.
* **Threading:** run geodiff in a `WorkerScript`.
  * Load it with `Qt.include("geodiff_inc.js")`; `.import` does not work in the worker.
  * Workers cannot read files themselves (QField doesn't set `QML_XHR_ALLOW_FILE_READ`). The UI thread reads files with `QfFileUtils` and posts them.
  * **WorkerScript messages drop ArrayBuffers/TypedArrays.** Send bytes as **arrays of ~8 KB "binary string" chunks**. A single multi-MB string message hangs Qt.
  * In V4, `String.fromCharCode.apply(null, typedArray)` returns zeros. Convert with `Array.prototype.slice.call(...)` first.
* **Model:** mirrors Mergin's design. Keep a **base** copy of each GeoPackage in `<project>/.mergin/` (the server ignores `.mergin/`) next to the **local** working copy, plus the project's server version and file metadata.
* **Push:** `createChangeset(base, local)`, then upload it with the push transaction API.
* **Pull:** `applyChangeset` on base, then `rebase` local edits on top. Write the conflict file the way Mergin mobile does.
* **Safety (fail closed, never best-effort):**
  * Release the files via the stub project before reading.
  * **Before push**, verify that applying the changeset to a copy of base reproduces local (0 changes).
  * **After pull/rebase**, run `PRAGMA integrity_check` and check that new local equals new base plus the rebased changes, before anything is overwritten.
  * Back up base and local to `.mergin/backup/` and keep a sync journal, so a sync interrupted mid-write is restored on next start.
  * On any mismatch, abort and leave the user's files untouched.
* **References:** https://github.com/MerginMaps/geodiff (C API: `geodiff/src/geodiff.h`). `pygeodiff` is the reference implementation used in tests.

### B2. Sync implementation notes (`plugin/qml/MerginSync.qml`, `GeodiffWorker.qml`, `js/syncplan.js`)
* **Algorithm:** follows mergin-client.
  * Pull downloads changed files in full; GeoPackages with local edits get `rebase(base, server, local, conflicts)`. Conflict file names match mergin-client: `<name> (edit conflict, <user> vN).json` and `<name> (conflicted copy, <user> vN).<ext>`.
  * Push uses the v1 transaction. Updated GeoPackages send a `diff` with `checksum` = base checksum, and the server applies the diff and computes the new checksum.
  * On "Version mismatch", pull again and retry once.
* **Safety:**
  * Every changeset is verified before upload: base + diff must equal local.
  * Local files are backed up before a pull overwrites them and restored if the pull fails. Once `mergin.json` is written the pull is committed.
  * A watchdog aborts stalled binary transfers; Qt's `XMLHttpRequest` has no timeout.
* **Files removed on the server:** plugins cannot delete non-media files, so the local copy is truncated and recorded in `.mergin/removed.json` (`{path: sha1}`). While its content still matches, it is left out of local changes, so it is not pushed back as a new file (`sync_e2e` scenario 6). The same truncation applies to backups and temporary files.
* **File discovery:** there is no directory listing for plugins. `QfLocalFilesModel` (recursive) finds *new* files of the types QField knows (data, images, audio, video, txt); files already in the metadata are always checked by path. A new file with an unknown extension is not pushed.
* **Binary transfers:** binary uploads (push chunks) use Qt `XMLHttpRequest`, because QfXmlHttpRequest receives an ArrayBuffer as a QJSValue.
* **User-Agent:** QField's network stack overrides `User-Agent`. Versions show `qfield|v4.3.6|…| QGIS/…` in the dashboard, which already identifies QField.
* **UI during sync:** the open project is swapped for its folder's stub to release its files. A map snapshot (`grabToImage` of `iface.mapCanvas()`) is shown with a Mergin-style progress card, and the toolbar Sync button spins (mobile's 720° animation).
* **Look:** Mergin Maps mobile icons are in `plugin/icons` (GPL-2.0+, see README there). Design tokens are in `plugin/js/style.js`.

### B3. Position tracking (`plugin/qml/MerginTracking.qml`, `js/trackingplan.js`)
* **Rule: QField's tracking behaviour is not changed** (dialog, form, M value type, background handling). The plugin only supplies values and keeps tracking alive through a sync.
* **Mergin tracking layer:** line layer `tracking_layer` (EPSG:4326, LineStringZM) with `tracking_start_time`, `tracking_end_time`, `total_distance`, `tracked_by` and defaults `@tracking_start_time`, `@tracking_end_time`, `round($length, 2)`, `@mm_username` (older projects: `@mergin_username`). Project entry `Mergin/PositionTracking/TrackingLayer` (readable for `.qgs`; otherwise the layer is recognised by the four fields).
* **Variables:** in-memory project variables via `QfExpressionContextUtils.setProjectVariable(qgisProject, …)` (documented QField plugin API): `mm_username`, `mm_user_email`, `mm_full_name`, `mm_url`, `mm_project_name`, `mm_project_full_name`, `mm_project_version` + `mergin_*` aliases (as Mergin Maps mobile's `variablesmanager.cpp`). Set on project load and login. They vanish when the project is reloaded; the project file stays unchanged (verified).
* `@tracking_start_time` is set when QField's Tracking dialog (`iface.findItemByObjectName("trackerSettings")`) opens, so the form shows a start. Completion recomputes the four fields with `QfFeatureModel.resetAttributes(true)` (= `QgsVectorLayerUtils::createFeature`, the path mobile uses) with `@tracking_start_time` = first recorded point and `@tracking_end_time` = now. **`$length` there is ellipsoidal, in metres.** Fields the user set in the form (`trackingplan.userSetFields`) are kept.
* **Sync while tracking:** `MerginSync` calls `tracking.pauseForSync()` (QField `trackingModel.suspendUntilReplay()`, complete tracks, `projectInfo.saveTracker(layer)`) before the project swap, and `resumeAfterSync()` (`projectInfo.restoreTracker`, restore `tracker.startPositionTimestamp`, `trackingModel.startTracker(layer)` without a position) after it. The restored tracker rebuilds the line from the feature and appends. No positions are recorded during the sync (QField's background replay was tried: the position source is recreated when the trackers go, so its buffer misses that period).
* **Rebase renumbering:** a track inserted locally can get a new fid when a colleague inserted a feature with the same new id. After a sync the track is found by its stored start + `tracked_by` (`trackingplan.trackFilterExpression`); if not found, the tracker continues as a new feature, never on someone else's.
* **QField facts (4.3.6):**
  * "stop" deletes the tracker before emitting `layerInTrackingChanged(layer, false)` (the plugin polls fid and first-point time while a session runs); `suspendUntilReplay` emits nothing.
  * Creating a tracker restarts the positioning source, so QField often starts a session without a position: `startPositionTimestamp` is invalid and its "elapsed time" M values become epoch seconds. The plugin takes the first point's time from the position that produced the first vertex then.
  * QgsFeature has no `isValid` in QML (use the id: a feature not found has the null id).
  * Value types read from QML properties (e.g. `positionSource.positionInformation`) are live references: storing them in a JS array does not copy them.
* **Test:** `tests/qfield/tracking_e2e` (a `needs_gnss` marker makes `run_e2e.sh` start `nmea_server.py`, a simulated receiver on QField's TCP device, `QFIELD_POSITIONING_DEVICE`). It uses QField's real dialog and form, two syncs while tracking (the first after a colleague's track forces a rebase renumbering), then stop + sync. It checks the server copy (one track, start = first point, distance in metres, continuous M, partial upload kept, colleague's track intact, project file unchanged).

### C. UI (QML, `plugin/qml/MerginPanel.qml`)
* A toolbar button (`iface.addItemToPluginsToolbar`) opens the Mergin panel; a second one (Sync) appears when a Mergin project is open.
* Layout follows Mergin Maps mobile (https://merginmaps.com/docs/field/mobile-app-ui/#home):
  * signed out: server + login form (QField components);
  * **Home**: projects on this device, "Currently open" (forest card) then "Downloaded projects"; ⋮ opens "More options" (Synchronise project, Remove from device with confirmation);
  * **Projects**: the active workspace's server projects, titled with the workspace name; download button or ⋮;
  * search field on both tabs, bottom navigation (Home / Projects);
  * avatar (initials) → account page: name, email, server, Workspace row → "Select workspace", Manage Account (opens `<server>/dashboard/profile`), storage bar, Sign out. Close account is deliberately left out.
* objectNames used by tests: `merginProjectButton_<name>` (download), `merginProjectMore_<name>` / `merginHomeMore_<name>`, `merginAction_sync|remove`, `merginConfirmRemove`, `merginAvatar`, `merginWorkspaceRow`, `merginWorkspace_<name>`, `merginTab_home|projects`, `merginSearchField`, `merginPageTitle`, `merginSignOutRow`, plus the login fields.

## 5. Development Roadmap
When I ask you to start working, follow these phases sequentially:

* **Phase 1: Project Scaffolding**: plugin skeleton (`metadata.txt`, `main.qml`, icon, client/panel stubs), packaging script, server reachability check.
* **Phase 2: Authentication module**: login API, token persistence/refresh, login UI.
* **Phase 3: Project Management**: list projects, fetch metadata, download full projects into QField storage (stub-project bootstrap above), store base copies.
* **Phase 4 + 5 status (2026-10-22):** done.
  * geodiff-js runs in `GeodiffWorker`, and sync is implemented.
  * Verified by `tests/qfield/sync_e2e`: QField and an office user (mergin-client) in six scenarios, push, pull+rebase, conflict, no-op, server down then recovery, and a file deleted on the server, with an independent server/device check. Reset the server project first with `tests/server/reset_dummy_points.sh`.
* **Workspaces + Home/Projects UI (0.5.0, 2026-10-22):** done; verified by `tests/qml/tst_workspaces.qml` and `tests/qfield/workspaces_e2e` (CE + mock multi-workspace server).
  * Screencast: `docs/media/qfield-mergin-maps-sync-demo.mp4`, which includes the dashboard's feature-level edit log.
* **Phase 4: geodiff-js integration**: package the geodiff JS build into the plugin, add a WorkerScript wrapper with chunked transfer, implement the stub-project release/reload cycle, and validate continuously:
  * geodiff's gtest suite running in Qt's engine;
  * the differential fuzz harness against pygeodiff (now in geodiff-js, `tests/fuzz/`);
  * real-device benchmarks.
* **Phase 5: Full Sync Cycle**: push/pull transactions, apply remote changesets, rebase, conflict handling, the safety checks in 4B, and non-GeoPackage files (photos etc.) as whole-file uploads.
* **Phase 6: UI Polish & Testing**: progress bars, error states, offline handling.

## 6. Coding Guidelines
* QML/JS only. Keep pure helpers in `plugin/js/*.js` (`.pragma library`, no access to context properties like `iface`). Anything that needs `iface`, `settings` or `QfFileUtils` lives in QML objects.
* Asynchronous everything: callbacks/promises around `createHttpRequest()`, with no synchronous XHR.
* Log through `iface.logMessage()` with a `[Mergin]` prefix. Surface failures to the user with `mainWindow.displayToast(..., 'error')`.
* Validate every API used against the QField source of the minimum supported version before relying on it.
* QML gotchas found so far:
  * Property names must start with lowercase.
  * Don't redeclare `Item` properties (e.g. `layer`).
  * `QgsVectorLayer.featureCount` is not callable from QML.
  * XHR/`readFileContent` of a 0-byte file does not give a usable ArrayBuffer, so guard with `buf && buf.byteLength`.
* `iface.findItemByObjectName()` searches QField's QObject tree, so it **cannot find plugin items**; they are only visually reparented. Tests find the plugin by searching the visual children of `pluginsToolbar` for `objectName: "merginPluginButton"`, whose `panel` property exposes the live panel and client.
* **Tests:**
  * `tests/server/start_local_mergin.sh` starts a throwaway Mergin CE server (podman) on `127.0.0.1:5000` with user `fielduser` / `Field-Pass-123`.
  * `tests/qml/` holds unit and integration tests. Run them with `qmltestrunner -input tests/qml` (Qt 6.10). They use `XhrShim.js`, which, like the real QfXmlHttpRequest, rejects plain-object bodies, and `MockSettings.qml`.
  * `tests/server/prepare_test_projects.sh` seeds the server with 2 real projects (QField's bees and wastewater samples) and 2 dummy projects, using the official `mergin-client`.
    * Dummy `.qgs` files are generated from `tests/server/project_template.qgs`, a file QField itself wrote (QGIS 4.2.1). **Hand-written minimal QGIS XML loads but renders blank in QField**, because it lacks full CRS/extent definitions.
  * `tests/qfield/run_e2e.sh <name>` installs the built plugin into real QField and opens `tests/qfield/<name>/<name>.qgs`.
    * The test logic runs as a project plugin (`<name>.qml`) or, when it must survive project switches, as a test-only **app plugin** in `tests/qfield/<name>/driver/`.
    * Screenshots are taken from the X display when the test logs `E2E SHOT <name>`, because `grabToImage` is refused there. The capture happens ~0.5 s later, so log the shot in one driver step and act in the next.
    * `RECORD=<mp4> RECORD_SIZE=540x960` records a screencast (Fedora's ffmpeg: `libopenh264`, no libx264).
  * `WEB=1 tests/server/start_local_mergin.sh` also runs the Mergin web dashboard (frontend + nginx proxy) on `127.0.0.1:8080`.
    * Mount `projects` with SELinux `:z`, not `:Z`: `:Z` locks the other container out.
    * Restart `mm-proxy` whenever `mm-server` restarts; nginx caches its IP.
  * `tests/qfield/record_sync_screencast.sh` records QField (part 1) and the dashboard (part 2, `tests/qfield/web/dashboard_demo.py`, Chrome driven over CDP by `web/cdp.py`), then composes them with ffmpeg.
    * Chrome must be forced to X11 (`--ozone-platform=x11`, no `WAYLAND_DISPLAY`) or it opens on the user's desktop.
    * Chrome needs password-manager prefs off, or its save-password bubble appears in the recording.
  * `tests/qfield/demo` is the screencast driver. It operates the real UI at human pace, with a touch marker and captions parented to the popup `QQuickOverlay`.
* **Testing in real QField:** `tests/qfield/run_in_qfield.sh` runs the QField Linux AppImage (extracted to `$S/qfield-app/squashfs-root`) with an isolated HOME. It pre-grants plugin permissions, auto-opens a project, and **disables Sentry** (`enableInfoCollection=false`, which must be set before the first launch).
  * The AppImage only ships the xcb platform plugin, so run it on a nested `Xwayland :99` locally or `Xvfb :99` in CI.
  * Feasibility notes from the original spike are in geodiff-js `docs/research-notes.md`.
* **CI** (`.github/workflows/ci.yml`): unit tests; CE server in podman + mock multi-workspace server + integration tests; QField 4.3.6 AppImage on Xvfb running all `tests/qfield/*_e2e` (screenshots uploaded as artifacts). `release.yml` publishes on tag `v<version>` (must match `plugin/metadata.txt`).
* **Packaging:** `scripts/package.sh` → `dist/qfield-plugin-merginmaps-v<version>.zip`. QField names the installed plugin folder after the zip minus `-v<version>`, taking the name from GitHub's Content-Disposition, so the stable `releases/latest/download/qfield-plugin-merginmaps.zip` URL and versioned zips install to the same folder.
