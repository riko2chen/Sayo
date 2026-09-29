# Homebrew tap for Sayo

Install [Homebrew](https://brew.sh/) first, then run:

```sh
brew install --cask riko2chen/sayo/sayo
```

This installs Sayo in Applications and adds the `sayo` command to your Homebrew bin directory. Open Sayo, grant Accessibility permission, and configure a model service.

To update:

```sh
brew update
brew upgrade --cask --greedy riko2chen/sayo/sayo
```

You can also check for updates inside Sayo. To uninstall the app and command:

```sh
brew uninstall --cask riko2chen/sayo/sayo
```

## 中文

先安装 [Homebrew](https://brew.sh/)，再运行上面的安装命令。安装完成后，打开「应用程序」中的 Sayo，按引导授予辅助功能权限并配置模型服务。安装时也会添加 `sayo` 命令。

更新可使用上面的 `brew update` 和 `brew upgrade` 命令，或在 Sayo 内检查更新。卸载命令会移除应用和命令行入口，保留用户配置。

## Maintenance

The `Sync latest Sayo release` workflow checks the latest published stable release of [riko2chen/Sayo](https://github.com/riko2chen/Sayo) hourly and can also be run manually. GitHub may delay scheduled runs or disable schedules in inactive public repositories; use the workflow's **Run workflow** button to sync immediately.

The updater checks versioned asset URLs, the checksum manifest, GitHub's asset digest when present, and the appcast metadata. Before changing the Cask, it downloads the DMG and verifies its size and SHA-256. It rejects downgrades and checksum changes to an existing version. Unchanged releases do not cause a download or commit.

The workflow uses this tap's `GITHUB_TOKEN` to commit only `Casks/sayo.rb`. It needs no signing credentials or access to the Sayo source repository. Source templates and tests are maintained under `Distribution/homebrew` in the Sayo repository.
