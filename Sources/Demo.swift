import AppKit

let isDemoMode = CommandLine.arguments.contains("--demo")

/// `--backdrop` (with `--demo`): a clean full-screen gradient behind the menu so its glass
/// blurs something tidy instead of whatever windows are open. Clicks pass straight through.
@MainActor
enum DemoBackdrop {
    private static var window: NSWindow?

    static func showIfRequested() {
        guard isDemoMode, CommandLine.arguments.contains("--backdrop"), let screen = NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.ignoresMouseEvents = true
        window.contentView = NSImageView(image: NSImage(size: screen.frame.size, flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.83, green: 0.80, blue: 0.97, alpha: 1),
                                NSColor(srgbRed: 0.62, green: 0.56, blue: 0.92, alpha: 1),
                                NSColor(srgbRed: 0.36, green: 0.30, blue: 0.72, alpha: 1)])!
                .draw(in: rect, angle: -35)
            for (x, y, r, color) in [(0.78, 0.92, 0.45, NSColor.white.withAlphaComponent(0.55)),
                                     (0.15, 0.25, 0.5, NSColor(srgbRed: 0.47, green: 0.36, blue: 1, alpha: 0.35)),
                                     (0.9, 0.2, 0.35, NSColor(srgbRed: 0.85, green: 0.45, blue: 1, alpha: 0.25))] {
                let center = NSPoint(x: rect.width * x, y: rect.height * y)
                NSGradient(colors: [color, color.withAlphaComponent(0)])!
                    .draw(fromCenter: center, radius: 0, toCenter: center, radius: rect.width * r, options: [])
            }
            return true
        })
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        self.window = window
    }
}

/// `Meter --demo`: fixed sample usage for screenshots. No network, no settings or cache writes.
enum DemoData {
    static let sources: [Source] = [
        Source(kind: .claude, account: nil),
        Source(kind: .codex, account: nil),
        Source(kind: .glm, account: APIAccount(name: "Work", key: "")),
        Source(kind: .kimi, account: APIAccount(name: "Personal", key: "")),
    ]

    static var states: [String: ProviderState] {
        let now = Date()
        func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3_600) }
        func snapshot(_ plan: String?, _ windows: [(String, Double, Double)]) -> ProviderState {
            ProviderState(snapshot: Snapshot(windows: windows.map { UsageWindow(label: $0.0, percent: $0.1, resetsAt: at($0.2)) },
                                             plan: plan, fetchedAt: now))
        }
        return [
            sources[0].id: snapshot("max", [("5-hour", 42, 2.3), ("Week", 84, 52), ("Sonnet wk", 35, 52)]),
            sources[1].id: snapshot("plus", [("5-hour", 18, 3.1), ("Week", 54, 97)]),
            sources[2].id: snapshot("pro", [("5-hour", 9, 4.2), ("Week", 23, 121), ("MCP/mo", 4, 400)]),
            sources[3].id: snapshot(nil, [("5-hour", 96, 0.7), ("Week", 60, 75)]),
        ]
    }
}
