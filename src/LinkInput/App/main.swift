import AppKit
import InputMethodKit
import Carbon
import YiliuCore
import UniformTypeIdentifiers
import OSLog
import LinkAllShared

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    var server: IMKServer?
    /// English completion or direct input in the frontmost host's session.
    var asciiMode = false { didSet { if asciiMode != oldValue { renderStatus() } } }
    private var activity = ""
    private lazy var settings = SettingsController()
    private var quitObserver: NSObjectProtocol?
    private var eraseOnQuit = false
    private var resetting = false
    private var inputObservers: [NSObjectProtocol] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        _ = HistoryBridge.shared
        inputObservers.append(DistributedNotificationCenter.default().addObserver(forName: LinkAllIPC.inputPing, object: nil, queue: .main) { [weak self] _ in self?.publishStatus() })
        inputObservers.append(DistributedNotificationCenter.default().addObserver(forName: LinkAllIPC.inputCommand, object: nil, queue: .main) { [weak self] note in
            guard let data = note.userInfo?["command"] as? Data, let command = try? JSONDecoder().decode(InputCommand.self, from: data), command.version == LinkAllIPC.version else { return }
            self?.perform(command)
        })
        quitObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("work.yiliu.quit"), object: nil, queue: .main) { [weak self] _ in if self?.resetting != true { self?.quit() } }
        let resource = Bundle.main.resourceURL?.appendingPathComponent("Rime").path ?? "Vendor/Rime"
        let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Yiliu/Rime").path
        do { try RimeEngine.start(shared: resource, user: user); try RimeEngine.configure(Preferences.shared.inputOptions) }
        catch { let alert = NSAlert(); alert.messageText = "输入词库初始化失败"; alert.informativeText = "请重新安装 LinkInput，或切回系统输入法。"; alert.runModal(); NSApp.terminate(nil); return }
        server = IMKServer(name: "Yiliu_Connection", bundleIdentifier: Bundle.main.bundleIdentifier ?? "work.yiliu.inputmethod.Yiliu")
        Logger(subsystem: "work.yiliu.inputmethod.Yiliu", category: "lifecycle").notice("InputMethodKit server ready: \(self.server != nil)")
        renderStatus()
        // Coordinator reports "意" when idle; the idle icon then shows the input mode.
        Coordinator.shared.statusChanged = { [weak self] title in self?.activity = title == "意" ? "" : title; self?.renderStatus() }
        settings.onSave = { [weak self] in
            Coordinator.shared.settingsChanged()
            self?.asciiMode = Preferences.shared.scheme.isEnglish
            self?.publishStatus()
        }
        settings.onDiagnostics = { [weak self] in self?.showDiagnostics() }
        settings.onReset = { [weak self] in self?.resetLocalData() }
        Coordinator.shared.prepareVoiceUI()
        if let issue = Hotkeys.shared.configure() { Logger(subsystem: LinkAllIdentity.inputBundle, category: "hotkeys").error("\(issue, privacy: .public)") }
        publishStatus()
        if CommandLine.arguments.contains("--settings") || !UserDefaults.standard.bool(forKey: "didWelcome") {
            UserDefaults.standard.set(true, forKey: "didWelcome"); showSettings()
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        Coordinator.shared.clear(); HistoryBridge.shared.flush(); RimeEngine.sync(); RimeEngine.shutdown()
        if eraseOnQuit {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Yiliu")
            try? FileManager.default.removeItem(at: directory)
            Preferences.shared.clearToken()
            UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
            UserDefaults.standard.removePersistentDomain(forName: "work.yiliu.companion")
        }
    }
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, in parent: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; parent.addItem(item); return item
        }
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let child = NSMenu(title: title); item.submenu = child; menu.addItem(item)
            return child
        }
        let input = submenu("输入法：" + Preferences.shared.scheme.title)
        for scheme in InputScheme.allCases {
            let i = item(scheme.title, #selector(changeScheme(_:)), in: input)
            i.representedObject = scheme.rawValue
            i.state = Preferences.shared.scheme == scheme ? .on : .off
        }
        let voice = Preferences.shared.voiceOptions
        let voiceMenu = submenu("语音输入：" + voice.selectedMode.name)
        for mode in voice.modes {
            let i = item(mode.name, #selector(changeDictationMode(_:)), in: voiceMenu); i.representedObject = mode.id
            i.state = voice.selectedMode.id == mode.id ? .on : .off
        }
        voiceMenu.addItem(.separator())
        _ = item("开始／结束语音输入", #selector(triggerVoice), in: voiceMenu)
        let manual = Preferences.shared.manualOptions
        let manualMenu = submenu("AI 整理：" + manual.selectedMode.name)
        for mode in manual.modes {
            let i = item(mode.name, #selector(changeManualMode(_:)), in: manualMenu); i.representedObject = mode.id
            i.state = manual.selectedMode.id == mode.id ? .on : .off
        }
        manualMenu.addItem(.separator())
        _ = item("整理当前输入", #selector(triggerEnhancement), in: manualMenu)
        menu.addItem(.separator())
        _ = item("打开 LinkAll…", #selector(showHistory), in: menu)
        _ = item("设置…", #selector(showSettings), in: menu)
        menu.addItem(.separator())
        _ = item("退出 LinkInput", #selector(quit), in: menu)
        return menu
    }
    @objc private func changeScheme(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let scheme = InputScheme(rawValue: value) else { return }
        Preferences.shared.scheme = scheme; asciiMode = scheme.isEnglish; publishStatus()
    }
    @objc private func changeDictationMode(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        Preferences.shared.voiceOptions.selectedModeID = id; publishStatus()
    }
    @objc private func changeManualMode(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        Preferences.shared.manualOptions.selectedModeID = id; publishStatus()
    }
    private func renderStatus() { publishStatus() }
    private func publishStatus() {
        let voice = Preferences.shared.voiceOptions, manual = Preferences.shared.manualOptions
        let state = InputSnapshot(activity: activity.isEmpty ? (asciiMode ? "英" : "中") : activity,
            scheme: Preferences.shared.scheme.rawValue,
            schemes: InputScheme.allCases.map { InputChoice(id: $0.rawValue, title: $0.title) },
            voiceMode: voice.selectedMode.id.uuidString, voiceModes: voice.modes.map { InputChoice(id: $0.id.uuidString, title: $0.name) },
            manualMode: manual.selectedMode.id.uuidString, manualModes: manual.modes.map { InputChoice(id: $0.id.uuidString, title: $0.name) })
        guard let data = try? JSONEncoder().encode(state) else { return }
        DistributedNotificationCenter.default().postNotificationName(LinkAllIPC.inputState, object: nil, userInfo: ["state": data], deliverImmediately: true)
    }
    private func perform(_ command: InputCommand) {
        if let pid = command.targetPID, command.action == .voice || command.action == .enhance || command.action == .activate,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            Coordinator.shared.notifyTargetChanged(); publishStatus(); return
        }
        switch command.action {
        case .settings: showSettings()
        case .activate:
            let filter = [kTISPropertyInputSourceID as String: LinkAllIdentity.inputSource] as CFDictionary
            let sources = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
            if let source = sources.first { TISSelectInputSource(source) }
        case .voice: triggerVoice()
        case .enhance: triggerEnhancement()
        case .scheme:
            if let value = command.value, let scheme = InputScheme(rawValue: value) { Preferences.shared.scheme = scheme; asciiMode = scheme.isEnglish }
        case .voiceMode:
            if let id = command.value.flatMap(UUID.init(uuidString:)), Preferences.shared.voiceOptions.modes.contains(where: { $0.id == id }) { Preferences.shared.voiceOptions.selectedModeID = id }
        case .manualMode:
            if let id = command.value.flatMap(UUID.init(uuidString:)), Preferences.shared.manualOptions.modes.contains(where: { $0.id == id }) { Preferences.shared.manualOptions.selectedModeID = id }
        }
        publishStatus()
    }
    @objc private func triggerVoice() { Coordinator.shared.voiceHotkey() }
    @objc private func triggerEnhancement() {
        YiliuInputController.latest(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)?.finishForDraft()
        Coordinator.shared.enhanceHotkey()
    }
    @objc private func showHistory() { ensureLinkAll(show: true) }
    private func ensureLinkAll(show: Bool) {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: LinkAllIdentity.shellBundle).isEmpty {
            if show { DistributedNotificationCenter.default().postNotificationName(LinkAllIPC.shellShow, object: LinkModule.record.rawValue, userInfo: nil, deliverImmediately: true) }
            return
        }
        let url = FileManager.default.fileExists(atPath: LinkAllIdentity.shellURL.path) ? LinkAllIdentity.shellURL : LinkAllIdentity.legacyShellURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let config = NSWorkspace.OpenConfiguration(); config.activates = show; config.arguments = show ? ["--history"] : ["--background"]
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }
    @objc func showSettings() { settings.load(); settings.showWindow(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func clearDraft() { Coordinator.shared.clear() }
    @objc private func resetLocalData() {
        let alert = NSAlert(); alert.messageText = "清除 LinkAll 的全部本地数据？"
        alert.informativeText = "这会清除输入和语音历史、桌面截图、宠物配置、草稿、已学习的词语、API 凭据、设置和诊断计数，并退出 LinkAll。已发送到云端的数据不在本地清除范围内。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清除并退出")
        if alert.runModal() == .alertSecondButtonReturn {
            resetting = true
            let companions = NSRunningApplication.runningApplications(withBundleIdentifier: "work.yiliu.companion")
            companions.forEach { _ = $0.terminate() }
            finishReset(after: 0)
        }
    }
    private func finishReset(after attempt: Int) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "work.yiliu.companion").isEmpty else {
            if attempt < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.finishReset(after: attempt + 1) } }
            else { resetting = false; let alert = NSAlert(); alert.messageText = "请先关闭 LinkAll 的对话框，再清除本地数据。"; alert.runModal() }
            return
        }
        eraseOnQuit = true; resetting = false; quit()
    }
    @objc private func showDiagnostics() {
        let alert = NSAlert(); alert.messageText = "本地诊断与反馈"; alert.informativeText = Coordinator.shared.diagnostics()
        alert.addButton(withTitle: "关闭"); alert.addButton(withTitle: "导出用于反馈…"); alert.addButton(withTitle: "清除计数")
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            let save = NSSavePanel(); save.allowedContentTypes = [.json]; save.nameFieldStringValue = "Yiliu-diagnostics.json"
            if save.runModal() == .OK, let url = save.url {
                do { try Coordinator.shared.usage.export().write(to: url, options: .atomic) }
                catch { let error = NSAlert(); error.messageText = "诊断导出失败，请换一个保存位置。"; error.runModal() }
            }
        case .alertThirdButtonReturn: Coordinator.shared.usage.clear()
        default: break
        }
    }
    @objc private func restoreSystem() {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let raw = TISGetInputSourceProperty(current, kTISPropertyInputSourceID),
              String(describing: Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()) == LinkAllIdentity.inputSource else { return }
        let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.ABC"] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
        if let source = sources.first { TISEnableInputSource(source); TISSelectInputSource(source) }
    }
    @objc private func quit() {
        restoreSystem(); NSApp.terminate(nil)
    }
}
if CommandLine.arguments.contains("--quit") {
    DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("work.yiliu.quit"), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}
if CommandLine.arguments.contains("--import-token") {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { fputs("No credential supplied on stdin\n", stderr); exit(2) }
    do { try Preferences.shared.saveToken(token); print("Credential saved in Keychain"); exit(0) }
    catch { fputs("Keychain write failed\n", stderr); exit(1) }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
