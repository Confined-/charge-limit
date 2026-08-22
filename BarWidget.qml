import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "confined.charge-limit"

  readonly property int pollIntervalSec: Math.max(5, parseInt(setting("pollIntervalSec", 30), 10) || 30)
  readonly property bool applyAtBootPref: setting("applyAtBoot", true) === true

  readonly property string helperBin: "/usr/local/bin/battery-charge-limit"
  readonly property string helperVersion: "3"
  readonly property string hookName: "confined.charge-limit.sh"
  readonly property string pluginDir: {
    var p = root.scriptPath()
    return p.substring(0, p.lastIndexOf("/"))
  }
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/battery-charge-limit"

  readonly property int limitEnd: 80
  readonly property int limitStart: 70

  property bool probed: false
  property bool supported: false
  property bool granted: false
  property bool helperOutdated: false
  property int limit: -1
  property int startThreshold: -1
  property int batteryPct: -1
  property bool charging: false
  property bool applying: false
  property string lastError: ""
  property int pendingEnd: -1
  property int pendingStart: -1
  property bool granting: false

  readonly property bool limitActive: root.limit > 0 && root.limit < 100

  function num(value, fallback) {
    var n = Number(value)
    return isFinite(n) ? n : fallback
  }

  // ---- Bar presentation ----
  readonly property string barText: "\uF0E7"

  readonly property string barTooltip: {
    if (!root.probed) return "Battery charge limit…"
    if (!root.supported) return "Battery charge limit not supported on this hardware"
    var bat = root.batteryPct >= 0 ? " • Battery " + root.batteryPct + "%" + (root.charging ? " ⚡" : "") : ""
    var state = root.limitActive
      ? "Charge limit on (" + root.limit + "/" + Math.max(0, root.startThreshold) + ")"
      : "Charge limit off"
    var err = root.lastError !== "" ? " • " + root.lastError : ""
    return state + bat + err + " • Click to toggle"
  }

  // ---- Script path resolution ----
  function scriptPath(name) {
    var url = String(Qt.resolvedUrl(name || "helper.sh"))
    if (url.indexOf("file://localhost/") === 0) url = url.substring("file://localhost/".length)
    else if (url.indexOf("file://") === 0) url = url.substring("file://".length)
    try {
      return decodeURIComponent(url)
    } catch (e) {
      return url
    }
  }

  // ---- Status polling ----
  function refresh() {
    getStatus.command = ["bash", root.scriptPath(), "get"]
    if (!getStatus.running) getStatus.running = true
  }

  function onGetFinished(text) {
    var raw = String(text || "").trim()
    if (!raw) {
      if (root.probed && root.lastError === "") root.lastError = "status unavailable"
      return
    }
    var data
    try {
      data = JSON.parse(raw)
    } catch (e) {
      if (root.probed) root.lastError = "bad status response"
      return
    }
    if (!data || data.ok !== true) {
      if (root.probed) root.lastError = String(data && data.error ? data.error : "status failed")
      return
    }
    var wasGranted = root.granted
    root.probed = true
    root.supported = data.supported === true
    var nowGranted = data.installed === true
    root.helperOutdated = nowGranted && String(data.version || "") !== root.helperVersion
    root.granted = nowGranted
    root.lastError = ""
    if (Array.isArray(data.batteries) && data.batteries.length > 0) {
      root.limit = root.num(data.batteries[0].end, -1)
      root.startThreshold = root.num(data.batteries[0].start, -1)
      root.batteryPct = root.num(data.batteries[0].capacity, -1)
      root.charging = data.batteries[0].charging === true
    } else {
      root.limit = -1
      root.startThreshold = -1
      root.batteryPct = -1
      root.charging = false
    }
    if (nowGranted && !wasGranted && !root.helperOutdated) Qt.callLater(root.syncBootPref)
    Qt.callLater(root.flushPending)
  }

  // ---- Toggling ----
  function flushPending() {
    if (root.pendingEnd >= 0 && !root.applying && root.granted && root.supported && !root.helperOutdated) {
      var e = root.pendingEnd
      var s = root.pendingStart
      root.pendingEnd = -1
      root.pendingStart = -1
      root.applyLimits(e, s)
    }
  }

  function toggleLimit() {
    if (!root.supported) return
    if (root.limitActive) root.applyLimits(100, 0)
    else root.applyLimits(root.limitEnd, root.limitStart)
  }

  function clampLimit(value) {
    var n = Math.round(Number(value))
    if (!isFinite(n)) return -1
    return Math.max(20, Math.min(100, n))
  }

  function applyLimits(endValue, startValue) {
    var end = root.clampLimit(endValue)
    if (end < 0) return
    var start = Math.round(Number(startValue))
    if (!isFinite(start) || start < 0) start = 0
    if (start >= end) start = Math.max(0, end - 5)
    if (!root.granted || root.helperOutdated) {
      root.pendingEnd = end
      root.pendingStart = start
      if (!root.granting) root.requestGrant()
      return
    }
    if (setStatus.running) {
      root.pendingEnd = end
      root.pendingStart = start
      return
    }
    root.applying = true
    root.lastError = ""
    setStatus.command = ["sudo", "-n", root.helperBin, "set", String(end), String(start)]
    setStatus.running = true
  }

  function onSetFinished(text) {
    root.applying = false
    var raw = String(text || "").trim()
    if (raw === "") {
      if (root.granted && !root.helperOutdated) {
        root.granted = false
        root.lastError = "Permission required — click again to re-grant"
      }
      return
    }
    var data = null
    try {
      data = JSON.parse(raw)
    } catch (e) {
      data = null
    }
    if (!data) {
      root.lastError = "Unreadable helper response"
      return
    }
    if (data.ok !== true) {
      root.lastError = String(data.error || "set failed")
      return
    }
    if (Array.isArray(data.batteries) && data.batteries.length > 0) {
      root.limit = root.num(data.batteries[0].end, root.limit)
      root.startThreshold = root.num(data.batteries[0].start, root.startThreshold)
    }
    root.lastError = ""
    root.persistState()
    root.refresh()
  }

  // ---- Persistence (state file + boot hook) ----
  function persistState() {
    if (!root.supported || root.limit < 0) return
    var start = root.startThreshold >= 0 ? root.startThreshold : 0
    if (start >= root.limit) start = Math.max(0, root.limit - 5)
    stateProc.command = ["bash", root.scriptPath(), "save-state", String(root.limit), String(start)]
    if (!stateProc.running) stateProc.running = true
    syncBootPref()
  }

  function syncBootPref() {
    if (!root.granted) return
    bootPrefProc.command = ["bash", root.scriptPath(), "boot-pref", root.applyAtBootPref ? "on" : "off"]
    if (!bootPrefProc.running) bootPrefProc.running = true
  }

  function installHook() {
    hookProc.command = ["omarchy", "hook", "install", "post-boot", root.pluginDir + "/" + root.hookName]
    if (!hookProc.running) hookProc.running = true
  }

  // ---- Grant / redeploy flow (one-time pkexec setup) ----
  function requestGrant() {
    if (root.granting) return
    root.granting = true
    var user = String(Quickshell.env("USER") || "")
    if (user === "") user = String(Quickshell.env("HOME") || "").replace(/^.*\//, "")
    grantProc.command = ["pkexec", root.scriptPath("setup-root.sh"), user]
    if (!grantProc.running) grantProc.running = true
  }

  function onGrantFinished(text) {
    root.granting = false
    var raw = String(text || "").trim()
    if (raw === "") {
      root.lastError = "Authorization cancelled"
      return
    }
    var data = null
    try {
      data = JSON.parse(raw)
    } catch (e) {
      data = null
    }
    if (data && data.ok === true) root.refresh()
    else root.lastError = data && data.error ? String(data.error) : "Setup failed"
  }

  // ---- Processes ----
  Process {
    id: getStatus
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onGetFinished(text)
    }
  }

  Process {
    id: setStatus
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSetFinished(text)
    }
  }

  Process {
    id: grantProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onGrantFinished(text)
    }
  }

  Process {
    id: stateProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0 && root.applyAtBootPref) root.installHook()
    }
  }

  Process {
    id: bootPrefProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0 && root.applyAtBootPref) root.installHook()
    }
  }

  Process {
    id: hookProc
    stdout: StdioCollector { waitForEnd: true }
  }

  Timer {
    id: pollTimer
    interval: root.pollIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onPollIntervalSecChanged: pollTimer.restart()

  onApplyAtBootPrefChanged: root.syncBootPref()

  Component.onCompleted: root.refresh()

  // ---- UI ----
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    tooltipText: root.barTooltip
    foreground: !root.probed || !root.supported
      ? Color.muted
      : (root.limitActive ? Color.accent : Color.muted)
    dimmed: false
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton || buttonCode === Qt.RightButton) root.toggleLimit()
      else if (buttonCode === Qt.MiddleButton) root.refresh()
    }
  }
}
