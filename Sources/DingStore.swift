import AppKit
import Combine

struct Ding: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var bundleID: String?
    var appName: String
    var appPath: String?
    /// A sound was actually detected (vs. a notification that arrived silently).
    var heard: Bool
    /// Sound came from the system sound server (notification banner / alert), not the app itself.
    var viaSystem = false
    var duration: Double = 0
    var title: String?
    var subtitle: String?
    var body: String?
    var site: String?
    var notificationRec: Int64?

    var isIdentified: Bool { bundleID != nil }

    var summary: String? {
        let parts = [title, body].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
}

struct IncomingNotification {
    let rec: Int64
    let bundleID: String
    let date: Date
    let title: String?
    let subtitle: String?
    let body: String?
}

struct AppStat: Identifiable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let path: String?
    var today = 0
    var total = 0
    var heard = 0
    var last: Date = .distantPast
    var hourly = [Int](repeating: 0, count: 24)
}

@MainActor
final class DingStore: ObservableObject {
    @Published private(set) var dings: [Ding] = []
    @Published var ignored: Set<String> {
        didSet { UserDefaults.standard.set(Array(ignored), forKey: "ignored") }
    }
    @Published var soundsOnly: Bool {
        didSet { UserDefaults.standard.set(soundsOnly, forKey: "soundsOnly") }
    }
    @Published var appFilter: String?
    @Published var preciseAudio = false
    @Published var notificationAccess = false
    /// Bumped whenever a ding is heard, so the UI can flash.
    @Published private(set) var lastHeardID: UUID?

    var onHeard: ((Ding) -> Void)?

    static let defaultIgnored: Set<String> = [
        "com.apple.Music", "com.spotify.client", "com.apple.QuickTimePlayerX", "com.apple.TV",
        "com.apple.podcasts", "us.zoom.xos", "com.apple.FaceTime", "com.microsoft.teams2",
        "com.cheapassjimmy.dingdetective",
    ]

