# LinkAll

macOS 14+、Apple Silicon 的个人工作工具。LinkInput 负责输入、语音与就地 AI 整理；LinkRecord 负责本地记录、可见屏幕采集及桌宠；LinkAgent 提供当前场景的三候选回复，任务执行与长期记忆尚未启用。LinkAll 主应用统一菜单和模块导航，输入法进程独立。架构以 `docs/LinkAll架构.md` 为准；产品需求、开发状态与验收记录是本地内部文档（已 gitignore，不入库）。

## 重要约束
- 基础输入不依赖 AI；不下载或部署 AI 模型。桌面截图文字识别使用系统 Vision OCR，历史不自动上传；仅用户主动 V → 左 Command 触发回复建议时，可上传筛选后的当前场景文字，边界见 `docs/Agent回复建议.md`。
- 写入不等于发送，禁止合成 Return、自动提交消息或 shell 命令；唯一允许的合成按键是听写的 ⌘V（临时剪贴板，随后恢复），用于未连上输入法的兜底和多行整理结果。逐字输入的文字不含换行；多行只走粘贴，终端和单行输入框压成一行。未知目标只提供复制。
- 就地 AI 整理仅处理显式选区，或无选区时当前聚焦的小输入框（≤2000 字）全文；不读会话历史与文档全文。用户于 2026-10-04 授权新增本地输入/语音历史、应用/窗口与有限屏幕抽样、可自定义桌宠和简单玩法，现役范围见 `docs/PRD2.0.md`。默认关闭云端处理，不自动上传历史。
- 密钥只存 Keychain；诊断/系统日志无正文、音频、密钥。临时草稿只在内存，锁屏清除。本地 History 数据库按用户授权保存输入、语音原始转写和整理结果，可暂停、排除、搜索与删除；原始音频不落盘。锁屏停止采集，既有历史保留。
- 目标和草稿版本共同校验，迟到结果丢弃；未知写入结果不重试。
- 终端 Agent 建议可在确认同一编辑区域后，通过 IMK 插入单行文字，保留已有输入；只用鼠标采用，不把数字/Enter 当候选快捷键。终端滚屏不作为当前草稿读取，未读取不等于空输入框。
- 总产品名称 LinkAll，三个部分为 LinkInput / LinkRecord / LinkAgent。历史 bundle、输入源、钥匙串、可执行文件与用户数据路径保持兼容；身份映射见 `src/Shared/Product.swift` 与架构文档，不做机械全局替换。
- 不覆盖用户已有输入法和词库。临时文件在 `scratch/`，不提交。
- 仓库按公开发布考虑：入库文档只放对外说明（架构、隐私、依赖、回复建议）；需求、进度、验收证据和设计素材放 `.gitignore` 列出的本地文档，公开文档不链接它们。
- 开发构建用 Apple Development 证书签名（钥匙串按 Team ID 分区）；不要改回 ad-hoc，否则每次重建都要输密码才能读凭据。

## 验证
- `scripts/bootstrap.py` 获取锁定依赖，`swift test` 验证草稿事务、隐私和输入引擎；`python3 scripts/check-docs.py` 检查文档链接与现役路径。
- `scripts/build.sh` 构建 LinkAll 主应用与 LinkInput 输入法；`scripts/install.sh` 一次安装整套，`scripts/rollback.sh` 恢复上一版应用组合。
- 按 `docs/验收.md`（仅本地）记录真实实机证据，不能将单元测试当作主应用验收。输入测试须绑定宿主 PID/编辑框，优先使用 `scripts/HIDDriver` 的焦点校验，不用无目标按键或 AX 直接赋值冒充 IME 上屏。

## 任务路由
- 需求/范围：`docs/PRD2.0.md`；实现与下一步：`docs/开发状态.md`（均仅本地）；分层、依赖与升级：`docs/LinkAll架构.md`。
- 桌面测试使用 Peekaboo skill；已登录网页使用 OpenCLI skill；cmux 控制使用 cmux skill。
- 主应用与控制协议：`src/LinkAll/App/`、`src/Shared/`；回复建议：`src/LinkAgent/README.md`、`docs/Agent回复建议.md`。任务执行与长期记忆仍是规划，不得描述为已实现。
- 记录与桌宠：`src/LinkRecord/Core/` 为共享数据层，`src/LinkRecord/UI/` 为 LinkRecord 的 UI 与采集实现，`src/LinkInput/App/HistoryBridge.swift` 为异步记录桥接；截图与 OCR 不得放入 IMK 按键回调。
- API 接入参考 use-llm、media-generation skills。不要把技能凭据复制进代码或文档。
- 代码与公开文档不写死任何 API 地址：默认地址只放在 gitignore 的 `scripts/api-defaults.local.json`（模板 `scripts/api-defaults.example.json`），由 `build.sh` 打包为 `api-defaults.json`，`APIDefaults` 读取；公开构建默认留空。
- 语音整理默认 system prompt：`src/LinkInput/Core/Prompts/dictation-system.txt`；设置「语音输入 → 输出模式」支持按模式完整覆盖，模板占位符由 `ExpressionGuard.dictationSystem` 展开。
- 场景/换行默认提示词：`src/LinkInput/Core/Prompts/scenes.json`；分类与覆盖逻辑在 `src/LinkInput/Core/ScenePrompts.swift`，设置「语音输入 → 输出模式 → 高级设置 · 场景与排版」可编辑，实际写入限制仍由 `InputTarget`/`Coordinator` 决定。
- AI 整理默认 system prompt：`src/LinkInput/Core/Prompts/manual-system.txt`；设置「AI 整理」页按模式完整覆盖，支持新建/切换；temperature 固定为 1。模式独立存于 `manualOptions`，不影响语音模式；沿用现有文本 API 与 Keychain 凭据。
