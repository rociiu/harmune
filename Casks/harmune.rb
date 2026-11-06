# Template for a Homebrew tap. Scripts and CI don't publish this: before using
# it, set `version`, `sha256` (from SHA256SUMS) and the GitHub repository in
# `url` and `homepage`.
cask "harmune" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_OF_THE_ZIP"

  url "https://github.com/OWNER/harmune/releases/download/v#{version}/Harmune-#{version}-arm64.zip"
  name "Harmune"
  desc "Keyboard-first Apple Music player for the terminal"
  homepage "https://github.com/OWNER/harmune"

  depends_on macos: ">= :sequoia"
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
