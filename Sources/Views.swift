import SwiftUI

// MARK: - Root

struct WidgetView: View {
    @ObservedObject var store: DingStore
    var requestAudio: () -> Void
    @State private var tab: Tab = .feed

    enum Tab: String, CaseIterable { case feed = "Feed", catalogue = "By app" }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 10) {
                header
                LastDingCard(store: store, now: context.date)
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch tab {
                case .feed: FeedView(store: store, now: context.date)
                case .catalogue: CatalogueView(store: store, now: context.date) { tab = .feed }
                }

                StatusFooter(store: store, requestAudio: requestAudio)
            }
            .padding(14)
        }
        .frame(minWidth: 320, idealWidth: 340, minHeight: 420, idealHeight: 560)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.and.waves.left.and.right.fill")
                .foregroundStyle(.orange)
            Text("Ding Detective").font(.headline)
            Spacer()
            ListeningDot()
        }
    }
}

struct ListeningDot: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(.green).frame(width: 7, height: 7)
                .opacity(on ? 1 : 0.35)
                .animation(.easeInOut(duration: 1.2).repeatForever(), value: on)
            Text("Listening").font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { on = true }
    }
}

// MARK: - "That ding was…" card

struct LastDingCard: View {
    @ObservedObject var store: DingStore
    let now: Date
    @State private var flash = false

