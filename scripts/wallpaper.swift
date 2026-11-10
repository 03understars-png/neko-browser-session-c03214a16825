import AppKit
guard CommandLine.arguments.count > 1 else { exit(2) }
let url = URL(fileURLWithPath: CommandLine.arguments[1])
var failed = false
for screen in NSScreen.screens {
  do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:]) } catch { failed = true }
}
exit(failed ? 1 : 0)
