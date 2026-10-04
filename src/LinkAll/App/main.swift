import AppKit
import SwiftUI
import Combine
import LinkAllShared
import LinkAllUI
import LinkRecordCore
import LinkRecordUI

@MainActor final class LinkAllDelegate: NSObject, NSApplicationDelegate {
    private var record: RecordModel!
    private var recorder: DesktopRecorder!
    private var pet: PetController!
    private var window: NSWindow?
    private var status: NSStatusItem?
    private let selection = WorkspaceSelection()
    private let input = InputService()
    private var observers: [NSObjectProtocol] = []
    private var quitting = false
    private var ownsInputLifecycle = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { record = RecordModel(store: try HistoryStore()) }
        catch { let alert = NSAlert(); alert.messageText = "LinkRecord 无法打开本地记录"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil); return }
        record.showHistory = { [weak self] in self?.show(.record) }
        recorder = DesktopRecorder(model: record); pet = PetController(model: record)
        record.settingsChanged = { [weak self] in self?.pet.apply(); self?.recorder.changed(); self?.updateMenu() }
        input.onChange = { [weak self] in self?.updateMenu() }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status?.button?.image = LinkBrand.all.image(); status?.button?.imagePosition = .imageOnly
        status?.button?.setAccessibilityLabel("LinkAll")
        updateMenu(); recorder.start()
        observers.append(DistributedNotificationCenter.default().addObserver(forName: LinkAllIPC.shellShow, object: nil, queue: .main) { [weak self] note in
            let module = (note.object as? String).flatMap(LinkModule.init(rawValue:)) ?? .record
            Task { @MainActor in self?.show(module) }
        })
        // Compatibility with the installed input method and old CLI automation.
        for (name, action) in [("work.yiliu.history.show", { [weak self] in self?.show(.record) }), (LinkAllIPC.shellQuit.rawValue, { [weak self] in self?.quit() })] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { _ in Task { @MainActor in action() } })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.window?.orderOut(nil); self?.pet.hideForLock() } })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.pet.apply() } })
        ownsInputLifecycle = true; input.start()
        if !CommandLine.arguments.contains("--background") { show(.record) }
    }
    func applicationWillTerminate(_ notification: Notification) { record?.flush(); if ownsInputLifecycle { input.stop() } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(.record); return true }
    private func updateMenu() {
        guard record != nil else { return }
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector, _ parent: NSMenu, _ represented: Any? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; item.representedObject = represented; parent.addItem(item); return item
        }
        func section(_ title: String, brand: LinkBrand) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let child = NSMenu(title: title); item.submenu = child; item.image = brand.image(size: 16); menu.addItem(item); return child
        }
        _ = add("打开 LinkAll…", #selector(openWorkspace), menu)
        menu.addItem(.separator())
        let inputMenu = section("LinkInput", brand: .input)
        _ = add("在当前应用使用 LinkInput", #selector(inputAction(_:)), inputMenu, InputCommand(.activate))
        if let state = input.snapshot {
            func choices(_ title: String, _ values: [InputChoice], selected: String, action: InputAction) {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let child = NSMenu(title: title); item.submenu = child; inputMenu.addItem(item)
                for value in values { let entry = add(value.title, #selector(inputAction(_:)), child, InputCommand(action, value: value.id)); entry.state = value.id == selected ? .on : .off }
            }
            choices("输入方案：" + (state.schemes.first { $0.id == state.scheme }?.title ?? ""), state.schemes, selected: state.scheme, action: .scheme)
            choices("语音模式：" + (state.voiceModes.first { $0.id == state.voiceMode }?.title ?? ""), state.voiceModes, selected: state.voiceMode, action: .voiceMode)
            choices("AI 整理：" + (state.manualModes.first { $0.id == state.manualMode }?.title ?? ""), state.manualModes, selected: state.manualMode, action: .manualMode)
            inputMenu.addItem(.separator())
            _ = add("开始／结束语音输入", #selector(inputAction(_:)), inputMenu, InputCommand(.voice))
            _ = add("整理当前输入", #selector(inputAction(_:)), inputMenu, InputCommand(.enhance))
        } else { _ = add("启动 LinkInput", #selector(startInput), inputMenu) }
        _ = add("LinkInput 设置…", #selector(inputAction(_:)), inputMenu, InputCommand(.settings))
        let recordMenu = section("LinkRecord", brand: .record)
        _ = add("时间线与搜索…", #selector(openRecord(_:)), recordMenu, RecordPage.timeline.rawValue)
        _ = add("桌宠与换装…", #selector(openRecord(_:)), recordMenu, RecordPage.pet.rawValue)
        _ = add("记录设置…", #selector(openRecord(_:)), recordMenu, RecordPage.settings.rawValue)
        recordMenu.addItem(.separator())
        _ = add(record.settings.paused ? "恢复记录" : "暂停记录", #selector(togglePause), recordMenu)
        _ = add(record.settings.petVisible ? "隐藏桌宠" : "显示桌宠", #selector(togglePet), recordMenu)
        _ = add("记住这一刻", #selector(bookmark), recordMenu)
        let agentMenu = section("LinkAgent · 回复建议", brand: .agent)
        _ = add("查看 LinkAgent", #selector(openAgent), agentMenu)
        menu.addItem(.separator()); _ = add("退出 LinkAll", #selector(quit), menu)
        status?.menu = menu
        status?.button?.toolTip = "LinkAll · LinkInput：\(input.snapshot?.activity ?? "未连接") · LinkRecord：\(record.settings.paused ? "已暂停" : "记录中")"
    }
    private func show(_ module: LinkModule) {
        selection.module = module
        if window == nil {
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            value.title = "LinkAll"; value.isReleasedWhenClosed = false
            value.contentView = NSHostingView(rootView: WorkspaceView(selection: selection, input: input, record: record))
            value.center(); value.setFrameAutosaveName("LinkInputHistory"); window = value
        }
        record.reload(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openWorkspace() { show(selection.module) }
    @objc private func inputAction(_ sender: NSMenuItem) { if let command = sender.representedObject as? InputCommand { input.send(command) } }
    @objc private func startInput() { input.start() }
    @objc private func openRecord(_ sender: NSMenuItem) { record.page = RecordPage(rawValue: sender.representedObject as? Int ?? 0) ?? .timeline; show(.record) }
    @objc private func openAgent() { show(.agent) }
    @objc private func togglePause() { record.togglePause() }
    @objc private func togglePet() { record.settings.petVisible.toggle(); record.saveSettings() }
    @objc private func bookmark() { record.bookmark?() }
    @objc private func quit() {
        guard !quitting else { return }; quitting = true
        // Restore focus before stopping the input source, avoiding macOS reactivating it in the previous app.
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }
}
if CommandLine.arguments.contains("--quit") {
    DistributedNotificationCenter.default().postNotificationName(LinkAllIPC.shellQuit, object: nil, userInfo: nil, deliverImmediately: true); exit(0)
}
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { LinkAllDelegate() }
app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
