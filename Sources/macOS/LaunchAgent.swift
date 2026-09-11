import Foundation

// MARK: - Launch at login (LaunchAgent)

enum LaunchAgent {
    static let label = "com.local.pastehistory"

    static var plistURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    private static func executablePath() -> String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    static func enable() {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath()],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: plistURL)
            shell(["/bin/launchctl", "load", "-w", plistURL.path])
        }
    }

    static func disable() {
        shell(["/bin/launchctl", "unload", "-w", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private static func shell(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}
