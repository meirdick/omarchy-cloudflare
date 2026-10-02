import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Api.js" as Api
import "Model.js" as Model

Panel {
  id: root
  moduleName: "mdick.cloudflare"
  ipcTarget: "mdick.cloudflare"
  manageIpc: false

  // --- theme ---------------------------------------------------------------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Util.alpha(foreground, 0.14)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color barIconColor: cf.loggedIn ? barForeground : Qt.darker(barForeground, 1.55)

  // --- cursor --------------------------------------------------------------
  // One flat index over one ListView. The panel body is heterogeneous, but
  // every row is a row, so navigation does not need to know which section it
  // is in — which is what a per-section index model would have forced.
  property bool cursorActive: false
  property int cursorIndex: 0
  property string filter: ""
  property bool filtering: false
  property var pendingAction: null

  // "" is the overview; anything else is a resource type being drilled into.
  // The overview shows counts, not resources, so the panel opens at about
  // twenty rows instead of ninety.
  property string route: ""
  // Where the cursor was in the overview, restored on the way back out. Coming
  // back from Workers to find the cursor reset to the top is the small thing
  // that makes a drill-down feel like a maze.
  property int overviewCursor: 0

  // Starred resources, as "<kind>:<id>". Saved in this widget's entry in
  // shell.json, like the tray saves its pinned items.
  property var starred: []
  function syncStarred() { starred = settings && Array.isArray(settings.starred) ? settings.starred.slice() : [] }
  onSettingsChanged: syncStarred()
  Component.onCompleted: syncStarred()

  readonly property var rows: Model.buildRows(cf.resourceState(), cf.analytics, {
    deployRows: cf.deployRows,
    overviewDeployRows: cf.overviewDeployRows,
    limits: cf.limits,
    filter: root.filter,
    route: root.route,
    starred: root.starred,
    tokenRows: Api.tokenShortcuts()
  })
  readonly property var currentRow: rows.length > 0 && cursorIndex >= 0 && cursorIndex < rows.length
    ? rows[cursorIndex] : null

  // The hero doubles as the breadcrumb: in a type view it names the type and
  // says how to get back, so the drill-down never leaves you unsure where you
  // are or how to leave.
  readonly property string heroTitle: {
    if (route !== "") return Model.typeLabel(route)
    return cf.accountName !== "" ? cf.accountName : "Cloudflare"
  }

  readonly property string heroMeta: {
    if (!cf.configLoaded) return "Reading wrangler credentials"
    if (!cf.loggedIn) return "Not logged in — run wrangler login"
    if (cf.lastError !== "") return cf.lastError
    if (cf.accountId === "") return "Resolving account"
    if (filter !== "") return (rows.length === 1 && rows[0].kind === "empty" ? 0 : rows.length) + " matching"
    if (route !== "") return cf.accountName
    var parts = []
    if (cf.zones.length) parts.push(cf.zones.length + " domains")
    if (cf.workers.length) parts.push(cf.workers.length + " workers")
    if (cf.pages.length) parts.push(cf.pages.length + " pages")
    if (cf.buckets.length) parts.push(cf.buckets.length + " buckets")
    if (parts.length === 0) return cf.refreshing ? "Loading" : "No resources"
    return parts.join("  \u00b7  ")
  }

  readonly property string heroDetail: {
    if (cf.busy) return "SYNC"
    if (cf.failedDeploys > 0) return cf.failedDeploys + " FAILED"
    if (cf.lastRefreshMs > 0) return Model.relativeTime(cf.lastRefreshMs, nowMs).toUpperCase()
    return ""
  }

  // Ticks only while the panel is open — relative timestamps are the only
  // thing that needs it, and nothing is on screen to update when it is closed.
  property double nowMs: Date.now()
  Timer {
    interval: 30000
    repeat: true
    running: root.opened
    onTriggered: root.nowMs = Date.now()
  }

  // ------------------------------------------------------------- navigation

  function selectableAt(index) {
    if (index < 0 || index >= rows.length) return false
    return rows[index].selectable !== false
  }

  function clampCursor() {
    if (rows.length === 0) { cursorIndex = 0; return }
    if (cursorIndex >= rows.length) cursorIndex = rows.length - 1
    if (cursorIndex < 0) cursorIndex = 0
    if (!selectableAt(cursorIndex)) {
      for (var i = cursorIndex; i < rows.length; i++) if (selectableAt(i)) { cursorIndex = i; return }
      for (var j = cursorIndex; j >= 0; j--) if (selectableAt(j)) { cursorIndex = j; return }
    }
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy !== 0 && rows.length > 0) {
      var next = cursorIndex
      do {
        next += (dy > 0 ? 1 : -1)
      } while (next >= 0 && next < rows.length && !selectableAt(next))
      if (next >= 0 && next < rows.length) cursorIndex = next
    }
    // Left and right are the drill-down axis, the way they are in a file
    // manager: right goes in, left comes back out. They used to jump between
    // sections, which only existed because everything was on one screen.
    if (dx > 0) enterCurrent()
    else if (dx < 0) goBack()
    clampCursor()
  }

  // Descend into whatever the cursor is on, if it is a group. Leaf rows are
  // unaffected, so holding `l` cannot walk you somewhere unexpected.
  function enterCurrent() {
    var row = currentRow
    if (!row || row.kind !== "group") return false
    if (route === "") overviewCursor = cursorIndex
    route = row.target
    cursorIndex = 0
    cursorActive = true
    return true
  }

  function goBack() {
    if (filter !== "" || filtering) { leaveSearch(); return true }
    if (route === "") return false
    route = ""
    cursorIndex = overviewCursor
    clampCursor()
    return true
  }

  function leaveSearch() {
    filtering = false
    filter = ""
    filterField.text = ""
    cursorIndex = route === "" ? overviewCursor : 0
    clampCursor()
    keyCatcher.forceActiveFocus()
  }

  function setCursor(index) {
    cursorActive = true
    cursorIndex = index
    clampCursor()
  }

  function activateCursor() {
    var row = currentRow
    if (!row) return
    // Enter on a group opens it rather than the dashboard: the whole point of
    // the overview is that the obvious action on "Workers · 27" is to see them.
    if (row.kind === "group") { enterCurrent(); return }
    if (row.kind === "empty" || row.kind === "tiles") return
    cf.openUrl(Api.dashUrlFor(row))
    close()
  }

  // ------------------------------------------------------------- row actions

  function copyIdentifier(row) {
    if (!row) return
    if (row.kind === "tiles" || row.kind === "empty" || row.kind === "group") return
    var value = row.kind === "token" ? row.url : (row.id || row.name)
    cf.copyToClipboard(value, row.name || "value")
  }

  // The live site, as distinct from the dashboard page that manages it. Both
  // are useful and they are not the same destination, so they get their own key.
  function openLive(row) {
    if (!row || !row.liveUrl) {
      cf.flashStatus("No live URL for this row")
      return
    }
    cf.openUrl(row.liveUrl)
    close()
  }

  function copyUrl(row) {
    if (!row || row.kind === "tiles" || row.kind === "empty" || row.kind === "group") return
    // A live URL is the one you would paste to someone; the dashboard link is
    // only useful when there is no site behind the row.
    if (row.liveUrl) cf.copyToClipboard(row.liveUrl, row.liveHost)
    else cf.copyToClipboard(Api.dashUrlFor(row), "dashboard link")
  }

  // Save one value into this widget's entry in shell.json. Used only for
  // things you ask for: a star, or a chosen account.
  function persist(key, value) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return false
    var entry = { id: root.moduleName }
    for (var k in settings) if (k !== "id") entry[k] = settings[k]
    // An empty value removes the key, so unstarring everything leaves no trace.
    if (value === "" || (Array.isArray(value) && value.length === 0)) delete entry[key]
    else entry[key] = value
    root.bar.shell.updateEntryInline(root.moduleName, entry)
    return true
  }

  function toggleStarCurrent() {
    var row = currentRow
    var key = Model.starKey(row)
    if (!key) { cf.flashStatus("Stars are for resources"); return }
    starred = Model.toggleStar(starred, key)
    persist("starred", starred)
    // Starred items move to the top of a type view. Keep the cursor on the
    // same resource, or the next key acts on whatever took its place.
    for (var i = 0; i < rows.length; i++) {
      if (Model.starKey(rows[i]) === key) { cursorIndex = i; break }
    }
    cf.flashStatus((starred.indexOf(key) >= 0 ? "Starred " : "Removed star from ") + row.name)
  }

  function switchAccount() {
    var id = cf.nextAccountId()
    if (id === "") { cf.flashStatus("This login has one account"); return }
    cf.selectAccount(id)
    persist("accountId", id)
    route = ""
    cursorIndex = 0
    overviewCursor = 0
    cf.flashStatus("Account: " + cf.accountName)
  }

  function workerNameFor(row) {
    if (!row) return ""
    if (row.kind === "worker" || row.kind === "pages") return row.name
    if (row.kind === "deploy") return row.name
    return ""
  }

  function tailCurrent() {
    var row = currentRow
    if (!row) return
    if (row.kind === "worker" || (row.kind === "deploy" && row.target === "worker")) {
      cf.tailWorker(row.name)
      close()
    } else {
      cf.flashStatus("Tail only applies to a Worker")
    }
  }

  // Deploy, rollback and purge all change something real, so each one routes
  // through the confirm dialog rather than firing on a single keystroke.
  function requestAction(kind) {
    var row = currentRow
    if (!row) return
    var name = workerNameFor(row)

    if (kind === "purge") {
      if (row.kind !== "zone") { cf.flashStatus("Purge applies to a zone"); return }
      pendingAction = { kind: "purge", zone: { id: row.id, name: row.name } }
      confirm.message = "Purge the entire cache for " + row.name + "?"
      confirm.confirmText = "Purge"
    } else {
      if (name === "") { cf.flashStatus(kind === "deploy" ? "Deploy applies to a Worker or Pages project" : "Rollback applies to a Worker"); return }
      if (cf.projectDirFor(name) === "") {
        cf.flashStatus("No local wrangler project for " + name)
        return
      }
      pendingAction = { kind: kind, name: name }
      confirm.message = (kind === "deploy" ? "Deploy " : "Roll back ") + name + " from "
        + cf.projectDirFor(name) + "?"
      confirm.confirmText = kind === "deploy" ? "Deploy" : "Roll back"
    }

    confirm.selectedIndex = 0
    confirm.opened = true
  }

  function runPendingAction() {
    var action = pendingAction
    pendingAction = null
    confirm.opened = false
    if (!action) return
    if (action.kind === "purge") cf.purgeZone(action.zone)
    else if (action.kind === "deploy") { cf.deployProject(action.name); close() }
    else if (action.kind === "rollback") { cf.rollbackProject(action.name); close() }
  }

  // ------------------------------------------------------------- lifecycle

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    overviewCursor = 0
    // Always reopen on the overview. A panel that reopens three levels deep
    // where you left it is a panel you have to navigate out of before you can
    // see anything.
    route = ""
    filter = ""
    filtering = false
    filterField.text = ""
    pendingAction = null
    confirm.opened = false
    nowMs = Date.now()
    cf.refresh()
    if (!cf.analytics.loaded) cf.refreshAnalytics()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  onRowsChanged: clampCursor()

  Service {
    id: cf
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { cf.refresh(); cf.refreshAnalytics(); return "ok" }
    function status(): string {
      return cf.loggedIn
        ? (cf.accountName + " — " + cf.workers.length + " workers, " + cf.failedDeploys + " failed deploys")
        : "not logged in"
    }
    // Everything the panel knows about its own health, for debugging a widget
    // that renders empty without saying why.
    function diagnose(): string {
      return JSON.stringify({
        configLoaded: cf.configLoaded,
        hasToken: cf.token !== "",
        credentialSource: cf.credentialSource,
        credentialPaths: cf.wranglerConfigPaths,
        expiresInSec: Math.round((cf.tokenExpiresMs - Date.now()) / 1000),
        accountId: cf.accountId,
        // The card's place on screen, in the logical units grim -g takes, so a
        // preview can capture the card and nothing else.
        card: root.opened ? {
          x: Math.round(panel.cardOrigin.x), y: Math.round(panel.cardOrigin.y),
          w: panel.contentWidth, h: panel.contentHeight,
          screen: panel.screen ? panel.screen.name : ""
        } : null,
        accountName: cf.accountName,
        accounts: cf.accounts.length,
        starred: root.starred,
        tiles: (root.rows.filter(function(r) { return r.kind === "tiles" })[0] || { tiles: [] }).tiles.length,
        refreshing: cf.refreshing,
        analyticsLoaded: cf.analytics.loaded,
        counts: {
          workers: cf.workers.length, pages: cf.pages.length, buckets: cf.buckets.length,
          databases: cf.databases.length, namespaces: cf.namespaces.length,
          queues: cf.queues.length, zones: cf.zones.length
        },
        projectDirs: Object.keys(cf.projectDirs).length,
        accountSubdomain: cf.accountSubdomain,
        customDomains: Object.keys(cf.workerDomains).length,
        dotDevResolved: Object.keys(cf.workerDotDev).length,
        dotDevEnabled: Object.keys(cf.workerDotDev).filter(function(k) { return cf.workerDotDev[k] }).length,
        liveRows: root.rows.filter(function(r) { return !!r.liveHost }).length,
        lastError: cf.lastError,
        rows: root.rows.length,
        route: root.route,
        filtering: root.filtering,
        filter: root.filter,
        cursorIndex: root.cursorIndex,
        cursorSection: root.currentRow ? root.currentRow.section : "",
        cursorName: root.currentRow ? String(root.currentRow.name || root.currentRow.title || "") : ""
      })
    }
  }

  // ------------------------------------------------------------- bar button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: cf.loggedIn
      ? "Cloudflare — " + (cf.accountName || "account")
      : "Cloudflare — not logged in"
    iconComponent: Component {
      Item {
        CloudflareIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.barIconColor
          badgeColor: root.urgent
          crossed: !cf.loggedIn
          warning: cf.loggedIn && root.warningState
          busy: cf.busy
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) { cf.refresh(); cf.refreshAnalytics() }
      else if (buttonCode === Qt.MiddleButton) cf.openUrl(Api.dashAccount("/workers"))
      else root.toggle()
    }
  }

  readonly property bool warningState: cf.failedDeploys > 0 || cf.analytics.workersOverErrorRate > 0

  // ------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    // Sized to content, capped. A fixed tall card left a six-row type view
    // three-quarters empty. `list.contentHeight` is the sum of the delegate
    // heights and does not depend on how tall the view is, so this does not
    // feed back into itself; past the cap the list scrolls instead.
    //
    // The cap is 760 rather than 620 because at 620 the overview clipped its
    // own RESOURCES section — the rows you navigate by — below the fold.
    // KeyboardPanel clamps this to the screen anyway.
    contentHeight: panel.fittedContentHeight(
      headerColumn.implicitHeight + Style.space(18) + list.contentHeight + legend.implicitHeight,
      Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The filter field and the confirm dialog each own the keyboard while
      // they are up; without this they would fight the panel's own bindings.
      blocked: root.filtering || confirm.opened

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      // Escape unwinds one level before it closes the panel, so it is never a
      // choice between losing your place and losing the panel.
      onCloseRequested: if (!root.goBack()) root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "/") { root.filtering = true; Qt.callLater(function() { filterField.forceActiveFocus() }) }
        else if (t === "s") root.toggleStarCurrent()
        else if (t === "a") root.switchAccount()
        else if (t === "r") { cf.refresh(); cf.refreshAnalytics() }
        else if (t === "c") root.copyIdentifier(root.currentRow)
        else if (t === "u") root.copyUrl(root.currentRow)
        else if (t === "o") root.openLive(root.currentRow)
        else if (t === "t") root.tailCurrent()
        else if (t === "D") root.requestAction("deploy")
        else if (t === "R") root.requestAction("rollback")
        else if (t === "P") root.requestAction("purge")
      }

      // Header pinned to the top, legend pinned to the bottom, list filling
      // what is left. A single Column would have made the list's height depend
      // on its own content, which is circular once the list can scroll.
      Column {
        id: headerColumn
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(10)

        PanelHero {
          id: hero
          width: parent.width
          title: root.heroTitle
          meta: root.heroMeta
          detail: root.heroDetail
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: cf.loggedIn ? 1.0 : 0.5
          iconComponent: Component {
            CloudflareIcon {
              iconSize: Style.font.display
              color: root.foreground
              badgeColor: root.urgent
              crossed: !cf.loggedIn
              warning: cf.loggedIn && root.warningState
              busy: cf.busy
            }
          }
        }

        // Transient action feedback ("Copied …", "Purge needs a token …").
        Text {
          visible: cf.actionStatus !== ""
          width: parent.width
          text: cf.actionStatus
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // Always on screen, as in the dashboard. `/` or a click puts the
        // cursor in it; Escape leaves it.
        TextField {
          id: filterField
          width: parent.width
          placeholderText: Model.GLYPH_SEARCH + "  Search every resource"
          foreground: root.foreground
          font.family: root.fontFamily
          onActiveFocusChanged: root.filtering = activeFocus
          onTextChanged: {
            root.filter = text
            root.cursorIndex = 0
            root.cursorActive = true
          }

          Text {
            visible: !filterField.activeFocus && filterField.text === ""
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.controlPaddingX
            anchors.verticalCenter: parent.verticalCenter
            text: "/"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              root.leaveSearch()
              event.accepted = true
            } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
              root.moveCursor(0, event.key === Qt.Key_Down ? 1 : -1)
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.activateCursor()
              event.accepted = true
            }
          }
        }
      }

      // Key legend, pinned to the bottom. Cheaper than a help panel and it
      // stops the single-key shortcuts from being undiscoverable.
      Text {
        id: legend
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        // One line for each view. The full list of keys is in the README.
        text: root.route === "" && root.filter === ""
          ? "j/k move   l open   / search   s star" + (cf.accounts.length > 1 ? "   a account" : "") + "   r refresh"
          : "\u23ce dashboard   o site   s star   c copy   t tail   D deploy   h back"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      // Everything below the hero is one virtualized list. With ~70 resources
      // a Repeater in a Column would build every delegate up front; this
      // builds the handful that are on screen, owns its own scroll position,
      // and keeps the cursor visible on j/k.
      ListView {
        id: list
        anchors.top: headerColumn.bottom
        anchors.topMargin: Style.space(10)
        anchors.bottom: legend.top
        anchors.bottomMargin: Style.space(8)
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(4)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        model: root.rows
        currentIndex: root.cursorIndex
        // Deferred a turn: the model is rebuilt on every poll and on every
        // filter keystroke, and swapping it resets the view out from under an
        // immediate call.
        onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(keepCurrentVisible)
        function keepCurrentVisible() {
          if (currentIndex >= 0 && currentIndex < count) positionViewAtIndex(currentIndex, ListView.Contain)
        }

        delegate: Item {
          id: rowItem
          required property var modelData
          required property int index

          width: ListView.view.width
          height: rowColumn.implicitHeight

          Column {
            id: rowColumn
            width: parent.width
            spacing: Style.space(4)

            // Breathing room above a section rule. It has to be its own item:
            // padding the separator's own height paints the whole thing, and a
            // 1px rule became a nine-pixel slab.
            Item {
              visible: rowItem.index > 0 && rowItem.modelData.sectionTitle !== ""
              width: 1
              height: Style.space(8)
            }

            PanelSeparator {
              visible: rowItem.index > 0 && rowItem.modelData.sectionTitle !== ""
              foreground: root.foreground
            }

            PanelSectionHeader {
              visible: rowItem.modelData.sectionTitle !== ""
              text: rowItem.modelData.sectionTitle
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Loader {
              id: rowLoader
              width: parent.width
              sourceComponent: rowItem.modelData.kind === "tiles"
                ? tilesComponent
                : (rowItem.modelData.kind === "empty" ? emptyComponent : entryComponent)
            }

            // Bindings rather than assignment in onLoaded: the ListView
            // recycles delegates, so the item outlives the modelData it was
            // first handed and would otherwise render a stale row.
            Binding {
              target: rowLoader.item
              property: "row"
              value: rowItem.modelData
              when: rowLoader.item !== null
            }

            Binding {
              target: rowLoader.item
              property: "rowIndex"
              value: rowItem.index
              when: rowLoader.item !== null
            }
          }
        }
      }

      ConfirmDialog {
        id: confirm
        anchors.fill: parent
        foreground: root.foreground
        fontFamily: root.fontFamily
        cancelText: "Cancel"
        onCanceled: {
          confirm.opened = false
          root.pendingAction = null
          keyCatcher.forceActiveFocus()
        }
        onConfirmed: root.runPendingAction()

        // ConfirmDialog has no key handling of its own; it exposes handleKey
        // for whichever surface owns focus. The catcher is blocked while the
        // dialog is up, so this is where its keys have to arrive.
        Keys.onPressed: function(event) {
          if (confirm.handleKey(event)) event.accepted = true
        }
        focus: confirm.opened
        onOpenedChanged: if (opened) forceActiveFocus()
      }
    }
  }

  // ------------------------------------------------------------- row types

  // A resource, a deployment, or a token shortcut. They differ only in glyph,
  // trailing text and accent, so one component covers all three rather than
  // three near-identical ones drifting apart.
  component EntryRow: CursorSurface {
    id: entry
    property var row: null
    property int rowIndex: -1

    readonly property bool isDeploy: row && row.kind === "deploy"
    readonly property bool isToken: row && row.kind === "token"
    readonly property bool isGroup: row && row.kind === "group"
    readonly property string glyph: row
      ? (isDeploy ? Model.glyphFor(row.target === "pages" ? "pages" : "worker")
        : (isGroup ? Model.glyphFor(row.target) : Model.glyphFor(row.kind)))
      : ""
    // A row that serves a site gets a visit button at its right edge. Printing
    // the hostname instead cost the row its figure, and read as inert text
    // rather than something you can go to.
    readonly property bool hasLive: !!(row && row.liveHost)
    readonly property real visitInset: hasLive ? Style.space(24) : 0
    readonly property bool isStarred: !!(row && row.starred)
    readonly property string trailing: {
      if (!row) return ""
      if (isDeploy) return Model.relativeTime(row.whenMs, root.nowMs)
      if (isGroup) return row.count + "  \uf105"  // count, then chevron-right
      if (isToken) return "\uf08e"                // external-link
      if (isStarred) return Model.GLYPH_STAR
      return ""
    }
    readonly property bool alarming: row ? (row.alarming === true || row.failed === true) : false

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: entryInner.implicitHeight + Style.spacing.lg

    Row {
      id: entryInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8) + entry.visitInset
      spacing: Style.space(8)

      Text {
        id: glyphText
        text: entry.glyph
        color: entry.alarming ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        width: Style.space(20)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: parent.width - glyphText.width - trailingText.width - Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: entry.row ? String(entry.row.name || entry.row.label || "") : ""
          color: entry.alarming ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: {
            if (!entry.row) return ""
            if (entry.isToken) return String(entry.row.hint || "")
            return String(entry.row.detail || "")
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        id: trailingText
        text: entry.trailing
        color: entry.isStarred && !entry.isDeploy && !entry.isGroup ? Color.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      id: entryHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor(entry.rowIndex)
      onClicked: { root.setCursor(entry.rowIndex); root.activateCursor() }

      // "7h" is the scannable form; the timestamp behind it is what you want
      // on the one occasion the age actually matters.
      PanelToolTip {
        visible: entryHover.containsMouse && text !== ""
        text: entry.isDeploy ? Model.absoluteTime(entry.row.whenMs) : ""
        fontFamily: root.fontFamily
      }
    }

    // Declared after the row-wide MouseArea so it wins the click: the row opens
    // the dashboard, this opens the site. Two destinations, two targets.
    PanelActionButton {
      visible: entry.hasLive
      anchors.right: parent.right
      anchors.rightMargin: Style.space(3)
      anchors.verticalCenter: parent.verticalCenter
      iconText: "\uf08e"
      tooltipText: entry.row ? "Open " + entry.row.liveHost : ""
      foreground: root.dim
      hoverColor: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      size: Style.space(20)
      onClicked: root.openLive(entry.row)
    }
  }

  // The analytics figures as small cards, three per line, in the style of the
  // dashboard's analytics page: name, value, change against the day before,
  // and the last 24 hours as a line.
  component TilesRow: Item {
    id: tilesRow
    property var row: null
    property int rowIndex: -1
    readonly property var tiles: row && row.tiles ? row.tiles : []
    readonly property real gap: Style.space(6)

    implicitHeight: tileGrid.implicitHeight

    Grid {
      id: tileGrid
      width: parent.width
      columns: 3
      spacing: tilesRow.gap

      Repeater {
        model: tilesRow.tiles
        Tile {
          required property var modelData
          width: (tileGrid.width - 2 * tilesRow.gap) / 3
          tile: modelData
        }
      }
    }
  }

  component Tile: CursorSurface {
    id: tileCard
    property var tile: null
    readonly property bool alarming: !!(tile && tile.alarming)

    bordered: true
    foreground: root.foreground
    implicitHeight: tileInner.implicitHeight + Style.space(14)

    Column {
      id: tileInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(7)
      spacing: Style.space(3)

      Text {
        width: parent.width
        text: tileCard.tile ? tileCard.tile.title : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        Text {
          id: tileValue
          text: tileCard.tile ? tileCard.tile.value : ""
          color: tileCard.alarming ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          anchors.baseline: tileValue.baseline
          width: parent.width - tileValue.width - parent.spacing
          text: tileCard.tile ? tileCard.tile.delta : ""
          color: tileCard.tile && tileCard.tile.worse ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        visible: text !== ""
        width: parent.width
        text: tileCard.tile ? String(tileCard.tile.note || "") : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Sparkline {
        visible: !!(tileCard.tile && tileCard.tile.points && tileCard.tile.points.length > 1)
        width: parent.width
        height: visible ? Style.space(18) : 0
        points: tileCard.tile ? tileCard.tile.points : []
        stroke: root.foreground
      }

      // With an allowance set, a bar shows how much of it is used.
      Item {
        visible: !!(tileCard.tile && tileCard.tile.meter >= 0)
        width: parent.width
        height: visible ? Style.space(4) : 0

        Rectangle {
          id: tileTrack
          anchors.fill: parent
          radius: height / 2
          color: root.track
        }

        Rectangle {
          height: tileTrack.height
          radius: tileTrack.radius
          width: tileTrack.width * Util.clamp(tileCard.tile ? tileCard.tile.meter : 0, 0, 1)
          color: tileCard.alarming ? root.urgent : root.foreground
        }
      }
    }

    MouseArea {
      id: tileHover
      anchors.fill: parent
      hoverEnabled: true

      PanelToolTip {
        visible: tileHover.containsMouse && text !== ""
        text: tileCard.tile ? tileCard.tile.tooltip : ""
        fontFamily: root.fontFamily
      }
    }
  }

  // The last 24 hours as a thin line with a light fill. Scaled to its own
  // maximum: it shows the shape of the day, not a value you can read off.
  component Sparkline: Canvas {
    id: spark
    property var points: []
    property color stroke: root.foreground

    onPointsChanged: requestPaint()
    onStrokeChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var pts = spark.points || []
      var n = pts.length
      if (n < 2 || width <= 0 || height <= 0) return
      var max = 0
      for (var i = 0; i < n; i++) max = Math.max(max, Number(pts[i]) || 0)
      var top = 1
      var bottom = height - 1
      function x(i) { return (i / (n - 1)) * width }
      function y(v) { return max > 0 ? bottom - ((Number(v) || 0) / max) * (bottom - top) : bottom }

      ctx.beginPath()
      ctx.moveTo(0, bottom)
      for (i = 0; i < n; i++) ctx.lineTo(x(i), y(pts[i]))
      ctx.lineTo(width, bottom)
      ctx.closePath()
      ctx.fillStyle = Qt.rgba(spark.stroke.r, spark.stroke.g, spark.stroke.b, 0.12)
      ctx.fill()

      ctx.beginPath()
      for (i = 0; i < n; i++) {
        if (i === 0) ctx.moveTo(x(i), y(pts[i]))
        else ctx.lineTo(x(i), y(pts[i]))
      }
      ctx.strokeStyle = Qt.rgba(spark.stroke.r, spark.stroke.g, spark.stroke.b, 0.75)
      ctx.lineWidth = 1.2
      ctx.stroke()
    }
  }

  component EmptyRow: Item {
    id: empty
    property var row: null
    property int rowIndex: -1
    implicitHeight: emptyText.implicitHeight + Style.spacing.lg

    Text {
      id: emptyText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      text: empty.row ? String(empty.row.name || "") : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
    }
  }

  Component { id: entryComponent; EntryRow {} }
  Component { id: tilesComponent; TilesRow {} }
  Component { id: emptyComponent; EmptyRow {} }
}
