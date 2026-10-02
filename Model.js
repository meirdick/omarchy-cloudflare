// Row building and formatting. Pure JavaScript: no Qt, no processes. It runs
// inside QML and under plain node, where test/ checks it against fixtures.
//
// The panel has three views:
//   overview   what is broken, starred resources, the dashboard figures,
//              recent deploys, and one row per resource type
//   type view  all resources of one type, busiest first
//   search     every resource of every type, from any view

// ---------------------------------------------------------------- formatting

function formatBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n <= 0) return "0 B"
  var units = ["B", "KB", "MB", "GB", "TB", "PB"]
  var i = 0
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
  return (n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)) + " " + units[i]
}

function formatCount(value) {
  var n = Number(value)
  if (!isFinite(n)) return "—"
  if (n < 1000) return String(Math.round(n))
  if (n < 1000000) return (n / 1000).toFixed(n < 10000 ? 1 : 0) + "k"
  if (n < 1000000000) return (n / 1000000).toFixed(n < 10000000 ? 1 : 0) + "M"
  return (n / 1000000000).toFixed(1) + "B"
}

// Short on purpose. "3d" says the same as "3 days ago" in less space.
function relativeTime(thenMs, nowMs) {
  var then = Number(thenMs)
  if (!isFinite(then) || then <= 0) return ""
  var delta = Math.max(0, Number(nowMs) - then)
  var minutes = Math.floor(delta / 60000)
  if (minutes < 1) return "just now"
  if (minutes < 60) return minutes + "m"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h"
  var days = Math.floor(hours / 24)
  if (days < 30) return days + "d"
  var months = Math.floor(days / 30)
  if (months < 12) return months + "mo"
  return Math.floor(months / 12) + "y"
}

// Full number with commas, for tooltips. The row shows "128k".
function formatExact(value) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return "—"
  var sign = n < 0 ? "-" : ""
  var digits = String(Math.abs(n))
  var out = ""
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 === 0) out += ","
    out += digits[i]
  }
  return sign + out
}

function two(n) { return (n < 10 ? "0" : "") + n }

// "13 Aug 2026, 09:10", in local time.
function absoluteTime(ms) {
  var t = Number(ms)
  if (!isFinite(t) || t <= 0) return ""
  var d = new Date(t)
  var months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
  return d.getDate() + " " + months[d.getMonth()] + " " + d.getFullYear()
    + ", " + two(d.getHours()) + ":" + two(d.getMinutes())
}

function parseTime(value) {
  if (!value) return 0
  var ms = Date.parse(String(value))
  return isFinite(ms) ? ms : 0
}

// ---------------------------------------------------------------- glyphs

// Written as escapes. Every codepoint was checked against the cmap of
// JetBrainsMono Nerd Font. A missing glyph draws as a box, or as some other
// character that looks intended: the first set here all drew as "«".
var GLYPH_STAR = ""
var GLYPH_SEARCH = ""

function glyphFor(kind) {
  switch (kind) {
  case "worker": return ""  // bolt
  case "pages":  return ""  // code
  case "r2":     return ""  // archive
  case "d1":     return ""  // database
  case "kv":     return ""  // key
  case "queue":  return ""  // inbox
  case "zone":   return ""  // globe
  case "token":  return ""  // shield
  }
  return ""                 // cloud
}

// One name per type, used for the group row and the type view title.
// Zones are "Domains", as in the current Cloudflare dashboard.
function typeLabel(kind) {
  switch (kind) {
  case "worker": return "Workers"
  case "pages":  return "Pages"
  case "r2":     return "R2 buckets"
  case "d1":     return "D1 databases"
  case "kv":     return "KV namespaces"
  case "queue":  return "Queues"
  case "zone":   return "Domains"
  case "token":  return "Create a token"
  }
  return kind
}

// Dashboard order: domains first, then compute, then storage.
var RESOURCE_KINDS = ["zone", "worker", "pages", "r2", "d1", "kv", "queue"]

