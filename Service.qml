import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// One connection to tetherd for the whole shell.
//
// The bar builds a widget per monitor, so a socket owned by the widget would
// mean a subscription per screen. A service plugin is instantiated once and
// handed to every widget through bar.shell.serviceFor(), which is where the
// state below lives instead.
//
// Nothing here polls. tetherd's "subscribe" registers this process as a local
// subscriber and then pushes bt_message, bt_connection_changed and
// bt_message_read as they happen; the only requests we make are the initial
// snapshot and a re-list of conversations after something changed.
Item {
  id: root

  // Injected by the shell for service plugins.
  property var shell: null
  property var manifest: null

  // ---- settings -----------------------------------------------------------
  // The shell hands plugin settings to the bar widget, not to the service, so
  // the widget pushes them across.
  property string socketPathOverride: ""
  property int threadLimit: 12
  property bool markReadOnOpen: true

  function applySettings(settings) {
    function value(key, fallback) {
      var found = settings ? settings[key] : undefined
      return found === undefined || found === null ? fallback : found
    }
    socketPathOverride = String(value("socketPath", "")).trim()
    threadLimit = Model.clampInt(value("threadLimit", 12), 12, 1, 50)
    markReadOnOpen = Model.truthy(value("markReadOnOpen", true), true)
  }

  // ---- connection ---------------------------------------------------------
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  // The relay checks the endpoint properly. This only refuses a relative path
  // early, so a typo fails here instead of one process later.
  readonly property string socketPath: {
    if (socketPathOverride !== "")
      return socketPathOverride.charAt(0) === "/" ? socketPathOverride : ""
    return runtimeDir !== "" ? runtimeDir + "/tether/tetherd.sock" : ""
  }

  // Up means the relay verified the endpoint and connected, not merely that the
  // process started.
  readonly property bool daemonUp: proxyReady

  property bool proxyReady: false
  // Whatever the relay last refused, in its own words. Shown in the panel.
  property string proxyProblem: ""

  readonly property string proxyPath: {
    var url = Qt.resolvedUrl("tether-proxy").toString()
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }

  // ---- state --------------------------------------------------------------
  property var link: ({})            // last bt_connection_changed
  property var btStatus: ({})        // last bt_status
  property var snapshot: ({})        // last state_snapshot: the Wi-Fi side
  property var allThreads: []        // every conversation tetherd knows
  property int unreadTotal: 0
  property int unreadThreads: 0

  property string openThread: ""
  property var messages: []
  property bool messagesLoading: false

  property bool sending: false
  property string sendError: ""

  // What the iPhone would pull if it asked for the clipboard right now.
  property string clipboardText: ""
  property bool clipboardKnown: false

  // Frames refused for length. Surfaced so a daemon behaving badly is visible
  // rather than silently ignored.
  property int oversizedFrames: 0

  property bool sendingFile: false
  property string fileSendMessage: ""
  property bool fileSendOk: true

  // Handles already sent to the phone as read, so reopening a thread does not
  // re-send the same batch. A bounded FIFO: see Model.rememberHandles.
  property var markedRead: Model.emptyMarked()

  // Threads whose messages were fetched only so their unread handles could be
  // marked. See markAllRead().
  property var markAllPending: ({})
  property bool markingAll: false

  readonly property var visibleThreads: Model.visibleThreads(allThreads, threadLimit)
  // Two transports, two states. Bluetooth carries messages and notifications;
  // Wi-Fi carries the clipboard and files. Either can be up alone.
  // When the relay refused the endpoint, that is the useful thing to say. The
  // generic "start tetherd" line would send someone looking in the wrong place.
  readonly property var state: {
    var base = Model.bluetoothState(daemonUp, link)
    if (daemonUp || proxyProblem === "") return base
    return { level: base.level, title: base.title, detail: proxyProblem }
  }
  readonly property var wifi: Model.wifiState(daemonUp, snapshot)
  readonly property bool wifiReady: Model.wifiReady(wifi)
  readonly property bool clipboardAvailable: Model.clipboardAvailable(snapshot)
  readonly property string barTooltip: Model.barTooltip(state, unreadTotal)
  readonly property var openThreadRow: Model.findThread(allThreads, openThread)

  // Reading happens in tether-proxy, not here.
  //
  // Two checks cannot be done from QML at all. `SplitParser` assembles bytes
  // until it sees the delimiter, inside C++, with no length property, so a peer
  // that withholds a newline grows that buffer without bound and any QML-side
  // length test runs only once a frame has already been built. And
  // `Quickshell.Io.Socket` exposes `path` and `connected` and nothing else: it
  // cannot stat the endpoint or read peer credentials, so this side has no way
  // to tell tetherd's socket from anything else sitting at that path.
  //
  // So the relay owns both. It stats the socket and every directory above it,
  // checks SO_PEERCRED, and emits nothing but complete frames under a hard
  // ceiling. Everything below reads bounded lines from a pipe.
  Process {
    id: relay
    running: false
    command: ["python3", root.proxyPath, root.socketPath]
    stdinEnabled: true

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) { root.handleLine(line) }
    }

    // The relay reports faults as JSON on stdout. Anything on stderr is a
    // Python traceback, which is a bug worth surfacing rather than hiding.
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function (line) { root.proxyProblem = Model.clampText(line, 300) }
    }

    onExited: function (code, status) {
      root.proxyReady = false
      root.onDaemonLost()
    }
  }

  function startRelay() {
    if (root.socketPath === "" || relay.running) return
    relay.running = true
  }

  // A changed path means a different endpoint, which has to be re-verified from
  // scratch rather than reused.
  onSocketPathChanged: {
    relay.running = false
    startRelay()
  }

  // The daemon may be stopped, restarted, or not up yet when the shell starts.
  // triggeredOnStart makes the first attempt immediate; the timer only runs
  // while the socket is down, so a healthy connection costs nothing.
  Timer {
    id: reconnect
    interval: 4000
    repeat: true
    triggeredOnStart: true
    running: root.socketPath !== "" && !root.proxyReady
    onTriggered: root.startRelay()
  }

  // client_connected and friends say what changed but not what the whole list
  // now looks like, so the snapshot is re-read rather than patched. Coalesced,
  // because a reconnecting phone produces several in a row.
  Timer {
    id: snapshotRefresh
    interval: 300
    repeat: false
    onTriggered: root.request({ "command": "state_snapshot" })
  }

  // A thread that never answers must not leave the sweep spinning.
  Timer {
    id: markAllTimeout
    interval: 15000
    repeat: false
    onTriggered: {
      root.markingAll = false
      root.markAllPending = ({})
    }
  }

  // A file goes out over the network to a phone that may be slow or gone.
  Timer {
    id: fileSendTimeout
    interval: 120000
    repeat: false
    onTriggered: {
      if (!root.sendingFile) return
      root.sendingFile = false
      root.fileSendOk = false
      root.fileSendMessage = "The transfer did not finish. The file may not have arrived."
    }
  }

  // A conversation list is cheap and several events can land together, so
  // re-listing is coalesced rather than run once per message.
  Timer {
    id: threadRefresh
    interval: 350
    repeat: false
    onTriggered: root.request({ "command": "bt_list_threads" })
  }

  // A send is an OBEX push that can hang on a phone that has wandered off.
  // Without this the composer would stay disabled until the panel was rebuilt.
  Timer {
    id: sendTimeout
    interval: 25000
    repeat: false
    onTriggered: {
      if (!root.sending) return
      root.sending = false
      root.sendError = "The phone did not answer. The message may not have been sent."
    }
  }

  function request(payload) {
    if (!proxyReady || !relay.running) return false
    relay.write(JSON.stringify(payload) + "\n")
    return true
  }

  function onDaemonConnected() {
    // subscribe replies with a state_snapshot and the Bluetooth link, so the
    // Wi-Fi side needs no separate request here.
    request({ "command": "subscribe" })
    request({ "command": "bt_status" })
    request({ "command": "bt_list_threads" })
    request({ "command": "clipboard_get" })
    if (openThread !== "") request({ "command": "bt_list_messages", "thread": openThread })
  }

  function onFileSendResult(event) {
    fileSendTimeout.stop()
    sendingFile = false
    var result = Model.fileSendResult(event)
    fileSendOk = result.ok
    fileSendMessage = result.message
  }

  function onDaemonLost() {
    // Conversations are kept so the panel does not blank out during a daemon
    // restart; the hero says the connection is gone, which is the honest
    // reading of a list that is no longer being updated.
    link = ({})
    snapshot = ({})
    sending = false
    sendingFile = false
    messagesLoading = false
  }

  function handleLine(line) {
    // The relay already guarantees frames under its ceiling, so this is a
    // second line of defence rather than the only one. Kept because it costs a
    // length compare and covers the relay itself misbehaving.
    if (Model.frameTooLarge(line)) {
      oversizedFrames++
      return
    }
    var text = String(line || "").trim()
    if (text === "") return

    var event
    try {
      event = JSON.parse(text)
    } catch (error) {
      return
    }
    if (!event || typeof event !== "object") return

    switch (String(event.command || "")) {
    // ---- the relay's own frames ----
    case "proxy_ready":
      proxyProblem = ""
      proxyReady = true
      onDaemonConnected()
      break
    case "proxy_closed":
      proxyReady = false
      break
    case "proxy_overflow":
      // The peer sent more than a frame's worth with no delimiter. The relay
      // has already dropped the link; say so rather than looking merely idle.
      proxyReady = false
      oversizedFrames++
      proxyProblem = "The daemon sent an oversized frame and the connection was dropped."
      break
    case "proxy_error":
      proxyReady = false
      proxyProblem = Model.proxyProblem(event)
      break

    case "bt_status":
      btStatus = event
      break
    case "bt_connection_changed":
      link = event
      break
    case "bt_threads":
      applyThreads(event.threads)
      break
    case "bt_messages":
      applyMessages(event.thread, event.messages)
      break
    case "bt_message":
      onMessage(event)
      break
    case "bt_message_read":
      onReadReceipt(event)
      break
    case "bt_send_result":
      onSendResult(event)
      break
    case "state_snapshot":
      snapshot = event
      break
    // The Wi-Fi side is pushed too: these three are what keep the transport row
    // honest without anything on a timer asking.
    case "client_connected":
    case "untrusted_client_connected":
    case "client_disconnected":
      snapshotRefresh.restart()
      break
    case "clipboard_content":
      clipboardText = String(event.content || "")
      clipboardKnown = true
      break
    case "file_send_complete":
      onFileSendResult(event)
      break
    default:
      break
    }
  }

  function applyThreads(threads) {
    allThreads = Model.threadRows(threads)
    unreadTotal = Model.unreadTotal(allThreads)
    unreadThreads = Model.unreadThreads(allThreads)
  }

  function applyMessages(thread, list) {
    var key = String(thread || "")

    // A sweep asked for this thread purely to learn its unread handles.
    if (markAllPending[key]) {
      var handles = Model.unreadHandles(Model.messageRows(list), Model.markedSeen(markedRead))
      if (handles.length > 0) rememberMarked(handles)
      var remaining = ({})
      var left = 0
      for (var t in markAllPending) {
        if (t === key) continue
        remaining[t] = true
        left++
      }
      markAllPending = remaining
      if (left === 0) {
        markingAll = false
        markAllTimeout.stop()
      }
    }

    if (key !== openThread) return
    messages = Model.messageRows(list)
    messagesLoading = false
    if (markReadOnOpen) markOpenThreadRead()
  }

  // Sends the batch and records it, so a later fetch of the same thread does
  // not ask the phone to mark the same handles twice.
  function rememberMarked(handles) {
    if (!request({ "command": "bt_mark_read", "handles": handles, "read": true })) return
    markedRead = Model.rememberHandles(markedRead, handles)
  }

  function onMessage(event) {
    if (String(event.thread || "") === openThread) {
      messages = Model.mergeMessage(messages, event)
      if (markReadOnOpen) markOpenThreadRead()
    }
    threadRefresh.restart()
  }

  function onReadReceipt(event) {
    var handles = Model.toArray(event.handles)
    if (handles.length > 0) messages = Model.applyReadState(messages, handles, event.read === true)
    threadRefresh.restart()
  }

  function onSendResult(event) {
    sendTimeout.stop()
    sending = false
    sendError = event.success === true ? "" : (Model.collapse(event.message) || "The message could not be sent.")
    if (event.success === true) threadRefresh.restart()
  }

  // ---- actions ------------------------------------------------------------

  function openConversation(key) {
    var wanted = Model.clampText(key, 200)
    if (wanted === openThread) return
    openThread = wanted
    messages = []
    sendError = ""
    messagesLoading = wanted !== ""
    if (wanted !== "") request({ "command": "bt_list_messages", "thread": wanted })
  }

  function closeConversation() {
    openThread = ""
    messages = []
    messagesLoading = false
    sendError = ""
  }

  // Opening a conversation marks it read here and on the phone, which is what
  // makes the bar's unread dot agree with what has actually been seen. Tether's
  // own app does the same; markReadOnOpen turns it off for anyone who would
  // rather the phone not be told.
  function markOpenThreadRead() {
    var handles = Model.unreadHandles(messages, Model.markedSeen(markedRead))
    if (handles.length === 0) return
    rememberMarked(handles)
  }

  // Clear every unread flag at once.
  //
  // This exists because the flags cannot clear themselves. iOS stops serving a
  // message over MAP after a day or so, and tetherd only refreshes read state
  // for messages a listing still returns — so anything read on the phone after
  // it left that window stays unread here for good. Measured: nine unread, all
  // of them 30-31 August, none still listed by the phone.
  //
  // The daemon marks them read locally even when the phone will not take the
  // sync ("marked read on this computer only"), which is exactly right for
  // messages already read on the phone.
  function markAllRead() {
    var keys = Model.unreadThreadKeys(allThreads)
    if (keys.length === 0) return
    var pending = ({})
    for (var i = 0; i < keys.length; i++) {
      pending[keys[i]] = true
      request({ "command": "bt_list_messages", "thread": keys[i] })
    }
    markAllPending = pending
    markingAll = true
    markAllTimeout.restart()
  }

  function sendReply(body) {
    var text = Model.replyBody(body)
    if (text === "" || openThread === "" || sending) return false
    if (!request({ "command": "bt_send_message", "thread": openThread, "body": text })) {
      sendError = "Tether is not running."
      return false
    }
    sending = true
    sendError = ""
    sendTimeout.restart()
    return true
  }

  function requestClipboard() {
    request({ "command": "clipboard_get" })
  }

  // The daemon opens its own connection to the phone per send and reports back
  // with file_send_complete, so this returns as soon as the ask is in.
  function sendFile(path) {
    var target = Model.sendablePath(path)
    if (target === "" || sendingFile) {
      if (target === "" && !sendingFile) {
        fileSendOk = false
        fileSendMessage = "That is not an absolute file path."
      }
      return false
    }
    if (!request({ "command": "send_file", "path": target })) {
      fileSendOk = false
      fileSendMessage = "Tether is not running."
      return false
    }
    sendingFile = true
    fileSendOk = true
    fileSendMessage = "Sending " + Model.fileName(target) + "…"
    fileSendTimeout.restart()
    return true
  }

  function clearFileSendMessage() {
    if (!sendingFile) fileSendMessage = ""
  }

  function refresh() {
    if (!daemonUp) {
      startRelay()
      return
    }
    request({ "command": "bt_status" })
    request({ "command": "bt_list_threads" })
    request({ "command": "state_snapshot" })
    request({ "command": "clipboard_get" })
    if (openThread !== "") request({ "command": "bt_list_messages", "thread": openThread })
  }

  // Ask tetherd to bring the phone link up. The same command `tether
  // --bt-enable on` sends; the result arrives as a bt_connection_changed push.
  function reconnectPhone() {
    request({ "command": "bt_set_enabled", "enabled": true })
  }
}
