import AppKit
import FlutterMacOS

/// Ana uygulama penceresine dokunmadan sağ üstte yardımcı NSPanel'ler gösterir.
final class DesktopAuxiliaryPanels {
  static let shared = DesktopAuxiliaryPanels()

  private var actionChannel: FlutterMethodChannel?
  private var reconnectPanel: AuxiliaryPanel?
  private var filesPanel: AuxiliaryPanel?
  private var hudPanel: AuxiliaryPanel?

  func register(messenger: FlutterBinaryMessenger) {
    actionChannel = FlutterMethodChannel(
      name: "com.directdrop.app/overlay",
      binaryMessenger: messenger
    )
    actionChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "sync":
        if let args = call.arguments as? [String: Any] {
          self.applySync(args)
        }
        result(nil)
      case "hideAll":
        self.hideAll()
        result(nil)
      case "playSound":
        Self.playRequestSound()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func hideAll() {
    reconnectPanel?.closePanel()
    reconnectPanel = nil
    filesPanel?.closePanel()
    filesPanel = nil
    hudPanel?.closePanel()
    hudPanel = nil
  }

  private func applySync(_ args: [String: Any]) {
    var yOffset: CGFloat = 0

    if let reconnect = args["reconnect"] as? [String: Any] {
      let panel = reconnectPanel ?? AuxiliaryPanel(kind: .reconnect)
      reconnectPanel = panel
      panel.updateReconnect(reconnect) { [weak self] action, payload in
        self?.sendAction(action, payload: payload)
      }
      panel.show(atStackOffset: yOffset)
      yOffset += panel.frame.height + 10
    } else {
      reconnectPanel?.closePanel()
      reconnectPanel = nil
    }

    if let files = args["files"] as? [String: Any] {
      let panel = filesPanel ?? AuxiliaryPanel(kind: .files)
      filesPanel = panel
      let structureChanged = panel.updateFiles(files) { [weak self] action, payload in
        self?.sendAction(action, payload: payload)
      }
      // Yalnızca satır yapısı değiştiğinde (ya da panel henüz görünür değilken)
      // yeniden konumlandır; salt ilerleme güncellemelerinde paneli oynatma —
      // aksi halde bekleyen satırdaki butonlara basmak zorlaşır.
      if structureChanged || !panel.isVisible {
        panel.show(atStackOffset: yOffset)
      }
      yOffset += panel.frame.height + 10
    } else {
      filesPanel?.closePanel()
      filesPanel = nil
    }

    if let hud = args["hud"] as? [String: Any] {
      let panel = hudPanel ?? AuxiliaryPanel(kind: .hud)
      hudPanel = panel
      panel.updateHud(hud) { [weak self] action, payload in
        self?.sendAction(action, payload: payload)
      }
      panel.show(atStackOffset: yOffset)
    } else {
      hudPanel?.closePanel()
      hudPanel = nil
    }
  }

  private func sendAction(_ action: String, payload: [String: Any]) {
    var args = payload
    args["action"] = action
    actionChannel?.invokeMethod("onAction", arguments: args)
  }

  /// Sağ köşe paneli arka planda bir istekle açıldığında kısa bir bildirim sesi
  /// çalar (uygulama gizliyken kullanıcının fark etmesi için).
  static func playRequestSound() {
    if let sound = NSSound(named: NSSound.Name("Glass")) {
      sound.play()
    } else {
      NSSound.beep()
    }
  }
}

// MARK: - Panel

private final class AuxiliaryPanel: NSPanel {
  enum Kind { case reconnect, files, hud }

  private let kind: Kind
  private var actionHandler: ((String, [String: Any]) -> Void)?

  private let effectView = NSVisualEffectView()
  private let headerRow = NSStackView()
  private let innerHeader = NSStackView()
  private let titleBlock = NSStackView()
  private let avatarBadge = AvatarBadge()
  private let titleLabel = NSTextField(labelWithString: "")
  private let closeButton = NSButton()
  private let subtitleLabel = NSTextField(labelWithString: "")
  private let stackView = NSStackView()
  private let buttonBar = NSStackView()
  private let listStack = NSStackView()
  private let spinner = NSProgressIndicator()

