# Agent Tracker

A macOS menu bar app that shows your Claude Code and Codex usage at a glance —
the same information as the CLI's `/usage` screen, always one click away in the
top menu bar.

```
✳ Claude Code
  PRO

[ Claude ] [ Codex ]

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

The panel has two tabs — **Claude** and **Codex** — and the menu bar icon
changes to match the selected one (✳ for Claude, `</>` for Codex), so you can
tell at a glance which tool you're tracking. The selection is remembered
across launches.

## How it works

Neither tab needs its own login — the app piggybacks on the CLIs.

### Claude tab

- **Authentication**: seeds from the OAuth token that `claude` stores after
  login (macOS Keychain item `Claude Code-credentials`, with a fallback to
  `~/.claude/.credentials.json`), then keeps its own copy in the Keychain item
  `com.agent-tracker.usage` and refreshes that in place. The CLI's item is
  read again only if the app's own refresh token stops working.

  The app keeps a copy because the CLI *rewrites* its Keychain item on every
  token refresh, which regenerates the item's ACL and silently revokes the
  "Always Allow" grant — that's what made the permission dialog reappear every
  few hours. An item only this app writes keeps its grant.
- **Limits** (Session / Weekly percentages and reset countdowns): fetched from
  the same OAuth usage endpoint the CLI's `/usage` screen uses.
- **Tokens by day / by model**: computed locally by scanning the CLI's session
  logs in `~/.claude/projects/**/*.jsonl` for the last 7 days. Log content
  never leaves your machine.

### Codex tab

Entirely local, no network call and no credentials: the Codex CLI writes both
its token counts and the server's rate-limit snapshot into its own session
logs under `~/.codex/sessions/**/*.jsonl`.

- **Limits**: the most recent rate-limit snapshot Codex recorded — one row per
  window it reports (e.g. `5h` and `Weekly`), with the plan type next to the
  title. Because Codex only records these while it's running, the panel shows
  the timestamp the snapshot was taken.
- **Tokens by day / by model**: the per-turn token counts from the same logs,
  for the last 7 days on this machine.

Data refreshes automatically every 60 seconds, or on demand via the refresh
button in the panel. If the usage API rate-limits a request, the app backs
off until the limit resets (the refresh button greys out and its tooltip
shows when it'll unlock) instead of retrying every 60 seconds regardless.

## Usage

1. Click the ✳ icon in the menu bar to open the panel.
2. Switch between the **Claude** and **Codex** tabs with the buttons under the
   title.
3. **LIMITS** shows how much of each usage window you've used, and when it
   resets.
4. **TOKENS BY DAY** / **TOKENS BY MODEL** show local usage for the last 7
   days, from this machine only.
5. Use the refresh (↻) button for an on-demand update, or the power button to
   quit.

The panel is a standard macOS menu bar popover — click anywhere outside it,
or the icon again, to dismiss it.

## Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools (`xcode-select --install`)
- The Claude CLI, logged in at least once (`claude` → `/login`)
- For the Codex tab: the Codex CLI, run at least once (it just reads
  `~/.codex/sessions`)

## Build & install

```bash
git clone https://github.com/rylgyl/agent-tracker.git
cd agent-tracker
./scripts/make-app.sh --install
open "/Applications/Agent Tracker.app"
```

Or run it straight from source during development:

```bash
swift run
```

On first launch, macOS will ask for permission to read the
`Claude Code-credentials` Keychain item — click **Always Allow**. The app then
maintains its own credential and won't need that item again.

Because the app is only ad-hoc signed, its code identity changes every time you
rebuild it, which invalidates the grant on its own Keychain item too. So expect
one prompt after each `./scripts/make-app.sh` — but not between rebuilds.

### Sharing with someone else

The app is only ad-hoc signed (no Apple Developer ID), so give people the
*source*, not a copy of the built `.app` — each person should clone and build
it themselves:

```bash
git clone https://github.com/rylgyl/agent-tracker.git
cd agent-tracker
./scripts/make-app.sh --install
open "/Applications/Agent Tracker.app"
```

Building locally avoids the macOS quarantine flag that gets attached to
files downloaded or AirDropped in, so Gatekeeper won't block it. They'll also
need the Claude CLI installed and logged in on their own machine (see
Requirements above) — the app reads *their* local credentials, not yours.

### Launch at login

System Settings → General → Login Items → add **Agent Tracker**.

## Troubleshooting

- **"No Claude CLI credentials found"** — run `claude` in a terminal and log
  in, then hit refresh in the panel.
- **"Not authorized"** — your token was revoked or the refresh failed; run
  `claude` again to re-authenticate.
- **Token charts are empty** — token history comes from local CLI logs, so it
  only covers usage from `claude` on this machine (not claude.ai or other
  devices).
- **"No Codex sessions found"** — Codex hasn't run on this machine, or its
  logs live somewhere other than `~/.codex/sessions`.
- **Codex limits look stale** — Codex only reports its limits while it's
  running, so the panel shows the newest snapshot from its logs along with
  when it was taken. Run Codex once to freshen it.
- **"Rate limited by the usage API"** — the OAuth usage endpoint is being hit
  too often (e.g. repeated manual refreshes). The app backs off automatically
  and the panel/tooltip shows when it'll retry; no action needed.

## Project layout

```
Package.swift                 Swift Package (no Xcode project needed)
Sources/AgentTracker/
  App.swift                   MenuBarExtra entry point
  MenuView.swift              The panel UI
  UsageStore.swift            State + 60s refresh loop
  Credentials.swift           Keychain/file credential loading + OAuth refresh
  UsageAPI.swift              Limits from the OAuth usage endpoint
  LocalUsage.swift            Claude JSONL log scanner (tokens by day/model)
  CodexUsage.swift            Codex rollout log scanner (limits + tokens)
  Formatters.swift            "184.8K", "Resets in 6d 4h", etc.
scripts/make-app.sh           Builds and installs the .app bundle
scripts/make-icon.swift       Renders AppIcon.icns from the in-app asterisk mark
```
