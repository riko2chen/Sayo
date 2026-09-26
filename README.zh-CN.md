[English](README.md) · [简体中文](README.zh-CN.md)

<p align="center">
  <img src="Sources/SayoUI/Resources/SayoLogo.png" alt="Sayo" width="96">
</p>

# Sayo

开源的原生 macOS 写作助手，在当前输入框里完成翻译、润色与语气调整。支持 Terminal 与 codex TUI，支持 codex desktop、Chrome 等第三方软件。

## 下载

**[前往 GitHub Releases](https://github.com/riko2chen/Sayo/releases)** · [项目主页](https://sayo.rikolab.com/)

支持 **macOS 14 及以上版本**，适用于 Apple Silicon 和 Intel Mac。

获得 `Sayo.app` 后，将其放入「应用程序」并打开，按引导授予辅助功能权限、配置模型服务。

在其他应用的输入框中按 `option+E` 即可开始使用。

## 功能

- **原地翻译与润色**：处理中英混输、翻译和语气调整；有选区时处理选中文字，无选区时默认处理整个输入框。
- **预览或直接替换**：手动模式先查看结果，静默模式通过快捷键直接改写。
- **双目标语言**：支持绑定两个快捷键，分别转写成两种不同语言。
- **终端与 CLI**：支持 zsh、bash 4+、fish，以及 Codex CLI、Claude Code 等外部编辑器接入。

## 特色

- **模型自由选择**：使用自己的 API Key，连接 OpenAI、Deepseek等云端服务，也支持本地模型，在低配置机器也能轻巧运行。
- **更方便一点点**：无需选中，可以直接通过快捷键进行翻译。
- **支持范围广**：为 zsh、fish 以及 codex、claude 等 agent 单独做了适配
- **隐私保护** ：采用 [GPL-3.0-only](LICENSE) 许可证，API Key保存在钥匙串内。

## 模型选择

如果需要**自动切换可用模型**，可以考虑安装 [magpie](https://usemagpie.ai/)。
如果希望用本地模型，可以考虑 [Hy-MT2](https://github.com/Tencent-Hunyuan/Hy-MT2) ，在 MacBook Pro M1 都可以流畅运行。或者可以用 Chrome 自带的本地模型 Gemini Nano(可以通过 Sayo 的设置启用)。

## 问题反馈

可以通过 [GitHub Issues](https://github.com/riko2chen/Sayo/issues) 反馈问题或提出建议。

欢迎向 `dev` 分支提交 PR。构建、测试和更新说明规则见 [CONTRIBUTING.md](CONTRIBUTING.md)。

版本变化见 [更新记录](UPDATE_NOTES.md)。
