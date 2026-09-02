# Tether for the Omarchy bar

iPhone messages in the Omarchy bar. An unread badge, your recent conversations,
replies from the keyboard, plus the shared clipboard and file sending.

It draws what [Tether](https://github.com/zackb/tether) already knows. Tether
talks to the phone; this plugin does no Bluetooth of its own.

![the conversation list](docs/conversations.png)
![one conversation](docs/conversation.png)

## Requirements

Omarchy with `omarchy-shell`, and Tether 0.2.19 or newer, paired with an iPhone
and running.

On Arch it is the `tether-bin` AUR package. Tether's own README says
`yay -S tether`, which does not exist.

```bash
yay -S tether-bin
```

Check the link before installing this:

```bash
tether --bt-connection   # profiles should read connected
tether --bt-threads      # should list your conversations
```

Start `tetherd` yourself. Tether ships no service unit, so nothing starts it at
login.

`python3` is required. It runs `tether-proxy`, the small relay that reads the
socket. See below.

`zenity` is optional and only used for the file picker. Without it,
`omarchy-shell tether sendFile <path>` still works.

## Install

```bash
omarchy plugin add https://github.com/jordanful/omarchy-tether.git --enable
```

Plugins arrive disabled so you can read the code first, and `--enable` skips
that. Move it with `omarchy bar move io.github.jordanful.tether --section
right`. Remove it with `omarchy plugin remove io.github.jordanful.tether`.

## Using it

Click the bar icon for your conversations, then click one to open it.
Right-click opens Tether's own window. Middle-click refreshes.

The panel takes keyboard focus when it opens.

| Key | Does |
|---|---|
| `j` `k` or `↓` `↑` | move the cursor. The first press only reveals it |
| `Enter` or `Space` | open the conversation under the cursor |
| `l` or `→` | open the conversation under the cursor |
| `h` or `←` | back to the list |
| `r` | jump to the reply box |
| `Enter` in the reply box | send |
| `Esc` | back to the list, or close the panel |
| `Tab` | next bar panel |

Links in a message are clickable and open in your default browser, the one
`xdg-settings` names. Only `http` and `https` are ever launchable.

Two radios carry different things and fail independently, so the panel reports
each one. Bluetooth carries messages and notifications. Wi-Fi carries the
clipboard and files. When either is down, the row shows the daemon's own
explanation.

## Clipboard and files

Both ride Wi-Fi, so they only appear while the Tether app is open on the phone
and on the same network.

The clipboard section shows what the phone would receive if it asked. There is
no send button because nothing local can force a push. Tether mirrors every copy
by itself, and the phone pulls on demand with its own Get Clipboard.

Send file opens zenity and hands the path to the daemon. The result appears
above the buttons, in the daemon's words.

## Known limits

Messages you send from the phone never appear. iOS lists a `sent` folder over
MAP and then serves nothing from it. Asked directly, `ListMessages("sent")`
comes back empty while `ListMessages("inbox")` returns messages. Nothing here or
in Tether can fix that. Replies sent from this panel do show, right aligned with
a tick.

Unread counts go stale. iOS stops serving a message after about a day, and
Tether can only refresh read state for messages a listing still returns, so
anything you read on the phone after that stays unread here for good. The check
button in the header clears all of them at once. Opening a conversation clears
that one.

## Settings

Set these with `omarchy bar set io.github.jordanful.tether <key> <value>`, or
edit the widget's entry in `~/.config/omarchy/shell.json`.

| Key | Default | Does |
|---|---|---|
| `hideWhenDisconnected` | `false` | Take the icon out of the bar while the phone is away |
| `markReadOnOpen` | `true` | Mark a conversation read, on the phone too, when you open it |
| `showPreviews` | `true` | Show what was said in the list, not only who said it |
| `threadLimit` | `12` | How many conversations to list, 1 to 50. Unread ones are always listed |
| `socketPath` | `""` | Path to `tetherd.sock`. Empty means `$XDG_RUNTIME_DIR/tether/tetherd.sock` |

Turn `markReadOnOpen` off if you would rather this never touched the phone's
unread state. The badge will then only clear when you read the message there.

## IPC

```bash
omarchy-shell tether toggle
omarchy-shell tether show
omarchy-shell tether hide
omarchy-shell tether back
omarchy-shell tether openThread 'tel:+15551234567'
omarchy-shell tether sendFile ~/report.pdf
omarchy-shell tether markAllRead
```

`openThread` goes straight to one conversation, which makes a good keybinding
for whoever you talk to most. Thread keys are the ones `tether --bt-threads`
prints.

## Troubleshooting

**Tether is not running.** The plugin cannot reach the daemon socket. Check
`tetherd` is up and `$XDG_RUNTIME_DIR/tether/tetherd.sock` exists. If yours
lives elsewhere, set `socketPath`.

**iPhone disconnected, or messages not connected.** The daemon is fine and the
phone is not. `tether --bt-connection` says the same thing with more detail. The
Reconnect button asks Tether to bring the link up. If the phone never offers
Messages access, try `tether --bt-solicit`.

**Conversations are listed but empty.** MAP is still syncing. Give it a moment
or hit refresh.

**Send file and the clipboard section are missing.** They ride Wi-Fi, and the
Wi-Fi row will say why. Usually the Tether app is closed, or the two are on
different networks.

**The picker does not open.** Install `zenity`, or use
`omarchy-shell tether sendFile <path>`.

**Nothing appears in the bar.** Check `omarchy plugin list --json | grep tether`
shows it enabled, then run `omarchy-shell shell rescanPlugins`. QML errors turn
up in `journalctl --user -t omarchy-shell`.

## Development

`Model.js` holds the pure functions and imports nothing from QML, so it runs in
a plain harness. `Service.qml` owns the socket and the state. `Panel.qml` is the
bar button and the popup, and draws only what the service hands it.

```bash
node tests/model.test.js
python3 tests/proxy.test.py
omarchy plugin validate .
```

The relay's tests run against real sockets in `$XDG_RUNTIME_DIR`, not mocks,
because everything it does is a syscall.

### The relay, and why reading does not happen in QML

`tether-proxy` is a standard-library python3 script that sits between the shell
and tetherd. The panel spawns it, reads bounded lines from its stdout, and
writes commands to its stdin. It exists because two checks cannot be done from
QML at all.

`SplitParser` assembles bytes until it sees the delimiter, inside C++, with no
length property. A peer that withholds a newline grows that buffer without
bound, and a length test in QML runs only once a frame has already been built,
which is too late. `Quickshell.Io.Socket` exposes `path` and `connected` and
nothing else, so it cannot stat the endpoint or read peer credentials, and has
no way to tell tetherd's socket from anything else at that path.

The relay does both. It stats the socket and every directory above it, on the
resolved path, refusing anything not owned by this user or writable by others.
It checks `SO_PEERCRED`, so the process actually serving the socket has to be
this user. It emits only complete frames under a 256 KB ceiling, and on overflow
it drops the connection and exits rather than sitting on a poisoned buffer. Any
refusal is reported in the Bluetooth row, naming the reason.

The shell restarts the relay on the same retry timer that used to reopen the
socket, so a relay that dies comes back in about four seconds.

### Limits on what the daemon can do

This runs inside `omarchy-shell`, the single process drawing the desktop, so an
oversized payload freezes Hyprland's shell rather than one app. A listing keeps
at most 500 conversations and 500 messages, newest first. Message bodies cap at
4000 characters because `TextMetrics` lays them out on the UI thread, and names,
addresses, keys and handles cap at 200. Mark all read fans out to at most 50
threads. The set of handles already marked read is a 2000-entry FIFO, so a long
session cannot grow it without end.

Replies cap at 4000 characters and paths at 4096, and `sendFile` takes absolute
paths only. `socketPath` must be absolute, and the relay verifies the rest.

Message bodies render as `StyledText` so links can be anchors, but no markup
from a message survives to the renderer: every run is escaped first and the only
tags in the result are anchors the plugin writes itself. That matters because
`StyledText` honours `<img src>`, and a remote one would make the shell issue an
unauthenticated GET. An `<img>` in a message arrives as `&lt;img&gt;` and draws
as text. Anything other than `http` or `https` is never turned into a link, and
the URL is re-checked when clicked before it reaches the browser.

The plugin launches four processes, all with fixed arguments and no shell:
`tether-proxy`, `tether-gtk`, `zenity --file-selection`, and
`omarchy launch browser <url>` for a clicked link. It installs nothing.

Tether's socket protocol is undocumented, so the commands used here were read
out of `net.cpp` and then checked against a running daemon, because the two do
not always agree. `clipboard_available` is in the source but missing from
0.2.19's snapshot, and the enable command is `bt_set_enabled`, not the
`bt_enable` its CLI flag suggests.

## Licence

MIT. Tether is a separate project with its own licence.
