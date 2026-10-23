import AppKit
import ServiceManagement

// MARK: - Sources

enum Kind: String, CaseIterable {
    case claude, codex, glm = "zcoder", kimi

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .glm: return "GLM Coding"
        case .kimi: return "Kimi Code"
        }
    }

    var bundleIDs: [String] {
        switch self {
        case .claude: return ["com.anthropic.claudefordesktop"]
        case .codex: return ["com.openai.codex"]
        case .glm: return ["dev.zcode.app"]
        case .kimi: return ["com.moonshot.kimi", "ai.moonshot.kimi", "com.moonshot.kimi-desktop", "com.moonshot.kimichat"]
        }
    }

    var usagePage: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .glm: return URL(string: "https://bigmodel.cn/usercenter/glm-coding/usage")!
        case .kimi: return URL(string: "https://www.kimi.com/code/console")!
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .glm: return "z.circle"
        case .kimi: return "moon"
        }
    }

    var usesAPIKey: Bool { self == .glm || self == .kimi }
}

struct Source {
    let kind: Kind
    let account: APIAccount?

    var id: String { account.map { "\(kind.rawValue):\($0.name)" } ?? kind.rawValue }
    var title: String { account.map { "\(kind.title) · \($0.name)" } ?? kind.title }
}

enum Accounts {
    static let url = supportDir.appendingPathComponent("accounts.json")

    static func load() -> [String: [APIAccount]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [APIAccount]].self, from: data)) ?? [:]
    }

    static func save(_ accounts: [String: [APIAccount]]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func sources() -> [Source] {
        let accounts = load()
        return [Source(kind: .claude, account: nil), Source(kind: .codex, account: nil)]
            + (accounts[Kind.glm.rawValue] ?? []).map { Source(kind: .glm, account: $0) }
            + (accounts[Kind.kimi.rawValue] ?? []).map { Source(kind: .kimi, account: $0) }
    }
}

final class Fetcher {
    let claude = ClaudeProvider()
    let codex = CodexProvider()

    func fetch(_ source: Source) async throws -> Snapshot {
        switch (source.kind, source.account) {
        case (.claude, _): return try await claude.fetch()
        case (.codex, _): return try await codex.fetch()
        case (.glm, let account?): return try await GLMProvider.fetch(account)
        case (.kimi, let account?): return try await KimiProvider.fetch(account)
        default: throw FetchError.failed("Missing account")
        }
    }
}

enum SnapshotCache {
    static let url = supportDir.appendingPathComponent("cache.json")

    static func load() -> [String: Snapshot] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Snapshot].self, from: data)) ?? [:]
    }

    static func save(_ snapshots: [String: Snapshot]) {
        try? JSONEncoder().encode(snapshots).write(to: url, options: .atomic)
    }
}