  private static let kPanelWidth: CGFloat = 380
  private static let kRowHeight: CGFloat = 32
  private static let kRowSpacing: CGFloat = 8

  private var contentWidthConstraint: NSLayoutConstraint?

  /// Aktif transferde paneli her ilerleme güncellemesinde baştan kurmamak için:
  /// satır yapısı aynı kaldığı sürece yalnızca ilerleme çubukları güncellenir;
  /// böylece bekleyen satırlardaki ✕/✓ butonları kararlı ve basılabilir kalır.
  private var fileProgressBars: [String: NSProgressIndicator] = [:]
  private var renderedFileSignature = ""

  init(kind: Kind) {
    self.kind = kind
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: Self.kPanelWidth, height: 140),
      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    level = .floating
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isMovableByWindowBackground = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    contentMinSize = NSSize(width: Self.kPanelWidth, height: 80)
    setupChrome()
  }

  private func applyPanelSize(height: CGFloat) {
    let h = max(height, 80)
    let size = NSSize(width: Self.kPanelWidth, height: h)
    setContentSize(size)
    contentView?.setFrameSize(size)
    contentWidthConstraint?.constant = Self.kPanelWidth
    layoutIfNeeded()
  }

  private func setupChrome() {
    effectView.material = .hudWindow
    effectView.state = .active
    effectView.blendingMode = .behindWindow
    effectView.wantsLayer = true
    effectView.layer?.cornerRadius = 18
    effectView.layer?.masksToBounds = true
    effectView.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.maximumNumberOfLines = 1
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let closeConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
    closeButton.image = NSImage(
      systemSymbolName: "xmark",
      accessibilityDescription: "Kapat"
    )?.withSymbolConfiguration(closeConfig)
    closeButton.imagePosition = .imageOnly
    closeButton.bezelStyle = .regularSquare
    closeButton.isBordered = false
    closeButton.contentTintColor = .secondaryLabelColor
    closeButton.toolTip = "Paneli kapat"
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
    closeButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
    closeButton.setContentHuggingPriority(.required, for: .horizontal)
    closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    let closeHandler = ButtonHandler(action: { [weak self] in
      guard let self else { return }
      self.actionHandler?("panel_dismiss", ["kind": self.panelKindName])
    })
    objc_setAssociatedObject(
      closeButton, &ButtonHandler.key, closeHandler, .OBJC_ASSOCIATION_RETAIN)
    closeButton.target = closeHandler
    closeButton.action = #selector(ButtonHandler.invoke)

    subtitleLabel.font = .systemFont(ofSize: 12)
    subtitleLabel.textColor = .secondaryLabelColor
    subtitleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.maximumNumberOfLines = 2

    avatarBadge.translatesAutoresizingMaskIntoConstraints = false
    avatarBadge.widthAnchor.constraint(equalToConstant: 38).isActive = true
    avatarBadge.heightAnchor.constraint(equalToConstant: 38).isActive = true
    avatarBadge.setContentHuggingPriority(.required, for: .horizontal)
    avatarBadge.isHidden = true

    // Başlık + alt yazı dikey blok.
    titleBlock.orientation = .vertical
    titleBlock.alignment = .leading
    titleBlock.spacing = 2
    titleBlock.addArrangedSubview(titleLabel)
    titleBlock.addArrangedSubview(subtitleLabel)

    // Avatar + başlık bloğu (dikeyde ortalı).
    innerHeader.orientation = .horizontal
    innerHeader.alignment = .centerY
    innerHeader.spacing = 10
    innerHeader.addArrangedSubview(avatarBadge)
    innerHeader.addArrangedSubview(titleBlock)

    // Kapatma butonu sağ üstte kalsın diye header'ı üstten hizala.
    headerRow.orientation = .horizontal
    headerRow.alignment = .top
    headerRow.spacing = 8
    headerRow.addArrangedSubview(innerHeader)
    headerRow.addArrangedSubview(closeButton)

    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.isHidden = true

    stackView.orientation = .vertical
    stackView.alignment = .width
    stackView.spacing = 8
    stackView.translatesAutoresizingMaskIntoConstraints = false

    buttonBar.orientation = .horizontal
    buttonBar.spacing = 8

    listStack.orientation = .vertical
    listStack.distribution = .fill
    listStack.alignment = .width
    listStack.spacing = Self.kRowSpacing
    listStack.isHidden = true

    let content = NSView()
    content.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(effectView)
    effectView.addSubview(stackView)

    stackView.addArrangedSubview(headerRow)
    stackView.addArrangedSubview(spinner)
    stackView.addArrangedSubview(listStack)
    stackView.addArrangedSubview(buttonBar)

    contentView = content

    let width = content.widthAnchor.constraint(equalToConstant: Self.kPanelWidth)
    width.priority = .required
    contentWidthConstraint = width

    NSLayoutConstraint.activate([
      width,
      content.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
      effectView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      effectView.topAnchor.constraint(equalTo: content.topAnchor),
      effectView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      stackView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 16),
      stackView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -16),
      stackView.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 14),
      stackView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -14),
    ])
  }

  func show(atStackOffset yOffset: CGFloat) {
    guard let screen = NSScreen.main else { return }
    applyPanelSize(height: frame.height)
    layoutIfNeeded()
    let vf = screen.visibleFrame
    let w = Self.kPanelWidth
    let h = frame.height
    let x = vf.maxX - w - 14
    let y = vf.maxY - h - 36 - yOffset
    setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    orderFrontRegardless()
  }

  func closePanel() {
    orderOut(nil)
  }

  private var panelKindName: String {
    switch kind {
    case .reconnect: return "reconnect"
    case .files: return "files"
    case .hud: return "hud"
    }
  }

  // MARK: Reconnect

  func updateReconnect(
    _ data: [String: Any],
    handler: @escaping (String, [String: Any]) -> Void
  ) {
    actionHandler = handler
    clearButtons()
    clearList()
    listStack.isHidden = true

    let title = data["title"] as? String ?? "Bağlantı isteği"
    titleLabel.stringValue = title
    subtitleLabel.stringValue = data["subtitle"] as? String ?? ""
    subtitleLabel.isHidden = (data["subtitle"] as? String ?? "").isEmpty

    let phase = data["phase"] as? String ?? "prompt"

    // Sol tarafta gönderen cihazın türüne göre dairesel avatar (kopmada kırmızı).
    let deviceName = (data["fromDeviceName"] as? String ?? title)
    if phase == "disconnected" {
      avatarBadge.setSymbol("wifi.slash")
      avatarBadge.setStyle(disconnected: true)
    } else {
      avatarBadge.setSymbol(Self.deviceSymbol(for: deviceName))
      avatarBadge.setStyle(disconnected: false)
    }
    avatarBadge.isHidden = false

    let deviceId = data["fromDeviceId"] as? String ?? ""
    let createdAt = data["clientCreatedAt"] as? Int ?? 0
    let payload: [String: Any] = [
      "fromDeviceId": deviceId,
      "clientCreatedAt": createdAt,
    ]

    // Yükseklik = üst boşluk(14) + başlık satırı(avatar 38) + ara(8) + içerik + alt boşluk(14)
    switch phase {
    case "connecting":
      spinner.isHidden = false
      spinner.startAnimation(nil)
      buttonBar.isHidden = true
      // 14 + 38 + 8 + 18(spinner) + 14
      applyPanelSize(height: 92)
    case "connected":
      spinner.stopAnimation(nil)
      spinner.isHidden = true
      buttonBar.isHidden = true
      // 14 + 38 + 14 (yalnızca başlık satırı)
      applyPanelSize(height: 80)
    case "disconnected":
      spinner.stopAnimation(nil)
      spinner.isHidden = true
      buttonBar.isHidden = true
      // Başlık + alt başlık (kopma nedeni) sığsın diye biraz daha yüksek.
      applyPanelSize(height: 86)
    default:
      spinner.stopAnimation(nil)
      spinner.isHidden = true
      buttonBar.isHidden = false
      buttonBar.distribution = .fillEqually
      addButton("Reddet", style: .plain, large: true) { [weak self] in
        self?.actionHandler?("reconnect_reject", payload)
      }
      addButton("Onayla", style: .prominent, large: true) { [weak self] in
        self?.actionHandler?("reconnect_approve", payload)
      }
      // 14 + 38 + 8 + 34(buton) + 14
      applyPanelSize(height: 108)
    }
  }

  /// Cihaz adından platforma göre SF Symbol seçer.
  private static func deviceSymbol(for name: String) -> String {
    let n = name.lowercased()
    if n.contains("ipad") { return "ipad" }
    if n.contains("iphone") { return "iphone" }
    if n.contains("macbook") { return "laptopcomputer" }
    if n.contains("imac") || n.contains("mac") { return "desktopcomputer" }
    if n.contains("android") || n.contains("pixel") || n.contains("galaxy") {
      return "candybarphone"
    }
    if n.contains("windows") || n.contains("pc") { return "pc" }
    return "iphone"
  }

  // MARK: Files

  /// Dosya panelini günceller. Satır yapısı (dosya kimliği + aşama + toplu
  /// aksiyon görünürlüğü) değişmediyse SADECE ilerleme çubuklarını yerinde
  /// günceller ve `false` döner (yeniden konumlandırma/yeniden kurma yok).
  /// Yapı değiştiyse satırları baştan kurar ve `true` döner.
  @discardableResult
  func updateFiles(
    _ data: [String: Any],
    handler: @escaping (String, [String: Any]) -> Void
  ) -> Bool {
    actionHandler = handler

    let files = data["items"] as? [[String: Any]] ?? []
    let showBulk = data["showBulkActions"] as? Bool ?? !files.isEmpty
    let showOpen = data["showOpenAction"] as? Bool ?? false
    let shown = Array(files.prefix(8))

    let signature = shown.map { file -> String in
      let id = file["id"] as? String ?? ""
      let phase = file["phase"] as? String ?? "pending"
      let canOpen = file["canOpen"] as? Bool ?? false
      return "\(id):\(phase):\(canOpen)"
    }.joined(separator: "|") + ";bulk=\(showBulk);open=\(showOpen)"

    // Yapı aynı → yalnızca ilerleme çubuklarını güncelle, paneli yeniden kurma.
    if signature == renderedFileSignature && !shown.isEmpty {
      for file in shown {
        let id = file["id"] as? String ?? ""
        guard let bar = fileProgressBars[id] else { continue }
        let phase = file["phase"] as? String ?? "transferring"
        var progress = file["progress"] as? Double ?? 0
        if phase == "completed" { progress = 1 }
        bar.doubleValue = progress
      }
      return false
    }

    // Yapı değişti → satırları baştan kur.
    renderedFileSignature = signature
    spinner.stopAnimation(nil)
    spinner.isHidden = true
    clearButtons()
    clearList()

    titleLabel.stringValue = data["title"] as? String ?? "Dosya isteği"
    subtitleLabel.stringValue = data["subtitle"] as? String ?? ""
    listStack.isHidden = shown.isEmpty

    var listHeight: CGFloat = 0
    for (index, file) in shown.enumerated() {
      let phase = file["phase"] as? String ?? "pending"
      if phase == "pending" {
        let id = file["id"] as? String ?? ""
        let name = file["name"] as? String ?? "Dosya"
        addPendingFileRow(name: name, fileId: id)
      } else {
        addInlineProgressRow(file)
      }
      listHeight += Self.kRowHeight
      if index < shown.count - 1 { listHeight += Self.kRowSpacing }
    }

    buttonBar.isHidden = !(showBulk || showOpen)
    if showBulk {
      buttonBar.distribution = .fill
      addButton("Tümünü reddet", style: .plain) { [weak self] in
        self?.actionHandler?("files_reject_all", [:])
      }
      addSpacer()
      addButton("Tümünü onayla", style: .prominent) { [weak self] in
        self?.actionHandler?("files_accept_all", [:])
      }
    } else if showOpen {
      // Transfer bitti: paneli otomatik kapatmak yerine dosyaları açma seçeneği
      // sun; kullanıcı dilerse sağ üstteki X ile kapatır.
      buttonBar.distribution = .fillEqually
      addButton("Dosyaları aç", style: .prominent) { [weak self] in
        self?.actionHandler?("files_open", [:])
      }
    }

    // Üst boşluk(14) + başlık(20) + altyazı(16) + stack aralıkları(8*2) + alt boşluk(14)
    var height: CGFloat = 14 + 20 + 16 + 8 + 14
    if !shown.isEmpty { height += listHeight + 8 }
    if showBulk || showOpen { height += 34 + 8 }
    applyPanelSize(height: min(height, 540))
    return true
  }

  // MARK: HUD

  func updateHud(
    _ data: [String: Any],
    handler: @escaping (String, [String: Any]) -> Void
  ) {
    actionHandler = handler
    spinner.stopAnimation(nil)
    spinner.isHidden = true
    buttonBar.isHidden = true
    clearButtons()
    clearList()

    titleLabel.stringValue = data["title"] as? String ?? "Aktif transfer"
    subtitleLabel.stringValue = data["subtitle"] as? String ?? ""

    let items = data["items"] as? [[String: Any]] ?? []
    listStack.isHidden = false
    if items.isEmpty {
      addProgressPlaceholder("İndirme başlatılıyor…")
    } else {
      for item in items.prefix(6) {
        addProgressRow(item)
      }
    }

    let rows = max(items.count, 1)
    let height = 96 + CGFloat(rows) * 50
    applyPanelSize(height: min(height, 400))
  }

  // MARK: UI helpers

  private func clearButtons() {
    buttonBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
  }

  private func clearList() {
    listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    fileProgressBars.removeAll()
  }

  private func addSpacer() {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    buttonBar.addArrangedSubview(spacer)
  }

  private enum ButtonStyle { case plain, prominent }

  private func addButton(
    _ title: String,
    style: ButtonStyle,
    large: Bool = false,
    action: @escaping () -> Void
  ) {
    let button = NSButton(title: title, target: nil, action: nil)
    button.translatesAutoresizingMaskIntoConstraints = false
    if large { button.controlSize = .large }
    let height: CGFloat = large ? 34 : 28
    button.heightAnchor.constraint(equalToConstant: height).isActive = true
    let fontSize: CGFloat = large ? 14 : 13

    if style == .prominent {
      // Nonactivating panel'de varsayılan buton (.rounded + bezelColor) accent
      // dolgusunu güvenilir göstermiyor; içi beyaz kalıp pasif görünüyordu.
      // Bu yüzden katman destekli düz (dolu) accent buton çiziyoruz.
      button.isBordered = false
      button.bezelStyle = .regularSquare
      button.wantsLayer = true
      button.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
      button.layer?.cornerRadius = large ? 9 : 7
      button.layer?.masksToBounds = true
      button.contentTintColor = .white
      button.keyEquivalent = "\r"
      button.attributedTitle = NSAttributedString(
        string: title,
        attributes: [
          .foregroundColor: NSColor.white,
          .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        ]
      )
    } else {
      button.bezelStyle = .rounded
      button.attributedTitle = NSAttributedString(
        string: title,
        attributes: [
          .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
        ]
      )
    }
    let handler = ButtonHandler(action: action)
    objc_setAssociatedObject(button, &ButtonHandler.key, handler, .OBJC_ASSOCIATION_RETAIN)
    button.target = handler
    button.action = #selector(ButtonHandler.invoke)
    buttonBar.addArrangedSubview(button)
  }

  /// Onay bekleyen dosya: tek satır → [ad .......... genişler]  [✕] [✓]
  private func addPendingFileRow(name: String, fileId: String) {
    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false

    let label = makeNameLabel(name)

    let reject = makeIconButton("✕")
    wireIconButton(reject) { [weak self] in
      self?.actionHandler?("file_reject", ["fileId": fileId])
    }
    let approve = makeIconButton("✓")
    wireIconButton(approve) { [weak self] in
      self?.actionHandler?("file_accept", ["fileId": fileId])
    }

    row.addSubview(label)
    row.addSubview(reject)
    row.addSubview(approve)

    NSLayoutConstraint.activate([
      approve.trailingAnchor.constraint(equalTo: row.trailingAnchor),
      approve.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      reject.trailingAnchor.constraint(equalTo: approve.leadingAnchor, constant: -8),
      reject.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
      label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      label.trailingAnchor.constraint(lessThanOrEqualTo: reject.leadingAnchor, constant: -10),
    ])
    attachRow(row, height: Self.kRowHeight)
  }

  /// Onaylanmış dosya: aktif → [ad ...] [=======]; tamamlandı → [ad ...] [Aç]
  private func addInlineProgressRow(_ item: [String: Any]) {
    let id = item["id"] as? String ?? ""
    let name = item["name"] as? String ?? "Dosya"
    let phase = item["phase"] as? String ?? "transferring"
    let canOpen = item["canOpen"] as? Bool ?? false

    if phase == "completed" && canOpen && !id.isEmpty {
      addCompletedFileRow(name: name, fileId: id)
      return
    }

    var progress = item["progress"] as? Double ?? 0
    if phase == "completed" { progress = 1 }

    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false

    let label = makeNameLabel(name)
    label.font = .systemFont(ofSize: 12, weight: .medium)

    let bar = NSProgressIndicator()
    bar.isIndeterminate = false
    bar.minValue = 0
    bar.maxValue = 1
    bar.doubleValue = progress
    bar.controlSize = .small
    bar.translatesAutoresizingMaskIntoConstraints = false

    row.addSubview(label)
    row.addSubview(bar)

    NSLayoutConstraint.activate([
      bar.trailingAnchor.constraint(equalTo: row.trailingAnchor),
      bar.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      bar.heightAnchor.constraint(equalToConstant: 6),
      bar.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.5),
      label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
      label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      label.trailingAnchor.constraint(lessThanOrEqualTo: bar.leadingAnchor, constant: -12),
    ])
    if !id.isEmpty { fileProgressBars[id] = bar }
    attachRow(row, height: Self.kRowHeight)
  }

  /// Tamamlanan alınan dosya: [ad ...] [Aç]
  private func addCompletedFileRow(name: String, fileId: String) {
    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false

    let label = makeNameLabel(name)
    label.font = .systemFont(ofSize: 12, weight: .medium)

    let openBtn = NSButton(title: "Aç", target: nil, action: nil)
    openBtn.bezelStyle = .rounded
    openBtn.controlSize = .small
    openBtn.font = .systemFont(ofSize: 12, weight: .medium)
    openBtn.translatesAutoresizingMaskIntoConstraints = false
    openBtn.setContentHuggingPriority(.required, for: .horizontal)
    openBtn.setContentCompressionResistancePriority(.required, for: .horizontal)
    wireIconButton(openBtn) { [weak self] in
      self?.actionHandler?("file_open", ["fileId": fileId])
    }

    row.addSubview(label)
    row.addSubview(openBtn)

    NSLayoutConstraint.activate([
      openBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor),
      openBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
      label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      label.trailingAnchor.constraint(lessThanOrEqualTo: openBtn.leadingAnchor, constant: -10),
    ])
    attachRow(row, height: Self.kRowHeight)
  }

  private func attachRow(_ row: NSView, height: CGFloat) {
    row.translatesAutoresizingMaskIntoConstraints = false
    row.heightAnchor.constraint(equalToConstant: height).isActive = true
    listStack.addArrangedSubview(row)
    row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
  }

  private func makeNameLabel(_ name: String) -> NSTextField {
    let label = NSTextField(labelWithString: name)
    label.lineBreakMode = .byTruncatingMiddle
    label.cell?.truncatesLastVisibleLine = true
    label.font = .systemFont(ofSize: 12)
    label.maximumNumberOfLines = 1
    label.toolTip = name
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return label
  }

  /// Eski stil köşeleri yuvarlatılmış metin butonu (✕ / ✓).
  private func makeIconButton(_ title: String) -> NSButton {
    let button = NSButton(title: title, target: nil, action: nil)
    button.bezelStyle = .roundRect
    button.font = .systemFont(ofSize: 13, weight: .semibold)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 30).isActive = true
    button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    return button
  }

  private func wireIconButton(_ button: NSButton, action: @escaping () -> Void) {
    let handler = ButtonHandler(action: action)
    objc_setAssociatedObject(button, &ButtonHandler.key, handler, .OBJC_ASSOCIATION_RETAIN)
    button.target = handler
    button.action = #selector(ButtonHandler.invoke)
  }

  /// HUD paneli satırı (ad + tam genişlik çubuk + durum metni).
  private func addProgressRow(_ item: [String: Any]) {
    let name = item["name"] as? String ?? "Dosya"
    let progress = item["progress"] as? Double ?? 0
    let status = item["status"] as? String ?? "Alınıyor"

    let label = makeNameLabel(name)
    label.font = .systemFont(ofSize: 12, weight: .medium)

    let statusLabel = NSTextField(labelWithString: status)
    statusLabel.font = .systemFont(ofSize: 11)
    statusLabel.textColor = .secondaryLabelColor

    let bar = NSProgressIndicator()
    bar.isIndeterminate = false
    bar.minValue = 0
    bar.maxValue = 1
    bar.doubleValue = progress
    bar.controlSize = .small
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.heightAnchor.constraint(equalToConstant: 6).isActive = true

    let box = NSStackView(views: [label, bar, statusLabel])
    box.orientation = .vertical
    box.alignment = .width
    box.spacing = 4
    box.distribution = .fill
    attachRow(box, height: 56)
  }

  private func addProgressPlaceholder(_ text: String) {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 12)
    label.textColor = .secondaryLabelColor
    listStack.addArrangedSubview(label)
  }
}

