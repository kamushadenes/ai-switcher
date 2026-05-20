# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.0.0] - 2026-05-20

### Added

- Added first-class Claude.ai OAuth account capture, activation, switching,
  re-login, and local activity parsing alongside Codex account support.
- Added provider-scoped account pools so Codex and Claude each keep an
  independent active account.
- Added Claude OAuth usage polling from Anthropic's first-party usage endpoint
  with OAuth token refresh on endpoint rate limits and local auth/activity
  fallback bars when quota data is unavailable.

### Changed

- Renamed the product to AI Switcher with bundle identifier
  `com.personal.ai-switcher` and fresh app data under `~/.ai-switcher`.
- Changed analytics, switch history, release metadata, and documentation to be
  provider-aware while preserving verified Codex usage bars and only showing
  Claude quota values when first-party usage data is available.
- Changed Claude account switching to capture isolated `CLAUDE_CONFIG_DIR`
  logins, copy only Claude `.credentials.json` files during activation, and
  patch only Claude Code account identity fields in `~/.claude.json` while
  leaving Nix-managed Claude configuration untouched.

### Fixed

- Fixed provider-scoped active account state after adding, recovering, or
  deleting Claude and Codex profiles.
- Fixed provider-scoped stale account tracking so Codex limit refreshes do not
  clear Claude auth recovery warnings.
- Fixed historical appcast entries so they keep pointing at existing
  CodexSwitcher release assets.
- Fixed the menu bar item startup state so AI Switcher shows a visible fallback
  label before account data finishes loading.
- Fixed Claude activity loading to cache transcript metadata while preserving
  full transcript archive coverage.
- Fixed Claude OAuth login completion when Claude Code stores opaque OAuth
  tokens and exposes account identity through `claude auth status --json`.
- Fixed Claude auth-status checks so a hanging `claude auth status --json`
  command cannot stall account capture.
- Fixed Claude login polling to parse captured OAuth credentials before using
  the `claude auth status --json` fallback.
- Fixed Claude add-account and re-login flows to reuse captured credentials
  instead of repeatedly polling live Claude credentials after OAuth completion.
- Fixed Claude startup recovery for opaque Claude Code credential blobs.
- Fixed Claude usage polling to use saved profile credentials without touching
  live Claude credential files during background refreshes.
- Fixed cancelled Claude add-account flows to restore the previous active Claude
  credential even when another provider is selected.
- Fixed Claude re-login for inactive profiles so live credentials return to the
  active Claude profile after the refreshed credentials are saved.
- Fixed Claude re-login timeout and cancellation cleanup so abandoned re-login
  attempts cannot hijack later add-account completions.
- Fixed abandoned Claude login timeouts to restore the previously active Claude
  credentials instead of leaving partial OAuth credentials live.
- Fixed Claude automatic switching and health indicators to respond to fetched
  Claude quota exhaustion.
- Fixed Claude automatic switching to defer credential-file changes while a
  Claude process is still running.
- Fixed Claude running-session detection so OAuth login commands and shell
  diagnostics do not block usage refreshes or deferred switches.
- Fixed local app builds to prefer a stable code-signing identity over ad-hoc
  signing so macOS can trust the same app identity across launches.
- Fixed Claude usage bars and exhaustion checks to include active model-specific
  and monthly quota windows returned by the first-party usage endpoint.
- Fixed Claude quota parsing to ignore unknown experimental quota windows until
  they are explicitly supported.
- Fixed Claude Opus weekly quota parsing so Opus-specific exhaustion is shown
  and can trigger account switching.
- Fixed active Claude usage polling to keep refreshed profile credentials in
  AI Switcher without mutating live Claude credentials during background
  refreshes.
- Fixed active Claude OAuth refresh to update stored profile credentials without
  rewriting live Claude credentials during usage polling.
- Fixed Claude account verification so switches validate the credential-file
  copy instead of querying live Claude auth status.
- Fixed startup recovery stale marking so a failure in one provider does not
  mark unrelated active provider accounts stale.
- Fixed Claude account switching to perform credential-file activation off the
  main UI thread, skip main-thread Claude verification retries, and ignore
  duplicate switch clicks while activation is already running.
- Fixed first Claude activation on fresh installs so captured credentials are
  copied into a live Claude credential file even when none existed before.
- Fixed Claude credential restoration so opaque saved credential blobs are
  copied without live auth-status validation or rollback prompts.
- Fixed startup Claude auth recovery to run away from the main UI actor so
  launch does not freeze the menu bar while credential recovery is checked.
- Fixed Claude running-session detection to run `ps` away from the main UI actor
  with a timeout so rate-limit refreshes cannot freeze menu interactions.