struct ProviderState {
    var snapshot: Snapshot?
    var error: FetchError?
    var inFlight = false
    var nextDue = Date.distantPast
    var failures = 0
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let refreshInterval: TimeInterval = 180
    private static let staleAfter: TimeInterval = 15 * 60

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let fetcher = Fetcher()
    private var sources: [Source] = []
    private var states: [String: ProviderState] = [:]
    private var logoCache: [Kind: NSImage] = [:]
    private var appearanceObservation: NSKeyValueObservation?
    private var menuIsOpen = false
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // An older copy (e.g. one launched from a now-deleted build folder) would fight us for the bar.
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.usagebar")
        where other.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            other.terminate()
        }

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        // Redraw when the menu bar flips between light and dark (wallpaper, dark mode).
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateBar() }
        }

        if isDemoMode {
            states = DemoData.states
            DemoBackdrop.showIfRequested()
            if let flag = CommandLine.arguments.firstIndex(of: "--export-bar"), flag + 1 < CommandLine.arguments.count {
                reloadSources()
                exportBarImages(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
                NSApp.terminate(nil)
                return
            }
        } else {
            for (id, snapshot) in SnapshotCache.load() { states[id] = ProviderState(snapshot: snapshot) }
        }
        reloadSources()
        if !isDemoMode { setUpLaunchAtLoginOnce() }

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // After sleep the tokens have usually expired; refresh as soon as the network is back.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleAll(after: 8) }
        }
        Log.write("Meter started")
        tick()
    }

    // MARK: Settings

    private var disabled: Set<String> {
        get { isDemoMode ? [] : Set(UserDefaults.standard.stringArray(forKey: "disabled") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "disabled") }
    }

    private var hidden: Set<String> {
        get { isDemoMode ? [] : Set(UserDefaults.standard.stringArray(forKey: "hiddenInBar") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "hiddenInBar") }
    }

    private var activeSources: [Source] { sources.filter { !disabled.contains($0.id) } }

    private func reloadSources() {
        sources = isDemoMode ? DemoData.sources : Accounts.sources()
        let ids = Set(sources.map(\.id))
        states = states.filter { ids.contains($0.key) }
        updateBar()
        if menuIsOpen { rebuildMenu() }
    }

    // MARK: Fetching

    private func scheduleAll(after delay: TimeInterval) {
        for id in states.keys { states[id]?.nextDue = Date(timeIntervalSinceNow: delay) }
    }

    private func tick(force: Bool = false) {
        guard !isDemoMode else { return }
        for source in activeSources {
            var state = states[source.id] ?? ProviderState()
            if state.inFlight || (!force && Date() < state.nextDue) { continue }
            state.inFlight = true
            states[source.id] = state
            Task { await run(source) }
        }
        if menuIsOpen { rebuildMenu() }
    }

    private func run(_ source: Source) async {
        let result: Result<Snapshot, FetchError>
        do {
            result = .success(try await fetcher.fetch(source))
        } catch let error as FetchError {
            result = .failure(error)
        } catch {
            result = .failure(.failed(error.localizedDescription))
        }

        guard var state = states[source.id] else { return }  // account was removed meanwhile
        state.inFlight = false
        switch result {
        case .success(let snapshot):
            state.snapshot = snapshot
            state.error = nil
            state.failures = 0
            state.nextDue = Date(timeIntervalSinceNow: Self.refreshInterval)
        case .failure(let error):
            state.error = error
            state.failures += 1
            state.nextDue = Date(timeIntervalSinceNow: backoff(error, attempt: state.failures))
            Log.write("\(source.id): \(error.message)")
        }
        states[source.id] = state
        if case .success = result {
            SnapshotCache.save(states.compactMapValues(\.snapshot))
        }
        updateBar()
        if menuIsOpen { rebuildMenu() }
    }

    private func backoff(_ error: FetchError, attempt: Int) -> TimeInterval {
        switch error {
        case .rateLimited(let retryAfter): return max(retryAfter ?? 0, 300)
        // Cheap to re-check: providers skip the network until the stored credentials change.
        case .signIn: return 60
        case .badKey: return 600
        case .failed: return min(60 * pow(2, Double(attempt - 1)), 600)
        }
    }

    // MARK: Menu bar

    private var barStyle: String {
        get { CommandLine.arguments.contains("--rings") ? "ring" : UserDefaults.standard.string(forKey: "barStyle") ?? "number" }
        set { UserDefaults.standard.set(newValue, forKey: "barStyle") }
    }

    /// Monochrome logo mask cut from the provider's app icon, or an SF Symbol if the app isn't installed.
    private func logo(_ kind: Kind) -> NSImage {
        if let cached = logoCache[kind] { return cached }
        let appURL = kind.bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        let image = appURL.flatMap { monochromeLogo(from: NSWorkspace.shared.icon(forFile: $0.path)) }
            ?? NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.title)
            ?? NSImage()
        image.isTemplate = true
        logoCache[kind] = image
        return image
    }

    private func level(_ percent: Double, normal: NSColor = .labelColor) -> NSColor {
        percent >= 90 ? .systemRed : percent >= 70 ? .systemOrange : normal
    }

    private enum BarValue {
        case percent(Double, stale: Bool)
        case attention
        case pending
    }

    private func barValue(for source: Source) -> BarValue {
        let state = states[source.id]
        switch state?.error {
        case .signIn?, .badKey?: return .attention
        default: break
        }
        guard let snapshot = state?.snapshot, let headline = snapshot.headline else {
            return state?.error == nil ? .pending : .attention
        }
        return .percent(headline, stale: Date().timeIntervalSince(snapshot.fetchedAt) > Self.staleAfter)
    }

    /// The whole status item is drawn as one image: monochrome logos in the menu bar's own
    /// foreground colour, numbers without "%", and orange/red only when a limit is close.
    private func updateBar() {
        guard let button = statusItem.button else { return }
        let entries = activeSources.filter { !hidden.contains($0.id) }
        button.title = ""
        button.toolTip = activeSources.map { source -> String in
            switch barValue(for: source) {
            case .percent(let p, _): return "\(source.title): \(Int(p.rounded()))%"
            case .attention: return "\(source.title): \(states[source.id]?.error?.message ?? "needs attention")"
            case .pending: return "\(source.title): updating…"
            }
        }.joined(separator: "\n")
        guard !entries.isEmpty else {
            let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Meter")
            image?.isTemplate = true
            button.image = image
            return
        }

        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.image = barImage(for: entries, dark: dark, rings: barStyle == "ring")
        button.imagePosition = .imageOnly
    }

    private func barImage(for entries: [Source], dark: Bool, rings: Bool) -> NSImage {
        let fg: NSColor = dark ? .white : .black
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let height: CGFloat = 18, gap: CGFloat = 7

        struct Piece { let logo: NSImage; let value: BarValue; let text: NSAttributedString?; let width: CGFloat }
        let pieces: [Piece] = entries.map { source in
            let value = barValue(for: source)
            if rings { return Piece(logo: logo(source.kind), value: value, text: nil, width: 17) }
            let string: String, color: NSColor
            switch value {
            case .percent(let p, let stale):
                string = "\(Int(p.rounded()))"
                color = stale ? fg.withAlphaComponent(0.45) : level(p, normal: fg)
            case .attention: string = "!"; color = .systemOrange
            case .pending: string = "–"; color = fg.withAlphaComponent(0.45)
            }
            let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
            return Piece(logo: logo(source.kind), value: value, text: text, width: 14 + 2 + ceil(text.size().width))
        }
        let width = pieces.reduce(0) { $0 + $1.width } + gap * CGFloat(pieces.count - 1)

        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for piece in pieces {
                if let text = piece.text {
                    drawTinted(piece.logo, in: NSRect(x: x, y: (height - 14) / 2, width: 14, height: 14), color: fg)
                    let size = text.size()
                    text.draw(at: NSPoint(x: x + 16, y: (height - size.height) / 2))
                } else {
                    let center = NSPoint(x: x + 8.5, y: height / 2)
                    let track = NSBezierPath()
                    track.appendArc(withCenter: center, radius: 7.6, startAngle: 0, endAngle: 360)
                    track.lineWidth = 1.6
                    if case .attention = piece.value { NSColor.systemOrange.setStroke() } else { fg.withAlphaComponent(0.25).setStroke() }
                    track.stroke()
                    if case .percent(let p, let stale) = piece.value, p > 0 {
                        let arc = NSBezierPath()
                        arc.appendArc(withCenter: center, radius: 7.6, startAngle: 90,
                                      endAngle: 90 - 360 * min(p, 100) / 100, clockwise: true)
                        arc.lineWidth = 1.6
                        arc.lineCapStyle = .round
                        (stale ? fg.withAlphaComponent(0.45) : self.level(p, normal: fg)).setStroke()
                        arc.stroke()
                    }
                    drawTinted(piece.logo, in: NSRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9), color: fg)
                }
                x += piece.width + gap
            }
            return true
        }
    }

    /// `--demo --export-bar <dir>`: write the status item in both styles and appearances at 4× for docs.
    private func exportBarImages(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, dark, rings) in [("numbers-dark", true, false), ("rings-dark", true, true),
                                    ("numbers-light", false, false), ("rings-light", false, true)] {
            let image = barImage(for: activeSources, dark: dark, rings: rings)
            let scale: CGFloat = 4
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale),
                                             pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { continue }
            rep.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        // Opening the menu is a good moment to catch up on anything that's a minute old.
        for source in activeSources {
            guard let state = states[source.id], !state.inFlight else { continue }
            if case .rateLimited? = state.error { continue }
            if case .badKey? = state.error { continue }
            if let fetched = state.snapshot?.fetchedAt, Date().timeIntervalSince(fetched) < 60, state.error == nil { continue }
            states[source.id]?.nextDue = .distantPast
        }
        menu.minimumWidth = 0
        tick()
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        menu.minimumWidth = 0
    }

    private func item(_ title: String, _ action: Selector?, key: String = "", represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = represented
        return item
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let active = activeSources
        if active.isEmpty {
            let empty = item("No plans connected", nil)
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for (index, source) in active.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            addSection(for: source)
        }
        menu.addItem(.separator())
        menu.addItem(othersMenu())
        menu.addItem(.separator())
        menu.addItem(buttonsItem)
        // While open, the menu may grow but never shrink, so refreshes can't make it jump narrower.
        if menuIsOpen { menu.minimumWidth = max(menu.minimumWidth, menu.size.width) }
    }

    private func addSection(for source: Source) {
        let state = states[source.id] ?? ProviderState()

        // Header: name, then plan and freshness in grey.
        var detail: [String] = []
        if let plan = state.snapshot?.plan, !plan.isEmpty { detail.append(plan.capitalized) }
        // No transient "updating…" here: it's wider than the age text and made the open menu jump in width.
        if let fetched = state.snapshot?.fetchedAt { detail.append(ago(fetched)) }
        let header = NSMutableAttributedString(string: source.title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        if !detail.isEmpty {
            header.append(NSAttributedString(string: "  " + detail.joined(separator: " · "), attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let headerItem = item("", #selector(openApp(_:)), represented: source.id)
        headerItem.attributedTitle = header
        headerItem.toolTip = installedApp(source.kind) == nil ? "Open \(source.kind.usagePage.absoluteString)" : "Open \(source.kind.title)"
        menu.addItem(headerItem)

        let rowFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 50), NSTextTab(textAlignment: .left, location: 132)]
        for window in state.snapshot?.windows ?? [] {
            let row = NSMutableAttributedString(string: "\(shortLabel(window.label))\t", attributes: [
                .font: rowFont, .paragraphStyle: paragraph, .foregroundColor: NSColor.secondaryLabelColor])
            let bar = NSTextAttachment()
            bar.image = progressImage(window.percent)
            bar.bounds = CGRect(x: 0, y: (rowFont.capHeight - 5) / 2, width: 40, height: 5)
            row.append(NSAttributedString(attachment: bar))
            row.append(NSAttributedString(string: " \(Int(window.percent.rounded()))%\t", attributes: [
                .font: rowFont, .paragraphStyle: paragraph, .foregroundColor: level(window.percent)]))
            row.append(NSAttributedString(string: resetText(window.resetsAt), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .paragraphStyle: paragraph,
                .foregroundColor: NSColor.tertiaryLabelColor]))
            let rowItem = item("", #selector(openPage(_:)), represented: source.id)
            rowItem.attributedTitle = row
            rowItem.toolTip = "Usage details: \(source.kind.usagePage.absoluteString)"
            menu.addItem(rowItem)
        }

        if let error = state.error {
            var text = "⚠︎ \(error.message)"
            if state.snapshot != nil { text += " (showing last data)" }
            let errorItem = item("", nil)
            errorItem.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemOrange])
            menu.addItem(errorItem)
            if let fix = fixItem(for: source, error: error) { menu.addItem(fix) }
        }
    }

    private func fixItem(for source: Source, error: FetchError) -> NSMenuItem? {
        switch (source.kind, error) {
        case (.claude, .signIn): return item("Sign In Again…", #selector(signInClaude))
        case (.codex, .signIn): return item("Sign In Again…", #selector(signInCodex))
        case (_, .badKey): return item("Change API Key…", #selector(changeKey(_:)), represented: source.id)
        default: return nil
        }
    }

    private func othersMenu() -> NSMenuItem {
        let parent = item("Others", nil)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(accountsMenu())
        submenu.addItem(togglesMenu(title: "Providers", selector: #selector(toggleEnabled(_:)), isOn: { !self.disabled.contains($0.id) }, among: sources))
        submenu.addItem(togglesMenu(title: "Show in Menu Bar", selector: #selector(toggleShown(_:)), isOn: { !self.hidden.contains($0.id) }, among: activeSources))

        let style = item("Menu Bar Style", nil)
        let styles = NSMenu()
        for (title, value) in [("Numbers", "number"), ("Rings", "ring")] {
            let option = item(title, #selector(setBarStyle(_:)), represented: value)
            option.state = barStyle == value ? .on : .off
            styles.addItem(option)
        }
        style.submenu = styles
        submenu.addItem(style)

        submenu.addItem(.separator())
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        submenu.addItem(login)
        submenu.addItem(item("Open Log", #selector(openLog)))
        parent.submenu = submenu
        return parent
    }

    /// Refresh and Quit as two side-by-side glass buttons pinned to the bottom of the menu.
    private lazy var buttonsItem: NSMenuItem = {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 42))
        view.autoresizingMask = [.width]
        let stack = NSStackView(views: [
            glassButton("Refresh", symbol: "arrow.clockwise", action: #selector(refreshNow)),
            glassButton("Quit", symbol: "power", action: #selector(quit)),
        ])
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
        ])
        let item = NSMenuItem()
        item.view = view
        return item
    }()

    private func glassButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage()
        let button = NSButton(title: title, image: image, target: self, action: action)
        button.imagePosition = .imageLeading
        button.controlSize = .large
        button.contentTintColor = .labelColor
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
        } else {
            button.bezelStyle = .rounded
        }
        return button
    }

    private func togglesMenu(title: String, selector: Selector, isOn: (Source) -> Bool, among list: [Source]) -> NSMenuItem {
        let parent = item(title, nil)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for source in list {
            let toggle = item(source.title, selector, represented: source.id)
            toggle.state = isOn(source) ? .on : .off
            submenu.addItem(toggle)
        }
        parent.submenu = submenu
        return parent
    }

    private func accountsMenu() -> NSMenuItem {
        let parent = item("Accounts", nil)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(item("Add GLM Coding Plan Account…", #selector(addAccount(_:)), represented: Kind.glm.rawValue))
        submenu.addItem(item("Add Kimi Code Account…", #selector(addAccount(_:)), represented: Kind.kimi.rawValue))
        let keyed = sources.filter { $0.kind.usesAPIKey }
        if !keyed.isEmpty { submenu.addItem(.separator()) }
        for source in keyed {
            let accountItem = item(source.title, nil)
            let actions = NSMenu()
            actions.addItem(item("Rename…", #selector(renameAccount(_:)), represented: source.id))
            actions.addItem(item("Change API Key…", #selector(changeKey(_:)), represented: source.id))
            actions.addItem(item("Delete…", #selector(deleteAccount(_:)), represented: source.id))
            accountItem.submenu = actions
            submenu.addItem(accountItem)
        }
        parent.submenu = submenu
        return parent
    }

    private func progressImage(_ percent: Double) -> NSImage {
        let color: NSColor = percent >= 90 ? .systemRed : percent >= 70 ? .systemOrange : .labelColor
        return NSImage(size: NSSize(width: 40, height: 5), flipped: false) { rect in
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5).fill()
            if percent > 0 {
                color.setFill()
                let width = max(rect.height, rect.width * min(percent, 100) / 100)
                NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: rect.height), xRadius: 2.5, yRadius: 2.5).fill()
            }
            return true
        }
    }

    private func shortLabel(_ label: String) -> String {
        switch label {
        case "Week": return "Week"
        case "Opus wk": return "Opus"
        case "Sonnet wk": return "Sonnet"
        default:
            if label.hasPrefix("MCP") { return "MCP" }
            for (suffix, short) in [("-hour", "h"), ("-day", "d"), ("-week", "w"), ("-month", "mo"), ("-min", "m")]
            where label.hasSuffix(suffix) {
                return label.dropLast(suffix.count) + short
            }
            return label
        }
    }

    /// "42m", "3h 10m", "Fri 14:00" — when the window resets.
    private func resetText(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h \(Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60))m" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: date)
    }

    private func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    // MARK: Actions

    private func source(_ sender: NSMenuItem) -> Source? {
        sources.first { $0.id == sender.representedObject as? String }
    }

    @objc private func refreshNow() { tick(force: true) }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func setBarStyle(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? String else { return }
        barStyle = style
        updateBar()
    }

    @objc private func openPage(_ sender: NSMenuItem) {
        if let source = source(sender) { NSWorkspace.shared.open(source.kind.usagePage) }
    }

    private func installedApp(_ kind: Kind) -> URL? {
        kind.bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    /// Header click: open the provider's own app, or its web console when the app isn't installed.
    @objc private func openApp(_ sender: NSMenuItem) {
        guard let source = source(sender) else { return }
        if let app = installedApp(source.kind) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(source.kind.usagePage)
        }
    }

    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if disabled.contains(id) { disabled.remove(id) } else { disabled.insert(id) }
        updateBar()
        tick()
    }

    @objc private func toggleShown(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) }
        updateBar()
    }

    @objc private func signInClaude() {
        let candidates = ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.claude/local/claude"]
            .map { NSString(string: $0).expandingTildeInPath }
        let binary = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "claude"
        runInTerminal(name: "claude-login", command: "'\(binary)' auth login")
        scheduleAll(after: 20)
    }

    @objc private func signInCodex() {
        var candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex"]
            .map { NSString(string: $0).expandingTildeInPath }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            candidates.append(app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex").path)
        }
        if let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            runInTerminal(name: "codex-login", command: "'\(binary)' login")
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
        scheduleAll(after: 20)
    }

    private func runInTerminal(name: String, command: String) {
        let script = supportDir.appendingPathComponent("\(name).command")
        let body = "#!/bin/bash\n\(command)\necho\necho 'Done — Meter will pick this up within a minute. You can close this window.'\n"
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert("Couldn't change Launch at Login",
                      "Move Meter to the Applications folder and try again, or add it in System Settings › General › Login Items.")
        }
    }

    private func setUpLaunchAtLoginOnce() {
        // The UsageBar → Meter rename moved the bundle, so the old login item points nowhere; register once more.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didSetUpLaunchAtLogin") || !defaults.bool(forKey: "didRegisterMeterLoginItem") {
            try? SMAppService.mainApp.register()
            defaults.set(true, forKey: "didSetUpLaunchAtLogin")
            defaults.set(true, forKey: "didRegisterMeterLoginItem")
        }
    }

    // MARK: Accounts

    @objc private func addAccount(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = Kind(rawValue: raw) else { return }
        let info = kind == .glm
            ? "Get your GLM Coding Plan API key at open.bigmodel.cn › API Keys. It is stored only on this Mac."
            : "Create a Kimi Code API key (starts with sk-kimi-) at kimi.com/code/console. It is stored only on this Mac."
        guard let values = prompt("Add \(kind.title) Account", info, fields: [
            ("Account name (e.g. Personal / Work)", "", false), ("API key", "", true)]) else { return }
        guard let key = validKey(values[1], kind: kind) else { return }

        var accounts = Accounts.load()
        var list = accounts[kind.rawValue] ?? []
        var name = values[0].isEmpty ? "Default" : values[0]
        let base = name
        var n = 2
        while list.contains(where: { $0.name == name }) { name = "\(base) \(n)"; n += 1 }
        list.append(APIAccount(name: name, key: key))
        accounts[kind.rawValue] = list
        Accounts.save(accounts)
        reloadSources()
        tick()
    }

    @objc private func renameAccount(_ sender: NSMenuItem) {
        guard let source = source(sender), var account = source.account else { return }
        guard let values = prompt("Rename \"\(account.name)\"", "", fields: [("Account name", account.name, false)]),
              !values[0].isEmpty, values[0] != account.name else { return }
        let oldID = source.id
        account.name = values[0]
        guard update(source, with: account) else { return }
        states[Source(kind: source.kind, account: account).id] = states[oldID]
        reloadSources()
    }

    @objc private func changeKey(_ sender: NSMenuItem) {
        guard let source = source(sender), var account = source.account else { return }
        guard let values = prompt("Change API Key for \"\(account.name)\"", "", fields: [("API key", "", true)]),
              let key = validKey(values[0], kind: source.kind) else { return }
        account.key = key
        guard update(source, with: account) else { return }
        states[source.id]?.error = nil
        states[source.id]?.nextDue = .distantPast
        reloadSources()
        tick()
    }

    @objc private func deleteAccount(_ sender: NSMenuItem) {
        guard let source = source(sender), let account = source.account else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Delete account \"\(account.name)\"?"
        alert.informativeText = "This only removes it from Meter; your \(source.kind.title) account is not affected."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var accounts = Accounts.load()
        accounts[source.kind.rawValue]?.removeAll { $0 == account }
        Accounts.save(accounts)
        reloadSources()
        SnapshotCache.save(states.compactMapValues(\.snapshot))
    }

    private func update(_ source: Source, with account: APIAccount) -> Bool {
        guard let old = source.account else { return false }
        var accounts = Accounts.load()
        guard let index = accounts[source.kind.rawValue]?.firstIndex(of: old) else { return false }
        if account.name != old.name, accounts[source.kind.rawValue]!.contains(where: { $0.name == account.name }) {
            showAlert("An account named \"\(account.name)\" already exists", "")
            return false
        }
        accounts[source.kind.rawValue]![index] = account
        Accounts.save(accounts)
        return true
    }

    private func validKey(_ key: String, kind: Kind) -> String? {
        if key.isEmpty { return nil }
        if kind == .kimi, !key.hasPrefix("sk-kimi-") {
            showAlert("Not a Kimi Code key (needs sk-kimi-…)", "Create one at kimi.com/code/console.")
            return nil
        }
        return key
    }

    private func prompt(_ title: String, _ info: String, fields: [(placeholder: String, value: String, secure: Bool)]) -> [String]? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let rowHeight: CGFloat = 30
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: rowHeight * CGFloat(fields.count)))
        let inputs: [NSTextField] = fields.enumerated().map { index, field in
            let input = field.secure ? NSSecureTextField() : NSTextField()
            input.frame = NSRect(x: 0, y: rowHeight * CGFloat(fields.count - 1 - index) + 3, width: 300, height: 24)
            input.placeholderString = field.placeholder
            input.stringValue = field.value
            container.addSubview(input)
            return input
        }
        alert.accessoryView = container
        alert.window.initialFirstResponder = inputs.first
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return inputs.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func showAlert(_ title: String, _ info: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.runModal()
    }
}
