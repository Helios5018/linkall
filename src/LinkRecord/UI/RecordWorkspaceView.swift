import SwiftUI
import AppKit
import LinkRecordCore
import LinkAllShared
import LinkAllUI

public struct RecordWorkspaceView: View {
    @ObservedObject var model: RecordModel
    public init(model: RecordModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: LinkBrand.record.image(size: 28, tile: true)).renderingMode(.original).foregroundStyle(LinkAppearance.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("LinkRecord · 记录与桌宠").font(LinkAppearance.titleFont)
                    Text(model.desktopStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("页面", selection: $model.page) { Text("时间线").tag(RecordPage.timeline); Text("桌宠与换装").tag(RecordPage.pet); Text("记录设置").tag(RecordPage.settings) }.pickerStyle(.segmented).labelsHidden().frame(width: 330)
                Button(model.settings.paused ? "恢复记录" : "暂停记录") { model.togglePause() }
            }.padding(LinkAppearance.pageInset)
            Divider()
            if !model.message.isEmpty {
                HStack { Text(model.message).font(.callout); Spacer(); Button("知道了") { model.message = "" } }.padding(10).background(Color.orange.opacity(0.1))
            }
            if model.page == .timeline { timeline }
            else if model.page == .pet { petSettings }
            else { recordingSettings }
        }.frame(minWidth: 900, minHeight: 620)
    }
    private var timeline: some View {
        HSplitView {
            VStack(spacing: 12) {
                TextField("搜索文字、应用、窗口或备注", text: $model.query).textFieldStyle(.roundedBorder)
                HStack {
                    Picker("类型", selection: $model.kind) { Text("全部类型").tag(RecordKind?.none); ForEach(RecordKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) } }.labelsHidden()
                    Toggle("重要", isOn: $model.starredOnly).toggleStyle(.checkbox)
                }
                List(selection: $model.selected) {
                    ForEach(model.records) { record in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(record.kind.title).font(.caption.bold()).foregroundStyle(LinkAppearance.accent)
                                if record.starred { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                                Spacer(); Text(record.date, format: .dateTime.month().day().hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(record.displayText.isEmpty ? record.appName : record.displayText).font(.system(size: 13)).lineLimit(2)
                            Text([record.appName, record.window].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.padding(.vertical, 5).tag(record.id)
                    }
                }.listStyle(.inset)
                HStack {
                    Text("\(model.records.count) 条").font(.caption).foregroundStyle(.secondary)
                    Spacer(); Button("加载更多") { model.limit += 200; model.reload() }; Button("刷新") { model.reload() }
                }
            }.padding(16).frame(minWidth: 310, idealWidth: 350, maxWidth: 430)
            if let record = model.selectedRecord { RecordDetail(record: record, model: model).id(record.id).frame(minWidth: 450) }
            else {
                VStack(spacing: 15) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 42)).foregroundStyle(LinkAppearance.accent.opacity(0.7))
                    Text(model.records.isEmpty ? "从下一次输入开始，留住你的思路" : "选择一条记录，看看当时的你").font(.title3)
                    Text("打字、语音与整理结果只保存在本机。\n记录上屏不代表消息已经发送。").multilineTextAlignment(.center).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private var petSettings: some View {
        HStack(spacing: 45) {
            VStack(spacing: 20) {
                PetArt(style: model.settings.petStyle, tint: model.settings.petColor, accessory: model.settings.petAccessory, action: model.playing, customPath: model.settings.petImage).frame(width: 250, height: 260)
                Text(model.settings.petName).font(.system(size: 30, weight: .bold, design: .rounded))
                Text("陪你工作，也陪你发一会儿呆。").foregroundStyle(.secondary)
                HStack { Button("摸摸 ♡") { model.play("摸摸") }; Button("喂食 🍪") { model.play("喂食") }; Button("追球 🧶") { model.play("追球") } }
                Text(model.playing.isEmpty ? "本次打开一起玩了 \(model.playCount) 次" : "\(model.playing)中…").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
            Form {
                Toggle("在桌面显示小伙伴", isOn: $model.settings.petVisible).accessibilityLabel("在桌面显示小伙伴")
                TextField("名字", text: $model.settings.petName)
                Picker("外形", selection: $model.settings.petStyle) { Text("糯米猫").tag("cat"); Text("棉花兔").tag("bunny"); if !model.settings.petImage.isEmpty { Text("自定义图片").tag("custom") } }
                Picker("毛色", selection: $model.settings.petColor) { Text("奶油").tag("cream"); Text("蜜桃").tag("rose"); Text("薄荷").tag("mint"); Text("香芋").tag("lavender") }.disabled(model.settings.petStyle == "custom")
                Picker("饰品", selection: $model.settings.petAccessory) { Text("小围巾").tag("scarf"); Text("小花").tag("flower"); Text("蝴蝶结").tag("bow"); Text("不佩戴").tag("none") }.disabled(model.settings.petStyle == "custom")
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("桌宠大小"); Spacer(); Text("\(Int(model.settings.petSize)) pt").monospacedDigit().foregroundStyle(.secondary) }
                    Slider(value: $model.settings.petSize, in: PetSizing.range, step: 10)
                        .accessibilityLabel("桌宠大小").accessibilityValue("\(Int(model.settings.petSize)) pt")
                    HStack {
                        Text("小").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复默认") { model.settings.petSize = PetSizing.standard }
                        Spacer()
                        Text("大").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("80–360 pt，拖动立即生效。").font(.caption).foregroundStyle(.secondary)
                }
                Button(model.settings.petStyle == "custom" ? "替换自定义图片…" : "导入自己的形象…") { model.importPet() }
                Text(model.settings.petStyle == "custom" ? "自定义图片保留原貌，不叠加毛色或饰品；可继续摸摸、喂食和追球。通过上方「外形」可随时切回猫或兔。" : "支持 PNG / JPEG / HEIC / TIFF，推荐透明背景 PNG。").font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("隐藏桌宠不影响记录。小伙伴的玩法只是陪伴，不会替你操作其他应用。").font(.callout).foregroundStyle(.secondary)
            }.formStyle(.grouped).frame(width: 360)
        }.padding(30).onChange(of: model.settings) { model.saveSettings() }
    }
    private var recordingSettings: some View {
        Form {
            Section("记录范围") {
                Toggle("记录打字、语音转写与 AI 整理", isOn: $model.settings.input).accessibilityLabel("记录打字、语音转写与 AI 整理")
                Toggle("记录前台应用与窗口变化", isOn: $model.settings.desktop).accessibilityLabel("记录前台应用与窗口变化")
                Toggle("保存桌面截图与识别文字", isOn: $model.settings.screenshots).accessibilityLabel("保存桌面截图与识别文字")
                Text("仅记录经过 LinkInput 的输入。语音保存原始转写与整理结果，不保存录音文件。桌面抽样当前应用所在屏幕，并读取可确认可见的应用文字；不会读取滚动区域外的全文。OCR 可能认错字，抽样也可能漏过短暂内容。").font(.caption).foregroundStyle(.secondary)
            }
            Section("截图与存储") {
                Picker("抽样间隔", selection: $model.settings.screenshotSeconds) { Text("10 秒").tag(10.0); Text("20 秒").tag(20.0); Text("30 秒").tag(30.0); Text("60 秒").tag(60.0) }
                Stepper("截图保留 \(model.settings.retentionDays) 天", value: $model.settings.retentionDays, in: 1...30)
                Picker("截图容量上限", selection: $model.settings.maxImageMB) { Text("100 MB").tag(100); Text("1 GB").tag(1024); Text("5 GB").tag(5120); Text("10 GB").tag(10240); Text("100 GB").tag(102400) }
                Text("截图当前占用：\(ByteCountFormatter.string(fromByteCount: model.imageBytes, countStyle: .file))。达到期限或容量时先删除旧截图，重要片段也受容量约束；文字、备注和来源继续保留。").font(.caption).foregroundStyle(.secondary)
            }
            Section("权限与排除") {
                HStack {
                    Button("授权窗口标题读取") { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
                    Button("授权屏幕录制") { if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) } }
                }
                TextField("不记录的应用 Bundle ID（逗号分隔）", text: Binding(get: { model.settings.excludedApps.joined(separator: ", ") }, set: { model.settings.excludedApps = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }))
                Text("锁屏、安全输入和排除的应用不采集。历史不会自动上传，也不会进入诊断日志。").font(.caption).foregroundStyle(.secondary)
            }
            Section("管理记录") {
                HStack { Button("打开本地记录目录") { NSWorkspace.shared.open(model.store.directory) }; Button("删除最近 5 分钟…") { model.deleteRecent() } }
                Text("记录默认长期保留，可在时间线逐条删除。删除原始截图后，仅凭文字无法完整还原屏幕。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).onChange(of: model.settings) { model.saveSettings() }
    }
}

private struct RecordDetail: View {
    let record: HistoryRecord
    @ObservedObject var model: RecordModel
    @State private var note = ""
    @State private var related: [HistoryRecord] = []
    @State private var relatedError = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(record.kind.title).font(.title2.bold()); Spacer()
                    Button { var changed = record; changed.starred.toggle(); model.update(changed) } label: { Image(systemName: record.starred ? "star.fill" : "star") }
                    Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.displayText, forType: .string) }
                    Button("删除", role: .destructive) { model.delete(record) }
                }
                Text(record.date.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.secondary)
                if record.kind == .screenshot, record.ended > record.date {
                    Text("相同画面最后采到于 \(record.ended.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                }
                Text([record.appName, record.app, record.window].filter { !$0.isEmpty }.joined(separator: "\n")).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Text(record.status).font(.caption.bold()).padding(8).background(LinkAppearance.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                if record.kind == .activity {
                    Text("记录到 \(record.ended.formatted(date: .omitted, time: .standard))；应用活动本身只记录窗口与时间。").font(.caption).foregroundStyle(.secondary)
                    Text("这次停留的屏幕内容").font(.headline)
                    if relatedError { Text("屏幕记录读取失败，请刷新后重试。").foregroundStyle(.secondary) }
                    else if related.isEmpty { Text("没有关联的屏幕片段。抽样可能漏过短暂停留；也请确认记录设置中的截图开关和系统授权。").foregroundStyle(.secondary) }
                    ForEach(related) { photo in
                        RelatedScreen(record: photo, store: model.store, initiallyExpanded: photo.id == related.first?.id)
                    }
                    Button("查看这个应用的全部屏幕片段") { model.selected = nil; model.kind = .screenshot; model.query = record.app }
                }
                if !record.original.isEmpty { block(record.kind == .voice ? "原始转写" : record.kind == .screenshot ? "屏幕识别文字" : "原文", record.original) }
                if let snapshot = record.screenText { ScreenTextSources(snapshot: snapshot) }
                if !record.result.isEmpty { block("整理结果", record.result) }
                if !record.delivered.isEmpty, record.delivered != record.result { block("交付文字", record.delivered) }
                if let path = model.store.imageURL(record.image) {
                    if let image = NSImage(contentsOf: path) {
                        ScreenCapturePreview(image: image, snapshot: record.screenText)
                        Button("打开截图") { NSWorkspace.shared.open(path) }
                    } else { Text("原始截图已按保留规则清理；文字仍可搜索。").font(.caption).foregroundStyle(.secondary) }
                }
                Divider(); Text("给这段记忆加一句备注").font(.headline)
                TextEditor(text: $note).frame(minHeight: 70).border(.secondary.opacity(0.2))
                Button("保存备注") { var changed = record; changed.note = note; model.update(changed) }
            }.padding(24)
        }.onAppear { note = record.note }
        .task(id: record.ended) {
            guard record.kind == .activity else { return }
            do {
                let store = model.store, activity = record
                let rows = try await Task.detached(priority: .utility) { try store.relatedScreenshots(to: activity) }.value
                guard !Task.isCancelled else { return }; related = rows; relatedError = false
            } catch { if !Task.isCancelled { relatedError = true } }
        }
    }
    private func block(_ title: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); Text(content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)) }
    }
}

