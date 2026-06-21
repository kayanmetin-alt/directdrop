import AppKit
import FlutterMacOS
import PhotosUI
import UniformTypeIdentifiers

/// Fotoğraflar kütüphanesinden görsel ve video seçimi (PHPicker, macOS 13+).
@available(macOS 13.0, *)
final class PhotosPickerHandler: NSObject, PHPickerViewControllerDelegate {
  static let shared = PhotosPickerHandler()

  private var pendingResult: FlutterResult?
  private weak var presentingController: NSViewController?

  private override init() {
    super.init()
  }

  func pick(from controller: NSViewController, result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(FlutterError(code: "busy", message: "Seçim zaten açık.", details: nil))
      return
    }

    pendingResult = result

    var config = PHPickerConfiguration(photoLibrary: .shared())
    config.selectionLimit = 0
    config.filter = .any(of: [.images, .videos])

    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    picker.preferredContentSize = NSSize(width: 960, height: 640)

    // Sheet, Flutter NSViewController üzerinde küçük kalıyor; modal pencere tam boyut verir.
    let presenter = NSApp.mainWindow?.contentViewController ?? controller
    presentingController = presenter

    NSApp.activate(ignoringOtherApps: true)
    presenter.presentAsModalWindow(picker)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    presentingController?.dismiss(picker)

    guard let result = pendingResult else { return }
    pendingResult = nil
    presentingController = nil

    if results.isEmpty {
      result(nil)
      return
    }

    exportResults(results, result: result)
  }

  private func exportResults(_ results: [PHPickerResult], result: @escaping FlutterResult) {
    let destination = uniqueExportDestination()
    var paths: [String] = []
    var seen = Set<String>()
    let lock = NSLock()
    let group = DispatchGroup()

    func addPath(_ path: String) {
      lock.lock()
      defer { lock.unlock() }
      if seen.insert(path).inserted {
        paths.append(path)
      }
    }

    for pick in results {
      let provider = pick.itemProvider
      guard let typeId = preferredTypeIdentifier(for: provider) else { continue }

      group.enter()
      provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, error in
        defer { group.leave() }
        if let error {
          debugPrint("PhotosPicker: load failed \(error)")
          return
        }
        guard let url else { return }
        if let copied = self.copyLoadedFile(from: url, provider: provider, destination: destination) {
          addPath(copied.path)
        }
      }
    }

    group.notify(queue: .main) {
      result(paths.isEmpty ? nil : paths)
    }
  }

  private func preferredTypeIdentifier(for provider: NSItemProvider) -> String? {
    if Self.videoTypes.contains(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
      return Self.videoTypes.first { provider.hasItemConformingToTypeIdentifier($0) }
    }
    if Self.imageTypes.contains(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
      return Self.imageTypes.first { provider.hasItemConformingToTypeIdentifier($0) }
    }
    return UTType.data.identifier
  }

  private static let videoTypes: [String] = [
    UTType.movie.identifier,
    UTType.mpeg4Movie.identifier,
    UTType.quickTimeMovie.identifier,
    UTType.video.identifier,
    "public.mpeg-4",
    "com.apple.quicktime-movie",
  ]

  private static let imageTypes: [String] = [
    UTType.heic.identifier,
    UTType.jpeg.identifier,
    UTType.png.identifier,
    UTType.tiff.identifier,
    UTType.image.identifier,
    "public.heic",
    "public.jpeg",
  ]

  private func copyLoadedFile(
    from url: URL,
    provider: NSItemProvider,
    destination: URL
  ) -> URL? {
    let baseName = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let stem = (baseName?.isEmpty == false) ? baseName! : UUID().uuidString
    let ext = url.pathExtension.isEmpty ? defaultExtension(for: provider) : url.pathExtension
    let output = destination.appendingPathComponent(stem).appendingPathExtension(ext)

    do {
      if FileManager.default.fileExists(atPath: output.path) {
        try FileManager.default.removeItem(at: output)
      }
      try FileManager.default.copyItem(at: url, to: output)
      return output
    } catch {
      debugPrint("PhotosPicker: copy failed \(error)")
      return nil
    }
  }

  private func defaultExtension(for provider: NSItemProvider) -> String {
    if Self.videoTypes.contains(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
      return "mov"
    }
    return "jpg"
  }

  private func uniqueExportDestination() -> URL {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("DirectDrop/PhotosPicker", isDirectory: true)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd_HHmmss_SSS'Z'"
    let stamp = formatter.string(from: Date())
    let destination = base.appendingPathComponent(stamp, isDirectory: true)
    try? FileManager.default.createDirectory(
      at: destination,
      withIntermediateDirectories: true,
      attributes: nil)
    return destination
  }
}

enum MediaPickerChannel {
  static let name = "com.directdrop.app/media_picker"

  static func register(with controller: NSViewController, messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "pickFromPhotos":
        if #available(macOS 13.0, *) {
          PhotosPickerHandler.shared.pick(from: controller, result: result)
        } else {
          result(FlutterError(
            code: "unsupported",
            message: "Fotoğraflar seçici macOS 13 veya üzeri gerektirir.",
            details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
