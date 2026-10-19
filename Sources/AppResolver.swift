import AppKit
import Darwin

struct AppInfo: Hashable, Codable {
    let bundleID: String
    let name: String
    let path: String?
}

/// Maps PIDs and bundle identifiers (including helper processes, XPC services and
/// Chrome's notification service) back to the user-facing app that owns them.
@MainActor
final class AppResolver {
    static let shared = AppResolver()

    private var pidCache: [pid_t: AppInfo?] = [:]
    private var bundleCache: [String: AppInfo] = [:]
    private var iconCache: [String: NSImage] = [:]

    func app(forPID pid: pid_t) -> AppInfo? {
        if let cached = pidCache[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let info = length > 0 ? app(forExecutablePath: String(cString: buffer)) : nil
        pidCache[pid] = info
        return info
    }

    func app(forBundleID bundleID: String) -> AppInfo {
        if let cached = bundleCache[bundleID] { return cached }
        var info: AppInfo?
        var parts = bundleID.split(separator: ".").map(String.init)
        // Try the full ID, then progressively shorter prefixes
        // (com.google.Chrome.framework.AlertNotificationService -> com.google.Chrome).
        while info == nil, parts.count >= 2 {
            let candidate = parts.joined(separator: ".")
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) {
                info = app(forExecutablePath: url.path)
            }
            parts.removeLast()
        }
        let resolved = info ?? AppInfo(bundleID: bundleID, name: Self.prettify(bundleID), path: nil)
        bundleCache[bundleID] = resolved
        return resolved
    }

    /// The outermost .app bundle on the path owns the process (Slack Helper.app lives inside Slack.app).
    private func app(forExecutablePath path: String) -> AppInfo? {
        let components = (path as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let appPath = NSString.path(withComponents: Array(components[...index]))
        let bundle = Bundle(path: appPath)
        let bundleID = bundle?.bundleIdentifier ?? appPath
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
        return AppInfo(bundleID: bundleID, name: name, path: appPath)
    }

    func icon(for bundleID: String?, path: String?) -> NSImage {
        let key = path ?? bundleID ?? "?"
        if let cached = iconCache[key] { return cached }
        let image: NSImage
        if let path {
            image = NSWorkspace.shared.icon(forFile: path)
        } else if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "speaker.wave.2.circle.fill", accessibilityDescription: nil)!
        }
        iconCache[key] = image
        return image
    }

    private static func prettify(_ bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}

// MARK: - Permissions

enum Permissions {
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let service = "kTCCServiceAudioCapture" as CFString

    /// nil = undetermined
    static var audioCaptureGranted: Bool? {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessPreflight") else { return nil }
        switch unsafeBitCast(sym, to: PreflightFn.self)(service, nil) {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    static func requestAudioCapture(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessRequest") else { completion(false); return }
        unsafeBitCast(sym, to: RequestFn.self)(service, nil) { granted in completion(granted) }
    }

    static func openAudioCaptureSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
    }

    static func openFullDiskAccessSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    static func openNotificationSettings(for bundleID: String?) {
        if let bundleID {
            open("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)")
        } else {
            open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        }
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

/// Appends to ~/Library/Logs/DingDetective.log (handy for figuring out why something wasn't caught).
func debugLog(_ message: String) {
    let line = "\(Date().formatted(.iso8601)) \(message)\n"
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DingDetective.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile(); handle.write(line.data(using: .utf8)!); try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}
