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

private func testUpdates() throws {
    check(AppVersion("1.0") == AppVersion("v1.0.0"), "旧版 1.0 与发布标签 v1.0.0 应等价")
    check(AppVersion("1.10.0")! > AppVersion("1.9.9")!, "版本号应按数值比较，不能按字符串排序")
    check(AppVersion("2.0.0")! > AppVersion("1.99.99")!, "主版本升级优先于次版本与补丁")
    for invalid in ["", "v", "1", "1..0", "1.0.0.1", "1.0.0-beta.1", "-1.0.0", "01.0.0", "１.0.0", String(repeating: "9", count: 50) + ".0.0"] {
        check(AppVersion(invalid) == nil, "拒绝不支持的版本号：\(invalid)")
    }

    let download = "https://github.com/yqstar/PasteHistory/releases/download/v1.10.0/PasteHistory-1.10.0-universal.dmg"
    var payload: [String: Any] = [
        "tag_name": "v1.10.0", "html_url": "https://github.com/yqstar/PasteHistory/releases/tag/v1.10.0",
        "draft": false, "prerelease": false, "body": "## 改进\n- 更新功能",
        "assets": [["name": "PasteHistory-1.10.0-universal.dmg", "state": "uploaded", "size": 2048,
                    "browser_download_url": download]],
    ]
    func parse(_ payload: [String: Any], status: Int = 200) throws -> PublishedRelease {
        let response = HTTPURLResponse(url: AppReleaseInfo.latestAPIURL, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        return try GitHubReleaseChecker.parse(data: JSONSerialization.data(withJSONObject: payload), response: response)
    }
    let release = try parse(payload)
    check(release.version == AppVersion("1.10.0") && release.notes.contains("更新功能"), "解析正式版本与中文更新说明")
    check(release.downloadURL?.absoluteString == download, "选取当前版本的 Universal DMG")
    for code in [403, 404, 429, 500] {
        do {
            _ = try parse(payload, status: code)
            check(false, "HTTP \(code) 不得显示检查成功")
        } catch let error as UpdateCheckError {
            switch (code, error) {
            case (403, .rateLimited), (429, .rateLimited), (404, .noRelease), (500, .server(500)): break
            default: check(false, "HTTP \(code) 应显示对应错误原因")
            }
        }
    }
    for key in ["draft", "prerelease"] {
        var invalid = payload
        invalid[key] = true
        do { _ = try parse(invalid); check(false, "不得提示草稿或预发布版本") }
        catch UpdateCheckError.invalidResponse { }
    }
    for url in ["http://github.com/yqstar/PasteHistory/releases/tag/v1.10.0",
                "https://example.com/yqstar/PasteHistory/releases/tag/v1.10.0",
                "https://github.com/another/project/releases/tag/v1.10.0",
                "https://github.com/yqstar/PasteHistory/releases/tag/v9.9.9"] {
        var invalid = payload
        invalid["html_url"] = url
        do { _ = try parse(invalid); check(false, "拒绝非本项目或标签不符的发布地址") }
        catch UpdateCheckError.invalidResponse { }
    }
    payload["body"] = NSNull()
    payload["assets"] = []
    let missing = try parse(payload)
    check(missing.downloadURL == nil && !missing.notes.isEmpty, "缺少安装包或说明时提供发布页面回退")
    for url in ["https://example.com/package.dmg", download.replacingOccurrences(of: "v1.10.0/", with: "v1.9.0/")] {
        payload["assets"] = [["name": "PasteHistory-1.10.0-universal.dmg", "state": "uploaded", "size": 2048,
                              "browser_download_url": url]]
        let unsafeAsset = try parse(payload)
        check(unsafeAsset.downloadURL == nil, "忽略来源或版本不符的安装包地址")
    }
    let badResponse = HTTPURLResponse(url: AppReleaseInfo.latestAPIURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
    do {
        _ = try GitHubReleaseChecker.parse(data: Data("<html>error</html>".utf8), response: badResponse)
        check(false, "无效 JSON 不得判为最新版本")
    } catch UpdateCheckError.invalidResponse { }
}

private final class UpdateStubProtocol: URLProtocol {
    static var failure: Error?
    static var observedRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.observedRequest = request
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"tag_name":"v1.0.3","html_url":"https://github.com/yqstar/PasteHistory/releases/tag/v1.0.3","draft":false,"prerelease":false,"assets":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private func testUpdateTransport() {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [UpdateStubProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let checker = GitHubReleaseChecker(session: session)
    for offline in [false, true] {
        UpdateStubProtocol.failure = offline ? URLError(.notConnectedToInternet) : nil
        var completed = false
        checker.fetchLatest { result in
            check(Thread.isMainThread, "网络结果应在主线程更新界面")
            switch result {
            case .success(let release): check(!offline && release.version == AppVersion("1.0.3"), "网络响应传递正式版本")
            case .failure(let error): check(offline && error is UpdateCheckError, "断网应显示可重试的网络错误")
            }
            completed = true
        }
        let deadline = Date().addingTimeInterval(3)
        while !completed && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(completed, "检查更新请求必须回调")
    }
    let request = UpdateStubProtocol.observedRequest
    check(request?.url == AppReleaseInfo.latestAPIURL && request?.httpMethod == "GET", "只请求公开的最新正式版本接口")
    check(request?.httpBody == nil && request?.value(forHTTPHeaderField: "Authorization") == nil,
          "更新请求不携带剪贴板内容或授权凭据")
}

do {
    testSelectionRestoration()
    try testHistoryLimits()
    try testSnippetValidationAndDeduplication()
    try testSnippetBackupRecovery()
    try testSavingRemovedSnippet()
    try testCoalescedPersistence()
    testSearchAndPreview()
    try testUpdates()
    testUpdateTransport()
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
