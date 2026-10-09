import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Todo.js" as Todo

Panel {
  id: root
  moduleName: "omarchy-tuxedo"
  ipcTarget: "omarchy-tuxedo"
  manageIpc: false

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.toggle() }
    function toggle(): void { root.toggle() }
    function show(): void { root.open() }
    function close(): void { root.close() }
    function hide(): void { root.close() }
  }

  readonly property string defaultTodoPath: Quickshell.env("HOME") + "/todo.txt"
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
    + "/omarchy/omarchy-tuxedo/state.json"
  readonly property string helperPath: {
    var url = String(Qt.resolvedUrl("secure_files.py"))
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.slice(7)) : ""
  }
  readonly property int todoOutputLimit: 8 * 1024 * 1024 * 6 + 256
  readonly property int stateOutputLimit: 1024 * 1024 * 6 + 256
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color barForeground: bar ? bar.barForeground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var tasks: []
  property var completedTasks: []
  property var projects: []
  property var contexts: []
  readonly property var projectCounts: Todo.counts(tasks, "projects")
  readonly property var contextCounts: Todo.counts(tasks, "contexts")
  property string filterKind: "all"
  property string filterValue: ""
  property string searchText: ""
  readonly property string activeSearchScope: Todo.searchScope(searchText)
  property int dataRevision: 0
  property string statusMessage: ""
  property string todoPath: defaultTodoPath
  property bool badgeDueOnly: false
  property bool twoLineDescriptions: false
  property bool filterSidebarOpen: false
  property bool sidebarPreviewActive: false
  property string sortMode: "sort:due"
  property string panelMode: "tasks"
  property var selectedLines: ({})
  property int selectionRevision: 0
  property int editingLineNumber: 0
  property int activeTaskIndex: 0
  property int sidebarCursor: 0
  property string keyPrefix: ""
  property bool ioReady: false
  property bool todoReadPending: false
  property bool stateReadPending: false
  property bool stateWritePending: false
  property bool todoWatcherWanted: false
  property bool stateWatcherWanted: false
  property bool todoWatcherRestartImmediate: false
  property bool doneReadPending: false
  property bool doneWatcherWanted: false
  property bool doneWatcherRestartImmediate: false
  property string todoReadPath: ""
  property string doneReadPath: ""
  property string stateWritePayload: ""
  readonly property int dueCount: tasks.filter(function(task) { return task.isDue }).length
  readonly property int badgeCount: badgeDueOnly ? dueCount : tasks.length
  readonly property int selectedCount: {
    var revision = selectionRevision
    return Object.keys(selectedLines).length
  }
  readonly property int sidebarEntryCount: projects.length + contexts.length
  readonly property string previewFilterKind: sidebarCursor < projects.length ? "project" : "context"
  readonly property string previewFilterValue: sidebarCursor < projects.length
    ? (projects[sidebarCursor] || "") : (contexts[sidebarCursor - projects.length] || "")
  readonly property string effectiveFilterKind: sidebarPreviewActive && filterSidebarOpen
    && sidebarEntryCount > 0 ? previewFilterKind : filterKind
  readonly property string effectiveFilterValue: sidebarPreviewActive && filterSidebarOpen
    && sidebarEntryCount > 0 ? previewFilterValue : filterValue
  readonly property var activityTasks: Todo.filterByFacet(completedTasks,
    effectiveFilterKind, effectiveFilterValue)
  readonly property var completionActivity: Todo.completionHeatmap(activityTasks, todayIso(), 26)
  readonly property var topActivityProjects: Todo.topCompletedFacets(activityTasks, "projects",
    completionActivity.startDate, completionActivity.endDate, 3)
  readonly property var activeTask: visibleTasks.length > 0 && activeTaskIndex >= 0
    ? visibleTasks[Math.min(activeTaskIndex, visibleTasks.length - 1)] : null

  readonly property var visibleTasks: {
    var revision = dataRevision
    var result = []
    var scope = Todo.searchScope(searchText)
    var candidates = scope === "done" ? completedTasks
      : (scope === "all" ? tasks.concat(completedTasks) : tasks)
    for (var i = 0; i < candidates.length; i++) {
      var task = candidates[i]
      if (scope === "due" && !task.isDue) continue
      if (scope === "rec" && !Todo.isRecurring(task)) continue
      if (effectiveFilterKind === "project" && task.projects.indexOf(effectiveFilterValue) < 0) continue
      if (effectiveFilterKind === "context" && task.contexts.indexOf(effectiveFilterValue) < 0) continue
      if (effectiveFilterKind === "due" && !task.isDue) continue
      if (!Todo.matchesSearch(task, searchText)) continue
      result.push(task)
    }
    result.sort(function(a, b) {
      if (sortMode === "sort:file") return a.lineNumber - b.lineNumber
      if (sortMode === "sort:priority") {
        var aPriority = a.priority === "" ? 999 : a.priority.charCodeAt(0) - 65
        var bPriority = b.priority === "" ? 999 : b.priority.charCodeAt(0) - 65
        var priorityOrder = aPriority - bPriority
        return priorityOrder !== 0 ? priorityOrder : a.lineNumber - b.lineNumber
      }
      if (a.due === "" && b.due !== "") return 1
      if (a.due !== "" && b.due === "") return -1
      var dueOrder = a.due.localeCompare(b.due)
      return dueOrder !== 0 ? dueOrder : a.lineNumber - b.lineNumber
    })
    return result
  }

  function todayIso() {
    var d = new Date()
    var month = String(d.getMonth() + 1).padStart(2, "0")
    var day = String(d.getDate()).padStart(2, "0")
    return d.getFullYear() + "-" + month + "-" + day
  }

  function parseTodo(raw) {
    var wasEditing = editingLineNumber !== 0
    var nextTasks = []
    var projectSet = Object.create(null)
    var contextSet = Object.create(null)
    var lines = String(raw || "").split("\n")
    var today = todayIso()

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line === "" || /^x\s/.test(line)) continue
      var task = Todo.parseLine(lines[i])
      task.projects.forEach(function(value) { projectSet[value] = true })
      task.contexts.forEach(function(value) { contextSet[value] = true })
      task.lineNumber = i + 1
      task.completed = false
      task.completedDate = ""
      task.isDue = task.due !== "" && task.due <= today
      task.overdue = task.due !== "" && task.due < today
      nextTasks.push(task)
    }

    tasks = nextTasks
    projects = Object.keys(projectSet).sort(function(a, b) { return a.localeCompare(b) })
    contexts = Object.keys(contextSet).sort(function(a, b) { return a.localeCompare(b) })
    selectedLines = ({})
    selectionRevision++
    editingLineNumber = 0
    dataRevision++
    clampActiveTask()
    if (wasEditing) Qt.callLater(function() { taskKeyCatcher.forceActiveFocus() })
  }

  function parseDone(raw) {
    var nextTasks = []
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim() === "") continue
      var task = Todo.parseCompletedLine(lines[i])
      task.lineNumber = i + 1
      task.isDue = false
      task.overdue = false
      nextTasks.push(task)
    }
    completedTasks = nextTasks
    dataRevision++
    clampActiveTask()
  }

  function navigationDelta(event) {
    if (event.modifiers === Qt.ControlModifier) {
      if (event.key === Qt.Key_N) return 1
      if (event.key === Qt.Key_P) return -1
    }
    if (event.modifiers === Qt.NoModifier) {
      if (event.key === Qt.Key_J || event.key === Qt.Key_Down) return 1
      if (event.key === Qt.Key_K || event.key === Qt.Key_Up) return -1
    }
    return 0
  }

  function selectFilter(kind, value) {
    filterKind = kind
    filterValue = value || ""
    taskList.positionViewAtBeginning()
    clampActiveTask()
  }

  function selectSearchScope(scope) {
    searchField.text = Todo.withSearchScope(searchField.text, scope)
    searchField.forceActiveFocus()
  }

  function clampActiveTask() {
    if (visibleTasks.length === 0) activeTaskIndex = 0
    else activeTaskIndex = Math.max(0, Math.min(activeTaskIndex, visibleTasks.length - 1))
    Qt.callLater(function() {
      if (visibleTasks.length > 0) taskList.positionViewAtIndex(activeTaskIndex, ListView.Contain)
    })
  }

  function moveActiveTask(delta) {
    if (visibleTasks.length === 0) return
    activeTaskIndex = Math.max(0, Math.min(activeTaskIndex + delta, visibleTasks.length - 1))
    taskList.positionViewAtIndex(activeTaskIndex, ListView.Contain)
  }

  function setActiveTask(index) {
    if (visibleTasks.length === 0) return
    activeTaskIndex = Math.max(0, Math.min(index, visibleTasks.length - 1))
    taskList.positionViewAtIndex(activeTaskIndex, ListView.Contain)
  }

  function clearPrefix() {
    keyPrefix = ""
    chordTimer.stop()
  }

  function beginPrefix(prefix) {
    keyPrefix = prefix
    chordTimer.restart()
  }

  function focusTaskList() {
    clearPrefix()
    panelMode = "tasks"
    sidebarPreviewActive = false
    filterSidebarOpen = false
    Qt.callLater(function() { taskKeyCatcher.forceActiveFocus() })
  }

  function openSidebar(kind) {
    clearPrefix()
    filterSidebarOpen = true
    sidebarCursor = kind === "context" ? projects.length : 0
    if (sidebarEntryCount > 0) sidebarCursor = Math.min(sidebarCursor, sidebarEntryCount - 1)
    sidebarPreviewActive = sidebarEntryCount > 0
    taskList.positionViewAtBeginning()
    clampActiveTask()
    Qt.callLater(function() { filterSidebar.forceActiveFocus() })
  }

  function toggleSidebar() {
    if (filterSidebarOpen) {
      sidebarPreviewActive = false
      filterSidebarOpen = false
    } else openSidebar(filterKind === "context" ? "context" : "project")
  }

  function moveSidebarCursor(delta) {
    if (sidebarEntryCount === 0) return
    sidebarCursor = Math.max(0, Math.min(sidebarCursor + delta, sidebarEntryCount - 1))
    sidebarPreviewActive = true
    taskList.positionViewAtBeginning()
    clampActiveTask()
  }

  function applySidebarFilter(kind, value) {
    sidebarPreviewActive = false
    if (filterKind === kind && filterValue === value) selectFilter("all", "")
    else selectFilter(kind, value)
  }

  function activateSidebarCursor() {
    if (sidebarEntryCount === 0) return
    var kind = sidebarCursor < projects.length ? "project" : "context"
    var value = kind === "project" ? projects[sidebarCursor] : contexts[sidebarCursor - projects.length]
    applySidebarFilter(kind, value)
  }

  function positionSidebarCursor() {
    if (!filterSidebarOpen || sidebarEntryCount === 0) return
    var item = sidebarCursor < projects.length
      ? projectRepeater.itemAt(sidebarCursor)
      : contextRepeater.itemAt(sidebarCursor - projects.length)
    if (!item) return
    var y = item.mapToItem(sidebarColumn, 0, 0).y
    if (y < sidebarFlick.contentY) sidebarFlick.contentY = y
    else if (y + item.height > sidebarFlick.contentY + sidebarFlick.height)
      sidebarFlick.contentY = y + item.height - sidebarFlick.height
  }

  function deleteActiveOrSelected() {
    if (actionProcess.running) return
    var numbers = selectedCount > 0 ? selectedTaskNumbers(true)
      : (activeTask && !activeTask.completed ? [activeTask.lineNumber] : [])
    if (numbers.length === 0) return
    statusMessage = "Deleting " + numbers.length + " task(s)…"
    actionProcess.command = tuxedoCommand(["del"].concat(numbers.map(String)).concat(["-f"]))
    actionProcess.running = true
  }

  function copyActiveTask() {
    if (!activeTask) return
    Quickshell.clipboardText = activeTask.rawText
    statusMessage = "Copied task"
  }

  function handleQuickTaskKey(event) {
    if (panelMode !== "tasks" || editingLineNumber !== 0
        || (!searchField.activeFocus && !taskKeyCatcher.activeFocus)) return false
    if (event.modifiers === Qt.ControlModifier && (event.key === Qt.Key_N || event.key === Qt.Key_P)) {
      clearPrefix()
      moveActiveTask(event.key === Qt.Key_N ? 1 : -1)
      return true
    }
    if (event.modifiers === Qt.AltModifier && event.key === Qt.Key_X) {
      clearPrefix()
      completeTask(activeTask)
      return true
    }
    return false
  }

  function handleListKey(event) {
    if (!taskKeyCatcher.activeFocus || panelMode !== "tasks" || filterSidebarOpen || editingLineNumber !== 0) return false
    if (handleQuickTaskKey(event)) return true
    if ((event.text === "/" && (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) === 0)
        || (event.key === Qt.Key_K && event.modifiers === Qt.ControlModifier)) {
      clearPrefix()
      searchField.forceActiveFocus()
      return true
    }
    if (event.key === Qt.Key_A && event.modifiers === Qt.ControlModifier) {
      clearPrefix()
      selectFilter("all", "")
      return true
    }
    if (event.key === Qt.Key_Escape) {
      clearPrefix()
      close()
      return true
    }
    var keyText = String(event.text || "")
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var page = Math.max(1, Math.floor(taskList.height / Style.space(twoLineDescriptions ? 80 : 48)))
    var delta = navigationDelta(event)
    if (delta) { clearPrefix(); moveActiveTask(delta); return true }

    if (keyPrefix !== "") {
      var chord = keyPrefix + keyText.toLowerCase()
      clearPrefix()
      if (chord === "gg") { setActiveTask(0); return true }
      if (chord === "dd") { deleteActiveOrSelected(); return true }
      if (chord === "yy") { copyActiveTask(); return true }
      if (chord === "fp") { openSidebar("project"); return true }
      if (chord === "fc") { openSidebar("context"); return true }
    }

    if (ctrl && event.key === Qt.Key_D) { moveActiveTask(page); return true }
    if (ctrl && event.key === Qt.Key_U) { moveActiveTask(-page); return true }
    if (keyText === "G") { setActiveTask(visibleTasks.length - 1); return true }
    if (keyText === "D") { toggleDescriptionLines(); return true }
    if (keyText === "S") { cycleSortMode(); return true }
    if (event.key === Qt.Key_E || event.key === Qt.Key_I) { startEditing(activeTask); return true }
    if (event.key === Qt.Key_X) { completeTask(activeTask); return true }
    if (event.key === Qt.Key_Space) { toggleSelected(activeTask); return true }
    if (keyText === "?") {
      clearPrefix()
      panelMode = "help"
      Qt.callLater(function() { helpView.forceActiveFocus() })
      return true
    }
    if (["g", "d", "y", "f"].indexOf(keyText.toLowerCase()) >= 0) {
      beginPrefix(keyText.toLowerCase())
      return true
    }
    clearPrefix()
    return false
  }

  function donePath() {
    var slash = todoPath.lastIndexOf("/")
    return (slash >= 0 ? todoPath.slice(0, slash + 1) : "") + "done.txt"
  }

  function tuxedoCommand(args) {
    return ["env", "TODO_FILE=" + todoPath, "DONE_FILE=" + donePath(), "tuxedo"].concat(args)
  }

  function completeTask(task) {
    if (!task || task.completed || actionProcess.running) return
    statusMessage = "Completing…"
    actionProcess.command = tuxedoCommand(["do", String(task.lineNumber)])
    actionProcess.running = true
  }

  function isSelected(task) {
    var revision = selectionRevision
    return !!task && !task.completed && selectedLines[String(task.lineNumber)] === task.text
  }

  function toggleSelected(task) {
    if (!task || task.completed || editingLineNumber !== 0) return
    var next = {}
    for (var key in selectedLines) next[key] = selectedLines[key]
    var lineKey = String(task.lineNumber)
    if (next[lineKey] === task.text) delete next[lineKey]
    else next[lineKey] = task.text
    selectedLines = next
    selectionRevision++
  }

  function selectedTaskNumbers(descending) {
    var numbers = []
    for (var key in selectedLines) {
      var lineNumber = Number(key)
      if (isFinite(lineNumber) && selectedLines[key] !== undefined) numbers.push(lineNumber)
    }
    numbers.sort(function(a, b) { return descending ? b - a : a - b })
    return numbers
  }

  function completeSelected() {
    if (selectedCount === 0 || actionProcess.running) return
    var numbers = selectedTaskNumbers(false)
    statusMessage = "Completing " + numbers.length + " task(s)…"
    actionProcess.command = tuxedoCommand(["do"].concat(numbers.map(String)))
    actionProcess.running = true
  }

  function deleteSelected() {
    if (selectedCount === 0 || actionProcess.running) return
    var numbers = selectedTaskNumbers(true)
    statusMessage = "Deleting " + numbers.length + " task(s)…"
    actionProcess.command = tuxedoCommand(["del"].concat(numbers.map(String)).concat(["-f"]))
    actionProcess.running = true
  }

  function startEditing(task) {
    if (!task || task.completed || actionProcess.running) return
    selectedLines = ({})
    selectionRevision++
    editingLineNumber = task.lineNumber
  }

  function cancelEditing() {
    editingLineNumber = 0
    focusTaskList()
  }

  function saveEditing(task, text) {
    var value = String(text || "").trim()
    if (/[\r\n]/.test(value)) {
      statusMessage = "A task must be a single line; remove pasted line breaks before saving"
      return
    }
    if (!task || value === "" || value === task.text || actionProcess.running) {
      cancelEditing()
      return
    }
    statusMessage = "Saving…"
    actionProcess.command = tuxedoCommand(["replace", String(task.lineNumber), value])
    actionProcess.running = true
  }

  function addTask(text) {
    var value = String(text || "").trim()
    if (value === "" || actionProcess.running) return
    statusMessage = "Adding…"
    actionProcess.command = tuxedoCommand(["add", value])
    actionProcess.running = true
  }

  function filterLabel() {
    if (effectiveFilterKind === "project") return "+" + effectiveFilterValue
    if (effectiveFilterKind === "context") return "@" + effectiveFilterValue
    if (effectiveFilterKind === "due") return "Due"
    return "All"
  }

  function loadState(raw) {
    var state = null
    try { state = JSON.parse(String(raw || "")) } catch (e) {}
    var savedPath = state ? String(state.todoPath || "").trim() : ""
    todoPath = savedPath.charAt(0) === "/" ? savedPath : defaultTodoPath
    badgeDueOnly = state && state.badgeDueOnly === true
    twoLineDescriptions = state && state.twoLineDescriptions === true
    var savedSort = state ? String(state.sortMode || "") : ""
    sortMode = ["sort:due", "sort:file", "sort:priority"].indexOf(savedSort) >= 0
      ? savedSort
      : "sort:due"
  }

  function friendlyFileError(code, kind) {
    var names = {
      "NOT_FOUND": kind === "todo" ? "The configured todo.txt file does not exist" : "State file not found",
      "SYMLINK": "Refusing to use a symbolic link for " + kind,
      "NOT_REGULAR": "The " + kind + " path is not a regular file",
      "WRONG_OWNER": "The " + kind + " file is not owned by the current user",
      "TOO_LARGE": "The " + kind + " file exceeds its safety limit",
      "LINE_TOO_LONG": "A todo.txt line exceeds 64 KiB",
      "INVALID_UTF8": "The " + kind + " file is not valid UTF-8",
      "STATE_FILE_MODE": "The state file permissions are too broad",
      "STATE_DIR_WRONG_OWNER": "The private state directory has the wrong owner",
      "STATE_DIR_MODE": "Could not secure the private state directory",
      "WATCH_PARENT": "Could not watch the " + kind + " directory",
      "ACCESS": "Permission denied while reading " + kind,
      "CHANGED": "The " + kind + " file changed while it was being read"
    }
    return names[code] || "Could not securely access " + kind
  }

  function parseHelperReply(raw, limit, kind) {
    var value = String(raw || "")
    if (value.length > limit) {
      statusMessage = "The " + kind + " helper response exceeded its safety limit"
      return null
    }
    var reply = null
    try { reply = JSON.parse(value) } catch (e) {}
    if (!reply || reply.ok !== true) {
      statusMessage = friendlyFileError(reply ? String(reply.error || "") : "", kind)
      return null
    }
    return reply
  }

  function requestTodoRead() {
    if (!ioReady || helperPath === "") return
    if (todoReadProcess.running) {
      todoReadPending = true
      return
    }
    todoReadPending = false
    todoReadPath = todoPath
    todoReadProcess.command = ["python3", helperPath, "read-todo", todoReadPath]
    todoReadProcess.running = true
  }

  function requestDoneRead() {
    if (!ioReady || helperPath === "") return
    if (doneReadProcess.running) {
      doneReadPending = true
      return
    }
    doneReadPending = false
    doneReadPath = donePath()
    doneReadProcess.command = ["python3", helperPath, "read-done", doneReadPath]
    doneReadProcess.running = true
  }

  function requestStateRead() {
    if (helperPath === "") {
      statusMessage = "Could not resolve the bundled file helper"
      return
    }
    if (stateReadProcess.running) {
      stateReadPending = true
      return
    }
    stateReadPending = false
    stateReadProcess.command = ["python3", helperPath, "read-state", statePath]
    stateReadProcess.running = true
  }

  function saveState() {
    var payload = JSON.stringify({
      version: 1,
      todoPath: todoPath,
      badgeDueOnly: badgeDueOnly,
      twoLineDescriptions: twoLineDescriptions,
      sortMode: sortMode
    })
    if (payload.length > 1024 * 1024) {
      statusMessage = "State exceeds its 1 MiB safety limit"
      return
    }
    stateWritePayload = payload
    if (stateWriteProcess.running) {
      stateWritePending = true
      return
    }
    stateWritePending = false
    stateWriteProcess.command = ["python3", helperPath, "write-state", statePath]
    stateWriteProcess.running = true
  }

  function restartTodoWatcher() {
    if (!ioReady || helperPath === "") return
    todoWatcherWanted = true
    todoWatchRestart.stop()
    if (todoWatchProcess.running) {
      todoWatcherRestartImmediate = true
      todoWatchProcess.signal(15)
    } else {
      todoWatchProcess.command = ["python3", helperPath, "watch", todoPath]
      todoWatchProcess.running = true
    }
  }

  function restartDoneWatcher() {
    if (!ioReady || helperPath === "") return
    doneWatcherWanted = true
    doneWatchRestart.stop()
    if (doneWatchProcess.running) {
      doneWatcherRestartImmediate = true
      doneWatchProcess.signal(15)
    } else {
      doneWatchProcess.command = ["python3", helperPath, "watch", donePath()]
      doneWatchProcess.running = true
    }
  }

  function startStateWatcher() {
    if (!ioReady || helperPath === "") return
    stateWatcherWanted = true
    if (!stateWatchProcess.running) stateWatchRestart.start()
  }

  function toggleBadgeMode() {
    badgeDueOnly = !badgeDueOnly
    saveState()
  }

  function toggleDescriptionLines() {
    twoLineDescriptions = !twoLineDescriptions
    saveState()
  }

  function cycleSortMode() {
    var modes = ["sort:due", "sort:file", "sort:priority"]
    var current = modes.indexOf(sortMode)
    sortMode = modes[(current + 1) % modes.length]
    saveState()
    taskList.positionViewAtBeginning()
    clampActiveTask()
  }

  function showSettings() {
    panelMode = "settings"
    settingsPathField.text = todoPath
    Qt.callLater(function() {
      settingsPathField.forceActiveFocus()
      settingsPathField.selectAll()
    })
  }

  function hideSettings() {
    panelMode = "tasks"
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function saveTodoPath(path) {
    var value = String(path || "").trim()
    if (value.charAt(0) !== "/") {
      statusMessage = "Use an absolute path beginning with /"
      return
    }
    todoPath = value
    saveState()
    statusMessage = ""
    panelMode = "tasks"
    restartTodoWatcher()
    restartDoneWatcher()
    requestTodoRead()
    requestDoneRead()
  }

  onOpenedChanged: {
    if (!opened) {
      selectedLines = ({})
      selectionRevision++
      editingLineNumber = 0
      panelMode = "tasks"
      filterSidebarOpen = false
      clearPrefix()
      return
    }
    requestTodoRead()
    requestDoneRead()
    statusMessage = ""
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  onVisibleTasksChanged: clampActiveTask()
  onSidebarCursorChanged: Qt.callLater(positionSidebarCursor)
  Timer {
    id: chordTimer
    interval: 700
    repeat: false
    onTriggered: root.keyPrefix = ""
  }

  Component.onCompleted: {
    requestStateRead()
  }

  Process {
    id: todoReadProcess
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var reply = root.parseHelperReply(text, root.todoOutputLimit, "todo")
        if (reply && root.todoReadPath === root.todoPath) {
          root.parseTodo(String(reply.data || ""))
          root.statusMessage = ""
        } else if (!reply && root.todoReadPath === root.todoPath) {
          root.tasks = []
          root.projects = []
          root.contexts = []
          root.selectedLines = ({})
          root.selectionRevision++
          root.dataRevision++
        }
      }
    }
    onExited: {
      if (root.todoReadPending || root.todoReadPath !== root.todoPath) root.requestTodoRead()
    }
  }

  Process {
    id: doneReadProcess
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var reply = root.parseHelperReply(text, root.todoOutputLimit, "done")
        if (reply && root.doneReadPath === root.donePath()) {
          root.parseDone(String(reply.data || ""))
        } else if (!reply && root.doneReadPath === root.donePath()) {
          root.completedTasks = []
          root.dataRevision++
        }
      }
    }
    onExited: {
      if (root.doneReadPending || root.doneReadPath !== root.donePath()) root.requestDoneRead()
    }
  }

  Process {
    id: stateReadProcess
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var reply = root.parseHelperReply(text, root.stateOutputLimit, "state")
        var previousTodoPath = root.todoPath
        root.loadState(reply ? String(reply.data || "") : "")
        if (!root.ioReady) {
          root.ioReady = true
          root.restartTodoWatcher()
          root.restartDoneWatcher()
          root.startStateWatcher()
          root.requestTodoRead()
          root.requestDoneRead()
        } else if (root.todoPath !== previousTodoPath) {
          root.restartTodoWatcher()
          root.restartDoneWatcher()
          root.requestTodoRead()
          root.requestDoneRead()
        }
      }
    }
    onExited: if (root.stateReadPending) root.requestStateRead()
  }

  Process {
    id: stateWriteProcess
    running: false
    stdinEnabled: true
    onStarted: write(root.stateWritePayload + "\n")
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseHelperReply(text, 512, "state")
    }
    onExited: if (root.stateWritePending) root.saveState()
  }

  Process {
    id: todoWatchProcess
    running: false
    stdout: SplitParser {
      onRead: function(line) {
        var value = String(line || "").trim()
        if (value === "EVENT") todoReadDebounce.restart()
        else if (value === "READY") {}
        else if (value !== "") {
          var reply = root.parseHelperReply(value, 512, "todo")
        }
      }
    }
    onExited: {
      if (!root.todoWatcherWanted) return
      if (root.todoWatcherRestartImmediate) {
        root.todoWatcherRestartImmediate = false
        todoWatchProcess.command = ["python3", root.helperPath, "watch", root.todoPath]
        todoWatchProcess.running = true
      } else {
        todoWatchRestart.start()
      }
    }
  }

  Process {
    id: stateWatchProcess
    running: false
    stdout: SplitParser {
      onRead: function(line) {
        var value = String(line || "").trim()
        if (value === "EVENT") stateReadDebounce.restart()
        else if (value === "READY") {}
        else if (value !== "") {
          var reply = root.parseHelperReply(value, 512, "state")
        }
      }
    }
    onExited: if (root.stateWatcherWanted) stateWatchRestart.start()
  }

  Process {
    id: doneWatchProcess
    running: false
    stdout: SplitParser {
      onRead: function(line) {
        var value = String(line || "").trim()
        if (value === "EVENT") doneReadDebounce.restart()
        else if (value === "READY") {}
        else if (value !== "") {
          var reply = root.parseHelperReply(value, 512, "done")
        }
      }
    }
    onExited: {
      if (!root.doneWatcherWanted) return
      if (root.doneWatcherRestartImmediate) {
        root.doneWatcherRestartImmediate = false
        doneWatchProcess.command = ["python3", root.helperPath, "watch", root.donePath()]
        doneWatchProcess.running = true
      } else {
        doneWatchRestart.start()
      }
    }
  }

  Timer { id: todoReadDebounce; interval: 80; repeat: false; onTriggered: root.requestTodoRead() }
  Timer { id: doneReadDebounce; interval: 80; repeat: false; onTriggered: root.requestDoneRead() }
  Timer { id: stateReadDebounce; interval: 80; repeat: false; onTriggered: root.requestStateRead() }
  Timer {
    id: todoWatchRestart
    interval: 5000
    repeat: false
    onTriggered: {
      todoWatchProcess.command = ["python3", root.helperPath, "watch", root.todoPath]
      todoWatchProcess.running = true
    }
  }
  Timer {
    id: stateWatchRestart
    interval: 5000
    repeat: false
    onTriggered: {
      stateWatchProcess.command = ["python3", root.helperPath, "watch", root.statePath]
      stateWatchProcess.running = true
    }
  }
  Timer {
    id: doneWatchRestart
    interval: 5000
    repeat: false
    onTriggered: {
      doneWatchProcess.command = ["python3", root.helperPath, "watch", root.donePath()]
      doneWatchProcess.running = true
    }
  }

  Process {
    id: actionProcess
    running: false
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") root.statusMessage = String(text).trim()
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.statusMessage = ""
        addField.text = ""
      } else if (root.statusMessage === "") {
        root.statusMessage = "The action could not be completed"
      }
      root.requestTodoRead()
      root.requestDoneRead()
    }
  }

  implicitWidth: Style.space(38)
  Process {
    id: placementProcess
    stderr: StdioCollector { id: placementError; waitForEnd: true }
    onExited: function(exitCode) {
      root.statusMessage = exitCode === 0 ? "Bar position updated" : (placementError.text.trim() || "Could not move the widget")
    }
  }

  implicitHeight: bar ? bar.barSize : Style.bar.sizeHorizontal

  Item {
    id: indicator
    anchors.fill: parent

    Text {
      anchors.centerIn: parent
      text: "󰄲"
      color: root.barForeground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body + 2
    }

    Rectangle {
      visible: root.badgeCount > 0
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: 1
      anchors.topMargin: 2
      width: Math.max(Style.space(14), countText.implicitWidth + Style.space(5))
      height: Style.space(14)
      radius: height / 2
      color: root.badgeDueOnly ? root.urgent : Commons.Color.accent

      Text {
        id: countText
        anchors.centerIn: parent
        text: root.badgeCount > 99 ? "99+" : String(root.badgeCount)
        color: Commons.Color.background
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption - 1
        font.bold: true
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggle()
      onEntered: if (root.bar) root.bar.showTooltip(root, root.tasks.length + " open tasks")
      onExited: if (root.bar) root.bar.hideTooltip(root)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: indicator
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.panelMode === "settings" ? settingsPathField
      : (root.panelMode === "help" ? helpView : searchField)
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(Style.space(610), Style.space(680))

    Item {
      id: taskKeyCatcher
      width: 0
      height: 0
      focus: false

      Keys.onTabPressed: addField.forceActiveFocus()
      Keys.onBacktabPressed: searchField.forceActiveFocus()
      Keys.onPressed: function(event) {
        if (root.handleListKey(event)) event.accepted = true
      }
    }

    Column {
      anchors.fill: parent
      spacing: Style.space(10)

      Row {
        width: parent.width
        spacing: Style.space(10)

        Text {
          id: taskIcon
          text: "󰄲"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading + 3
        }

        Column {
          width: parent.width - taskIcon.width - lineMode.implicitWidth - badgeMode.implicitWidth
            - settingsButton.width - parent.spacing * 4

          Text {
            text: "Tuxedo Todo"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Text {
            text: root.tasks.length + " open · " + root.dueCount + " due · " + root.sortMode
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          id: lineMode
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(5)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.twoLineDescriptions ? "Two lines" : "One line"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          ToggleSwitch {
            anchors.verticalCenter: parent.verticalCenter
            checked: root.twoLineDescriptions
            trackHeight: Style.space(18)
            foreground: root.foreground
            accent: Commons.Color.accent
            onToggled: root.toggleDescriptionLines()
          }
        }

        Row {
          id: badgeMode
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(5)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.badgeDueOnly ? "Due" : "All"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          ToggleSwitch {
            anchors.verticalCenter: parent.verticalCenter
            checked: root.badgeDueOnly
            trackHeight: Style.space(18)
            foreground: root.foreground
            accent: root.urgent
            onToggled: root.toggleBadgeMode()
          }
        }

        PanelActionButton {
          id: settingsButton
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰒓"
          tooltipText: root.panelMode === "settings" ? "Back to tasks" : "Settings"
          foreground: root.dim
          hoverColor: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.heading
          onClicked: root.panelMode === "settings" ? root.hideSettings() : root.showSettings()
        }
      }

      TextField {
        id: searchField
        visible: root.panelMode === "tasks"
        width: parent.width
        placeholderText: "Search tasks — try in:done"
        foreground: root.foreground
        accent: Commons.Color.accent
        font.family: root.fontFamily
        onTextChanged: root.searchText = text
        Keys.onPressed: function(event) {
          if (root.handleQuickTaskKey(event)) event.accepted = true
        }
        Keys.onEscapePressed: root.close()
        Keys.onTabPressed: root.focusTaskList()
        Keys.onBacktabPressed: addField.forceActiveFocus()
      }

      Row {
        visible: root.panelMode === "tasks"
        width: parent.width
        height: Style.space(34)
        spacing: Style.space(14)

        Row {
          id: scopeActions
          spacing: Style.space(16)

          Repeater {
            model: [
              { scope: "open", label: "Open" },
              { scope: "all", label: "All" },
              { scope: "due", label: "Due" },
              { scope: "rec", label: "Rec" },
              { scope: "done", label: "Done" }
            ]
            TextAction {
              required property var modelData
              label: modelData.label
              selected: root.activeSearchScope === modelData.scope
              onActivated: root.selectSearchScope(modelData.scope)
            }
          }
        }

        Item {
          width: Math.max(0, parent.width - scopeActions.width - filterAction.width
            - sortAction.width - parent.spacing * 3)
          height: 1
        }

        TextAction {
          id: filterAction
          iconText: "󰈲"
          label: "Filter"
          selected: root.filterSidebarOpen || root.filterKind === "project" || root.filterKind === "context"
          onActivated: root.toggleSidebar()
        }
        TextAction { id: sortAction; iconText: "󰒺"; label: "Sort"; onActivated: root.cycleSortMode() }
      }

      Rectangle { visible: root.panelMode === "tasks"; width: parent.width; height: 1; color: root.dim; opacity: 0.35 }

      Text {
        visible: root.panelMode === "tasks"
        width: parent.width
        text: root.visibleTasks.length + " matching"
        color: Commons.Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Item {
        id: taskArea
        visible: root.panelMode === "tasks"
        width: parent.width
        height: Math.max(0, parent.height - Style.space(root.selectedCount > 0 ? 405 : 359))

        Rectangle {
          id: filterSidebar
          visible: root.filterSidebarOpen
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: Style.space(165)
          radius: Style.cornerRadius
          color: Style.normalFillFor(root.foreground, Commons.Color.accent)
          focus: false

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_A && event.modifiers === Qt.ControlModifier) {
              root.clearPrefix()
              root.selectFilter("all", "")
              event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
              root.focusTaskList()
              event.accepted = true
            } else if (root.navigationDelta(event) !== 0) {
              root.moveSidebarCursor(root.navigationDelta(event))
              event.accepted = true
            } else if (event.key === Qt.Key_Space) {
              root.activateSidebarCursor()
              event.accepted = true
            }
          }

          Column {
            anchors.fill: parent
          anchors.margins: Style.space(8)
            spacing: Style.space(8)

            Row {
              width: parent.width

              Text {
                width: parent.width - closeFilters.width
                anchors.verticalCenter: parent.verticalCenter
                text: "Filters"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              PanelActionButton {
                id: closeFilters
                iconText: "×"
                tooltipText: "Close filters"
                foreground: root.dim
                hoverColor: root.foreground
                onClicked: {
                  root.sidebarPreviewActive = false
                  root.filterSidebarOpen = false
                }
              }
            }

            Flickable {
              id: sidebarFlick
              width: parent.width
              height: parent.height - Style.space(32)
              contentWidth: width
              contentHeight: sidebarColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: sidebarColumn
                width: parent.width
                spacing: Style.space(6)

                Text {
                  width: parent.width
                  text: "Projects"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Repeater {
                  id: projectRepeater
                  model: root.projects
                  TextAction {
                    required property int index
                    required property string modelData
                    width: sidebarColumn.width
                    label: "+" + modelData
                    countText: "(" + (root.projectCounts[modelData] || 0) + ")"
                    leftAlign: true
                    selected: root.filterKind === "project" && root.filterValue === modelData
                    cursorHighlighted: filterSidebar.activeFocus && root.sidebarCursor === index
                    onActivated: root.applySidebarFilter("project", modelData)
                  }
                }

                Text {
                  width: parent.width
                  topPadding: Style.space(8)
                  text: "Contexts"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Repeater {
                  id: contextRepeater
                  model: root.contexts
                  TextAction {
                    required property int index
                    required property string modelData
                    width: sidebarColumn.width
                    label: "@" + modelData
                    countText: "(" + (root.contextCounts[modelData] || 0) + ")"
                    leftAlign: true
                    selected: root.filterKind === "context" && root.filterValue === modelData
                    cursorHighlighted: filterSidebar.activeFocus && root.sidebarCursor === root.projects.length + index
                    onActivated: root.applySidebarFilter("context", modelData)
                  }
                }
              }
            }
          }
        }

        ListView {
          id: taskList
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          anchors.right: parent.right
          width: parent.width - (root.filterSidebarOpen ? filterSidebar.width + Style.space(8) : 0)
          model: root.visibleTasks
          clip: true
          spacing: Style.space(2)
          boundsBehavior: Flickable.StopAtBounds
          focus: false
          activeFocusOnTab: false

        delegate: Rectangle {
          id: taskRow
          required property int index
          required property var modelData
          readonly property bool selected: root.isSelected(modelData)
          readonly property bool active: (taskKeyCatcher.activeFocus || searchField.activeFocus)
            && index === root.activeTaskIndex
          readonly property bool editing: !modelData.completed && root.editingLineNumber === modelData.lineNumber
          width: ListView.view.width
          height: editing ? Math.max(Style.space(90), editField.implicitHeight + Style.space(12))
            : Math.max(Style.space(root.twoLineDescriptions ? 80 : 48), taskDescription.implicitHeight + Style.space(12))
          radius: Style.cornerRadius
          color: selected
            ? Style.selectedFillFor(root.foreground, Commons.Color.accent)
            : (active
              ? Style.hoverFillFor(root.foreground, Commons.Color.accent)
              : (taskMouse.containsMouse ? Style.hoverFillFor(root.foreground, Commons.Color.accent) : "transparent"))
          border.width: active ? 2 : 0
          border.color: Commons.Color.accent

          MouseArea {
            id: taskMouse
            anchors.fill: parent
            enabled: !taskRow.editing
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.activeTaskIndex = index
              if (!taskRow.modelData.completed) root.toggleSelected(taskRow.modelData)
            }
          }

          Row {
            visible: !taskRow.editing
            anchors.fill: parent
            anchors.leftMargin: Style.space(5)
            anchors.rightMargin: Style.space(5)
            spacing: Style.space(9)

            Rectangle {
              id: completeBox
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(16)
              height: width
              radius: Math.max(2, Style.cornerRadius / 2)
              color: "transparent"
              border.width: 1
              border.color: modelData.isDue ? root.urgent : root.dim

              Text {
                anchors.centerIn: parent
                text: "✓"
                color: root.foreground
                opacity: modelData.completed || completeMouse.containsMouse ? 1 : 0
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: completeMouse
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                enabled: !modelData.completed
                hoverEnabled: true
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.completeTask(taskRow.modelData)
              }
            }

            Column {
              id: taskDescription
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - completeBox.width - dueText.width - editButton.width - parent.spacing * 3
              spacing: 2

              Text {
                width: parent.width
                text: modelData.displayText
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: modelData.priority === "A"
                wrapMode: root.twoLineDescriptions ? Text.WordWrap : Text.NoWrap
                maximumLineCount: root.twoLineDescriptions ? 2 : 1
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                visible: modelData.priority !== "" || modelData.projects.length > 0 || modelData.contexts.length > 0 || modelData.metadata.length > 0
                text: Todo.metadataHtml(modelData, root.dim, root.urgent)
                textFormat: Text.StyledText
                color: Commons.Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: root.twoLineDescriptions ? Text.WordWrap : Text.NoWrap
                maximumLineCount: root.twoLineDescriptions ? 2 : 1
                elide: Text.ElideRight
              }
            }

            Text {
              id: dueText
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(80)
              horizontalAlignment: Text.AlignRight
              text: modelData.overdue ? "overdue" : modelData.due
              textFormat: Text.PlainText
              color: modelData.isDue ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            PanelActionButton {
              id: editButton
              visible: !modelData.completed
              anchors.verticalCenter: parent.verticalCenter
              iconText: "✎"
              tooltipText: "Edit task"
              foreground: root.dim
              hoverColor: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.body + 2
              onClicked: root.startEditing(taskRow.modelData)
            }
          }

          Row {
            visible: taskRow.editing
            anchors.fill: parent
            anchors.leftMargin: Style.space(4)
            anchors.rightMargin: Style.space(4)
            spacing: Style.space(5)

            TextArea {
              id: editField
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - saveEditButton.width - cancelEditButton.width - parent.spacing * 2
              text: taskRow.editing ? taskRow.modelData.rawText : ""
              textFormat: TextEdit.PlainText
              wrapMode: TextEdit.Wrap
              color: root.foreground
              selectionColor: Commons.Color.accent
              selectedTextColor: Commons.Color.background
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              background: Rectangle {
                color: Commons.Color.background
                radius: Style.cornerRadius
                border.color: Commons.Color.accent
              }
              Keys.onReturnPressed: root.saveEditing(taskRow.modelData, text)
              Keys.onEnterPressed: root.saveEditing(taskRow.modelData, text)
              onVisibleChanged: if (visible) Qt.callLater(function() {
                editField.forceActiveFocus()
                editField.selectAll()
              })
              Keys.onEscapePressed: function(event) {
                root.cancelEditing()
                event.accepted = true
              }
            }

            PanelActionButton {
              id: saveEditButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "✓"
              tooltipText: "Save"
              foreground: root.foreground
              hoverColor: Commons.Color.accent
              onClicked: root.saveEditing(taskRow.modelData, editField.text)
            }

            PanelActionButton {
              id: cancelEditButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "×"
              tooltipText: "Cancel"
              foreground: root.dim
              hoverColor: root.urgent
              onClicked: root.cancelEditing()
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: root.visibleTasks.length === 0
          text: "No tasks in " + root.filterLabel()
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }
      }

      Text {
        visible: root.panelMode === "tasks" && root.statusMessage !== ""
        width: parent.width
        text: root.statusMessage
        textFormat: Text.PlainText
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      TextField {
        id: addField
        visible: root.panelMode === "tasks"
        width: parent.width
        placeholderText: "Add a task — try: pay rent Friday"
        foreground: root.foreground
        accent: Commons.Color.accent
        font.family: root.fontFamily
        onAccepted: root.addTask(text)
        Keys.onEscapePressed: root.close()
        Keys.onTabPressed: searchField.forceActiveFocus()
        Keys.onBacktabPressed: root.focusTaskList()
      }

      Column {
        id: completionHeatmap
        visible: root.panelMode === "tasks"
        width: parent.width
        height: Style.space(116)
        spacing: Style.space(6)

        Rectangle { width: parent.width; height: 1; color: root.dim; opacity: 0.35 }

        Row {
          width: parent.width
          height: parent.height - Style.space(7)
          spacing: Style.space(16)

          Column {
            width: Math.max(0, parent.width - activityChart.width - parent.spacing)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              text: String(root.completionActivity.total)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading + 4
              font.bold: true
            }

            Text {
              width: parent.width
              text: "completed in 6 months"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Item { width: 1; height: root.topActivityProjects.length > 0 ? Style.space(3) : 0 }

            Text {
              visible: root.topActivityProjects.length > 0
              width: parent.width
              text: "Top projects"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption - 1
              font.bold: true
            }

            Repeater {
              model: root.topActivityProjects

              Row {
                required property var modelData
                width: parent.width
                height: Style.space(12)

                Text {
                  width: parent.width - projectCount.width - Style.space(5)
                  text: "+" + modelData.name
                  color: Commons.Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption - 2
                  elide: Text.ElideRight
                }

                Text {
                  id: projectCount
                  text: String(modelData.count)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption - 2
                }
              }
            }
          }

          Column {
            id: activityChart
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(3)

            Row {
              spacing: Style.space(5)

              Item { width: Style.space(24); height: 1 }

              Row {
                spacing: Style.space(3)

                Repeater {
                  model: root.completionActivity.monthLabels

                  Text {
                    required property string modelData
                    width: Style.space(9)
                    text: modelData
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption - 2
                  }
                }
              }
            }

            Row {
              spacing: Style.space(5)

              Column {
                width: Style.space(24)
                spacing: Style.space(3)

                Repeater {
                  model: ["", "Mon", "", "Wed", "", "Fri", ""]

                  Text {
                    required property string modelData
                    width: Style.space(24)
                    height: Style.space(9)
                    verticalAlignment: Text.AlignVCenter
                    text: modelData
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption - 2
                  }
                }
              }

              Grid {
                id: activityGrid
                rows: 7
                flow: Grid.TopToBottom
                spacing: Style.space(3)

                Repeater {
                  model: root.completionActivity.cells

                  Rectangle {
                    required property var modelData
                    width: Style.space(9)
                    height: width
                    radius: Math.max(1, Style.cornerRadius / 3)
                    color: modelData.level > 0 ? Commons.Color.accent : root.foreground
                    opacity: modelData.future ? 0.04 : (modelData.level === 0 ? 0.12 : 0.28 + modelData.level * 0.18)

                    ToolTip.visible: activityMouse.containsMouse && !modelData.future
                    ToolTip.text: modelData.date + " · " + modelData.count
                      + (modelData.count === 1 ? " task completed" : " tasks completed")
                    ToolTip.delay: 250

                    MouseArea {
                      id: activityMouse
                      anchors.fill: parent
                      hoverEnabled: true
                    }
                  }
                }
              }
            }
          }
        }
      }

      Row {
        visible: root.panelMode === "tasks" && root.selectedCount > 0
        width: parent.width
        spacing: Style.space(8)

        Button {
          width: (parent.width - parent.spacing) / 2
          text: "Complete (" + root.selectedCount + ")"
          iconText: "✓"
          bordered: true
          foreground: root.foreground
          accent: Commons.Color.accent
          fontFamily: root.fontFamily
          onClicked: root.completeSelected()
        }

        Button {
          width: (parent.width - parent.spacing) / 2
          text: "Delete (" + root.selectedCount + ")"
          iconText: "󰆴"
          bordered: true
          foreground: root.urgent
          accent: root.urgent
          fontFamily: root.fontFamily
          onClicked: root.deleteSelected()
        }
      }

      FocusScope {
        id: helpView
        visible: root.panelMode === "help"
        width: parent.width
        height: parent.height - Style.space(74)
        focus: visible

        Keys.onEscapePressed: root.focusTaskList()

        Flickable {
          anchors.fill: parent
          contentWidth: width
          contentHeight: helpColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: helpColumn
            width: parent.width
            spacing: Style.space(16)

            HelpSection {
              title: "NAVIGATION"
              shortcuts: [
                ["j / ↓ / Ctrl+N", "next task"],
                ["k / ↑ / Ctrl+P", "previous task"],
                ["gg", "first task"],
                ["G", "last task"],
                ["Ctrl+D / Ctrl+U", "page down / up"],
                ["Tab / Shift+Tab", "search / list / add"]
              ]
            }

            HelpSection {
              title: "EDITING"
              shortcuts: [
                ["e / i", "edit active task"],
                ["x", "complete task"],
                ["Alt+X", "complete (search / list)"],
                ["dd", "delete selected or active"],
                ["yy", "copy raw todo.txt line"],
                ["Space", "toggle selection"]
              ]
            }

            HelpSection {
              title: "VIEW & FILTERS"
              shortcuts: [
                ["fp / fc", "project / context filters"],
                ["Ctrl+A", "clear project/context filter"],
                ["/ / Ctrl+K", "focus search"],
                ["Ctrl+N / Ctrl+P", "navigate while searching"],
                ["in:open/all/done/due/rec", "search scope"],
                ["j / ↓ / Ctrl+N", "next sidebar filter"],
                ["k / ↑ / Ctrl+P", "previous sidebar filter"],
                ["Space", "toggle highlighted filter"],
                ["D", "toggle density"],
                ["S", "cycle sort mode"],
                ["? / Esc", "help / back"]
              ]
            }
          }
        }
      }

      Column {
        visible: root.panelMode === "settings"
        width: parent.width
        spacing: Style.space(12)

        Text {
          text: "Bar position"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }

        Row {
          spacing: Style.space(16)
          Repeater {
            model: ["left", "center", "right"]
            TextAction {
              required property string modelData
              label: modelData.charAt(0).toUpperCase() + modelData.slice(1)
              onActivated: {
                if (placementProcess.running) return
                placementProcess.command = ["omarchy", "bar", "move", root.moduleName, "--section", modelData]
                placementProcess.running = true
              }
            }
          }
        }

        Text {
          width: parent.width
          text: "Todo file"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Text {
          width: parent.width
          text: "Choose the absolute path to your todo.txt file. The archive will use done.txt in the same folder."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        TextField {
          id: settingsPathField
          width: parent.width
          placeholderText: root.defaultTodoPath
          foreground: root.foreground
          accent: Commons.Color.accent
          font.family: root.fontFamily
          onAccepted: root.saveTodoPath(text)
          Keys.onEscapePressed: root.hideSettings()
        }

        Text {
          visible: root.statusMessage !== ""
          width: parent.width
          text: root.statusMessage
          textFormat: Text.PlainText
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            width: (parent.width - parent.spacing) / 2
            text: "Save"
            iconText: "✓"
            bordered: true
            foreground: root.foreground
            accent: Commons.Color.accent
            fontFamily: root.fontFamily
            onClicked: root.saveTodoPath(settingsPathField.text)
          }

          Button {
            width: (parent.width - parent.spacing) / 2
            text: "Cancel"
            iconText: "×"
            bordered: true
            foreground: root.dim
            accent: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.hideSettings()
          }
        }
      }
    }
  }

  component TextAction: Item {
    id: action
    required property string label
    property string iconText: ""
    property string countText: ""
    property bool selected: false
    property bool leftAlign: false
    property bool cursorHighlighted: false
    signal activated()
    implicitWidth: actionRow.implicitWidth
    implicitHeight: Style.space(24)
    width: implicitWidth
    height: implicitHeight

    Rectangle {
      anchors.fill: parent
      anchors.margins: -Style.space(2)
      radius: Style.cornerRadius
      color: action.cursorHighlighted ? Style.hoverFillFor(root.foreground, Commons.Color.accent) : "transparent"
      border.width: action.cursorHighlighted ? 1 : 0
      border.color: Commons.Color.accent
    }

    Row {
      id: actionRow
      anchors.left: action.leftAlign ? parent.left : undefined
      anchors.horizontalCenter: action.leftAlign ? undefined : parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Text {
        id: actionIcon
        visible: action.iconText !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: action.iconText
        color: action.selected || actionMouse.containsMouse ? Commons.Color.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: action.leftAlign
          ? Math.max(0, action.width - (actionIcon.visible ? actionIcon.width + actionRow.spacing : 0)
            - (actionCount.visible ? actionCount.width + actionRow.spacing : 0))
          : implicitWidth
        text: action.label
        textFormat: Text.PlainText
        color: action.selected ? Commons.Color.accent : (actionMouse.containsMouse ? root.foreground : root.dim)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: action.selected
        font.underline: actionMouse.containsMouse
        elide: Text.ElideRight
      }

      Text {
        id: actionCount
        visible: action.countText !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: action.countText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      id: actionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: action.activated()
    }
  }

  component HelpSection: Column {
    required property string title
    required property var shortcuts
    width: parent ? parent.width : 0
    spacing: Style.space(5)

    Text {
      text: parent.title
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
    }

    Repeater {
      model: parent.shortcuts

      Row {
        required property var modelData
        width: parent.width
        spacing: Style.space(12)

        Text {
          width: Style.space(176)
          text: modelData[0]
          textFormat: Text.PlainText
          color: Commons.Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          width: parent.width - Style.space(188)
          text: modelData[1]
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
      }
    }
  }
}
