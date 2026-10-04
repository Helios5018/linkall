import SwiftUI
import LinkAllShared
import LinkAllUI
import LinkRecordUI

@MainActor final class WorkspaceSelection: ObservableObject { @Published var module: LinkModule = .record }

struct WorkspaceView: View {
    @ObservedObject var selection: WorkspaceSelection
    @ObservedObject var input: InputService
    @ObservedObject var record: RecordModel
    var body: some View {
        HStack(spacing: 0) {
            LinkSidebar(title: "LinkAll", subtitle: "表达、记忆与行动", footer: "一个入口，三个部分",
                        items: LinkModule.allCases.map { LinkSidebarItem(id: $0.id, title: $0.title, subtitle: $0.summary, symbol: $0.symbol, brand: LinkBrand(rawValue: $0.title)) },
                        selected: selection.module.id) { id in
                if let module = LinkModule(rawValue: id) { selection.module = module }
            }
            Divider()
            Group {
                switch selection.module {
                case .record: RecordWorkspaceView(model: record)
                case .input: inputOverview
                case .agent: agentOverview
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 1120, minHeight: 660).background(LinkAppearance.background)
    }
    private var inputOverview: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label { Text("LinkInput") } icon: { Image(nsImage: LinkBrand.input.image(size: 28, tile: true)) }.font(LinkAppearance.titleFont)
            Text("把想法写出来").font(.title2).foregroundStyle(.secondary)
            Text("打字、语音输入和就地 AI 整理，沿用你已经配置的输入方案、模式与快捷键。")
            if let state = input.snapshot {
                GroupBox("当前输入配置") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("输入方案：" + (state.schemes.first { $0.id == state.scheme }?.title ?? ""))
                        Text("语音模式：" + (state.voiceModes.first { $0.id == state.voiceMode }?.title ?? ""))
                        Text("AI 整理：" + (state.manualModes.first { $0.id == state.manualMode }?.title ?? ""))
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
            } else { Text("LinkInput 正在连接；启动后可查看当前方案。").foregroundStyle(.secondary) }
            if !input.issue.isEmpty { Text(input.issue).foregroundStyle(.orange) }
            HStack { Button("打开 LinkInput 设置") { input.send(InputCommand(.settings)) }.buttonStyle(.borderedProminent); Button("重新连接") { input.start() } }
            Text("经过 LinkInput 的输入会按记录设置保存到 LinkRecord，可随时回看。写入文字不等于发送消息。").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.padding(LinkAppearance.pageInset).frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var agentOverview: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label { Text("LinkAgent") } icon: { Image(nsImage: LinkBrand.agent.image(size: 28, tile: true)) }.font(LinkAppearance.titleFont)
            Text("回复建议 · 第一版").font(.callout.bold()).padding(8).background(LinkAppearance.accent.opacity(0.12), in: Capsule())
            Text("根据当前场景，给你三个回复选择。").font(.title2)
            Text("使用 LinkInput 时，先按 V，再轻点左 Command。LinkAgent 会结合当前输入框与本应用近期记录，给出 3 条不同意图的建议。按 1/2/3 或点击候选写入，Esc 取消。")
            Text("仅在你主动触发且开启文本云端处理时上传筛选后的文字。可查看参考依据；选择只写入，不发送。没有可靠输入目标时仅复制。任务执行与长期记忆尚未启用。").foregroundStyle(.secondary)
            Spacer()
        }.padding(LinkAppearance.pageInset).frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
