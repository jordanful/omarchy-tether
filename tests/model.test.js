// Run with: node tests/model.test.js
// Model.js has no exports, so it is evaluated here rather than imported.

const fs = require("fs")
const path = require("path")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
const Model = new Function(
  source + "; return { collapse, relativeTime, clockTime, dayLabel, initials, tintIndex, "
  + "threadRow, threadRows, findThread, visibleThreads, unreadTotal, unreadThreads, "
  + "messageRow, messageRows, mergeMessage, applyReadState, unreadHandles, "
  + "barTooltip, truthy, clampInt, toArray, isLocalHandle, GLYPH, "
  + "bluetoothState, wifiState, wifiReady, clipboardPreview, clipboardSummary, "
  + "fileSendResult, pickedPath, fileName, shortState, connectionSummary }"
)()

let failures = 0

function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected)
  if (!ok) {
    failures++
    console.log("FAIL " + name + "\n  expected " + JSON.stringify(expected) + "\n  got      " + JSON.stringify(actual))
  }
}

// A thread object exactly as tetherd's bt_threads sends it, copied off the box
// with the identifying parts swapped out.
const liveThread = {
  address: "+15550001111",
  count: 15,
  group: false,
  name: "Dana Reyes",
  preview: "  see you   then ",
  repliable: true,
  thread: "tel:+15550001111",
  timestamp: 1788285315,
  unread: 1
}

const NOW = 1788285315 + 90

// ---- time ----------------------------------------------------------------

check("relativeTime under a minute", Model.relativeTime(NOW - 30, NOW), "now")
check("relativeTime minutes", Model.relativeTime(NOW - 5 * 60, NOW), "5m")
check("relativeTime hours", Model.relativeTime(NOW - 3 * 3600, NOW), "3h")
check("relativeTime days", Model.relativeTime(NOW - 3 * 86400, NOW), "3d")
check("relativeTime falls back to a date past a week", Model.relativeTime(1735689600, NOW).length > 2, true)
check("relativeTime rejects a missing stamp", Model.relativeTime(0, NOW), "")
// A phone whose clock is a few seconds ahead must not read as negative.
check("relativeTime clamps the future", Model.relativeTime(NOW + 45, NOW), "now")

check("clockTime pads", Model.clockTime(new Date(2026, 0, 2, 9, 5).getTime() / 1000), "09:05")

const today = Math.floor(new Date(2026, 8, 1, 12, 0).getTime() / 1000)
const yesterday = Math.floor(new Date(2026, 7, 31, 23, 30).getTime() / 1000)
check("dayLabel today", Model.dayLabel(today, today), "Today")
check("dayLabel yesterday", Model.dayLabel(yesterday, today), "Yesterday")
// Calendar arithmetic, not a 86400 subtraction: 23.5 hours back is still
// yesterday, and a DST-shortened day would break a seconds comparison.
check("dayLabel across a short gap is still yesterday",
  Model.dayLabel(Math.floor(new Date(2026, 7, 31, 22, 0).getTime() / 1000), today), "Yesterday")

// ---- identity ------------------------------------------------------------

check("initials takes two words", Model.initials("Dana Reyes"), "DR")
check("initials takes one word", Model.initials("Mom"), "M")
check("initials ignores a bare number", Model.initials("+15550001111"), "")
check("initials handles accents", Model.initials("Émile Zola"), "ÉZ")
check("tintIndex is stable", Model.tintIndex("tel:+15550001111", 6), Model.tintIndex("tel:+15550001111", 6))
check("tintIndex stays in range", Model.tintIndex("tel:+15550001111", 6) < 6, true)

// ---- threads -------------------------------------------------------------

const row = Model.threadRow(liveThread)
check("threadRow collapses the preview", row.preview, "see you then")
check("threadRow titles from the name", row.title, "Dana Reyes")
check("threadRow keeps the address", row.address, "+15550001111")
check("threadRow reads repliable", row.repliable, true)
check("threadRow falls back to the address for a nameless thread",
  Model.threadRow({ thread: "tel:+1", address: "+1" }).title, "+1")