// ---------------------------------------------------------------- live URLs

// The address a resource serves on, as the dashboard prints it under each
// application name. A custom domain wins over the platform hostname.
//
// `<name>.<subdomain>.workers.dev` is used only when the account says the
// script has that route on. Some Workers have it off, and a guessed link
// would give a 404.
function workerLiveHost(name, state) {
  var custom = state.workerDomains ? state.workerDomains[name] : ""
  if (custom) return String(custom)
  if (state.accountSubdomain && state.workerDotDev && state.workerDotDev[name] === true)
    return name + "." + state.accountSubdomain + ".workers.dev"
  return ""
}

function pagesLiveHost(project) {
  var domains = Array.isArray(project.domains) ? project.domains : []
  for (var i = 0; i < domains.length; i++) {
    var host = String(domains[i] || "")
    if (host && host.indexOf(".pages.dev") < 0) return host
  }
  return String(project.subdomain || (domains.length ? domains[0] : ""))
}

function hostToUrl(host) {
  var h = String(host || "").trim()
  if (!h) return ""
  return /^https?:\/\//.test(h) ? h : "https://" + h
}

// Name to hostname for Workers and Pages, so a deploy row links to the same
// site as its resource row.
function buildLiveHosts(state) {
  var worker = {}
  var pages = {}
  var i
  for (i = 0; i < state.workers.length; i++) {
    var wn = String(state.workers[i].id || "")
    var wh = workerLiveHost(wn, state)
    if (wh) worker[wn] = wh
  }
  for (i = 0; i < state.pages.length; i++) {
    var ph = pagesLiveHost(state.pages[i])
    if (ph) pages[String(state.pages[i].name || "")] = ph
  }
  return { worker: worker, pages: pages }
}

// ---------------------------------------------------------------- deployments

// Workers and Pages report deploys in different shapes. Both become
// {name, target, detail, whenMs} so one list can sort them.
//
// A Worker script has no build status, only a change time. Pages projects
// carry the real build stage, which is where a failure shows.
function buildDeploys(workers, pages, limit, liveHosts) {
  var rows = []
  var i

  for (i = 0; i < workers.length; i++) {
    var w = workers[i]
    var name = String(w.id || "")
    var host = liveHosts ? String(liveHosts.worker[name] || "") : ""
    var via = String(w.last_deployed_from || "")
    rows.push({
      kind: "deploy", target: "worker", name: name,
      detail: "Worker" + (via ? " · " + via : ""),
      failed: false,
      liveHost: host, liveUrl: hostToUrl(host),
      whenMs: parseTime(w.modified_on || w.created_on)
    })
  }

  for (i = 0; i < pages.length; i++) {
    var p = pages[i]
    var pname = String(p.name || "")
    var latest = p.latest_deployment
    var stage = latest && latest.latest_stage ? latest.latest_stage : null
    var status = stage ? String(stage.status || "") : ""
    var failed = status === "failure" || status === "canceled"
    var phost = liveHosts ? String(liveHosts.pages[pname] || "") : ""
    rows.push({
      kind: "deploy", target: "pages", name: pname,
      detail: "Pages · " + (failed ? (stage.name || "build") + " " + status
        : (status === "success" || status === "" ? "deployed" : status)),
      failed: failed,
      liveHost: phost, liveUrl: hostToUrl(phost),
      whenMs: latest ? parseTime(latest.created_on) : 0
    })
  }

  rows.sort(function(a, b) { return b.whenMs - a.whenMs })
  var cap = Math.max(1, Number(limit) || 8)
  return rows.slice(0, cap)
}

function failedDeployCount(rows) {
  var n = 0
  for (var i = 0; i < rows.length; i++) if (rows[i].failed) n++
  return n
}

// ---------------------------------------------------------------- analytics

var HOUR = 3600000

function emptySeries() {
  return { now: 0, prev: 0, points: [] }
}

