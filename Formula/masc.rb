# Homebrew formula for masc.
#
# Two install paths both work:
#   brew tap jeong-sik/masc && brew install masc            # this repo as the tap
#   brew install jeong-sik/masc/masc                        # one-liner
#
# On each release, bump `version` and the per-arch url/sha256 below. masc does
# not publish a SHA256SUMS file, so compute each (download first, then hash):
#   curl -fsSL -o /tmp/masc-macos-arm64 <url> && shasum -a 256 /tmp/masc-macos-arm64
class Masc < Formula
  desc "MASC MCP Server: multi-agent streaming coordination"
  homepage "https://github.com/jeong-sik/masc"
  license "MIT"
  version "v0.19.51"

  on_macos do
    on_arm do
      url "https://github.com/jeong-sik/masc/releases/download/v0.19.51/masc-macos-arm64"
      sha256 "fb2e6cf37917b1fd3a54ff25b40c0801f4689e393a938d1a124dc61d8509c05b"
    end
    on_intel do
      odie "masc macOS x86_64 release asset is not built. Build from source per README."
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/jeong-sik/masc/releases/download/v0.19.51/masc-linux-x64"
      sha256 "731afe9657a11a8b500135bda2f6213499128b53751b8d2a0e435b3c182f57e8"
    end
    on_arm do
      odie "masc Linux arm64 release asset is not built yet."
    end
  end

  # The downloaded resource is the bare platform binary (no archive to uncompress).
  def install
    bin.install File.basename(stable.url) => "masc"
  end

  test do
    assert_match "MASC", shell_output("#{bin}/masc --version 2>&1", 1)
  end
end
