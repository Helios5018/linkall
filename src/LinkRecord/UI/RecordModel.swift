import AppKit
import SwiftUI
import LinkRecordCore
import UniformTypeIdentifiers

public enum RecordPage: Int, Sendable { case timeline, pet, settings }

@MainActor public final class RecordModel: ObservableObject {
    @Published public var page: RecordPage = .timeline
    @Published public var settings = HistorySettings()
    @Published var records: [HistoryRecord] = []
    @Published var query = "" { didSet { scheduleReload() } }
    @Published var kind: RecordKind? { didSet { reload() } }
    @Published var starredOnly = false { didSet { reload() } }
    @Published var selected: UUID?
    @Published public var message = ""
    @Published public var hasError = false
    @Published public var desktopStatus = "正在准备"
    @Published var imageBytes: Int64 = 0
    @Published var limit = 200
    @Published var playing = ""
    @Published var playCount = 0
    let store: HistoryStore
    private let worker = DispatchQueue(label: "work.yiliu.companion.storage", qos: .utility)
    private var reloadWork: DispatchWorkItem?
    private var revision = 0
    private var maintenance: Timer?
    private var observers: [NSObjectProtocol] = []
    public var showHistory: (() -> Void)?
    public var settingsChanged: (() -> Void)?
    public var bookmark: (() -> Void)?
    public init(store: HistoryStore) {
        self.store = store
        do { settings = try store.settings(); settings.petSize = PetSizing.clamped(settings.petSize) } catch { message = error.localizedDescription }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("work.yiliu.history.changed"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.hasError = false; self?.scheduleReload() } })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("work.yiliu.history.failed"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.hasError = true; self?.message = "输入记录保存失败，请检查磁盘空间。" } })
        reload(); prune()
        maintenance = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.prune() } }
    }
    func prune() {
        let settings = settings
        worker.async { [weak self, store] in
            do {
                let bytes = try store.pruneImages(days: settings.retentionDays, maxBytes: Int64(settings.maxImageMB) * 1024 * 1024)
                DispatchQueue.main.async { self?.imageBytes = bytes }
            } catch { DispatchQueue.main.async { self?.hasError = true; self?.message = "旧截图清理失败，请检查磁盘权限。" } }
        }
    }
    func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }; reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    public func reload() {
        revision += 1
        let version = revision, query = query, kind = kind, starred = starredOnly, limit = limit
        worker.async { [weak self, store] in
            let value = Result { try store.records(query: query, kind: kind, starred: starred, limit: limit) }
            DispatchQueue.main.async {
                guard let self, version == self.revision else { return }
                switch value { case .success(let rows): self.records = rows; case .failure(let error): self.message = error.localizedDescription }
            }
        }
    }
    func resizePet(_ size: Double) {
        settings.petSize = PetSizing.clamped(size); saveSettings()
    }
    public func saveSettings() {
        settings.petSize = PetSizing.clamped(settings.petSize)
        settings.screenshotSeconds = min(300, max(10, settings.screenshotSeconds))
        settings.retentionDays = min(30, max(1, settings.retentionDays)); settings.maxImageMB = min(102400, max(50, settings.maxImageMB))
        let settings = settings
        worker.async { [weak self, store] in
            do { try store.saveSettings(settings); DispatchQueue.main.async { self?.settingsChanged?(); self?.prune() } }
            catch { DispatchQueue.main.async { self?.hasError = true; self?.message = error.localizedDescription } }
        }
    }
    public func flush() { worker.sync {} }
    public func togglePause() { settings.paused.toggle(); saveSettings() }
    func update(_ record: HistoryRecord) { worker.async { [weak self, store] in
        do { try store.annotate(record.id, starred: record.starred, note: record.note); DispatchQueue.main.async { self?.reload() } }
        catch { DispatchQueue.main.async { self?.hasError = true; self?.message = error.localizedDescription } }
    } }
    func delete(_ record: HistoryRecord) { worker.async { [weak self, store] in
        do { try store.delete(record.id); DispatchQueue.main.async { self?.selected = nil; self?.reload() } }
        catch { DispatchQueue.main.async { self?.hasError = true; self?.message = error.localizedDescription } }
    } }
    func deleteRecent() {
        let alert = NSAlert(); alert.messageText = "删除最近 5 分钟的记录？"; alert.informativeText = "文字和关联截图会从本机删除，无法撤销。"; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        worker.async { [weak self, store] in
            do { try store.deleteRecent(since: Date().addingTimeInterval(-300)); DispatchQueue.main.async { self?.reload() } }
            catch { DispatchQueue.main.async { self?.hasError = true; self?.message = error.localizedDescription } }
        }
    }
    func play(_ action: String) {
        playing = action; playCount += 1
        let round = playCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in if self?.playCount == round { self?.playing = "" } }
    }
    func importPet() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]; panel.message = "选择宠物形象，透明背景 PNG 效果更好"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let source = panel.url else { return }
            self?.importPetImage(source)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    private func importPetImage(_ source: URL) {
        do {
            guard let image = NSImage(contentsOf: source), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), bitmap.pixelsWide <= 8192, bitmap.pixelsHigh <= 8192,
                  let png = bitmap.representation(using: .png, properties: [:]) else { message = "请选择有效图片，最长边不超过 8192 像素。"; return }
            let url = store.directory.appendingPathComponent("pet-\(UUID().uuidString).png")
            try png.write(to: url, options: .atomic)
            let previous = URL(fileURLWithPath: settings.petImage)
            settings.petImage = url.path; settings.petStyle = "custom"
            // Persist the new pointer before removing an owned previous image.
            let updated = settings
            worker.async { [weak self, store] in
                do {
                    try store.saveSettings(updated)
                    if previous.deletingLastPathComponent().standardizedFileURL == store.directory.standardizedFileURL,
                       previous.lastPathComponent == "pet.png" || (previous.lastPathComponent.hasPrefix("pet-") && previous.pathExtension == "png") {
                        try? FileManager.default.removeItem(at: previous)
                    }
                    DispatchQueue.main.async { self?.settingsChanged?() }
                } catch { DispatchQueue.main.async { self?.hasError = true; self?.message = "形象保存失败，请检查磁盘空间。" } }
            }
        } catch { message = "形象导入失败，请检查图片和磁盘空间。" }
    }
    var selectedRecord: HistoryRecord? { records.first { $0.id == selected } }
}