function emptyAnalytics() {
  return {
    loaded: false,
    perWorker: {}, perBucket: {}, perDatabase: {}, perZone: {},
    r2Bytes: 0, r2Objects: 0, d1RowsRead: 0, d1RowsWritten: 0,
    workersOverErrorRate: 0,
    series: {
      requests: emptySeries(), invocations: emptySeries(), errors: emptySeries(),
      cacheHit: emptySeries(), cpuP90: emptySeries()
    }
  }
}

function num(value) {
  var n = Number(value)
  return isFinite(n) ? n : 0
}

function list(value) {
  return Array.isArray(value) ? value : []
}

// Slot of an hour stamp in the 48-hour window that ends at the last full hour.
// Slots 0-23 are the previous 24 hours, slots 24-47 the current 24 hours.
function hourSlot(stamp, windowStartMs) {
  var t = parseTime(stamp)
  if (!t) return -1
  var slot = Math.floor((t - windowStartMs) / HOUR)
  return slot >= 0 && slot < 48 ? slot : -1
}

function zeros(n) {
  var out = []
  for (var i = 0; i < n; i++) out.push(0)
  return out
}

function sumRange(values, from, to) {
  var s = 0
  for (var i = from; i < to; i++) s += values[i]
  return s
}

// Turns the GraphQL answer from Api.usageQuery into per-resource maps and
// the six dashboard figures. Pure, so test/ can drive it with a fixture.
function reduceAnalytics(data, errorRatePercent, nowMs) {
  var out = emptyAnalytics()
  out.loaded = true

  var viewer = (data && data.viewer) || {}
  var account = list(viewer.accounts)[0] || {}
  var windowStart = Math.floor(num(nowMs) / HOUR) * HOUR - 48 * HOUR
  var threshold = num(errorRatePercent) || 1
  var i

  // Per-Worker figures for the current 24 hours.
  var scripts = list(account.scripts)
  for (i = 0; i < scripts.length; i++) {
    var sc = scripts[i]
    var name = String(sc.dimensions ? sc.dimensions.scriptName : "")
    var req = num(sc.sum && sc.sum.requests)
    var err = num(sc.sum && sc.sum.errors)
    var rate = req > 0 ? (err / req) * 100 : 0
    out.perWorker[name] = { requests: req, errors: err, errorRate: rate }
    if (req > 0 && rate >= threshold) out.workersOverErrorRate++
  }

  // Account-wide Worker totals, hour by hour.
  var inv = zeros(48)
  var errs = zeros(48)
  var cpu = zeros(48)
  var hourly = list(account.hourly)
  for (i = 0; i < hourly.length; i++) {
    var h = hourly[i]
    var slot = hourSlot(h.dimensions && h.dimensions.datetimeHour, windowStart)
    if (slot < 0) continue
    inv[slot] += num(h.sum && h.sum.requests)
    errs[slot] += num(h.sum && h.sum.errors)
    cpu[slot] = num(h.quantiles && h.quantiles.cpuTimeP90)
  }
  out.series.invocations = { now: sumRange(inv, 24, 48), prev: sumRange(inv, 0, 24), points: inv.slice(24) }
  out.series.errors = { now: sumRange(errs, 24, 48), prev: sumRange(errs, 0, 24), points: errs.slice(24) }
  var cpuNow = list(account.cpuNow)[0]
  var cpuPrev = list(account.cpuPrev)[0]
  out.series.cpuP90 = {
    now: num(cpuNow && cpuNow.quantiles && cpuNow.quantiles.cpuTimeP90),
    prev: num(cpuPrev && cpuPrev.quantiles && cpuPrev.quantiles.cpuTimeP90),
    points: cpu.slice(24)
  }

  // R2 reports a running maximum per bucket, so the total is the sum of the
  // per-bucket maxima, not a sum of rows.
  var storage = list(account.r2StorageAdaptiveGroups)
  for (i = 0; i < storage.length; i++) {
    var st = storage[i]
    var bucket = String(st.dimensions ? st.dimensions.bucketName : "")
    var bytes = num(st.max && st.max.payloadSize)
    var objects = num(st.max && st.max.objectCount)
    var prior = out.perBucket[bucket]
    out.perBucket[bucket] = prior
      ? { bytes: Math.max(prior.bytes, bytes), objects: Math.max(prior.objects, objects) }
      : { bytes: bytes, objects: objects }
  }
  for (var b in out.perBucket) {
    out.r2Bytes += out.perBucket[b].bytes
    out.r2Objects += out.perBucket[b].objects
  }

  var d1 = list(account.d1AnalyticsAdaptiveGroups)
  for (i = 0; i < d1.length; i++) {
    var d = d1[i]
    var dbId = String(d.dimensions ? d.dimensions.databaseId : "")
    var db = out.perDatabase[dbId] || { rowsRead: 0, rowsWritten: 0 }
    db.rowsRead += num(d.sum && d.sum.rowsRead)
    db.rowsWritten += num(d.sum && d.sum.rowsWritten)
    out.perDatabase[dbId] = db
    out.d1RowsRead += num(d.sum && d.sum.rowsRead)
    out.d1RowsWritten += num(d.sum && d.sum.rowsWritten)
  }

  // Domains, hour by hour, summed across all zones on the account.
  var zreq = zeros(48)
  var zcached = zeros(48)
  var zones = list(viewer.zones)
  for (i = 0; i < zones.length; i++) {
    var z = zones[i]
    var tag = String(z.zoneTag || "")
    var agg = { requests: 0, bytes: 0, threats: 0 }
    var groups = list(z.httpRequests1hGroups)
    for (var g = 0; g < groups.length; g++) {
      var zs = hourSlot(groups[g].dimensions && groups[g].dimensions.datetime, windowStart)
      if (zs < 0) continue
      var sum = groups[g].sum || {}
      zreq[zs] += num(sum.requests)
      zcached[zs] += num(sum.cachedRequests)
      if (zs >= 24) {
        agg.requests += num(sum.requests)
        agg.bytes += num(sum.bytes)
        agg.threats += num(sum.threats)
      }
    }
    out.perZone[tag] = agg
  }
  out.series.requests = { now: sumRange(zreq, 24, 48), prev: sumRange(zreq, 0, 24), points: zreq.slice(24) }

  // Cache hit rate by request count. An hour with no requests has no rate.
  var hit = []
  for (i = 24; i < 48; i++) hit.push(zreq[i] > 0 ? zcached[i] / zreq[i] : 0)
  var nowReq = out.series.requests.now
  var prevReq = out.series.requests.prev
  out.series.cacheHit = {
    now: nowReq > 0 ? sumRange(zcached, 24, 48) / nowReq : 0,
    prev: prevReq > 0 ? sumRange(zcached, 0, 24) / prevReq : 0,
    points: hit
  }

  return out
}

