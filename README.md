# AI Switcher

A macOS menu bar app that manages multiple Codex and Claude.ai OAuth accounts,
keeps one active account per provider, and gives you local activity analytics
for AI coding sessions.

![macOS](https://img.shields.io/badge/macOS-26%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.2-orange)
![License](https://img.shields.io/badge/license-MIT-green)

<p align="center">
  <img src="assets/readme/analytics-window.png" width="1100" alt="AI Switcher analytics window with summary cards, token and cost trends, breakdowns, limit pressure, and alerts">
</p>

<p align="center">
  <img src="assets/readme/accounts-overview.png" width="31%" alt="Accounts overview with weekly and 5-hour rate limit bars, token usage, and cost">
  <img src="assets/readme/chart-view.png" width="31%" alt="Chart view showing token usage trends by account">
  <img src="assets/readme/projects-view.png" width="31%" alt="Projects view with per-project token and cost breakdown">
</p>

<p align="center">
  <img src="assets/readme/sessions-view.png" width="31%" alt="Sessions view with searchable threaded AI coding session history">
  <img src="assets/readme/heatmap-view.png" width="31%" alt="Heatmap view showing the busiest coding hours across the week">
  <img src="assets/readme/top-dollar-view.png" width="31%" alt="Top dollar view ranking the most expensive prompts by cost">
</p>

---

## Features

### Account Management

- **Provider pools** — Manage separate Codex and Claude account pools with one
  active account per provider
- **Auto-switching** — Codex detects weekly and 5-hour pressure via API and
  switches to the best available Codex account automatically
- **Smart selection** — Codex picks the account with the lowest weekly usage %,
  not round-robin
- **Proactive thresholds** — Codex leaves the active account before hard
  exhaustion at `weekly <= 5%` or `5-hour <= 7%`
- **Background cutover refresh** — When Codex is active, the app refreshes its
  bundled background runtime on switch so the new account is actually applied
  without closing the window
- **Claude restart guidance** — Claude switches copy the active
  `.credentials.json` data, patch only the account identity fields in
  `~/.claude.json`, and notify you to restart open `claude` sessions
- **Switch verification** — Switch telemetry records queued, restarted, and
  fallback states for postmortems
- **Re-login flow** — Refresh stale tokens without leaving the app
- **Account aliases** — Friendly names per account, rename via right-click
- **Auth recovery** — Automatic recovery if Codex auth is corrupted and
  stale-state handling for provider credentials

### Token & Cost Tracking

- **Codex token attribution** — Accurate per-account tracking using delta
  computation from Codex JSONL session files
- **Real Codex input/output split** — Cost calculation uses actual
  `input_tokens`/`output_tokens` from session logs
- **Codex cost tracking** — Per-account USD cost with model-specific pricing for
  gpt-4.x, gpt-5.x, o3, o4-mini
- **Codex rate limit bars** — Weekly and 5-hour remaining progress bars per
  Codex account
- **Codex rate limit forecasting** — Estimates time-to-exhaustion based on usage
  pace
- **Claude local activity** — Claude sessions and projects are read from local
  transcripts without inventing quota, token, or cost numbers
- **80% warning** — Notification when a Codex account approaches its weekly
  limit
- **Restored notifications** — Get notified when a limited account becomes
  available again
- **Weekly budget alerts** — Set a USD budget; receive a notification when you
  exceed it
- **Weekly summary** — Automatic Sunday evening stats notification

### AI Coding Insights (Analytics)

- **Projects** — Per-project activity and, where verified, token/cost breakdown
  with drill-down and CSV export
- **Sessions** — Full session list with search, parent/child threading, agent
  role badges (reviewer, explorer, worker)
- **Heatmap** — 7-day × 24-hour activity heatmap showing when you code most
- **Top $** — Codex prompts ranked by USD cost when verified token fields exist
- **Chart** — 7-day daily token usage chart per Codex account
- **Reconciliation ledger** — Provider-side limit drops are matched against
  local usage with explained, weak, unexplained, idle, and ignored windows
- **Forensic export** — Ledger rows export as CSV/JSON with reason codes,
  confidence, matched sessions, and policy metadata

### UI & UX

- **Account health indicators** — 🟢 healthy · 🟡 stale token · ⚪ unchecked ·
  🔒 exhausted
- **Live session indicator** — Green pulse when tokens are actively being
  consumed
- **Switch history** — Full log with type icons: ⚡ auto-switch · ↔ manual
  switch
- **Automation timeline** — Queued, ready, verifying, seamless, fallback, and
  inconclusive switch events with timing details
- **Automation confidence** — In-app health summary for stale auth, fallback
  pressure, and stuck pending switches
- **Email privacy** — One-click blur toggle for email addresses
- **Dark / Light mode** — Persistent appearance preference
- **TR / EN language** — Turkish and English UI (auto-detects system language)
- **Update checker** — GitHub-based update notifications (no Sparkle dependency)

---

## Requirements

- macOS 26 (Tahoe) or later
- [OpenAI Codex CLI](https://github.com/openai/codex) installed
- [Claude Code CLI](https://code.claude.com/docs/en/cli-usage) installed for
  Claude account support

---

## Installation

1. Download `AISwitcher-vX.X.X-signed.zip` from the [Releases](../../releases)
   page
2. Unzip and move `AISwitcher.app` to `/Applications`
3. Launch — the app appears in the menu bar

> Signed with a Developer ID certificate and notarized by Apple. No Gatekeeper
> warning on first launch.

To launch at login: **System Settings → General → Login Items** → add
`AISwitcher`.

## Release Automation

Single command local release flow:

```bash
./scripts/release.sh 10585e36-d130-478a-b63a-5b871d472338
```

What it does:

- runs `swift test`
- builds the signed and notarized app
- reads the version from `Info.plist`
- validates the matching changelog entry in `CHANGELOG.md`
- creates/pushes the git tag if needed
- creates or updates the GitHub release and uploads the signed zip

---

## How It Works

```
~/.codex/auth.json              ← active Codex credentials (Codex reads this)
~/.codex/sessions/**/*.jsonl    ← session logs (token usage, prompts, models)
~/.claude/accounts/*/.credentials.json ← active Claude Code OAuth credentials
~/.claude.json                  ← Claude Code account identity metadata
~/.claude/projects/**/*.jsonl  ← Claude local activity transcripts
~/.ai-switcher/profiles/       ← stored credentials per account
~/.ai-switcher/cache/          ← token delta cache for fast attribution
```

1. AI Switcher stores profile credentials in `~/.ai-switcher` and leaves legacy
   `~/.codex-switcher` data untouched.
2. Codex switching atomically replaces `~/.codex/auth.json` with the selected
   Codex profile.
3. Claude login and re-login run with an isolated `CLAUDE_CONFIG_DIR`, then
   Claude switching copies the selected `.credentials.json` data into the
   existing live Claude credential file and patches only `emailAddress`,
   `organizationUuid`, `organizationName`, and `displayName` under
   `~/.claude.json`'s `oauthAccount`.
4. If Codex work is still active, the switch is queued until a safe boundary is
   reached.
5. If Codex is active, AI Switcher refreshes the bundled background runtime
   during switch so the new account is guaranteed to take effect without closing
   the window.
6. If Claude sessions are open, AI Switcher notifies you to restart them after
   the credential file changes.
7. Analytics keeps a reconciliation ledger so provider-side limit drops can be
   compared against local activity later.

Codex token attribution reads `input_tokens`, `cached_input_tokens`, and
`output_tokens` from each session's JSONL events and maps them to the account
that was active at that timestamp. Claude local activity is shown without
inferred token or cost values unless a verified first-party source is added.

---

## Adding Accounts

1. Click **+ Add Account**
2. Choose **Codex** or **Claude**
3. Browser opens automatically for OAuth sign-in
4. Sign in — AI Switcher detects the new credentials automatically
5. Give the account an alias → click **Save**

---

## Usage

| Action                 | How                                                 |
| ---------------------- | --------------------------------------------------- |
| Switch account         | Click an account row                                |
| Force switch to next   | **Switch Now** in the footer                        |
| View switch history    | **History** tab                                     |
| View analytics         | **Chart / Projects / Sess. / Heatmap / Top $** tabs |
| Rename account         | Right-click → **Rename**                            |
| Delete account         | Right-click → **Delete**                            |
| Re-login stale account | Right-click → **Re-login**                          |
| Set weekly budget      | Settings bar → **$X/$Y** button                     |
| Reset token statistics | Settings bar → **↺** (with confirmation)            |
| Blur/show emails       | Settings bar → **Show/Hide**                        |
| Toggle dark/light      | Settings bar → **Dark/Light**                       |
| Change language        | Settings bar → **🌐** (Auto → TR → EN)              |
| Check for updates      | Footer → **Update** (opens GitHub releases page)    |

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

---

## Architecture

| File                           | Responsibility                                                                        |
| ------------------------------ | ------------------------------------------------------------------------------------- |
| `AppStore.swift`               | Central state, profile CRUD, provider selection, smart switching, rate limit polling  |
| `ProfileManager.swift`         | Codex auth file backup plus Claude credential-file profile management and verification |
| `ClaudeCodeManager.swift`      | Claude Code credential-file read/write and auth status parsing                        |
| `SessionTokenParser.swift`     | Codex per-event delta attribution and session records                                 |
| `ClaudeTranscriptParser.swift` | Claude local activity transcript parsing without inferred usage numbers               |
| `RateLimitFetcher.swift`       | Codex API polling for rate limit data                                                 |
| `RateLimitForecaster.swift`    | Usage pace analysis and exhaustion prediction                                         |
| `CostCalculator.swift`         | USD cost calculation with model-specific pricing                                      |
| `UsageMonitor.swift`           | FSEvents-based session log watcher                                                    |
| `UpdateChecker.swift`          | GitHub API update checker                                                             |
| `MenuContentView.swift`        | Popover UI with tab navigation                                                        |
| `ProjectBreakdownView.swift`   | Projects analytics tab with drill-down and CSV export                                 |
| `SessionExplorerView.swift`    | Sessions tab with search and thread tree                                              |
| `HeatmapView.swift`            | 7×24 activity heatmap                                                                 |
| `ExpensivePromptsView.swift`   | Top 20 most expensive prompts                                                         |
| `UsageChartView.swift`         | 7-day daily usage chart                                                               |
| `BundleExtension.swift`        | Bundle.appResources — correct icon/resource lookup in signed .app                     |
| `L10n.swift`                   | TR/EN localization                                                                    |

---

## Contributing

Pull requests are welcome. Please open an issue first for major changes.

1. Fork the repo
2. Create a branch: `git checkout -b feature/your-feature`
3. Commit: `git commit -m 'feat: add your feature'`
4. Push: `git push origin feature/your-feature`
5. Open a Pull Request

---

## License

MIT — see [LICENSE](LICENSE)

---

## Author

**Senol Dogan** — Senior Full Stack Developer

- Website: [senoldogan.dev](https://www.senoldogan.dev)
- Email: [contact@senoldogan.dev](mailto:contact@senoldogan.dev)
- LinkedIn:
  [linkedin.com/in/senoldogann](https://www.linkedin.com/in/senoldogann)
- X / Twitter: [@senoldoganx](https://x.com/senoldoganx)
