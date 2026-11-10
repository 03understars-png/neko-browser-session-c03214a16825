import AppKit
import ApplicationServices

let askers: Set<String> = ["UserNotificationCenter", "CoreServicesUIAgent", "universalaccessd", "SecurityAgent",
                           "Sunshine", "System Settings", "NotificationCenter"]

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
  var value: AnyObject?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
  (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func title(_ element: AXUIElement) -> String {
  (attribute(element, kAXTitleAttribute) as? String) ?? (attribute(element, kAXDescriptionAttribute) as? String) ?? ""
}

func wanted(_ label: String) -> Bool {
  label == "Allow" || label.hasPrefix("Use “Brave") || label.hasPrefix("Use \"Brave")
}
let dismissers: Set<String> = ["universalAccessAuthWarn"]

func press(in element: AXUIElement, dismiss: Bool = false, depth: Int = 0) -> Bool {
  if depth > 8 { return false }
  for child in children(element) {
    let role = (attribute(child, kAXRoleAttribute) as? String) ?? ""
    if role == kAXButtonRole as String && (dismiss ? title(child) == "Deny" : wanted(title(child))) {
      return AXUIElementPerformAction(child, kAXPressAction as CFString) == .success
    }
    if press(in: child, dismiss: dismiss, depth: depth + 1) { return true }
  }
  return false
}

if !AXIsProcessTrusted() && CommandLine.arguments.dropFirst().first != "--list" {
  FileHandle.standardError.write("clicker: no Accessibility permission\n".data(using: .utf8)!)
  Thread.sleep(forTimeInterval: 10)
  exit(1)
}
func buttons(_ element: AXUIElement, depth: Int = 0) -> [String] {
  if depth > 8 { return [] }
  return children(element).flatMap { child -> [String] in
    let role = (attribute(child, kAXRoleAttribute) as? String) ?? ""
    let text = role == kAXStaticTextRole as String ? ["“" + ((attribute(child, kAXValueAttribute) as? String) ?? "") + "”"] : []
    return (role == kAXButtonRole as String ? [title(child)] : []) + text + buttons(child, depth: depth + 1)
  }
}
if CommandLine.arguments.dropFirst().first == "--list" {
  for app in NSWorkspace.shared.runningApplications {
    let element = AXUIElementCreateApplication(app.processIdentifier)
    let windows = (attribute(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    if !windows.isEmpty { print(app.localizedName ?? "?", windows.map { buttons($0) }) }
  }
  exit(0)
}
func answerNotifications(_ element: AXUIElement, depth: Int = 0) -> Bool {
  if depth > 10 { return false }
  var names: CFArray?
  if AXUIElementCopyActionNames(element, &names) == .success, let actions = names as? [String] {
    var described: [(String, String)] = []
    for action in actions {
      var text: CFString?
      _ = AXUIElementCopyActionDescription(element, action as CFString, &text)
      described.append((action, text.map { $0 as String } ?? action))
    }
    for wanted in ["Allow", "Close"] {
      if let found = described.first(where: { $0.1 == wanted }) {
        return AXUIElementPerformAction(element, found.0 as CFString) == .success
      }
    }
  }
  for child in children(element) where answerNotifications(child, depth: depth + 1) { return true }
  return false
}

func ours(_ window: AXUIElement) -> Bool {
  let text = buttons(window).joined(separator: " ")
  return ["“Sunshine”", "“bash”", "“CuaDriver”", "“Cua Driver”", "“sh”", "“python3”"].contains { text.contains($0) }
}

let quietUntil: Double = {
  let args = Array(CommandLine.arguments.dropFirst())
  if let at = args.firstIndex(of: "--quiet-until"), at + 1 < args.count { return Double(args[at + 1]) ?? 0 }
  return 0
}()

while true {
  for app in NSWorkspace.shared.runningApplications {
    let name = app.localizedName ?? ""
    let bundle = app.bundleIdentifier ?? ""
    if bundle == "com.apple.systempreferences" && Date().timeIntervalSince1970 < quietUntil {
      if app.forceTerminate() { FileHandle.standardError.write("closed System Settings\n".data(using: .utf8)!) }
      continue
    }
    if bundle == "com.apple.notificationcenterui" {
      let element = AXUIElementCreateApplication(app.processIdentifier)
      for window in (attribute(element, kAXWindowsAttribute) as? [AXUIElement]) ?? [] where answerNotifications(window) {
        FileHandle.standardError.write("answered a notification\n".data(using: .utf8)!)
      }
    }
    let dismiss = dismissers.contains(name)
    if bundle.hasPrefix("com.apple.") && !askers.contains(name) && !dismiss {
      let element = AXUIElementCreateApplication(app.processIdentifier)
      for window in (attribute(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
      where buttons(window).joined(separator: " ").contains("private window picker") && press(in: window) {
        FileHandle.standardError.write("allowed the streamer past the window picker\n".data(using: .utf8)!)
      }
    }
    guard dismiss || askers.contains(name) || bundle.hasPrefix("com.apple.") && name.hasSuffix("Agent") else { continue }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    var refused = false
    for window in (attribute(element, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
      if press(in: window, dismiss: dismiss) {
        FileHandle.standardError.write("pressed a button of \(name)\n".data(using: .utf8)!)
      } else if ours(window) {
        refused = true
      }
    }
    let windows = (attribute(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    let onlyLocalNetwork = !windows.isEmpty && windows.allSatisfy { buttons($0).joined(separator: " ").contains("find devices on local networks") }
    if refused && name == "UserNotificationCenter" && onlyLocalNetwork && app.forceTerminate() {
      FileHandle.standardError.write("closed the local network questions about the desktop's own parts\n".data(using: .utf8)!)
    } else if refused && name == "UserNotificationCenter" {
      for window in windows where ours(window) {
        var away = CGPoint(x: -4000, y: -4000)
        if let value = AXValueCreate(.cgPoint, &away),
           AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success {
          FileHandle.standardError.write("moved a question about the desktop's own parts off the screen\n".data(using: .utf8)!)
        }
      }
    }
    if refused && name == "universalAccessAuthWarn" && app.forceTerminate() {
      FileHandle.standardError.write("closed \(name): a question about the desktop's own parts\n".data(using: .utf8)!)
    }
  }
  RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
}
