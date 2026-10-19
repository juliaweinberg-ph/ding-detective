import SwiftUI

// MARK: - Theme

enum Theme {
    /// Neon chartreuse.
    static let accent = Color(red: 0.84, green: 1.0, blue: 0.0)
    static let deep = Color(red: 0.76, green: 0.97, blue: 0.0)
    static let brand = LinearGradient(colors: [Color(red: 0.92, green: 1.0, blue: 0.42), deep],
                                      startPoint: .top, endPoint: .bottom)
    /// Text and glyphs sitting on the accent; chartreuse is too bright for white.
    static let onAccent = Color(red: 0.08, green: 0.1, blue: 0.02)
    static let expandedRadius: CGFloat = 26

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Root

struct WidgetView: View {
    @ObservedObject var store: DingStore
    var requestAudio: () -> Void

    var body: some View {
        Group {
            if store.collapsed {
                CollapsedBar(store: store)
            } else {
                ExpandedWidget(store: store, requestAudio: requestAudio)
            }
        }
        .environment(\.colorScheme, .dark)
        // Ding Detective has no Dock icon, so the widget itself offers a way out.
        .contextMenu {
            Button(store.collapsed ? "Expand" : "Collapse") { store.collapsed.toggle() }
            Toggle("Silent Mode", isOn: $store.silent)
            Button("Hide Widget") {
                NSApp.windows.first { $0 is WidgetPanel }?.orderOut(nil)
            }
            Divider()
            Button("Quit Ding Detective") { NSApp.terminate(nil) }
        }
    }
}

// MARK: - Glass

/// Smoked glass: a behind-window blur, darkened, with a soft top highlight and a hairline edge.
struct Glass<S: InsettableShape>: View {
    let shape: S
    var glow: Double = 0

    var body: some View {
        ZStack {
            BehindWindowBlur()
            Color.black.opacity(0.42)
            LinearGradient(colors: [.white.opacity(0.09), .clear], startPoint: .top, endPoint: .center)
            RadialGradient(colors: [Theme.accent.opacity(0.45 * glow), .clear],
                           center: .leading, startRadius: 0, endRadius: 220)
        }
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75)
        )
        .overlay(shape.strokeBorder(Theme.accent.opacity(0.85 * glow), lineWidth: 1.5))
    }
}

struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Fades a glow in when something dings, then lets it settle.
struct RingGlow: ViewModifier {
    let trigger: UUID?
    @Binding var glow: Double
    func body(content: Content) -> some View {
        content.onChange(of: trigger) { _, _ in
            withAnimation(.easeOut(duration: 0.18)) { glow = 1 }
            withAnimation(.easeInOut(duration: 1.8).delay(0.5)) { glow = 0 }
        }
    }
}

// MARK: - Collapsed capsule

struct CollapsedBar: View {
    @ObservedObject var store: DingStore
    @State private var glow = 0.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 11) {
                if let ding = store.latestHeard {
                    Button { store.open(ding) } label: {
                        HStack(spacing: 11) {
                            BadgedIcon(ding: ding, size: 36, ringing: store.lastHeardID)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ding.isIdentified ? ding.appName : "System sound")
                                    .font(Theme.rounded(13.5, .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(ding.summary ?? ding.site ?? (ding.isIdentified ? "Made a sound" : "Played by macOS"))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.white.opacity(0.58))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Go to \(ding.isIdentified ? ding.appName : "it")")

                    Text(shortRelative(ding.date, now: context.date))
                        .font(Theme.rounded(11, .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize()
                    if store.silent { SilentToggle(store: store) }
                } else {
                    BrandMark(size: 36, ringing: store.lastHeardID)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ding Detective").font(Theme.rounded(13.5, .semibold)).foregroundStyle(.white)
                        LiveLabel(text: store.silent ? "Silent · still logging" : "Listening")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if store.silent { SilentToggle(store: store) }
                }
                CircleButton(symbol: "chevron.down", help: "Expand") { store.collapsed = false }
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Glass(shape: Capsule(style: .continuous), glow: glow))
        }
        .modifier(RingGlow(trigger: store.lastHeardID, glow: $glow))
    }
}

// MARK: - Expanded card

struct ExpandedWidget: View {
    @ObservedObject var store: DingStore
    var requestAudio: () -> Void
    @State private var tab: Tab = .feed
    @State private var glow = 0.0
    @Namespace private var tabs

    enum Tab: String, CaseIterable { case feed = "Feed", catalogue = "By app" }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 14) {
                header(now: context.date)
                HeroCard(store: store, now: context.date)
                tabBar
                Group {
                    switch tab {
                    case .feed: FeedView(store: store, now: context.date)
                    case .catalogue: CatalogueView(store: store, now: context.date) { tab = .feed }
                    }
                }
                .frame(maxHeight: .infinity)
                PermissionCallout(store: store, requestAudio: requestAudio)
            }
            .padding(16)
            .background(Glass(shape: RoundedRectangle(cornerRadius: Theme.expandedRadius, style: .continuous), glow: glow))
        }
        .modifier(RingGlow(trigger: store.lastHeardID, glow: $glow))
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 10) {
            BrandMark(size: 30, ringing: store.lastHeardID)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ding Detective").font(Theme.rounded(14.5, .semibold)).foregroundStyle(.white)
                let today = store.dings.filter { $0.heard && Calendar.current.isDateInToday($0.date) }.count
                let state = store.silent ? "Silent" : "Listening"
                LiveLabel(text: today == 0 ? state : "\(state) · \(today) today")
            }
            Spacer()
            SilentToggle(store: store)
            CircleButton(symbol: "chevron.up", help: "Collapse to a bar") { store.collapsed = true }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { tab = item }
                    } label: {
                        Text(item.rawValue)
                            .font(Theme.rounded(12, .semibold))
                            .foregroundStyle(.white.opacity(tab == item ? 1 : 0.5))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background {
                                if tab == item {
                                    Capsule().fill(.white.opacity(0.14))
                                        .matchedGeometryEffect(id: "tab", in: tabs)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Capsule().fill(.white.opacity(0.06)))

            Spacer()

            if tab == .feed {
                Chip(title: "Sounds only", symbol: "waveform", on: store.soundsOnly) {
                    withAnimation(.easeInOut(duration: 0.2)) { store.soundsOnly.toggle() }
                }
            }
        }
    }
}

