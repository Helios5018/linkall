import AppKit
import SwiftUI
import LinkAllShared
import LinkAllUI
import Security
import YiliuCore

/// Settings are touched on the main queue; the cached secret only on keychainQueue.
final class Preferences: @unchecked Sendable {
    static let shared = Preferences()
    var config: APIConfiguration {
        didSet { if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: "apiConfiguration") } }
    }
    var manualOptions: ManualOptions {
        didSet { if let data = try? JSONEncoder().encode(manualOptions) { UserDefaults.standard.set(data, forKey: "manualOptions") } }
    }
    var inputOptions: InputOptions {
        didSet { if let data = try? JSONEncoder().encode(inputOptions) { UserDefaults.standard.set(data, forKey: "inputOptions") } }
    }
    var voiceOptions: VoiceOptions {
        didSet { if let data = try? JSONEncoder().encode(voiceOptions) { UserDefaults.standard.set(data, forKey: "voiceOptions") } }
    }
    var scheme: InputScheme {
        didSet { UserDefaults.standard.set(scheme.rawValue, forKey: "scheme") }
    }
    init() {
        inputOptions = UserDefaults.standard.data(forKey: "inputOptions").flatMap { try? JSONDecoder().decode(InputOptions.self, from: $0) } ?? InputOptions()
        var saved = UserDefaults.standard.data(forKey: "apiConfiguration").flatMap { try? JSONDecoder().decode(APIConfiguration.self, from: $0) } ?? APIConfiguration()
        saved.upgradeDefaults()
        // The global pause control has been retired; never strand an older installation in paused mode.
        saved.paused = false
        config = saved
        manualOptions = UserDefaults.standard.data(forKey: "manualOptions").flatMap { try? JSONDecoder().decode(ManualOptions.self, from: $0) } ?? ManualOptions()
        scheme = InputScheme(rawValue: UserDefaults.standard.string(forKey: "scheme") ?? "") ?? .flypy
        if let data = UserDefaults.standard.data(forKey: "voiceOptions"), let saved = try? JSONDecoder().decode(VoiceOptions.self, from: data) {
            voiceOptions = saved
        } else {
            // Earlier builds stored only a hold-to-record flag; keep that choice, otherwise default to hybrid.
            var migrated = VoiceOptions()
            if UserDefaults.standard.bool(forKey: "holdToRecord") { migrated.recordMode = .pushToTalk }
            voiceOptions = migrated
        }
    }
    // Reading the secret can raise a Keychain password prompt that blocks the caller until answered.
    // On the main thread that freezes the IME and the host app typing into it, so reads stay on this queue.
    private let keychainQueue = DispatchQueue(label: "work.yiliu.keychain")
    private var cachedToken: String? // keychainQueue only; dropped on lock, sleep and clear.
    /// Checks attributes only, which never prompts.
    func hasToken() -> Bool {
        var query = keyQuery
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
    func hasTokenAsync() async -> Bool {
        await withCheckedContinuation { done in keychainQueue.async { done.resume(returning: self.hasToken()) } }
    }
    func token() async -> String {
        await withCheckedContinuation { done in
            keychainQueue.async {
                if let cached = self.cachedToken { done.resume(returning: cached); return }
                var query = self.keyQuery
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { done.resume(returning: ""); return }
                let token = String(decoding: data, as: UTF8.self)
                self.cachedToken = token
                done.resume(returning: token)
            }
        }
    }
    func forgetCachedToken() { keychainQueue.async { self.cachedToken = nil } }
    func saveToken(_ token: String) throws {
        guard !token.isEmpty else { return }
        forgetCachedToken()
        let attrs: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(keyQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var query = keyQuery
            query[kSecValueData as String] = Data(token.utf8)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    func clearToken() { forgetCachedToken(); SecItemDelete(keyQuery as CFDictionary) }
    private var keyQuery: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "work.yiliu.inputmethod.Yiliu", kSecAttrAccount as String: "api-token"] }
}

