# Homebrew cask for thock. To publish:
#   1. Create a repository named "homebrew-thock" under your GitHub account.
#   2. Put this file at Casks/thock.rb, fill in version and sha256 from
#      Tools/release.sh output (dist/thock-<version>.dmg.sha256).
#   3. Users install with:
#        brew install --cask --no-quarantine obsiidi/thock/thock
#      --no-quarantine skips Gatekeeper for the unnotarized app.
cask "thock" do
  version "0.7.0"
  sha256 "a53d5afec2665f3b78998de0191b3959f8120875f8e5a7e700cc29374732b054"

  url "https://github.com/obsiidi/thock/releases/download/v#{version}/thock-#{version}.dmg"
  name "thock"
  desc "Mechanical keyboard sounds with key force, in the menu bar"
  homepage "https://github.com/obsiidi/thock"

  depends_on macos: ">= :ventura"

  app "thock.app"

  zap trash: [
    "~/Library/Application Support/thock",
    "~/Library/Preferences/com.obsidi.thock.plist",
  ]
end
