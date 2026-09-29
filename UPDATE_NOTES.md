# Sayo update notes

## 0.2.1

### English

- Update the author display name to @Riko in the About section.
- Refresh the About the Author section with consistent contact rows, clearer link details, and email copy feedback.
- Keep the verified editing target when autocomplete suggestions take accessibility focus, and replace text in one verified step to avoid interruptions from refreshing suggestions.
- Copy/paste compatibility now verifies the original editor before writing back and stops when the editor cannot be identified.

### 简体中文

- 将关于作者区域的显示名称更新为 @Riko。
- 重新设计关于作者区域，统一联系入口的样式与交互，清晰展示链接信息，并增加邮箱复制反馈。
- 候选建议接管无障碍焦点时仍保留经核验的输入目标，并一次性替换及回读确认，避免候选项刷新打断逐字写入。
- 复制/粘贴兼容模式现在会在写回前核验原输入框，无法确认输入框身份时停止操作。

## 0.2.0

### English

- AI diagnosis now scans the past 30 minutes, lets you select failed cases before authorizing analysis, and opens a GitHub issue draft with redacted results and evidence.
- Support Apple Account authentication for notarized GitHub release packages.
- Removed the Anthropic template from the new-model list while keeping existing saved profiles accessible.

### 简体中文

- AI 自诊断现可检测过去 30 分钟内的失败案例，勾选并授权后进行分析，支持查看结果和打开带脱敏信息的 GitHub issue 草稿。
- 支持使用 Apple 账户认证，为 GitHub 发布的安装包完成公证。
- 从新增模型列表中移除 Anthropic 预设，已保存的配置仍可访问。

## 0.1.0

### English

- Translate and polish text in place, with manual previews and direct replacement.
- Use separate shortcuts for two translation languages, with English and Simplified Chinese interfaces.
- Connect cloud or local models, including Chrome Gemini Nano, and test model connections.
- Integrate with zsh, bash, fish, and external editors for terminal workflows.
- Check for updates automatically with a one-hour cache, download in the background, and show green download progress before prompting to install.

### 简体中文

- 在当前输入位置翻译和润色文字，支持手动预览与直接替换。
- 支持两个翻译目标语言的独立快捷键，以及英文和简体中文界面。
- 连接云端或本地模型，包括 Chrome Gemini Nano，并测试模型连接。
- 集成 zsh、bash、fish 和外部编辑器，支持终端工作流。
- 自动检查更新并缓存一小时，在后台下载，以绿色进度显示下载状态，准备好后再提示安装。
