import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  @IBAction func showAbout(_ sender: Any?) {
    let credits = NSMutableAttributedString(string: "作者：Sinri Edogawa\n问题反馈：\n")
    let issuesURL = URL(string: "https://github.com/sinri/imbroglio/issues")!
    credits.append(NSAttributedString(
      string: issuesURL.absoluteString,
      attributes: [.link: issuesURL]
    ))
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    guard let window = mainFlutterWindow else { return true }
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
    sender.activate(ignoringOtherApps: true)
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
