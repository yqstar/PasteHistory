import Cocoa
import Carbon.HIToolbox
import Darwin

private var failureCount = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failureCount += 1
        print("FAIL: \(message)")
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PasteHistoryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func testSelectionRestoration() {
    let a = UUID()
    let b = UUID()
    let c = UUID()
    let inserted = UUID()

    check(restoredSelectionIndex(previousID: b, previousIndex: 1,
                                 newIDs: [inserted, a, b, c]) == 2,
          "刷新后应按 UUID 保留选中项")
    check(restoredSelectionIndex(previousID: b, previousIndex: 1,
                                 newIDs: [a, c]) == 1,
          "原项消失后应回退到接近的行号")
    check(restoredSelectionIndex(previousID: b, previousIndex: 1,
                                 newIDs: []) == nil,
          "空结果不应产生选中行")
}

private func testHistoryLimits() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let suiteName = "PasteHistoryTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        failureCount += 1
        print("FAIL: 无法创建隔离的 UserDefaults")
        return
    }
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = HistoryStore(baseDir: directory, defaults: defaults)
    check(store.maxItems == 100, "历史条数默认值应为 100")
    store.maxItems = 10_000
    check(store.maxItems == 500, "历史条数上限应为 500")
    for index in 0...500 {
        store.add(ClipItem(id: UUID(), kind: .text, text: "history-\(index)",
                           imageFile: nil, date: Date()))
    }
    check(store.items.count == 500, "历史记录实际保留数量不应超过 500")
    store.maxItems = 1
    check(store.maxItems == 10, "历史条数下限应为 10")
    check(store.items.count == 10, "降低历史上限时应立即裁剪现有数据")
}

private func testSnippetValidationAndDeduplication() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SnippetStore(baseDir: directory)

    do {
        _ = try store.add(title: "空", content: "  \n\t")
        check(false, "空白正文不应保存")
    } catch SnippetStore.StoreError.emptyContent {
        // Expected.
    }

    let first: Snippet
    switch try store.add(title: "第一条", content: "alpha") {
    case .added(let snippet): first = snippet
    case .duplicate:
        check(false, "首次添加不应判为重复")
        return
    }

    switch try store.add(title: "重复", content: "alpha") {
    case .added:
        check(false, "相同正文不应重复新增")
    case .duplicate(let existing):
        check(existing.id == first.id, "重复保存应返回原片段")
    }
    check(store.items.count == 1, "重复正文不应增加片段数量")

    let imported = [
        Snippet(id: UUID(), title: "导入重复", content: "alpha", hotKey: nil),
        Snippet(id: UUID(), title: "新增", content: "beta", hotKey: nil),
    ]
    let summary = try store.importItems(imported, mode: .merge)
    check(summary.added == 1 && summary.skipped == 1,
          "合并导入应忽略与现有正文重复的片段")
    check(store.items.count == 2, "合并导入后应保留两条唯一正文")

    let invalid = Snippet(id: UUID(), title: "无效快捷键", content: "gamma",
                          hotKey: HotKeyConfig(keyCode: 1, carbonModifiers: 0,
                                               display: "G"))
    do {
        _ = try store.importItems([invalid], mode: .replace)
        check(false, "无修饰键的导入快捷键应被拒绝")
    } catch SnippetStore.StoreError.invalidHotKey {
        // Expected.
    }
    check(store.items.count == 2, "导入校验失败时不应修改现有片段")
}

private func testSnippetBackupRecovery() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = SnippetStore(baseDir: directory)
    _ = try store.add(title: "第一版", content: "one")
    _ = try store.add(title: "第二版", content: "two")

    let mainURL = directory.appendingPathComponent("snippets.json")
    let backupURL = mainURL.appendingPathExtension("bak")
    check(FileManager.default.fileExists(atPath: backupURL.path),
          "第二次写入后应保留上一版 JSON 备份")
    try Data("{broken".utf8).write(to: mainURL, options: .atomic)

    let recovered = SnippetStore(baseDir: directory)
    check(recovered.items.count == 1 && recovered.items.first?.content == "one",
          "主文件损坏时应从上一版备份恢复")
    check(recovered.startupWarning != nil, "恢复损坏数据时应产生用户可见警告")

    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    check(names.contains(where: { $0.hasPrefix("snippets.corrupt-") && $0.hasSuffix(".json") }),
          "损坏的主文件应被隔离保留")

    try FileManager.default.removeItem(at: mainURL)
    let recoveredMissingMain = SnippetStore(baseDir: directory)
    check(recoveredMissingMain.items.first?.content == "one",
          "主文件缺失时也应从备份恢复")
    check(recoveredMissingMain.startupWarning != nil,
          "从缺失主文件恢复时应产生用户可见提示")
}