/// Collapsed sections keep their controls alive, so saving never loses hidden values.
private final class SettingsDisclosure: NSStackView {
    private let toggle = NSButton()
    let body = NSStackView()
    private let title: String
    init(_ title: String) {
        self.title = title
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 12
        toggle.title = "▸ " + title; toggle.isBordered = false
        toggle.font = .systemFont(ofSize: 13, weight: .medium)
        toggle.target = self; toggle.action = #selector(expand)
        toggle.setAccessibilityLabel(title)
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 14
        addArrangedSubview(toggle); addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        body.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func expand() {
        body.isHidden.toggle(); toggle.title = (body.isHidden ? "▸ " : "▾ ") + title
        toggle.setAccessibilityValue(body.isHidden ? "已折叠" : "已展开")
    }
}

private final class SettingsPage: NSStackView {
    override var isFlipped: Bool { true }
}

final class SettingsController: NSWindowController, NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    private let llm = NSTextField(), asr = NSTextField(), model = NSTextField(), asrModel = NSTextField()
    private let token = NSSecureTextField(), exclusions = NSTextField()
    private let textConsent = NSButton(checkboxWithTitle: "允许 AI 整理上传选中文字或当前输入框内容", target: nil, action: nil)
    private let audioConsent = NSButton(checkboxWithTitle: "允许语音转写上传本次录音", target: nil, action: nil)
    private let format = NSPopUpButton(), auth = NSPopUpButton()
    private let draftShortcut = NSPopUpButton(), voiceShortcut = NSPopUpButton(), voiceMode = NSPopUpButton()
    private let inputRate = NSTextField(), outputRate = NSTextField(), audioRate = NSTextField()
    private let streaming = NSButton(checkboxWithTitle: "流式转写：边说边识别，松开即出字（失败自动改为整段上传）", target: nil, action: nil)
    private let currentMode = NSPopUpButton(), editMode = NSPopUpButton(), modeName = NSTextField()
    private let modePolish = NSButton(checkboxWithTitle: "识别后调用 AI 整理", target: nil, action: nil)
    private let deleteModeButton = NSButton()
    private let modeSystemPrompt = NSTextView(), resetSystemPromptButton = NSButton()
    private let currentManualMode = NSPopUpButton(), editManualMode = NSPopUpButton(), manualName = NSTextField()
    private let manualPrompt = NSTextView(), deleteManualModeButton = NSButton()
    private var editingManual = ManualOptions(), editingManualIndex = 0
    private let sceneSelector = NSPopUpButton(), scenePrompt = NSTextView()
    private let sceneDetail = NSTextField(wrappingLabelWithString: "")
    private var editingScenes = ScenePrompts(), editingSceneKind = ScenePromptKind.terminal
    /// Text edits debounce briefly; controls and window close flush pending valid changes.
    private var editingModes: [DictationMode] = [], editingIndex = 0
    private var saveWork: DispatchWorkItem?
    private var hasUnsavedChanges = false
    private var credentialEditing = false
    private let pasteFallback = NSButton(checkboxWithTitle: "未连上 LinkInput 输入法时，经剪贴板粘贴（随后恢复原剪贴板）", target: nil, action: nil)
    private let muteWhileRecording = NSButton(checkboxWithTitle: "录音时静音系统声音", target: nil, action: nil)
    private let maxRecordingMinutes = NSPopUpButton()
    private let vocabulary = NSTextField(), replacements = NSTextField(), fillerWords = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let inputScheme = NSPopUpButton(), candidateCount = NSPopUpButton(), candidateRows = NSPopUpButton()
    private let mixedPinyin = NSButton(checkboxWithTitle: "双拼兼容全拼", target: nil, action: nil)
    private let expandedPinyin = NSButton(checkboxWithTitle: "双拼显示完整拼音", target: nil, action: nil)
    private var fuzzyButtons: [FuzzyPair: NSButton] = [:]
    // Hidden tab content is built before its parent enters the window layout.
    // Give AppKit a usable initial size so the first selection never lays out a zero-width form.
    private let pages = NSTabView(frame: NSRect(x: 0, y: 0, width: 771, height: 690))
    private let voicePages = NSTabView(frame: NSRect(x: 0, y: 0, width: 735, height: 512))
    private var sidebarHost: NSHostingView<LinkSidebar>?
    private let voiceSections = NSSegmentedControl()
    private let voiceModeList = SettingsPage(), manualModeList = SettingsPage()
    private let useVoiceMode = NSButton(), useManualMode = NSButton()
    private let voiceServiceStatus = NSTextField(wrappingLabelWithString: "")
    private let manualServiceStatus = NSTextField(wrappingLabelWithString: "")
    private let credentialStatus = NSTextField(wrappingLabelWithString: "")
    private let doublePinyinSettings = NSStackView(), pinyinSettings = NSStackView()
    private let voicePromptSettings = NSStackView()
    var onSave: (() -> Void)?
    var onDiagnostics: (() -> Void)?
    var onReset: (() -> Void)?
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "LinkInput 设置"; window.minSize = NSSize(width: 960, height: 660); window.center()
        super.init(window: window)
        window.delegate = self
        let root = NSStackView(); root.orientation = .horizontal; root.alignment = .top; root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 960),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 628)
        ])
        let sidebar = NSHostingView(rootView: settingsSidebar(selected: 0))
        sidebarHost = sidebar
        root.addArrangedSubview(sidebar)
        sidebar.widthAnchor.constraint(equalToConstant: LinkAppearance.sidebarWidth).isActive = true
        sidebar.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        let divider = NSBox(); divider.boxType = .separator; root.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        let content = NSStackView(); content.orientation = .vertical; content.alignment = .leading; content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 14, right: 10)
        root.addArrangedSubview(content); content.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        content.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -(LinkAppearance.sidebarWidth + 1)).isActive = true
        pages.tabViewType = .noTabsNoBorder
        content.addArrangedSubview(pages); pages.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -20).isActive = true
        pages.setContentHuggingPriority(.defaultLow, for: .vertical)
        func page(_ title: String, in tabs: NSTabView? = nil) -> NSStackView {
            let item = NSTabViewItem(identifier: title); item.label = title
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 735, height: 512))
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true; scroll.drawsBackground = false
            let stack = SettingsPage(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
            stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 24, right: 18)
            stack.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = stack
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
                stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
            ])
            item.view = scroll; (tabs ?? pages).addTabViewItem(item); return stack
        }
        func note(_ text: String, in stack: NSStackView) {
            let label = NSTextField(wrappingLabelWithString: text); label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12); stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }
        func heading(_ text: String, in stack: NSStackView) {
            let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 14, weight: .semibold)
            stack.addArrangedSubview(label)
        }
        func title(_ text: String, in stack: NSStackView) {
            let label = NSTextField(labelWithString: text); label.font = LinkAppearance.appKitTitleFont
            stack.addArrangedSubview(label)
        }
        func field(_ title: String, _ control: NSView, in stack: NSStackView) {
            let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 115).isActive = true
            let row = NSStackView(views: [label, control]); row.distribution = .fill; row.spacing = 12; row.alignment = .centerY
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }
        func group(_ body: NSStackView, in parent: NSStackView) {
            body.orientation = .vertical; body.alignment = .leading; body.spacing = 14
            parent.addArrangedSubview(body); body.widthAnchor.constraint(equalTo: parent.widthAnchor, constant: -36).isActive = true
        }
        func disclosure(_ text: String, in parent: NSStackView) -> NSStackView {
            let section = SettingsDisclosure(text); parent.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: parent.widthAnchor, constant: -36).isActive = true
            return section.body
        }
        func serviceSummary(_ label: NSTextField, in stack: NSStackView) {
            label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label); label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
            stack.addArrangedSubview(NSStackView(views: [
                NSButton(title: "配置服务…", target: self, action: #selector(openServices)),
                NSButton(title: "管理云端授权…", target: self, action: #selector(openPrivacy))
            ]))
        }
        func modeEditor(_ list: NSStackView, use: NSButton, add: Selector, delete: NSButton, in parent: NSStackView) -> NSStackView {
            let row = NSStackView(); row.orientation = .horizontal; row.distribution = .fill; row.alignment = .top; row.spacing = 18
            parent.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: parent.widthAnchor, constant: -36).isActive = true
            let left = NSStackView(); left.orientation = .vertical; left.alignment = .leading; left.spacing = 12
            row.addArrangedSubview(left); left.widthAnchor.constraint(equalToConstant: 155).isActive = true
            list.orientation = .vertical; list.alignment = .leading; list.spacing = 6
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
            list.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = list
            left.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true
            left.addArrangedSubview(NSButton(title: "新建模式", target: self, action: add)); left.addArrangedSubview(delete)
            let editor = NSStackView(); editor.orientation = .vertical; editor.alignment = .leading; editor.spacing = 14
            row.addArrangedSubview(editor); editor.setContentHuggingPriority(.defaultLow, for: .horizontal)
            editor.addArrangedSubview(use)
            return editor
        }
        let input = page("输入法")
        title("输入法", in: input)
        heading("输入方案", in: input)
        inputScheme.addItems(withTitles: InputScheme.allCases.map(\.title)); field("当前方案", inputScheme, in: input)
        note("中文方案支持英文候选；English 补全支持单词补全，空格选词并加空格。输入代码、路径时可选「英文直通」。", in: input)
        note("轻点 Shift 切换中文与英文直通；需要英文候选时，选择「English 补全」。", in: input)
        heading("候选显示", in: input)
        candidateCount.addItems(withTitles: (5...10).map { "\($0) 个" })
        field("每行候选词", candidateCount, in: input)
        candidateRows.addItems(withTitles: (3...10).map { "\($0) 行" })
        field("展开候选行数", candidateRows, in: input)
        note("上下键展开多行网格，超出行数时滚动。展开后上下换行、左右选词，数字键选择高亮行。", in: input)
        group(doublePinyinSettings, in: input)
        heading("双拼设置", in: doublePinyinSettings)
        doublePinyinSettings.addArrangedSubview(mixedPinyin)
        note("小鹤双拼中可直接输入全拼，例如 nihc 或 nihao 都可输入「你好」。重码时请按候选选择。", in: doublePinyinSettings)
        doublePinyinSettings.addArrangedSubview(expandedPinyin)
        note("默认显示实际按键 nihc；开启后显示展开拼音。", in: doublePinyinSettings)
        group(pinyinSettings, in: input)
        heading("模糊音", in: pinyinSettings)
        note("按需勾选，适用于全拼和小鹤双拼。默认全部关闭；开启后可能增加重码。", in: pinyinSettings)
        for pairs in [Array(FuzzyPair.allCases.prefix(4)), Array(FuzzyPair.allCases.suffix(4))] {
            let row = NSStackView(); row.spacing = 18
            for pair in pairs {
                let button = NSButton(checkboxWithTitle: pair.title, target: nil, action: nil)
                fuzzyButtons[pair] = button; row.addArrangedSubview(button)
            }
            pinyinSettings.addArrangedSubview(row)
        }
        // Voice has three task-oriented sections, with one shared service summary.
        let voiceItem = NSTabViewItem(identifier: "语音输入"); voiceItem.label = "语音输入"
        let voiceRoot = NSStackView(frame: NSRect(x: 0, y: 0, width: 771, height: 690)); voiceRoot.autoresizingMask = [.width, .height]; voiceRoot.orientation = .vertical; voiceRoot.alignment = .leading; voiceRoot.spacing = 14
        voiceRoot.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 0, right: 18)
        voiceItem.view = voiceRoot; pages.addTabViewItem(voiceItem)
        title("语音输入", in: voiceRoot); serviceSummary(voiceServiceStatus, in: voiceRoot)
        voiceSections.segmentCount = 3
        for (i, label) in ["录音与识别", "输出模式", "词汇与替换"].enumerated() { voiceSections.setLabel(label, forSegment: i) }
        voiceSections.selectedSegment = 0; voiceSections.target = self; voiceSections.action = #selector(changeVoiceSection)
        voiceRoot.addArrangedSubview(voiceSections)
        voicePages.tabViewType = .noTabsNoBorder; voiceRoot.addArrangedSubview(voicePages)
        voicePages.widthAnchor.constraint(equalTo: voiceRoot.widthAnchor, constant: -36).isActive = true
        voicePages.setContentHuggingPriority(.defaultLow, for: .vertical)
        let shortcuts = page("录音与识别", in: voicePages)
        heading("开始录音", in: shortcuts)
        voiceShortcut.addItems(withTitles: Hotkeys.voiceChoices.map(\.title))
        voiceMode.addItems(withTitles: RecordMode.allCases.map(\.title))
        field("录音快捷键", voiceShortcut, in: shortcuts); field("录音方式", voiceMode, in: shortcuts)
        note("按下录音键立即开始；接着按其他组合键时自动取消。Esc 可取消本次录音。", in: shortcuts)
        maxRecordingMinutes.addItems(withTitles: VoiceOptions.recordingMinutesRange.map { "\($0) 分钟" })
        field("单次录音上限", maxRecordingMinutes, in: shortcuts)
        note("默认 10 分钟，最长 30 分钟。到达上限后自动停止并转写；修改从下次录音生效。", in: shortcuts)
        shortcuts.addArrangedSubview(muteWhileRecording)
        heading("识别与上屏", in: shortcuts)
        streaming.title = "流式识别（失败时自动改为整段上传）"
        pasteFallback.title = "未连接输入法时通过剪贴板粘贴，并恢复原剪贴板"
        shortcuts.addArrangedSubview(streaming); shortcuts.addArrangedSubview(pasteFallback)
        note("录音结束后写入原输入框，不会自动发送。输出内容在「输出模式」中设置。", in: shortcuts)
        let modesPage = page("输出模式", in: voicePages)
        let words = page("词汇与替换", in: voicePages)
        heading("识别词汇与本地清理", in: words)
        vocabulary.placeholderString = "Claude Code, cmux, LinkInput"
        replacements.placeholderString = "cloud code=Claude Code；link input=LinkInput"
        fillerWords.placeholderString = "嗯、呃（留空则不删除）"
        field("专有词汇", vocabulary, in: words); field("词语替换", replacements, in: words); field("删除口头语", fillerWords, in: words)
        note("专有词汇用于提高识别率；词语替换在转写后执行，格式为 错=对，以分号分隔。", in: words)
        let manualPage = page("AI 整理")
        title("AI 整理", in: manualPage); serviceSummary(manualServiceStatus, in: manualPage)
        draftShortcut.addItems(withTitles: Hotkeys.draftChoices.map(\.title))
        field("整理快捷键", draftShortcut, in: manualPage)
        note("处理选中文字，或当前小输入框全文；预览后采用。这里的模式与语音输出模式独立。", in: manualPage)
        heading("整理模式", in: manualPage)
        deleteManualModeButton.title = "删除模式"; deleteManualModeButton.target = self
        deleteManualModeButton.action = #selector(deleteManualMode)
        useManualMode.target = self; useManualMode.action = #selector(activateManualMode)
        let manual = modeEditor(manualModeList, use: useManualMode, add: #selector(newManualMode), delete: deleteManualModeButton, in: manualPage)
        field("名称", manualName, in: manual)
        manualName.setAccessibilityLabel("AI 整理模式名称")
        heading("模式提示词", in: manual)
        let manualScroll = NSScrollView(); manualScroll.hasVerticalScroller = true; manualScroll.borderType = .bezelBorder
        manualPrompt.isRichText = false; manualPrompt.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        manualPrompt.isAutomaticQuoteSubstitutionEnabled = false; manualPrompt.isAutomaticDashSubstitutionEnabled = false
        manualPrompt.isAutomaticTextReplacementEnabled = false; manualPrompt.isAutomaticSpellingCorrectionEnabled = false
        manualPrompt.autoresizingMask = [.width]; manualPrompt.isVerticallyResizable = true
        manualPrompt.textContainer?.widthTracksTextView = true; manualPrompt.allowsUndo = true
        manualPrompt.setAccessibilityLabel("AI 整理 System Prompt")
        manualScroll.documentView = manualPrompt; manual.addArrangedSubview(manualScroll)
        manualScroll.widthAnchor.constraint(equalTo: manual.widthAnchor, constant: -36).isActive = true
        manualScroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
        note("提示词自动保存，完整替换默认内容。输出格式须保留 JSON：text 为结果，note 为说明。", in: manual)
        manual.addArrangedSubview(NSButton(title: "恢复默认提示词", target: self, action: #selector(resetManualPrompt)))
        heading("语音输出模式", in: modesPage)
        note("录音开始时使用当前模式，也可在菜单栏切换。原文模式不调用 AI；整理失败时使用原转写。", in: modesPage)
        deleteModeButton.title = "删除模式"; deleteModeButton.target = self; deleteModeButton.action = #selector(deleteMode)
        useVoiceMode.target = self; useVoiceMode.action = #selector(activateVoiceMode)
        let modes = modeEditor(voiceModeList, use: useVoiceMode, add: #selector(newMode), delete: deleteModeButton, in: modesPage)
        field("名称", modeName, in: modes); modes.addArrangedSubview(modePolish)
        group(voicePromptSettings, in: modes)
        heading("模式提示词", in: voicePromptSettings)
        let promptScroll = NSScrollView(); promptScroll.hasVerticalScroller = true; promptScroll.borderType = .bezelBorder
        modeSystemPrompt.isRichText = false; modeSystemPrompt.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        modeSystemPrompt.isAutomaticQuoteSubstitutionEnabled = false; modeSystemPrompt.isAutomaticDashSubstitutionEnabled = false
        modeSystemPrompt.isAutomaticTextReplacementEnabled = false; modeSystemPrompt.isAutomaticSpellingCorrectionEnabled = false
        modeSystemPrompt.autoresizingMask = [.width]; modeSystemPrompt.isVerticallyResizable = true
        modeSystemPrompt.textContainer?.widthTracksTextView = true; modeSystemPrompt.allowsUndo = true
        modeSystemPrompt.setAccessibilityLabel("完整 System Prompt")
        promptScroll.documentView = modeSystemPrompt
        voicePromptSettings.addArrangedSubview(promptScroll)
        promptScroll.widthAnchor.constraint(equalTo: voicePromptSettings.widthAnchor, constant: -36).isActive = true
        promptScroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        note("可选占位符：{{CUSTOM_VOCABULARY}} 为专有词汇，{{SCENE}} 为应用场景及换行要求。删除占位符即可省略对应内容；本次转写文字另行发送。", in: voicePromptSettings)
        resetSystemPromptButton.title = "恢复默认 System Prompt"; resetSystemPromptButton.target = self
        resetSystemPromptButton.action = #selector(resetSystemPrompt)
        voicePromptSettings.addArrangedSubview(resetSystemPromptButton)
        let scenes = disclosure("高级设置 · 场景与排版", in: modesPage)
        heading("场景与排版", in: scenes)
        note("所有语音模式共用。按录音所在应用选择场景，再附上单行或多行要求，填入 System Prompt 的 {{SCENE}}。未使用该占位符的模式不附加这些内容。", in: scenes)
        sceneSelector.addItems(withTitles: ScenePromptKind.allCases.map(\.title))
        sceneSelector.target = self; sceneSelector.action = #selector(sceneSelectionChanged)
        field("编辑场景", sceneSelector, in: scenes)
        sceneDetail.font = .systemFont(ofSize: 12); sceneDetail.textColor = .secondaryLabelColor
        scenes.addArrangedSubview(sceneDetail); sceneDetail.widthAnchor.constraint(equalTo: scenes.widthAnchor, constant: -36).isActive = true
        let sceneScroll = NSScrollView(); sceneScroll.hasVerticalScroller = true; sceneScroll.borderType = .bezelBorder
        scenePrompt.isRichText = false; scenePrompt.font = .systemFont(ofSize: 13)
        scenePrompt.isAutomaticQuoteSubstitutionEnabled = false; scenePrompt.isAutomaticDashSubstitutionEnabled = false
        scenePrompt.isAutomaticTextReplacementEnabled = false; scenePrompt.isAutomaticSpellingCorrectionEnabled = false
        scenePrompt.autoresizingMask = [.width]; scenePrompt.isVerticallyResizable = true
        scenePrompt.textContainer?.widthTracksTextView = true; scenePrompt.allowsUndo = true
        scenePrompt.setAccessibilityLabel("场景提示词")
        sceneScroll.documentView = scenePrompt
        scenes.addArrangedSubview(sceneScroll)
        sceneScroll.widthAnchor.constraint(equalTo: scenes.widthAnchor, constant: -36).isActive = true
        sceneScroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        note("编辑后自动保存，下次录音生效。留空表示不附加这项提示。", in: scenes)
        scenes.addArrangedSubview(NSButton(title: "恢复当前场景默认值", target: self, action: #selector(resetScenePrompt)))
        let ai = page("模型与服务")
        title("模型与服务", in: ai)
        note("连接配置在这里统一管理。修改文本服务将同时影响语音整理和 AI 整理。", in: ai)
        heading("文本整理服务", in: ai)
        field("API 地址", llm, in: ai); field("模型", model, in: ai)
        heading("语音识别服务", in: ai)
        field("API 地址", asr, in: ai); field("模型", asrModel, in: ai)
        heading("服务凭据", in: ai)
        field("API 凭据", token, in: ai)
        credentialStatus.font = .systemFont(ofSize: 12); credentialStatus.textColor = .secondaryLabelColor
        ai.addArrangedSubview(credentialStatus)
        note("两个服务沿用同一份凭据与鉴权方式；凭据仅保存在系统钥匙串。留空保留现有凭据。", in: ai)
        let advanced = disclosure("高级连接设置", in: ai)
        format.addItems(withTitles: ["Gemini", "OpenAI 兼容"])
        auth.addItems(withTitles: ["x-internal-token", "Authorization", "xi-api-key", "api-key"])
        field("文本协议", format, in: advanced); field("鉴权方式", auth, in: advanced)
        let pricing = disclosure("费用估算（可选）", in: ai)
        note("USD 单价，留空表示未知。", in: pricing)
        field("输入 / 百万 token", inputRate, in: pricing); field("输出 / 百万 token", outputRate, in: pricing)
        field("音频 / 分钟", audioRate, in: pricing)
        let privacy = page("通用与隐私")
        title("通用与隐私", in: privacy)
        heading("云端处理授权", in: privacy)
        textConsent.title = "允许文本云端处理（语音/AI 整理与 Agent 回复建议）"
        audioConsent.title = "允许上传本次录音进行语音识别"
        privacy.addArrangedSubview(textConsent); privacy.addArrangedSubview(audioConsent)
        note("普通键盘输入始终离线。云端处理仅在你主动录音或整理时运行。", in: privacy)
        heading("隐私", in: privacy)
        note("草稿只在内存中，锁屏后清除。不会读取会话历史或文档全文，也不会上传诊断。请求只发往你在「模型与服务」中配置的服务；云端服务可能留存数据，本地清除不会删除云端记录。", in: privacy)
        field("排除应用", exclusions, in: privacy)
        note("填写应用 Bundle ID，以逗号分隔。", in: privacy)
        privacy.addArrangedSubview(NSButton(title: "管理辅助功能权限…", target: self, action: #selector(requestAccessibility)))
        heading("本地维护", in: privacy)
        privacy.addArrangedSubview(NSButton(title: "本地诊断…", target: self, action: #selector(diagnostics)))
        privacy.addArrangedSubview(NSButton(title: "清除内存草稿", target: self, action: #selector(clearDraft)))
        privacy.addArrangedSubview(NSButton(title: "清除凭据与云端授权…", target: self, action: #selector(clearData)))
        privacy.addArrangedSubview(NSButton(title: "重置全部本地数据…", target: self, action: #selector(resetData)))
        note("重置会清除 LinkInput 的学习词库、凭据与设置，并退出输入法。执行前会再次确认。", in: privacy)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        content.addArrangedSubview(status); status.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -20).isActive = true
        for field in [llm, asr, model, asrModel, token, exclusions, inputRate, outputRate, audioRate, modeName, vocabulary, replacements, fillerWords, manualName] {
            field.delegate = self
        }
        manualPrompt.delegate = self
        modeSystemPrompt.delegate = self
        scenePrompt.delegate = self
        let controls: [NSControl] = [inputScheme, candidateCount, candidateRows, mixedPinyin, expandedPinyin,
            textConsent, audioConsent, format, auth, draftShortcut, voiceShortcut, voiceMode, streaming,
            currentMode, modePolish, pasteFallback, muteWhileRecording, currentManualMode] + Array(fuzzyButtons.values)
        for control in controls { control.target = self; control.action = #selector(saveControlChange) }
        maxRecordingMinutes.target = self; maxRecordingMinutes.action = #selector(saveRecordingLimit)
        voicePages.selectTabViewItem(at: 0); voiceSections.selectedSegment = 0
        load(); selectPage(0)
        window.setContentSize(NSSize(width: 1040, height: 740)); window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func selectPage(_ index: Int) {
        // Ending field editing flushes credentials and any debounced text before hiding the field.
        window?.makeFirstResponder(nil)
        if hasUnsavedChanges { saveSettings() }
        pages.selectTabViewItem(at: index)
        sidebarHost?.rootView = settingsSidebar(selected: index)
    }
    private func settingsSidebar(selected: Int) -> LinkSidebar {
        let titles = ["输入法", "语音输入", "AI 整理", "模型与服务", "通用与隐私"]
        let subtitles = ["方案与候选", "录音与输出模式", "选区与整理模式", "连接与凭据", "授权与本地维护"]
        let icons = ["keyboard", "mic", "sparkles", "server.rack", "gearshape"]
        return LinkSidebar(title: "LinkInput", subtitle: "打字、语音与 AI 整理", footer: "LinkAll · 设置自动保存",
                           items: titles.indices.map { LinkSidebarItem(id: String($0), title: titles[$0], subtitle: subtitles[$0], symbol: icons[$0]) },
                           selected: String(selected)) { [weak self] id in
            if let index = Int(id) { self?.selectPage(index) }
        }
    }
    @objc private func openServices() { selectPage(3) }
    @objc private func openPrivacy() { selectPage(4) }
    @objc private func changeVoiceSection() {
        window?.makeFirstResponder(nil)
        if hasUnsavedChanges { saveSettings() }
        voicePages.selectTabViewItem(at: max(0, voiceSections.selectedSegment))
    }
    private func updateInputVisibility() {
        let scheme = InputScheme.allCases[max(0, inputScheme.indexOfSelectedItem)]
        doublePinyinSettings.isHidden = scheme != .flypy
        pinyinSettings.isHidden = scheme != .flypy && scheme != .pinyin
    }
    private func updateServiceStatus() {
        let c = Preferences.shared.config
        let text = c.textAllowed ? "文本处理已授权" : "文本处理未授权"
        voiceServiceStatus.stringValue = "识别：\(c.asrModel) · \(c.audioAllowed ? "录音上传已授权" : "录音上传未授权")\n整理：\(c.model) · \(text)"
        manualServiceStatus.stringValue = "文本服务：\(c.model) · \(text)"
        Task { @MainActor [weak self] in
            let exists = await Preferences.shared.hasTokenAsync()
            self?.credentialStatus.stringValue = exists ? "凭据已保存到钥匙串。" : "尚未配置凭据。"
        }
    }
    private func renderModeList(_ list: NSStackView, names: [String], current: Int, editing: Int, action: Selector) {
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, name) in names.enumerated() {
            let button = NSButton(title: name + (index == current ? " · 当前使用" : ""), target: self, action: action)
            button.tag = index; button.setButtonType(.pushOnPushOff); button.bezelStyle = .recessed
            button.state = index == editing ? .on : .off; button.alignment = .left
            button.lineBreakMode = .byTruncatingTail; button.toolTip = button.title
            button.setAccessibilityLabel(button.title)
            list.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
    }
    @objc private func editVoiceMode(_ sender: NSButton) {
        window?.makeFirstResponder(nil)
        editMode.selectItem(at: sender.tag); modeSelectionChanged()
    }
    @objc private func selectManualEditor(_ sender: NSButton) {
        window?.makeFirstResponder(nil)
        editManualMode.selectItem(at: sender.tag); manualModeChanged()
    }
    @objc private func activateVoiceMode() {
        currentMode.selectItem(at: editingIndex); saveControlChange()
    }
    @objc private func activateManualMode() {
        currentManualMode.selectItem(at: editingManualIndex); saveControlChange()
    }
    func load() {
        // Reopening an already visible window must not overwrite edits that failed validation.
        if hasUnsavedChanges { saveSettings(); if hasUnsavedChanges { return } }
        saveWork?.cancel(); saveWork = nil
        let c = Preferences.shared.config
        let options = Preferences.shared.inputOptions
        inputScheme.selectItem(at: InputScheme.allCases.firstIndex(of: Preferences.shared.scheme) ?? 0)
        candidateCount.selectItem(at: options.pageSize - 5)
        candidateRows.selectItem(at: options.visibleCandidateRows - 3)
        mixedPinyin.state = options.fullPinyinInDoublePinyin ? .on : .off
        expandedPinyin.state = options.showFullPinyin ? .on : .off
        for (pair, button) in fuzzyButtons { button.state = options.fuzzyPairs.contains(pair) ? .on : .off }
        status.stringValue = "设置自动保存。"
        llm.stringValue = c.llmURL; asr.stringValue = c.asrURL; model.stringValue = c.model; asrModel.stringValue = c.asrModel
        textConsent.state = c.textAllowed ? .on : .off; audioConsent.state = c.audioAllowed ? .on : .off
        exclusions.stringValue = c.excludedApps.joined(separator: ",")
        format.selectItem(at: c.format == .gemini ? 0 : 1); auth.selectItem(withTitle: c.authHeader)
        token.stringValue = ""; token.placeholderString = "留空保留现有凭据"
        draftShortcut.selectItem(at: min(Hotkeys.draftChoices.count - 1, max(0, UserDefaults.standard.integer(forKey: "draftShortcut"))))
        voiceShortcut.selectItem(at: min(Hotkeys.voiceChoices.count - 1, max(0, UserDefaults.standard.integer(forKey: "voiceShortcut"))))
        editingManual = Preferences.shared.manualOptions
        editingManualIndex = editingManual.modes.firstIndex { $0.id == editingManual.selectedMode.id } ?? 0
        refreshManualModeMenus(current: editingManual.selectedMode.id); showManualMode()
        let voice = Preferences.shared.voiceOptions
        editingScenes = voice.scenePrompts; showScene()
        voiceMode.selectItem(at: RecordMode.allCases.firstIndex(of: voice.recordMode) ?? 0)
        maxRecordingMinutes.selectItem(at: voice.maxRecordingMinutes - VoiceOptions.recordingMinutesRange.lowerBound)
        streaming.state = voice.streaming ? .on : .off
        editingModes = voice.modes
        editingIndex = editingModes.firstIndex { $0.id == voice.selectedMode.id } ?? 0
        refreshModeMenus(current: voice.selectedMode.id); showMode()
        pasteFallback.state = voice.pasteFallback ? .on : .off; muteWhileRecording.state = voice.muteWhileRecording ? .on : .off
        vocabulary.stringValue = voice.vocabulary.joined(separator: ", ")
        replacements.stringValue = voice.replacements.map { "\($0.from)=\($0.to)" }.joined(separator: "；")
        fillerWords.stringValue = voice.fillerWords.joined(separator: "、")
        inputRate.stringValue = c.inputUSDPerMillion.map { String($0) } ?? ""
        outputRate.stringValue = c.outputUSDPerMillion.map { String($0) } ?? ""
        audioRate.stringValue = c.audioUSDPerMinute.map { String($0) } ?? ""
        updateInputVisibility(); updateServiceStatus()
    }
    private func scheduleSave() {
        hasUnsavedChanges = true; saveWork?.cancel()
        status.stringValue = "正在保存…"
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Do not persist half-composed Chinese text.
            if self.modeSystemPrompt.hasMarkedText() || (self.window?.firstResponder as? NSTextView)?.hasMarkedText() == true {
                self.scheduleSave(); return
            }
            self.saveSettings()
        }
        saveWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
    @objc private func saveControlChange() {
        hasUnsavedChanges = true; saveSettings(); updateInputVisibility()
        voicePromptSettings.isHidden = modePolish.state != .on
    }
    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSTextField) === token {
            credentialEditing = true; hasUnsavedChanges = true
            status.stringValue = "凭据输入结束后自动保存。"; return
        }
        scheduleSave()
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if (notification.object as? NSTextField) === token { credentialEditing = false }
        if hasUnsavedChanges { saveSettings() }
    }
    func textDidChange(_ notification: Notification) { scheduleSave() }
    func windowWillClose(_ notification: Notification) {
        credentialEditing = false
        if hasUnsavedChanges { saveSettings() }
    }
    private func saveSettings() {
        saveWork?.cancel(); saveWork = nil
        commitMode()
        commitScene()
        commitManualMode()
        if let empty = editingManual.modes.first(where: { $0.effectivePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            status.stringValue = "AI 整理模式「\(empty.name)」的 System Prompt 不能为空，请填写或恢复默认。"; return
        }
        editingManual.selectedModeID = currentManualModeID
        if let empty = editingModes.first(where: { $0.polish && $0.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true }) {
            status.stringValue = "「\(empty.name)」的 System Prompt 不能为空，请填写或恢复默认。"; return
        }
        var c = Preferences.shared.config
        c.llmURL = llm.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        c.asrURL = asr.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard [c.llmURL, c.asrURL].allSatisfy({ URL(string: $0)?.scheme == "https" && URL(string: $0)?.host != nil && URL(string: $0)?.user == nil }) else { status.stringValue = "请输入有效的 HTTPS API 地址"; return }
        c.model = model.stringValue; c.asrModel = asrModel.stringValue
        c.format = format.indexOfSelectedItem == 0 ? .gemini : .openAI; c.authHeader = auth.titleOfSelectedItem ?? "x-internal-token"
        c.textAllowed = textConsent.state == .on; c.audioAllowed = audioConsent.state == .on
        c.excludedApps = exclusions.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let prices = [inputRate, outputRate, audioRate].map { $0.stringValue.trimmingCharacters(in: .whitespaces) }
        guard prices.allSatisfy({ $0.isEmpty || (Double($0).map { $0.isFinite && $0 >= 0 } ?? false) }) else { status.stringValue = "单价请填非负数字，未知请留空。"; return }
        c.inputUSDPerMillion = Double(prices[0]); c.outputUSDPerMillion = Double(prices[1]); c.audioUSDPerMinute = Double(prices[2])
        var options = InputOptions()
        options.candidateCount = candidateCount.indexOfSelectedItem + 5
        options.expandedCandidateRows = candidateRows.indexOfSelectedItem + 3
        options.fullPinyinInDoublePinyin = mixedPinyin.state == .on
        options.showFullPinyin = expandedPinyin.state == .on
        options.fuzzyPairs = Set(fuzzyButtons.filter { $0.value.state == .on }.map(\.key))
        do {
            if options != Preferences.shared.inputOptions { try RimeEngine.configure(options) }
        } catch { status.stringValue = "输入配置未保存：" + error.localizedDescription; return }
        do {
            if !credentialEditing {
                try Preferences.shared.saveToken(token.stringValue); token.stringValue = ""
            }
            Preferences.shared.config = c
            Preferences.shared.manualOptions = editingManual
            refreshManualModeMenus(current: editingManual.selectedModeID)
            Preferences.shared.inputOptions = options
            Preferences.shared.scheme = InputScheme.allCases[inputScheme.indexOfSelectedItem]
            UserDefaults.standard.set(draftShortcut.indexOfSelectedItem, forKey: "draftShortcut")
            UserDefaults.standard.set(voiceShortcut.indexOfSelectedItem, forKey: "voiceShortcut")
            var voice = Preferences.shared.voiceOptions
            voice.recordMode = RecordMode.allCases[max(0, voiceMode.indexOfSelectedItem)]
            voice.maxRecordingMinutes = maxRecordingMinutes.indexOfSelectedItem + VoiceOptions.recordingMinutesRange.lowerBound
            voice.streaming = streaming.state == .on
            commitMode()
            voice.modes = editingModes
            voice.scenePrompts = editingScenes
            voice.selectedModeID = editingModes[min(max(0, currentMode.indexOfSelectedItem), editingModes.count - 1)].id
            voice.pasteFallback = pasteFallback.state == .on; voice.muteWhileRecording = muteWhileRecording.state == .on
            voice.vocabulary = VoiceOptions.parseList(vocabulary.stringValue)
            voice.replacements = VoiceOptions.parseReplacements(replacements.stringValue)
            voice.fillerWords = VoiceOptions.parseList(fillerWords.stringValue)
            Preferences.shared.voiceOptions = voice
            refreshModeMenus(current: voice.selectedModeID)
            hasUnsavedChanges = credentialEditing
            status.stringValue = Hotkeys.shared.configure() ?? (credentialEditing ? "凭据输入结束后自动保存。" : "已自动保存。")
            updateServiceStatus()
            onSave?()
        }
        catch { try? RimeEngine.configure(Preferences.shared.inputOptions); status.stringValue = "无法保存钥匙串凭据，请检查系统授权。" }
    }
    private var currentManualModeID: UUID {
        editingManual.modes[min(max(0, currentManualMode.indexOfSelectedItem), editingManual.modes.count - 1)].id
    }
    private func refreshManualModeMenus(current: UUID) {
        for popup in [currentManualMode, editManualMode] {
            popup.removeAllItems()
            // Let NSPopUpButton install its selection action, then restore names (which may repeat).
            for index in editingManual.modes.indices { popup.addItem(withTitle: String(index)) }
            for (item, mode) in zip(popup.itemArray, editingManual.modes) { item.title = mode.name }
        }
        currentManualMode.selectItem(at: editingManual.modes.firstIndex { $0.id == current } ?? 0)
        editManualMode.selectItem(at: editingManualIndex)
        renderModeList(manualModeList, names: editingManual.modes.map(\.name), current: currentManualMode.indexOfSelectedItem,
                       editing: editingManualIndex, action: #selector(selectManualEditor(_:)))
        useManualMode.title = currentManualMode.indexOfSelectedItem == editingManualIndex ? "当前使用的模式" : "设为当前模式"
        useManualMode.isEnabled = currentManualMode.indexOfSelectedItem != editingManualIndex
    }
    private func showManualMode() {
        let mode = editingManual.modes[editingManualIndex]
        manualName.stringValue = mode.name; manualName.isEditable = !mode.isBuiltIn
        manualPrompt.string = mode.effectivePrompt; manualPrompt.undoManager?.removeAllActions()
        deleteManualModeButton.isEnabled = !mode.isBuiltIn
    }
    private func commitManualMode() {
        guard editingManual.modes.indices.contains(editingManualIndex) else { return }
        var mode = editingManual.modes[editingManualIndex]
        if !mode.isBuiltIn {
            let name = manualName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            mode.name = name.isEmpty ? "未命名模式" : name
        }
        mode.systemPrompt = manualPrompt.string == ExpressionGuard.systemPrompt ? nil : manualPrompt.string
        editingManual.modes[editingManualIndex] = mode
    }
    @objc private func manualModeChanged() {
        let current = currentManualModeID
        commitManualMode(); editingManualIndex = max(0, editManualMode.indexOfSelectedItem)
        refreshManualModeMenus(current: current); showManualMode()
        if hasUnsavedChanges { saveSettings() }
    }
    @objc private func newManualMode() {
        let current = currentManualModeID
        commitManualMode(); editingManual.modes.append(ManualMode(name: "新模式"))
        editingManualIndex = editingManual.modes.count - 1
        refreshManualModeMenus(current: current); showManualMode(); saveControlChange(); window?.makeFirstResponder(manualName)
    }
    @objc private func deleteManualMode() {
        guard !editingManual.modes[editingManualIndex].isBuiltIn else { return }
        let current = currentManualModeID == editingManual.modes[editingManualIndex].id ? ManualMode.defaultID : currentManualModeID
        editingManual.modes.remove(at: editingManualIndex); editingManualIndex = max(0, editingManualIndex - 1)
        refreshManualModeMenus(current: current); showManualMode(); saveControlChange()
    }
    @objc private func resetManualPrompt() {
        manualPrompt.string = ExpressionGuard.systemPrompt; manualPrompt.undoManager?.removeAllActions(); saveControlChange()
    }
    /// Items are added one by one: `addItems(withTitles:)` silently drops duplicate names.
    private func refreshModeMenus(current: UUID) {
        for popup in [currentMode, editMode] {
            popup.removeAllItems()
            for index in editingModes.indices { popup.addItem(withTitle: String(index)) }
            for (item, mode) in zip(popup.itemArray, editingModes) { item.title = mode.name }
        }
        currentMode.selectItem(at: editingModes.firstIndex { $0.id == current } ?? 0); editMode.selectItem(at: editingIndex)
        renderModeList(voiceModeList, names: editingModes.map(\.name), current: currentMode.indexOfSelectedItem,
                       editing: editingIndex, action: #selector(editVoiceMode(_:)))
        useVoiceMode.title = currentMode.indexOfSelectedItem == editingIndex ? "当前使用的模式" : "设为当前模式"
        useVoiceMode.isEnabled = currentMode.indexOfSelectedItem != editingIndex
    }
    private func showMode() {
        let mode = editingModes[editingIndex]
        modeName.stringValue = mode.name; modeName.isEditable = !mode.isBuiltIn
        modePolish.state = mode.polish ? .on : .off; modePolish.isEnabled = !mode.isBuiltIn
        voicePromptSettings.isHidden = !mode.polish
        modeSystemPrompt.string = mode.systemPrompt ?? ExpressionGuard.dictationTemplate
        modeSystemPrompt.undoManager?.removeAllActions()
        modeSystemPrompt.isEditable = mode.polish || !mode.isBuiltIn
        resetSystemPromptButton.isEnabled = modeSystemPrompt.isEditable
        deleteModeButton.isEnabled = !mode.isBuiltIn
    }
    private func commitMode() {
        guard editingModes.indices.contains(editingIndex) else { return }
        var mode = editingModes[editingIndex]
        if !mode.isBuiltIn {
            let name = modeName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            mode.name = name.isEmpty ? "未命名模式" : name; mode.polish = modePolish.state == .on
        }
        mode.systemPrompt = modeSystemPrompt.string == ExpressionGuard.dictationTemplate ? nil : modeSystemPrompt.string
        editingModes[editingIndex] = mode
    }
    private func showScene() {
        sceneSelector.selectItem(at: ScenePromptKind.allCases.firstIndex(of: editingSceneKind) ?? 0)
        scenePrompt.string = editingScenes[editingSceneKind]
        scenePrompt.undoManager?.removeAllActions()
        sceneDetail.stringValue = editingSceneKind.detail
    }
    private func commitScene() { editingScenes[editingSceneKind] = scenePrompt.string }
    @objc private func sceneSelectionChanged() {
        commitScene()
        editingSceneKind = ScenePromptKind.allCases[max(0, sceneSelector.indexOfSelectedItem)]
        showScene()
        if hasUnsavedChanges { saveSettings() }
    }
    @objc private func resetScenePrompt() {
        editingScenes.reset(editingSceneKind); showScene(); saveControlChange()
    }
    private var currentModeID: UUID { editingModes[min(max(0, currentMode.indexOfSelectedItem), editingModes.count - 1)].id }
    @objc private func modeSelectionChanged() {
        let current = currentModeID
        commitMode(); editingIndex = max(0, editMode.indexOfSelectedItem); refreshModeMenus(current: current); showMode()
        if hasUnsavedChanges { saveSettings() }
    }
    @objc private func newMode() {
        let current = currentModeID
        commitMode(); editingModes.append(DictationMode(name: "新模式"))
        editingIndex = editingModes.count - 1; refreshModeMenus(current: current); showMode()
        saveControlChange()
        window?.makeFirstResponder(modeName)
    }
    @objc private func deleteMode() {
        guard !editingModes[editingIndex].isBuiltIn else { return }
        let current = currentModeID == editingModes[editingIndex].id ? DictationMode.polishID : currentModeID
        editingModes.remove(at: editingIndex); editingIndex = max(0, editingIndex - 1)
        refreshModeMenus(current: current); showMode()
        saveControlChange()
    }
    @objc private func resetSystemPrompt() {
        guard modeSystemPrompt.isEditable else { return }
        modeSystemPrompt.string = ExpressionGuard.dictationTemplate
        modeSystemPrompt.undoManager?.removeAllActions()
        saveControlChange()
    }
    @objc private func saveRecordingLimit() {
        // This setting applies to the next recording; other settings retain their cancellation policy.
        Preferences.shared.voiceOptions.maxRecordingMinutes = maxRecordingMinutes.indexOfSelectedItem + VoiceOptions.recordingMinutesRange.lowerBound
        status.stringValue = "已自动保存，下次录音生效。"
    }
    @objc private func requestAccessibility() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
    @objc private func diagnostics() { onDiagnostics?() }
    @objc private func resetData() { if hasUnsavedChanges { saveSettings() }; onReset?() }
    @objc private func clearDraft() { Coordinator.shared.clear(); status.stringValue = "已清除内存草稿。" }
    @objc private func clearData() {
        let alert = NSAlert(); alert.messageText = "清除 API 凭据与云端授权？"
        alert.informativeText = "同时清除内存草稿，保留输入设置与学习词库。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        saveWork?.cancel(); saveWork = nil; hasUnsavedChanges = false; credentialEditing = false; token.stringValue = ""
        Preferences.shared.clearToken(); Preferences.shared.config.textAllowed = false; Preferences.shared.config.audioAllowed = false
        Coordinator.shared.clear(); onSave?(); load(); status.stringValue = "已清除 API 凭据和内存草稿，撤回云端授权。Rime 用户词库保留。"
    }
}
