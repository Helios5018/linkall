import AppKit
import Carbon
import LinkRecordCore
import OSLog

/// No disk or Accessibility call is made on the IMK key callback. Payloads never enter system logs.
final class HistoryBridge: @unchecked Sendable {
    static let shared = HistoryBridge()
    private let queue = DispatchQueue(label: "work.yiliu.history.writer", qos: .utility)
    private var store: HistoryStore?
    private var typing: HistoryRecord?
    private var locked = false // main queue
    private var observers: [NSObjectProtocol] = []
    init() {
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in self?.locked = name.hasSuffix("IsLocked") })
        }
    }
    func record(kind: RecordKind, app: String, text: String, status: String) -> HistoryRecord? {
        guard !locked, !IsSecureEventInputEnabled(), !Preferences.shared.config.excludedApps.contains(app), app != Bundle.main.bundleIdentifier, app != "work.yiliu.companion" else { return nil }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: app).first?.localizedName ?? app
        let record = HistoryRecord(kind: kind, app: app, appName: name, original: text, status: status)
        submit(record, initial: true); return record
    }
    func typed(_ text: String, app: String, passthrough: Bool = false) {
        guard !text.isEmpty else { return }
        _ = record(kind: passthrough ? .passthrough : .typing, app: app, text: text, status: passthrough ? "透传输入 · 宿主未确认" : "已请求上屏 · 不代表发送")
    }
    func submit(_ record: HistoryRecord, initial: Bool = false) {
        guard !locked, !IsSecureEventInputEnabled() else { return }
        queue.async {
            do {
                if self.store == nil { self.store = try HistoryStore() }
                guard let store = self.store, try store.settings().allows(record.kind, app: record.app) else { self.typing = nil; return }
                var record = record
                if record.window.isEmpty { record.window = try store.contextualWindow(app: record.app, before: record.date) }
                if initial, [.typing, .passthrough].contains(record.kind) {
                    if var previous = self.typing, previous.kind == record.kind, previous.app == record.app, previous.window == record.window,
                       record.date.timeIntervalSince(previous.ended) < 3, previous.original.count < 4000 {
                        previous.original += record.original; previous.ended = record.date
                        if try store.updateContent(previous) { self.typing = previous }
                        else { try store.insert(record); self.typing = record }
                    } else { try store.insert(record); self.typing = record }
                } else {
                    self.typing = nil
                    if initial { try store.insert(record) } else { try store.updateContent(record) }
                }
                DistributedNotificationCenter.default().postNotificationName(.init("work.yiliu.history.changed"), object: nil, userInfo: nil, deliverImmediately: true)
            } catch {
                Logger(subsystem: "work.yiliu.inputmethod.Yiliu", category: "history").error("Local history persistence failed")
                DistributedNotificationCenter.default().postNotificationName(.init("work.yiliu.history.failed"), object: nil, userInfo: nil, deliverImmediately: true)
            }
        }
    }
    func flush() { queue.sync {} }
}
