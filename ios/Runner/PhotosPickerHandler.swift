import Flutter
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers

enum HeicJpegConverter {
  private static let heicExtensions: Set<String> = ["heic", "heif"]

  static func isHeicFile(_ url: URL) -> Bool {
    heicExtensions.contains(url.pathExtension.lowercased())
  }

  static func convertPaths(_ paths: [String]) -> [String] {
    paths.map { path in
      let url = URL(fileURLWithPath: path)
      guard isHeicFile(url) else { return path }
      return convertFile(at: url)?.path ?? path
    }
  }

  static func convertFile(at source: URL) -> URL? {
    guard let sourceImage = CGImageSourceCreateWithURL(source as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(sourceImage, 0, nil)
    else {
      return nil
    }

    let destination = source.deletingPathExtension().appendingPathExtension("jpg")
    if FileManager.default.fileExists(atPath: destination.path) {
      try? FileManager.default.removeItem(at: destination)
    }

    guard let destRef = CGImageDestinationCreateWithURL(
      destination as CFURL,
      UTType.jpeg.identifier as CFString,
      1,
      nil
    ) else {
      return nil
    }

    let options = [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
    CGImageDestinationAddImage(destRef, cgImage, options)
    guard CGImageDestinationFinalize(destRef) else { return nil }
    return destination
  }
}

final class MediaPickerProgressSink: NSObject, FlutterStreamHandler {
  static let shared = MediaPickerProgressSink()

  private var eventSink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func emitExportProgress(
    completed: Int,
    total: Int,
    fraction: Double,
    fileName: String?
  ) {
    var payload: [String: Any] = [
      "phase": "exporting",
      "completed": completed,
      "total": max(total, 1),
      "fraction": min(max(fraction, 0), 1),
    ]
    if let fileName, !fileName.isEmpty {
      payload["fileName"] = fileName
    }
    eventSink?(payload)
  }
}

/// Fotoğraflar kütüphanesinden görsel ve video seçimi (PHPicker).
final class PhotosPickerHandler: NSObject, PHPickerViewControllerDelegate {
  static let shared = PhotosPickerHandler()

  private var pendingResult: FlutterResult?
  private weak var presentingController: UIViewController?
  private var preferJpegExport = false
  private var exportCancelled = false
  private var activeExportResult: FlutterResult?
  private var progressObservations: [NSKeyValueObservation] = []

  private override init() {
    super.init()
  }

  func cancelExport() {
    exportCancelled = true
    progressObservations.removeAll()
    if let result = activeExportResult {
      activeExportResult = nil
      result(FlutterError(code: "cancelled", message: "Medya hazırlığı iptal edildi.", details: nil))
    }
  }

  func pick(
    from controller: UIViewController,
    preferJpeg: Bool,
    result: @escaping FlutterResult
  ) {
    guard pendingResult == nil else {
      result(FlutterError(code: "busy", message: "Seçim zaten açık.", details: nil))
      return
    }

    preferJpegExport = preferJpeg
    pendingResult = result
    presentingController = controller

    var config = PHPickerConfiguration(photoLibrary: .shared())
    config.selectionLimit = 0
    config.filter = .any(of: [.images, .videos])
    if #available(iOS 15.0, *) {
      config.preferredAssetRepresentationMode = .current
    }

    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    if UIDevice.current.userInterfaceIdiom == .pad {
      picker.modalPresentationStyle = .formSheet
      picker.preferredContentSize = CGSize(width: 540, height: 720)
    } else {
      picker.modalPresentationStyle = .pageSheet
    }
    controller.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)

    guard let result = pendingResult else { return }
    pendingResult = nil
    presentingController = nil

    if results.isEmpty {
      preferJpegExport = false
      result(nil)
      return
    }

    exportResults(results, result: result)
  }