- Fixed Claude running-session detection to drain `ps` output while the process
  runs so large process lists do not make the probe time out as not running.
- Fixed Claude add-account, cancel, timeout, re-login, and delete restore paths
  so Claude credential writes use the off-main activation path.
- Fixed Claude usage polling to preserve and honor usage endpoint `Retry-After`
  backoff hints.
- Fixed provider-scoped pending switch and exhaustion state so Claude automation
  does not block independent Codex account switching.
- Fixed automatic switch cooldown and fallback restart cleanup so they apply to
  the provider being switched without clearing unrelated provider queues.
- Fixed switch orchestration state so completed or blocked switches do not hide
  pending switches for other providers.
- Fixed switch timeline provider attribution after seamless verification
  completes or becomes inconclusive.
- Fixed Claude usage refresh deferral while Claude is running so it does not
  create a long stale polling backoff.
- Fixed Codex seamless-switch fallback so it restarts the verified Codex target
  even when Claude is selected in the UI.
- Fixed Claude usage rate-limit handling so usage endpoint `Retry-After`
  responses are backed off without an immediate OAuth refresh retry.
- Fixed queued automatic switches so they execute through the automatic
  activation path instead of manual override handling.
- Fixed no-restart Codex switch timeline events to retain provider attribution.
- Fixed cross-provider quota refreshes so they cannot fail an unrelated
  provider's active seamless verification.
- Fixed Claude identity detection so explicit non-Claude.ai auth status cannot
  fall back to stale OAuth credential files.
- Fixed Claude active-account verification so live auth status cannot override
  credential-file state.
- Fixed Claude usage credential selection so non-Claude.ai auth status cannot
  reuse or persist stale OAuth credential files.
- Fixed Claude credential restore writes so recreated credentials use Claude
  Code's live credential file.
- Fixed Claude credential access so background usage polling and startup
  recovery do not show repeated macOS credential prompts.
- Fixed Claude transcript parsing so actual tool-result logs are not treated as
  user prompts, large tool-result payloads are skipped before JSON parsing,
  literal `tool_result` prompt text is preserved, and unchanged transcript
  caches are not rewritten on every refresh.
- Fixed statistics reset so Claude transcript activity caches are deleted along
  with Codex token and session caches.
- Fixed first-launch session cache rebuilds so Codex and Claude transcript
  scans use stable file fingerprints, preserve empty caches, and do less date
  parsing work.
- Fixed Claude automatic switching so unrelated repeated Codex usage fetch
  failures do not suppress successful Claude quota refresh handling.
- Fixed failed re-login attempts so stale re-login targets are cleared before
  the next account flow.
- Fixed Claude usage polling to refresh expired OAuth access tokens before
  marking an account stale.
- Fixed Claude switching so Claude Code's root account metadata is updated to
  the selected profile and stale metadata fails switch verification.

## [2.2.5] - 2026-04-14

### Fixed

- Fixed Codex crash-screen recovery after a background account refresh by
  auto-clicking `Reload` when the `An error has occurred` page appears.
- Fixed the background cutover path so automatic window recovery prevents users
  from staying on the SIGTERM crash page.

## [2.2.4] - 2026-04-14

### Added

- Added drag-to-reorder account rows with persisted ordering.
- Added a dedicated Settings view with theme mode, text size, text family,
  accent color presets, and a live preview card.
- Added typed switch decision records, readiness evaluation, bounded decision
  persistence, and safer manual override behavior.
- Added a unified diagnostics timeline that merges switch decisions, automation
  events, reconciliation anomalies, alerts, and data-quality signals.
- Added read-only local Codex thread intelligence from `state_5.sqlite` with
  recent activity, repo hot spots, and open spawn-edge visibility in analytics.
- Added contextual next-action recommendations and remembered analytics history
  tab state.
- Added targeted regression coverage for diagnostics, workflow summaries,
  recommendations, audit exports, and session-usage caching.

### Changed

- Changed account switching to refresh Codex's bundled app-server in the
  background so the window stays open while new credentials load.
- Changed menu highlights, active indicators, progress bars, and analytics
  summary accents to follow the selected appearance preset.
- Changed JSON audit exports to include diagnostics summary and timeline data
  without leaking prompt text or local project paths.

### Fixed

- Fixed switched accounts so they no longer require a full visible Codex
  relaunch to escape stale `you hit limit` local sessions.
- Fixed session usage tracking around day boundaries so midnight sessions are
  counted correctly.

## [2.2.2] - 2026-04-10

### Added

- Added targeted regression coverage for deferred notification permission
  scheduling and single-run gating.

### Changed

- Changed notification authorization to run from a deferred, one-shot launch
  bootstrap instead of eager singleton construction.