    private let correlationWindow: TimeInterval = 4
    private let fileURL: URL
    private var saveWork: DispatchWorkItem?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ding Detective", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("dings.json")
        ignored = Set(UserDefaults.standard.stringArray(forKey: "ignored") ?? Array(Self.defaultIgnored))
        soundsOnly = UserDefaults.standard.object(forKey: "soundsOnly") as? Bool ?? false
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Ding].self, from: data) {
            dings = saved
        }
    }

    // MARK: Queries

    var visibleDings: [Ding] {
        dings.filter { ding in
            if let id = ding.bundleID, ignored.contains(id) { return false }
            if soundsOnly && !ding.heard { return false }
            if let appFilter, ding.bundleID != appFilter { return false }
            return true
        }
    }

    var latestHeard: Ding? {
        dings.first { $0.heard && !ignored.contains($0.bundleID ?? "") }
    }

    var stats: [AppStat] {
        var byApp: [String: AppStat] = [:]
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let dayAgo = Date().addingTimeInterval(-86_400)
        for ding in dings {
            guard let id = ding.bundleID, !ignored.contains(id) else { continue }
            var stat = byApp[id] ?? AppStat(bundleID: id, name: ding.appName, path: ding.appPath)
            stat.total += 1
            if ding.heard { stat.heard += 1 }
            if ding.date >= startOfDay { stat.today += 1 }
            if ding.date > stat.last { stat.last = ding.date }
            if ding.date > dayAgo {
                let hoursAgo = Int(Date().timeIntervalSince(ding.date) / 3600)
                stat.hourly[23 - min(23, hoursAgo)] += 1
            }
            byApp[id] = stat
        }
        return byApp.values.sorted { ($0.today, $0.total, $0.last) > ($1.today, $1.total, $1.last) }
    }

    // MARK: Mutations

    /// A sound was detected. `app` is nil for system-played sounds (notification banners),
    /// which get attributed once the matching notification shows up.
    @discardableResult
    func recordSound(app: AppInfo?, viaSystem: Bool, at date: Date = Date()) -> UUID? {
        if let id = app?.bundleID, ignored.contains(id) { return nil }
        if app == nil, dings.contains(where: { $0.heard && $0.bundleID != nil && !$0.viaSystem
                                               && abs($0.date.timeIntervalSince(date)) < 1.5 }) {
            return nil
        }

        // A notification may already have been logged for this sound.
        if let index = dings.firstIndex(where: { candidate in
            !candidate.heard && candidate.notificationRec != nil
                && abs(candidate.date.timeIntervalSince(date)) < correlationWindow
                && (app == nil || Self.sameApp(candidate.bundleID, app?.bundleID))
        }) {
            dings[index].heard = true
            dings[index].viaSystem = viaSystem
            announce(dings[index])
            return dings[index].id
        }

        let ding = Ding(date: date, bundleID: app?.bundleID, appName: app?.name ?? "System sound",
                        appPath: app?.path, heard: true, viaSystem: viaSystem)
        insert(ding)
        announce(ding)
        return ding.id
    }

    func recordNotification(_ note: IncomingNotification, announceIfMatched: Bool = true) {
        guard !dings.contains(where: { $0.notificationRec == note.rec }) else { return }
        let app = AppResolver.shared.app(forBundleID: note.bundleID)
        let site = Self.site(in: note)

        // Attach to a sound heard around the same time, from this app or from the system.
        if let index = dings.firstIndex(where: { candidate in
            candidate.heard && candidate.notificationRec == nil
                && abs(candidate.date.timeIntervalSince(note.date)) < correlationWindow
                && (candidate.bundleID == nil || Self.sameApp(candidate.bundleID, app.bundleID))
        }) {
            dings[index].bundleID = app.bundleID
            dings[index].appName = app.name
            dings[index].appPath = app.path
            dings[index].title = note.title
            dings[index].subtitle = note.subtitle
            dings[index].body = note.body
            dings[index].site = site
            dings[index].notificationRec = note.rec
            if announceIfMatched { announce(dings[index]) }
            scheduleSave()
            return
        }

        insert(Ding(date: note.date, bundleID: app.bundleID, appName: app.name, appPath: app.path,
                    heard: false, title: note.title, subtitle: note.subtitle, body: note.body,
                    site: site, notificationRec: note.rec))
    }

    func updateDuration(_ id: UUID, _ duration: Double) {
        guard let index = dings.firstIndex(where: { $0.id == id }) else { return }
        dings[index].duration = duration
        scheduleSave()
    }

    /// A sound turned out to be music / video / a call rather than a ding.
    func discardSound(_ id: UUID) {
        guard let index = dings.firstIndex(where: { $0.id == id }) else { return }
        if dings[index].notificationRec != nil {
            dings[index].heard = false
            scheduleSave()
        } else {
            remove(id)
        }
    }

    func remove(_ id: UUID) {
        dings.removeAll { $0.id == id }
        scheduleSave()
    }

    func ignore(_ bundleID: String?) {
        guard let bundleID else { return }
        ignored.insert(bundleID)
        if appFilter == bundleID { appFilter = nil }
    }

    func clear() {
        dings.removeAll()
        scheduleSave()
    }

    // MARK: Links

    static let browsers = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
                           "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
                           "com.apple.Safari", "org.mozilla.firefox"]

    func canOpenSite(_ ding: Ding) -> Bool {
        ding.site != nil && Self.browsers.contains(where: { ding.bundleID?.hasPrefix($0) == true })
    }

    /// Jump to wherever the ding came from: the website (in the browser that sent it) or the app.
    func open(_ ding: Ding) {
        let workspace = NSWorkspace.shared
        let appURL = ding.appPath.map { URL(fileURLWithPath: $0) }
            ?? ding.bundleID.flatMap { workspace.urlForApplication(withBundleIdentifier: $0) }

        if canOpenSite(ding), let site = ding.site, let url = URL(string: "https://\(site)") {
            if let appURL {
                workspace.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            } else {
                workspace.open(url)
            }
            return
        }
        if let appURL {
            workspace.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Private

    private func insert(_ ding: Ding) {
        let index = dings.firstIndex { $0.date < ding.date } ?? dings.endIndex
        dings.insert(ding, at: index)
        if dings.count > 2000 { dings.removeLast(dings.count - 2000) }
        scheduleSave()
    }

    private func announce(_ ding: Ding) {
        debugLog("DING \(ding.appName) system=\(ding.viaSystem) \(ding.summary ?? "")")
        lastHeardID = ding.id
        onHeard?(ding)
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = dings
        let url = fileURL
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }

    private static func sameApp(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a == b || a.hasPrefix(b + ".") || b.hasPrefix(a + ".")
    }

    private static let domainPattern = try! NSRegularExpression(
        pattern: #"\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,})\b"#, options: [.caseInsensitive])

    /// Browsers put the sending site's origin in the notification subtitle (e.g. "mail.google.com").
    private static func site(in note: IncomingNotification) -> String? {
        for text in [note.subtitle, note.title] {
            guard let text else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = domainPattern.firstMatch(in: text, range: range),
               let r = Range(match.range(at: 1), in: text) {
                return String(text[r]).lowercased()
            }
        }
        return nil
    }
}
