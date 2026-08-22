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
  property var batteries: []
  property int batteryPct: -1
  property bool charging: false
  property bool applying: false
  property string lastError: ""
  property int pendingEnd: -1
  property int pendingStart: -1
  property bool granting: false
  property bool stateDirty: false
  property bool bootPrefDirty: false
  property int requestedEnd: -1
  property int requestedStart: -1

  function activeBatteryCount(list) {
    var n = 0
    for (var i = 0; i < list.length; i++) {
      var e = root.num(list[i] && list[i].end, -1)
      if (e > 0 && e < 100) n++
    }
    return n
  }

  readonly property int activeBatteries: root.activeBatteryCount(root.batteries)
  readonly property bool limitActive: root.activeBatteries > 0
  readonly property bool mixedLimits: root.batteries.length > 1
    && root.activeBatteries > 0
    && root.activeBatteries < root.batteries.length

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
    var state
    if (root.mixedLimits) {
      var parts = []
      for (var i = 0; i < root.batteries.length; i++) {
        var b = root.batteries[i]
        var e = root.num(b.end, -1)
        parts.push((b.name || ("BAT" + i)) + " " + ((e > 0 && e < 100) ? e + "/" + Math.max(0, root.num(b.start, 0)) : "off"))
      }
      state = "Charge limit mixed: " + parts.join(", ")
    } else {
      var first = root.batteries.length > 0 ? root.batteries[0] : null
      state = root.limitActive
        ? "Charge limit on (" + root.num(first && first.end, root.limitEnd) + "/" + Math.max(0, root.num(first && first.start, 0)) + ")"
        : "Charge limit off"
    }
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
      root.batteries = data.batteries
      var pctSum = 0
      var pctCount = 0
      var anyCharging = false
      for (var i = 0; i < data.batteries.length; i++) {
        var b = data.batteries[i]
        if (root.num(b.capacity, -1) >= 0) {
          pctSum += root.num(b.capacity, 0)
          pctCount++
        }
        if (b.charging === true) anyCharging = true
      }
      root.batteryPct = pctCount > 0 ? Math.round(pctSum / pctCount) : -1
      root.charging = anyCharging
    } else {
      root.batteries = []
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
    root.requestedEnd = end
    root.requestedStart = start
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
    root.lastError = ""
    root.persistState(root.requestedEnd, root.requestedStart)
    root.refresh()
  }

  // ---- Persistence (state file + boot hook) ----
  function persistState(endValue, startValue) {
    if (!root.supported) return
    if (stateProc.running) {
      root.stateDirty = true
      return
    }
    stateProc.command = ["bash", root.scriptPath(), "save-state", String(clampLimit(endValue)), String(Math.max(0, Math.round(Number(startValue) || 0)))]
    stateProc.running = true
  }

  function syncBootPref() {
    if (!root.granted) return
    if (bootPrefProc.running) {
      root.bootPrefDirty = true
      return
    }
    bootPrefProc.command = ["bash", root.scriptPath(), "boot-pref", root.applyAtBootPref ? "on" : "off"]
    bootPrefProc.running = true
  }

  function installHook() {
    hookProc.command = ["omarchy", "hook", "install", "post-boot", root.pluginDir + "/" + root.hookName]
    if (!hookProc.running) hookProc.running = true
  }

  function removeHook() {
    removeHookProc.command = ["rm", "-f", Quickshell.env("HOME") + "/.config/omarchy/hooks/post-boot.d/" + root.hookName]
    if (!removeHookProc.running) removeHookProc.running = true
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
      if (root.stateDirty) {
        root.stateDirty = false
        Qt.callLater(function() { root.persistState(root.requestedEnd, root.requestedStart) })
      } else if (exitCode === 0 && root.applyAtBootPref) {
        root.installHook()
      }
    }
  }

  Process {
    id: bootPrefProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (root.bootPrefDirty) {
        root.bootPrefDirty = false
        Qt.callLater(root.syncBootPref)
      } else if (exitCode === 0) {
        if (root.applyAtBootPref) root.installHook()
        else root.removeHook()
      }
    }
  }

  Process {
    id: hookProc
    stdout: StdioCollector { waitForEnd: true }
  }

  Process {
    id: removeHookProc
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
