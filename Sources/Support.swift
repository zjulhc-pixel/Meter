import Foundation

// MARK: - Paths & logging

let home = FileManager.default.homeDirectoryForCurrentUser

let supportDir: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let url = base.appendingPathComponent("Meter", isDirectory: true)
    // Carry over accounts and cache from when the app was called UsageBar.
    let legacy = base.appendingPathComponent("UsageBar", isDirectory: true)
    if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: legacy.path) {
        try? FileManager.default.moveItem(at: legacy, to: url)
    }
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    return url
}()

let isCheckMode = CommandLine.arguments.contains("--check")

/// Append-only diagnostics log. Never pass tokens or keys in here.
enum Log {
    static let url = home.appendingPathComponent("Library/Logs/Meter.log")
    private static let lock = NSLock()

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let data = Data(line.utf8)
        lock.lock(); defer { lock.unlock() }
        if isCheckMode { FileHandle.standardError.write(data) }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Model

struct UsageWindow: Codable {
    let label: String
    let percent: Double
    let resetsAt: Date?
}

struct Snapshot: Codable {
    let windows: [UsageWindow]
    let plan: String?
    let fetchedAt: Date

    /// The window closest to its limit is the one that actually blocks you.
    var headline: Double? { windows.map(\.percent).max() }
}

enum FetchError: Error {
    /// The user has to sign in again; retrying with the same credentials is pointless.
    case signIn(String)
    case badKey(String)
    case rateLimited(TimeInterval?)
    case failed(String)

    var message: String {
        switch self {
        case .signIn(let m), .badKey(let m), .failed(let m): return m
        case .rateLimited: return "Rate limited — retrying later"
        }
    }
}

// MARK: - HTTP

struct HTTPResult {
    let status: Int
    let data: Data
    let response: HTTPURLResponse

    var json: Any? { try? JSONSerialization.jsonObject(with: data) }

    /// The OAuth-style `error` code of an error body, safe to log.
    var errorCode: String {
        guard let obj = json as? [String: Any] else { return "" }
        if let s = obj["error"] as? String { return s }
        if let e = obj["error"] as? [String: Any] { return (e["code"] as? String) ?? (e["type"] as? String) ?? "" }
        return ""
    }
}

private let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 20
    config.timeoutIntervalForResource = 40
    return URLSession(configuration: config)
}()

func http(_ url: String, method: String = "GET", headers: [String: String] = [:],
          json body: [String: Any]? = nil) async throws -> HTTPResult {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Meter/2.0", forHTTPHeaderField: "User-Agent")
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    if let body {
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    do {
        let (data, response) = try await session.data(for: request)
        return HTTPResult(status: (response as! HTTPURLResponse).statusCode, data: data,
                          response: response as! HTTPURLResponse)
    } catch {
        throw FetchError.failed("Network error: \(error.localizedDescription)")
    }
}

/// Turns 429 / non-2xx into errors. Call after handling provider-specific auth statuses.
func requireOK(_ r: HTTPResult) throws {
    if r.status == 429 {
        throw FetchError.rateLimited(r.response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
    }
    guard (200..<300).contains(r.status) else { throw FetchError.failed("HTTP \(r.status)") }
}

// MARK: - JSON helpers

func num(_ value: Any?) -> Double? {
    switch value {
    case let n as NSNumber: return n.doubleValue
    case let s as String: return Double(s)
    default: return nil
    }
}

func parseDate(_ value: Any?) -> Date? {
    if let s = value as? String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
    }
    if let n = num(value), n > 0 { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
    return nil
}

/// "5-hour", "Week", … from a window length in seconds.
func windowLabel(seconds: Double?) -> String? {
    guard let s = seconds, s > 0 else { return nil }
    if s == 604_800 { return "Week" }
    if s.truncatingRemainder(dividingBy: 86_400) == 0 { return "\(Int(s / 86_400))-day" }
    if s.truncatingRemainder(dividingBy: 3_600) == 0 { return "\(Int(s / 3_600))-hour" }
    return "\(Int(s / 60))-min"
}

func jwtExpiry(_ token: String) -> Date? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    guard let data = Data(base64Encoded: s),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let exp = num(obj["exp"]) else { return nil }
    return Date(timeIntervalSince1970: exp)
}

/// Writes JSON via a temp file + rename so a crash never leaves a half-written credentials file.
func writeJSONAtomically(_ obj: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).meter-tmp")
    try data.write(to: tmp)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
    guard rename(tmp.path, url.path) == 0 else {
        try? FileManager.default.removeItem(at: tmp)
        throw FetchError.failed("Couldn't write \(url.lastPathComponent)")
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<j], radix: 16) else { return nil }
            data.append(byte)
            i = j
        }
        self = data
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Subprocesses

@discardableResult
func runProcess(_ path: String, _ args: [String], stdin: Data? = nil) -> (status: Int32, out: Data, err: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let out = Pipe(), err = Pipe(), input = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = stdin == nil ? FileHandle.nullDevice : input
    do { try process.run() } catch { return (-1, Data(), "\(error)") }
    if let stdin {
        input.fileHandleForWriting.write(stdin)
        try? input.fileHandleForWriting.close()
    }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, outData, String(data: errData, encoding: .utf8) ?? "")
}
