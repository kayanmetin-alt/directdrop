import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    if let window = NSApp.mainWindow {
      WindowFrameStorage.save(from: window)
    }
    super.applicationWillTerminate(notification)
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
