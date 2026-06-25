import Cocoa

/// Son pencere boyutu ve konumunu UserDefaults'ta saklar.
enum WindowFrameStorage {
  private static let prefix = "com.directdrop.app.window"
  private static let minWidth: CGFloat = 400
  private static let minHeight: CGFloat = 720
  private static let maxWidth: CGFloat = 520
  private static let maxHeight: CGFloat = 920
  private static let defaultWidth: CGFloat = 440
  private static let defaultHeight: CGFloat = 780

  static func applyConstraints(to window: NSWindow) {
    window.minSize = NSSize(width: minWidth, height: minHeight)
    window.maxSize = NSSize(width: maxWidth, height: maxHeight)
    window.contentAspectRatio = NSSize(width: defaultWidth, height: defaultHeight)
  }

  static func restore(to window: NSWindow) {
    applyConstraints(to: window)
    guard let frame = loadFrame() else { return }
    window.setFrame(frame, display: false)
  }

  static func save(from window: NSWindow) {
    guard window.isVisible, !window.isMiniaturized else { return }

    var frame = window.frame
    frame.size.width = min(max(frame.size.width, minWidth), maxWidth)
    frame.size.height = min(max(frame.size.height, minHeight), maxHeight)
    guard frame.width >= minWidth, frame.height >= minHeight else { return }

    let defaults = UserDefaults.standard
    defaults.set(Double(frame.origin.x), forKey: "\(prefix).x")
    defaults.set(Double(frame.origin.y), forKey: "\(prefix).y")
    defaults.set(Double(frame.size.width), forKey: "\(prefix).width")
    defaults.set(Double(frame.size.height), forKey: "\(prefix).height")
  }

  static func startObserving(_ window: NSWindow) {
    let center = NotificationCenter.default
    center.addObserver(
      forName: NSWindow.didResizeNotification,
      object: window,
      queue: .main
    ) { _ in
      save(from: window)
    }
    center.addObserver(
      forName: NSWindow.didMoveNotification,
      object: window,
      queue: .main
    ) { _ in
      save(from: window)
    }
  }

  private static func loadFrame() -> NSRect? {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: "\(prefix).width") != nil else { return nil }

    var frame = NSRect(
      x: defaults.double(forKey: "\(prefix).x"),
      y: defaults.double(forKey: "\(prefix).y"),
      width: defaults.double(forKey: "\(prefix).width"),
      height: defaults.double(forKey: "\(prefix).height"))

    frame.size.width = min(max(frame.size.width, minWidth), maxWidth)
    frame.size.height = min(max(frame.size.height, minHeight), maxHeight)

    guard frame.width >= minWidth, frame.height >= minHeight else { return nil }
    guard isVisibleOnAnyScreen(frame) else { return nil }
    return frame
  }

  private static func isVisibleOnAnyScreen(_ frame: NSRect) -> Bool {
    let intersection = NSScreen.screens.contains { screen in
      !screen.visibleFrame.intersection(frame).isNull
    }
    return intersection
  }
}
