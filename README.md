# Codex Account Tracker

A private native macOS SwiftUI app for tracking Codex quota state across ChatGPT/Codex accounts.

The app talks to a local Codex app-server over WebSocket and stores persistent account snapshots at:

```text
~/Library/Application Support/CodexAccountTracker/accounts.json
```

It is intentionally separate from the Codex Quota menu bar app. The menu bar app is for tiny live quota visibility; this app is a private multi-account dashboard that remembers every account it has seen.

## What It Tracks

Each saved account card shows:

- email
- plan type
- 5-hour quota used and remaining
- 5-hour reset time
- weekly quota used and remaining
- weekly reset time
- manually editable ChatGPT subscription expiration/renewal date
- last seen time
- active account indicator

`primary` quota is treated as the 5-hour window. `secondary` quota is treated as the weekly window. Remaining percent is calculated as `100 - usedPercent`.

## Azure Usage Dashboard

The Azure Usage and OpenAI Codex Usage sections are separate from the ChatGPT/Codex account quota cards. They scan local Codex JSONL logs and recompute token usage without changing the saved account tracker data. Full scan results are cached locally after each scan so the app can reopen with the last known dashboard immediately and only rescan when you click refresh/scan.

Log paths scanned:

```text
~/.codex/sessions/**/*.jsonl
~/.codex/archived_sessions/**/*.jsonl
```

Counting rules:

- A session is included in Azure Usage only when a `session_meta` record has `payload.model_provider == "azure"`.
- A session is included in OpenAI Codex Usage only when `session_meta.payload.model_provider == "openai"` and `session_meta.payload.originator == "Codex Desktop"`.
- The active model/deployment is read from preceding `turn_context` records with `payload.model`.
- Token usage is counted only from `event_msg` records where `payload.type == "token_count"`.
- Only `payload.info.last_token_usage` is summed.
- Azure de-dupes repeated `payload.info.total_token_usage` cumulative signatures within a session.
- OpenAI Codex de-dupes repeated cumulative signatures by `(session_meta.payload.id, total_token_usage_signature)`, processes sessions by `session_meta.timestamp`, and skips fork startup replay bursts.
- Malformed, missing, or negative usage records are skipped.
- Events before a model is known are grouped under `unknown`.

Token totals include input tokens, cached input tokens, uncached input tokens, output tokens, reasoning output tokens, total tokens, and event count. Full cached scan results are filtered in memory for all time, last 24 hours, last 7 days, or usage since a custom date. The cache files live in `~/Library/Application Support/CodexAccountTracker/` and store token usage summaries/records only, not secrets.

The dashboards also show estimated USD cost by model and in total. Cost estimates use built-in per-1M-token pricing presets when the local deployment/model name can be recognized. Current presets include GPT-5.5, GPT-5.5 pro, GPT-5.4, GPT-5.4 mini, and a GPT-5 fallback for OpenAI Codex-style model names. For `gpt-55` / GPT-5.5, the default estimate uses $5.00 per 1M uncached input tokens, $0.50 per 1M cached input tokens, and $30.00 per 1M output tokens. Reasoning output tokens are included in output token totals and are not billed as a separate line item by this local estimate. Unknown model pricing is shown as $0 until a pricing preset is added.

Azure endpoint/resource/deployment grouping is best-effort. Codex session logs reliably expose Azure provider and model/deployment, but they may not include the Azure endpoint or resource. The app safely reads non-secret local metadata from files such as `~/.codex/config.toml` and `/opt/homebrew/bin/codex-azure` when present, ignoring lines that look like keys, tokens, passwords, credentials, or bearer secrets. If endpoint/resource cannot be discovered, usage is grouped under `unknown endpoint` and a warning is shown.

Local Codex logs may not contain all Azure billing dimensions, pricing inputs, or server-side billing adjustments. Azure prices can vary by model version, deployment type, region/data zone, provisioned throughput, reservations, batch discounts, enterprise agreement, and future price changes. Treat this dashboard as a local token-usage and estimated-cost view, not an Azure billing statement.

## How Updates Work

- `Live Monitor` connects to the configured local Codex app-server and listens for `account/updated` and `account/rateLimits/updated`.
- WebSocket notifications are the primary update path.
- A 300-second refresh loop is kept as a low-overhead fallback.
- If a refresh is already running, one follow-up refresh is queued instead of dropping the update.
- If Live Monitor is disconnected unexpectedly, the app automatically tries to reconnect.
- Quota notifications are only applied after confirming the currently active account with `account/read`, so account switches do not save a quota snapshot under the wrong email.
- If the app-server accepts a WebSocket connection but does not answer a JSON-RPC request, the request times out after 10 seconds instead of leaving the UI stuck refreshing.

Codex app-server only reports the currently active Codex account. For inactive saved accounts, the app preserves the last real snapshot. If a saved reset timestamp has passed while that account is inactive, the app locally marks that window as reset (`0%` used, `100%` remaining) on startup and during the once-per-minute display clock. That inferred reset is written back to `accounts.json`, but the reset timestamp itself remains the last Codex-provided timestamp until Codex provides a fresh real snapshot for that account.

## Server Options

Recommended steady state:

- Codex Quota Menu owns `ws://127.0.0.1:49731`.
- Codex Account Tracker owns `ws://127.0.0.1:14567`.

Keeping them separate avoids both apps being disrupted by the same app-server restart during account switches.

The shared endpoint is:

```text
ws://127.0.0.1:49731
```

This matches the Codex Quota menu app.

The private fallback endpoint is:

```text
ws://127.0.0.1:14567
```

This is the default endpoint for the account tracker when no preference has been saved.

Buttons:

- `Live Monitor`: connect to the currently configured endpoint.
- `Start Shared Server`: start `codex app-server` on `ws://127.0.0.1:49731`.
- `Start Own Server`: start `codex app-server` on `ws://127.0.0.1:14567`.
- `Refresh`: do a one-shot refresh from the configured endpoint.

If a launched app-server exits, the app clears its running-server state so the UI does not get stuck showing a dead server as running. When stopping a managed server, the app also terminates child app-server processes so stale orphaned servers do not keep occupying the shared/private ports after account switches or restarts.

## Security posture

- Does not read browser cookies.
- Does not request Full Disk Access.
- Does not request Accessibility.
- Does not request Screen Recording.
- Does not store OpenAI passwords.
- Does not store Codex auth tokens.
- Does not store Azure API keys or secrets.
- Does not print or expose secret-bearing config lines while scanning Azure usage metadata.
- Does not request broad Keychain access.
- Connects only to the configured local `codex app-server` URL.

## Development

Build:

```sh
swift build
```

Run:

```sh
swift run CodexAccountTracker
```

Package a simple `.app` bundle:

```sh
./scripts/package_app.sh
```

The generated app bundle is written to `.build/Codex Account Tracker.app`.

The clickable Dock/Finder bundle used during local development is:

```text
Codex Account Tracker.app
```

When replacing that bundle's executable manually, re-sign it and then reapply the custom Finder icon. The custom icon uses Finder metadata, so strict codesign verification may complain after the icon is applied even though normal local verification passes.

## Private GitHub Repo Notes

This project is currently intended for a private repository.

Safe to commit:

- `Package.swift`
- `Sources/`
- `Assets/`
- `scripts/`
- `.github/workflows/build.yml`
- `.gitignore`
- `README.md`

Do not commit:

- `.build/`
- generated `.app` bundles
- `.DS_Store`
- runtime `accounts.json`
- local logs or temporary files

The included GitHub Actions workflow runs a release build on macOS with:

```sh
swift build -c release
```
