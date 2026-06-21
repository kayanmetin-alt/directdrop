import Flutter
import UIKit
import UserNotifications
import FirebaseMessaging

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var filesChannelRegistered = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }

    GeneratedPluginRegistrant.register(with: self)
    application.registerForRemoteNotifications()

    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    DispatchQueue.main.async { [weak self] in
      self?.registerFilesChannelIfNeeded()
    }
    return ok
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Messaging.messaging().apnsToken = deviceToken
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    NSLog("DirectDrop APNs kaydı başarısız: \(error.localizedDescription)")
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
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
        Self.openInFilesApp(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    MediaPickerChannel.register(with: controller, messenger: controller.binaryMessenger)
  }

  /// Dosyalar uygulamasında DirectDrop indirme klasörünü açar.
  private static func openInFilesApp(result: @escaping FlutterResult) {
    let fm = FileManager.default
    guard let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
      result(false)
      return
    }

    let downloadsURL = documentsURL
      .appendingPathComponent("DirectDrop", isDirectory: true)
      .appendingPathComponent("Downloads", isDirectory: true)

    do {
      try fm.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
    } catch {
      result(false)
      return
    }

    var candidates: [URL] = []
    for folder in [downloadsURL, documentsURL.appendingPathComponent("DirectDrop", isDirectory: true), documentsURL] {
      if let shared = sharedDocumentsURL(for: folder) {
        candidates.append(shared)
      }
    }
    if let filesRoot = URL(string: "shareddocuments://") {
      candidates.append(filesRoot)
    }

    tryOpenURLs(candidates, index: 0, result: result)
  }

  private static func sharedDocumentsURL(for fileURL: URL) -> URL? {
    if var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) {
      components.scheme = "shareddocuments"
      if let url = components.url { return url }
    }
    let path = fileURL.path
    if path.isEmpty { return nil }
    return URL(string: "shareddocuments://\(path)")
  }

  private static func tryOpenURLs(
    _ urls: [URL],
    index: Int,
    result: @escaping FlutterResult
  ) {
    guard index < urls.count else {
      result(false)
      return
    }

    let url = urls[index]
    DispatchQueue.main.async {
      UIApplication.shared.open(url, options: [:]) { success in
        if success {
          result(true)
        } else {
          tryOpenURLs(urls, index: index + 1, result: result)
        }
      }
    }
  }
}