// Change against the previous 24 hours, in percent. Null when there is no
// earlier figure to compare with.
function deltaPercent(now, prev) {
  if (!(prev > 0)) return null
  return ((now - prev) / prev) * 100
}

// "↗ 24.5%". Empty for no change, so a flat metric shows no arrow.
function formatDelta(pct) {
  if (pct === null || !isFinite(pct)) return ""
  if (Math.abs(pct) < 0.05) return ""
  var size = Math.abs(pct)
  return (pct > 0 ? "↗ " : "↘ ") + (size >= 100 ? Math.round(size) : size.toFixed(1)) + "%"
}

function formatMs(micros) {
  var ms = num(micros) / 1000
  if (ms <= 0) return "0 ms"
  return (ms < 10 ? ms.toFixed(1) : Math.round(ms)) + " ms"
}

function formatPercent(ratio) {
  var p = num(ratio) * 100
  return (p < 10 ? p.toFixed(2) : p.toFixed(1)) + "%"
}

// One dashboard figure. `goodWhenUp` sets the colour of the change: more
// requests is fine, more errors is not.
function tile(id, title, value, series, goodWhenUp, tooltip) {
  var pct = series ? deltaPercent(series.now, series.prev) : null
  return {
    id: id, title: title, value: value,
    delta: formatDelta(pct),
    worse: pct !== null && Math.abs(pct) >= 0.05 && ((pct > 0) !== goodWhenUp),
    points: series ? series.points : [],
    tooltip: tooltip || "", meter: -1, note: ""
  }
}

