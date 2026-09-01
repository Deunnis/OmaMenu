import QtQuick
import qs.Commons
import qs.Ui

// Live style editor for this menu, shown in place of the row list when the
// "Menu Look" row under Style is chosen. Every slider writes straight to the
// menu's cfg* properties (instant preview) and debounces a save of the small
// JSON file behind them.
Item {
  id: root

  // The Menu.qml root. Read for colors/fonts, written for the live values.
  property Item menu: null

  signal done()

  readonly property color fg: root.menu ? root.menu.foreground : Color.foreground
  readonly property string fam: root.menu ? root.menu.fontFamily : Style.font.family

  Timer {
    id: saveTimer
    interval: 300
    onTriggered: if (root.menu) root.menu.saveLookConfig()
  }
  function commit() { saveTimer.restart() }

  component Knob: Column {
    id: knob
    property string title: ""
    property string readout: ""
    property real value: 0
    property real from: 0
    property real to: 1
    property real stepBy: 1
    property bool integer: true
    signal moved(real v)

    width: parent ? parent.width : 0
    spacing: Style.space(5)

    Row {
      width: parent.width
      Text {
        text: knob.title
        width: parent.width - roText.width
        color: root.fg
        font.family: root.fam
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        id: roText
        text: knob.readout
        color: root.fg
        opacity: 0.6
        font.family: root.fam
        font.pixelSize: Style.font.body
      }
    }

    PanelSlider {
      width: parent.width
      value: knob.value
      minimum: knob.from
      maximum: knob.to
      step: knob.stepBy
      integer: knob.integer
      fillColor: root.fg
      knobColor: root.fg
      onMoved: function (v) { knob.moved(v) }
      onReleased: function (v) { knob.moved(v) }
    }
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(16)

    Text {
      text: "Menu Look"
      color: root.fg
      font.family: root.fam
      font.pixelSize: Style.font.heading
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      text: "Applies to this menu only, live as you drag, saved per theme — "
        + "switching themes switches these too. Esc or ← goes back."
      color: root.fg
      opacity: 0.55
      font.family: root.fam
      font.pixelSize: Style.font.bodySmall
    }

    Knob {
      title: "Size"
      integer: false
      from: 0.8; to: 1.5; stepBy: 0.05
      value: root.menu ? root.menu.cfgScale : 1
      readout: (root.menu ? root.menu.cfgScale : 1).toFixed(2) + "×"
      onMoved: function (v) { if (root.menu) { root.menu.cfgScale = v; root.commit() } }
    }

    Knob {
      title: "Corner roundness"
      from: 0; to: 24; stepBy: 1
      value: root.menu ? root.menu.effCornerRadius : 0
      readout: (root.menu ? root.menu.effCornerRadius : 0) + " px"
      onMoved: function (v) { if (root.menu) { root.menu.cfgCornerRadius = Math.round(v); root.commit() } }
    }

    Knob {
      title: "Border width"
      from: 0; to: 6; stepBy: 1
      value: root.menu ? root.menu.effBorderWidth : 1
      readout: (root.menu ? root.menu.effBorderWidth : 1) + " px"
      onMoved: function (v) { if (root.menu) { root.menu.cfgBorderWidth = Math.round(v); root.commit() } }
    }

    Knob {
      title: "Transparency"
      from: 0; to: 90; stepBy: 5
      value: root.menu ? root.menu.cfgTransparency : 0
      readout: (root.menu ? root.menu.cfgTransparency : 0) + "%"
      onMoved: function (v) { if (root.menu) { root.menu.cfgTransparency = Math.round(v); root.commit() } }
    }

    Item { width: 1; height: Style.space(2) }

    Text {
      text: "Reset to theme defaults"
      color: root.fg
      opacity: resetHover.hovered ? 1 : 0.6
      font.family: root.fam
      font.pixelSize: Style.font.bodySmall
      HoverHandler { id: resetHover }
      TapHandler { onTapped: if (root.menu) root.menu.resetLookConfig() }
    }
  }
}
