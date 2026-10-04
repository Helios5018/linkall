# LinkAgent

第一版已接入 LinkInput 的 **V → 轻点左 Command** 回复建议。`ReplyAgent.swift` 负责本地上下文筛选、来源区分、提示词和三候选输出校验；网络调用由输入法注入，凭据继续只在 Keychain。

LinkAgent Swift target 仅依赖 LinkRecordCore；不读取图片、不执行工具、不自动发送，不创建长期记忆或任务执行数据库。检索与网络异步运行，不在 IMK 按键回调里等待。

当前 App 内只读建议可以在输入法进程中运行。未来具有工具权限的任务执行器仍须独立进程、身份校验 IPC、动作授权、重复执行保护和审计；记录内容或模型输出不构成执行授权。

方案、资料筛选与局限见 [回复建议](../../docs/Agent回复建议.md)，分层见 [架构](../../docs/LinkAll架构.md)。
