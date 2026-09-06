import Cocoa

final class UpdateWindowController: NSObject {
    private let checker: ReleaseChecking
    private let currentVersion: String
    private let buildNumber: String
    private let localNotes: String
    private let openURL: (URL) -> Bool
    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var checkButton: NSButton!
    private var downloadButton: NSButton!
    private var releaseButton: NSButton!
    private var progress: NSProgressIndicator!
    private var notesTabs: NSSegmentedControl!
    private var notesView: NSTextView!
    private var latestRelease: PublishedRelease?
    private var isChecking = false

    init(checker: ReleaseChecking = GitHubReleaseChecker(),
         currentVersion: String = AppReleaseInfo.version,
         buildNumber: String = AppReleaseInfo.build,
         localNotes: String = AppReleaseInfo.bundledNotes,
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.checker = checker
        self.currentVersion = currentVersion
        self.buildNumber = buildNumber
        self.localNotes = localNotes
        self.openURL = openURL
        super.init()
    }

    func show(checkForUpdates: Bool = false) {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { centerWindowOnPointerScreen(window) }
        window.makeKeyAndOrderFront(nil)
        if checkForUpdates { checkForUpdate() }
        else { notesTabs.selectedSegment = 0; showNotes() }
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "版本与更新"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = UIStyle.canvas
        window.minSize = NSSize(width: 540, height: 520)
        window.isReleasedWhenClosed = false

        let content = SurfaceView(fill: UIStyle.canvas, radius: 0)
        window.contentView = content
        let icon = UIStyle.symbol("doc.on.clipboard", size: 32, color: .controlAccentColor)
        icon.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let title = UIStyle.label("PasteHistory", size: 21, weight: .semibold)
        let version = UIStyle.label("版本 \(currentVersion) · 构建 \(buildNumber)", size: 12, color: .secondaryLabelColor)
        version.isSelectable = true
        let titleStack = NSStackView(views: [title, version])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 5
        let header = NSStackView(views: [icon, titleStack])
        header.spacing = 12
        header.alignment = .centerY

        statusLabel = UIStyle.label("随时检查新版本", size: 14, weight: .semibold)
        detailLabel = UIStyle.label("点击“检查更新”获取最新正式版本。", size: 12, color: .secondaryLabelColor)
        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byWordWrapping
        let statusText = NSStackView(views: [statusLabel, detailLabel])
        statusText.orientation = .vertical
        statusText.alignment = .leading
        statusText.spacing = 6
        statusText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.widthAnchor.constraint(equalTo: statusText.widthAnchor).isActive = true

        progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        checkButton = button("检查更新", #selector(checkForUpdate))
        checkButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        checkButton.imagePosition = .imageLeading
        let card = SurfaceView(border: UIStyle.border)
        for view in [statusText, progress!, checkButton!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
        }
        NSLayoutConstraint.activate([
            statusText.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            statusText.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            statusText.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            statusText.trailingAnchor.constraint(equalTo: progress.leadingAnchor, constant: -12),
            progress.trailingAnchor.constraint(equalTo: checkButton.leadingAnchor, constant: -8),
            progress.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            progress.heightAnchor.constraint(equalToConstant: 16),
            checkButton.widthAnchor.constraint(equalToConstant: 108),
            checkButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            checkButton.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])

        notesTabs = NSSegmentedControl(labels: ["本地版本记录", "最新发布说明"],
                                       trackingMode: .selectOne, target: self, action: #selector(showNotes))
        notesTabs.selectedSegment = 0
        notesTabs.setEnabled(false, forSegment: 1)
        notesTabs.setAccessibilityLabel("版本记录来源")

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        notesView = NSTextView()
        notesView.isEditable = false
        notesView.isSelectable = true
        notesView.isVerticallyResizable = true
        notesView.isHorizontallyResizable = false
        notesView.autoresizingMask = [.width]
        notesView.textContainer?.widthTracksTextView = true
        notesView.textContainerInset = NSSize(width: 16, height: 14)
        notesView.backgroundColor = UIStyle.surface
        notesView.setAccessibilityLabel("版本更新记录")
        scroll.documentView = notesView

        let privacy = UIStyle.label("仅手动检查时连接 GitHub；不会上传剪贴板或片段内容。", size: 11, color: .secondaryLabelColor)
        privacy.maximumNumberOfLines = 0
        privacy.lineBreakMode = .byWordWrapping
        let allReleases = button("全部发布 ↗", #selector(openAllReleases))
        releaseButton = button("发布页面 ↗", #selector(openRelease))
        releaseButton.isHidden = true
        downloadButton = button("下载新版…", #selector(downloadRelease))
        downloadButton.contentTintColor = .controlAccentColor
        downloadButton.isHidden = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let actions = NSStackView(views: [allReleases, spacer, releaseButton, downloadButton])
        actions.spacing = 8

        let stack = NSStackView(views: [header, card, notesTabs, scroll, privacy, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            privacy.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        showNotes()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    @objc private func checkForUpdate() {
        guard !isChecking else { return }
        guard let installed = AppVersion(currentVersion) else {
            statusLabel.stringValue = "无法检查更新"
            detailLabel.stringValue = UpdateCheckError.invalidVersion.localizedDescription
            return
        }
        isChecking = true
        latestRelease = nil
        checkButton.isEnabled = false
        downloadButton.isHidden = true
        releaseButton.isHidden = true
        notesTabs.setEnabled(false, forSegment: 1)
        notesTabs.selectedSegment = 0
        showNotes()
        statusLabel.stringValue = "正在检查更新…"
        detailLabel.stringValue = "正在获取 GitHub 上的最新正式版本。"
        progress.startAnimation(nil)
        checker.fetchLatest { [weak self] result in
            guard let self else { return }
            self.isChecking = false
            self.progress.stopAnimation(nil)
            self.checkButton.isEnabled = true
            self.checkButton.title = "重新检查"
            switch result {
            case .success(let release):
                guard let latest = release.version else { return }
                self.latestRelease = release
                self.notesTabs.setEnabled(true, forSegment: 1)
                self.releaseButton.isHidden = false
                if latest > installed {
                    self.statusLabel.stringValue = "发现新版本 \(latest)"
                    self.detailLabel.stringValue = release.downloadURL == nil
                        ? "当前为 \(installed)。请前往发布页面查看安装包。"
                        : "当前为 \(installed)。下载后退出应用，将新版拖入“应用程序”替换。"
                    self.downloadButton.isHidden = release.downloadURL == nil
                    self.notesTabs.selectedSegment = 1
                } else if latest == installed {
                    self.statusLabel.stringValue = "已是最新版本"
                    self.detailLabel.stringValue = "当前版本 \(installed) 与最新正式版本一致。"
                } else {
                    self.statusLabel.stringValue = "当前版本领先于公开发布"
                    self.detailLabel.stringValue = "当前为 \(installed)，最新公开版本为 \(latest)，无需降级。"
                }
                self.showNotes()
            case .failure(let error):
                self.statusLabel.stringValue = "检查更新失败"
                self.detailLabel.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func showNotes() {
        let text = notesTabs.selectedSegment == 1 ? (latestRelease?.notes ?? "") : localNotes
        let styled = NSMutableAttributedString()
        for line in text.components(separatedBy: .newlines) {
            let heading = line.hasPrefix("#")
            let content = heading ? String(line.drop(while: { $0 == "#" || $0 == " " }))
                : (line.hasPrefix("- ") ? "• " + line.dropFirst(2) : line)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = heading ? 7 : 3
            styled.append(NSAttributedString(string: content + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: heading ? 14 : 12, weight: heading ? .semibold : .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]))
        }
        notesView.textStorage?.setAttributedString(styled)
        if let scroll = notesView.enclosingScrollView {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    @objc private func openAllReleases() { open(AppReleaseInfo.releasesURL) }
    @objc private func openRelease() { if let url = latestRelease?.htmlURL { open(url) } }
    @objc private func downloadRelease() { if let url = latestRelease?.downloadURL { open(url) } }

    private func open(_ url: URL) {
        if !openURL(url) {
            let alert = NSAlert()
            alert.messageText = "无法打开浏览器"
            alert.informativeText = "请复制此链接到浏览器打开：\n\(url.absoluteString)"
            alert.addButton(withTitle: "好")
            alert.beginSheetModal(for: window)
        }
    }
}
