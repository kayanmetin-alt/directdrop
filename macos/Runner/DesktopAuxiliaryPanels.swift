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
      panel.updateFiles(files) { [weak self] action, payload in
        self?.sendAction(action, payload: payload)
      }
      panel.show(atStackOffset: yOffset)
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
}

// MARK: - Panel

private final class AuxiliaryPanel: NSPanel {
  enum Kind { case reconnect, files, hud }

  private let kind: Kind
  private var actionHandler: ((String, [String: Any]) -> Void)?

  private let effectView = NSVisualEffectView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let subtitleLabel = NSTextField(labelWithString: "")
  private let stackView = NSStackView()
  private let buttonBar = NSStackView()
  private let listStack = NSStackView()
  private let spinner = NSProgressIndicator()

  private static let kPanelWidth: CGFloat = 420
  private static let kFileRowHeight: CGFloat = 34
  private static let kTrailingActionsWidth: CGFloat = 132
  private static let kIconButtonSize: CGFloat = 28
  private static let kNameDisplayMaxLen = 36

  private var contentWidthConstraint: NSLayoutConstraint?

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

    subtitleLabel.font = .systemFont(ofSize: 12)
    subtitleLabel.textColor = .secondaryLabelColor
    subtitleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.maximumNumberOfLines = 2

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

    listStack.distribution = .fill
    listStack.alignment = .width
    listStack.spacing = 6
    listStack.isHidden = true

    let content = NSView()
    content.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(effectView)
    effectView.addSubview(stackView)

    stackView.addArrangedSubview(titleLabel)
    stackView.addArrangedSubview(subtitleLabel)
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

  // MARK: Reconnect

  func updateReconnect(
    _ data: [String: Any],
    handler: @escaping (String, [String: Any]) -> Void
  ) {
    actionHandler = handler
    clearButtons()
    clearList()
    listStack.isHidden = true

    titleLabel.stringValue = data["title"] as? String ?? "Bağlantı isteği"
    subtitleLabel.stringValue = data["subtitle"] as? String ?? ""

    let phase = data["phase"] as? String ?? "prompt"
    let deviceId = data["fromDeviceId"] as? String ?? ""
    let createdAt = data["clientCreatedAt"] as? Int ?? 0
    let payload: [String: Any] = [
      "fromDeviceId": deviceId,
      "clientCreatedAt": createdAt,
    ]

    switch phase {
    case "connecting":
      spinner.isHidden = false
      spinner.startAnimation(nil)
      buttonBar.isHidden = true
      applyPanelSize(height: 116)
    case "connected":
      spinner.stopAnimation(nil)
      spinner.isHidden = true
      buttonBar.isHidden = true
      titleLabel.stringValue = "✓ " + (data["title"] as? String ?? "Bağlandı")
      applyPanelSize(height: 100)
    default:
      spinner.stopAnimation(nil)
      spinner.isHidden = true
      buttonBar.isHidden = false
      addButton("Reddet", style: .plain) { [weak self] in
        self?.actionHandler?("reconnect_reject", payload)
      }
      addSpacer()
      addButton("Onayla", style: .prominent) { [weak self] in
        self?.actionHandler?("reconnect_approve", payload)
      }
      applyPanelSize(height: 132)
    }
  }

  // MARK: Files

  func updateFiles(
    _ data: [String: Any],
    handler: @escaping (String, [String: Any]) -> Void
  ) {
    actionHandler = handler
    spinner.stopAnimation(nil)
    spinner.isHidden = true
    clearButtons()
    clearList()

    titleLabel.stringValue = data["title"] as? String ?? "Dosya isteği"
    subtitleLabel.stringValue = data["subtitle"] as? String ?? ""

    let files = data["items"] as? [[String: Any]] ?? []
    let showBulk = data["showBulkActions"] as? Bool ?? !files.isEmpty
    listStack.isHidden = files.isEmpty

    for file in files.prefix(8) {
      let phase = file["phase"] as? String ?? "pending"
      if phase == "pending" {
        let id = file["id"] as? String ?? ""
        let name = file["name"] as? String ?? "Dosya"
        addPendingFileRow(name: name, fileId: id)
      } else {
        addInlineProgressRow(file)
      }
    }

    buttonBar.isHidden = !showBulk
    if showBulk {
      addButton("Tümünü reddet", style: .plain) { [weak self] in
        self?.actionHandler?("files_reject_all", [:])
      }
      addSpacer()
      addButton("Tümünü onayla", style: .prominent) { [weak self] in
        self?.actionHandler?("files_accept_all", [:])
      }
    }

    var height = showBulk ? 132.0 : 88.0
    height += CGFloat(min(files.count, 8)) * ( Self.kFileRowHeight + 6)
    applyPanelSize(height: min(height, 520))
  }

