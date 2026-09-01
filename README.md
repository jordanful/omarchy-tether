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
omarchy plugin validate .
```

### Limits on what the daemon can do

This runs inside `omarchy-shell`, the single process drawing the desktop, so a
malformed or enormous payload freezes Hyprland's shell rather than one app. A
buggy daemon is a likelier cause than a hostile one and the effect is the same,
so everything the socket sends is bounded. Frames over 256 KB are dropped
without being parsed. A listing keeps at most 500 conversations and 500
messages, newest first. Message bodies cap at 4000 characters because
`TextMetrics` lays them out on the UI thread, and names, addresses and keys cap
at 200. Mark all read fans out to at most 50 threads.

Replies cap at 4000 characters and paths at 4096, and `sendFile` takes absolute
paths only. `socketPath` must be absolute; QML cannot stat a socket, so its
owner and mode cannot be checked from here, and the default stays inside
`$XDG_RUNTIME_DIR`, which systemd creates 0700.

The plugin launches two processes, both with fixed arguments and no shell:
`tether-gtk` and `zenity --file-selection`. It installs nothing.

Tether's socket protocol is undocumented, so the commands used here were read
out of `net.cpp` and then checked against a running daemon, because the two do
not always agree. `clipboard_available` is in the source but missing from
0.2.19's snapshot, and the enable command is `bt_set_enabled`, not the
`bt_enable` its CLI flag suggests.

## Licence

MIT. Tether is a separate project with its own licence.
