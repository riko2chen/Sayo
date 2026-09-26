# Run with: HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 brew ruby scripts/verify_cask.rb <release-directory>
# Read-only: loads the Cask DSL but never taps, downloads or installs anything.
require "cask/cask_loader"
require "json"

directory = Pathname(ARGV.fetch(0)).expand_path
release = JSON.parse((directory/"release.json").read)
cask = Cask::CaskLoader.load(directory/"homebrew-tap/Casks/sayo.rb")
raise "Cask version mismatch" unless cask.version.to_s == "#{release.fetch('version')},#{release.fetch('build')}"
raise "Cask URL mismatch" unless cask.url.to_s == release.fetch("downloadURL")
raise "Cask checksum mismatch" unless cask.sha256.to_s == release.fetch("sha256")
raise "Cask livecheck feed mismatch" unless cask.livecheck.url == release.fetch("feedURL")
raise "Cask must use Sparkle livecheck" unless cask.livecheck.strategy == :sparkle
raise "Cask must declare self updates" unless cask.auto_updates
raise "Cask minimum OS mismatch" unless cask.depends_on.macos.version == Version.new(release.fetch("minimumSystemVersion"))
raise "Cask must install app and CLI" unless cask.artifacts.map(&:to_s) == ["Sayo.app (App)", "#{cask.config.appdir}/Sayo.app/Contents/MacOS/sayo (Binary)"]
puts "Verified Homebrew Cask without installing: #{cask.version}"
