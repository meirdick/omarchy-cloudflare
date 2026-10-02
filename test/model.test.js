const { test } = require("node:test")
const assert = require("node:assert")
const fs = require("node:fs")
const path = require("node:path")

const Model = require("../Model.js")

// Fixed clock. The fixture's last full hour is 12:00 UTC.
const NOW = Date.parse("2026-08-13T12:34:00Z")
const FIXTURES = path.join(__dirname, "..", "fixtures")
const load = name => JSON.parse(fs.readFileSync(path.join(FIXTURES, name), "utf8"))

const state = load("account.json")
const analytics = Model.reduceAnalytics(load("usage.json").data, 1, NOW)
const options = extra => Object.assign({
  deployRows: 8, overviewDeployRows: 3, filter: "", route: "", starred: [],
  limits: { workerRequestsPerDay: 0, r2StorageGb: 0, d1RowsReadPerDay: 0 },
  tokenRows: [{ kind: "token", id: "t", name: "Account API tokens", url: "https://x" }]
}, extra || {})

test("the current and previous 24 hours are split at the last full hour", () => {
  const s = analytics.series
  assert.equal(s.invocations.now, 24 * 150)
  assert.equal(s.invocations.prev, 24 * 100)
  assert.equal(s.errors.now, 24 * 3)
  assert.equal(s.invocations.points.length, 24)
  assert.equal(s.requests.now, 24 * (250 + 50))
  assert.equal(s.requests.prev, 24 * (200 + 50))
})

test("CPU P90 comes from the whole-window query, not from hourly values", () => {
  assert.equal(analytics.series.cpuP90.now, 8134)
  assert.equal(analytics.series.cpuP90.prev, 8259)
})

test("cache hit rate is cached requests over requests", () => {
  assert.equal(analytics.series.cacheHit.now, (24 * 25) / (24 * 300))
  assert.equal(analytics.series.cacheHit.prev, (24 * 30) / (24 * 250))
})

test("R2 storage is the sum of per-bucket maxima, not of rows", () => {
  assert.equal(analytics.r2Bytes, 3000 + 5000)
  assert.equal(analytics.r2Objects, 30 + 5)
})

test("a Worker over the error threshold is counted, an idle one is not", () => {
  assert.equal(analytics.perWorker["api-gateway"].errorRate, 2)
  assert.equal(analytics.workersOverErrorRate, 2)
})

test("tiles show the dashboard figures with the change against the day before", () => {
  const tiles = Model.buildTiles(analytics, options().limits, { zones: 2, workers: 3, buckets: 2 })
  assert.deepEqual(tiles.map(t => t.id), ["requests", "invocations", "errors", "cache", "cpu", "r2"])
  const byId = Object.fromEntries(tiles.map(t => [t.id, t]))
  assert.equal(byId.invocations.delta, "↗ 50.0%")
  assert.equal(byId.invocations.worse, false)
  assert.equal(byId.errors.delta, "↗ 200%")
  assert.equal(byId.errors.worse, true)
  assert.equal(byId.cpu.value, "8.1 ms")
  assert.equal(byId.cpu.worse, false)
  assert.equal(byId.r2.note, "35 objects")
})

test("an allowance turns a tile into a meter and flags it at 90%", () => {
  const limits = { workerRequestsPerDay: 3800, r2StorageGb: 0, d1RowsReadPerDay: 0 }
  const tiles = Model.buildTiles(analytics, limits, { zones: 2, workers: 3, buckets: 2 })
  const inv = tiles.find(t => t.id === "invocations")
  assert.ok(inv.meter > 0.9)
  assert.equal(inv.alarming, true)
})

test("no earlier figure means no arrow", () => {
  assert.equal(Model.deltaPercent(10, 0), null)
  assert.equal(Model.formatDelta(null), "")
  assert.equal(Model.formatDelta(0), "")
})

test("the overview names what is broken and puts domains first", () => {
  const rows = Model.buildRows(state, analytics, options())
  const attention = rows.filter(r => r.section === "NEEDS ATTENTION").map(r => r.name)
  assert.deepEqual(attention.sort(), ["api-gateway", "docs", "example.dev", "image-resizer"])
  const groups = rows.filter(r => r.kind === "group" && r.target !== "token").map(r => r.target)
  assert.equal(groups[0], "zone")
  const tiles = rows.find(r => r.kind === "tiles")
  assert.equal(tiles.selectable, false)
  assert.equal(rows.find(r => r.target === "zone").name, "Domains")
})

test("starred resources get their own section and lead their type view", () => {
  const starred = ["r2:nightly-backups"]
  const overview = Model.buildRows(state, analytics, options({ starred }))
  assert.deepEqual(overview.filter(r => r.section === "STARRED").map(r => r.name), ["nightly-backups"])
  const view = Model.buildRows(state, analytics, options({ starred, route: "r2" }))
  assert.equal(view[0].name, "nightly-backups")
  assert.equal(view[0].starred, true)
})

test("toggling a star adds it once and removes it again", () => {
  const on = Model.toggleStar([], "zone:z1")
  assert.deepEqual(on, ["zone:z1"])
  assert.deepEqual(Model.toggleStar(on, "zone:z1"), [])
})

test("live addresses prefer a custom domain and never guess workers.dev", () => {
  const workers = Model.resourcesOf("worker", state, analytics, [])
  const host = name => workers.find(w => w.name === name).liveHost
  assert.equal(host("api-gateway"), "api.example.com")
  assert.equal(host("image-resizer"), "image-resizer.acme.workers.dev")
  assert.equal(host("webhook-relay"), "")
  const pages = Model.resourcesOf("pages", state, analytics, [])
  assert.equal(pages.find(p => p.name === "marketing-site").liveHost, "www.example.com")
})

test("search matches names, hostnames and type names", () => {
  const byHost = Model.buildRows(state, analytics, options({ filter: "api.example" }))
  assert.deepEqual(byHost.map(r => r.name), ["api-gateway"])
  const byType = Model.buildRows(state, analytics, options({ filter: "domains" }))
  assert.deepEqual(byType.map(r => r.name).sort(), ["example.com", "example.dev"])
})

test("a failed Pages build reads as failed in recent deploys", () => {
  const rows = Model.buildDeploys(state.workers, state.pages, 8, null)
  const docs = rows.find(r => r.name === "docs")
  assert.equal(docs.failed, true)
  assert.equal(docs.detail, "Pages · build failure")
  assert.equal(Model.failedDeployCount(rows), 1)
})
