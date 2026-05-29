import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// Photos gibi uygulamalar videoyu JPEG önizlemesi olarak değil, gerçek dosya olarak çözer.
final class DirectDropDragTarget: NSView {
  private let channel: FlutterMethodChannel
  private let itemsLock = NSLock()
  private lazy var workQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.qualityOfService = .userInitiated
    return queue
  }()

  private static let videoTypeIdentifiers: [String] = [
    UTType.movie.identifier,
    UTType.mpeg4Movie.identifier,
    UTType.quickTimeMovie.identifier,
    UTType.video.identifier,
    "public.mpeg-4",
    "com.apple.quicktime-movie",
  ]

  private static let imageTypeIdentifiers: [String] = [
    UTType.jpeg.identifier,
    UTType.png.identifier,
    UTType.tiff.identifier,
    UTType.heic.identifier,
    UTType.image.identifier,
    "public.jpeg",
  ]

  init(frame frameRect: NSRect, messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.directdrop.app/drop",
      binaryMessenger: messenger)
    super.init(frame: frameRect)
    registerDragTypes()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func registerDragTypes() {
    var types = NSFilePromiseReceiver.readableDraggedTypes.map {
      NSPasteboard.PasteboardType($0)
    }
    types.append(.fileURL)
    types.append(NSPasteboard.PasteboardType("NSFilenamesPboardType"))
    types.append(NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"))
    for typeId in Self.videoTypeIdentifiers + Self.imageTypeIdentifiers {
      types.append(NSPasteboard.PasteboardType(typeId))
    }
    registerForDraggedTypes(types)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    channel.invokeMethod("dragEntered", arguments: nil)
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    channel.invokeMethod("dragExited", arguments: nil)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let pasteboard = sender.draggingPasteboard
    let destination = uniqueDropDestination()
    var paths: [String] = []
    var seen = Set<String>()
    let group = DispatchGroup()

    func addPath(_ path: String) {
      itemsLock.lock()
      defer { itemsLock.unlock() }
      if seen.insert(path).inserted {
        paths.append(path)
      }
    }

    func finish() {
      channel.invokeMethod("dragExited", arguments: nil)
      if !paths.isEmpty {
        channel.invokeMethod("droppedFiles", arguments: paths)
      }
    }

    // Photos hem JPEG URL hem de asıl dosya için NSFilePromiseReceiver verir.
    // URL'ler önce okunursa yalnızca önizleme gider — önce promise'ları tercih et.
    if let receivers = pasteboard.readObjects(
      forClasses: [NSFilePromiseReceiver.self],
      options: nil) as? [NSFilePromiseReceiver],
      !receivers.isEmpty {
      for receiver in receivers {
        group.enter()
        receiver.receivePromisedFiles(
          atDestination: destination,
          options: [:],
          operationQueue: workQueue
        ) { url, error in
          if let error {
            debugPrint("DirectDrop: file promise error: \(error)")
          } else {
            addPath(url.path)
          }
          group.leave()
        }
      }
      group.notify(queue: .main) { finish() }
      return true
    }

    let providers = itemProviders(from: pasteboard)
    let videoProviders = providers.filter { provider in
      Self.videoTypeIdentifiers.contains {
        provider.hasItemConformingToTypeIdentifier($0)
      }
    }

    if !videoProviders.isEmpty {
      for provider in videoProviders {
        group.enter()
        loadVideo(from: provider, destination: destination) { url in
          if let url {
            addPath(url.path)
          }
          group.leave()
        }
      }
      group.notify(queue: .main) {
        if paths.isEmpty {
          self.resolveFileUrls(from: pasteboard, addPath: addPath, finish: finish)
        } else {
          finish()
        }
      }
      return true
    }

    if pasteboardIndicatesVideo(pasteboard) {
      for provider in providers {
        group.enter()
        loadBestRepresentation(from: provider, destination: destination) { url in
          if let url {
            addPath(url.path)
          }
          group.leave()
        }
      }
      group.notify(queue: .main) {
        if paths.isEmpty {
          self.resolveFileUrls(from: pasteboard, addPath: addPath, finish: finish)
        } else {
          finish()
        }
      }
      return true
    }

    resolveFileUrls(from: pasteboard, addPath: addPath, finish: finish)
    return true
  }

  private func resolveFileUrls(
    from pasteboard: NSPasteboard,
    addPath: (String) -> Void,
    finish: @escaping () -> Void
  ) {
    let urls = (pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    let legacyList = (pasteboard.propertyList(
      forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String]) ?? []

    urls.forEach { addPath($0.path) }
    legacyList.forEach { addPath($0) }
    finish()
  }

  private func pasteboardIndicatesVideo(_ pasteboard: NSPasteboard) -> Bool {
    for item in pasteboard.pasteboardItems ?? [] {
      for type in item.types {
        let raw = type.rawValue.lowercased()
        if Self.videoTypeIdentifiers.contains(type.rawValue) {
          return true
        }
        if raw.contains("movie") || raw.contains("mpeg") || raw.contains("quicktime") {
          return true
        }
      }
    }
    return false
  }

  private func itemProviders(from pasteboard: NSPasteboard) -> [NSItemProvider] {
    (pasteboard.readObjects(
      forClasses: [NSItemProvider.self],
      options: nil) as? [NSItemProvider]) ?? []
  }

  private func loadBestRepresentation(
    from provider: NSItemProvider,
    destination: URL,
    completion: @escaping (URL?) -> Void
  ) {
    if Self.videoTypeIdentifiers.contains(where: {
      provider.hasItemConformingToTypeIdentifier($0)
    }) {
      loadVideo(from: provider, destination: destination, completion: completion)
      return
    }

    let typeId = Self.imageTypeIdentifiers.first(where: {
      provider.hasItemConformingToTypeIdentifier($0)
    }) ?? UTType.data.identifier

    provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, error in
      guard let url else {
        if let error {
          debugPrint("DirectDrop: load failed: \(error)")
        }
        completion(nil)
        return
      }
      completion(self.copyLoadedFile(from: url, provider: provider, destination: destination))
    }
  }

  private func loadVideo(
    from provider: NSItemProvider,
    destination: URL,
    completion: @escaping (URL?) -> Void
  ) {
    guard let typeId = Self.videoTypeIdentifiers.first(where: {
      provider.hasItemConformingToTypeIdentifier($0)
    }) else {
      completion(nil)
      return
    }

    provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, error in
      guard let url else {
        if let error {
          debugPrint("DirectDrop: video load failed: \(error)")
        }
        completion(nil)
        return
      }
      completion(self.copyLoadedFile(from: url, provider: provider, destination: destination))
    }
  }

  private func copyLoadedFile(
    from url: URL,
    provider: NSItemProvider,
    destination: URL
  ) -> URL? {
    let baseName = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let stem = (baseName?.isEmpty == false) ? baseName! : UUID().uuidString
    let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
    let output = destination.appendingPathComponent(stem).appendingPathExtension(ext)

    do {
      if FileManager.default.fileExists(atPath: output.path) {
        try FileManager.default.removeItem(at: output)
      }
      try FileManager.default.copyItem(at: url, to: output)
      return output
    } catch {
      debugPrint("DirectDrop: copy failed: \(error)")
      return nil
    }
  }

  private func uniqueDropDestination() -> URL {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("DirectDrop/Drops", isDirectory: true)
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
