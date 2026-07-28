# homebrew-discord-agent-bridge

Homebrew tap for [`dab`](https://github.com/10000DOO/discord-agent-bridge) — a self-hosted Discord bot that runs Claude Code / Codex / Grok per channel.

## Install

```bash
brew tap 10000DOO/discord-agent-bridge
brew install 10000DOO/discord-agent-bridge/dab
```

## Requirements (checked, not auto-installed)

- Node.js 20+ — install/upgrade yourself via `brew install node` or https://nodejs.org
- Swift 6.1+ (Xcode / Command Line Tools) — install/upgrade yourself via `xcode-select --install`

The formula only checks for these; it will not install or upgrade them for you.

## Usage

```bash
dab --setup   # first-time configuration guidance
dab           # run the bot (reads DISCORD_BOT_TOKEN from env)
```

## Run as a background service (auto-restart)

Secrets (`DISCORD_BOT_TOKEN`, etc.) go in `~/.dab/env` — the formula never creates or manages
this file. Create it yourself (0600 permissions) with at least:

```bash
mkdir -p ~/.dab && chmod 700 ~/.dab
cat > ~/.dab/env <<'EOF'
DISCORD_BOT_TOKEN=your-token-here
EOF
chmod 600 ~/.dab/env
```

(see [`swift/deploy/env.example`](https://github.com/10000DOO/discord-agent-bridge/blob/main/swift/deploy/env.example) in the main repo for the full list of optional variables)

Then manage the service with `brew services`:

```bash
brew services start dab     # start now, and auto-start at login / auto-restart on crash
brew services stop dab      # stop and disable auto-start
brew services restart dab   # e.g. after editing ~/.dab/env
brew services list          # check status
```

Logs go to `$(brew --prefix)/var/log/dab.log` / `dab.error.log`.

## `/update` (Discord slash command)

When `dab` runs as a `brew services` background service (as set up above), approving `/update`
in Discord fully automates the upgrade — no manual `brew` commands needed:

1. `brew update` + `brew upgrade dab` to the latest release.
2. `brew services restart dab`.
3. Waits (up to ~90s) for the new process to actually reconnect to Discord's gateway.
4. If it reconnects in time: posts a success message back to the same Discord channel.
5. If it doesn't (crash, bad build, gateway auth failure, ...): automatically reverts to the
   previously installed version, restarts it, and posts a rollback notice to Discord instead.

This runs as a detached script (`homebrew-self-update.sh`, installed alongside `dab`) so it
survives the old `dab` process exiting mid-restart. Progress is also logged to
`~/.dab/logs/homebrew-update.log`. Nothing needs to be configured — the formula wires this up
automatically for `brew`-installed `dab`.
