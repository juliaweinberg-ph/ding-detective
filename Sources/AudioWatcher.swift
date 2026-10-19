import AppKit
import CoreAudio

extension ProcessTap: @unchecked Sendable {}

/// Watches every process registered with CoreAudio and turns short bursts of sound into dings.
///
/// Two modes:
/// - Basic (no permission): an app "dings" when it opens an audio output stream.
/// - Precise (System Audio Recording granted): each app's output is tapped and metered, so we see
///   real sound onsets even when an app keeps a silent stream open, and we can hear sounds the
///   system plays on an app's behalf (notification banners) via systemsoundserverd.
@MainActor
final class AudioWatcher {
    private struct Proc {
        let app: AppInfo?
        let isSystemSounds: Bool
        var isSelf = false
        var running = false
        var lastRunning = Date.distantPast
        var tap: ProcessTap?
        var tapReadyAt: Date?
        var tapPending = false
    }

    private struct Source {
        var app: AppInfo?
        var running = false
        var runningSince: Date?
        var lastLoud = Date.distantPast
        var segmentStart: Date?
        var dingID: UUID?
        var edgeDing: (id: UUID, at: Date)?
        var lastDingAt = Date.distantPast
        var mediaUntil = Date.distantPast
    }

    // Tuning
    private let loudLevel: Float = 0.003      // ≈ -50 dBFS
    private let quietGap: TimeInterval = 1.0  // silence that separates two dings
    private let maxDingLength: TimeInterval = 5 // longer than this is music / video / a call
    private let mediaCooldown: TimeInterval = 60
    private let idleTapLifetime: TimeInterval = 600

    private let store: DingStore
    private let resolver = AppResolver.shared
    private var procs: [AudioObjectID: Proc] = [:]
    private var sources: [String: Source] = [:]
    private var systemTap: ProcessTap?
    private var systemTapExclusions: Set<AudioObjectID> = []
    private var systemTapPending = false
    private var lastLevelLog = Date.distantPast
    private var maxSystemLevel: Float = 0
    private var outputUID: String?
    private var tapsEnabled = false
    private var timer: Timer?
    private var tick = 0
    private let setupQueue = DispatchQueue(label: "ding.tap.setup", qos: .userInitiated)
    private static let systemKey = "__system__"

    init(store: DingStore) {
        self.store = store
    }

    func start() {
        outputUID = CA.defaultOutputUID()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        timer?.tolerance = 0.01
    }

    func setPrecise(_ enabled: Bool) {
        guard enabled != tapsEnabled else { return }
        tapsEnabled = enabled
        store.preciseAudio = enabled
        debugLog("precise audio: \(enabled)")
        if !enabled { tearDownTaps() }
    }

    // MARK: Loop

    private func step() {
        let now = Date()
        tick += 1
        if tick % 2 == 0 { refreshProcesses(now) }
        if tick % 20 == 0 { checkOutputDevice() }
        guard tapsEnabled else { return }

        var levels: [String: Float] = [:]
        for proc in procs.values {
            guard let tap = proc.tap, let key = proc.app?.bundleID else { continue }
            if sources[key]?.app == nil { sources[key, default: Source(app: nil)].app = proc.app }
            levels[key] = max(levels[key] ?? 0, tap.meter.take())
        }
        if let systemTap {
            let level = systemTap.meter.take()
            levels[Self.systemKey] = level
            maxSystemLevel = max(maxSystemLevel, level)
            if now.timeIntervalSince(lastLevelLog) > 2 {
                if maxSystemLevel > 0.0005 { debugLog(String(format: "system level peak %.4f", maxSystemLevel)) }
                maxSystemLevel = 0
                lastLevelLog = now
            }
        }
        for key in Set(levels.keys).union(sources.keys) {
            meter(key, level: levels[key] ?? 0, now: now)
        }
    }

    private func refreshProcesses(_ now: Date) {
        let objects = CA.processObjects()
        let alive = Set(objects)
        for (object, proc) in procs where !alive.contains(object) {
            proc.tap?.invalidate()
            procs[object] = nil
        }

        var appRunning: [String: Bool] = [:]
        for object in objects {
            if procs[object] == nil {
                let pid = CA.pid(object)
                let bundle = CA.string(object, kAudioProcessPropertyBundleID)
                let isSystem = bundle == "systemsoundserverd"
                let app = (pid == getpid() || isSystem) ? nil : resolver.app(forPID: pid)
                procs[object] = Proc(app: app, isSystemSounds: isSystem, isSelf: pid == getpid())
            }
            guard var proc = procs[object] else { continue }

            if proc.isSystemSounds { continue }
            guard let app = proc.app, !store.ignored.contains(app.bundleID) else { continue }

            let running = CA.isRunningOutput(object)
            if running {
                proc.lastRunning = now
                if !proc.running { processStartedOutput(object, proc: &proc, app: app, now: now) }
            } else if let tap = proc.tap, now.timeIntervalSince(proc.lastRunning) > idleTapLifetime {
                tap.invalidate()
                proc.tap = nil
                proc.tapReadyAt = nil
            }
            proc.running = running
            procs[object] = proc
            appRunning[app.bundleID] = (appRunning[app.bundleID] ?? false) || running
        }

        if tapsEnabled {
            // System tap hears every process that isn't an app (or us): banner sounds, alerts, beeps.
            let exclusions = Set(procs.filter { $0.value.app != nil || $0.value.isSelf }.keys)
            if !systemTapPending && (systemTap == nil || exclusions != systemTapExclusions) {
                makeSystemTap(excluding: exclusions)
            }
        } else {
            basicModeEdges(appRunning, now: now)
        }
    }

