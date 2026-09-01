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

do {
    testSelectionRestoration()
    try testHistoryLimits()
    try testSnippetValidationAndDeduplication()
    try testSnippetBackupRecovery()
} catch {
    failureCount += 1
    print("FAIL: 未预期错误：\(error)")
}

if failureCount == 0 {
    print("PASS: PasteHistory 第一阶段逻辑测试全部通过")
} else {
    print("FAIL: 共 \(failureCount) 项测试失败")
    exit(EXIT_FAILURE)
}
