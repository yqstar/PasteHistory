import Cocoa
import Carbon.HIToolbox
import Darwin

// Runs only against temporary stores; it never starts clipboard monitoring or auto-paste.
private var failures = 0
private let scriptedKeyTimestamp: TimeInterval = 0.12345
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { print("PASS: \(message)") }
    else { failures += 1; print("FAIL: \(message)") }
}

private func pump(_ duration: TimeInterval = 0.2) {
    let end = Date().addingTimeInterval(duration)
    while Date() < end {
        if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                      inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    }
}

private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}

private func testPaletteCellReuse() {
    let cell = PaletteCellView(frame: .zero)
    func labels() -> [String] {
        descendants(cell).compactMap { $0 as? NSTextField }
            .filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue)
    }
    var row = PaletteRow(id: UUID(), icon: nil, title: "原片段", subtitle: "原摘要",
                         badge: "代码", badgeColor: .systemIndigo,
                         accessoryBadge: "快捷键冲突", accessoryBadgeColor: .systemRed)
    cell.apply(row)
    check(labels().contains("代码") && labels().contains("快捷键冲突"), "列表行应显示类型与快捷键状态标签")
    row.title = "更新片段"
    row.subtitle = "更新摘要"
    cell.apply(row)
    check(labels().contains("更新片段") && labels().contains("更新摘要") && !labels().contains("原片段"),
          "复用相同标签时，标题和摘要仍应更新")
    row.badge = "文本"
    row.badgeColor = .systemBlue
    row.accessoryBadge = nil
    row.subtitle = ""
    cell.apply(row)
    check(labels().contains("文本") && !labels().contains("代码") && !labels().contains("快捷键冲突")
          && !labels().contains("更新摘要"), "复用列表行时应移除过期标签并隐藏空摘要")
    row.badge = nil
    cell.apply(row)
    check(descendants(cell).allSatisfy { !($0 is PillView) }, "无标签的行不应残留上一行的标签视图")
}

private func buttons(_ window: NSWindow, title: String) -> [NSButton] {
    descendants(window.contentView!).compactMap { $0 as? NSButton }
        .filter { $0.title == title && !$0.isHiddenOrHasHiddenAncestor }
}

private func click(_ window: NSWindow, _ title: String) {
    guard let button = buttons(window, title: title).first else {
        check(false, "找不到按钮：\(title)")
        return
    }
    button.performClick(nil)
    pump()
}

private func respond(_ window: NSWindow, _ title: String) {
    pump()
    guard let sheet = window.attachedSheet else {
        check(false, "应显示确认或错误提示：\(title)")
        return
    }
    click(sheet, title)
}

private func snapshot(_ window: NSWindow, _ name: String) throws {
    guard CommandLine.arguments.count > 1, let view = window.contentView else { return }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png")
    try bitmap.representation(using: .png, properties: [:])?.write(to: url)
}

private final class StubReleaseChecker: ReleaseChecking {
    var calls = 0
    var completion: ((Result<PublishedRelease, Error>) -> Void)?
    func fetchLatest(completion: @escaping (Result<PublishedRelease, Error>) -> Void) {
        calls += 1
        self.completion = completion
    }
}