check("threadRow rejects a thread with no key", Model.threadRow({ name: "x" }), null)
// The daemon defaults repliable to true when it omits the field.
check("threadRow defaults repliable", Model.threadRow({ thread: "t" }).repliable, true)

const rows = Model.threadRows([
  { thread: "a", timestamp: 10, unread: 0 },
  { thread: "b", timestamp: 30, unread: 2 },
  { thread: "c", timestamp: 20, unread: 0 }
])
check("threadRows sorts newest first", rows.map(r => r.key), ["b", "c", "a"])
check("unreadTotal sums", Model.unreadTotal(rows), 2)
check("unreadThreads counts", Model.unreadThreads(rows), 1)
check("findThread finds", Model.findThread(rows, "c").key, "c")
check("findThread misses cleanly", Model.findThread(rows, "zz"), null)

// The reason visibleThreads exists: an unread conversation past the cap would
// otherwise be counted in the hero and absent from the list.
const many = Model.threadRows([
  { thread: "n1", timestamp: 100 },
  { thread: "n2", timestamp: 90 },
  { thread: "old-unread", timestamp: 10, unread: 2 }
])
check("visibleThreads keeps unread past the cap",
  Model.visibleThreads(many, 2).map(r => r.key), ["n1", "n2", "old-unread"])
check("visibleThreads drops read threads past the cap",
  Model.visibleThreads(many, 1).map(r => r.key), ["n1", "old-unread"])

// ---- messages ------------------------------------------------------------

const incoming = { handle: "h1", thread: "t", body: "hi", timestamp: 1000, outgoing: false, read: false }
const mine = { handle: "local-1", thread: "t", body: "sent", timestamp: 1100, outgoing: true, read: true }

check("messageRow marks a local handle pending", Model.messageRow(mine).pending, true)
check("messageRow leaves a phone handle alone", Model.messageRow(incoming).pending, false)
check("isLocalHandle", Model.isLocalHandle("local-9"), true)

let list = Model.messageRows([mine, incoming])
check("messageRows sorts oldest first", list.map(m => m.handle), ["h1", "local-1"])
check("messageRows stamps the first message of a day", list[0].dayBreak !== "", true)
check("messageRows leaves same-day neighbours unstamped", list[1].dayBreak, "")
check("mergeMessage does not restamp the list it was given",
  (function () { var before = list[0].dayBreak; Model.mergeMessage(list, { handle: "zz", thread: "t", body: "x", timestamp: 1 }); return list[0].dayBreak === before })(), true)

// The phone lists its own copy of a sent message under a different handle, so
// the pending placeholder is what the arriving copy has to replace.
const echoed = { handle: "phone-77", thread: "t", body: "sent", timestamp: 1150, outgoing: true, read: true }
let merged = Model.mergeMessage(list, echoed)
check("mergeMessage replaces the local echo", merged.map(m => m.handle), ["h1", "phone-77"])
check("mergeMessage clears pending", merged[1].pending, false)

// Same body, but far outside the echo window: a real second message.
const later = { handle: "phone-78", thread: "t", body: "sent", timestamp: 1100 + 4000, outgoing: true, read: true }
check("mergeMessage keeps a repeat sent much later",
  Model.mergeMessage(list, later).map(m => m.handle), ["h1", "local-1", "phone-78"])

check("mergeMessage replaces by handle",
  Model.mergeMessage(list, { handle: "h1", thread: "t", body: "edited", timestamp: 1000 })[0].body, "edited")
check("mergeMessage appends something new",
  Model.mergeMessage(list, { handle: "h9", thread: "t", body: "new", timestamp: 1200 }).length, 3)

check("applyReadState flips the named handles",
  Model.applyReadState(list, ["h1"], true)[0].read, true)