  // kFileRowHeight etc. defined above init

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
    action: @escaping () -> Void
  ) {
    let button = NSButton(title: title, target: nil, action: nil)
    button.bezelStyle = style == .prominent ? .rounded : .roundRect
    if style == .prominent {
      button.keyEquivalent = "\r"
    }
    let handler = ButtonHandler(action: action)
    objc_setAssociatedObject(button, &ButtonHandler.key, handler, .OBJC_ASSOCIATION_RETAIN)
    button.target = handler
    button.action = #selector(ButtonHandler.invoke)
    buttonBar.addArrangedSubview(button)
  }

  private func addPendingFileRow(name: String, fileId: String) {
    let row = makeFileRowStack()

    let label = makeNameLabel(truncateDisplayName(name))
    let reject = makeIconButton("✕")
    let approve = makeIconButton("✓")

    wireIconButton(reject, action: { [weak self] in
      self?.actionHandler?("file_reject", ["fileId": fileId])
    })
    wireIconButton(approve, action: { [weak self] in
      self?.actionHandler?("file_accept", ["fileId": fileId])
    })

    let actions = NSStackView(views: [reject, approve])
    actions.orientation = .horizontal
    actions.spacing = 6
    actions.alignment = .centerY
    actions.setContentHuggingPriority(.required, for: .horizontal)
    actions.setContentCompressionResistancePriority(.required, for: .horizontal)
    actions.translatesAutoresizingMaskIntoConstraints = false
    actions.widthAnchor.constraint(equalToConstant: Self.kTrailingActionsWidth).isActive = true

    row.addArrangedSubview(label)
    row.addArrangedSubview(actions)
    attachFileRow(row)
  }

  private func addInlineProgressRow(_ item: [String: Any]) {
    let name = item["name"] as? String ?? "Dosya"
    let progress = item["progress"] as? Double ?? 0
    let phase = item["phase"] as? String ?? "transferring"

    let row = makeFileRowStack()
    let label = makeNameLabel(truncateDisplayName(name))

    let barContainer = NSView()
    barContainer.translatesAutoresizingMaskIntoConstraints = false
    barContainer.widthAnchor.constraint(equalToConstant: Self.kTrailingActionsWidth).isActive = true

    let bar = NSProgressIndicator()
    bar.isIndeterminate = false
    bar.minValue = 0
    bar.maxValue = 1
    bar.doubleValue = progress
    bar.controlSize = .small
    bar.translatesAutoresizingMaskIntoConstraints = false

    barContainer.addSubview(bar)
    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: barContainer.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: barContainer.trailingAnchor),
      bar.centerYAnchor.constraint(equalTo: barContainer.centerYAnchor),
    ])

    if phase == "completed" {
      bar.doubleValue = 1
    }

    row.addArrangedSubview(label)
    row.addArrangedSubview(barContainer)
    attachFileRow(row)
  }

  private func makeFileRowStack() -> NSStackView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    row.distribution = .fill
    row.translatesAutoresizingMaskIntoConstraints = false
    row.heightAnchor.constraint(equalToConstant: Self.kFileRowHeight).isActive = true
    return row
  }

  private func attachFileRow(_ row: NSStackView) {
    listStack.addArrangedSubview(row)
    row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
  }

  private func truncateDisplayName(_ name: String) -> String {
    if name.count <= Self.kNameDisplayMaxLen { return name }
    let ext: String
    if let dot = name.lastIndex(of: ".") {
      ext = String(name[dot...])
    } else {
      ext = ""
    }
    let baseMax = Self.kNameDisplayMaxLen - ext.count - 1
    if baseMax < 8 {
      return String(name.prefix(Self.kNameDisplayMaxLen - 1)) + "…"
    }
    return String(name.prefix(baseMax)) + "…" + ext
  }

  private func makeNameLabel(_ name: String) -> NSTextField {
    let label = NSTextField(labelWithString: name)
    label.lineBreakMode = .byTruncatingMiddle
    label.font = .systemFont(ofSize: 12)
    label.maximumNumberOfLines = 1
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return label
  }

  private func wireIconButton(_ button: NSButton, action: @escaping () -> Void) {
    let handler = ButtonHandler(action: action)
    objc_setAssociatedObject(button, &ButtonHandler.key, handler, .OBJC_ASSOCIATION_RETAIN)
    button.target = handler
    button.action = #selector(ButtonHandler.invoke)
  }

  private func addFileRow(name: String, fileId: String) {
    addPendingFileRow(name: name, fileId: fileId)
  }

  private func makeIconButton(_ title: String) -> NSButton {
    let button = NSButton(title: title, target: nil, action: nil)
    button.bezelStyle = .roundRect
    button.font = .systemFont(ofSize: 13, weight: .semibold)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: Self.kIconButtonSize).isActive = true
    button.heightAnchor.constraint(equalToConstant: Self.kIconButtonSize).isActive = true
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    return button
  }

  private func addProgressRow(_ item: [String: Any]) {
    let name = item["name"] as? String ?? "Dosya"
    let progress = item["progress"] as? Double ?? 0
    let status = item["status"] as? String ?? "Alınıyor"

    let box = NSStackView()
    box.orientation = .vertical
    box.alignment = .leading
    box.spacing = 3
    box.translatesAutoresizingMaskIntoConstraints = false

    let label = NSTextField(labelWithString: name)
    label.lineBreakMode = .byTruncatingMiddle
    label.font = .systemFont(ofSize: 12, weight: .medium)

    let bar = NSProgressIndicator()
    bar.isIndeterminate = false
    bar.minValue = 0
    bar.maxValue = 1
    bar.doubleValue = progress
    bar.controlSize = .small
    bar.translatesAutoresizingMaskIntoConstraints = false

    let statusLabel = NSTextField(labelWithString: status)
    statusLabel.font = .systemFont(ofSize: 11)
    statusLabel.textColor = .secondaryLabelColor

    box.addArrangedSubview(label)
    box.addArrangedSubview(bar)
    box.addArrangedSubview(statusLabel)
    listStack.addArrangedSubview(box)
    box.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
    bar.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
  }

  private func addProgressPlaceholder(_ text: String) {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 12)
    label.textColor = .secondaryLabelColor
    listStack.addArrangedSubview(label)
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
