import Foundation
import CSQLite
import LinkAllShared

public enum RecordKind: String, Codable, CaseIterable, Sendable {
    case typing, passthrough, voice, enhancement, activity, screenshot, bookmark
    public var title: String {
        switch self {
        case .typing: return "打字"
        case .passthrough: return "直通输入"
        case .voice: return "语音"
        case .enhancement: return "AI 整理"
        case .activity: return "桌面活动"
        case .screenshot: return "屏幕片段"
        case .bookmark: return "重要时刻"
        }
    }
}
public struct HistoryRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID = UUID()
    public var date: Date = Date()
    public var ended: Date = Date()
    public var kind: RecordKind
    public var app: String
    public var appName: String
    public var window: String
    public var original: String
    public var result: String = ""
    public var delivered: String = ""
    public var status: String
    public var note: String = ""
    public var starred: Bool = false
    public var image: String? = nil
    // Missing on legacy records. Image reuse and successful OCR reuse are tracked separately.
    public var screenshotFingerprint: String? = nil
    public var screenshotOCRComplete: Bool? = nil
    public var screenText: ScreenTextSnapshot? = nil
    public init(kind: RecordKind, app: String = "", appName: String = "", window: String = "", original: String = "", status: String = "已记录") {
        self.kind = kind; self.app = app; self.appName = appName; self.window = window
        self.original = original; self.status = status
    }
    public var searchable: String { [original, result, delivered, note, window, appName, app, kind.title].joined(separator: "\n") }
    public var displayText: String { !delivered.isEmpty ? delivered : (!result.isEmpty ? result : (!original.isEmpty ? original : window)) }
}
public struct HistorySettings: Codable, Equatable, Sendable {
    public var paused = false
    public var input = true
    public var desktop = true
    public var screenshots = false
    public var screenshotSeconds: Double = 20
    public var retentionDays = 30
    public var maxImageMB = 102400
    public var excludedApps = ["com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7"]
    public var petVisible = true
    public var petName = "糯米"
    public var petStyle = "cat"
    public var petColor = "cream"
    public var petAccessory = "scarf"
    public var petSize: Double = 150
    public var petImage = ""
    public init() {}
    public func allows(_ kind: RecordKind, app: String) -> Bool {
        !paused && !excludedApps.contains(app) && (kind != .screenshot || screenshots) && (kind == .bookmark || ([.typing, .passthrough, .voice, .enhancement].contains(kind) ? input : desktop))
    }
}
public enum HistoryPaths {
    public static var root: URL { LinkAllIdentity.dataRoot.appendingPathComponent("History", isDirectory: true) }
}
public struct HistoryFailure: Error, LocalizedError {
    public let code: Int32
    public var errorDescription: String? { "记录数据库操作失败（\(code)），请检查磁盘空间与目录权限。" }
}
/// Every connection owns a serial queue; WAL allows the input method and companion to work independently.
public final class HistoryStore: @unchecked Sendable {
    public let directory: URL
    public var imageDirectory: URL { directory.appendingPathComponent("Screenshots", isDirectory: true) }
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "work.yiliu.history.database", qos: .utility)
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(directory: URL = HistoryPaths.root) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("history.sqlite").path
        let status = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK else { throw HistoryFailure(code: status) }
        sqlite3_busy_timeout(db, 2000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, date REAL NOT NULL, kind TEXT NOT NULL, app TEXT NOT NULL, starred INTEGER NOT NULL, search TEXT NOT NULL, data BLOB NOT NULL); CREATE INDEX IF NOT EXISTS records_date ON records(date DESC); CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY, data BLOB NOT NULL);")
        try execute("CREATE INDEX IF NOT EXISTS records_image ON records(json_extract(data,'$.image')); CREATE INDEX IF NOT EXISTS records_screenshot_fingerprint ON records(json_extract(data,'$.screenshotFingerprint'), date DESC);")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw HistoryFailure(code: code) }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &value, nil)
        guard code == SQLITE_OK, let value else { throw HistoryFailure(code: code) }; return value
    }
    private func bind(_ text: String, _ index: Int32, _ stmt: OpaquePointer) { sqlite3_bind_text(stmt, index, text, -1, transient) }
    private func bind(_ data: Data, _ index: Int32, _ stmt: OpaquePointer) { _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(data.count), transient) } }
    private func finish(_ stmt: OpaquePointer) throws { let code = sqlite3_step(stmt); guard code == SQLITE_DONE else { throw HistoryFailure(code: code) } }
    private func blob(_ stmt: OpaquePointer, _ column: Int32) -> Data { Data(bytes: sqlite3_column_blob(stmt, column), count: Int(sqlite3_column_bytes(stmt, column))) }
    public func settings() throws -> HistorySettings { try queue.sync {
        let s = try statement("SELECT data FROM settings WHERE id=1"); defer { sqlite3_finalize(s) }
        if sqlite3_step(s) == SQLITE_ROW { return try JSONDecoder().decode(HistorySettings.self, from: blob(s, 0)) }
        return HistorySettings()
    } }
    public func saveSettings(_ value: HistorySettings) throws { try queue.sync {
        let s = try statement("INSERT INTO settings VALUES (1,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data"); defer { sqlite3_finalize(s) }
        bind(try JSONEncoder().encode(value), 1, s); try finish(s)
    } }
    private func write(_ record: HistoryRecord, updateOnly: Bool) throws {
        let sql = updateOnly ? "UPDATE records SET date=?,kind=?,app=?,starred=?,search=?,data=? WHERE id=?" : "INSERT OR IGNORE INTO records(date,kind,app,starred,search,data,id) VALUES(?,?,?,?,?,?,?)"
        let s = try statement(sql); defer { sqlite3_finalize(s) }
        sqlite3_bind_double(s, 1, record.date.timeIntervalSince1970); bind(record.kind.rawValue, 2, s); bind(record.app, 3, s)
        sqlite3_bind_int(s, 4, record.starred ? 1 : 0); bind(record.searchable, 5, s); bind(try JSONEncoder().encode(record), 6, s); bind(record.id.uuidString, 7, s)
        try finish(s)
    }
    public func insert(_ record: HistoryRecord) throws { try queue.sync { try write(record, updateOnly: false) } }
    /// Persistent lookup, with no in-memory OCR cache to outlive deletion or image retention.
    public func reusableScreenshot(fingerprint: String) throws -> HistoryRecord? { try queue.sync {
        try reusableScreenshotOnQueue(fingerprint: fingerprint)
    } }
    /// Read by identity so deleted/expired records cannot supply incremental OCR.
    public func reusableScreenText(id: UUID) throws -> ScreenTextSnapshot? { try queue.sync {
        try reusableScreenTextOnQueue(id: id)
    } }
    private func reusableScreenTextOnQueue(id: UUID) throws -> ScreenTextSnapshot? {
        let s = try statement("SELECT data FROM records WHERE id=? AND kind='screenshot'")
        defer { sqlite3_finalize(s) }; bind(id.uuidString, 1, s)
        let code = sqlite3_step(s)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw HistoryFailure(code: code) }
        let record = try JSONDecoder().decode(HistoryRecord.self, from: blob(s, 0))
        guard let url = imageURL(record.image), FileManager.default.isReadableFile(atPath: url.path),
              record.screenText?.version == ScreenTextSnapshot.currentVersion else { return nil }
        return record.screenText
    }
    private func reusableScreenshotOnQueue(fingerprint: String, requiringOCR: Bool = true) throws -> HistoryRecord? {
        let s = try statement("SELECT data FROM records WHERE json_extract(data,'$.screenshotFingerprint')=? AND kind='screenshot' AND (?=0 OR json_extract(data,'$.screenshotOCRComplete')=1) ORDER BY date DESC")
        defer { sqlite3_finalize(s) }; bind(fingerprint, 1, s); sqlite3_bind_int(s, 2, requiringOCR ? 1 : 0)
        while true {
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW else { throw HistoryFailure(code: code) }
            let record = try JSONDecoder().decode(HistoryRecord.self, from: blob(s, 0))
            if let url = imageURL(record.image), FileManager.default.isReadableFile(atPath: url.path) { return record }
        }
    }
    /// Image references, record insertion and deletion share the same serialized transaction boundary.
    /// A nil JPEG means OCR/image reuse was selected; if that source disappeared, drop the late result.
    public func saveScreenshot(_ incoming: HistoryRecord, jpeg: Data?, continuing previousID: UUID? = nil, reusedOCRSource: UUID? = nil) throws -> HistoryRecord? { try queue.sync {
        precondition(incoming.kind == .screenshot)
        try execute("BEGIN IMMEDIATE")
        var created: URL?
        do {
            if let reusedOCRSource, try reusableScreenTextOnQueue(id: reusedOCRSource) == nil {
                try execute("COMMIT"); return nil
            }
            let reused = try incoming.screenshotFingerprint.flatMap { try reusableScreenshotOnQueue(fingerprint: $0, requiringOCR: jpeg == nil) }
            guard jpeg != nil || reused != nil else { try execute("COMMIT"); return nil }
            var record = incoming
            if let previousID, incoming.screenshotFingerprint != nil {
                let s = try statement("SELECT data FROM records WHERE id=?")
                bind(previousID.uuidString, 1, s)
                let code = sqlite3_step(s)
                let data = code == SQLITE_ROW ? blob(s, 0) : nil
                sqlite3_finalize(s)
                guard code == SQLITE_ROW || code == SQLITE_DONE else { throw HistoryFailure(code: code) }
                // Never recreate a continuous segment that the user deleted while capture was in flight.
                guard let data else { try execute("COMMIT"); return nil }
                let previous = try JSONDecoder().decode(HistoryRecord.self, from: data)
                if previous.kind == .screenshot, previous.app == incoming.app, previous.window == incoming.window,
                   previous.screenshotFingerprint == incoming.screenshotFingerprint,
                   incoming.date >= previous.ended, let url = imageURL(previous.image), FileManager.default.isReadableFile(atPath: url.path) {
                    record = previous; record.ended = incoming.date
                    record.original = incoming.original; record.screenshotOCRComplete = incoming.screenshotOCRComplete
                    record.screenText = incoming.screenText
                    try write(record, updateOnly: true); try execute("COMMIT"); return record
                }
            }
            if let reused {
                record.image = reused.image
                if jpeg == nil {
                    if record.screenText == nil { record.original = reused.original; record.screenText = reused.screenText }
                    record.screenshotOCRComplete = true
                }
            } else {
                guard let jpeg else { try execute("COMMIT"); return nil }
                record.image = record.id.uuidString + ".jpg"
                let url = imageURL(record.image)!
                created = url
                try jpeg.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            try write(record, updateOnly: false)
            try execute("COMMIT")
            return record
        } catch {
            try? execute("ROLLBACK")
            if let created { try? FileManager.default.removeItem(at: created) }
            throw error
        }
    } }
    /// Updates never resurrect a record that the user deleted while a request was in flight.
    public func update(_ record: HistoryRecord) throws { try queue.sync { try write(record, updateOnly: true) } }
    /// Background updates preserve annotations made in the companion while work is still in flight.
    @discardableResult public func updateContent(_ incoming: HistoryRecord) throws -> Bool {
        try mutate(incoming.id) { existing in
            let note = existing.note, starred = existing.starred
            existing = incoming; existing.note = note; existing.starred = starred
        }
    }
    public func annotate(_ id: UUID, starred: Bool, note: String) throws {
        _ = try mutate(id) { $0.starred = starred; $0.note = note }
    }
    private func mutate(_ id: UUID, change: (inout HistoryRecord) -> Void) throws -> Bool { try queue.sync {
        try execute("BEGIN IMMEDIATE")
        do {
            let s = try statement("SELECT data FROM records WHERE id=?")
            bind(id.uuidString, 1, s)
            let code = sqlite3_step(s)
            guard code == SQLITE_ROW else {
                sqlite3_finalize(s)
                guard code == SQLITE_DONE else { throw HistoryFailure(code: code) }
                try execute("COMMIT"); return false
            }
            let data = blob(s, 0); sqlite3_finalize(s)
            var value = try JSONDecoder().decode(HistoryRecord.self, from: data)
            change(&value); try write(value, updateOnly: true); try execute("COMMIT"); return true
        } catch { try? execute("ROLLBACK"); throw error }
    } }
    public func records(query: String = "", kind: RecordKind? = nil, starred: Bool = false, limit: Int = 200, offset: Int = 0) throws -> [HistoryRecord] { try queue.sync {
        let s = try statement("SELECT data FROM records WHERE (?='' OR instr(lower(search),lower(?))>0) AND (?='' OR kind=?) AND (?=0 OR starred=1) ORDER BY date DESC LIMIT ? OFFSET ?")
        defer { sqlite3_finalize(s) }
        bind(query, 1, s); bind(query, 2, s); bind(kind?.rawValue ?? "", 3, s); bind(kind?.rawValue ?? "", 4, s)
        sqlite3_bind_int(s, 5, starred ? 1 : 0); sqlite3_bind_int(s, 6, Int32(clamping: limit)); sqlite3_bind_int(s, 7, Int32(clamping: offset))
        var result: [HistoryRecord] = []
        while true {
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw HistoryFailure(code: code) }
            result.append(try JSONDecoder().decode(HistoryRecord.self, from: blob(s, 0)))
        }; return result
    } }
    public func relatedScreenshots(to activity: HistoryRecord, limit: Int = 6) throws -> [HistoryRecord] { try queue.sync {
        let s = try statement("SELECT data FROM records WHERE kind='screenshot' AND app=? AND date>=? AND date<=? AND json_extract(data,'$.window')=? ORDER BY date DESC LIMIT ?")
        defer { sqlite3_finalize(s) }
        bind(activity.app, 1, s); sqlite3_bind_double(s, 2, activity.date.timeIntervalSince1970 - 1.5)
        sqlite3_bind_double(s, 3, activity.ended.timeIntervalSince1970 + 2); bind(activity.window, 4, s)
        sqlite3_bind_int(s, 5, Int32(clamping: limit))
        var result: [HistoryRecord] = []
        while true {
            let code = sqlite3_step(s); if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw HistoryFailure(code: code) }
            result.append(try JSONDecoder().decode(HistoryRecord.self, from: blob(s, 0)))
        }; return result
    } }
    /// Exact app and time filtering happens in SQLite, before the limit (other apps cannot crowd out context).
    public func recentContext(app: String, since: Date, before: Date, kind: RecordKind? = nil, limit: Int = 40) throws -> [HistoryRecord] { try queue.sync {
        let s = try statement("SELECT data FROM records WHERE app=? AND MAX(date, COALESCE(json_extract(data,'$.ended')+978307200,date))>=? AND date<=? AND (?='' OR kind=?) ORDER BY MAX(date, COALESCE(json_extract(data,'$.ended')+978307200,date)) DESC LIMIT ?")
        defer { sqlite3_finalize(s) }
        bind(app, 1, s); sqlite3_bind_double(s, 2, since.timeIntervalSince1970)
        sqlite3_bind_double(s, 3, before.timeIntervalSince1970); bind(kind?.rawValue ?? "", 4, s); bind(kind?.rawValue ?? "", 5, s)
        sqlite3_bind_int(s, 6, Int32(clamping: max(0, min(limit, 100))))
        var result: [HistoryRecord] = []
        while true {
            let code = sqlite3_step(s); if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw HistoryFailure(code: code) }
            result.append(try JSONDecoder().decode(HistoryRecord.self, from: blob(s, 0)))
        }
        return result
    } }
    public func contextualWindow(app: String, before: Date) throws -> String { try queue.sync {
        let s = try statement("SELECT data FROM records WHERE kind='activity' AND app=? AND date<=? ORDER BY date DESC LIMIT 1"); defer { sqlite3_finalize(s) }
        bind(app, 1, s); sqlite3_bind_double(s, 2, before.timeIntervalSince1970)
        if sqlite3_step(s) == SQLITE_ROW {
            let record = try JSONDecoder().decode(HistoryRecord.self, from: blob(s, 0))
            return before.timeIntervalSince(record.ended) <= 30 ? record.window : ""
        }; return ""
    } }
    public func delete(_ id: UUID) throws { try queue.sync {
        try execute("BEGIN IMMEDIATE")
        do {
            let read = try statement("SELECT data FROM records WHERE id=?"); bind(id.uuidString, 1, read)
            let code = sqlite3_step(read)
            let data = code == SQLITE_ROW ? blob(read, 0) : nil
            sqlite3_finalize(read)
            guard code == SQLITE_ROW || code == SQLITE_DONE else { throw HistoryFailure(code: code) }
            let record = try data.map { try JSONDecoder().decode(HistoryRecord.self, from: $0) }
            let s = try statement("DELETE FROM records WHERE id=?")
            defer { sqlite3_finalize(s) }; bind(id.uuidString, 1, s); try finish(s)
            if let image = record?.image, let url = imageURL(image) {
                let refs = try statement("SELECT 1 FROM records WHERE json_extract(data,'$.image')=? LIMIT 1")
                defer { sqlite3_finalize(refs) }; bind(image, 1, refs)
                let remaining = sqlite3_step(refs)
                guard remaining == SQLITE_ROW || remaining == SQLITE_DONE else { throw HistoryFailure(code: remaining) }
                if remaining == SQLITE_DONE, FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    } }
    public func deleteRecent(since: Date) throws {
        // Enumerate by date in one queue operation, then use the same image-aware deletion path.
        let ids: [UUID] = try queue.sync {
            let s = try statement("SELECT id FROM records WHERE date>=?"); defer { sqlite3_finalize(s) }; sqlite3_bind_double(s, 1, since.timeIntervalSince1970)
            var ids: [UUID] = []; while sqlite3_step(s) == SQLITE_ROW { if let p = sqlite3_column_text(s, 0), let id = UUID(uuidString: String(cString: p)) { ids.append(id) } }; return ids
        }
        for id in ids { try delete(id) }
    }
    public func imageURL(_ name: String?) -> URL? {
        guard let name, name == URL(fileURLWithPath: name).lastPathComponent, !name.isEmpty, name != ".", name != ".." else { return nil }
        return imageDirectory.appendingPathComponent(name)
    }
    /// Applies an absolute disk cap even to bookmarks; text and bookmark metadata remain searchable.
    @discardableResult public func pruneImages(days: Int, maxBytes: Int64, now: Date = Date()) throws -> Int64 { try queue.sync {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        var entries: [(URL, Int64, Date)] = try files.map { let v = try $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]); return ($0, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast) }
        entries.sort { $0.2 < $1.2 }; var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        let deadline = now.addingTimeInterval(-Double(max(1, days)) * 86400)
        for (url, size, date) in entries where date < deadline || total > max(0, maxBytes) { try fm.removeItem(at: url); total -= size }
        return total
    } }
}
