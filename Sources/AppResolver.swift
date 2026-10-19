import AppKit
import Darwin
import SwiftUI

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

    private var tintCache: [String: Color] = [:]

    /// A vivid colour pulled from the app's icon, used to tint the "latest ding" card.
    func tint(for bundleID: String?, path: String?) -> Color {
        let key = path ?? bundleID ?? "?"
        if let cached = tintCache[key] { return cached }
        var result = Color(red: 0.84, green: 1.0, blue: 0.0)
        let image = icon(for: bundleID, path: path)
        let side = 24
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            // Bucket vivid pixels by hue and use the most common hue, so a multicoloured icon
            // (Chrome, Slack) picks one of its colours instead of averaging them into mud.
            let bins = 12
            var weight = [Double](repeating: 0, count: bins)
            var hueSum = [Double](repeating: 0, count: bins)
            var brightSum = [Double](repeating: 0, count: bins)
            for x in 0..<side {
                for y in 0..<side {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          c.alphaComponent > 0.5, c.saturationComponent > 0.3, c.brightnessComponent > 0.3 else { continue }
                    let bin = min(bins - 1, Int(c.hueComponent * Double(bins)))
                    // Yellows turn olive over dark glass, so let an icon's other colours win.
                    let isYellow = (0.11...0.2).contains(c.hueComponent)
                    let w = c.saturationComponent * c.brightnessComponent * (isYellow ? 0.35 : 1)
                    weight[bin] += w
                    hueSum[bin] += c.hueComponent * w
                    brightSum[bin] += c.brightnessComponent * w
                }
            }
            if let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 1 {
                let hue = hueSum[best] / weight[best]
                let brightness = brightSum[best] / weight[best]
                result = Color(nsColor: NSColor(hue: hue, saturation: 0.75, brightness: min(0.85, max(0.6, brightness)), alpha: 1))
            } else {
                result = Color(white: 0.55)   // greyscale icon
            }
        }
        tintCache[key] = result
        return result
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