private func testSavingRemovedSnippet() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SnippetStore(baseDir: directory)
    let original = Snippet(id: UUID(), title: "编辑中的片段", content: "original")
    let replacement = Snippet(id: UUID(), title: "替换导入", content: "replacement")
    _ = try store.importItems([original], mode: .replace)
    var draft = original
    draft.content = "尚未保存的修改"
    _ = try store.importItems([replacement], mode: .replace)

    do {
        try store.update(draft)
        check(false, "原片段已移除时，保存必须报错，不能静默成功")
    } catch SnippetStore.StoreError.snippetNotFound {
        // The editor can now retain the draft and offer saving it as a new snippet.
    }
    check(store.items == [replacement], "保存过期草稿失败时应保留替换导入的数据")
    let reloaded = SnippetStore(baseDir: directory)
    check(reloaded.items == [replacement], "保存失败不应改写磁盘中的片段")
}

private func testCoalescedPersistence() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "PasteHistoryTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let history = HistoryStore(baseDir: directory, defaults: defaults)
    let first = ClipItem(id: UUID(), kind: .text, text: "one", imageFile: nil, date: Date())
    history.add(first)
    history.flush()
    for text in ["two", "three"] {
        history.add(ClipItem(id: UUID(), kind: .text, text: text, imageFile: nil, date: Date()))
    }
    history.flush()
    let backupURL = directory.appendingPathComponent("history.json.bak")
    let backup = try Data(contentsOf: backupURL)
    history.flush()
    let reloaded = HistoryStore(baseDir: directory, defaults: defaults)
    check(reloaded.items.map(\.text) == ["three", "two", "one"], "连续修改后 flush 应写入最新快照")
    reloaded.flush()
    let unchangedBackup = try Data(contentsOf: backupURL)
    check(backup == unchangedBackup, "未修改时重复 flush 或重启退出不应覆盖上一版备份")

    let snippets = SnippetStore(baseDir: directory)
    _ = try snippets.add(title: "A", content: "alpha")
    _ = try snippets.add(title: "B", content: "beta")
    let alpha = snippets.items.first { $0.content == "alpha" }!
    var beta = snippets.items.first { $0.content == "beta" }!
    snippets.bump(id: alpha.id)
    beta.content = "edited beta"
    try snippets.update(beta)
    RunLoop.current.run(until: Date().addingTimeInterval(0.7))
    snippets.flush()
    let saved = SnippetStore(baseDir: directory).items
    check(saved.map(\.content) == ["edited beta", "alpha"], "同步保存后，旧的延迟排序快照不能覆盖新内容")
    let snippetBackupURL = directory.appendingPathComponent("snippets.json.bak")
    let snippetBackup = try Data(contentsOf: snippetBackupURL)
    snippets.flush()
    let unchangedSnippetBackup = try Data(contentsOf: snippetBackupURL)
    check(unchangedSnippetBackup == snippetBackup, "片段重复 flush 应保留上一版备份")
}

private func testSearchAndPreview() {
    check(matchesQuery("Alpha", "ALPHA"), "英文搜索应忽略大小写")
    check(!matchesQuery("Alpha", "beta"), "未命中的英文搜索不应产生假结果")
    check(matchesQuery("剪贴板", "jian tie"), "中文片段应支持拼音匹配")
    check(matchesQuery("剪贴板", "TIE BAN"), "缓存后的拼音匹配也应忽略大小写")
    check(!matchesQuery("剪贴板", "missing"), "缓存后的未命中查询应返回 false")
    check(matchesQuery("Café", "cafe"), "搜索应保留去音调匹配")
    check(matchesQuery(String(repeating: "a", count: 500) + "TAIL_MARKER", "TAIL_MARKER"), "完整正文可匹配长文本尾部")
    check(oneLinePreview("  👨‍👩‍👧‍👦你好\n世界  ", limit: 4) == "👨‍👩‍👧‍👦你好 …", "摘要应保留完整 emoji 和中文字符并折叠换行")
    check(oneLinePreview("a\r\nb\tc", limit: 20) == "a b c", "摘要应统一处理换行和制表符")
}

do {
    testSelectionRestoration()
    try testHistoryLimits()
    try testSnippetValidationAndDeduplication()
    try testSnippetBackupRecovery()
    try testSavingRemovedSnippet()
    try testCoalescedPersistence()
    testSearchAndPreview()
} catch {
    failureCount += 1
    print("FAIL: 未预期错误：\(error)")
}

if failureCount == 0 {
    print("PASS: PasteHistory 逻辑测试全部通过")
} else {
    print("FAIL: 共 \(failureCount) 项测试失败")
    exit(EXIT_FAILURE)
}
