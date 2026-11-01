"""Run the shipped focus binding with Quickshell's real keyed delegates."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class DelegateFocusTests(unittest.TestCase):
    def test_focus_tracks_address_during_reorder(self):
        source = Path(__file__).with_name("Service.qml").read_text()
        # Extract the actual binding, not a separately maintained copy.
        start = source.index("      readonly property", source.index("readonly property string workspaceName:"))
        bindings = source[start:source.index("      readonly property int padX:", start)]
        harness = '''import QtQuick
import Quickshell
ShellRoot {
  id: root
  property var entries: [{address: "0xa", focused: true}, {address: "0xb", focused: false}]
BINDINGS
  Row {
    id: tabs
    Repeater {
      id: repeater
      model: ScriptModel { values: root.entries; objectProp: "address" }
      delegate: Item { required property var modelData; width: 100; height: 30 }
    }
  }
  property int step: 0
  property var scenarios: [
    [{address: "0xb", focused: true}, {address: "0xa", focused: false}],
    [{address: "0xa", focused: false}, {address: "0xb", focused: true}],
    [{address: "0xa", focused: true}, {address: "0xb", focused: false}],
    [{address: "0xb", focused: false}],
    [{address: "0xc", focused: true}, {address: "0xb", focused: false}],
    []
  ]
  Timer {
    id: advance; interval: 30; running: true
    onTriggered: { root.entries = root.scenarios[root.step]; check.start() }
  }
  Timer {
    id: check; interval: 30
    onTriggered: {
      var expected = root.entries.find(e => e.focused)
      var address = expected ? expected.address : ""
      var actual = root.focusedTab ? root.focusedTab.modelData.address : ""
      if (actual !== address) {
        console.error("FAIL focus after reorder", root.step, "expected", address, "actual", actual)
        Qt.quit()
        return
      }
      root.step++
      if (root.step === root.scenarios.length) { console.log("PASS focus identity"); Qt.quit() }
      else advance.start()
    }
  }
}
'''.replace("BINDINGS", bindings)
        with tempfile.TemporaryDirectory(prefix="window-strip-qml-") as directory:
            entry = Path(directory) / "shell.qml"
            entry.write_text(harness)
            result = subprocess.run(
                ["qs", "-p", str(entry)],
                env={**os.environ, "QT_QPA_PLATFORM": "offscreen"},
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=5,
            )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("PASS focus identity", result.stdout)


if __name__ == "__main__":
    unittest.main()
