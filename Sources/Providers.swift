import Foundation

// MARK: - Claude
//
// Claude Code keeps its OAuth credentials in the login keychain ("Claude Code-credentials"),
// or in ~/.claude/.credentials.json. The access token lives ~8 hours and only the CLI used to
// refresh it, so the usage display went blank whenever `claude` hadn't run in a while. We now refresh
// it ourselves exactly the way the CLI does and write the result back, so both stay in sync.

struct ClaudeCreds {
    var root: [String: Any]

    var oauth: [String: Any] { root["claudeAiOauth"] as? [String: Any] ?? [:] }
    // The CLI blanks these out (rather than deleting the item) when it decides you're logged out.
    var accessToken: String? { (oauth["accessToken"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var refreshToken: String? { (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var clientID: String? { oauth["clientId"] as? String }
    var scopes: [String] { oauth["scopes"] as? [String] ?? [] }
    var plan: String? { oauth["subscriptionType"] as? String }
    var expiresAt: Date? { num(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) } }
    var isExpired: Bool { (expiresAt?.timeIntervalSinceNow ?? 0) < 120 }
}

enum ClaudeStore {
    enum Location { case keychain(account: String), file }

    static let service = "Claude Code-credentials"
    static let file = home.appendingPathComponent(".claude/.credentials.json")
    // Going through /usr/bin/security (like the CLI does) keeps us inside the item's ACL,
    // so there are no keychain prompts and rebuilding the app never breaks access.
    private static let security = "/usr/bin/security"

    static func load() throws -> (ClaudeCreds, Location) {
        let r = runProcess(security, ["find-generic-password", "-s", service, "-w"])
        if r.status == 0, let obj = decode(r.out) {
            return (ClaudeCreds(root: obj), .keychain(account: keychainAccount()))
        }
        if let data = try? Data(contentsOf: file),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (ClaudeCreds(root: obj), .file)
        }
        if r.status != 44 {  // 44 = item not found
            Log.write("claude: keychain read failed (status \(r.status)) \(r.err.prefix(200))")
            throw FetchError.failed("Couldn't read Claude credentials from Keychain")
        }
        throw FetchError.signIn("Not signed in to Claude Code")
    }

    static func save(_ creds: ClaudeCreds, to location: Location) throws {
        let data = try JSONSerialization.data(withJSONObject: creds.root)
        switch location {
        case .file:
            try writeJSONAtomically(creds.root, to: file)
        case .keychain(let account):
            // Same command the CLI uses; -X takes hex so the JSON needs no escaping, and
            // feeding it through `security -i` keeps the secret out of the process list.
            let command = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(data.hex)\"\n"
            let r = command.utf8.count < 4000
                ? runProcess(security, ["-i"], stdin: Data(command.utf8))
                : runProcess(security, ["add-generic-password", "-U", "-a", account, "-s", service, "-X", data.hex])
            // `security -i` can exit 0 even when the command inside fails, so read it back.
            guard r.status == 0, let (stored, _) = try? load(),
                  stored.refreshToken == creds.refreshToken, stored.accessToken == creds.accessToken else {
                Log.write("claude: keychain write failed (status \(r.status)) \(r.err.prefix(200))")
                throw FetchError.failed("Couldn't save refreshed Claude token to Keychain")
            }
        }
    }

    private static func decode(_ out: Data) -> [String: Any]? {
        var text = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.hasPrefix("{"), let raw = Data(hex: text) { text = String(data: raw, encoding: .utf8) ?? "" }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func keychainAccount() -> String {
        let r = runProcess(security, ["find-generic-password", "-s", service])  // attributes only
        let text = (String(data: r.out, encoding: .utf8) ?? "") + r.err
        for line in text.split(separator: "\n") where line.contains("\"acct\"<blob>=\"") {
            if let start = line.range(of: "<blob>=\"")?.upperBound, let end = line.lastIndex(of: "\""), end > start {
                return String(line[start..<end])
            }
        }
        return NSUserName()
    }
}

actor ClaudeProvider {
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let usageURL = "https://api.anthropic.com/api/oauth/usage"

    /// A refresh token the server rejected; don't hammer the endpoint with it again.
    private var deadRefreshToken: String?
    /// Refreshed credentials we couldn't persist yet (the old refresh token is already spent).
    private var unsaved: (ClaudeCreds, ClaudeStore.Location)?

    func fetch() async throws -> Snapshot {
        var creds = try currentCreds().0
        if creds.isExpired { creds = try await refresh(replacing: creds).0 }

        var r = try await usage(creds)
        if r.status == 401 || r.status == 403 {
            Log.write("claude: usage returned \(r.status), refreshing token")
            creds = try await refresh(replacing: creds).0
            r = try await usage(creds)
            if r.status == 401 || r.status == 403 { throw FetchError.signIn("Claude sign-in expired") }
        }
        try requireOK(r)
        guard let obj = r.json as? [String: Any] else { throw FetchError.failed("Unexpected Claude response") }

        let windows: [(String, String)] = [("five_hour", "5-hour"), ("seven_day", "Week"),
                                           ("seven_day_opus", "Opus wk"), ("seven_day_sonnet", "Sonnet wk")]
        let parsed = windows.compactMap { key, label -> UsageWindow? in
            guard let w = obj[key] as? [String: Any], let pct = num(w["utilization"]) else { return nil }
            return UsageWindow(label: label, percent: pct, resetsAt: parseDate(w["resets_at"]))
        }
        return Snapshot(windows: parsed, plan: creds.plan, fetchedAt: Date())
    }

    private func currentCreds() throws -> (ClaudeCreds, ClaudeStore.Location) {
        if let (creds, location) = unsaved {
            do {
                try ClaudeStore.save(creds, to: location)
                unsaved = nil
                Log.write("claude: saved pending refreshed token")
            } catch {}
            return (creds, location)
        }
        let loaded = try ClaudeStore.load()
        guard loaded.0.refreshToken != nil || loaded.0.accessToken != nil else {
            throw FetchError.signIn("Not signed in to Claude Code")
        }
        return loaded
    }

    private func usage(_ creds: ClaudeCreds) async throws -> HTTPResult {
        try await http(Self.usageURL, headers: [
            "Authorization": "Bearer \(creds.accessToken ?? "")",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "Meter/2.0",
        ])
    }

    private func refresh(replacing stale: ClaudeCreds) async throws -> (ClaudeCreds, ClaudeStore.Location) {
        // The CLI may have refreshed in the meantime; its token is as good as ours.
        var (creds, location) = try unsaved ?? ClaudeStore.load()
        if creds.accessToken != stale.accessToken, !creds.isExpired { return (creds, location) }

        guard let refreshToken = creds.refreshToken else { throw FetchError.signIn("Claude sign-in expired") }
        if refreshToken == deadRefreshToken { throw FetchError.signIn("Claude sign-in expired") }

        var body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refreshToken,
                                   "client_id": creds.clientID ?? Self.clientID]
        if !creds.scopes.isEmpty { body["scope"] = creds.scopes.joined(separator: " ") }
        var r = try await http(Self.tokenURL, method: "POST", json: body)
        if r.status == 400, r.errorCode == "invalid_scope" {
            body.removeValue(forKey: "scope")
            r = try await http(Self.tokenURL, method: "POST", json: body)
        }

        guard r.status == 200, let obj = r.json as? [String: Any], let access = obj["access_token"] as? String else {
            Log.write("claude: token refresh failed: HTTP \(r.status) \(r.errorCode)")
            if r.status == 429 { try requireOK(r) }
            // Lost a race with the CLI? Then the keychain already holds a newer token.
            if let (latest, latestLocation) = try? ClaudeStore.load(), latest.refreshToken != refreshToken {
                return (latest, latestLocation)
            }
            if r.status == 400 || r.status == 401 {
                deadRefreshToken = refreshToken
                throw FetchError.signIn("Claude sign-in expired")
            }
            throw FetchError.failed("Claude token refresh failed (HTTP \(r.status))")
        }

        let now = Date().timeIntervalSince1970
        var oauth = creds.oauth
        oauth["accessToken"] = access
        if let newRefresh = obj["refresh_token"] as? String { oauth["refreshToken"] = newRefresh }
        if let expiresIn = num(obj["expires_in"]) { oauth["expiresAt"] = Int64((now + expiresIn) * 1000) }
        if let refreshExpiresIn = num(obj["refresh_token_expires_in"]) {
            oauth["refreshTokenExpiresAt"] = Int64((now + refreshExpiresIn) * 1000)
        }
        if let scope = obj["scope"] as? String { oauth["scopes"] = scope.split(separator: " ").map(String.init) }
        creds.root["claudeAiOauth"] = oauth

        do {
            try ClaudeStore.save(creds, to: location)
            unsaved = nil
            Log.write("claude: token refreshed")
        } catch {
            unsaved = (creds, location)
        }
        deadRefreshToken = nil
        return (creds, location)
    }
}

// MARK: - Codex
//
// Codex (ChatGPT app / codex CLI) keeps ChatGPT OAuth tokens in ~/.codex/auth.json. Same story:
// the access token expires and only Codex itself refreshed it.

actor CodexProvider {
    static let tokenURL = "https://auth.openai.com/oauth/token"
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let usageURL = "https://chatgpt.com/backend-api/wham/usage"

    static var authFile: URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        }
        return home.appendingPathComponent(".codex/auth.json")
    }

    private var deadRefreshToken: String?

    func fetch() async throws -> Snapshot {
        var root = try load()
        if let access = tokens(root)["access_token"] as? String,
           let exp = jwtExpiry(access), exp.timeIntervalSinceNow < 120 {
            root = try await refresh(replacing: root)
        }

        var r = try await usage(root)
        if r.status == 401 || r.status == 403 {
            Log.write("codex: usage returned \(r.status), refreshing token")
            root = try await refresh(replacing: root)
            r = try await usage(root)
            if r.status == 401 || r.status == 403 { throw FetchError.signIn("Codex sign-in expired") }
        }
        try requireOK(r)
        guard let obj = r.json as? [String: Any] else { throw FetchError.failed("Unexpected Codex response") }

        let limits = obj["rate_limit"] as? [String: Any] ?? [:]
        let windows = [("primary_window", "5-hour"), ("secondary_window", "Week")].compactMap { key, fallback -> UsageWindow? in
            guard let w = limits[key] as? [String: Any], let pct = num(w["used_percent"]) else { return nil }
            var reset = parseDate(w["reset_at"])
            if reset == nil, let after = num(w["reset_after_seconds"]) { reset = Date(timeIntervalSinceNow: after) }
            return UsageWindow(label: windowLabel(seconds: num(w["limit_window_seconds"])) ?? fallback,
                               percent: pct, resetsAt: reset)
        }
        return Snapshot(windows: windows, plan: obj["plan_type"] as? String, fetchedAt: Date())
    }

    private func tokens(_ root: [String: Any]) -> [String: Any] { root["tokens"] as? [String: Any] ?? [:] }

    private func load() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: Self.authFile) else { throw FetchError.signIn("Sign in to Codex first") }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.failed("Couldn't parse ~/.codex/auth.json")
        }
        guard tokens(root)["access_token"] is String else { throw FetchError.signIn("Sign in to Codex with ChatGPT first") }
        return root
    }

    private func usage(_ root: [String: Any]) async throws -> HTTPResult {
        let t = tokens(root)
        var headers = ["Authorization": "Bearer \(t["access_token"] as? String ?? "")", "User-Agent": "codex_cli_rs"]
        if let account = t["account_id"] as? String { headers["ChatGPT-Account-Id"] = account }
        return try await http(Self.usageURL, headers: headers)
    }

    private func refresh(replacing stale: [String: Any]) async throws -> [String: Any] {
        var root = try load()
        let staleAccess = tokens(stale)["access_token"] as? String
        if let access = tokens(root)["access_token"] as? String, access != staleAccess,
           (jwtExpiry(access)?.timeIntervalSinceNow ?? 0) > 120 {
            return root
        }
        guard let refreshToken = tokens(root)["refresh_token"] as? String, refreshToken != deadRefreshToken else {
            throw FetchError.signIn("Codex sign-in expired")
        }

        let r = try await http(Self.tokenURL, method: "POST", json: [
            "client_id": Self.clientID, "grant_type": "refresh_token",
            "refresh_token": refreshToken, "scope": "openid profile email",
        ])
        guard r.status == 200, let obj = r.json as? [String: Any], let access = obj["access_token"] as? String else {
            Log.write("codex: token refresh failed: HTTP \(r.status) \(r.errorCode)")
            if r.status == 429 { try requireOK(r) }
            if let latest = try? load(), tokens(latest)["refresh_token"] as? String != refreshToken { return latest }
            if r.status == 400 || r.status == 401 {
                deadRefreshToken = refreshToken
                throw FetchError.signIn("Codex sign-in expired")
            }
            throw FetchError.failed("Codex token refresh failed (HTTP \(r.status))")
        }

        var t = tokens(root)
        t["access_token"] = access
        if let id = obj["id_token"] as? String { t["id_token"] = id }
        if let newRefresh = obj["refresh_token"] as? String { t["refresh_token"] = newRefresh }
        root["tokens"] = t
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        root["last_refresh"] = iso.string(from: Date())
        try writeJSONAtomically(root, to: Self.authFile)
        deadRefreshToken = nil
        Log.write("codex: token refreshed")
        return root
    }
}