    // MARK: Precise mode

    private func processStartedOutput(_ object: AudioObjectID, proc: inout Proc, app: AppInfo, now: Date) {
        guard tapsEnabled else { return }
        let warm = proc.tapReadyAt.map { now.timeIntervalSince($0) > 0.3 } ?? false
        if warm { return } // the meter will tell us whether anything audible plays

        // Cold tap: the opening of the ding may be over before the tap is up, so count the
        // stream opening itself and let the meter adopt it if sound follows.
        var source = sources[app.bundleID] ?? Source(app: app)
        if now >= source.mediaUntil, now.timeIntervalSince(source.lastDingAt) > quietGap,
           let id = store.recordSound(app: app, viaSystem: false, at: now) {
            source.edgeDing = (id, now)
            source.lastDingAt = now
        }
        sources[app.bundleID] = source

        if proc.tap == nil && !proc.tapPending, let uid = outputUID {
            proc.tapPending = true
            setupQueue.async { [weak self] in
                let tap = ProcessTap(processes: [object], outputUID: uid)
                DispatchQueue.main.async {
                    debugLog("tap for \(app.name): \(tap == nil ? "FAILED" : "ok")")
                    guard let self, self.tapsEnabled, var current = self.procs[object] else { tap?.invalidate(); return }
                    current.tap = tap
                    current.tapReadyAt = Date()
                    current.tapPending = false
                    self.procs[object] = current
                }
            }
        }
    }

    private func makeSystemTap(excluding exclusions: Set<AudioObjectID>) {
        guard let uid = outputUID else { return }
        systemTapPending = true
        setupQueue.async { [weak self] in
            let tap = ProcessTap(processes: Array(exclusions), excluding: true, outputUID: uid)
            DispatchQueue.main.async {
                guard let self else { tap?.invalidate(); return }
                self.systemTapPending = false
                guard self.tapsEnabled else { tap?.invalidate(); return }
                let first = self.systemTap == nil
                self.systemTap?.invalidate()
                self.systemTap = tap
                self.systemTapExclusions = exclusions
                if first { debugLog("system sound tap: \(tap == nil ? "FAILED" : "ok") (excluding \(exclusions.count) app processes)") }
            }
        }
    }

    private func meter(_ key: String, level: Float, now: Date) {
        var source = sources[key] ?? Source(app: nil)
        defer { sources[key] = source }

        if level > loudLevel {
            if source.segmentStart == nil {
                source.segmentStart = now
                if let edge = source.edgeDing, now.timeIntervalSince(edge.at) < 1.5 {
                    source.dingID = edge.id
                } else if now < source.mediaUntil {
                    source.dingID = nil
                } else {
                    let isSystem = key == Self.systemKey
                    source.dingID = store.recordSound(app: isSystem ? nil : source.app, viaSystem: isSystem, at: now)
                    source.lastDingAt = now
                }
                source.edgeDing = nil
            }
            source.lastLoud = now
            if let start = source.segmentStart, now.timeIntervalSince(start) > maxDingLength {
                if let id = source.dingID { store.discardSound(id); source.dingID = nil }
                source.mediaUntil = now.addingTimeInterval(mediaCooldown)
            }
        } else if let start = source.segmentStart, now.timeIntervalSince(source.lastLoud) > quietGap {
            if let id = source.dingID { store.updateDuration(id, source.lastLoud.timeIntervalSince(start)) }
            source.segmentStart = nil
            source.dingID = nil
        }
    }

    // MARK: Basic mode

    private func basicModeEdges(_ appRunning: [String: Bool], now: Date) {
        // Apps whose processes went away still need their falling edge.
        let keys = Set(appRunning.keys).union(sources.keys.filter { sources[$0]?.running == true })
        for bundleID in keys {
            let running = appRunning[bundleID] ?? false
            var source = sources[bundleID] ?? Source(app: procs.values.first { $0.app?.bundleID == bundleID }?.app)
            if running && !source.running {
                source.runningSince = now
                if now >= source.mediaUntil, now.timeIntervalSince(source.lastDingAt) > quietGap {
                    source.dingID = store.recordSound(app: source.app, viaSystem: false, at: now)
                    source.lastDingAt = now
                }
            } else if running, let since = source.runningSince, now.timeIntervalSince(since) > 20 {
                // Basic mode can't hear silence, so only drop streams that are clearly media.
                if let id = source.dingID { store.discardSound(id); source.dingID = nil }
                source.mediaUntil = now.addingTimeInterval(mediaCooldown)
            } else if !running && source.running {
                if let id = source.dingID, let since = source.runningSince {
                    store.updateDuration(id, now.timeIntervalSince(since))
                }
                source.dingID = nil
                source.runningSince = nil
            }
            source.running = running
            sources[bundleID] = source
        }
    }

    // MARK: Taps

    private func checkOutputDevice() {
        let uid = CA.defaultOutputUID()
        guard uid != outputUID else { return }
        outputUID = uid
        tearDownTaps()
    }

    private func tearDownTaps() {
        for key in procs.keys {
            procs[key]?.tap?.invalidate()
            procs[key]?.tap = nil
            procs[key]?.tapReadyAt = nil
            procs[key]?.tapPending = false
        }
        systemTap?.invalidate()
        systemTap = nil
        systemTapExclusions = []
    }
}