### Fixed

- Fixed a launch crash by moving notification permission requests out of
  `AppStore` initialization so the menu bar app no longer aborts during early
  startup on some macOS setups.

## [2.1.4] - 2026-04-04

### Added

- Added a sortable forensic ledger in the analytics window with summary pills,
  reason codes, confidence labels, and row drilldown.

### Changed

- Changed CSV and JSON exports to carry reconciliation rows and policy metadata
  without prompt text or local project paths.
- Changed automatic switching to react at `weekly <= 5%` or `5-hour <= 7%`
  instead of waiting for hard exhaustion.
- Changed account switches to restart a running Codex process so the active CLI
  does not stay pinned to an exhausted account.
- Changed manual selection and `Switch Now` to skip accounts below safe weekly
  or 5-hour thresholds.

### Removed

- Removed old audit generation logic while retaining bounded compatibility
  export fields for migration.

## [2.1.3] - 2026-04-03

### Added

- Added direct `CSV` and `JSON` export for trust and audit data from the
  analytics window.
- Added provider delta evidence with audit summary, full drain event rows, and
  timeline points for offline inspection.
- Added idle-window drain forensic exports so suspicious drops can be shared and
  reviewed outside the app.
- Added regression coverage for CSV audit columns and JSON audit payloads.

## [2.1.2] - 2026-04-03

### Added

- Added a usage audit layer that compares consecutive rate-limit snapshots
  against local usage records to flag explained, weak, and unattributed drain
  events.
- Added idle drain detection in the analytics window for limit drops that happen
  while no local Codex activity is observed.
- Added a compact drain timeline for inspecting suspicious provider-side
  capacity drops over time.
- Added targeted regression coverage for unattributed drain, explained drain,
  idle windows, and audit timeline generation.

### Changed

- Changed per-account confidence wording to reflect fetch health instead of
  implying provider correctness.

### Removed

- Removed the large automation confidence and attention blocks from History so
  the analytics window owns detailed diagnostics.

## [2.1.1] - 2026-04-03

### Added

- Added switch timeline states for queued, ready, verifying, seamless,
  fallback, and inconclusive events with wait and verification timing.
- Added automation confidence health summaries and per-account attention strips
  for stale auth, fetch instability, and fallback pressure.
- Added deduplicated automation health alerts for degraded automation and stuck
  pending switches.
- Added a separate analytics window for cost control and operational visibility
  with summary cards, trends, breakdowns, limit pressure, and alert panels.

### Changed

- Changed menu actions into a compact vertical sidebar while preserving the
  existing glass styling.
- Changed popover width and sidebar proportions so account cards have a cleaner
  layout.
- Changed the main list, add-account flow, and footer strip to reduce wasted top
  and bottom space.
- Changed recent automation, reliability, and health labels to render
  consistently in Turkish and English.
- Changed menubar analytics, deep views, and the analytics window to read from a
  shared snapshot model.
- Changed derived project, session, hourly, and top-cost analytics to come from
  `AnalyticsEngine` over raw usage and session records.

### Fixed

- Fixed the Add Account `Start` action to launch `codex login` through a login
  shell more reliably and show visible failure feedback.
- Fixed Add Account to avoid opening the Codex sign-in browser twice while the
  CLI owns the auth window.
- Fixed Add Account completion layout and the inline `Close` button dismissal.
- Fixed Projects CSV export to open a real save flow and write stable escaped
  output.
- Fixed weekly budget saving to recheck usage immediately so over-budget
  warnings fire without waiting for a later refresh.
- Fixed auto-switches to queue during active work and execute after the session
  goes idle.
- Fixed seamless switch verification to prefer restart-free switching and only
  fall back to restarting Codex when post-switch limit behavior still indicates
  failure.
- Fixed range filtering so insights include recent turns from older sessions.
- Fixed range-safe chart summaries so per-account cost labels show only the
  matching 7-day cost window.

## [2.1.0] - 2026-04-03

### Added

- Added update status visibility for current version, latest version, last
  checked time, and update state.
- Added `7d`, `30d`, and `all-time` range filters for insights and chart views.
- Added rate-limit health diagnostics for stale reason, HTTP failure context,
  and last successful fetch per account.
- Added release automation through `./scripts/release.sh <issuer-id>` for tests,
  signed and notarized builds, tags, and GitHub release publishing.
- Added parser and update-check regression coverage for ranges, login URL
  extraction, and release state parsing.

### Fixed

- Fixed Add Account and Re-login to capture the auth URL from `codex login`
  output and open the browser reliably.

## [2.0.1] - 2026-04-03

### Fixed

- Fixed bundle version, release build script, and GitHub update detection so
  they stay aligned.