// It must not reach back into the array it was handed: the panel keeps its own
// reference to those rows, and a caller-visible flip here silently changed what
// unreadHandles saw next.
check("applyReadState leaves its input alone", list[0].read, false)

check("unreadHandles skips outgoing and read", Model.unreadHandles(list), ["h1"])
check("unreadHandles skips what was already sent", Model.unreadHandles(list, { h1: true }), [])

// ---- connection ----------------------------------------------------------

check("bluetoothState with no daemon", Model.bluetoothState(false, {}).level, "down")
check("bluetoothState with no phone", Model.bluetoothState(true, { device_present: false }).level, "down")
check("bluetoothState with the phone away",
  Model.bluetoothState(true, { device_present: true, device_paired: true, classic_connected: false }).level, "warn")
check("bluetoothState with messages down",
  Model.bluetoothState(true, { device_present: true, device_paired: true, classic_connected: true, map_open: false }).level, "warn")
check("bluetoothState connected",
  Model.bluetoothState(true, { device_present: true, device_paired: true, classic_connected: true, map_open: true }).level, "ok")
// The daemon writes these sentences for people; they are shown, not reworded.
check("bluetoothState carries the daemon's own wording",
  Model.bluetoothState(true, { device_present: true, device_paired: true, classic_connected: true, map_open: true,
    profile_reason: "Messages and contacts are connected." }).detail,
  "Messages and contacts are connected.")

// ---- Wi-Fi -----------------------------------------------------------------
// Paired and connected are different things: a phone stays a known host
// forever, and is a connected client only while its app is open on the network.
check("wifiState with no daemon", Model.wifiState(false, {}).level, "down")
check("wifiState with nothing paired",
  Model.wifiState(true, { connected_clients: [], paired_devices: [] }).level, "down")
check("wifiState paired but away",
  Model.wifiState(true, { connected_clients: [], paired_devices: [{ fingerprint: "a" }] }).level, "warn")
check("wifiState connected",
  Model.wifiState(true, { connected_clients: [{ device_name: "Jordan's iPhone", paired: true }] }).level, "ok")
check("wifiState names the device",
  Model.wifiState(true, { connected_clients: [{ device_name: "Jordan's iPhone", paired: true }] }).title,
  "Jordan's iPhone connected")
// The known-hosts dump stores "Unknown Device" when it never learned a name.
check("wifiState falls back on a nameless device",
  Model.wifiState(true, { connected_clients: [{ device_name: "Unknown Device", paired: true }] }).title,
  "iPhone connected")
check("wifiState prefers a paired client over an unpaired one",
  Model.wifiState(true, { connected_clients: [{ device_name: "Stranger" }, { device_name: "Mine", paired: true }] }).device,
  "Mine")
check("wifiState mentions mDNS when it is the problem",
  Model.wifiState(true, { connected_clients: [], paired_devices: [{ fingerprint: "a" }], mdns_available: false }).detail
    .indexOf("announcing") >= 0, true)
check("shortState ok", Model.shortState({ level: "ok" }), "Connected")
check("shortState warn", Model.shortState({ level: "warn" }), "Away")
check("shortState down", Model.shortState({ level: "down" }), "Off")

// The summary names what works rather than what does not, because that is the
// question being asked of a bar panel.
var UP = { level: "ok" }, AWAY = { level: "warn" }
check("connectionSummary both", Model.connectionSummary(UP, UP), "Messages, clipboard and files")
check("connectionSummary bluetooth only", Model.connectionSummary(UP, AWAY), "Messages only")
check("connectionSummary wifi only", Model.connectionSummary(AWAY, UP), "Clipboard and files only")
check("connectionSummary neither", Model.connectionSummary(AWAY, AWAY), "Nothing connected")
// When the daemon itself is down both transports say the same thing, and
// saying it once is better than "Nothing connected".
check("connectionSummary collapses a dead daemon",
  Model.connectionSummary(Model.bluetoothState(false, {}), Model.wifiState(false, {})).indexOf("not running") >= 0, true)

