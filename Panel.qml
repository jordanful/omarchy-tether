import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Bar button plus popup. Everything shown here comes from the shared service,
// which holds the one connection to tetherd and keeps running whether or not
// this panel is open — that is what lets the unread dot be trusted.
Panel {
  id: root

  readonly property string pluginId: "io.github.jordanful.tether"

  moduleName: pluginId
  ipcTarget: "tether"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits, and add openThread to the lifecycle methods the base registers.
  manageIpc: false

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(pluginId) : null

  // The shell hands plugin settings to the bar widget rather than to the
  // service, so the widget is what pushes them across.
  function pushSettings() {
    if (service && typeof service.applySettings === "function") service.applySettings(settings)
  }
  onSettingsChanged: pushSettings()
  onServiceChanged: pushSettings()
  Component.onCompleted: pushSettings()

  // `bar.foreground` is the source for painted colour; reading Panel's own
  // barForeground before the bar is attached yields undefined, and assigning
  // undefined to a colour leaves everything unpainted.
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color muted: Qt.darker(fg, 1.5)

  readonly property var state: service ? service.state : Model.statusFor(false, ({}))
  readonly property int unread: service ? service.unreadTotal : 0
  readonly property var threads: service ? service.visibleThreads : []
  readonly property var messages: service ? service.messages : []
  readonly property string openThread: service ? service.openThread : ""
  readonly property bool inConversation: openThread !== ""
  readonly property var openRow: service ? service.openThreadRow : null

  readonly property bool showPreviews: Model.truthy(setting("showPreviews", true), true)
  readonly property bool hideWhenDisconnected: Model.truthy(setting("hideWhenDisconnected", false), false)

  // Replying needs an open MAP session and a thread the phone will accept a
  // reply on — a group thread with no reply address is not one.
  readonly property bool canReply: !!service
    && inConversation
    && !!openRow
    && openRow.repliable
    && !!service.link
    && service.link.map_open === true

  // A theme is free to set accent to its foreground — this one does — so an
  // unread marker painted in accent disappears into the glyph it sits on.
  // bar.active is the colour omarchy already reserves for a bar widget that
  // wants attention, which is exactly what an unread message is.
  readonly property color attention: bar ? bar.urgent : Color.urgent

  readonly property color hoverFill: bar ? Style.hoverFillFor(fg, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(fg, Color.accent) : "transparent"

  // Avatar tints, taken from the theme rather than fixed hues so a contact
  // circle never fights the bar it sits under.
  readonly property var tints: [
    Color.accent,
    Qt.lighter(Color.accent, 1.35),
    Qt.darker(Color.accent, 1.3),
    fg,
    Qt.darker(fg, 1.35),
    Qt.lighter(Color.accent, 1.7)
  ]

  // ---- cursor -------------------------------------------------------------
  // One cursor, shared by keyboard and mouse, over whichever list is on screen.
  // Visuals come from CursorSurface, never from containsMouse, so only one row
  // is ever highlighted.
  property bool cursorActive: false
  property int threadIndex: 0
  property int messageIndex: -1

  function clamp(value, low, high) {
    if (high < low) return low
    return value < low ? low : (value > high ? high : value)
  }

  function moveCursor(delta) {
    if (inConversation) {
      var messageCount = messages.length
      if (messageCount === 0) return
      messageIndex = clamp((messageIndex < 0 ? messageCount - 1 : messageIndex) + delta, 0, messageCount - 1)
      return
    }
    var threadCount = threads.length
    if (threadCount === 0) return
    threadIndex = clamp(threadIndex + delta, 0, threadCount - 1)
  }

  function openAt(index) {
    if (index < 0 || index >= threads.length) return
    openConversation(threads[index].key)
  }

  function openConversation(key) {
    if (!service) return
    service.openConversation(key)
    messageIndex = -1
    cursorActive = false
  }

  function goBack() {
    if (!service) return
    service.closeConversation()
    messageIndex = -1
  }

  // Enter and Space. Inside a conversation there is one thing to activate and
  // it is not destructive, so the composer takes focus whether or not a cursor
  // is showing. Opening a conversation is guarded on a visible cursor: without
  // that, a stray Return lands on whatever happens to be at index 0 and marks
  // a stranger's thread read.
  function activateCursor() {
    if (inConversation) {
      if (canReply) composer.forceActiveFocus()
      return
    }
    if (cursorActive) openAt(threadIndex)
  }

  function submitReply() {
    if (!canReply || !service) return
    if (!service.sendReply(composer.text)) return
    composer.text = ""
  }

  function launchApp() {
    Quickshell.execDetached(["tether-gtk"])
    close()
  }

  // A thread list that shortens or reorders under the cursor would otherwise
  // leave it pointing past the end.
  onThreadsChanged: threadIndex = clamp(threadIndex, 0, Math.max(0, threads.length - 1))
  onMessagesChanged: if (messageIndex >= messages.length) messageIndex = messages.length - 1

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      threadIndex = 0
      messageIndex = -1
      if (service) service.refresh()
    } else {
      // The popup is a glance surface: it opens on the conversation list, not
      // wherever it was left. Reopening a thread is one keystroke.
      composer.text = ""
      goBack()
    }
  }

  visible: !hideWhenDisconnected || state.level === "ok"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "tether"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    // Jump straight to one conversation, for a keybinding or a script:
    //   omarchy-shell tether openThread 'tel:+15550001111'
    // Thread keys are what `tether --bt-threads` prints.
    function openThread(key: string): void {
      root.open()
      root.openConversation(key)
    }

    function back(): void { root.goBack() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.service ? root.service.barTooltip : "Tether"

    // Read from inside `iconComponent`, where naming the enclosing panel would
    // be ambiguous with BarIconButton's own root.
    readonly property bool hasUnread: root.unread > 0
    readonly property bool live: root.state.level === "ok"
    readonly property color glyphColor: live ? root.fg : Qt.darker(root.fg, 1.55)
    readonly property color dotColor: root.attention
    // Forced opaque: the ring's whole job is to cut the badge out of the glyph
    // behind it, and a semi-transparent bar would let the ink show through.
    readonly property color ringColor: {
      var base = root.bar ? root.bar.background : Color.bar.background
      return Qt.rgba(base.r, base.g, base.b, 1.0)
    }
    readonly property color openFill: Style.selectedFillFor(root.fg, Color.accent)
    readonly property bool panelOpen: root.opened

    iconComponent: Component {
      Item {
        Rectangle {
          anchors.centerIn: parent
          width: Style.space(20)
          height: width
          radius: Style.cornerRadius
          visible: button.panelOpen
          color: button.openFill
        }

        Text {
          id: mark
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: Model.GLYPH.bubble
          color: button.glyphColor
          font.family: button.fontFamily
          font.pixelSize: button.fontSize
          renderType: Text.NativeRendering
        }

        // A count in the bar would need a second glyph run and a width that
        // moves every time a message lands. The dot answers the only question
        // a message icon is asked from across the room.
        //
        // Drawn as a dot inside a ring of bar background rather than as a bare
        // dot: a theme is free to be monochrome, and this one is — accent,
        // bar.active and the foreground are all the same grey, so a dot of any
        // theme colour laid on the glyph is invisible. The cut-out is what
        // makes the badge read, in every theme, colour or not.
        Rectangle {
          id: badge
          visible: button.hasUnread
          width: Style.space(8)
          height: width
          radius: width / 2
          color: button.ringColor
          anchors.right: mark.right
          anchors.top: mark.top
          anchors.rightMargin: -width * 0.25
          anchors.topMargin: -width * 0.15

          Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.62
            height: width
            radius: width / 2
            color: button.dotColor
          }
        }
      }
    }

    onPressed: function (pressedButton) {
      if (pressedButton === Qt.MiddleButton) {
        if (root.service) root.service.refresh()
        return
      }
      if (pressedButton === Qt.RightButton) {
        root.launchApp()
        return
      }
      root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the composer holds focus every key belongs to it, including the
      // j and k that would otherwise drive the cursor.
      blocked: composer.activeFocus

      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) {
          root.cursorActive = true
          return
        }
        if (dy !== 0) {
          root.moveCursor(dy)
          return
        }
        if (dx > 0 && !root.inConversation) root.openAt(root.threadIndex)
        else if (dx < 0 && root.inConversation) root.goBack()
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.inConversation ? root.goBack() : root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (text) {
        if (text === "r" && root.canReply) composer.forceActiveFocus()
        else if (text === "o") root.launchApp()
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(14)

        // ---------- Hero: what the link is doing ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, refreshButton.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: Model.GLYPH.bubble
            color: root.fg
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            opacity: root.state.level === "ok" ? 1.0 : 0.5
          }

          PanelActionButton {
            id: refreshButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: Model.GLYPH.refresh
            tooltipText: "Refresh"
            foreground: root.fg
            hoverColor: root.fg
            fontFamily: root.bar.fontFamily
            onClicked: if (root.service) root.service.refresh()
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: refreshButton.width + Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: root.unread > 0 ? "Messages · " + root.unread + " unread" : "Messages"
              color: root.fg
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.state.title.toUpperCase()
              color: root.state.level === "ok" ? Qt.darker(root.fg, 1.4) : root.attention
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // The daemon writes these reasons for people, so they are shown rather
        // than reworded into something less specific.
        Text {
          visible: root.state.level !== "ok" && root.state.detail !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.state.detail
          color: root.muted
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator { foreground: root.fg }

        // ---------- Conversations ----------
        Column {
          id: threadsView
          visible: !root.inConversation
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "CONVERSATIONS"
            foreground: root.fg
            fontFamily: root.bar.fontFamily
          }

          ListView {
            id: threadList
            width: parent.width
            height: Math.min(contentHeight, Style.space(360))
            spacing: Style.space(6)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            visible: root.threads.length > 0

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            model: root.threads
            currentIndex: root.cursorActive ? root.threadIndex : -1
            onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(keepCurrentVisible)
            function keepCurrentVisible() {
              if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
            }

            delegate: Item {
              required property var modelData
              required property int index
              width: ListView.view.width
              height: threadRow.implicitHeight

              ThreadRow {
                id: threadRow
                width: parent.width
                thread: modelData
                rowIndex: index
              }
            }
          }

          Text {
            visible: root.threads.length === 0
            width: parent.width
            textFormat: Text.PlainText
            text: root.state.level === "ok"
              ? "No conversations yet. Messages appear as the phone syncs them."
              : "No conversations to show."
            color: root.muted
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }

        // ---------- One conversation ----------
        Column {
          id: conversationView
          visible: root.inConversation
          width: parent.width
          spacing: Style.space(10)

          Item {
            width: parent.width
            implicitHeight: Math.max(backButton.implicitHeight, conversationLabels.implicitHeight)

            PanelActionButton {
              id: backButton
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              iconText: Model.GLYPH.back
              tooltipText: "Back to conversations"
              foreground: root.fg
              hoverColor: root.fg
              fontFamily: root.bar.fontFamily
              onClicked: root.goBack()
            }

            Column {
              id: conversationLabels
              anchors.left: backButton.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              Text {
                textFormat: Text.PlainText
                text: root.openRow ? root.openRow.title : root.openThread
                color: root.fg
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                visible: !!root.openRow && root.openRow.named && root.openRow.address !== ""
                textFormat: Text.PlainText
                text: root.openRow ? root.openRow.address : ""
                color: root.muted
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          ListView {
            id: messageList
            width: parent.width
            height: Math.min(contentHeight, Style.space(340))
            spacing: Style.space(8)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            visible: root.messages.length > 0

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            model: root.messages
            currentIndex: root.cursorActive ? root.messageIndex : -1

            // A conversation opens on its newest message, the way it is read.
            // Only while the cursor is parked, so j/k is never yanked back down
            // by an arriving message.
            onCountChanged: if (!root.cursorActive) Qt.callLater(positionViewAtEnd)
            onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(keepCurrentVisible)
            function keepCurrentVisible() {
              if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
            }

            delegate: Item {
              required property var modelData
              required property int index
              width: ListView.view.width
              height: bubbleColumn.implicitHeight

              MessageBubble {
                id: bubbleColumn
                width: parent.width
                message: modelData
                rowIndex: index
              }
            }
          }

          Text {
            visible: root.messages.length === 0
            width: parent.width
            textFormat: Text.PlainText
            text: root.service && root.service.messagesLoading ? "Loading…" : "No messages in this conversation."
            color: root.muted
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // ---------- Composer ----------
          Item {
            width: parent.width
            visible: root.canReply
            implicitHeight: Math.max(composer.implicitHeight, sendButton.implicitHeight)

            TextField {
              id: composer
              anchors.left: parent.left
              anchors.right: sendButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              enabled: root.canReply && !(root.service && root.service.sending)
              placeholderText: root.service && root.service.sending ? "Sending…" : "Reply…"
              foreground: root.fg
              onAccepted: root.submitReply()
              // The key catcher stands down while this has focus, so Escape has
              // to be answered here or it would close nothing.
              Keys.onEscapePressed: function (event) {
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
            }

            PanelActionButton {
              id: sendButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: Model.GLYPH.send
              tooltipText: "Send"
              enabled: composer.text.trim() !== "" && !(root.service && root.service.sending)
              foreground: root.fg
              hoverColor: Color.accent
              fontFamily: root.bar.fontFamily
              onClicked: root.submitReply()
            }
          }

          Text {
            visible: root.inConversation && !root.canReply
            width: parent.width
            textFormat: Text.PlainText
            text: !!root.openRow && !root.openRow.repliable
              ? "This conversation cannot be replied to from here."
              : "Replies need the phone's Messages connection."
            color: root.muted
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: !!root.service && root.service.sendError !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.service ? Model.GLYPH.alert + "  " + root.service.sendError : ""
            color: root.attention
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ---------- Footer ----------
        PanelSeparator { foreground: root.fg }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            text: "Open Tether"
            iconText: Model.GLYPH.external
            bordered: true
            foreground: root.fg
            fontFamily: root.bar.fontFamily
            onClicked: root.launchApp()
          }

          Button {
            visible: root.state.level === "warn"
            text: "Reconnect"
            iconText: Model.GLYPH.phone
            bordered: true
            foreground: root.fg
            fontFamily: root.bar.fontFamily
            onClicked: if (root.service) root.service.reconnectPhone()
          }
        }
      }
    }
  }

  // ---------- Row types ----------

  // One conversation: who, what they last said, when, and whether it is unread.
  component ThreadRow: CursorSurface {
    id: threadRowRoot

    required property var thread
    required property int rowIndex

    readonly property bool rowSelected: root.cursorActive && !root.inConversation && root.threadIndex === rowIndex
    readonly property bool hasUnread: thread.unread > 0
    readonly property string letters: Model.initials(thread.title)

    hasCursor: rowSelected
    foreground: root.fg
    fill: root.hoverFill
    currentFill: root.selectedFill

    implicitHeight: threadContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: threadMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor

      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.threadIndex = threadRowRoot.rowIndex
      }
      onClicked: root.openConversation(threadRowRoot.thread.key)
    }

    Item {
      id: threadContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(avatar.height, threadText.implicitHeight, threadMeta.implicitHeight)

      Rectangle {
        id: avatar
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(30)
        height: width
        radius: width / 2
        color: Qt.rgba(
          root.tints[Model.tintIndex(threadRowRoot.thread.key, root.tints.length)].r,
          root.tints[Model.tintIndex(threadRowRoot.thread.key, root.tints.length)].g,
          root.tints[Model.tintIndex(threadRowRoot.thread.key, root.tints.length)].b,
          0.22)

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          // A thread keyed by a bare number has no letters to show, so it gets
          // the glyph instead of a mangled initial.
          text: threadRowRoot.letters !== "" ? threadRowRoot.letters : Model.GLYPH.phone
          color: root.fg
          font.family: root.bar.fontFamily
          font.pixelSize: threadRowRoot.letters !== "" ? Style.font.bodySmall : Style.font.icon
          font.bold: true
        }
      }

      Column {
        id: threadText
        anchors.left: avatar.right
        anchors.leftMargin: Style.space(10)
        anchors.right: threadMeta.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          text: threadRowRoot.thread.title
          color: root.fg
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          font.bold: threadRowRoot.hasUnread
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          visible: root.showPreviews && threadRowRoot.thread.preview !== ""
          textFormat: Text.PlainText
          text: threadRowRoot.thread.preview
          color: threadRowRoot.hasUnread ? Qt.darker(root.fg, 1.2) : root.muted
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }

      Column {
        id: threadMeta
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Text {
          anchors.right: parent.right
          textFormat: Text.PlainText
          text: Model.relativeTime(threadRowRoot.thread.timestamp, root.clockNow)
          color: root.muted
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        Rectangle {
          anchors.right: parent.right
          visible: threadRowRoot.hasUnread
          width: Style.space(7)
          height: width
          radius: width / 2
          color: root.attention
        }
      }
    }
  }

  // One message. Incoming sits left, outgoing right, the way a thread is read.
  component MessageBubble: Column {
    id: bubbleRoot

    required property var message
    required property int rowIndex

    readonly property bool selected: root.cursorActive && root.inConversation && root.messageIndex === rowIndex

    spacing: Style.space(6)

    Text {
      visible: bubbleRoot.message.dayBreak !== ""
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: bubbleRoot.message.dayBreak
      color: root.muted
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Item {
      width: parent.width
      implicitHeight: bubble.implicitHeight

      // Measured off an unwrapped copy of the body rather than off the Text
      // that draws it: binding a wrapped Text's width to its own implicitWidth
      // is the classic way to build a layout loop.
      TextMetrics {
        id: bodyMetrics
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        text: bubbleRoot.message.body
      }

      Rectangle {
        id: bubble
        anchors.left: bubbleRoot.message.outgoing ? undefined : parent.left
        anchors.right: bubbleRoot.message.outgoing ? parent.right : undefined
        width: Math.min(parent.width * 0.82, bodyMetrics.width + Style.space(24))
        implicitHeight: bubbleBody.implicitHeight + Style.space(10)
        radius: Style.cornerRadius
        color: bubbleRoot.selected
          ? root.hoverFill
          : (bubbleRoot.message.outgoing
            ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.20)
            : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.07))
        opacity: bubbleRoot.message.pending ? 0.6 : 1.0

        Behavior on opacity { NumberAnimation { duration: 140 } }

        Column {
          id: bubbleBody
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          spacing: Style.space(2)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: bubbleRoot.message.body
            color: root.fg
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }

          Row {
            anchors.right: bubbleRoot.message.outgoing ? parent.right : undefined
            spacing: Style.space(4)

            Text {
              textFormat: Text.PlainText
              text: Model.clockTime(bubbleRoot.message.timestamp)
              color: root.muted
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: bubbleRoot.message.outgoing && !bubbleRoot.message.pending
              textFormat: Text.PlainText
              text: Model.GLYPH.check
              color: root.muted
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  // Relative stamps go stale while the panel sits open. One minute is the
  // finest thing they resolve, so that is how often they are recomputed.
  property int clockNow: Math.floor(Date.now() / 1000)
  Timer {
    interval: 30000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: root.clockNow = Math.floor(Date.now() / 1000)
  }
}