// MARK: - Hero

struct HeroCard: View {
    @ObservedObject var store: DingStore
    let now: Date
    @State private var hover = false

    var body: some View {
        if let ding = store.latestHeard {
            let tint = AppResolver.shared.tint(for: ding.bundleID, path: ding.appPath)
            Button { store.open(ding) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        AppIcon(ding: ding, size: 46)
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("LATEST DING · \(relative(ding.date, now: now).uppercased())")
                                .font(Theme.rounded(9.5, .bold)).tracking(0.6)
                                .foregroundStyle(.white.opacity(0.55))
                            Text(ding.isIdentified ? ding.appName : "A system sound")
                                .font(Theme.rounded(19, .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(ding.summary ?? (ding.isIdentified ? "Made a sound." : "Played by macOS. Waiting for the notification behind it…"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if ding.isIdentified {
                        HStack(spacing: 5) {
                            Text(store.canOpenSite(ding) ? "Open \(ding.site ?? "")" : "Open \(ding.appName)")
                                .lineLimit(1)
                            Image(systemName: "arrow.up.right")
                        }
                        .font(Theme.rounded(11.5, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(hover ? 0.24 : 0.15)))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    ZStack {
                        Color.white.opacity(0.06)
                        // A glow of the app's colour rising from behind its icon.
                        RadialGradient(colors: [tint.opacity(0.55), tint.opacity(0.18), .clear],
                                       center: UnitPoint(x: 0.12, y: 0.2), startRadius: 0, endRadius: 260)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 0.75)
                )
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.15), value: hover)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "ear.badge.waveform")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Theme.brand)
                Text("Waiting for the next ding")
                    .font(Theme.rounded(14, .semibold)).foregroundStyle(.white)
                Text("You'll see which app it was, what it said, and a link straight back to it.")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.06)))
        }
    }
}

// MARK: - Feed

struct FeedView: View {
    @ObservedObject var store: DingStore
    let now: Date