- Fixed multi-event token streams to merge into a single turn instead of
  undercounting projects and Top $.
- Fixed heatmap activity buckets to use actual turn timestamps instead of only
  session start time.
- Fixed nested sub-agent sessions so they render recursively in the Sessions
  view.

## [2.0.0] - 2026-04-03

### Changed

- Changed the architecture by removing multi-provider abstractions for a
  simpler and faster Codex-only codebase.
- Changed the Codex-only migration to preserve rate-limit bars, forecasting,
  token tracking, insights, and budget alerts.

### Removed

- Removed Claude Code support to focus on OpenAI Codex account management.

## [1.14.0] - 2026-04-03

### Added

- Added Claude Code account management alongside Codex accounts with credentials
  stored in Keychain.
- Added Codex Insights tabs for projects, sessions, heatmap, Top $, and chart
  views.
- Added weekly budget alerts for USD spend limits.
- Added automatic Sunday evening weekly token and cost summary notifications.

### Changed

- Changed cost calculation to use real input and output token splits from JSONL
  instead of a 50/50 approximation.
- Changed Claude login to use `zsh -l` so the `claude` binary resolves from
  common shell paths.

### Removed

- Removed Sparkle from update checking in favor of GitHub API-based updates.

### Fixed

- Fixed the reset button with a confirmation dialog, cache clearing, immediate
  UI refresh, and reset coverage for all Insights views.
- Fixed the Update button so it always opens the releases page when clicked.

## [1.9.1] - 2026-04-03

### Fixed

- Fixed Codex force-quit by switching from `terminate()` to `forceTerminate()`
  so the app no longer shows a "Quit Codex?" dialog.
- Fixed the app icon so it appears correctly in Dock and Finder.

## [1.9.0] - 2026-04-03

### Added

- Added switch history icons for automatic and manual switches.
- Added Developer ID signing and Apple notarization so first launch avoids
  Gatekeeper warnings.

### Changed

- Changed Codex account switches to automatically close and relaunch Codex after
  every switch.

## [1.8.2] - 2026-04-01

### Fixed

- Fixed automatic switching to confirm rate limits through the API before
  switching, eliminating false positives.

## [1.8.1] - 2026-04-01

### Fixed

- Fixed long-running sessions so they no longer produce token spikes at the
  7-day boundary.
- Fixed attribution for tokens from before any switch history by dropping them
  instead of misattributing them.

## [1.8.0] - 2026-04-01

### Changed

- Changed token parsing to use per-event delta attribution, eliminating billions
  of misattributed tokens.

## [1.7.0] - 2026-04-01

### Added

- Added reset statistics to clear token, cost, and forecast data.
- Added a re-login flow to refresh expired tokens without leaving the app.
- Added an 80% weekly usage warning notification.

### Changed

- Changed the polling interval from 60 seconds to 300 seconds for better energy
  usage.

### Fixed

- Fixed a file descriptor leak in background polling.

[unreleased]: https://github.com/kamushadenes/ai-switcher/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/kamushadenes/ai-switcher/compare/5fd5294...v3.0.0
[2.2.5]: https://github.com/kamushadenes/ai-switcher/tree/5fd5294
[2.2.4]: https://github.com/kamushadenes/ai-switcher/tree/9afc1fb
[2.2.2]: https://github.com/kamushadenes/ai-switcher/tree/2058117
[2.1.4]: https://github.com/kamushadenes/ai-switcher/tree/d6c3ee1
[2.1.3]: https://github.com/kamushadenes/ai-switcher/tree/ed26b37
[2.1.2]: https://github.com/kamushadenes/ai-switcher/tree/67c2165
[2.1.1]: https://github.com/kamushadenes/ai-switcher/tree/6368652
[2.1.0]: https://github.com/kamushadenes/ai-switcher/tree/fcfe084
[2.0.1]: https://github.com/kamushadenes/ai-switcher/tree/76cb818
[2.0.0]: https://github.com/kamushadenes/ai-switcher/tree/6b6a99a
[1.14.0]: https://github.com/kamushadenes/ai-switcher/tree/16cd980
[1.9.1]: https://github.com/kamushadenes/ai-switcher/tree/3fd7a68
[1.9.0]: https://github.com/kamushadenes/ai-switcher/tree/80b1cc5
[1.8.2]: https://github.com/kamushadenes/ai-switcher/tree/99d7a27
[1.8.1]: https://github.com/kamushadenes/ai-switcher/tree/d2dda1f
[1.8.0]: https://github.com/kamushadenes/ai-switcher/tree/7aad87d
[1.7.0]: https://github.com/kamushadenes/ai-switcher/tree/85481f6
