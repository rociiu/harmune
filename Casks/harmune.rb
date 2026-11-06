# Template rendered by Scripts/render-cask.sh.
cask "harmune" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/@REPOSITORY@/releases/download/v#{version}/Harmune-#{version}-arm64.zip"
  name "Harmune"
  desc "Keyboard-first Apple Music player for the terminal"
  homepage "https://github.com/@REPOSITORY@"

  depends_on macos: :sequoia
  depends_on arch: :arm64

  app "Harmune.app"
  binary "#{appdir}/Harmune.app/Contents/Resources/bin/harmune"

  uninstall quit: "com.orinbyte.harmune"

  zap trash: [
    "~/.config/harmune",
    "~/.local/state/harmune",
    "~/Library/Application Support/Harmune",
    "~/Library/Caches/Harmune",
    "~/Library/Logs/Harmune",
  ]
end