    var body: some View {
        VStack(spacing: 8) {
            if let filter = store.appFilter {
                HStack {
                    Chip(title: store.dings.first { $0.bundleID == filter }?.appName ?? filter,
                         symbol: "xmark", on: true) { store.appFilter = nil }
                    Spacer()
                }
            }
            let dings = Array(store.visibleDings.prefix(300))
            if dings.isEmpty {
                EmptyState(symbol: "bell.slash", text: store.soundsOnly ? "No sounds yet" : "Nothing yet")
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                        ForEach(sections(dings), id: \.title) { section in
                            Text(section.title.uppercased())
                                .font(Theme.rounded(9.5, .bold)).tracking(0.8)
                                .foregroundStyle(.white.opacity(0.38))
                                .padding(.horizontal, 8)
                                .padding(.top, section.title == sections(dings).first?.title ? 0 : 10)
                                .padding(.bottom, 2)
                            ForEach(section.dings) { ding in
                                DingRow(store: store, ding: ding, now: now)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct Section { let title: String; let dings: [Ding] }

    private func sections(_ dings: [Ding]) -> [Section] {
        let calendar = Calendar.current
        var order: [String] = []
        var grouped: [String: [Ding]] = [:]
        for ding in dings {
            let title: String
            if now.timeIntervalSince(ding.date) < 3600 { title = "Last hour" }
            else if calendar.isDateInToday(ding.date) { title = "Earlier today" }
            else if calendar.isDateInYesterday(ding.date) { title = "Yesterday" }
            else { title = "Older" }
            if grouped[title] == nil { order.append(title) }
            grouped[title, default: []].append(ding)
        }
        return order.map { Section(title: $0, dings: grouped[$0]!) }
    }
}

struct DingRow: View {
    @ObservedObject var store: DingStore
    let ding: Ding
    let now: Date
    @State private var hover = false

    var body: some View {
        HStack(spacing: 11) {
            AppIcon(ding: ding, size: 30)
                .opacity(ding.heard ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ding.isIdentified ? ding.appName : "System sound")
                        .font(Theme.rounded(12.5, .semibold))
                        .foregroundStyle(.white.opacity(ding.heard ? 1 : 0.6))
                        .lineLimit(1)
                    if let site = ding.site {
                        Text(site).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                    }
                }
                Text(ding.summary ?? (ding.heard ? "Made a sound" : "Silent notification"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hover {
                HStack(spacing: 4) {
                    CircleButton(symbol: "arrow.up.right", help: "Go to it") { store.open(ding) }
                    CircleButton(symbol: "bell.slash", help: "Notification settings for this app") {
                        Permissions.openNotificationSettings(for: ding.bundleID)
                    }
                    CircleButton(symbol: "eye.slash", help: "Stop tracking this app") { store.ignore(ding.bundleID) }
                }
                .transition(.opacity)
            } else {
                HStack(spacing: 6) {
                    if ding.silenced == true {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.accent.opacity(0.8))
                            .help("Muted by silent mode")
                    } else if ding.heard {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                            .shadow(color: Theme.accent.opacity(0.8), radius: 3)
                            .help("Made a sound")
                    }
                    Text(shortRelative(ding.date, now: now))
                        .font(Theme.rounded(11, .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(hover ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
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
            EmptyState(symbol: "square.stack", text: "No dings catalogued yet")
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(stats) { stat in
                        CatalogueRow(store: store, stat: stat, now: now) {
                            store.appFilter = stat.bundleID
                            showFeed()
                        }
                    }
                }
            }
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
        HStack(spacing: 11) {
            Image(nsImage: AppResolver.shared.icon(for: stat.bundleID, path: stat.path))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.name).font(Theme.rounded(12.5, .semibold)).foregroundStyle(.white).lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(stat.today)").font(Theme.rounded(11, .bold)).foregroundStyle(Theme.accent)
                    Text("today · \(stat.total) total")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hover {
                HStack(spacing: 4) {
                    CircleButton(symbol: "arrow.up.right", help: "Open app") {
                        if let path = stat.path { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    }
                    CircleButton(symbol: "bell.slash", help: "Notification settings for this app") {
                        Permissions.openNotificationSettings(for: stat.bundleID)
                    }
                    CircleButton(symbol: "eye.slash", help: "Stop tracking this app") { store.ignore(stat.bundleID) }
                }
                .transition(.opacity)
            } else {
                Sparkbars(values: stat.hourly)
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .onTapGesture(perform: select)
        .help("Show only \(stat.name) · last dinged \(relative(stat.last, now: now))")
    }
}

/// Last 24 hours, one bar per hour.
struct Sparkbars: View {
    let values: [Int]
    var body: some View {
        let peak = max(1, values.max() ?? 1)
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(values.indices, id: \.self) { i in
                Capsule()
                    .fill(Theme.brand)
                    .frame(width: 2.5, height: max(4, 20 * CGFloat(values[i]) / CGFloat(peak)))
                    .opacity(values[i] > 0 ? 1 : 0)
            }
        }
        .frame(height: 20, alignment: .bottom)
        .background(alignment: .bottom) {
            Capsule().fill(.white.opacity(0.1)).frame(height: 1)
        }
        .help("Last 24 hours")
    }
}

// MARK: - Permissions

/// Only shows up when something is missing.
struct PermissionCallout: View {
    @ObservedObject var store: DingStore
    var requestAudio: () -> Void

    var body: some View {
        if !store.preciseAudio {
            callout(store.silent ? "Silent mode needs sound access to mute dings"
                                 : "Turn on sound access to hear notification banners",
                    action: "Enable", perform: requestAudio)
        } else if !store.notificationAccess {
            callout("Allow Full Disk Access to see what notifications said", action: "Allow",
                    perform: Permissions.openFullDiskAccessSettings)
        }
    }

    private func callout(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
            Spacer(minLength: 4)
            Button(action: perform) {
                Text(action).font(Theme.rounded(11, .semibold)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Theme.brand))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent.opacity(0.25), lineWidth: 0.75))
    }
}

// MARK: - Bits

/// The app icon's chartreuse bell tile. Wiggles whenever `ringing` changes.
struct BrandMark: View {
    let size: CGFloat
    var ringing: UUID?
    @State private var angle: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(Theme.brand)
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: "bell.and.waves.left.and.right.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .rotationEffect(.degrees(angle), anchor: .top)
            )
            .shadow(color: Theme.deep.opacity(0.45), radius: size * 0.15, y: size * 0.05)
            .modifier(Wiggle(trigger: ringing, angle: $angle))
    }
}

/// An app icon wearing a little chartreuse bell badge, so the capsule still reads as Ding Detective.
struct BadgedIcon: View {
    let ding: Ding
    let size: CGFloat
    var ringing: UUID?
    @State private var angle: Double = 0

    var body: some View {
        AppIcon(ding: ding, size: size)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(Theme.brand)
                    .frame(width: size * 0.42, height: size * 0.42)
                    .overlay(
                        Image(systemName: "bell.fill")
                            .font(.system(size: size * 0.21, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                            .rotationEffect(.degrees(angle), anchor: .top)
                    )
                    .overlay(Circle().strokeBorder(.black.opacity(0.55), lineWidth: 1.5))
                    .offset(x: size * 0.1, y: size * 0.08)
            }
            .modifier(Wiggle(trigger: ringing, angle: $angle))
    }
}

struct Wiggle: ViewModifier {
    let trigger: UUID?
    @Binding var angle: Double
    func body(content: Content) -> some View {
        content.onChange(of: trigger) { _, _ in
            Task { @MainActor in
                for target in [18.0, -14, 10, -6, 3, 0] {
                    withAnimation(.easeInOut(duration: 0.08)) { angle = target }
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        }
    }
}

struct LiveLabel: View {
    let text: String
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.accent).frame(width: 6, height: 6)
                .shadow(color: Theme.accent.opacity(pulse ? 0.9 : 0.2), radius: pulse ? 4 : 1)
                .animation(.easeInOut(duration: 1.4).repeatForever(), value: pulse)
            Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
        .onAppear { pulse = true }
    }
}

/// Speaker button that turns silent mode on and off; lit up while dings are being muted.
struct SilentToggle: View {
    @ObservedObject var store: DingStore
    @State private var hover = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { store.silent.toggle() }
        } label: {
            Image(systemName: store.silent ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(store.silent ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.white.opacity(hover ? 1 : 0.7)))
                .frame(width: 24, height: 24)
                .background(Circle().fill(store.silent ? AnyShapeStyle(Theme.brand)
                                                       : AnyShapeStyle(.white.opacity(hover ? 0.2 : 0.1))))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(store.silent ? "Silent mode is on: dings are muted but still logged. Click to turn it off."
                           : "Silent mode: mute dings but keep logging them")
    }
}

/// Small round button used for collapse / expand and row actions.
struct CircleButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.7))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(hover ? 0.2 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(help)
    }
}

struct Chip: View {
    let title: String
    let symbol: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
                Text(title).font(Theme.rounded(11, .semibold)).lineLimit(1)
            }
            .foregroundStyle(on ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.white.opacity(0.55)))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(on ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.white.opacity(0.06))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct EmptyState: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.white.opacity(0.3))
            Text(text).font(Theme.rounded(12, .medium)).foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppIcon: View {
    let ding: Ding
    let size: CGFloat
    var body: some View {
        if ding.isIdentified {
            Image(nsImage: AppResolver.shared.icon(for: ding.bundleID, path: ding.appPath))
                .resizable().frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(.white.opacity(0.12))
                .frame(width: size * 0.84, height: size * 0.84)
                .overlay(Image(systemName: "waveform").font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8)))
                .frame(width: size, height: size)
        }
    }
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

/// Compact form for tight spots: "now", "12s", "4m", "3h", "Mon".
func shortRelative(_ date: Date, now: Date) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 5 { return "now" }
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86_400 { return "\(s / 3600)h" }
    return date.formatted(.dateTime.weekday(.abbreviated))
}
