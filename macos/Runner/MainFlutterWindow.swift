import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let windowChannel = FlutterMethodChannel(
      name: "com.directdrop.app/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    windowChannel.setMethodCallHandler { call, result in
      if call.method == "activate" {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
