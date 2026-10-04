import AppKit
import LinkAllShared

/// LinkAll routes user menu actions to the input process; it never edits host text itself.
@MainActor final class InputService: ObservableObject {
    @Published private(set) var snapshot: InputSnapshot?
    @Published private(set) var issue = ""
    private var pending: [InputCommand] = []
    private var launching = false
    private var observers: [NSObjectProtocol] = []
    private var timeout: DispatchWorkItem?
    var onChange: (() -> Void)?
    init() {
        observers.append(DistributedNotificationCenter.default().addObserver(forName: LinkAllIPC.inputState, object: nil, queue: .main) { [weak self] note in
            guard let data = note.userInfo?["state"] as? Data,
                  let state = try? JSONDecoder().decode(InputSnapshot.self, from: data), state.version == LinkAllIPC.version else { return }
            Task { @MainActor in
                guard let self else { return }
                self.snapshot = state; self.issue = ""; self.launching = false; self.timeout?.cancel(); self.onChange?()
                let commands = self.pending; self.pending.removeAll()
                for command in commands {
                    guard let payload = try? JSONEncoder().encode(command) else { continue }
                    DistributedNotificationCenter.default().postNotificationName(LinkAllIPC.inputCommand, object: nil, userInfo: ["command": payload], deliverImmediately: true)
                }
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.bundleIdentifier == LinkAllIdentity.inputBundle else { return }
            Task { @MainActor in self?.snapshot = nil; self?.launching = false; self?.pending.removeAll(); self?.onChange?() }
        })
    }
    func send(_ command: InputCommand) {
        var command = command
        if command.action == .voice || command.action == .enhance || command.action == .activate { command.targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier }
        pending.append(command); start()
    }
    func start() {
        timeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.snapshot == nil || !self.pending.isEmpty { self.issue = "LinkInput 尚未响应，请重试。"; self.pending.removeAll(); self.launching = false; self.onChange?() }
        }
        self.timeout = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        if !NSRunningApplication.runningApplications(withBundleIdentifier: LinkAllIdentity.inputBundle).isEmpty { ping(); return }
        guard !launching else { return }
        guard FileManager.default.fileExists(atPath: LinkAllIdentity.inputURL.path) else { issue = "LinkInput 尚未安装，请运行 LinkAll 安装脚本。"; pending.removeAll(); onChange?(); return }
        launching = true
        let config = NSWorkspace.OpenConfiguration(); config.activates = false
        NSWorkspace.shared.openApplication(at: LinkAllIdentity.inputURL, configuration: config) { [weak self] _, error in
            Task { @MainActor in
                if error != nil { self?.launching = false; self?.pending.removeAll(); self?.issue = "LinkInput 启动失败，请检查安装。"; self?.onChange?() }
                else { self?.ping() }
            }
        }
    }
    private func ping() { DistributedNotificationCenter.default().postNotificationName(LinkAllIPC.inputPing, object: nil, userInfo: nil, deliverImmediately: true) }
    func stop() { timeout?.cancel(); pending.removeAll(); DistributedNotificationCenter.default().postNotificationName(LinkAllIPC.inputQuit, object: nil, userInfo: nil, deliverImmediately: true) }
}
