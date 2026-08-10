class Dab < Formula
  desc "Self-hosted Discord bot running Claude Code / Codex / Grok per channel (discord-agent-bridge)"
  homepage "https://github.com/10000DOO/discord-agent-bridge"
  url "https://github.com/10000DOO/discord-agent-bridge/archive/refs/tags/v3.7.1.tar.gz"
  sha256 "8bce36852c800cebc4c3defc00888544d280f1ed23634d47a48c427e3c13f142"
  license "MIT"

  # Node.js and Swift are checked (not installed) in #install below — see the
  # odie messages there for why `depends_on` is deliberately not used for either.

  def install
    # Node.js: check only. `depends_on "node"` would let Homebrew silently install/upgrade
    # Node, which this project's release process explicitly does not want — the user manages
    # their own Node.js.
    #
    # `which("node")` alone checks superenv's sanitized build PATH, which excludes
    # user toolchain managers (nvm, volta, fnm, ...) — a Node installed that way would be
    # reported as "missing" even though it exists. ORIGINAL_PATHS is the user's real PATH
    # captured before Homebrew sanitizes it; this is the same idiom Homebrew itself uses to
    # detect user-installed npm/cargo/etc. (bundle/extensions/npm.rb, cargo.rb).
    # scripts/find-node.sh (shipped in the tarball) is the single rule set for locating Node
    # across every install method — nvm/volta/fnm/asdf/mise/n put it under a per-version
    # directory in $HOME that `which("node", ORIGINAL_PATHS)` cannot see whenever brew is
    # invoked with anything other than a full login PATH (launchd, a sanitized shell, the
    # self-update script). ORIGINAL_PATHS is still tried first *inside* that script, so a
    # user's own choice on PATH still wins.
    finder = buildpath/"scripts/find-node.sh"
    node = nil
    if finder.exist?
      found = Utils.popen_read("/bin/bash", finder.to_s, err: :close).strip
      node = Pathname(found) if !found.empty? && File.executable?(found)
    end
    node ||= which("node", ORIGINAL_PATHS)
    odie <<~EOS if node.nil?
      Node.js가 필요합니다 (버전 20 이상). discord-agent-bridge의 클로드 백엔드는
      Node.js 기반 사이드카 프로세스로 동작합니다.

      아래 중 하나로 직접 설치한 뒤 다시 시도해주세요:
        brew install node
        또는 https://nodejs.org 에서 20 이상 버전 설치

      (이 Formula는 Node.js를 자동으로 설치하거나 업그레이드하지 않습니다.)
    EOS

    node_version_raw = Utils.safe_popen_read(node, "--version").strip
    node_major = node_version_raw[/v?(\d+)/, 1].to_i
    odie <<~EOS if node_major < 20
      감지된 Node.js 버전(#{node_version_raw})이 너무 낮습니다 — 20 이상이 필요합니다.

      아래 중 하나로 직접 업그레이드한 뒤 다시 시도해주세요:
        brew upgrade node
        또는 https://nodejs.org 에서 20 이상 버전 설치

      (이 Formula는 Node.js를 자동으로 업그레이드하지 않습니다.)
    EOS

    # Swift: check only. Homebrew has no way to auto-install Xcode anyway, but the error
    # message below is our own — do not rely on the generic `depends_on :xcode` message.
    # Same ORIGINAL_PATHS reasoning as node above (Xcode CLT's swift isn't in superenv's PATH).
    swift = which("swift", ORIGINAL_PATHS)
    odie <<~EOS if swift.nil?
      Swift 툴체인이 필요합니다 (6.1 이상). Xcode 또는 Command Line Tools를 설치해주세요:

        xcode-select --install

      또는 App Store에서 Xcode를 설치/업데이트한 뒤 다시 시도해주세요.
      (이 Formula는 Xcode/Swift를 자동으로 설치하지 않습니다.)
    EOS

    swift_version_output = Utils.safe_popen_read(swift, "--version")
    match = swift_version_output.match(/Swift version (\d+)\.(\d+)/)
    odie "swift --version 출력을 해석하지 못했습니다:\n#{swift_version_output}" if match.nil?
    swift_major = match[1].to_i
    swift_minor = match[2].to_i
    if swift_major < 6 || (swift_major == 6 && swift_minor < 1)
      odie <<~EOS
        감지된 Swift 버전(#{swift_major}.#{swift_minor})이 너무 낮습니다 — 6.1 이상이 필요합니다.

        Xcode 또는 Command Line Tools를 업데이트해주세요:
          xcode-select --install
        또는 App Store에서 Xcode를 최신 버전으로 업데이트한 뒤 다시 시도해주세요.

        (이 Formula는 Xcode/Swift를 자동으로 업데이트하지 않습니다.)
      EOS
    end

    # Swift 실행 파일 빌드 (executable product "dab" -> swift/.build/release/dab)
    # --disable-sandbox: Homebrew의 install 단계는 이미 자체 sandbox-exec 안에서 돈다.
    # SwiftPM이 Package.swift 매니페스트 컴파일에 자기 sandbox까지 추가로 걸려고 하면
    # 중첩 sandbox_apply가 거부돼("Operation not permitted") 빌드 자체가 실패한다.
    system swift, "build", "--package-path", "swift", "-c", "release", "--disable-sandbox"
    libexec.install "swift/.build/release/dab" => "dab-bin"

    # 클로드 사이드카(Node/TS)는 cli.ts 하나만으로 뜨지 않는다 — core/, modes/claude/,
    # discord/documentShare.js 까지 상대 경로로 임포트하므로 src 전체를 같이 설치해야 한다.
    libexec.install "package.json", "package-lock.json", "src"
    # The wrapper and homebrew-self-update.sh both re-resolve Node at run time, so the finder
    # has to live in the keg, not just in the build directory.
    #
    # Guarded on existence so this formula still installs a release tarball from before the
    # finder existed: both consumers already fall back to the install-time path when it is
    # missing, so an older tarball simply keeps the old behaviour instead of failing to build.
    if finder.exist?
      libexec.install "scripts/find-node.sh"
      chmod 0755, libexec/"find-node.sh"
    end
    # tsx는 devDependencies에 있지만 사이드카를 tsx로 실행하는 한 런타임에 필요하다.
    # `--omit=dev`를 쓰면 안 된다.
    # npm은 PATH가 아니라 위에서 확인한 node와 같은 디렉터리에서 직접 찾는다 — "npm"을
    # 그대로 시스템 호출하면 superenv가 좁혀놓은 빌드용 PATH에는 nvm 등으로 설치된
    # npm이 없어서 실패한다(node를 ORIGINAL_PATHS로 찾아야 했던 것과 같은 이유).
    npm = node.dirname/"npm"
    odie "node는 있지만 그 옆에 npm이 없습니다: #{npm}" unless npm.executable?
    # npm 자체가 `#!/usr/bin/env node` 셔뱅 스크립트라, 절대 경로로 실행해도 실행 시점
    # PATH에 node가 없으면 "env: node: No such file or directory"로 죽는다.
    # ORIGINAL_PATHS로 찾은 node의 디렉터리를 이 설치 단계 PATH에만 추가해준다.
    ENV.prepend_path "PATH", node.dirname
    system npm, "install", "--prefix", libexec

    # findRepoRoot()가 cwd 기준으로 package.json + src/sidecar/claude/cli.ts를 찾는데,
    # brew로 설치하면 사용자는 임의의 디렉터리에서 dab을 실행하므로 이 탐색은 항상 실패한다.
    # DAB_CLAUDE_SIDECAR_CMD로 사이드카 경로를 고정 지정해 cwd와 무관하게 만든다
    # (swift/scripts/install.sh의 run.sh 생성부와 같은 "얇은 래퍼" 방식). node도 설치 시점에
    # 확인한 절대 경로를 그대로 박아서, dab을 나중에 launchd 등 PATH가 없는 곳에서
    # 실행해도 사이드카를 못 찾는 일이 없게 한다.
    # 시크릿(DISCORD_BOT_TOKEN 등)은 install.sh 방식과 동일하게 ~/.dab/env(0600) 하나로만
    # 관리한다 — Formula가 그 파일을 만들지는 않고, 있으면 읽어들이기만 한다.
    # Node is resolved at EVERY launch, not baked in. A version manager installs into a
    # per-version directory (~/.nvm/versions/node/v24.12.0/bin/node); baking that string means
    # the next `nvm install` silently breaks the Claude sidecar AND the updater's own Node
    # lookup at the same time. The install-time path is kept as the last-resort fallback for
    # machines with no version manager, which is what find-node.sh consults last.
    (bin/"dab").write <<~EOS
      #!/bin/bash
      [ -f "$HOME/.dab/env" ] && source "$HOME/.dab/env"
      export DAB_NODE_FALLBACK_DIR="#{node.dirname}"
      dab_node="$(/bin/bash "#{libexec}/find-node.sh" 2>/dev/null || true)"
      [ -x "$dab_node" ] || dab_node="#{node}"
      export DAB_CLAUDE_SIDECAR_CMD="$dab_node #{libexec}/node_modules/tsx/dist/cli.mjs #{libexec}/src/sidecar/claude/cli.ts"
      export DAB_INSTALL_METHOD="homebrew"
      export DAB_HOMEBREW_UPDATE_SCRIPT="#{libexec}/homebrew-self-update.sh"
      exec "#{libexec}/dab-bin" "$@"
    EOS
    chmod 0755, bin/"dab"

    # Discord's `/update` spawns this detached (see DAB_HOMEBREW_UPDATE_SCRIPT above) to own
    # upgrade -> restart -> verify -> rollback, since the process it replaces can't do that to
    # itself. It must be executable directly (spawned by absolute path, not via a shell).
    # buildpath (cwd here) is the extracted release tarball, which doesn't contain this
    # tap-only script — read it from the tap via __dir__ instead (verified to resolve to this
    # Formula's own directory under Homebrew's module_eval-based formula loading).
    (libexec/"homebrew-self-update.sh").write (Pathname(__dir__)/"../scripts/homebrew-self-update.sh").read
    chmod 0755, libexec/"homebrew-self-update.sh"
  end

  service do
    run [opt_bin/"dab"]
    keep_alive true
    log_path var/"log/dab.log"
    error_log_path var/"log/dab.error.log"
    # Path the running dab writes to once Discord's gateway READY fires (any normal boot, not
    # just updates) — homebrew-self-update.sh polls this exact path after a restart it triggers.
    environment_variables DAB_SUCCESSOR_READY_FILE: "#{Dir.home}/.dab/homebrew-ready-marker"
  end

  test do
    system "#{bin}/dab", "sidecar-smoke"
  end
end