private func testUpdateWindow() throws {
    let checker = StubReleaseChecker()
    var openedURLs: [URL] = []
    let notesURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("CHANGELOG.md")
    let controller = UpdateWindowController(checker: checker, currentVersion: "1.0.4", buildNumber: "12",
                                            localNotes: try String(contentsOf: notesURL, encoding: .utf8),
                                            openURL: { openedURLs.append($0); return true })
    controller.show()
    pump()
    let window = NSApp.windows.first { $0.title == "版本与更新" }!
    let views = descendants(window.contentView!)
    let text = views.compactMap { $0 as? NSTextView }.first!
    let tabs = views.compactMap { $0 as? NSSegmentedControl }.first!
    func contains(_ title: String) -> Bool {
        descendants(window.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == title }
    }
    check(checker.calls == 0 && text.string.contains("1.0.4"), "打开本地版本记录不发起网络请求")
    check(text.visibleRect.minX == 0 && text.visibleRect.minY == 0, "版本记录初次显示时应从左上角开始，不裁切文本")
    try snapshot(window, "updates-local-light")
    controller.show(checkForUpdates: true)
    controller.show(checkForUpdates: true)
    check(checker.calls == 1 && buttons(window, title: "检查更新").first?.isEnabled == false,
          "检查过程中禁用按钮，重复操作不会并发请求")
    let payload = ###"{"tag_name":"v1.10.0","html_url":"https://github.com/yqstar/PasteHistory/releases/tag/v1.10.0","body":"## 本次更新\n- 改善版本管理\n- 修复问题","draft":false,"prerelease":false,"assets":[{"name":"PasteHistory-1.10.0-universal.dmg","state":"uploaded","size":2048,"browser_download_url":"https://github.com/yqstar/PasteHistory/releases/download/v1.10.0/PasteHistory-1.10.0-universal.dmg"}]}"###
    func release(_ version: String) throws -> PublishedRelease {
        try JSONDecoder().decode(PublishedRelease.self, from: Data(payload.replacingOccurrences(of: "1.10.0", with: version).utf8))
    }
    checker.completion?(.success(try release("1.10.0")))
    pump()
    check(contains("发现新版本 1.10.0") && tabs.selectedSegment == 1 && text.string.contains("本次更新"),
          "新版显示正确版本号并自动展示发布说明")
    click(window, "下载新版…")
    check(openedURLs.last?.lastPathComponent == "PasteHistory-1.10.0-universal.dmg", "下载按钮打开对应的 Universal DMG")
    click(window, "发布页面 ↗")
    check(openedURLs.last?.path.hasSuffix("/tag/v1.10.0") == true, "发布页面打开当前检查到的版本")
    try snapshot(window, "updates-available-light")
    window.appearance = NSAppearance(named: .darkAqua)
    window.setContentSize(NSSize(width: 540, height: 500))
    pump()
    try snapshot(window, "updates-available-dark-small")
    let visibleButtons = descendants(window.contentView!).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
    check(visibleButtons.allSatisfy { window.contentView!.bounds.contains($0.convert($0.bounds, to: window.contentView!)) },
          "最小窗口下更新操作按钮均在可视范围内")
    check(text.frame.width <= text.enclosingScrollView!.contentSize.width + 1 && text.visibleRect.minX == 0,
          "缩小窗口后版本说明仍按可视宽度换行，不发生横向裁切")
    controller.show()
    check(tabs.selectedSegment == 0 && text.string.contains("1.0.3"), "版本记录入口始终可以回到本地历史")

    for (version, expected) in [("1.0.4", "已是最新版本"), ("1.0.3", "当前版本领先于公开发布")] {
        controller.show(checkForUpdates: true)
        checker.completion?(.success(try release(version)))
        check(contains(expected) && buttons(window, title: "下载新版…").isEmpty, "\(expected)时不提供降级下载")
    }
    controller.show(checkForUpdates: true)
    checker.completion?(.failure(UpdateCheckError.network))
    pump()
    check(contains("检查更新失败") && buttons(window, title: "重新检查").first?.isEnabled == true,
          "网络失败后可重试，且清除过期下载入口")
    try snapshot(window, "updates-network-error-dark")
    window.performClose(nil)
    controller.show(checkForUpdates: true)
    check(window.isVisible && checker.calls == 5, "关闭后可重新打开并检查更新")
    checker.completion?(.failure(UpdateCheckError.rateLimited))
    window.performClose(nil)
}

