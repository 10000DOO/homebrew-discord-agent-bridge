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
