// Nothing here imports QML on purpose, so every function also runs in a plain
// JS harness — see tests/model.test.js. Service.qml and Panel.qml both read
// this file, which is what keeps the shaping of daemon payloads in one place.

var MINUTE = 60
var HOUR = 3600
var DAY = 86400

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

var PREVIEW_MAX = 120

// tetherd mints a handle with this prefix for a message sent from here, before
// the phone has listed its own copy. See core/include/tether/bluetooth/messages.hpp.
var LOCAL_HANDLE_PREFIX = "local-"

// How far apart our placeholder and the phone's copy of the same sent message
// may be and still be the same message. Mirrors LOCAL_ECHO_WINDOW_SECONDS.
var LOCAL_ECHO_WINDOW = 300

// Every codepoint here was rendered in JetBrainsMono Nerd Font and looked at
// before it was used. A fontconfig charset hit is not proof a glyph draws:
// nf-md-earbuds (U+F1085) is reported as covered and paints "LOG". These are
// written as fromCodePoint because they sit above the BMP, where a "\uXXXX"
// escape cannot reach them.
var GLYPH = {
  // Tether's own mark is two interlocking rings, so the bar wears a link
  // rather than a speech bubble — this plugin is a face for Tether, and the
  // icon should say so. fa-link over md-link-variant because its strokes
  // survive 16px; the variant thins out into a vertical chain.
  link: String.fromCodePoint(0xF0C1),      // nf-fa-link
  phone: String.fromCodePoint(0xF011C),    // nf-md-cellphone
  account: String.fromCodePoint(0xF0004),  // nf-md-account
  back: String.fromCodePoint(0xF0141),     // nf-md-chevron-left
  forward: String.fromCodePoint(0xF0142),  // nf-md-chevron-right
  send: String.fromCodePoint(0xF048A),     // nf-md-send
  check: String.fromCodePoint(0xF012C),    // nf-md-check
  refresh: String.fromCodePoint(0xF0450),  // nf-md-refresh
  external: String.fromCodePoint(0xF03CC), // nf-md-open-in-new
  alert: String.fromCodePoint(0xF0028),    // nf-md-alert-circle
  bluetooth: String.fromCodePoint(0xF00AF), // nf-md-bluetooth
  wifi: String.fromCodePoint(0xF05A9),      // nf-md-wifi
  upload: String.fromCodePoint(0xF0552)     // nf-md-upload
}

// Payloads and settings both cross the C++/QML boundary as array-like proxies,
// where Array.isArray() is false and only .length tells the truth.
function toArray(values) {
  if (!values || typeof values.length !== "number") return []
  var out = []
  for (var i = 0; i < values.length; i++) out.push(values[i])
  return out
}

function collapse(text, max) {
  var value = String(text === undefined || text === null ? "" : text).replace(/\s+/g, " ").trim()
  var cap = max === undefined ? PREVIEW_MAX : max
  return value.length > cap ? value.substring(0, cap - 1) + "…" : value
}

function nowSeconds() {
  return Math.floor(Date.now() / 1000)
}

function pad2(value) {
  return value < 10 ? "0" + value : String(value)
}

function sameDay(a, b) {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
}

// Conversation-list stamps: how long ago, in the shortest form still
// unambiguous. Tether counts in seconds since the epoch.
function relativeTime(timestamp, now) {
  var ts = Number(timestamp)
  if (!isFinite(ts) || ts <= 0) return ""
  var ref = Number(now)
  if (!isFinite(ref) || ref <= 0) ref = nowSeconds()
  var diff = ref - ts
  if (diff < 0) diff = 0
  if (diff < MINUTE) return "now"
  if (diff < HOUR) return Math.floor(diff / MINUTE) + "m"
  if (diff < DAY) return Math.floor(diff / HOUR) + "h"
  if (diff < 7 * DAY) return Math.floor(diff / DAY) + "d"
  var d = new Date(ts * 1000)
  return d.getDate() + " " + MONTHS[d.getMonth()]
}

// Wall-clock under a bubble. 24h to match the bar's own default clock.
function clockTime(timestamp) {
  var ts = Number(timestamp)
  if (!isFinite(ts) || ts <= 0) return ""
  var d = new Date(ts * 1000)
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

// Calendar arithmetic rather than a seconds subtraction, because a DST
// boundary makes "yesterday" 23 or 25 hours wide.
function dayLabel(timestamp, now) {
  var ts = Number(timestamp)
  if (!isFinite(ts) || ts <= 0) return ""
  var ref = Number(now)
  if (!isFinite(ref) || ref <= 0) ref = nowSeconds()
  var d = new Date(ts * 1000)
  var today = new Date(ref * 1000)
  if (sameDay(d, today)) return "Today"
  var yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1)
  if (sameDay(d, yesterday)) return "Yesterday"
  if (d.getFullYear() === today.getFullYear())
    return WEEKDAYS[d.getDay()] + " " + d.getDate() + " " + MONTHS[d.getMonth()]
  return d.getDate() + " " + MONTHS[d.getMonth()] + " " + d.getFullYear()
}