// MARK: - API-key plans

struct APIAccount: Codable, Equatable {
    var name: String
    var key: String
}

enum GLMProvider {
    static let usageURL = "https://open.bigmodel.cn/api/monitor/usage/quota/limit"

    static func fetch(_ account: APIAccount) async throws -> Snapshot {
        let r = try await http(usageURL, headers: ["Authorization": account.key, "Accept-Language": "en-US,en"])
        if r.status == 401 { throw FetchError.badKey("Invalid API key (401)") }
        try requireOK(r)
        guard let obj = r.json as? [String: Any] else { throw FetchError.failed("Unexpected GLM response") }
        if num(obj["code"]) == 401 { throw FetchError.badKey("Invalid API key (401)") }
        guard obj["success"] as? Bool != false, let data = obj["data"] as? [String: Any] else {
            throw FetchError.failed((obj["msg"] as? String) ?? "GLM request failed")
        }

        let windows = (data["limits"] as? [[String: Any]] ?? []).compactMap { limit -> UsageWindow? in
            var percent = num(limit["percentage"])
            if percent == nil, let used = num(limit["currentValue"]), let total = num(limit["usage"]), total > 0 {
                percent = used / total * 100
            }
            guard let pct = percent else { return nil }
            let period = periodLabel(unit: num(limit["unit"]), number: num(limit["number"]))
            let label = (limit["type"] as? String) == "TIME_LIMIT" ? "MCP/\(period.short)" : period.long
            return UsageWindow(label: label, percent: pct, resetsAt: parseDate(limit["nextResetTime"]))
        }
        return Snapshot(windows: windows, plan: data["level"] as? String, fetchedAt: Date())
    }

