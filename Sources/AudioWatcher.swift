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
        var keepAudible = false
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
        /// Silent mode leaves this app audible until then (it's playing media / a call).
        var audibleUntil = Date.distantPast
    }

    // Tuning
    private let loudLevel: Float = 0.003      // ≈ -50 dBFS
    private let quietGap: TimeInterval = 1.0  // silence that separates two dings
    private let maxDingLength: TimeInterval = 5 // longer than this is music / video / a call
    private let mediaCooldown: TimeInterval = 60
    private let idleTapLifetime: TimeInterval = 600
    private let muteReleaseAfter: TimeInterval = 1.2 // a sound this long isn't a ding: let it play

    /// Never muted (or tapped as "system sound"): calls, Siri, dictation, VoiceOver.
    private static let alwaysAudible: Set<String> = [
        "com.apple.avconferenced", "com.apple.TelephonyUtilities", "com.apple.assistantd",
        "com.apple.CoreSpeech", "com.apple.corespeechd_system", "com.apple.universalaccessd",
        "com.apple.accessibility.heard", "com.apple.cmio.ContinuityCaptureAgent",
    ]

    private let store: DingStore
    private let resolver = AppResolver.shared
    private var procs: [AudioObjectID: Proc] = [:]
    private var sources: [String: Source] = [:]
    private var systemTap: ProcessTap?
    private var systemTapExclusions: Set<AudioObjectID> = []
    private var systemTapPending = false
    private var systemTapReadyAt = Date.distantPast
    private var lastLevelLog = Date.distantPast
    private var maxSystemLevel: Float = 0
    private var outputUID: String?
    private var tapsEnabled = false
    private var silent = false
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

    /// Silent mode: mute dings as they play (app sounds and notification banners), keep logging.
    func setSilent(_ enabled: Bool) {
        guard enabled != silent else { return }
        silent = enabled
        debugLog("silent mode: \(enabled)")
        systemTap?.setMuted(enabled)
        applyMuting(Date())
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
            var level = systemTap.meter.take()
            // A freshly started tap delivers a burst of startup noise; ignore its first second.
            if now.timeIntervalSince(systemTapReadyAt) < 1 { level = 0 }
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
        applyMuting(now)
    }

    /// Apps whose sound is never a ding: voice assistants and calls.
    private static let alwaysAudibleApps: Set<String> = [
        "com.apple.Siri", "com.apple.SiriNCService", "com.apple.FaceTime", "com.apple.TelephonyUtilities",
    ]

    private func shouldMute(_ bundleID: String, now: Date) -> Bool {
        guard silent, tapsEnabled, !Self.alwaysAudibleApps.contains(bundleID) else { return false }
        let source = sources[bundleID]
        return now >= (source?.audibleUntil ?? .distantPast) && now >= (source?.mediaUntil ?? .distantPast)
    }

    private func applyMuting(_ now: Date) {
        for proc in procs.values {
            guard let tap = proc.tap, let id = proc.app?.bundleID else { continue }
            let mute = shouldMute(id, now: now)
            if tap.isMuted != mute { tap.setMuted(mute) }
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
                procs[object] = Proc(app: app, isSystemSounds: isSystem, isSelf: pid == getpid(),
                                     keepAudible: Self.alwaysAudible.contains(bundle ?? ""))
            }
            guard var proc = procs[object] else { continue }

            if proc.isSystemSounds { continue }
            guard let app = proc.app, !store.ignored.contains(app.bundleID) else { continue }

            let running = CA.isRunningOutput(object)
            if running {
                proc.lastRunning = now
                if !proc.running { processStartedOutput(object, proc: &proc, app: app, now: now) }
            }
            if silent && tapsEnabled && proc.tap == nil && !proc.tapPending {
                // Tap ahead of time so even an app's first ding is caught muted.
                startTap(object, proc: &proc, app: app)
            } else if !running, !silent, let tap = proc.tap, now.timeIntervalSince(proc.lastRunning) > idleTapLifetime {
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
            let exclusions = Set(procs.filter { $0.value.app != nil || $0.value.isSelf || $0.value.keepAudible }.keys)
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

        if proc.tap == nil && !proc.tapPending { startTap(object, proc: &proc, app: app) }
    }

    private func startTap(_ object: AudioObjectID, proc: inout Proc, app: AppInfo) {
        guard let uid = outputUID else { return }
        proc.tapPending = true
        let muted = shouldMute(app.bundleID, now: Date())
        setupQueue.async { [weak self] in
            let tap = ProcessTap(processes: [object], muted: muted, outputUID: uid)
            DispatchQueue.main.async {
                debugLog("tap for \(app.name): \(tap == nil ? "FAILED" : "ok")\(muted ? " (muted)" : "")")
                guard let self, self.tapsEnabled, var current = self.procs[object] else { tap?.invalidate(); return }
                current.tap = tap
                current.tapReadyAt = Date()
                current.tapPending = false
                self.procs[object] = current
            }
        }
    }

    private func makeSystemTap(excluding exclusions: Set<AudioObjectID>) {
        guard let uid = outputUID else { return }
        systemTapPending = true
        let muted = silent
        setupQueue.async { [weak self] in
            let tap = ProcessTap(processes: Array(exclusions), excluding: true, muted: muted, outputUID: uid)
            DispatchQueue.main.async {
                guard let self else { tap?.invalidate(); return }
                self.systemTapPending = false
                guard self.tapsEnabled else { tap?.invalidate(); return }
                let first = self.systemTap == nil
                self.systemTap?.invalidate()
                tap?.setMuted(self.silent)
                self.systemTap = tap
                self.systemTapReadyAt = Date()
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
                    let silenced = isSystem ? silent && tapsEnabled : shouldMute(key, now: now)
                    source.dingID = store.recordSound(app: isSystem ? nil : source.app, viaSystem: isSystem,
                                                      silenced: silenced, at: now)
                    source.lastDingAt = now
                }
                source.edgeDing = nil
            }
            source.lastLoud = now
            // Too long for a ding (or already playing media): let this app be heard while it lasts.
            if key != Self.systemKey, let start = source.segmentStart,
               now.timeIntervalSince(start) > muteReleaseAfter || now < source.audibleUntil {
                source.audibleUntil = now.addingTimeInterval(mediaCooldown)
            }
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