// Up to two letters for the avatar. A thread keyed by a bare phone number has
// no letters to take and gets "", which is the row's cue to draw a glyph.
function initials(name) {
  var words = String(name || "").split(/\s+/)
  var letters = ""
  for (var i = 0; i < words.length && letters.length < 2; i++) {
    var first = words[i].charAt(0)
    if (/[A-Za-zÀ-ɏ]/.test(first)) letters += first.toUpperCase()
  }
  return letters
}

// Deterministic, so a contact keeps the same avatar tint between openings.
function tintIndex(key, buckets) {
  var text = String(key || "")
  var hash = 0
  for (var i = 0; i < text.length; i++) hash = (hash * 31 + text.charCodeAt(i)) % 100000007
  var count = (buckets === undefined || buckets <= 0) ? 6 : buckets
  return Math.abs(hash) % count
}

function isLocalHandle(handle) {
  return String(handle || "").indexOf(LOCAL_HANDLE_PREFIX) === 0
}

function threadRow(thread) {
  if (!thread) return null
  var key = String(thread.thread || "")
  if (key === "") return null
  var name = String(thread.name || "").trim()
  var address = String(thread.address || "").trim()
  return {
    key: key,
    title: name || address || key,
    address: address,
    named: name !== "",
    preview: collapse(thread.preview),
    timestamp: Number(thread.timestamp) || 0,
    unread: Math.max(0, Number(thread.unread) || 0),
    count: Math.max(0, Number(thread.count) || 0),
    group: thread.group === true,
    repliable: thread.repliable !== false
  }
}

function threadRows(threads) {
  var rows = []
  var list = toArray(threads)
  for (var i = 0; i < list.length; i++) {
    var row = threadRow(list[i])
    if (row) rows.push(row)
  }
  rows.sort(function (a, b) { return b.timestamp - a.timestamp })
  return rows
}

function findThread(rows, key) {
  var list = toArray(rows)
  var wanted = String(key || "")
  for (var i = 0; i < list.length; i++) if (list[i].key === wanted) return list[i]
  return null
}

// The most recent `limit` conversations, plus any unread one that recency
// alone would have cut off. Without the second half the hero can honestly
// report six unread while the list shows four of them and no way to reach the
// rest — the count and the list have to be able to agree.
function visibleThreads(rows, limit) {
  var list = toArray(rows)
  var cap = (limit === undefined || limit <= 0) ? list.length : limit
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (i < cap || (list[i].unread || 0) > 0) out.push(list[i])
  }
  return out
}

// The threads a "mark all read" sweep has to visit. Their messages are not in
// memory — only the open conversation's are — so each one has to be fetched
// before its handles can be marked.
function unreadThreadKeys(rows) {
  var out = []
  var list = toArray(rows)
  for (var i = 0; i < list.length; i++) if ((list[i].unread || 0) > 0) out.push(list[i].key)
  return out
}

function unreadTotal(rows) {
  var list = toArray(rows)
  var total = 0
  for (var i = 0; i < list.length; i++) total += list[i].unread || 0
  return total
}

function unreadThreads(rows) {
  var list = toArray(rows)
  var count = 0
  for (var i = 0; i < list.length; i++) if ((list[i].unread || 0) > 0) count++
  return count
}

function messageRow(message) {
  if (!message) return null
  var handle = String(message.handle || "")
  if (handle === "") return null
  return {
    handle: handle,
    thread: String(message.thread || ""),
    body: String(message.body || ""),
    timestamp: Number(message.timestamp) || 0,
    outgoing: message.outgoing === true,
    read: message.read === true,
    name: String(message.name || "").trim(),
    address: String(message.address || "").trim(),
    // Sent from here and not yet echoed back by the phone.
    pending: message.outgoing === true && isLocalHandle(handle),
    dayBreak: ""
  }
}

function copyRow(row) {
  var out = {}
  for (var key in row) out[key] = row[key]
  return out
}

// Stamps the first message of each calendar day, so a delegate can draw one
// separator per day without reaching for its neighbours.
//
// Copies rather than stamps in place: mergeMessage carries rows over from the
// list it was handed, and a function that quietly rewrites its caller's objects
// is how one view ends up changing another's.
function withDayBreaks(rows, now) {
  var out = []
  var previous = null
  for (var i = 0; i < rows.length; i++) {
    var row = copyRow(rows[i])
    var d = new Date(row.timestamp * 1000)
    row.dayBreak = (previous === null || !sameDay(previous, d)) ? dayLabel(row.timestamp, now) : ""
    previous = d
    out.push(row)
  }
  return out
}

