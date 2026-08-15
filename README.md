# Claude Usage Tracker

A macOS menu bar app that shows your Claude Code usage at a glance — the same
information as the CLI's `/usage` screen, always one click away in the top menu
bar.

```
✳ Claude Code
  PRO

LIMITS
Session  ▓░░░░░░░░░░░░░░░  8%
Resets in 21m
Weekly   ▓░░░░░░░░░░░░░░░  3%
Resets in 6d 4h

TOKENS BY DAY
Sun   ░░░░░░░░░░░░░░░░░░       0
Mon   ░░░░░░░░░░░░░░░░░░       0
...
Today ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  184.8K

TOKENS BY MODEL
Sonnet 5  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓  184.8K
```

## How it works

The app doesn't need its own login — it piggybacks on the Claude CLI:

- **Authentication**: reads the OAuth token that `claude` stores after login
  (macOS Keychain item `Claude Code-credentials`, with a fallback to
  `~/.claude/.credentials.json`). Expired tokens are refreshed automatically
  using the CLI's refresh token; nothing is written back, the CLI stays the
  owner of the credential.
- **Limits** (Session / Weekly percentages and reset countdowns): fetched from
  the same OAuth usage endpoint the CLI's `/usage` screen uses.
- **Tokens by day / by model**: computed locally by scanning the CLI's session
  logs in `~/.claude/projects/**/*.jsonl` for the last 7 days. Log content
  never leaves your machine.

Data refreshes automatically every 60 seconds, or on demand via the refresh
button in the panel.

## Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools (`xcode-select --install`)
- The Claude CLI, logged in at least once (`claude` → `/login`)

## Build & install

```bash
git clone https://github.com/rylgyl/claude-tracker.git
cd claude-tracker
./scripts/make-app.sh --install
open "/Applications/Claude Usage Tracker.app"
```

Or run it straight from source during development:

```bash
swift run
```

On first launch, macOS will ask for permission to read the
`Claude Code-credentials` Keychain item — click **Always Allow** so the prompt
doesn't reappear on every refresh.

### Launch at login

System Settings → General → Login Items → add **Claude Usage Tracker**.

## Troubleshooting

- **"No Claude CLI credentials found"** — run `claude` in a terminal and log
  in, then hit refresh in the panel.
- **"Not authorized"** — your token was revoked or the refresh failed; run
  `claude` again to re-authenticate.
- **Token charts are empty** — token history comes from local CLI logs, so it
  only covers usage from `claude` on this machine (not claude.ai or other
  devices).

## Project layout

```
Package.swift                 Swift Package (no Xcode project needed)
Sources/ClaudeUsageTracker/
  App.swift                   MenuBarExtra entry point
  MenuView.swift              The panel UI
  UsageStore.swift            State + 60s refresh loop
  Credentials.swift           Keychain/file credential loading + OAuth refresh
  UsageAPI.swift              Limits from the OAuth usage endpoint
  LocalUsage.swift            JSONL log scanner (tokens by day/model)
  Formatters.swift            "184.8K", "Resets in 6d 4h", etc.
scripts/make-app.sh           Builds and installs the .app bundle
```
