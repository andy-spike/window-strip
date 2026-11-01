import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Ui

Item {
  id: root
  property var shell: null
  property var state: ({ panels: {}, error: "Connecting to Hyprland…" })
  readonly property int stripHeight: Math.max(36, Style.font.body + Style.space(24))
  readonly property string backend: Qt.resolvedUrl("windows.py").toString().replace("file://", "")
  readonly property int motion: 140

  // Tab surfaces come from the bar palette, so they follow light and dark
  // themes. They sit on the wallpaper, so even resting tabs keep a backing.
  readonly property color tabRestFill: Util.alpha(Color.bar.background, 0.4)
  readonly property color tabHoverFill: Util.alpha(Color.bar.background, 0.75)
  readonly property color tabActiveFill: Util.alpha(Color.bar.background, 0.97)
  readonly property color tabRestBorder: Util.alpha(Color.bar.text, 0.08)
  // The focused tab's accent outline, a touch lighter than the 2 px window border.
  readonly property color tabActiveBorder: Color.accent
  readonly property real tabActiveBorderWidth: 1.5

  function closeWindow(address) {
    if (!/^0x[0-9a-f]+$/i.test(address)) return
    Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.window.close({ window = "address:' + address + '" })'])
  }

  // Resolves a window class to its desktop entry's icon. Desktop entries load
  // after startup and change when apps are installed, so every change clears
  // the cache and bumps iconRevision, which makes each tab look its icon up again.
  property var iconCache: ({})
  property int iconRevision: 0
  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      root.iconCache = ({})
      root.iconRevision++
    }
  }
  function iconFor(windowClass) {
    var key = String(windowClass || "")
    if (!key) return ""
    if (iconCache[key]) return iconCache[key]
    var entry = DesktopEntries.heuristicLookup(key)
    var icon = entry && entry.icon ? String(entry.icon) : ""
    var source = icon.charAt(0) === "/" ? "file://" + icon : icon ? Quickshell.iconPath(icon, true) : ""
    if (source) iconCache[key] = source
    return source
  }

  function focusWindow(address) {
    if (!/^0x[0-9a-f]+$/i.test(address)) return
    Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.focus({ window = "address:' + address + '" })'])
  }

  // Returns the title without the app name it often repeats, or "" when the
  // title adds nothing beyond the app name.
  function titleOf(entry) {
    var title = (entry.title || "").replace(/\s+/g, " ").trim()
    var app = entry.app || "Window"
    if (!title || title.toLowerCase() === app.toLowerCase()) return ""
    if (title.toLowerCase().indexOf(app.toLowerCase() + " (") === 0)
      title = title.slice(app.length + 2).replace(/\)$/, "")
    // Drop a trailing "- App", "— App Browser" or "| App" suffix.
    var suffix = title.match(/\s+[-–—|]\s+([^-–—|]+)$/)
    // Match the whole app name, so "Notes - Zenith" keeps "Zenith" for Zen.
    if (suffix) {
      var tail = suffix[1].trim().toLowerCase()
      var name = app.toLowerCase()
      if (tail === name || tail.indexOf(name + " ") === 0) title = title.slice(0, suffix.index)
    }
    return title
  }

  function label(entry) {
    var title = titleOf(entry)
    return (entry.app || "Window") + (title ? " · " + title : "")
  }

  Process {
    id: watcher
    command: ["python3", "-u", root.backend]
    running: true
    stdout: SplitParser {
      onRead: function(data) {
        try { root.state = JSON.parse(data) }
        catch (error) { console.warn("Window Strip: invalid state", error) }
      }
    }
    onExited: {
      root.state = { panels: {}, error: "Reconnecting to Hyprland…" }
      restartTimer.start()
    }
  }
  Timer {
    id: restartTimer
    interval: 2000
    onTriggered: watcher.running = true
  }

  // Useful for diagnostics and for checking the exact action used by clicks.
  IpcHandler {
    target: "window-strip"
    function status(): string { return JSON.stringify(root.state) }
    function focus(address: string): void { root.focusWindow(address) }
    function icons(): string {
      var result = {}
      for (var name in root.state.panels)
        root.state.panels[name].windows.forEach(function(w) { result[w["class"]] = root.iconFor(w["class"]) })
      return JSON.stringify(result)
    }
  }

  Variants {
    model: Quickshell.screens
    delegate: PanelWindow {
      id: panel
      required property var modelData
      screen: modelData
      readonly property var workspaceState: root.state.panels[modelData.name] || ({ workspace: "", windows: [] })
      readonly property var entries: workspaceState.windows
      readonly property string workspaceName: workspaceState.workspace
      readonly property string focusedAddress: {
        for (var i = 0; i < entries.length; i++) if (entries[i].focused) return entries[i].address
        return ""
      }
      readonly property Item focusedTab: {
        // ScriptModel moves existing delegates. Their numeric positions can
        // change while the focused index and total row width stay the same.
        for (var i = 0; i < repeater.count; i++) {
          var item = repeater.itemAt(i)
          if (item && item.modelData.address === focusedAddress) return item
        }
        return null
      }
      readonly property int padX: Style.spacing.controlPaddingX
      readonly property int maxEntryWidth: Style.space(280)
      readonly property int minEntryWidth: Style.space(96)
      readonly property int tabInsetY: Style.space(4)
      // Match the window corners (Hyprland's rounding), capped to a pill.
      readonly property real tabRadius: Math.min(Style.cornerRadius, (root.stripHeight - 2 * tabInsetY) / 2)
      readonly property int iconSize: Math.round(Style.font.body * 1.34)
      readonly property real fadeWidth: Style.space(28)
      property bool layoutReady: false
      // Cleared automatically when the hovered window closes.
      property Item hoveredTab: null
      property bool tooltipVisible: false
      readonly property bool barHidden: root.shell && root.shell.bar ? root.shell.bar.barHidden : false
      // The overlay layer draws above fullscreen windows, unlike the bar's
      // top layer. Stay mapped so the reserved row does not reflow the
      // windows behind, but draw nothing and pass every click through.
      readonly property bool fullscreen: workspaceState.fullscreen === true
      visible: !barHidden && !remapGuard.remapping
      mask: fullscreen ? emptyMask : null
      Region { id: emptyMask }
      onFullscreenChanged: if (fullscreen) tooltipVisible = false
      ScreenMoveRemap {
        id: remapGuard
        window: panel
      }
      anchors { top: true; left: true; right: true }
      implicitHeight: root.stripHeight
      color: "transparent"
      surfaceFormat.opaque: false
      // Hyprland reserves lower layers first. The overlay layer places this
      // row after the top-layer status bar, consistently across shell reloads.
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.namespace: "omarchy-window-strip"
      exclusionMode: ExclusionMode.Auto

      function clampScroll(x) {
        return Math.max(0, Math.min(x, Math.max(0, view.contentWidth - view.width)))
      }
      // Wheel scrolling moves at once. Focus changes glide into view.
      function scrollTo(x, animate) {
        x = clampScroll(x)
        if (animate && scrollAnimation.running && Math.abs(scrollAnimation.to - x) < 0.5) return
        scrollAnimation.stop()
        if (animate && Math.abs(x - view.contentX) > 0.5) {
          scrollAnimation.to = x
          scrollAnimation.start()
        } else {
          view.contentX = x
        }
      }
      function revealFocused() {
        var tab = focusedTab
        var target = scrollAnimation.running ? scrollAnimation.to : view.contentX
        if (tab) {
          if (tab.x < target) target = tab.x
          else if (tab.x + tab.width > target + view.width) target = tab.x + tab.width - view.width
        }
        scrollTo(target, layoutReady && !snapFocus)
        // Only the first reveal after focus returns snaps. Later focus
        // changes on the same layout glide again.
        if (tab) snapFocus = false
      }
      // A new workspace or a returning focus should appear in place rather
      // than slide in from the previous position. A new workspace waits for
      // the row to lay out; a returning focus only skips one animation.
      property bool snapFocus: false
      onWorkspaceNameChanged: layoutReady = false
      onFocusedTabChanged: {
        if (!focusedTab) snapFocus = true
        Qt.callLater(revealFocused)
      }
      onHoveredTabChanged: if (!hoveredTab) {
        hoverTimer.stop()
        tooltipVisible = false
      }
      onEntriesChanged: Qt.callLater(revealFocused)

      Flickable {
        id: view
        readonly property bool hiddenLeft: contentX > 1
        readonly property bool hiddenRight: contentX + width < contentWidth - 1
        anchors { fill: parent; leftMargin: 2 * Style.gapsOut; rightMargin: 2 * Style.gapsOut }
        visible: !panel.fullscreen
        clip: true
        interactive: false
        contentWidth: tabs.width
        contentHeight: height
        onContentXChanged: panel.tooltipVisible = false
        onWidthChanged: Qt.callLater(panel.revealFocused)
        NumberAnimation {
          id: scrollAnimation
          target: view
          property: "contentX"
          duration: root.motion
          easing.type: Easing.OutCubic
        }

        // Soft edges replace a scrollbar: they appear only on the side
        // that has hidden windows.
        layer.enabled: hiddenLeft || hiddenRight
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: fadeMask
          maskThresholdMin: 0
          maskSpreadAtMin: 1
        }

        Row {
          id: tabs
          height: view.height
          // Entry positions are only valid once the row has laid out.
          onPositioningComplete: {
            panel.revealFocused()
            if (panel.focusedTab) panel.layoutReady = true
          }
          spacing: Style.space(6)
          Repeater {
            id: repeater
            // Keyed by address, so each window keeps its delegate (and hover
            // state) across updates instead of the row being rebuilt.
            model: ScriptModel { values: panel.entries; objectProp: "address" }
            delegate: Item {
              id: tab
              required property var modelData
              required property int index
              readonly property string title: root.titleOf(modelData)
              readonly property bool active: modelData.focused
              readonly property bool hovered: pointer.containsMouse || closeArea.containsMouse
              readonly property string iconSource: root.iconRevision, root.iconFor(modelData["class"])
              readonly property real leadWidth: (appIcon.visible ? appIcon.width + content.spacing : 0)
                + (modelData.floating ? glyph.width + content.spacing : 0)
              // The close button's room is always reserved, so a tab keeps its
              // width when the button fades in on hover.
              readonly property real closeWidth: closeButton.width + content.spacing
              readonly property real naturalWidth: leadWidth + appText.implicitWidth
                + (title ? content.spacing + titleText.implicitWidth : 0) + closeWidth
              readonly property real textRoom: Math.max(0, width - 2 * panel.padX - leadWidth - closeWidth)
              width: Math.max(panel.minEntryWidth, Math.min(panel.maxEntryWidth, naturalWidth + 2 * panel.padX))
              height: tabs.height
              // New windows fade in instead of popping into the row.
              opacity: 0
              Component.onCompleted: opacity = 1
              Behavior on opacity { NumberAnimation { duration: root.motion; easing.type: Easing.OutCubic } }
              // A reorder can move this tab out from under a still pointer.
              onXChanged: if (panel.hoveredTab === tab) panel.tooltipVisible = false
              // Closing a hovered window gives no exit event.
              Component.onDestruction: if (panel.hoveredTab === tab) panel.hoveredTab = null
              Accessible.role: Accessible.PageTab
              Accessible.name: root.label(modelData)
              Accessible.description: modelData.floating ? "Floating window" : "Tiled window"
              Accessible.focused: active
              Accessible.onPressAction: root.focusWindow(modelData.address)

              // Tabs sit on the wallpaper, so each gets its own surface: light
              // at rest, firmer on hover, solid for the focused window.
              Rectangle {
                id: surface
                anchors { fill: parent; topMargin: panel.tabInsetY; bottomMargin: panel.tabInsetY }
                radius: panel.tabRadius
                color: tab.active ? root.tabActiveFill : tab.hovered ? root.tabHoverFill : root.tabRestFill
                border.width: tab.active ? root.tabActiveBorderWidth : 1
                border.color: tab.active ? root.tabActiveBorder : root.tabRestBorder
                // An accent outline and a soft shadow lift the focused tab off
                // the row. Both belong to this tab, so a reorder cannot leave
                // them on another window.
                layer.enabled: tab.active
                layer.effect: MultiEffect {
                  shadowEnabled: true
                  shadowColor: "#000000"
                  shadowOpacity: 0.22
                  shadowBlur: 0.5
                  shadowVerticalOffset: 1
                  autoPaddingEnabled: true
                }
                Behavior on color { ColorAnimation { duration: root.motion } }
                Behavior on border.color { ColorAnimation { duration: root.motion } }

                // Press feedback tints the surface without moving anything.
                Rectangle {
                  anchors.fill: parent
                  radius: parent.radius
                  color: Color.bar.text
                  opacity: pointer.pressed && !closeArea.containsMouse ? 0.08 : 0
                  Behavior on opacity { NumberAnimation { duration: 80 } }
                }
              }

              Row {
                id: content
                x: panel.padX
                anchors.verticalCenter: surface.verticalCenter
                spacing: Style.space(6)

                IconImage {
                  id: appIcon
                  visible: tab.iconSource !== ""
                  source: tab.iconSource
                  implicitSize: panel.iconSize
                  anchors.verticalCenter: parent.verticalCenter
                  opacity: tab.active || tab.hovered ? 1 : 0.8
                  Behavior on opacity { NumberAnimation { duration: root.motion } }
                }
                // Two offset outlines mark floating windows without relying
                // on a font glyph. The tooltip also names the state.
                Item {
                  id: glyph
                  visible: tab.modelData.floating
                  width: Math.round(Style.font.body * 0.75)
                  height: width
                  anchors.verticalCenter: parent.verticalCenter
                  Rectangle {
                    width: parent.width * 0.7; height: width; radius: 1
                    color: "transparent"; border.color: Color.bar.text
                  }
                  Rectangle {
                    x: parent.width * 0.3; y: x
                    width: parent.width * 0.7; height: width; radius: 1
                    color: "transparent"; border.color: Color.bar.text
                  }
                }
                Text {
                  id: appText
                  width: Math.min(implicitWidth, tab.textRoom
                    * (tab.title && tab.naturalWidth + 2 * panel.padX > panel.maxEntryWidth ? 0.45 : 1))
                  text: tab.modelData.app || "Window"
                  textFormat: Text.PlainText
                  color: Color.bar.text
                  opacity: tab.active ? 1 : 0.72
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.weight: Font.Normal
                  elide: Text.ElideRight
                  Behavior on opacity { NumberAnimation { duration: root.motion } }
                }
                Text {
                  id: titleText
                  visible: tab.title !== ""
                  width: Math.max(0, tab.textRoom - appText.width - content.spacing)
                  text: tab.title
                  textFormat: Text.PlainText
                  color: Color.bar.text
                  opacity: tab.active ? 1 : 0.72
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.weight: Font.Medium
                  elide: Text.ElideRight
                  Behavior on opacity { NumberAnimation { duration: root.motion } }
                }
              }
              MouseArea {
                id: pointer
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                // Middle-click closes, as it does for browser tabs.
                onClicked: function(mouse) {
                  if (mouse.button === Qt.MiddleButton) root.closeWindow(tab.modelData.address)
                  else root.focusWindow(tab.modelData.address)
                }
                onEntered: {
                  panel.hoveredTab = tab
                  hoverTimer.restart()
                }
                onExited: {
                  if (panel.hoveredTab === tab) {
                    hoverTimer.stop()
                    panel.tooltipVisible = false
                    panel.hoveredTab = null
                  }
                }
              }
              // Shown on the focused tab and on hover, like browser tabs.
              Item {
                id: closeButton
                width: panel.iconSize
                height: width
                anchors { right: surface.right; rightMargin: Math.round(panel.padX * 0.6); verticalCenter: surface.verticalCenter }
                opacity: tab.hovered || tab.active ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: root.motion } }
                Accessible.role: Accessible.Button
                Accessible.name: "Close " + root.label(tab.modelData)
                Accessible.onPressAction: root.closeWindow(tab.modelData.address)
                Rectangle {
                  anchors.fill: parent
                  radius: width / 2
                  color: Color.bar.text
                  opacity: closeArea.pressed ? 0.18 : closeArea.containsMouse ? 0.1 : 0
                  Behavior on opacity { NumberAnimation { duration: 80 } }
                }
                Repeater {
                  model: [45, -45]
                  Rectangle {
                    required property real modelData
                    anchors.centerIn: parent
                    width: Math.round(parent.width * 0.5)
                    height: Math.max(1, Math.round(Style.spaceReal(1.5)))
                    radius: height / 2
                    rotation: modelData
                    antialiasing: true
                    color: Color.bar.text
                    opacity: closeArea.containsMouse ? 1 : 0.7
                  }
                }
                MouseArea {
                  id: closeArea
                  anchors.fill: parent
                  enabled: closeButton.opacity > 0
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.closeWindow(tab.modelData.address)
                }
              }
            }
          }
        }

      }

      Rectangle {
        id: fadeMask
        anchors.fill: view
        visible: false
        layer.enabled: true
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: view.hiddenLeft ? "transparent" : "white" }
          GradientStop { position: panel.fadeWidth / Math.max(1, view.width); color: "white" }
          GradientStop { position: 1 - panel.fadeWidth / Math.max(1, view.width); color: "white" }
          GradientStop { position: 1; color: view.hiddenRight ? "transparent" : "white" }
        }
      }

      WheelHandler {
        target: null
        enabled: !panel.fullscreen
        onWheel: function(event) {
          var delta = event.pixelDelta.x || event.pixelDelta.y || (event.angleDelta.x || event.angleDelta.y) / 2
          panel.scrollTo(view.contentX - delta, false)
        }
      }

      Text {
        anchors { left: parent.left; leftMargin: view.anchors.leftMargin + panel.padX; verticalCenter: parent.verticalCenter }
        visible: panel.entries.length === 0 && !panel.fullscreen
        text: root.state.error || "No windows"
        color: Color.bar.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      Timer {
        id: hoverTimer
        interval: 500
        onTriggered: panel.tooltipVisible = panel.hoveredTab !== null
      }
      PopupWindow {
        id: tooltip
        readonly property var entry: panel.hoveredTab ? panel.hoveredTab.modelData : null
        readonly property real centerX: panel.hoveredTab ? view.x + panel.hoveredTab.x - view.contentX + panel.hoveredTab.width / 2 : 0
        visible: panel.tooltipVisible && entry !== null && !panel.fullscreen
        color: "transparent"
        implicitWidth: tooltipBubble.width
        implicitHeight: tooltipBubble.height
        anchor {
          window: panel
          rect.x: Math.max(view.x, Math.min(tooltip.centerX - tooltipBubble.width / 2, panel.width - view.x - tooltipBubble.width))
          rect.y: panel.height + Style.space(4)
          edges: Edges.Top | Edges.Left
          gravity: Edges.Bottom | Edges.Right
        }
        Rectangle {
          id: tooltipBubble
          readonly property int padX: Style.spacing.controlPaddingX
          readonly property int padY: Style.spacing.controlPaddingY
          width: Math.min(Style.space(560), tooltipColumn.implicitWidth + 2 * padX)
          height: tooltipColumn.implicitHeight + 2 * padY
          color: Color.tooltip.background
          border.color: Util.alpha(Color.tooltip.border, 0.25)
          border.width: Style.normalBorderWidth
          radius: Style.cornerRadius
          Column {
            id: tooltipColumn
            x: tooltipBubble.padX; y: tooltipBubble.padY
            width: tooltipBubble.width - 2 * tooltipBubble.padX
            spacing: Style.space(2)
            Text {
              width: Math.min(implicitWidth, Style.space(560) - 2 * tooltipBubble.padX)
              text: tooltip.entry ? tooltip.entry.title || tooltip.entry.app : ""
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              color: Color.tooltip.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              visible: tooltip.entry ? tooltip.entry.floating : false
              text: "Floating"
              color: Color.tooltip.text
              opacity: 0.8
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}