function messageRows(messages, now) {
  var rows = []
  var list = toArray(messages)
  for (var i = 0; i < list.length; i++) {
    var row = messageRow(list[i])
    if (row) rows.push(row)
  }
  rows.sort(function (a, b) { return a.timestamp - b.timestamp })
  return withDayBreaks(rows, now)
}

// A bt_message event either replaces the row with its handle or lands as a new
// one. The phone lists its own copy of a sent message under a different handle
// than our local- placeholder, so a pending row carrying the same body inside
// the echo window is what the arriving copy replaces.
function mergeMessage(rows, message, now) {
  var row = messageRow(message)
  if (!row) return toArray(rows)
  var list = toArray(rows)
  var out = []
  var replaced = false
  for (var i = 0; i < list.length; i++) {
    var existing = list[i]
    if (existing.handle === row.handle) {
      out.push(row)
      replaced = true
      continue
    }
    if (!replaced && existing.pending && !row.pending && row.outgoing
        && existing.body === row.body
        && Math.abs(existing.timestamp - row.timestamp) <= LOCAL_ECHO_WINDOW) {
      out.push(row)
      replaced = true
      continue
    }
    out.push(existing)
  }
  if (!replaced) out.push(row)
  out.sort(function (a, b) { return a.timestamp - b.timestamp })
  return withDayBreaks(out, now)
}

function applyReadState(rows, handles, read) {
  var wanted = {}
  var list = toArray(handles)
  for (var i = 0; i < list.length; i++) wanted[String(list[i])] = true
  var source = toArray(rows)
  var out = []
  for (var j = 0; j < source.length; j++) {
    if (!wanted[source[j].handle]) {
      out.push(source[j])
      continue
    }
    var row = copyRow(source[j])
    row.read = read === true
    out.push(row)
  }
  return out
}

// The handles a conversation still owes the phone a read receipt for. Outgoing
// messages and anything already sent are skipped so reopening a thread does not
// re-send the same batch.
function unreadHandles(rows, alreadyMarked) {
  var out = []
  var list = toArray(rows)
  for (var i = 0; i < list.length; i++) {
    var row = list[i]
    if (row.read || row.outgoing || !row.handle) continue
    if (alreadyMarked && alreadyMarked[row.handle]) continue
    out.push(row.handle)
  }
  return out
}

// Tether runs two independent transports and the panel has to be honest about
// both: Bluetooth carries messages and notifications, Wi-Fi carries the
// clipboard and files. Either can be up while the other is down, so they get a
// state function each. level is "ok", "warn" or "down".

// Bluetooth, in the daemon's own wording wherever it supplies some.
function bluetoothState(daemonUp, link) {
  if (!daemonUp)
    return { level: "down", title: "Tether is not running", detail: "Start tetherd to see your messages." }
  var state = link || {}
  if (!state.device_present)
    return { level: "down", title: "No iPhone paired", detail: "Pair one with tether --bt-pair <address>." }
  if (!state.device_paired)
    return { level: "warn", title: "iPhone not paired", detail: collapse(state.link_reason) }
  if (!state.classic_connected)
    return { level: "warn", title: "iPhone disconnected", detail: collapse(state.link_reason) || "Waiting for the phone." }
  if (!state.map_open)
    return { level: "warn", title: "Messages not connected", detail: collapse(state.profile_reason) || collapse(state.map_error) }
  // Messages are up. Notification mirroring rides a separate LE link that the
  // iPhone reopens on its own schedule, so it is routinely down for a minute
  // while everything else works — measured across a daemon restart, where MAP
  // came back at once and ANCS took another 45 seconds. Reporting "messages,
  // notifications" through that window is wrong about half of what it claims,
  // so the note replaces it until ANCS is actually live.
  var connected = { level: "ok", title: "Connected", detail: collapse(state.profile_reason) }
  if (state.ancs_ready === false)
    connected.note = collapse(state.ancs_reason) || "Messages only — notification mirroring is not active yet."
  return connected
}

// Wi-Fi, read off the daemon's state_snapshot plus the client_connected and
// client_disconnected events that keep it current.
//
// "Paired" and "connected" are different things here: a phone stays a known
// host forever, and is only a connected client while the Tether app is
// actually open and on the same network.
function wifiState(daemonUp, snapshot) {
  if (!daemonUp)
    return { level: "down", title: "Tether is not running", detail: "Start tetherd to share the clipboard and files." }

  var snap = snapshot || {}
  var clients = toArray(snap.connected_clients)
  var known = toArray(snap.paired_devices)

  if (clients.length > 0) {
    var client = null
    for (var i = 0; i < clients.length && !client; i++) if (clients[i].paired) client = clients[i]
    if (!client) client = clients[0]
    var name = collapse(client.device_name)
    if (name === "" || name === "Unknown Device") name = "iPhone"
    return {
      level: "ok",
      title: name + " connected",
      detail: "Clipboard and files are shared.",
      device: name,
      address: collapse(client.address)
    }
  }

  if (known.length > 0)
    return {
      level: "warn",
      title: "iPhone not on Wi-Fi",
      detail: snap.mdns_available === false
        ? "Paired, but this computer is not announcing itself on the network."
        : "Paired. Open Tether on the iPhone, on the same network."
    }

  return {
    level: "down",
    title: "No Wi-Fi device paired",
    detail: "Open Tether on the iPhone — it finds this computer by itself, then approve on both ends."
  }
}