  private func exportResults(_ results: [PHPickerResult], result: @escaping FlutterResult) {
    exportCancelled = false
    activeExportResult = result
    progressObservations.removeAll()

    let destination = uniqueExportDestination()
    var paths: [String] = []
    var seen = Set<String>()
    let lock = NSLock()
    let group = DispatchGroup()
    let total = results.count
    var finishedCount = 0

    func addPath(_ path: String) {
      lock.lock()
      defer { lock.unlock() }
      if seen.insert(path).inserted {
        paths.append(path)
      }
    }

    func emitOverall(currentIndex: Int, itemFraction: Double, fileName: String?) {
      let overall = total == 0
        ? 0.0
        : (Double(currentIndex) + itemFraction) / Double(total)
      MediaPickerProgressSink.shared.emitExportProgress(
        completed: currentIndex,
        total: total,
        fraction: overall,
        fileName: fileName
      )
    }

    emitOverall(currentIndex: 0, itemFraction: 0, fileName: nil)

    for (index, pick) in results.enumerated() {
      if exportCancelled { break }

      let provider = pick.itemProvider
      guard let typeId = preferredTypeIdentifier(for: provider) else {
        finishedCount += 1
        emitOverall(currentIndex: finishedCount, itemFraction: 0, fileName: nil)
        continue
      }

      let fileName = provider.suggestedName
      group.enter()

      let progressObs = provider.observe(\.progress, options: [.new, .initial]) { prov, _ in
        guard let progress = prov.progress else { return }
        let fraction = progress.totalUnitCount > 0
          ? Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
          : 0
        emitOverall(currentIndex: index, itemFraction: fraction, fileName: fileName)
      }
      progressObservations.append(progressObs)

      provider.loadFileRepresentation(forTypeIdentifier: typeId) { [weak self] url, error in
        progressObs.invalidate()
        defer { group.leave() }

        guard let self else { return }
        if self.exportCancelled { return }

        if let error {
          debugPrint("PhotosPicker: load failed \(error)")
          lock.lock()
          finishedCount += 1
          let done = finishedCount
          lock.unlock()
          emitOverall(currentIndex: done, itemFraction: 0, fileName: fileName)
          return
        }
        guard let url else {
          lock.lock()
          finishedCount += 1
          let done = finishedCount
          lock.unlock()
          emitOverall(currentIndex: done, itemFraction: 0, fileName: fileName)
          return
        }
        if let copied = self.copyLoadedFile(from: url, provider: provider, destination: destination) {
          addPath(copied.path)
        }
        lock.lock()
        finishedCount += 1
        let done = finishedCount
        lock.unlock()
        emitOverall(currentIndex: done, itemFraction: 0, fileName: fileName)
      }
    }

    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      self.progressObservations.removeAll()
      self.activeExportResult = nil
      self.preferJpegExport = false

      if self.exportCancelled {
        result(FlutterError(code: "cancelled", message: "Medya hazırlığı iptal edildi.", details: nil))
        return
      }

      result(paths.isEmpty ? nil : paths)
    }
  }

  private func preferredTypeIdentifier(for provider: NSItemProvider) -> String? {
    if Self.videoTypes.contains(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
      return Self.videoTypes.first { provider.hasItemConformingToTypeIdentifier($0) }
    }
    if Self.imageTypes(preferJpeg: preferJpegExport).contains(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
      return Self.imageTypes(preferJpeg: preferJpegExport).first {
        provider.hasItemConformingToTypeIdentifier($0)
      }
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

  private static func imageTypes(preferJpeg: Bool) -> [String] {
    if preferJpeg {
      return [
        UTType.jpeg.identifier,
        UTType.heic.identifier,
        UTType.png.identifier,
        UTType.tiff.identifier,
        UTType.image.identifier,
        "public.jpeg",
        "public.heic",
      ]
    }
    return [
      UTType.heic.identifier,
      UTType.jpeg.identifier,
      UTType.png.identifier,
      UTType.tiff.identifier,
      UTType.image.identifier,
      "public.heic",
      "public.jpeg",
    ]
  }

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
      if preferJpegExport, HeicJpegConverter.isHeicFile(output),
         let jpeg = HeicJpegConverter.convertFile(at: output)
      {
        try? FileManager.default.removeItem(at: output)
        return jpeg
      }
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
  static let eventsName = "com.directdrop.app/media_picker_events"

  static func register(with controller: UIViewController, messenger: FlutterBinaryMessenger) {
    let events = FlutterEventChannel(name: eventsName, binaryMessenger: messenger)
    events.setStreamHandler(MediaPickerProgressSink.shared)

    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "pickFromPhotos":
        let args = call.arguments as? [String: Any]
        let preferJpeg = args?["preferJpeg"] as? Bool ?? false
        PhotosPickerHandler.shared.pick(
          from: controller,
          preferJpeg: preferJpeg,
          result: result
        )
      case "cancelPhotoExport":
        PhotosPickerHandler.shared.cancelExport()
        result(nil)
      case "convertHeicToJpeg":
        guard let args = call.arguments as? [String: Any],
              let paths = args["paths"] as? [String]
        else {
          result(FlutterError(
            code: "invalid_args",
            message: "paths gerekli.",
            details: nil))
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let converted = HeicJpegConverter.convertPaths(paths)
          DispatchQueue.main.async {
            result(converted)
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
