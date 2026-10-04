import SwiftUI
import AppKit
import LinkRecordCore

struct PetView: View {
    @ObservedObject var model: RecordModel
    @State private var bounce = false
    @State private var ball = false
    private var scale: CGFloat { model.settings.petSize / PetSizing.standard }
    var body: some View {
        VStack(spacing: 0) {
            if !model.playing.isEmpty {
                Text(model.playing == "摸摸" ? "呼噜呼噜 ♡" : model.playing == "喂食" ? "嚼嚼，好吃！" : "接住啦！")
                    .font(.system(size: 12, weight: .medium, design: .rounded)).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule()).transition(.opacity)
            } else { Color.clear.frame(height: 26) }
            ZStack {
                PetArt(style: model.settings.petStyle, tint: model.settings.petColor, accessory: model.settings.petAccessory, action: model.playing, customPath: model.settings.petImage)
                    .offset(x: model.playing == "追球" && bounce ? 15 * scale : 0, y: bounce ? -7 * scale : 0)
                    .rotationEffect(.degrees(model.playing == "摸摸" && bounce ? -7 : 0))
                if model.playing == "喂食" { Text("🍪").font(.system(size: 30 * scale)).offset(x: 24 * scale, y: 22 * scale) }
                if model.playing == "摸摸" { Text("💕").font(.system(size: 25 * scale)).offset(x: 45 * scale, y: -50 * scale) }
                if model.playing == "追球" { Text("🧶").font(.system(size: 27 * scale)).offset(x: (ball ? 55 : -55) * scale, y: 48 * scale).animation(.easeInOut(duration: 0.65).repeatCount(4, autoreverses: true), value: ball) }
            }
            .frame(width: model.settings.petSize, height: model.settings.petSize)
            .contentShape(Rectangle())
            .onTapGesture { model.play("摸摸") }
            .contextMenu { controls }
        }
        .padding(12)
        .onChange(of: model.playCount) {
            bounce = false; ball = false
            withAnimation(.easeInOut(duration: 0.35).repeatCount(6, autoreverses: true)) { bounce = true }
            let round = model.playCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { if model.playCount == round { ball = true } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { if model.playCount == round { bounce = false; ball = false } }
        }
        .help(model.hasError ? model.message : "\(model.settings.paused ? "记录已暂停" : model.desktopStatus) · 点击摸摸，拖动移动，右键打开菜单")
    }
    @ViewBuilder private var controls: some View {
        Button("打开记录") { model.page = .timeline; model.showHistory?() }
        Button(model.settings.paused ? "恢复记录" : "暂停记录") { model.togglePause() }
        Button("记住这一刻") { model.bookmark?() }
        Divider()
        Button("桌宠与换装…") { model.page = .pet; model.showHistory?() }
        Button("摸摸") { model.play("摸摸") }
        Button("喂食 🍪") { model.play("喂食") }
        Button("追球 🧶") { model.play("追球") }
        Divider()
        Button("隐藏桌宠") { model.settings.petVisible = false; model.saveSettings() }
    }
}

private final class PetHostingView: NSHostingView<PetView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor public final class PetController {
    private let panel: NSPanel
    private let model: RecordModel
    public init(model: RecordModel) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 250), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "LinkRecord 桌宠"; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false
        panel.contentView = PetHostingView(rootView: PetView(model: model))
        panel.setFrameAutosaveName("LinkInputPet")
        if !panel.setFrameUsingName("LinkInputPet"), let screen = NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 230, y: screen.visibleFrame.minY + 35)) }
        apply()
    }
    public func apply() {
        let size = PetSizing.clamped(model.settings.petSize)
        let previous = panel.frame
        let content = NSSize(width: max(160, size + 24), height: size + 50)
        var frame = NSRect(x: previous.midX - content.width / 2, y: previous.minY, width: content.width, height: content.height)
        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
            frame.origin.y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        }
        panel.setFrame(frame, display: true)
        if model.settings.petVisible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }
    public func hideForLock() { panel.orderOut(nil) }
}