// Whether the panel should offer the things Wi-Fi carries.
// The word on the right of a transport row. The full sentence is one line
// below it, so this only has to separate the three cases at a glance.
function shortState(state) {
  if (!state) return ""
  if (state.level === "ok") return "Connected"
  if (state.level === "warn") return "Away"
  return "Off"
}

// The hero's one line, which has to cover both transports at once. Naming what
// currently works beats naming what is broken: "Messages only" tells you what
// you can do, where "Wi-Fi disconnected" makes you work it out.
function connectionSummary(bluetooth, wifi) {
  var bt = bluetooth || {}
  var wf = wifi || {}
  if (bt.level === "down" && wf.level === "down" && bt.title === wf.title) return bt.title
  var messages = bt.level === "ok"
  var files = wf.level === "ok"
  if (messages && files) return "Messages, clipboard and files"
  if (messages) return "Messages only"
  if (files) return "Clipboard and files only"
  return "Nothing connected"
}

// Whether the compositor lets tetherd read the selection at all. 0.2.19 does
// not report this, so a missing field means "assume it works" — the same
// default Tether's own GTK app takes.
function clipboardAvailable(snapshot) {
  var snap = snapshot || {}
  return snap.clipboard_available !== false
}

function wifiReady(wifi) {
  return !!wifi && wifi.level === "ok"
}

// What the iPhone would receive if it pulled the clipboard right now. Kept
// short: the row is a reassurance that the right thing is shared, not a viewer.
// iOS advertises a `sent` folder over MAP and then serves nothing from it —
// measured against the phone directly on 2026-09-01, where ListMessages("sent")
// answered with an empty set while "inbox" returned messages, and the journal
// held four outgoing messages in 149, all of them sent from here. So a thread
// shows what the other person said plus anything sent from this machine, and
// nothing you typed on the phone. Saying so next to the reply box stops a
// half-conversation reading as a bug in this plugin.
function sentInvisible(rows) {
  var list = toArray(rows)
  if (list.length === 0) return false
  for (var i = 0; i < list.length; i++) if (list[i].outgoing) return false
  return true
}

function clipboardPreview(text, max) {
  var value = String(text === undefined || text === null ? "" : text)
  var lines = value.split("\n").length
  var one = collapse(value, max === undefined ? 80 : max)
  return { text: one, empty: one === "", lines: lines, chars: value.length }
}

function clipboardSummary(preview) {
  if (!preview || preview.empty) return "Nothing on the clipboard"
  if (preview.lines > 1) return preview.chars + " characters, " + preview.lines + " lines"
  return preview.chars + (preview.chars === 1 ? " character" : " characters")
}

// file_send_complete carries a sentence written for a person; it is shown as
// written rather than reworded into something vaguer.
function fileSendResult(event) {
  if (!event) return { ok: false, message: "" }
  return {
    ok: event.success === true,
    message: collapse(event.message) || (event.success === true ? "Sent." : "The file could not be sent.")
  }
}

// The path zenity prints, or "" when the picker was cancelled. Only the first
// line is taken: multi-selection would hand back several, and this sends one.
function pickedPath(stdout) {
  var first = String(stdout === undefined || stdout === null ? "" : stdout).split("\n")[0]
  return first.replace(/^\s+|\s+$/g, "")
}

function fileName(path) {
  var parts = String(path || "").split("/")
  return parts[parts.length - 1] || ""
}

function barTooltip(state, unread) {
  if (!state) return "Tether"
  if (state.level !== "ok") return state.title
  if (unread <= 0) return "No unread messages"
  return unread === 1 ? "1 unread message" : unread + " unread messages"
}

// Coerce a shell.json value that may arrive as a bool, a number or a string.
function truthy(value, fallback) {
  if (value === undefined || value === null) return fallback === true
  if (value === true || value === false) return value
  var text = String(value).toLowerCase()
  if (text === "true" || text === "1" || text === "on" || text === "yes") return true
  if (text === "false" || text === "0" || text === "off" || text === "no") return false
  return fallback === true
}

function clampInt(value, fallback, min, max) {
  var n = Number(value)
  if (!isFinite(n)) return fallback
  n = Math.round(n)
  if (n < min) return min
  if (n > max) return max
  return n
}
