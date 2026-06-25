import Flutter
import UIKit

/// Aktif transfer oturumunda iOS arka plan süresini uzatır.
final class TransferBackgroundTaskHandler {
  static let shared = TransferBackgroundTaskHandler()

  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
  private var sessionActive = false

  func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "com.directdrop.app/transfer_session",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "setSessionActive":
        self.sessionActive = (call.arguments as? Bool) ?? false
        if !self.sessionActive {
          self.endBackgroundTask()
        }
        result(nil)
      case "beginBackgroundTask":
        self.beginBackgroundTask()
        result(nil)
      case "endBackgroundTask":
        self.endBackgroundTask()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func beginBackgroundTask() {
    endBackgroundTask()
    backgroundTaskId = UIApplication.shared.beginBackgroundTask(
      withName: "DirectDropTransfer"
    ) { [weak self] in
      guard let self else { return }
      self.endBackgroundTask()
      if self.sessionActive {
        self.beginBackgroundTask()
      }
    }
  }

  private func endBackgroundTask() {
    if backgroundTaskId != .invalid {
      UIApplication.shared.endBackgroundTask(backgroundTaskId)
      backgroundTaskId = .invalid
    }
  }
}