/// Sol üstte gönderen cihazı temsil eden, mavi gradyanlı dairesel avatar.
private final class AvatarBadge: NSView {
  private let gradient = CAGradientLayer()
  private let iconView = NSImageView()

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true
    gradient.colors = [
      NSColor(calibratedRed: 0.33, green: 0.68, blue: 1.0, alpha: 1).cgColor,
      NSColor(calibratedRed: 0.0, green: 0.42, blue: 0.95, alpha: 1).cgColor,
    ]
    gradient.startPoint = CGPoint(x: 0, y: 1)
    gradient.endPoint = CGPoint(x: 1, y: 0)
    layer?.addSublayer(gradient)

    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.contentTintColor = .white
    iconView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(iconView)
    NSLayoutConstraint.activate([
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 20),
      iconView.heightAnchor.constraint(equalToConstant: 20),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setSymbol(_ name: String) {
    let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
      ?? NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
    iconView.image = image?.withSymbolConfiguration(cfg)
  }

  /// Bağlantı koptu durumunda kırmızı, aksi halde mavi gradyan.
  func setStyle(disconnected: Bool) {
    if disconnected {
      gradient.colors = [
        NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.40, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.85, green: 0.16, blue: 0.16, alpha: 1).cgColor,
      ]
    } else {
      gradient.colors = [
        NSColor(calibratedRed: 0.33, green: 0.68, blue: 1.0, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.0, green: 0.42, blue: 0.95, alpha: 1).cgColor,
      ]
    }
  }

  override func layout() {
    super.layout()
    gradient.frame = bounds
    gradient.cornerRadius = bounds.height / 2
  }
}

private final class ButtonHandler: NSObject {
  static var key: UInt8 = 0
  private let action: () -> Void

  init(action: @escaping () -> Void) {
    self.action = action
  }

  @objc func invoke() {
    action()
  }
}