    /// Zhipu's quota units: 3 = hours, 4 = days, 5 = months, 6 = weeks.
    private static func periodLabel(unit: Double?, number: Double?) -> (long: String, short: String) {
        let n = Int(number ?? 1)
        switch Int(unit ?? 0) {
        case 3: return (n == 1 ? "Hour" : "\(n)-hour", "\(n)h")
        case 4: return (n == 1 ? "Day" : "\(n)-day", "day")
        case 5: return (n == 1 ? "Month" : "\(n)-month", "mo")
        case 6: return (n == 1 ? "Week" : "\(n)-week", "wk")
        default: return ("Quota", "quota")
        }
    }
}

enum KimiProvider {
    static let usageURL = "https://api.kimi.com/coding/v1/usages"

    static func fetch(_ account: APIAccount) async throws -> Snapshot {
        let r = try await http(usageURL, headers: ["Authorization": "Bearer \(account.key)"])
        if r.status == 401 { throw FetchError.badKey("Invalid API key (401)") }
        try requireOK(r)
        guard let obj = r.json as? [String: Any] else { throw FetchError.failed("Unexpected Kimi response") }

        var windows: [UsageWindow] = []
        for limit in obj["limits"] as? [[String: Any]] ?? [] {
            guard let (pct, reset) = detail(limit["detail"] as? [String: Any] ?? limit) else { continue }
            let window = limit["window"] as? [String: Any] ?? [:]
            let multiplier: Double
            switch window["timeUnit"] as? String ?? "" {
            case let u where u.contains("SECOND"): multiplier = 1
            case let u where u.contains("HOUR"): multiplier = 3_600
            case let u where u.contains("DAY"): multiplier = 86_400
            default: multiplier = 60
            }
            let label = windowLabel(seconds: num(window["duration"]).map { $0 * multiplier }) ?? "Limit"
            windows.append(UsageWindow(label: label, percent: pct, resetsAt: reset))
        }
        if let usage = obj["usage"] as? [String: Any], let (pct, reset) = detail(usage) {
            windows.append(UsageWindow(label: "Week", percent: pct, resetsAt: reset))
        }
        guard !windows.isEmpty else { throw FetchError.failed("Unexpected Kimi response") }
        return Snapshot(windows: windows, plan: nil, fetchedAt: Date())
    }

    private static func detail(_ d: [String: Any]) -> (Double, Date?)? {
        guard let limit = num(d["limit"]), limit > 0 else { return nil }
        let used = num(d["used"]) ?? (limit - (num(d["remaining"]) ?? limit))
        return (used / limit * 100, parseDate(d["resetTime"] ?? d["reset_time"] ?? d["resetAt"]))
    }
}
