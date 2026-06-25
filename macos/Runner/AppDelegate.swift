import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Dock simgesini gizle; uygulama yalnızca menü çubuğu simgesiyle çalışır.
    NSApp.setActivationPolicy(.accessory)
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Pencere gizlendiğinde uygulama arka planda (menü çubuğu simgesi) çalışmaya devam eder.
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    // Dock simgesi yok; yine de Launchpad / Spotlight ile açılırsa pencereyi göster.
    if !flag {
      NSApp.activate(ignoringOtherApps: true)
      for window in sender.windows {
        window.makeKeyAndOrderFront(nil)
      }
    }
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
