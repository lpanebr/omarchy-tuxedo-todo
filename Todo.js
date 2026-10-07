function parseLine(raw) {
  var text = String(raw).replace(/\r$/, "")
  var body = text.trim()
  var priority = /^\([A-Z]\)(?:\s|$)/.test(body) ? body.slice(1, 2) : ""
  if (priority) body = body.slice(3).trim()
  body = body.replace(/^\d{4}-\d{2}-\d{2}(?:\s+|$)/, "")
  var projects = [], contexts = [], metadata = [], title = [], due = ""
  var words = body.match(/(?:[^\s"]|"[^"]*")+/g) || []
  words.forEach(function(word) {
    if (!word) return
    if (/^\+[^+\s]+$/.test(word)) {
      if (projects.indexOf(word.slice(1)) < 0) projects.push(word.slice(1))
    } else if (/^@[^@\s]+$/.test(word)) {
      if (contexts.indexOf(word.slice(1)) < 0) contexts.push(word.slice(1))
    } else if (/^[^\s:]+:(?:"[^"]*"|[^\s:]+)$/.test(word) && !/^[a-z][a-z0-9+.-]*:\/\//i.test(word)) {
      metadata.push(word)
      if (/^due:\d{4}-\d{2}-\d{2}$/.test(word)) due = word.slice(4)
    } else title.push(word)
  })
  return { rawText: text, text: text.trim(), displayText: title.join(" "),
    priority: priority, projects: projects, contexts: contexts, metadata: metadata, due: due }
}

function parseCompletedLine(raw) {
  var text = String(raw).replace(/\r$/, "")
  var body = text.trim().replace(/^x(?:\s+|$)/, "")
  var completed = /^\d{4}-\d{2}-\d{2}(?:\s+|$)/.test(body) ? body.slice(0, 10) : ""
  if (completed) body = body.slice(10).trim()
  var task = parseLine(body)
  task.rawText = text
  task.text = text.trim()
  task.completed = true
  task.completedDate = completed
  return task
}

function absoluteOrEmpty(value) {
  var text = String(value || "").trim()
  return text.charAt(0) === "/" ? text : ""
}

// Mirrors Tuxedo: $TODO_FILE, else $TODO_DIR/todo.txt; falls back to ~/todo.txt.
function defaultTodoPath(env) {
  var file = absoluteOrEmpty(env.TODO_FILE)
  if (file) return file
  var dir = absoluteOrEmpty(env.TODO_DIR) || String(env.HOME || "")
  return dir.replace(/\/+$/, "") + "/todo.txt"
}

// $DONE_FILE only pairs with the environment's todo file; custom paths use a sibling done.txt.
function donePathFor(todoPath, customTodoPath, env) {
  var file = customTodoPath ? "" : absoluteOrEmpty(env.DONE_FILE)
  if (file) return file
  var slash = todoPath.lastIndexOf("/")
  return (slash >= 0 ? todoPath.slice(0, slash + 1) : "") + "done.txt"
}

function escapeHtml(value) {
  return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;")
}

function metadataHtml(task, color, contextColor) {
  var tags = (task.priority ? ["(" + task.priority + ")"] : [])
    .concat(task.projects.map(function(v) { return "+" + v }))
  var groups = []
  if (tags.length) groups.push(escapeHtml(tags.join("  ")))
  if (task.contexts.length) groups.push('<font color="' + escapeHtml(contextColor) + '">'
    + escapeHtml(task.contexts.map(function(v) { return "@" + v }).join("  ")) + '</font>')
  if (task.metadata.length) groups.push('<font color="' + escapeHtml(color) + '">'
    + escapeHtml(task.metadata.join("  ")) + '</font>')
  return groups.join("  ")
}

function counts(tasks, field) {
  var result = Object.create(null)
  tasks.forEach(function(task) {
    task[field].forEach(function(value) { result[value] = (result[value] || 0) + 1 })
  })
  return result
}

function filterByFacet(tasks, kind, value) {
  if (kind !== "project" && kind !== "context") return tasks
  var field = kind === "project" ? "projects" : "contexts"
  return tasks.filter(function(task) { return task[field].indexOf(value) >= 0 })
}

function localDateFromIso(value) {
  var parts = String(value || "").match(/^(\d{4})-(\d{2})-(\d{2})$/)
  if (!parts) return null
  var date = new Date(Number(parts[1]), Number(parts[2]) - 1, Number(parts[3]), 12)
  if (date.getFullYear() !== Number(parts[1]) || date.getMonth() !== Number(parts[2]) - 1
      || date.getDate() !== Number(parts[3])) return null
  return date
}

function localDateIso(date) {
  return date.getFullYear() + "-" + String(date.getMonth() + 1).padStart(2, "0")
    + "-" + String(date.getDate()).padStart(2, "0")
}

function completionHeatmap(tasks, todayIso, weekCount) {
  var today = localDateFromIso(todayIso) || new Date()
  today = new Date(today.getFullYear(), today.getMonth(), today.getDate(), 12)
  var weeks = Math.max(1, Number(weekCount) || 13)
  var start = new Date(today.getFullYear(), today.getMonth(), today.getDate() - today.getDay() - (weeks - 1) * 7, 12)
  var countsByDate = Object.create(null)
  tasks.forEach(function(task) {
    if (localDateFromIso(task.completedDate))
      countsByDate[task.completedDate] = (countsByDate[task.completedDate] || 0) + 1
  })

  var cells = []
  var monthLabels = []
  var total = 0
  var monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  for (var week = 0; week < weeks; week++) {
    var weekStart = new Date(start.getFullYear(), start.getMonth(), start.getDate() + week * 7, 12)
    var label = ""
    for (var day = 0; day < 7 && label === ""; day++) {
      var weekDay = new Date(weekStart.getFullYear(), weekStart.getMonth(), weekStart.getDate() + day, 12)
      if (weekDay.getDate() === 1) label = monthNames[weekDay.getMonth()]
    }
    if (week === 0 && label === "") label = monthNames[weekStart.getMonth()]
    monthLabels.push(label)
  }
  for (var i = 0; i < weeks * 7; i++) {
    var date = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i, 12)
    var iso = localDateIso(date)
    var future = date > today
    var count = future ? 0 : (countsByDate[iso] || 0)
    if (!future) total += count
    cells.push({ date: iso, count: count, future: future, level: Math.min(4, count) })
  }
  return { cells: cells, monthLabels: monthLabels, total: total, weeks: weeks,
    startDate: localDateIso(start), endDate: localDateIso(today) }
}

function topCompletedFacets(tasks, field, startDate, endDate, limit) {
  var facetCounts = Object.create(null)
  tasks.forEach(function(task) {
    if (!localDateFromIso(task.completedDate)
        || task.completedDate < startDate || task.completedDate > endDate) return
    task[field].forEach(function(value) { facetCounts[value] = (facetCounts[value] || 0) + 1 })
  })
  return Object.keys(facetCounts).map(function(value) {
    return { name: value, count: facetCounts[value] }
  }).sort(function(a, b) {
    return b.count - a.count || a.name.localeCompare(b.name)
  }).slice(0, Math.max(0, Number(limit) || 0))
}

function fuzzyMatch(value, query) {
  var haystack = String(value).toLowerCase()
  var needle = String(query).toLowerCase()
  var needleIndex = 0
  for (var i = 0; i < haystack.length && needleIndex < needle.length; i++) {
    if (haystack[i] === needle[needleIndex]) needleIndex++
  }
  return needleIndex === needle.length
}

function matchesSearch(task, query) {
  var tokens = String(query || "").trim().split(/\s+/).filter(function(token) { return token !== "" })
  return tokens.every(function(token) {
    if (/^in:(?:open|all|done|due|rec)$/i.test(token)) return true
    var values = String(task.text).split(/\s+/)
    var needle = token
    if (token.length > 1 && token[0] === "+") {
      values = task.projects
      needle = token.slice(1)
    } else if (token.length > 1 && token[0] === "@") {
      values = task.contexts
      needle = token.slice(1)
    }
    return values.some(function(value) { return fuzzyMatch(value, needle) })
  })
}

function searchScope(query) {
  var scope = "open"
  String(query || "").trim().split(/\s+/).forEach(function(token) {
    var match = token.toLowerCase().match(/^in:(open|all|done|due|rec)$/)
    if (match) scope = match[1]
  })
  return scope
}

function withSearchScope(query, scope) {
  var value = ["open", "all", "done", "due", "rec"].indexOf(scope) >= 0 ? scope : "open"
  var tokens = String(query || "").trim().split(/\s+/).filter(function(token) {
    return token !== "" && !/^in:(?:open|all|done|due|rec)$/i.test(token)
  })
  if (value !== "open") tokens.push("in:" + value)
  return tokens.join(" ")
}

function isRecurring(task) {
  return task.metadata.some(function(value) { return /^rec:/i.test(value) })
}
