import AppKit

if isCheckMode {
    // `Meter --check`: fetch every source once and print the result (never the credentials).
    Task.detached {
        let fetcher = Fetcher()
        for source in Accounts.sources() {
            do {
                let snapshot = try await fetcher.fetch(source)
                let windows = snapshot.windows.map { "\($0.label) \(Int($0.percent.rounded()))%" }.joined(separator: ", ")
                print("\(source.title) [\(snapshot.plan ?? "-")]: \(windows.isEmpty ? "no windows" : windows)")
            } catch let error as FetchError {
                print("\(source.title): ERROR \(error.message)")
            } catch {
                print("\(source.title): ERROR \(error)")
            }
        }
        exit(0)
    }
    dispatchMain()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
