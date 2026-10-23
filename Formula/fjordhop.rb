# Homebrew formula. This repo doubles as its own tap:
#   brew tap leffen-fjordline/fjordhop https://github.com/leffen-fjordline/fjordhop
#   brew install fjordhop            (--HEAD for the latest main)
# Builds from source, like install.sh, so the app is never quarantined.
class Fjordhop < Formula
  desc "Hop between Claude Code sessions in Ghostty"
  homepage "https://github.com/leffen-fjordline/fjordhop"
  url "https://github.com/leffen-fjordline/fjordhop/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "85defe8702833606ff593f494449182d395badc214bc449b9ad6df3bf230a243"
  license "MIT"
  head "https://github.com/leffen-fjordline/fjordhop.git", branch: "main"

  depends_on "fzf"
  depends_on macos: :sonoma

  def install
    system "app/build.sh", "--build-only"
    prefix.install "app/build/Fjordhop.app"
    bin.install "bin/cs"
  end

  # Open at Login (SMAppService) remembers the app's path, and the Cellar path
  # changes with every upgrade, so the app runs from a copy in ~/Applications.
  def caveats
    <<~EOS
      Copy the app to ~/Applications and start it (again after each upgrade):
        pkill -x Fjordhop; rm -rf ~/Applications/Fjordhop.app
        cp -R #{opt_prefix}/Fjordhop.app ~/Applications/ && open ~/Applications/Fjordhop.app

      Requires Ghostty 1.3 or later in /Applications.
    EOS
  end

  test do
    assert_predicate prefix/"Fjordhop.app/Contents/MacOS/Fjordhop", :executable?
    assert_match "cs", shell_output("head -3 #{bin}/cs")
  end
end
