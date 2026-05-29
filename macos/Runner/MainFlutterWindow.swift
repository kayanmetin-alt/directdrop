import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    WindowFrameStorage.restore(to: self)

    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    removeEmbeddedDropTargets(from: flutterViewController.view)

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

    let dropView = DirectDropDragTarget(
      frame: flutterViewController.view.bounds,
      messenger: flutterViewController.engine.binaryMessenger)
    dropView.autoresizingMask = [.width, .height]
    flutterViewController.view.addSubview(dropView, positioned: .above, relativeTo: nil)

    MediaPickerChannel.register(
      with: flutterViewController,
      messenger: flutterViewController.engine.binaryMessenger)

    WindowFrameStorage.startObserving(self)

    super.awakeFromNib()
  }

  /// desktop_drop eklentisinin eski sürükleyici katmanını kaldırır.
  private func removeEmbeddedDropTargets(from view: NSView) {
    for subview in view.subviews {
      let typeName = String(describing: type(of: subview))
      if typeName.contains("DropTarget") {
        subview.removeFromSuperview()
        continue
      }
      removeEmbeddedDropTargets(from: subview)
    }
  }
}