// The six figures of the dashboard analytics page, as far as the API allows.
// "Total requests" there also counts traffic this plugin cannot see, so the
// tile says "Domain requests" and counts domain traffic only.
function buildTiles(analytics, limits, counts) {
  var tiles = []
  if (!analytics || !analytics.loaded) return tiles
  var s = analytics.series
  var c = counts || {}

  if (c.zones > 0) {
    tiles.push(tile("requests", "Domain requests", formatCount(s.requests.now), s.requests, true,
      formatExact(s.requests.now) + " requests in the last 24 hours, "
        + formatExact(s.requests.prev) + " the 24 hours before"))
  }

  if (c.workers > 0) {
    var inv = tile("invocations", "Worker invocations", formatCount(s.invocations.now), s.invocations, true,
      formatExact(s.invocations.now) + " invocations in the last 24 hours, "
        + formatExact(s.invocations.prev) + " the 24 hours before")
    if (limits && limits.workerRequestsPerDay > 0) {
      inv.meter = s.invocations.now / limits.workerRequestsPerDay
      inv.tooltip += ". Allowance " + formatExact(limits.workerRequestsPerDay) + " a day"
    }
    tiles.push(inv)

    var errTile = tile("errors", "Worker errors", formatCount(s.errors.now), s.errors, false,
      formatExact(s.errors.now) + " errors in the last 24 hours, "
        + formatExact(s.errors.prev) + " the 24 hours before")
    errTile.alarming = s.errors.now > 0
    tiles.push(errTile)
  }

  if (c.zones > 0) {
    tiles.push(tile("cache", "Cache hit rate", formatPercent(s.cacheHit.now), s.cacheHit, true,
      "Share of domain requests served from cache, by request count"))
  }

  if (c.workers > 0 && s.cpuP90.now > 0) {
    tiles.push(tile("cpu", "CPU time P90", formatMs(s.cpuP90.now), s.cpuP90, false,
      "90% of Worker invocations used less CPU time than this"))
  }

  if (c.buckets > 0) {
    var r2 = tile("r2", "R2 storage", formatBytes(analytics.r2Bytes), null, true,
      formatExact(analytics.r2Bytes) + " bytes in " + formatExact(analytics.r2Objects) + " objects")
    r2.note = formatCount(analytics.r2Objects) + " objects"
    if (limits && limits.r2StorageGb > 0) {
      r2.meter = analytics.r2Bytes / (limits.r2StorageGb * 1073741824)
      r2.tooltip += ". Allowance " + limits.r2StorageGb + " GB"
    }
    tiles.push(r2)
  }

  // An allowance, when set, turns the figure red at 90%.
  for (var i = 0; i < tiles.length; i++) if (tiles[i].meter >= 0.9) tiles[i].alarming = true
  return tiles
}

// ---------------------------------------------------------------- stars

// A star is stored as "<kind>:<id>". Names can repeat across kinds, ids cannot.
function starKey(row) {
  if (!row || RESOURCE_KINDS.indexOf(row.kind) < 0) return ""
  return row.kind + ":" + String(row.id || row.name || "")
}

function toggleStar(starred, key) {
  var out = list(starred).slice()
  if (!key) return out
  var at = out.indexOf(key)
  if (at >= 0) out.splice(at, 1)
  else out.push(key)
  return out
}

// ---------------------------------------------------------------- resources