private struct RelatedScreen: View {
    let record: HistoryRecord
    let store: HistoryStore
    @State private var expanded: Bool
    init(record: HistoryRecord, store: HistoryStore, initiallyExpanded: Bool) {
        self.record = record; self.store = store; _expanded = State(initialValue: initiallyExpanded)
    }
    var body: some View {
        DisclosureGroup("屏幕片段 · " + record.date.formatted(date: .omitted, time: .standard), isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(record.original.isEmpty ? "未识别到文字，可查看截图。" : record.original).textSelection(.enabled)
                    if let snapshot = record.screenText { ScreenTextSources(snapshot: snapshot) }
                    if record.ended > record.date {
                        Text("相同画面最后采到于 \(record.ended.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                    }
                    if let url = store.imageURL(record.image), let image = NSImage(contentsOf: url) {
                        ScreenCapturePreview(image: image, snapshot: record.screenText)
                        Button("打开原始截图") { NSWorkspace.shared.open(url) }
                    } else { Text("原始截图已清理，识别文字仍然保留。").font(.caption).foregroundStyle(.secondary) }
                    Text("OCR 可能错漏；这是当时的可见画面，不是完整聊天记录。").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }
        }
    }
}

private struct ScreenTextSources: View {
    let snapshot: ScreenTextSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("应用可见文字 \(snapshot.accessibility.count) 处 · 图片识别 \(snapshot.ocrBlocks.count) 处").font(.caption).foregroundStyle(.secondary)
            if snapshot.accessibility.isEmpty {
                Text("未取得可确认可见的应用文字，当前使用图片识别结果。").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("查看文字来源") {
                ForEach(Array(snapshot.readingBlocks.prefix(120).enumerated()), id: \.offset) { _, block in
                    HStack(alignment: .top) {
                        Text(block.source == .accessibility ? "应用文字" : "图片识别").font(.caption).foregroundStyle(.secondary).frame(width: 60)
                        Text(block.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if let confidence = block.confidence {
                            Text(confidence, format: .percent.precision(.fractionLength(0))).font(.caption).foregroundStyle(.secondary).help("识别器置信度，不等同于准确率")
                        }
                    }.padding(.vertical, 3)
                }
                if snapshot.readingBlocks.count > 120 { Text("更多文字保留在上方完整正文中。").font(.caption) }
            }
            if !snapshot.accessibility.isEmpty {
                DisclosureGroup("核对原始图片识别文字") {
                    Text(snapshot.ocrBlocks.map(\.text).joined(separator: "\n")).textSelection(.enabled)
                }
            }
        }
    }
}

private struct ScreenCapturePreview: View {
    let image: NSImage
    let snapshot: ScreenTextSnapshot?
    @State private var showBounds = false
    var body: some View {
        VStack(alignment: .leading) {
            if snapshot != nil { Toggle("显示文字位置（蓝色为应用文字，橙色为图片识别）", isOn: $showBounds).font(.caption) }
            Image(nsImage: image).resizable().scaledToFit().overlay {
                if showBounds, let snapshot {
                    GeometryReader { geometry in
                        ForEach(Array(snapshot.readingBlocks.enumerated()), id: \.offset) { _, block in
                            Rectangle().stroke(block.source == .accessibility ? Color.blue : Color.orange, lineWidth: 1)
                                .frame(width: block.bounds.width * geometry.size.width, height: block.bounds.height * geometry.size.height)
                                .position(x: (block.bounds.x + block.bounds.width / 2) * geometry.size.width, y: (block.bounds.y + block.bounds.height / 2) * geometry.size.height)
                        }
                    }.allowsHitTesting(false)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