    var body: some View {
        Group {
            if let ding = store.latestHeard {
                Button { store.open(ding) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        AppIcon(ding: ding, size: 46)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("THAT DING WAS").font(.system(size: 9, weight: .bold)).tracking(1)
                                .foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline) {
                                Text(ding.isIdentified ? ding.appName : "A system sound")
                                    .font(.title3.weight(.semibold)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(relative(ding.date, now: now)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let summary = ding.summary {
                                Text(summary).font(.callout).lineLimit(2).foregroundStyle(.primary.opacity(0.85))
                            } else if !ding.isIdentified {
                                Text("Played by macOS. Waiting for the notification that caused it…")
                                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                            HStack(spacing: 4) {
                                Image(systemName: store.canOpenSite(ding) ? "safari" : "arrow.up.forward.app")
                                Text(store.canOpenSite(ding) ? "Open \(ding.site ?? "")" : "Open \(ding.appName)")
                                    .lineLimit(1)
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                            .opacity(ding.isIdentified ? 1 : 0)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "ear").font(.title).foregroundStyle(.secondary)
                    Text("Next time something dings, it shows up here: which app, what it said, and a link back to it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(flash ? Color.orange.opacity(0.35) : Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(flash ? 0.9 : 0), lineWidth: 1.5)
        )
        .onChange(of: store.lastHeardID) { _, _ in
            withAnimation(.easeOut(duration: 0.15)) { flash = true }
            withAnimation(.easeIn(duration: 1.6).delay(0.4)) { flash = false }
        }
    }
}

// MARK: - Feed

struct FeedView: View {
    @ObservedObject var store: DingStore
    let now: Date

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                if let filter = store.appFilter {
                    Button { store.appFilter = nil } label: {
                        HStack(spacing: 4) {
                            Text(store.dings.first { $0.bundleID == filter }?.appName ?? filter).lineLimit(1)
                            Image(systemName: "xmark.circle.fill")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Toggle("Sounds only", isOn: $store.soundsOnly)
                    .toggleStyle(.checkbox).font(.caption).foregroundStyle(.secondary)
            }

            let dings = store.visibleDings
            if dings.isEmpty {
                Spacer()
                Text("Nothing yet").font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(dings.prefix(300)) { ding in
                            DingRow(store: store, ding: ding, now: now)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct DingRow: View {
    @ObservedObject var store: DingStore
    let ding: Ding
    let now: Date
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(ding: ding, size: 26)
                .opacity(ding.heard ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(ding.isIdentified ? ding.appName : "System sound").font(.callout.weight(.medium)).lineLimit(1)
                    Image(systemName: ding.heard ? "speaker.wave.2.fill" : "bell.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(ding.heard ? Color.orange : Color.secondary)
                        .help(ding.heard ? "Made a sound" : "Silent notification")
                    if let site = ding.site {
                        Text(site).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if let summary = ding.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if hover {
                HStack(spacing: 2) {
                    iconButton("arrow.up.forward.app", help: "Go to it") { store.open(ding) }
                    iconButton("bell.badge.slash", help: "Notification settings for this app") {
                        Permissions.openNotificationSettings(for: ding.bundleID)
                    }
                    iconButton("eye.slash", help: "Stop tracking this app") { store.ignore(ding.bundleID) }
                }
            } else {
                Text(relative(ding.date, now: now)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hover ? Color.primary.opacity(0.07) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.open(ding) }
        .help(tooltip)
    }

    private var tooltip: String {
        var lines = [ding.date.formatted(date: .abbreviated, time: .standard)]
        if let t = ding.title { lines.append(t) }
        if let s = ding.subtitle { lines.append(s) }
        if let b = ding.body { lines.append(b) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Catalogue

struct CatalogueView: View {
    @ObservedObject var store: DingStore
    let now: Date
    var showFeed: () -> Void

    var body: some View {
        let stats = store.stats
        if stats.isEmpty {
            VStack { Spacer(); Text("No dings catalogued yet").font(.callout).foregroundStyle(.secondary); Spacer() }
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(stats) { stat in
                        CatalogueRow(store: store, stat: stat, now: now) {
                            store.appFilter = stat.bundleID
                            showFeed()
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct CatalogueRow: View {
    @ObservedObject var store: DingStore
    let stat: AppStat
    let now: Date
    var select: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppResolver.shared.icon(for: stat.bundleID, path: stat.path))
                .resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.name).font(.callout.weight(.medium)).lineLimit(1)
                Text("\(stat.today) today · \(stat.heard) heard · \(stat.total) total")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if hover {
                HStack(spacing: 2) {
                    iconButton("arrow.up.forward.app", help: "Open app") {
                        if let path = stat.path { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    }
                    iconButton("bell.badge.slash", help: "Notification settings for this app") {
                        Permissions.openNotificationSettings(for: stat.bundleID)
                    }
                    iconButton("eye.slash", help: "Stop tracking this app") { store.ignore(stat.bundleID) }
                }
            } else {
                VStack(alignment: .trailing, spacing: 3) {
                    Sparkbars(values: stat.hourly)
                    Text(relative(stat.last, now: now)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: select)
        .help("Show only \(stat.name)")
    }
}

/// Last 24 hours, one bar per hour.
struct Sparkbars: View {
    let values: [Int]
    var body: some View {
        let peak = max(1, values.max() ?? 1)
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(values.indices, id: \.self) { i in
                Rectangle()
                    .fill(values[i] > 0 ? Color.orange : Color.primary.opacity(0.12))
                    .frame(width: 2, height: values[i] > 0 ? max(2, 14 * CGFloat(values[i]) / CGFloat(peak)) : 1)
            }
        }
        .frame(height: 14, alignment: .bottom)
        .help("Last 24 hours")
    }
}

// MARK: - Permissions footer

struct StatusFooter: View {
    @ObservedObject var store: DingStore
    var requestAudio: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.bottom, 2)
            statusLine(ok: store.preciseAudio,
                       good: "Hearing every ding, including notification banners",
                       bad: "Basic mode: misses sounds macOS plays for banners",
                       action: "Enable", perform: requestAudio)
            statusLine(ok: store.notificationAccess,
                       good: "Reading notification text & source sites",
                       bad: "Can't see what notifications said",
                       action: "Grant access", perform: Permissions.openFullDiskAccessSettings)
        }
    }

    private func statusLine(ok: Bool, good: String, bad: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text(ok ? good : bad).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            if !ok {
                Button(action, action: perform).font(.caption2).buttonStyle(.link)
            }
        }
    }
}

// MARK: - Bits

struct AppIcon: View {
    let ding: Ding
    let size: CGFloat
    var body: some View {
        if ding.isIdentified {
            Image(nsImage: AppResolver.shared.icon(for: ding.bundleID, path: ding.appPath))
                .resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "waveform.circle.fill")
                .resizable().frame(width: size * 0.85, height: size * 0.85)
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

@MainActor
func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol).font(.system(size: 11)).frame(width: 22, height: 22).contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(help)
}

func relative(_ date: Date, now: Date) -> String {
    let s = Int(now.timeIntervalSince(date))
    if date == .distantPast { return "—" }
    if s < 5 { return "now" }
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86_400 { return "\(s / 3600)h ago" }
    return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}