// Every resource of one kind, in the row shape the panel draws. `weight`
// sorts the type view: the busiest Worker and the largest bucket come first.
function resourcesOf(kind, state, analytics, starred) {
  var rows = []
  var i

  if (kind === "worker") {
    for (i = 0; i < state.workers.length; i++) {
      var w = state.workers[i]
      var wname = String(w.id || "")
      var ws = analytics.perWorker[wname]
      var whost = workerLiveHost(wname, state)
      var wbad = !!(ws && ws.requests > 0 && ws.errorRate >= state.errorRateThreshold)
      rows.push({
        kind: "worker", name: wname, id: wname,
        liveHost: whost, liveUrl: hostToUrl(whost),
        weight: ws ? ws.requests : -1,
        detail: ws && ws.requests > 0
          ? formatCount(ws.requests) + " req/24h" + (ws.errors > 0 ? " · " + formatCount(ws.errors) + " errors" : "")
          : "idle",
        alarming: wbad,
        reason: wbad ? ws.errorRate.toFixed(1) + "% errors" : ""
      })
    }
  } else if (kind === "pages") {
    for (i = 0; i < state.pages.length; i++) {
      var p = state.pages[i]
      var stage = p.latest_deployment && p.latest_deployment.latest_stage
        ? p.latest_deployment.latest_stage : null
      var pbad = !!(stage && (stage.status === "failure" || stage.status === "canceled"))
      var phost = pagesLiveHost(p)
      var when = p.latest_deployment ? parseTime(p.latest_deployment.created_on) : 0
      rows.push({
        kind: "pages", name: String(p.name || ""), id: String(p.id || p.name || ""),
        liveHost: phost, liveUrl: hostToUrl(phost),
        weight: when,
        detail: when ? "deployed " + absoluteTime(when) : "no deploys",
        alarming: pbad,
        reason: pbad ? "last " + (stage.name || "build") + " " + stage.status : ""
      })
    }
  } else if (kind === "r2") {
    for (i = 0; i < state.buckets.length; i++) {
      var bk = state.buckets[i]
      var bname = String(bk.name || "")
      var bs = analytics.perBucket[bname]
      rows.push({
        kind: "r2", name: bname, id: bname,
        weight: bs ? bs.bytes : -1,
        detail: bs ? formatBytes(bs.bytes) + " · " + formatCount(bs.objects) + " objects" : "empty"
      })
    }
  } else if (kind === "d1") {
    for (i = 0; i < state.databases.length; i++) {
      var db = state.databases[i]
      var did = String(db.uuid || db.id || "")
      var ds = analytics.perDatabase[did]
      rows.push({
        kind: "d1", name: String(db.name || ""), id: did,
        weight: ds ? ds.rowsRead : -1,
        detail: ds && ds.rowsRead > 0
          ? formatCount(ds.rowsRead) + " rows read/24h"
          : (db.file_size ? formatBytes(db.file_size) : "idle")
      })
    }
  } else if (kind === "kv") {
    for (i = 0; i < state.namespaces.length; i++) {
      var k = state.namespaces[i]
      rows.push({ kind: "kv", name: String(k.title || ""), id: String(k.id || ""), weight: 0, detail: "" })
    }
  } else if (kind === "queue") {
    for (i = 0; i < state.queues.length; i++) {
      var q = state.queues[i]
      var consumers = list(q.consumers).length
      rows.push({
        kind: "queue", name: String(q.queue_name || q.name || ""), id: String(q.queue_id || q.id || ""),
        weight: consumers,
        detail: consumers > 0 ? consumers + (consumers === 1 ? " consumer" : " consumers") : "no consumers"
      })
    }
  } else if (kind === "zone") {
    for (i = 0; i < state.zones.length; i++) {
      var z = state.zones[i]
      var zid = String(z.id || "")
      var zs = analytics.perZone[zid]
      var zactive = String(z.status || "") === "active"
      rows.push({
        kind: "zone", name: String(z.name || ""), id: zid,
        liveHost: String(z.name || ""), liveUrl: hostToUrl(z.name),
        weight: zs ? zs.requests : -1,
        detail: zs && zs.requests > 0
          ? formatCount(zs.requests) + " req/24h · " + formatBytes(zs.bytes)
          : String(z.status || ""),
        alarming: !zactive,
        reason: zactive ? "" : "domain is " + String(z.status || "inactive")
      })
    }
  }

  var stars = list(starred)
  for (i = 0; i < rows.length; i++) rows[i].starred = stars.indexOf(starKey(rows[i])) >= 0
  return rows
}