check("wifiReady", Model.wifiReady({ level: "ok" }), true)
check("wifiReady is false while away", Model.wifiReady({ level: "warn" }), false)

// ---- clipboard and files ---------------------------------------------------

check("clipboardPreview collapses", Model.clipboardPreview("  two   words  ").text, "two words")
check("clipboardPreview counts the raw text, not the collapsed one",
  Model.clipboardPreview("ab\ncd").chars, 5)
check("clipboardPreview counts lines", Model.clipboardPreview("a\nb\nc").lines, 3)
check("clipboardPreview on nothing", Model.clipboardPreview("").empty, true)
check("clipboardSummary empty", Model.clipboardSummary(Model.clipboardPreview("")), "Nothing on the clipboard")
check("clipboardSummary singular", Model.clipboardSummary(Model.clipboardPreview("x")), "1 character")
check("clipboardSummary multiline",
  Model.clipboardSummary(Model.clipboardPreview("a\nb")), "3 characters, 2 lines")

check("fileSendResult carries the daemon's sentence",
  Model.fileSendResult({ success: false, message: "Send failed: No connected iPhone client is available." }).message,
  "Send failed: No connected iPhone client is available.")
check("fileSendResult ok", Model.fileSendResult({ success: true, message: "Sent report.pdf" }).ok, true)
check("fileSendResult without a message", Model.fileSendResult({ success: false }).message,
  "The file could not be sent.")

check("pickedPath takes the first line", Model.pickedPath("/home/a/one.pdf\n/home/a/two.pdf\n"), "/home/a/one.pdf")
check("pickedPath on a cancelled picker", Model.pickedPath(""), "")
check("fileName", Model.fileName("/home/a/report.pdf"), "report.pdf")
check("fileName of a bare name", Model.fileName("report.pdf"), "report.pdf")

check("barTooltip counts", Model.barTooltip({ level: "ok" }, 3), "3 unread messages")
check("barTooltip is singular at one", Model.barTooltip({ level: "ok" }, 1), "1 unread message")
check("barTooltip when nothing waits", Model.barTooltip({ level: "ok" }, 0), "No unread messages")
check("barTooltip reports a problem instead of a count",
  Model.barTooltip({ level: "down", title: "Tether is not running" }, 4), "Tether is not running")

// ---- settings ------------------------------------------------------------

check("truthy passes a bool", Model.truthy(false, true), false)
check("truthy reads a string", Model.truthy("false", true), false)
check("truthy falls back on nothing", Model.truthy(undefined, true), true)
check("truthy falls back on nonsense", Model.truthy("banana", false), false)
check("clampInt clamps high", Model.clampInt(900, 12, 1, 50), 50)
check("clampInt clamps low", Model.clampInt(0, 12, 1, 50), 1)
check("clampInt falls back on nonsense", Model.clampInt("x", 12, 1, 50), 12)
check("clampInt reads a numeric string", Model.clampInt("20", 12, 1, 50), 20)

// shell.json and daemon payloads both arrive as array-like proxies where
// Array.isArray() is false.
check("toArray copies an array-like", Model.toArray({ length: 2, 0: "a", 1: "b" }), ["a", "b"])
check("toArray survives a non-list", Model.toArray(null), [])

// ---- glyphs --------------------------------------------------------------
// Above the BMP, so a "\uXXXX" escape cannot reach them and a surrogate slip
// would ship a broken icon.
check("bubble glyph is one codepoint", Array.from(Model.GLYPH.bubble).length, 1)
check("bubble glyph codepoint", Model.GLYPH.bubble.codePointAt(0), 0xF0367)
check("send glyph codepoint", Model.GLYPH.send.codePointAt(0), 0xF048A)

if (failures === 0) console.log("all model tests pass")
else {
  console.log(failures + " failing")
  process.exit(1)
}
