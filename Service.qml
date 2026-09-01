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
  readonly property string socketPath: socketPathOverride !== ""
    ? socketPathOverride
    : (runtimeDir !== "" ? runtimeDir + "/tether/tetherd.sock" : "")

  readonly property bool daemonUp: socketHolder.item ? socketHolder.item.connected : false

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

  property bool sendingFile: false
  property string fileSendMessage: ""
  property bool fileSendOk: true

  // Handles already sent to the phone as read, so reopening a thread does not
  // re-send the same batch.
  property var markedRead: ({})

  readonly property var visibleThreads: Model.visibleThreads(allThreads, threadLimit)
  // Two transports, two states. Bluetooth carries messages and notifications;
  // Wi-Fi carries the clipboard and files. Either can be up alone.
  readonly property var state: Model.bluetoothState(daemonUp, link)
  readonly property var wifi: Model.wifiState(daemonUp, snapshot)
  readonly property bool wifiReady: Model.wifiReady(wifi)
  readonly property bool clipboardAvailable: Model.clipboardAvailable(snapshot)
  readonly property string barTooltip: Model.barTooltip(state, unreadTotal)
  readonly property var openThreadRow: Model.findThread(allThreads, openThread)

  // A Quickshell Socket is single-use: once it has disconnected, writing
  // `connected = true` on the same object never reconnects it. Measured with a
  // daemon stopped and restarted underneath one — the retry fired on every
  // interval, `connected` kept reading false, and the link stayed dead until
  // the whole shell was restarted. So a retry throws the object away and builds
  // a new one, which does reconnect. That is the difference between "tetherd
  // restarted and the bar caught up" and "the bar is dark until you notice".
  Component {
    id: socketComponent

    Socket {
      id: sock
      path: root.socketPath
      connected: true

      parser: SplitParser {
        splitMarker: "\n"
        onRead: function (line) { root.handleLine(line) }
      }

      // The socket is handed over rather than looked up: this fires while the
      // Loader is still building, so socketHolder.item is not assigned yet and
      // the subscribe would go nowhere.
      onConnectionStateChanged: connected ? root.onDaemonConnected(sock) : root.onDaemonLost()
    }
  }

  Loader {
    id: socketHolder
    active: false
    sourceComponent: socketComponent
  }

  function restartSocket() {
    socketHolder.active = false
    if (root.socketPath !== "") socketHolder.active = true
  }

  // Writing Socket.path leaves a connection already open on the old path alone,
  // so a changed setting has to rebuild the socket like any other retry.
  onSocketPathChanged: restartSocket()

  // The daemon may be stopped, restarted, or not up yet when the shell starts.
  // triggeredOnStart makes the first attempt immediate; the timer only runs
  // while the socket is down, so a healthy connection costs nothing.
  Timer {
    id: reconnect
    interval: 4000
    repeat: true
    triggeredOnStart: true
    running: root.socketPath !== "" && !root.daemonUp
    onTriggered: root.restartSocket()
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

  function requestOn(socket, payload) {
    if (!socket || !socket.connected) return false
    socket.write(JSON.stringify(payload) + "\n")
    socket.flush()
    return true
  }

  function request(payload) {
    return requestOn(socketHolder.item, payload)
  }

  function onDaemonConnected(socket) {
    // subscribe replies with a state_snapshot and the Bluetooth link, so the
    // Wi-Fi side needs no separate request here.
    requestOn(socket, { "command": "subscribe" })
    requestOn(socket, { "command": "bt_status" })
    requestOn(socket, { "command": "bt_list_threads" })
    requestOn(socket, { "command": "clipboard_get" })
    if (openThread !== "") requestOn(socket, { "command": "bt_list_messages", "thread": openThread })
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
    if (String(thread || "") !== openThread) return
    messages = Model.messageRows(list)
    messagesLoading = false
    if (markReadOnOpen) markOpenThreadRead()
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
    var wanted = String(key || "")
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
    var handles = Model.unreadHandles(messages, markedRead)
    if (handles.length === 0) return
    if (!request({ "command": "bt_mark_read", "handles": handles, "read": true })) return
    var next = ({})
    for (var key in markedRead) next[key] = true
    for (var i = 0; i < handles.length; i++) next[handles[i]] = true
    markedRead = next
  }

  function sendReply(body) {
    var text = String(body || "").trim()
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
    var target = String(path || "").trim()
    if (target === "" || sendingFile) return false
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
      restartSocket()
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
