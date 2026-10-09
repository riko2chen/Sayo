[English](README.md) · [简体中文](README.zh-CN.md)

<p align="center">
  <img src="Sources/SayoUI/Resources/SayoLogo.png" alt="Sayo" width="96">
</p>

# Sayo

An open-source, native macOS writing assistant for translating, polishing, and adjusting the tone of text right where you type. Works with Terminal and the Codex TUI, as well as third-party apps such as Codex desktop and Chrome.

## Installation

Requires **macOS 14 or later**. Supports Apple Silicon and Intel Macs.

### Homebrew

With [Homebrew](https://brew.sh/) installed, run:

```sh
brew install --cask riko2chen/sayo/sayo
```

This installs Sayo in Applications and adds the `sayo` command.

To update through Homebrew:

```sh
brew update
brew upgrade --cask --greedy riko2chen/sayo/sayo
```

You can also check for updates inside Sayo. To uninstall, run `brew uninstall --cask riko2chen/sayo/sayo`.

### Download the DMG

**[Get Sayo on GitHub Releases](https://github.com/riko2chen/Sayo/releases)** · [Website](https://sayo.rikolab.com/)

Move `Sayo.app` to Applications.

### First launch

Open Sayo and follow the setup instructions to grant Accessibility permission and configure your model service.

Press `Option+E` in another app's input field to get started.

## Features

- **In-place translation and polishing**: Handle mixed Chinese and English text, translation, and tone adjustments. Process selected text, or the entire input field by default when nothing is selected.
- **Preview or replace directly**: Use Click to rewrite to preview results, or Replace directly to rewrite and replace text with a keyboard shortcut.
- **Two target languages**: Assign two shortcuts to rewrite text in two different languages.
- **Terminal and CLI**: Supports zsh, bash 4+, fish, and external editor integrations for Codex CLI, Claude Code, and more.

## Highlights

- **Choose your model**: Use your own API key to connect to cloud services such as OpenAI and DeepSeek, or use local models. Sayo stays lightweight even on less powerful machines.
- **A little more convenient**: Translate with a keyboard shortcut without selecting text first.
- **Broad compatibility**: Dedicated integrations for zsh, fish, and agents such as Codex and Claude.
- **Privacy protection**: Licensed under [GPL-3.0-only](LICENSE), with API keys stored in macOS Keychain.

## Choosing a Model

For **automatic switching between available models**, consider installing [magpie](https://usemagpie.ai/).

For local models, consider [Hy-MT2](https://github.com/Tencent-Hunyuan/Hy-MT2), which runs smoothly even on an M1 MacBook Pro. You can also use Gemini Nano, Chrome's built-in local model, by enabling it in Sayo's settings.

## Feedback

Report issues or suggest improvements through [GitHub Issues](https://github.com/riko2chen/Sayo/issues).

Contribute through a pull request to `dev`. See [CONTRIBUTING.md](CONTRIBUTING.md) for building, testing, and update notes.

Read the [version history](UPDATE_NOTES.md) for release changes.