private func testClipboardAndThumbnails(in directory: URL, defaults: UserDefaults) throws {
    let history = HistoryStore(baseDir: directory.appendingPathComponent("clipboard"), defaults: defaults)
    let pasteboard = NSPasteboard.withUniqueName()
    let monitor = ClipboardMonitor(store: history, pasteboard: pasteboard)
    defer { monitor.stop(); history.flush(); pasteboard.releaseGlobally() }
    let text = ClipItem(id: UUID(), kind: .text, text: "restored text", imageFile: nil, date: Date())
    check(monitor.restore(text) && pasteboard.string(forType: .string) == text.text, "文本恢复使用指定剪贴板")
    let paths = [directory.appendingPathComponent("one.txt").path, directory.appendingPathComponent("two.txt").path]
    let files = ClipItem(id: UUID(), kind: .file, text: paths.joined(separator: "\n"), imageFile: nil, date: Date())
    check(monitor.restore(files), "多个文件路径可以恢复")
    let restoredURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    check(restoredURLs?.map(\.path) == paths, "文件恢复保留路径及顺序")

    let sample = NSImage(size: NSSize(width: 400, height: 200), flipped: false) { rect in
        NSColor.systemBlue.setFill()
        rect.fill()
        return true
    }
    let imageURL = history.imageURL("sample.png")
    let png = NSBitmapImageRep(data: sample.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try png.write(to: imageURL)
    let thumb = loadImageThumbnail(at: imageURL, maxSize: 48)
    check(thumb?.size == NSSize(width: 48, height: 24), "图片缩略图限制尺寸并保留宽高比")
    let image = ClipItem(id: UUID(), kind: .image, text: nil, imageFile: "sample.png", date: Date())
    check(monitor.restore(image) && pasteboard.canReadObject(forClasses: [NSImage.self], options: nil), "图片仍可恢复到剪贴板")
    monitor.writeText("self-written snippet")
    let missing = ClipItem(id: UUID(), kind: .image, text: nil, imageFile: "missing.png", date: Date())
    check(!monitor.restore(missing) && pasteboard.string(forType: .string) == "self-written snippet", "缺失图片不会清空已有剪贴板内容")
    monitor.start()
    pump(1.1)
    check(history.items.isEmpty, "应用自身写入不产生历史记录")
    pasteboard.clearContents()
    pasteboard.setString("externally copied text", forType: .string)
    pump(1.1)
    check(history.items.first?.text == "externally copied text", "简化轮询后仍会捕获外部复制")
    pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
    pasteboard.setString("synthetic concealed text", forType: .string)
    pump(0.4)
    check(history.items.count == 1, "隐藏类型的剪贴板内容仍会跳过")
    monitor.stop()

    history.add(image)
    history.add(ClipItem(id: UUID(), kind: .text, text: String(repeating: "a", count: 500) + "TAIL_MARKER", imageFile: nil, date: Date()))
    let controller = HistoryWindowController(store: history, monitor: monitor)
    controller.show()
    pump()
    let window = NSApp.windows.first { window in
        descendants(window.contentView!).contains { ($0 as? NSTextField)?.placeholderString == "搜索粘贴历史…" }
    }!
    try snapshot(window, "history-thumbnails")
    let search = descendants(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
    window.makeFirstResponder(search)
    (window.firstResponder as? NSTextView)?.insertText("TAIL_MARKER", replacementRange: NSRange(location: NSNotFound, length: 0))
    pump()
    let table = descendants(window.contentView!).compactMap { $0 as? NSTableView }.first!
    check(table.numberOfRows == 1, "历史选择器能搜索正文第 400 字之后的内容")
    window.performClose(nil)
}

private func runTests() throws {
    testPaletteCellReuse()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteHistoryUI-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "PasteHistoryUITests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let history = HistoryStore(baseDir: directory, defaults: defaults)
    let store = SnippetStore(baseDir: directory)
    let monitor = ClipboardMonitor(store: history)
    let editor = SnippetEditorWindowController(store: store)
    let picker = SnippetPickerWindowController(store: store, monitor: monitor)
    picker.onCreate = { editor.showNew() }
    picker.onEdit = { editor.showEdit($0) }
    picker.show()
    pump()
    let pickerWindow = NSApp.windows.first { window in
        descendants(window.contentView!).contains {
            ($0 as? NSTextField)?.placeholderString == "搜索代码片段…"
        }
    }!
    let createButtons = buttons(pickerWindow, title: "新建片段")
    check(createButtons.count == 2, "空片段列表显示顶部和中央新建按钮")
    try snapshot(pickerWindow, "snippet-empty")
    pickerWindow.setContentSize(NSSize(width: 440, height: 320))
    pump()
    try snapshot(pickerWindow, "snippet-empty-small")
    createButtons.first?.performClick(nil)
    pump()
    let window = NSApp.windows.first { $0.title == "新建片段" }!
    let title = descendants(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
    let body = descendants(window.contentView!).compactMap { $0 as? NSTextView }.first { !$0.isFieldEditor }!
    check(window.isVisible && !editor.hasUnsavedChanges, "空态按钮打开空白编辑器")
    window.performClose(nil)
    pump()
    check(!window.isVisible && window.attachedSheet == nil, "未修改的空白草稿可直接关闭")

    picker.show()
    pump()
    let newEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                   timestamp: scriptedKeyTimestamp,
                                   windowNumber: pickerWindow.windowNumber, context: nil,
                                   characters: "n", charactersIgnoringModifiers: "n",
                                   isARepeat: false, keyCode: UInt16(kVK_ANSI_N))!
    NSApp.postEvent(newEvent, atStart: false)
    pump()
    check(window.isVisible && !pickerWindow.isVisible, "空列表未选中行时，⌘N 仍可新建")
    window.makeFirstResponder(title)
    (window.firstResponder as? NSTextView)?.insertText("测试标题", replacementRange: NSRange(location: NSNotFound, length: 0))
    check(editor.hasUnsavedChanges, "标题正在输入时即可识别未保存修改")
    body.string = "first saved body"
    window.performClose(nil)
    pump()
    check(window.attachedSheet.map { buttons($0, title: "保存").count == 1 && buttons($0, title: "放弃").count == 1 && buttons($0, title: "取消").count == 1 } ?? false,
          "关闭修改后的草稿提供保存、放弃和取消")
    if let sheet = window.attachedSheet { try snapshot(sheet, "snippet-unsaved") }
    respond(window, "取消")
    check(window.isVisible && body.string == "first saved body", "取消关闭保留草稿")
    window.performClose(nil)
    respond(window, "保存")
    check(!window.isVisible && store.items.first?.content == "first saved body", "确认保存后写入片段并关闭")
    check(SnippetStore(baseDir: directory).items == store.items, "新建片段已持久化到磁盘")

    let saved = store.items.first!
    editor.showEdit(saved)
    body.string = "modified draft"
    editor.showEdit(saved)
    check(body.string == "modified draft" && window.attachedSheet == nil, "重新打开同一片段保留当前修改")
    editor.showNew()
    respond(window, "取消")
    check(body.string == "modified draft", "取消切换保留原编辑内容")
    editor.showNew()
    respond(window, "放弃")
    check(body.string.isEmpty && title.stringValue.isEmpty && !editor.hasUnsavedChanges, "放弃修改后切换到空白新建窗口")

    editor.showNew(content: "captured history body")
    check(editor.hasUnsavedChanges, "从历史带入的正文尚未保存时也受保护")
    editor.showEdit(saved)
    respond(window, "保存")
    check(store.items.contains { $0.content == "captured history body" }, "切换前保存历史带入内容")
    check(body.string == saved.content && !editor.hasUnsavedChanges, "保存成功后打开目标片段")

    editor.showNew()
    title.stringValue = "只有标题"
    editor.showEdit(saved)
    respond(window, "保存")
    check(window.isVisible && title.stringValue == "只有标题" && body.string.isEmpty,
          "保存空正文失败时取消切换并保留草稿")
    respond(window, "好")
    click(window, "取消")
    respond(window, "放弃")

    editor.showNew(content: saved.content)
    title.stringValue = "重复正文的新标题"
    click(window, "保存")
    check(window.isVisible && body.string == saved.content && title.stringValue == "重复正文的新标题",
          "重复正文不覆盖当前编辑内容")
    respond(window, "好")
    click(window, "取消")
    respond(window, "放弃")

    editor.showEdit(saved)
    body.string = "recovered removed draft"
    try store.delete(id: saved.id)
    click(window, "保存")
    check(window.isVisible && body.string == "recovered removed draft", "原片段被移除后保存失败仍保留草稿")
    respond(window, "好")
    click(window, "保存")
    check(!window.isVisible && store.items.contains { $0.content == "recovered removed draft" },
          "再次保存可将失去原片段的草稿另存为新片段")

    editor.showNew(content: "disk failure draft")
    let db = directory.appendingPathComponent("snippets.json")
    let heldDB = directory.appendingPathComponent("held-snippets.json")
    try FileManager.default.moveItem(at: db, to: heldDB)
    try FileManager.default.createDirectory(at: db, withIntermediateDirectories: false)
    click(window, "保存")
    check(window.isVisible && body.string == "disk failure draft" && editor.hasUnsavedChanges,
          "磁盘写入失败时保留编辑窗口和正文")
    respond(window, "好")
    try FileManager.default.removeItem(at: db)
    try FileManager.default.moveItem(at: heldDB, to: db)
    click(window, "取消")
    respond(window, "放弃")

    editor.showNew(content: "hidden editor draft")
    window.orderOut(nil)
    check(editor.hasUnsavedChanges, "窗口暂时隐藏后未保存内容仍受保护")
    var allowedToQuit: Bool?
    editor.confirmDiscardingChanges { allowedToQuit = $0 }
    respond(window, "取消")
    check(allowedToQuit == false && body.string == "hidden editor draft", "取消退出会重新显示并保留隐藏草稿")
    editor.confirmDiscardingChanges { allowedToQuit = $0 }
    respond(window, "保存")
    check(allowedToQuit == true && !editor.hasUnsavedChanges && store.items.contains { $0.content == "hidden editor draft" },
          "退出前保存草稿并清除未保存状态")
    window.performClose(nil)

    pickerWindow.setContentSize(NSSize(width: 600, height: 480))
    picker.show()
    pump()
    check(buttons(pickerWindow, title: "新建片段").count == 1, "已有片段时仅显示顶部新建按钮")
    try snapshot(pickerWindow, "snippet-populated")
    click(pickerWindow, "新建片段")
    check(window.isVisible && body.string.isEmpty, "顶部按钮可直接新建片段")
    window.performClose(nil)
    picker.show()
    pump()
    let search = descendants(pickerWindow.contentView!).compactMap { $0 as? NSTextField }
        .first { $0.placeholderString == "搜索代码片段…" }!
    pickerWindow.makeFirstResponder(search)
    (pickerWindow.firstResponder as? NSTextView)?.insertText("UNMATCHED_QUERY", replacementRange: NSRange(location: NSNotFound, length: 0))
    pump()
    check(buttons(pickerWindow, title: "新建片段").count == 2, "搜索无结果时也提供中央创建入口")
    picker.hide()
    try testClipboardAndThumbnails(in: directory, defaults: defaults)

    let settings = SettingsWindowController()
    settings.historyStore = history
    settings.snippetStore = store
    settings.show()
    pump()
    let settingsWindow = NSApp.windows.first { $0.title == "设置" }!
    let recorders = descendants(settingsWindow.contentView!).compactMap { $0 as? HotKeyRecorderButton }
    recorders[0].performClick(nil)
    recorders[1].performClick(nil)
    check(recorders[0].title != "按下组合键…" && recorders[1].title == "按下组合键…", "快捷键录制按钮互斥，不遗留旧监听")
    settingsWindow.performClose(nil)
    pump()
    check(recorders.allSatisfy { $0.title != "按下组合键…" }, "关闭设置会停止快捷键录制")
    try testUpdateWindow()
}

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Real keyboard/mouse input must not edit synthetic drafts while the UI test owns focus.
let inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged,
                                                              .leftMouseDown, .leftMouseUp,
                                                              .rightMouseDown, .rightMouseUp]) { event in
    event.type == .keyDown && event.timestamp == scriptedKeyTimestamp ? event : nil
}
DispatchQueue.main.async {
    do {
        if CommandLine.arguments.contains("--updates-only") { try testUpdateWindow() }
        else { try runTests() }
    }
    catch { failures += 1; print("FAIL: \(error)") }
    print(failures == 0 ? "PASS: 片段界面回归全部通过" : "FAIL: 共 \(failures) 项失败")
    if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
}
app.run()
