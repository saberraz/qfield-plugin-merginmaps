import QtQuick

// Test double for QField's `settings` (QfSettings).
QtObject {
  property var data: ({})
  function value(key, def) { return data.hasOwnProperty(key) ? data[key] : def; }
  function valueBool(key, def) { return data.hasOwnProperty(key) ? (data[key] === true || data[key] === "true") : def; }
  function setValue(key, v) { data[key] = v; }
  function remove(key) { delete data[key]; }
}