function allResources(state, analytics, starred) {
  var all = []
  for (var i = 0; i < RESOURCE_KINDS.length; i++)
    all = all.concat(resourcesOf(RESOURCE_KINDS[i], state, analytics, starred))
  return all
}

// Busiest and largest first. Ties sort by name, so the order stays the same
// between refreshes.
function bySignificance(a, b) {
  if (b.weight !== a.weight) return b.weight - a.weight
  return String(a.name).localeCompare(String(b.name))
}

// Starred first, then by significance.
function starredFirst(a, b) {
  if (a.starred !== b.starred) return a.starred ? -1 : 1
  return bySignificance(a, b)
}

function matchesFilter(row, filter) {
  if (!filter) return true
  var needle = filter.toLowerCase()
  return String(row.name || "").toLowerCase().indexOf(needle) >= 0
    || typeLabel(row.kind).toLowerCase().indexOf(needle) >= 0
    || String(row.liveHost || "").toLowerCase().indexOf(needle) >= 0
}

// ---------------------------------------------------------------- flattening

// The section title is carried on the first row of each group, not on a row of
// its own, so the cursor never lands on a header.
function flatten(groups) {
  var rows = []
  for (var g = 0; g < groups.length; g++) {
    var group = groups[g]
    if (!group.rows || group.rows.length === 0) continue
    for (var i = 0; i < group.rows.length; i++) {
      var row = group.rows[i]
      row.section = group.title
      row.sectionTitle = i === 0 ? group.title : ""
      row.index = rows.length
      rows.push(row)
    }
  }
  return rows
}

// ---------------------------------------------------------------- overview

// One row per type: the count and one figure worth knowing.
function groupRow(kind, state, analytics, options) {
  var rows = resourcesOf(kind, state, analytics, options.starred)
  var s = analytics.series
  var detail = ""
  var bad = 0
  var i

  for (i = 0; i < rows.length; i++) if (rows[i].alarming) bad++

  if (!analytics.loaded) detail = ""
  else if (kind === "zone") detail = formatCount(s.requests.now) + " req/24h"
  else if (kind === "worker") detail = formatCount(s.invocations.now) + " invocations/24h"
  else if (kind === "r2") detail = formatBytes(analytics.r2Bytes)
  else if (kind === "d1") {
    var allowance = options.limits ? options.limits.d1RowsReadPerDay : 0
    detail = formatCount(analytics.d1RowsRead) + (allowance > 0 ? " / " + formatCount(allowance) : "") + " rows read/24h"
  } else if (kind === "queue") {
    var consumers = 0
    for (i = 0; i < rows.length; i++) consumers += num(rows[i].weight)
    detail = consumers + (consumers === 1 ? " consumer" : " consumers")
  }

  if (bad > 0) detail = bad + (bad === 1 ? " needs attention" : " need attention")

  return {
    kind: "group", target: kind, name: typeLabel(kind),
    count: rows.length, detail: detail, alarming: bad > 0
  }
}

