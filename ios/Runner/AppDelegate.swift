import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var filesChannelRegistered = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    registerFilesChannelIfNeeded()
  }

  private func registerFilesChannelIfNeeded() {
    guard !filesChannelRegistered else { return }

    var controller = window?.rootViewController as? FlutterViewController
    if controller == nil {
      for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene else { continue }
        for window in windowScene.windows where window.isKeyWindow {
          controller = window.rootViewController as? FlutterViewController
          break
        }
        if controller != nil { break }
      }
    }

    guard let controller else { return }
    filesChannelRegistered = true

    let channel = FlutterMethodChannel(
      name: "com.directdrop.app/files",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "openDownloadsFolder":
        guard let path = call.arguments as? String, !path.isEmpty else {
          result(
            FlutterError(
              code: "INVALID_ARGS",
              message: "Klasör yolu gerekli",
              details: nil
            )
          )
          return
        }
        Self.openInFilesApp(path: path, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func openInFilesApp(path: String, result: @escaping FlutterResult) {
    let fm = FileManager.default
    let resolved = (path as NSString).expandingTildeInPath
    var isDir: ObjCBool = false

    if !fm.fileExists(atPath: resolved, isDirectory: &isDir) {
      do {
        try fm.createDirectory(
          atPath: resolved,
          withIntermediateDirectories: true,
          attributes: nil
        )
      } catch {
        result(false)
        return
      }
    }

    let folderURL = URL(fileURLWithPath: resolved, isDirectory: true)
    let sharedString = folderURL.absoluteString.replacingOccurrences(
      of: "file://",
      with: "shareddocuments://"
    )

    guard let sharedURL = URL(string: sharedString) else {
      result(false)
      return
    }

    DispatchQueue.main.async {
      UIApplication.shared.open(sharedURL, options: [:]) { success in
        result(success)
      }
    }
  }
}