function buildOverview(state, analytics, options) {
  var groups = []
  var everything = allResources(state, analytics, options.starred)
  var i

  // Anything failing, by name: a count of broken things does not say what
  // to fix.
  var attention = []
  for (i = 0; i < everything.length; i++) {
    if (!everything[i].alarming) continue
    var row = everything[i]
    row.detail = row.reason || row.detail
    attention.push(row)
  }
  attention.sort(bySignificance)
  groups.push({ title: "NEEDS ATTENTION", rows: attention })

  // Starred resources, in the order they were starred.
  var stars = list(options.starred)
  var starredRows = []
  for (i = 0; i < stars.length; i++) {
    for (var j = 0; j < everything.length; j++) {
      if (starKey(everything[j]) !== stars[i]) continue
      if (!everything[j].alarming) starredRows.push(everything[j])
      break
    }
  }
  groups.push({ title: "STARRED", rows: starredRows })

  // Resource types come before the figures, as on the dashboard home page:
  // they are what you navigate by.
  var typeRows = []
  for (i = 0; i < RESOURCE_KINDS.length; i++) {
    var group = groupRow(RESOURCE_KINDS[i], state, analytics, options)
    if (group.count > 0) typeRows.push(group)
  }
  groups.push({ title: "RESOURCES", rows: typeRows })

  // The dashboard figures, as one row of tiles.
  var tiles = buildTiles(analytics, options.limits, {
    zones: state.zones.length, workers: state.workers.length, buckets: state.buckets.length
  })
  if (tiles.length > 0)
    groups.push({ title: "ANALYTICS \u00b7 24H", rows: [{ kind: "tiles", tiles: tiles, selectable: false }] })

  groups.push({
    title: "RECENT DEPLOYS",
    rows: buildDeploys(state.workers, state.pages, options.overviewDeployRows, buildLiveHosts(state))
  })

  groups.push({
    title: "SHORTCUTS",
    rows: [{
      kind: "group", target: "token", name: typeLabel("token"),
      count: list(options.tokenRows).length,
      detail: "account, user, R2, AI Gateway, Turnstile", alarming: false
    }]
  })

  return flatten(groups)
}

// ---------------------------------------------------------------- type view

function buildTypeView(kind, state, analytics, options) {
  if (kind === "token")
    return flatten([{ title: "CREATE A TOKEN", rows: list(options.tokenRows).slice() }])

  var rows = resourcesOf(kind, state, analytics, options.starred)
  rows.sort(starredFirst)
  return flatten([{ title: typeLabel(kind).toUpperCase(), rows: rows }])
}

// ---------------------------------------------------------------- search

// Search covers every resource of every type, from any view.
function buildSearch(state, analytics, options) {
  var matched = []
  var everything = allResources(state, analytics, options.starred)
  for (var i = 0; i < everything.length; i++)
    if (matchesFilter(everything[i], options.filter)) matched.push(everything[i])
  matched.sort(starredFirst)

  if (matched.length === 0) {
    return flatten([{
      title: "SEARCH",
      rows: [{ kind: "empty", name: "Nothing matches “" + options.filter + "”", selectable: false }]
    }])
  }
  return flatten([{ title: matched.length + (matched.length === 1 ? " MATCH" : " MATCHES"), rows: matched }])
}

// ---------------------------------------------------------------- entry point

function buildRows(state, analytics, options) {
  if (options.filter) return buildSearch(state, analytics, options)
  if (options.route) return buildTypeView(options.route, state, analytics, options)
  return buildOverview(state, analytics, options)
}

if (typeof module !== "undefined") {
  module.exports = {
    GLYPH_STAR: GLYPH_STAR,
    GLYPH_SEARCH: GLYPH_SEARCH,
    RESOURCE_KINDS: RESOURCE_KINDS,
    formatBytes: formatBytes,
    formatCount: formatCount,
    formatExact: formatExact,
    formatDelta: formatDelta,
    relativeTime: relativeTime,
    absoluteTime: absoluteTime,
    glyphFor: glyphFor,
    typeLabel: typeLabel,
    workerLiveHost: workerLiveHost,
    pagesLiveHost: pagesLiveHost,
    buildDeploys: buildDeploys,
    failedDeployCount: failedDeployCount,
    emptyAnalytics: emptyAnalytics,
    reduceAnalytics: reduceAnalytics,
    deltaPercent: deltaPercent,
    buildTiles: buildTiles,
    starKey: starKey,
    toggleStar: toggleStar,
    resourcesOf: resourcesOf,
    buildRows: buildRows
  }
}
