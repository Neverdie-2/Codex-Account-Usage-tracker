# Cursor Source for Codex Account Tracker — Integration Plan

## 1. Overview & Assumptions

This plan **adds Cursor as another tracked source inside the existing Codex Account Tracker app** — the native SwiftUI macOS 14 SwiftPM app whose source lives in `Sources/CodexAccountTracker/` and whose folder currently holds this plan doc. It is **not** a new standalone app. The app already multi-tracks several sources (Codex/ChatGPT account quota cards via `AccountRecord`/`AccountStore`, plus usage dashboards for Azure, OpenAI Codex, Claude Code, and LM Studio, all driven by `AccountTrackerViewModel` → `ContentView`). Cursor becomes two **new sections** in that same window, persisted into the **same** Application Support directory, refreshed by the **same** ViewModel loop.

The Cursor feature surfaces Cursor account data in **two tables / two new sections**:

- **TABLE 1 — USAGE**: one row per Cursor conversation (composer), showing workspace/project, title, mode, model(s) actually used, message counts, AI lines added/removed, files changed, activity times, with **Today / 24h / 7d / All** filters and a **"models used today"** rollup chip list.
- **TABLE 2 — PER-ACCOUNT LIMITS**: one row per signed-in Cursor account, showing email, membership/plan, % used (auto / api / total), % remaining, included/bonus/total breakdown, billing-cycle reset + countdown, and on-demand status.

The app **runs on the user's Mac**: the new Cursor layer reads local Cursor files (`state.vscdb`, `renderer.log`, optionally the ai-tracking DB) and calls `cursor.com` with the local access token. This plan is meant to be executed in a **cloud session that has no access to this Mac**, so it embeds every concrete path, SQL shape, endpoint, JSON sample, and auth step, plus **offline fixtures + unit tests** so the cloud build is fully self-verifiable without live data.

### Assumptions (decided)

1. **Integration, not a new app.** All new code is added to the existing `CodexAccountTracker` module under `Sources/CodexAccountTracker/`. There is **no new `Package.swift`, no new `@main` App, no new module/target**. Type names are `Cursor*` types living **inside** the `CodexAccountTracker` module.
2. **Single Cursor account for v1.** The Cursor account model is kept as an **array of records keyed by lowercased email** (mirroring `AccountRecord.id`) so multi-account is a later additive change (see §14), not a rewrite — but v1 renders the single signed-in Cursor user.
3. **Reuse the existing app shell, ViewModel, and persistence.**
   - Persistence reuses `~/Library/Application Support/CodexAccountTracker/` via the canonical accessor `AzureUsageCacheStore.defaultDirectoryURL()`, with **`cursor-*`-prefixed** cache files: `cursor-usage-cache.json`, `cursor-usage-index.json`, `cursor-accounts.json`.
   - Refresh folds into the existing `AccountTrackerViewModel` 30-second refresh cycle (the live-client loop driven by `refreshIntervalSeconds`) and the existing 60-second `displayNow` clock, using the same `is*Refreshing` guard pattern the other usage sources use.
   - The two Cursor sections sit **alongside** the existing dashboards inside `ContentView`'s `LazyVStack`, rendered with the app's existing card/section/pill components.
4. **Stack is the existing one.** SwiftUI, `swift-tools-version:5.9`, `platforms: [.macOS(.v14)]`, system frameworks only (SwiftUI, AppKit, Foundation, Combine, Security, SQLite3), no third-party deps. SQLite via `import SQLite3` (already used by `OpencodeUsageStore`).
5. **Keep the "models used today" rollup and the Today/24h/7d/All filter** exactly as specified in §4 — that is the Cursor-specific extraction logic and does not change for integration.

---

## 2. Architecture — how Cursor plugs into the existing app

The app's wiring is: **plain file-IO stores → one `@MainActor ObservableObject` ViewModel (`AccountTrackerViewModel`, single source of truth) → SwiftUI `struct` views via `@EnvironmentObject`.** Cursor adds new data-layer classes, new `@Published` state on the existing ViewModel, and two new sections in the existing `ContentView`. Nothing about the existing wiring changes.

```
Local Cursor files / cursor.com API
   │
   ▼
┌──────────────────────────────────────────────────────────────┐
│ NEW DATA LAYER (plain final classes, no UI)                  │
│  CursorStateDBReader     copy-WAL → read-only SQLite          │
│  CursorUsageScanner      composers + bubbles → CursorUsageRecord[]
│  CursorRendererLogReader [buildRequestedModel] cross-check    │
│  CursorAuth              token→JWT→cookie                     │
│  CursorAPIClient         GET usage-summary/auth-me/auth-stripe│
│  CursorUsageCacheStore   cursor-usage-cache.json              │
│  CursorUsageIndexStore   cursor-usage-index.json (fingerprint)│
│  CursorAccountStore      cursor-accounts.json                 │
└──────────────────────────────────────────────────────────────┘
   │ load()/save(), scan(), fetch()
   ▼
┌──────────────────────────────────────────────────────────────┐
│ AccountTrackerViewModel  (EXISTING @MainActor ObservableObject)
│   + @Published private(set) cursorUsage: CursorUsageDashboard │
│   + @Published private(set) cursorAccounts: [CursorAccountRecord]
│   + @Published private(set) isCursorUsageRefreshing / isCursorLimitsRefreshing
│   + @Published private(set) cursorUsageLastScannedAt / cursorLimitsLastFetchedAt
│   + @Published var cursorUsageWindow: CursorUsageTimeWindow { didSet → rebuild }
│   start():     + loadCursorCaches(); + refreshCursorUsage(); + refreshCursorLimits()
│   30s loop:    + refreshCursorUsage()/refreshCursorLimits() folded into the cycle
│   60s clock:   reused for the billing-cycle countdown
└──────────────────────────────────────────────────────────────┘
   │ @EnvironmentObject
   ▼
┌──────────────────────────────────────────────────────────────┐
│ EXISTING ContentView → LazyVStack { … existing sections … ,  │
│   + CursorLimitsSectionView,                                  │
│   + CursorUsageSectionView }                                  │
└──────────────────────────────────────────────────────────────┘
```

**The two tables.** TABLE 1 is built by scanning local SQLite (composers + bubbles) into `CursorUsageRecord[]` → filtered in memory into a `CursorUsageDashboard` (mirrors how `AzureUsageScanner.dashboard(from:window:now:)` produces `AzureUsageDashboard`). TABLE 2 is built by reading the local token, calling `cursor.com/api/usage-summary` (+ `/auth/me`, `/auth/stripe`), mapping into `CursorAccountRecord`, and persisting to `cursor-accounts.json` via `CursorAccountStore`.

**Why a parallel `CursorAccountRecord` + `CursorAccountStore`** (not the existing `AccountRecord`/`AccountStore`): the existing `AccountRecord` is a fixed-shape `Codable` value type with Codex-specific two-window quota fields (`primary*`/`secondary*`/`*ResetsAt`), and `AccountStore` is hardcoded to `[AccountRecord]` → `accounts.json`. Cursor's single monthly cycle + percent-breakdown + on-demand shape does not fit those fields. The cleanest match to the real design is to **mirror the `AccountStore` pattern exactly** in a small parallel `CursorAccountStore` writing `cursor-accounts.json` (atomic, `[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]`, sorted by lowercased email), holding `[CursorAccountRecord]`. This keeps the Codex account card untouched and avoids overloading `AccountRecord` with Cursor-only optionals.

**Refresh model (folds into the existing loop).** `AccountTrackerViewModel.start()` already loads caches (`loadUsageCaches()`), starts the 60s `displayNow` clock (`startDisplayClock()`), kicks initial refreshes, and runs the 30s live loop. Cursor adds:
- `loadCursorCaches()` inside `start()` (right next to `loadUsageCaches()`) so the two sections render instantly from cache.
- One initial `refreshCursorUsage()` + `refreshCursorLimits()` in `start()`.
- A periodic re-trigger folded into the existing 30s cycle (see §9).
The billing-cycle countdown reuses the existing `displayNow` (no new clock).

**Key divergences from a Codex source (state in the plan, do not "port" blindly):**
- **No WebSocket / no child process.** Cursor uses a plain HTTPS API (`CursorAPIClient`, URLSession), unlike Codex's `CodexServerManager` + `CodexRPCClient`. There is no managed server, no notifications — the limits subsystem is a timed HTTPS poll + the existing Refresh buttons.
- **One monthly cycle, not 5h+weekly windows.** Cursor's `billingCycleStart → billingCycleEnd` is a single monthly window. The Codex account card's two `QuotaPanel`s become **one** "Billing cycle" panel in `CursorLimitsSectionView`. (Reuse the existing `FixedColorProgressBar`; the existing `QuotaPanel` is `private` to `ContentView.swift`, so add a Cursor-shaped panel there or a small new equivalent.)
- **Usage source is Cursor's local SQLite** (`state.vscdb`), not `~/.codex` / `~/.claude` JSONL. The fingerprint-index incremental pattern (`CodexLocalUsageFileFingerprint`-style `path+fileSize+modificationTimeNanoseconds`) is kept but keyed on `state.vscdb`.

---

## 3. File Tree

### 3a. NEW files added to `Sources/CodexAccountTracker/`

```
Sources/CodexAccountTracker/
├── CursorStateDBReader.swift            WAL-safe copy(state.vscdb+-wal+-shm)→temp→open read-only;
│                                          helpers itemValue(key:) + cursorDiskKVValues(likePrefix:) with trailing-`-` anchoring; temp cleanup
├── CursorRendererLogReader.swift        newest-mtime session dir; scan window*/renderer.log; [buildRequestedModel] (localTimestamp, modelName)
├── CursorAITrackingDBReader.swift       OPTIONAL: scored_commits sums; conversation_summaries enrichment if populated (tolerate EMPTY)
├── CursorUsageModels.swift              CursorUsageRecord, CursorUsageScanResult/Summary, CursorUsageDashboard, CursorUsageTimeWindow
├── CursorUsageScanner.swift             composers+bubbles → records; dedupe by id; dashboard(from:window:now:); modelsUsedToday rollup
├── CursorUsageCacheStore.swift          cursor-usage-cache.json {scannedAt,result}; mirrors AzureUsageCacheStore conventions
├── CursorUsageIndexStore.swift          cursor-usage-index.json; versioned (v=1, discard on mismatch); state.vscdb fingerprint; mirrors ClaudeCodeUsageIndexStore
├── CursorAccountRecord.swift            account/limits record (Codable/Equatable/Identifiable by lowercased email); blank(email:) + apply(...)
├── CursorAccountStore.swift             cursor-accounts.json load()/save() atomic, sorted by lowercased email; mirrors AccountStore exactly
├── CursorAuth.swift                     read accessToken; JWT base64url decode → sub/aud/exp; isExpired; cookieHeaderValue(sub:jwt:)
├── CursorAPIClient.swift                ephemeral URLSession; GET usage-summary/auth-me/auth-stripe/usage; 10s timeout; 401/403→.unauthorized
├── CursorLimitsModels.swift             UsageSummaryResponse, AuthMeResponse, AuthStripeResponse, LegacyUsageResponse (Codable, forgiving)
├── CursorUsageSectionView.swift         TABLE 1 section: window Picker + "models used today" chips + table + per-section Refresh
└── CursorLimitsSectionView.swift        TABLE 2 section: ForEach(cursorAccounts) → CursorAccountCardView (billing-cycle panel, breakdown, countdown, on-demand, stale badge)
```

### 3b. EXISTING files MODIFIED

| File | Edit |
|---|---|
| `Sources/CodexAccountTracker/AccountTrackerViewModel.swift` | Add Cursor `@Published` state (`cursorUsage`, `cursorAccounts`, `isCursorUsageRefreshing`, `isCursorLimitsRefreshing`, `cursorUsageLastScannedAt`, `cursorLimitsLastFetchedAt`, `cursorUsageWindow` with `didSet → rebuildCursorUsageDashboard()`). Add private stores (`cursorUsageCacheStore`, `cursorUsageIndexStore`, `cursorAccountStore`, `cursorScanner`, `cursorAPIClient`, `cursorScanResult`). Add `loadCursorCaches()` and call it inside `start()` next to `loadUsageCaches()`. Add `refreshCursorUsage()` and `refreshCursorLimits()` (the `is*Refreshing`-guarded, `Task.detached(.utility)` pattern used by `refreshLMStudioUsage()`/`refreshClaudeCodeUsage()`). Add `rebuildCursorUsageDashboard()`. Kick both refreshes once in `start()`. Fold a periodic re-trigger into the existing 30s loop (see §9). |
| `Sources/CodexAccountTracker/ContentView.swift` | Insert `CursorLimitsSectionView()` and `CursorUsageSectionView()` into the `LazyVStack` in **both** the `accounts.isEmpty` branch and the populated branch (alongside `AzureUsageSectionView()` … `LMStudioUsageSectionView()`). Place Cursor sections after the existing usage sections. (`StatusPill`, `PlanPill`, `FixedColorProgressBar`, `QuotaPanel` already live here and are reused/mirrored by the new section files.) |
| `Sources/CodexAccountTracker/AppPreferences.swift` | Add a `cursorUsageWindow` key (`codexAccountTracker.cursorUsageWindow`) backing the Today/24h/7d/All default, mirroring the `openAIAPIUsageWindow` get/set pair. Optionally a one-shot `cursorUsageBackfillDone` marker if a full rescan-on-upgrade is ever needed (not required for v1). |
| `Package.swift` | Add `resources: [.copy("Fixtures")]` to the existing `testTarget` (it currently has none). No other target/product change. |
| `Sources/CodexAccountTracker/SettingsView.swift` | Add read-only Cursor rows to the existing `Form`: API base (`https://cursor.com`), Cursor storage files (`cursor-usage-cache.json`, `cursor-accounts.json` under the existing storage path), and the Cursor usage-window default. Reuse the existing `LabeledContent` style. |

> No new `Package.swift`, no new `@main`, no new `scripts/`. The Cursor types compile into the existing `CodexAccountTracker` target.

### 3c. NEW test files + fixtures under `Tests/CodexAccountTrackerTests/`

```
Tests/CodexAccountTrackerTests/
├── Fixtures/                                  (NEW — wired via Package.swift resources: [.copy("Fixtures")])
│   ├── composerHeaders.sample.json            allComposers[] sample (embedded in §6.3)
│   ├── bubbles.sample.json                     bubbleId rows (type1 user w/ modelInfo, type2 assistant null)
│   ├── usage-summary.sample.json               captured /api/usage-summary 200 body
│   ├── auth-me.sample.json                     captured /api/auth/me 200 body
│   ├── auth-stripe.sample.json                 captured /api/auth/stripe 200 body
│   ├── renderer.sample.log                     [buildRequestedModel] lines
│   └── make_sample_vscdb.sql                   SQL to build a tiny SQLite fixture (ItemTable + cursorDiskKV)
├── CursorUsageScannerTests.swift               model extraction, dedupe, message counts, window filtering, today rollup
├── CursorStateDBReaderTests.swift              reads fixture .vscdb (copy-read), anchored LIKE join, prefix-decoy
├── CursorAuthTests.swift                       JWT base64url decode (padding), cookie format, exp-expired path
├── CursorLimitsParsingTests.swift              usage-summary/auth-me/auth-stripe decode, pct_remaining, countdown math, null onDemand
└── CursorDateBucketTests.swift                 ms-epoch↔Date, UTC→local day buckets, countdown formatting (Dd HHh MMm)
```

> Existing tests (`OpencodeUsageStoreTests`, `LMStudioConversationStoreTests`, `LMStudioPricingTests`) use `@testable import CodexAccountTracker` and inline JSON literals; the Cursor tests follow the same convention but also load `Fixtures/` via `Bundle.module`. Adding `resources: [.copy("Fixtures")]` is required for `Bundle.module` to find them.

---

## 4. TABLE 1 — USAGE Spec

**Row grain.** One row **per Cursor conversation (composer)**, keyed by `composerId` from `ItemTable['composer.composerHeaders'].allComposers[]`. A secondary `(model × today)` rollup is computed for the "models used today" chips. Filters (Today / 24h / 7d / All) apply to `last_activity_time` converted UTC→local against local-day boundaries — implemented as a **predicate**, not a stored column.

### 4.1 Copy-before-read (mandatory)

`state.vscdb` is SQLite **WAL mode held open by Cursor**. Never open the live file with a writer. `CursorStateDBReader`:

1. Resolve `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (+ `-wal`, `-shm`). **Ignore `state.vscdb.backup`** (stale).
2. `FileManager.copyItem` **all three** (`state.vscdb`, `state.vscdb-wal`, `state.vscdb-shm`) into a temp dir under `NSTemporaryDirectory()`. Copying only the main file silently loses today's un-checkpointed data (`-wal` is the freshest).
3. Open the **copy** read-only: `sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)` then `PRAGMA query_only=ON;` (use `file:<copy>?mode=ro` URI form). Run queries, close, delete temp dir. (Same SQLite3 C-API conventions as `OpencodeUsageStore.readMessageRows`.)

### 4.2 Columns

| Column | Source | Extraction |
|---|---|---|
| `conversationId` | `ItemTable['composer.composerHeaders']` | `SELECT value FROM ItemTable WHERE key='composer.composerHeaders'`; `JSON.allComposers[i].composerId`. Join key to `bubbleId:<composerId>-*`. |
| `workspace_project` | `allComposers[i].workspaceIdentifier` | `workspaceIdentifier.uri.path` (full path) + `.id`. Display **basename** of `uri.path`; keep full path+id for grouping. Null/absent → **"Unscoped"**. |
| `title` | `allComposers[i].name` (fallback `.subtitle`) | `name`; if empty/null → `subtitle`; then first user-bubble text truncated. Optional override: `conversation_summaries.title WHERE conversationId=composerId` (EMPTY this install — never block on it). |
| `mode` | `allComposers[i].unifiedMode` (fallback `forceMode`) | `unifiedMode ∈ {chat,agent,debug}`; if null use `forceMode`. |
| `models_used` | `cursorDiskKV 'bubbleId:<composerId>-*'` → `modelInfo.modelName` | `SELECT value FROM cursorDiskKV WHERE key LIKE 'bubbleId:'\|\|:composerId\|\|'-%'`. Per bubble JSON read `modelInfo.modelName` — **reliable only on `type==1` (user) bubbles**; `type==2` (assistant) usually `modelInfo:null` → skip nulls. Collect **DISTINCT** non-null names (e.g. `composer-2.5`, `claude-4.5-opus-high-thinking`). **NEVER** use `cursor/lastSingleModelPreference` (picker selection, not served). Cross-check newest `renderer.log [buildRequestedModel]`. |
| `message_count` | `cursorDiskKV 'bubbleId:<composerId>-*'` | `SELECT count(*)`. `user_count` = `type==1`, `assistant_count` = `type==2`, `message_count = user+assistant`. |
| `ai_lines_added` | `allComposers[i].totalLinesAdded` | Direct int. Optional repo-level corroboration: `scored_commits.composerLinesAdded` (68 rows, populated). |
| `ai_lines_removed` | `allComposers[i].totalLinesRemoved` | Direct int. Corroboration: `scored_commits.composerLinesDeleted`. |
| `files_changed` | `allComposers[i].filesChangedCount` | Direct int (supplemental). |
| `context_usage_pct` | `allComposers[i].contextUsagePercent` | Direct numeric (supplemental, optional). |
| `first_activity_time` | `allComposers[i].createdAt` (ms-epoch UTC) | `Date(ms)`. Refine: `MIN(bubble.createdAt)` (ISO8601 `…Z`) UTC→local. |
| `last_activity_time` | `allComposers[i].lastUpdatedAt` (ms-epoch UTC) | `Date(ms)`. Refine: `MAX(bubble.createdAt)`. **This is the field the Today/24h/7d/All filter compares.** |

**LIKE-join hazard:** `composerId` is a hyphenated UUID; anchor the LIKE on the trailing `-` (`'bubbleId:'||composerId||'-%'`) so a composerId that is a *prefix* of another can't leak bubbles.

### 4.3 Time-window filtering

`CursorUsageTimeWindow: String, CaseIterable, Identifiable, Codable` with cases `.today, .last24h, .last7d, .all`, a `label`, and `startDate(now:) -> Date?` (nil = all) — same shape as the existing `AzureUsageTimeWindow` enum so the section's `Picker` reuses the same pattern. Predicate on `last_activity_time` (UTC→**local**):
- **Today**: `localDay(lastUpdatedAt) == localDay(now)`
- **24h**: `now - lastUpdatedAt <= 86400s`
- **7d**: `now - lastUpdatedAt <= 7*86400s`
- **All**: no filter

### 4.4 "Models used today" rollup

Across **all** composers, gather every bubble whose `createdAt` (ISO `…Z` UTC→local) falls on **today's local date**; collect **DISTINCT** `modelInfo.modelName` from `type==1` bubbles. Cross-validate by grepping `[buildRequestedModel]` in the **newest-mtime** session dir's `window*/renderer.log` (those timestamps are already local). Render as chips (e.g. `['composer-2.5']`) using the existing pill styling.

### 4.5 Incremental cache + index

- **Per-result cache**: `CursorUsageCacheStore` → `cursor-usage-cache.json`, shape `{"scannedAt":<iso>,"result":{"records":[…CursorUsageRecord…],"summary":{…}}}`, `JSONEncoder([.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])`, `.iso8601` dates — exactly the encoder config `AzureUsageCacheStore.save` uses. Loaded on launch via `loadCursorCaches()` so the table renders before any rescan.
- **Per-file index**: `CursorUsageIndexStore` → `cursor-usage-index.json`, versioned (`version=1`, discard on mismatch — mirrors `ClaudeCodeUsageIndexStore.load`), keyed by `state.vscdb` path with a fingerprint `{path,fileSize,modificationTimeNanoseconds}` (reuse `CodexLocalUsageFileFingerprint.make(fileURL:)` if convenient, or a `Cursor`-local copy of the same struct). Re-scan SQLite only when the fingerprint changes; otherwise reuse the cached parse.
- **Dedupe**: `CursorUsageRecord.id = "cursor-composer-<composerId>"`; the scanner merges by `id` into a `Dictionary` keyed on `id` so rescans overwrite rather than double-count — the same `mergedUsageResult`-by-`id` discipline the ViewModel already uses for the Azure/OpenAI/Claude/LM Studio results. `DISTINCT` model names per conversation and per today-rollup.

---

## 5. TABLE 2 — PER-ACCOUNT LIMITS Spec

**Row grain.** One row per signed-in Cursor account. Primary feed `GET /api/usage-summary`; identity `GET /api/auth/me`; plan detail `GET /api/auth/stripe`; cached `state.vscdb` `ItemTable 'cursorAuth/*'` fields as **offline fallback**. Cursor free plan = **single monthly included-usage cycle** anchored to `billingCycleStart/End` (no 5h/weekly windows).

### 5.1 Auth sequence (token → JWT → cookie → GET)

1. **Read token locally** (WAL-safe copy + read-only, §4.1): `SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'` → JWT (~424 chars, 3 dot-separated segments).
2. **JWT decode** (`CursorAuth`): split on `.`, take the **middle** segment, base64url-decode (`-`→`+`, `_`→`/`, pad to length%4 with `=`), `JSONDecode` payload. Read `payload.sub = "google-oauth2|user_XXXX"`, `payload.aud = "https://cursor.com"`, `payload.exp` (unix seconds). **If `exp <= now` → token expired → skip API**, use cached `ItemTable` fields + stale badge.
3. **Build cookie** (exact): `Cookie: WorkosCursorSessionToken=<sub>::<accessToken>` where `sub` **keeps** the `google-oauth2|` prefix, the separator is a **literal `::`**, followed by the **raw unmodified JWT**. (Dropping the prefix or using a single `:` → 401.)
4. `GET https://cursor.com/api/usage-summary` with that `Cookie` header + a normal `User-Agent` → 200 JSON → populate the limits row.
5. Optionally `GET /api/auth/me` (email, sub) and `/api/auth/stripe` (membershipType, subscriptionStatus, pendingCancellationDate) with the **same** cookie; `GET /api/usage?user=<sub>` for the de-emphasized legacy panel.
6. On any **401/403** → token invalid/expired → fall back to `ItemTable 'cursorAuth/cachedEmail'`, `'cursorAuth/stripeMembershipType'`, `'cursorAuth/stripeSubscriptionStatus'` and **mark the row stale**.

### 5.2 Columns

| Column | Source | Extraction |
|---|---|---|
| `email` | `/api/auth/me .email` (primary) | Fallback: `ItemTable 'cursorAuth/cachedEmail'`. Backs `CursorAccountRecord.id = email.lowercased()`. |
| `user_sub_id` | `/api/auth/me .sub` or JWT `.sub` | `user_XXXX`. Used for `/api/usage?user=<sub>`. |
| `plan_membership_type` | `usage-summary.membershipType` | Enrich with `stripe.membershipType`, `.individualMembershipType`, `.isYearlyPlan`, `.isOnStudentPlan`. Fallback `ItemTable 'cursorAuth/stripeMembershipType'`. |
| `subscription_status` | `stripe.subscriptionStatus` | e.g. `canceled`. Surface `stripe.pendingCancellationDate` if non-null. Fallback `ItemTable 'cursorAuth/stripeSubscriptionStatus'`. |
| `pct_used_auto` | `individualUsage.plan.autoPercentUsed` | + label `autoModelSelectedDisplayMessage` ("You've used 4% of your included total usage"). |
| `pct_used_api` | `individualUsage.plan.apiPercentUsed` | + label `namedModelSelectedDisplayMessage`. |
| `pct_used_total` | `individualUsage.plan.totalPercentUsed` | Headline % used for the monthly cycle. |
| `pct_remaining` | **Derived** | `100 - totalPercentUsed`, clamp `[0,100]` (no API field). |
| `included_bonus_total_breakdown` | `individualUsage.plan.breakdown` | `included`, `bonus`, `total` (+ `plan.used/limit/remaining/enabled`). Render "used X of total N (included I + bonus B)". |
| `billing_cycle_start` | `usage-summary.billingCycleStart` | ISO8601 UTC; display local. |
| `reset_timestamp` | `usage-summary.billingCycleEnd` | ISO8601 UTC = monthly RESET (anchored to account start, observed 20th @ 11:57:07 UTC). |
| `reset_countdown` | **Derived** from `billingCycleEnd` | `billingCycleEnd(UTC) - now(UTC)`, format `Dd HHh MMm`, driven by the existing `displayNow` 60s clock. |
| `on_demand_status` | `individualUsage.onDemand` | `enabled` (bool), `used`, `limit`, `remaining` (limit/remaining may be **null** when disabled → guard). "On-demand: off" when `enabled=false`. |
| `is_unlimited` | `usage-summary.isUnlimited` (+ `limitType`) | When true, **suppress % cards**, show "Unlimited". |
| `legacy_premium_requests` | `GET /api/usage?user=<sub>` | Per-model `{numRequests,numRequestsTotal,numTokens,maxTokenUsage,maxRequestUsage}` + `startOfMonth`. Free plan → 0/null (deprecated). Small **de-emphasized** secondary panel only. |

### 5.3 Monthly cycle replaces Codex's two windows

The existing Codex `AccountCardView` renders two `QuotaPanel`s (5-hour + Weekly). The Cursor `CursorAccountCardView` shows **one** "Billing cycle" panel: `pct_used_total` ring (reuse `FixedColorProgressBar`), `pct_remaining`, the `included + bonus = total` line, the reset date, and a live countdown to `billingCycleEnd` driven by `viewModel.displayNow`. `reset_countdown = max(0, billingCycleEnd - now)`. `CursorAccountRecord` stores exactly one cycle: `billingCycleStart`, `billingCycleEnd`, `totalPercentUsed`, `breakdown`, `onDemand`, `isUnlimited`, plus `stale: Bool` and `lastSeenAt: String`.

---

## 6. Data-Source Reference Appendix (for fixtures/tests)

### 6.1 Paths

- `state.vscdb` (PRIMARY): `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (+ `-wal`, `-shm`). SQLite WAL. **Ignore** `state.vscdb.backup`.
- ai-tracking DB (SECONDARY): `~/.cursor/ai-tracking/ai-code-tracking.db` (SQLite).
- renderer.log: `~/Library/Application Support/Cursor/logs/<sessionTimestampDir>/window<N>/renderer.log` — pick **newest-mtime** session dir, scan all `window*`.
- Cursor API: `https://cursor.com/api/{usage-summary,auth/me,auth/stripe,usage?user=<sub>}`.
- Tracker storage (SHARED with the existing app): `~/Library/Application Support/CodexAccountTracker/` — Cursor files are `cursor-usage-cache.json`, `cursor-usage-index.json`, `cursor-accounts.json`.

### 6.2 SQLite schema

```sql
-- state.vscdb
CREATE TABLE ItemTable    (key TEXT, value TEXT);   -- value = JSON
CREATE TABLE cursorDiskKV (key TEXT, value TEXT);   -- value = JSON
-- ItemTable keys:
--  'composer.composerHeaders'  -> { allComposers:[ {type,composerId,createdAt,unifiedMode,forceMode,
--        name,subtitle,totalLinesAdded,totalLinesRemoved,filesChangedCount,lastUpdatedAt,
--        contextUsagePercent,workspaceIdentifier:{id,uri:{path}}} ] }
--  'cursor/lastSingleModelPreference' -> {"composer":"gemini-3-flash"}   (picker, NOT model used)
--  'cursorAuth/accessToken' | 'refreshToken' | 'cachedEmail'
--  'cursorAuth/stripeMembershipType' | 'cursorAuth/stripeSubscriptionStatus'
-- cursorDiskKV keys:
--  'bubbleId:<composerId>-<bubbleUuid>' -> {type:1|2,text,modelInfo:{modelName}|null,createdAt:"…Z"}

-- ai-code-tracking.db
CREATE TABLE conversation_summaries(conversationId,title,tldr,overview,summaryBullets,model,mode,updatedAt); -- EMPTY here
CREATE TABLE scored_commits(commitHash,branchName,scoredAt,linesAdded,linesDeleted,tabLinesAdded,
  tabLinesDeleted,composerLinesAdded,composerLinesDeleted,humanLinesAdded,humanLinesDeleted,
  blankLinesAdded,blankLinesDeleted,commitMessage,commitDate,v1AiPercentage,v2AiPercentage);            -- 68 rows
CREATE TABLE tracking_state(key,value);  -- trackingStartTime -> {"timestamp":1768061488544}
```

### 6.3 Captured sample JSON (use verbatim as fixtures)

**`composer.composerHeaders` value** (`composerHeaders.sample.json`):
```json
{ "allComposers": [
  { "type":"head", "composerId":"11111111-2222-3333-4444-555555555555",
    "createdAt":1750405404081, "lastUpdatedAt":1750409004081,
    "unifiedMode":"agent", "forceMode":"agent",
    "name":"Refactor auth module", "subtitle":"",
    "totalLinesAdded":128, "totalLinesRemoved":17, "filesChangedCount":4,
    "contextUsagePercent":42.5,
    "workspaceIdentifier":{ "id":"ws_abc", "uri":{ "path":"/Users/me/Desktop/MyProject" } } },
  { "type":"head", "composerId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    "createdAt":1749000000000, "lastUpdatedAt":1749000600000,
    "unifiedMode":"chat", "forceMode":null,
    "name":"", "subtitle":"quick question",
    "totalLinesAdded":0, "totalLinesRemoved":0, "filesChangedCount":0,
    "contextUsagePercent":5.0, "workspaceIdentifier":null }
] }
```

**Bubble rows** (`bubbles.sample.json`, one object per `cursorDiskKV` row):
```json
[
  { "key":"bubbleId:11111111-2222-3333-4444-555555555555-b1",
    "value":{ "type":1, "text":"refactor this", "modelInfo":{ "modelName":"composer-2.5" }, "createdAt":"2026-06-20T07:43:24.081Z" } },
  { "key":"bubbleId:11111111-2222-3333-4444-555555555555-b2",
    "value":{ "type":2, "text":"done", "modelInfo":null, "createdAt":"2026-06-20T07:43:30.000Z" } },
  { "key":"bubbleId:11111111-2222-3333-4444-555555555555-b3",
    "value":{ "type":1, "text":"now tests", "modelInfo":{ "modelName":"claude-4.5-opus-high-thinking" }, "createdAt":"2026-06-20T08:10:00.000Z" } }
]
```

**`/api/usage-summary`** (`usage-summary.sample.json`):
```json
{ "billingCycleStart":"2026-05-20T11:57:07.800Z",
  "billingCycleEnd":"2026-06-20T11:57:07.800Z",
  "membershipType":"free", "limitType":"user", "isUnlimited":false,
  "autoModelSelectedDisplayMessage":"You've used 4% of your included total usage",
  "namedModelSelectedDisplayMessage":"You've used 0% of your included API usage",
  "individualUsage":{
    "plan":{ "enabled":true, "used":0, "limit":0, "remaining":0,
             "breakdown":{ "included":0, "bonus":7, "total":7 },
             "autoPercentUsed":7.0, "apiPercentUsed":0, "totalPercentUsed":3.5 },
    "onDemand":{ "enabled":false, "used":0, "limit":null, "remaining":null } },
  "teamUsage":{} }
```

**`/api/auth/me`** (`auth-me.sample.json`):
```json
{ "email":"angeldanielov9@gmail.com", "email_verified":true, "name":"Angel",
  "sub":"user_01ABCDEF", "created_at":"2026-05-20T11:57:07.800Z",
  "updated_at":"2026-06-20T11:57:07.800Z", "picture":null, "id":"user_01ABCDEF" }
```

**`/api/auth/stripe`** (`auth-stripe.sample.json`):
```json
{ "membershipType":"free", "paymentId":null, "subscriptionStatus":"canceled",
  "verifiedStudent":false, "trialEligible":false, "trialLengthDays":0,
  "isOnStudentPlan":false, "isOnBillableAuto":false, "customerBalance":0,
  "isYearlyPlan":false, "pendingCancellationDate":null, "individualMembershipType":"free" }
```

**`renderer.sample.log`**:
```
2026-06-20 10:43:12.456 [info] [buildRequestedModel] composer-2.5
2026-06-20 11:02:55.001 [info] [buildRequestedModel] composer-2.5
2026-06-20 11:40:09.300 [info] [buildRequestedModel] composer-2.5
```

**`make_sample_vscdb.sql`** (build the test DB offline; no live data needed):
```sql
CREATE TABLE ItemTable(key TEXT, value TEXT);
CREATE TABLE cursorDiskKV(key TEXT, value TEXT);
INSERT INTO ItemTable VALUES('composer.composerHeaders', readfile('composerHeaders.sample.json'));
INSERT INTO ItemTable VALUES('cursor/lastSingleModelPreference', '{"composer":"gemini-3-flash"}');
INSERT INTO ItemTable VALUES('cursorAuth/cachedEmail', 'angeldanielov9@gmail.com');
INSERT INTO ItemTable VALUES('cursorAuth/stripeMembershipType', 'free');
INSERT INTO ItemTable VALUES('cursorAuth/stripeSubscriptionStatus', 'canceled');
-- accessToken: a synthetic 3-segment JWT with base64url middle = {"sub":"google-oauth2|user_01ABCDEF","aud":"https://cursor.com","exp":4102444800}
INSERT INTO ItemTable VALUES('cursorAuth/accessToken', 'eyJhbGciOiJub25lIn0.<base64url-payload>.sig');
INSERT INTO cursorDiskKV VALUES('bubbleId:11111111-2222-3333-4444-555555555555-b1','{"type":1,"text":"refactor this","modelInfo":{"modelName":"composer-2.5"},"createdAt":"2026-06-20T07:43:24.081Z"}');
INSERT INTO cursorDiskKV VALUES('bubbleId:11111111-2222-3333-4444-555555555555-b2','{"type":2,"text":"done","modelInfo":null,"createdAt":"2026-06-20T07:43:30.000Z"}');
INSERT INTO cursorDiskKV VALUES('bubbleId:11111111-2222-3333-4444-555555555555-b3','{"type":1,"text":"now tests","modelInfo":{"modelName":"claude-4.5-opus-high-thinking"},"createdAt":"2026-06-20T08:10:00.000Z"}');
-- decoy: a prefix-colliding composerId under a different conversation must NOT leak into composer 1111…
INSERT INTO cursorDiskKV VALUES('bubbleId:11111111-2222-3333-4444-555555555555X-WRONG','{"type":1,"text":"decoy","modelInfo":{"modelName":"decoy-model"},"createdAt":"2026-06-20T09:00:00.000Z"}');
```
> The test must regenerate the JWT payload at build time (or hardcode a known base64url string) so `CursorAuthTests` can decode it deterministically. `exp=4102444800` (year 2100) keeps the token "valid"; a second fixture with `exp` in the past exercises the expired/stale path.

---

## 7. Networking + Auth Module Spec

**`CursorAuth.swift`**
- `func readAccessTokenJWT() throws -> String` — via `CursorStateDBReader` (copy-read), `SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'`.
- `func decode(jwt:) throws -> JWTPayload{ sub:String; aud:String; exp:Int }` — split on `.`, middle segment, base64url→base64 (`-`→`+`, `_`→`/`, pad `%4`), `JSONDecoder`. Throws on malformed.
- `func isExpired(_ payload:, now:) -> Bool` — `payload.exp <= Int(now.timeIntervalSince1970)`.
- `func cookieHeaderValue(sub:String, jwt:String) -> String` — `"WorkosCursorSessionToken=\(sub)::\(jwt)"`. `sub` keeps `google-oauth2|` prefix. **Never logged, never persisted.**

**`CursorAPIClient.swift`** (URLSession HTTPS; mirrors `OpenAIAPIBillingClient`'s async URLSession style)
- One `URLSession` with `URLSessionConfiguration.ephemeral` (no cookie/credential storage on disk).
- Per request: `URLRequest(url:)`, set `Cookie` header = `cookieHeaderValue(...)`, set a normal `User-Agent`, `timeoutInterval = 10`.
- `func fetchUsageSummary() async throws -> UsageSummaryResponse`
- `func fetchAuthMe() async throws -> AuthMeResponse`
- `func fetchAuthStripe() async throws -> AuthStripeResponse`
- `func fetchLegacyUsage(sub:) async throws -> LegacyUsageResponse` (best-effort; tolerate 0/null).
- **Error handling**: map `401/403` → `CursorAPIError.unauthorized` (caller marks row stale, falls back to cached `ItemTable` fields). Other non-2xx → `.httpStatus(code)`. Timeout/transport → `.network`. JSON decode failure → `.decoding`. All decode types are forgiving: missing optionals default to nil, `onDemand.limit/remaining` are `Int?`.
- **No token persistence**: the JWT and cookie live only on the stack for the duration of a call; nothing writes them to disk or logs. (No Keychain entry — unlike the OpenAI admin key, the Cursor token is read fresh from the DB each call.)

---

## 8. UI Spec — two new sections inside the existing `ContentView`

The existing `ContentView` body is a `VStack { HeaderView(); ScrollView { LazyVStack { …account cards…, AzureUsageSectionView(), OpenAIUsageSectionView(), ClaudeCodeUsageSectionView(), LMStudioUsageSectionView() } } }`, rendered in **both** the `accounts.isEmpty` and populated branches. The two Cursor sections are added to that same `LazyVStack`, after the existing usage sections, in both branches. They are `@EnvironmentObject` views like every other section — no new scene, no new window, no menu-bar item.

Reuse the existing components (all defined in `ContentView.swift`): `StatusPill`, `PlanPill`, `FixedColorProgressBar`, the section card chrome (`.padding(16).background(Color(nsColor:.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(Color(nsColor:.separatorColor),lineWidth:1))`), and the per-section header layout (title + subtitle on the left, a `Picker` + a `Refresh` button on the right) that `CodexLogUsageSectionView` establishes. The Cursor `QuotaPanel`-equivalent mirrors the existing `QuotaPanel` (which is `private` to `ContentView.swift`).

**`CursorLimitsSectionView`** (TABLE 2) — mirrors the account-card area:
- `ForEach(viewModel.cursorAccounts) { CursorAccountCardView(account:, displayNow: viewModel.displayNow) }`.
- Card header: email (`.textSelection`), `PlanPill(account.membershipType)`, `StatusPill("Stale")` when `account.stale`.
- One **Billing-cycle panel**: `pct_used_total` headline + `FixedColorProgressBar(value: usedPercent, total: 100)`, `pct_remaining`, the `included + bonus = total` line, reset date + live countdown from `displayNow`. On-demand row ("On-demand: off" when disabled, guarding null limit/remaining). `isUnlimited` → show "Unlimited", suppress the ring. Optional small collapsible legacy-premium-requests panel.
- A per-section **Refresh** button → `viewModel.refreshCursorLimits()` with `.disabled(viewModel.isCursorLimitsRefreshing)`.

**`CursorUsageSectionView`** (TABLE 1) — mirrors `CodexLogUsageSectionView` structure:
- Header: title "Cursor Usage" + subtitle, a `Picker` bound to `$viewModel.cursorUsageWindow` (Today / 24h / 7d / All, labels from `CursorUsageTimeWindow.label`), a **"Models used today"** chip row (pills), and a **Refresh** button → `viewModel.refreshCursorUsage()` with `.disabled(viewModel.isCursorUsageRefreshing)`.
- A table (rows in a bordered `Color(nsColor:.textBackgroundColor)` container like `AzureUsageTableView`) with columns: project / title / mode / models / msgs (u+a) / +lines / −lines / files / last activity, fed by `viewModel.cursorUsage.records` already filtered by the selected window.
- Empty state: when no composers, a friendly in-section "No Cursor conversations yet" (not an error). When `state.vscdb` is missing/unreadable, show a banner with the expected path. When the token is expired/401, the Limits section shows cached fields with the "Stale" badge — the Usage section is independent of auth.

**`SettingsView`**: add read-only Cursor rows to the existing `Form(.grouped)` — API base (`https://cursor.com`), Cursor cache/account file names under the existing storage path (`viewModel.storagePath`), and the Cursor usage-window default. All read-only in v1 except the usage-window default.

**Permission/entitlements**: none. Cursor's files live under the user's own `~/Library/Application Support/Cursor` and `~/.cursor`, readable without Full Disk Access — same as the existing local-file sources.

---

## 9. Refresh / Caching / State (folded into `AccountTrackerViewModel`)

New `@Published` state on the existing ViewModel:
- `@Published private(set) var cursorUsage: CursorUsageDashboard = .empty`
- `@Published private(set) var cursorAccounts: [CursorAccountRecord] = []`
- `@Published private(set) var isCursorUsageRefreshing = false`
- `@Published private(set) var isCursorLimitsRefreshing = false`
- `@Published private(set) var cursorUsageLastScannedAt: Date?`
- `@Published private(set) var cursorLimitsLastFetchedAt: Date?`
- `@Published var cursorUsageWindow: CursorUsageTimeWindow = AppPreferences.cursorUsageWindow { didSet { AppPreferences.cursorUsageWindow = cursorUsageWindow; rebuildCursorUsageDashboard() } }`

New private members: `cursorUsageCacheStore`, `cursorUsageIndexStore`, `cursorAccountStore`, `cursorScanner` (`CursorUsageScanner`), `cursorAPIClient`, `cursorAuth`, and `var cursorScanResult: CursorUsageScanResult = .empty`.

**`start()` additions** (next to the existing `loadUsageCaches()` / initial refresh calls):
1. `loadCursorCaches()` — load `cursor-usage-cache.json` → `cursorScanResult` + `rebuildCursorUsageDashboard()`; load `cursor-accounts.json` → `cursorAccounts`. (The display clock and 30s loop already exist.)
2. Kick `refreshCursorUsage()` and `refreshCursorLimits()` once.

**`refreshCursorUsage()`** — copy the established source pattern (`refreshLMStudioUsage`/`refreshClaudeCodeUsage`):
```
guard !isCursorUsageRefreshing else { return }
isCursorUsageRefreshing = true
// fingerprint check: if state.vscdb fingerprint == cached index → reuse parse, just rebuild dashboard
Task { [weak self, cursorScanner, cursorUsageCacheStore, cursorUsageIndexStore] in
    let result = await Task.detached(priority: .utility) { cursorScanner.scan() }.value
    guard let self else { return }
    defer { isCursorUsageRefreshing = false }
    let scannedAt = Date()
    cursorScanResult = Self.mergedCursorResult(cursorScanResult, with: result)   // dedupe by id
    cursorUsageLastScannedAt = scannedAt
    cursorUsageCacheStore.save(cursorScanResult, scannedAt: scannedAt)
    cursorUsageIndexStore.save(fingerprintIndexFor(stateVscdb))
    rebuildCursorUsageDashboard()
}
```

**`refreshCursorLimits()`** — `is*Refreshing`-guarded async:
```
guard !isCursorLimitsRefreshing else { return }
isCursorLimitsRefreshing = true
Task { [weak self, cursorAPIClient, cursorAuth, cursorAccountStore] in
    guard let self else { return }
    defer { isCursorLimitsRefreshing = false }
    do {
        let jwt = try cursorAuth.readAccessTokenJWT()
        let payload = try cursorAuth.decode(jwt: jwt)
        if cursorAuth.isExpired(payload, now: displayNow) { applyStaleCursorAccountFromCachedItemTable(); return }
        let summary = try await cursorAPIClient.fetchUsageSummary()
        let me = try? await cursorAPIClient.fetchAuthMe()
        let stripe = try? await cursorAPIClient.fetchAuthStripe()
        var record = CursorAccountRecord(...map summary/me/stripe...)
        record.lastSeenAt = DateFormats.currentLocalTimestamp()   // reuse existing DateFormats
        upsertCursorAccount(record)
        cursorAccountStore.save(cursorAccounts)
        cursorLimitsLastFetchedAt = Date()
    } catch CursorAPIError.unauthorized {
        applyStaleCursorAccountFromCachedItemTable()              // ItemTable cursorAuth/* + stale badge
    } catch { lastError = error.localizedDescription }            // reuse existing lastError surface
}
```

**`rebuildCursorUsageDashboard()`**:
```
cursorUsage = CursorUsageScanner.dashboard(from: cursorScanResult, window: cursorUsageWindow, now: displayNow)
```

**Folding into the existing 30s loop.** The ViewModel's live loop runs `refreshLiveClient()` every `refreshIntervalSeconds` (30s). Add a parallel periodic trigger so Cursor stays current without touching the Codex live-monitor logic: either (a) call `refreshCursorUsage()` + `refreshCursorLimits()` from the same `startRefreshLoop()` body, or (b) add a dedicated `cursorRefreshTask` that sleeps `refreshIntervalSeconds` and calls both — cancelled in `shutdown()` alongside `displayClockTask`/`authMonitorTask`. Both are cheap and idempotent thanks to the `is*Refreshing` guards. (Prefer (a): one fewer task, and it matches how the existing loop drives a single refresh entry point.)

**Incremental scan-from-fingerprint:** `refreshCursorUsage` checks the `state.vscdb` fingerprint via `cursorUsageIndexStore`; unchanged → reuse the cached parse (skip the SQLite re-read), just `rebuildCursorUsageDashboard()`. Changed → re-copy + re-scan, merge by `id` (`mergedCursorResult` overwrites rows so re-scanned conversations never double-count).

**`shutdown()`**: cancel `cursorRefreshTask` if option (b) is used. (Option (a) needs no shutdown change.)

---

## 10. Build / Run / Package

This is the **existing** `CodexAccountTracker` package; the Cursor work is new files in the same target plus the small edits in §3b. From this folder:

- Build: `swift build`
- Run (window app): `swift run CodexAccountTracker`
- Test (offline): `swift test`
- Package `.app`: reuse the existing `scripts/package_app.sh` unchanged — it already builds `-c release` and assembles `Codex Account Tracker.app` from the `CodexAccountTracker` binary. No change needed for the Cursor source (same binary, same bundle).

**`Package.swift` edit (only change):** add `resources: [.copy("Fixtures")]` to the existing test target so the Cursor fixture files are bundled into `Bundle.module`:
```swift
.testTarget(
    name: "CodexAccountTrackerTests",
    dependencies: ["CodexAccountTracker"],
    path: "Tests/CodexAccountTrackerTests",
    resources: [.copy("Fixtures")]
)
```
> SQLite is linked via `import SQLite3` (already used by `OpencodeUsageStore`); no manifest dependency. No new product, target, or `@main`.

**Commit hygiene** (existing `.gitignore` already covers `.build/`, the built `.app`, `.DS_Store`): all `Sources/**` and `Tests/**` are commit-safe — fixtures are synthetic (no real JWT, no real message text; the placeholder email matches what's already in this repo's plan). **Never** commit a real `cursorAuth/accessToken`, a real `state.vscdb`, or any captured message bodies.

---

## 11. Test Plan (offline, embedded fixtures)

All tests run with **no network and no live Cursor data**, using `Tests/CodexAccountTrackerTests/Fixtures` (§6.3) loaded via `Bundle.module`. The test bundle builds a tiny SQLite from `make_sample_vscdb.sql` at setup (`sqlite3` via the SQLite3 C API in `setUp`, or a checked-in `.vscdb` byte fixture). Convention matches the existing tests: `import XCTest` + `@testable import CodexAccountTracker`.

1. **`CursorStateDBReaderTests`**: copy-then-read-only works; `SELECT value FROM ItemTable WHERE key='composer.composerHeaders'` round-trips; `LIKE 'bubbleId:'||composerId||'-%'` returns exactly the 3 bubbles for composer `1111…` and **not** the prefix-colliding decoy `bubbleId:…555555X-WRONG` (proves trailing-`-` anchoring).
2. **`CursorUsageScannerTests`**:
   - `models_used` for composer `1111…` = `["composer-2.5","claude-4.5-opus-high-thinking"]` (DISTINCT, type-1 only; type-2 null skipped).
   - `message_count=3` (`user=2`, `assistant=1`).
   - `ai_lines_added=128`, `ai_lines_removed=17`, `files_changed=4`.
   - `workspace_project` basename `MyProject`; second composer (null workspace) → `Unscoped`; title fallback `subtitle` → "quick question".
   - **Window filtering**: with `now=2026-06-20T12:00:00Z`, Today includes composer `1111…`, excludes `aaaa…` (2026-06-04).
   - **Models-used-today rollup**: bubbles dated `2026-06-20` (local) → `["composer-2.5","claude-4.5-opus-high-thinking"]`; `gemini-3-flash` (preference key) must **not** appear; `decoy-model` must **not** appear.
   - **Dedupe**: scanning twice yields identical record count (merge by `id`, no doubling).
3. **`CursorAuthTests`**: base64url decode with `-`/`_` and missing padding succeeds; `sub`/`aud`/`exp` parsed; `cookieHeaderValue` == `WorkosCursorSessionToken=google-oauth2|user_01ABCDEF::<jwt>` (literal `::`, prefix kept); past-`exp` fixture → `isExpired==true`.
4. **`CursorLimitsParsingTests`**: decode `usage-summary.sample.json` → `totalPercentUsed=3.5`, `pct_remaining=96.5`, `breakdown` `0+7=7`, `onDemand.enabled=false` with **null** limit/remaining handled; decode `auth-me`/`auth-stripe`; **countdown math** at `now=2026-06-19T11:57:07.800Z` vs `billingCycleEnd=2026-06-20T11:57:07.800Z` → `1d 00h 00m`; an `isUnlimited=true` variant suppresses the ring.
5. **`CursorDateBucketTests`**: ms-epoch `1750409004081` → correct `Date`; UTC `…Z` → correct **local** day; a 23:30Z timestamp crossing a local day boundary lands in the right "today" bucket; countdown formatter `Dd HHh MMm`.

**Done = `swift test` green** for the **whole existing app** (new Cursor tests pass AND the existing `OpencodeUsageStoreTests` / `LMStudioConversationStoreTests` / `LMStudioPricingTests` stay green); no test reaches the network or the real filesystem outside the fixtures dir.

---

## 12. Security & Privacy

- **Token use is minimal and ephemeral**: the `cursorAuth/accessToken` JWT is read from the copy of `state.vscdb` **only** to call its issuer `cursor.com`. It is **never logged, never persisted**, never written to cache, never put in the Keychain. `URLSession` uses `.ephemeral` config (no on-disk cookie/credential store).
- **No message text persisted**: caches (`cursor-usage-cache.json`, `cursor-usage-index.json`, `cursor-accounts.json`) store **summaries/counts/metadata only** — never bubble `text`. `cursor-accounts.json` holds no secrets (only email/plan/percentages/timestamps).
- **Copy-before-read** the WAL'd SQLite DB (main + `-wal` + `-shm`) and open the copy **read-only** (`SQLITE_OPEN_READONLY` + `PRAGMA query_only`); never open the live file with a writer (corruption + data-loss risk).
- **No special entitlements**: no Full Disk Access, Accessibility, or Screen Recording. All sources are under the user's own `~/Library/Application Support` and `~/.cursor`, readable without TCC prompts — consistent with the app's existing local-file sources.
- **Stale-not-error on auth failure**: on 401/403/expiry, fall back to cached `ItemTable 'cursorAuth/*'` fields with a visible "Stale" badge — never surface or store the raw token.
- **Commit hygiene**: the existing `.gitignore` already blocks `.build/` and the built `.app`; only synthetic fixtures are committed.

---

## 13. ULTRACODE Task Checklist (ordered, independently verifiable)

> Sized for parallel agents. Each task lists its **done-criterion** and whether it **adds file X** or **modifies existing file Y at hook Z**. Tasks within a wave are independent; later waves depend on earlier ones. Final gate: `swift build` + `swift test` green for the **whole existing app**, no regressions.

**Wave 0 — Shared scaffolding (modify existing)**
- **T0.1 — modify `Package.swift`.** Add `resources: [.copy("Fixtures")]` to the existing `testTarget`. **Add** the `Tests/CodexAccountTrackerTests/Fixtures/` files from §6.3. **Done:** `swift build` still succeeds; `Bundle.module` resolves the fixtures from a trivial test.
- **T0.2 — modify `AppPreferences.swift`.** Add `cursorUsageWindow` get/set (key `codexAccountTracker.cursorUsageWindow`) defaulting to `.today`, mirroring `openAIAPIUsageWindow`. **Done:** round-trips through `UserDefaults`; default is `.today`.

**Wave 1 — Data-layer readers (add, parallel)**
- **T1.1 — add `CursorStateDBReader.swift`.** Locate `state.vscdb`, copy main+`-wal`+`-shm` to temp, open read-only (SQLite3 C API like `OpencodeUsageStore`), helpers `itemValue(key:)` + `cursorDiskKVValues(likePrefix:)` with trailing-`-` anchoring; temp cleanup. **Done:** `CursorStateDBReaderTests` (read + anchored LIKE + prefix-decoy) pass.
- **T1.2 — add `CursorRendererLogReader.swift`.** Newest session dir, scan `window*/renderer.log`, return `(localTimestamp, modelName)` for `[buildRequestedModel]` lines. **Done:** parses `renderer.sample.log` → 3 `composer-2.5`, 0 gemini.
- **T1.3 — add `CursorAITrackingDBReader.swift` (optional).** `scored_commits` sums over a date window; `conversation_summaries` lookup tolerating EMPTY. **Done:** returns empty gracefully on empty fixture; sums correctly on a seeded one.

**Wave 2 — Usage subsystem (add)**
- **T2.1 — add `CursorUsageModels.swift`.** `CursorUsageRecord` (id, conversationId, workspaceProject{path,id,name}, title, mode, modelsUsed:[String], userCount, assistantCount, messageCount, linesAdded, linesRemoved, filesChanged, contextUsagePct, firstActivity, lastActivity), `CursorUsageScanResult/Summary` (with `.empty`), `CursorUsageDashboard` (with `.empty`), `CursorUsageTimeWindow` (`.today/.last24h/.last7d/.all`, `label`, `startDate(now:)`). **Done:** Codable round-trips; forward-compat (missing fields default).
- **T2.2 — add `CursorUsageScanner.swift`.** Composers → records; per-composer bubble query for models/counts/refined times; DISTINCT type-1 models; today-rollup; `static func dashboard(from:window:now:)`; merge/dedupe by id. **Done:** all `CursorUsageScannerTests` pass.
- **T2.3 — add `CursorUsageCacheStore.swift` + `CursorUsageIndexStore.swift`.** `cursor-usage-cache.json` (mirror `AzureUsageCacheStore` encoder config + `.iso8601`) and `cursor-usage-index.json` (versioned, fingerprint, mirror `ClaudeCodeUsageIndexStore`), both under `AzureUsageCacheStore.defaultDirectoryURL()`. **Done:** save/load round-trip; unchanged fingerprint skips rescan.

**Wave 3 — Limits subsystem (add, parallel with Wave 2)**
- **T3.1 — add `CursorAuth.swift`.** Token read, JWT base64url decode, `isExpired`, `cookieHeaderValue`. **Done:** `CursorAuthTests` pass.
- **T3.2 — add `CursorLimitsModels.swift` + `CursorAccountRecord.swift`.** UsageSummary/AuthMe/AuthStripe/LegacyUsage (forgiving Codable) + `CursorAccountRecord` (`id = email.lowercased()`, `blank(email:)`, apply/map helpers, `stale`, `lastSeenAt`). **Done:** decode all sample JSONs; `pct_remaining` computed; null `onDemand` handled.
- **T3.3 — add `CursorAPIClient.swift`.** Ephemeral URLSession, cookie header, 10s timeout, 401/403→`unauthorized`. **Done:** with a stubbed `URLProtocol` returning `usage-summary.sample.json`, returns a parsed response; stub 401 → `.unauthorized`.
- **T3.4 — add `CursorAccountStore.swift`.** `cursor-accounts.json` (atomic, sorted by lowercased email, `load()` → `[]` on failure) — mirror `AccountStore` exactly, with `defaultFileURL()` under the existing CodexAccountTracker dir. **Done:** round-trip; corrupt file → `[]` not throw.

**Wave 4 — ViewModel wiring (modify existing)**
- **T4.1 — modify `AccountTrackerViewModel.swift`.** Add the §9 `@Published` Cursor state, the private stores, `loadCursorCaches()` (call it inside `start()` next to `loadUsageCaches()`), `refreshCursorUsage()` + `refreshCursorLimits()` (the `is*Refreshing` + `Task.detached(.utility)` pattern), `rebuildCursorUsageDashboard()`, `cursorUsageWindow.didSet`, the initial kicks in `start()`, and the periodic re-trigger folded into `startRefreshLoop()`. **Done:** a ViewModel test drives `start()` with stub stores → `cursorUsage` + `cursorAccounts` populated; a re-entrant `refreshCursorUsage()` is a no-op while already refreshing; existing tests stay green.

**Wave 5 — UI (add + modify, after T4.1)**
- **T5.1 — add `CursorUsageSectionView.swift`.** Window `Picker` ($cursorUsageWindow), "Models used today" chips, table columns, per-section Refresh, Unscoped label, in-section empty/missing-DB states. Reuse `StatusPill`/section chrome. **Done:** renders fixture rows; switching window filters rows.
- **T5.2 — add `CursorLimitsSectionView.swift`.** `ForEach(cursorAccounts)` → `CursorAccountCardView`: billing-cycle panel (reuse `FixedColorProgressBar`), `pct_used_total`/`pct_remaining`, breakdown, live countdown from `displayNow`, on-demand row, `Stale` badge, `isUnlimited` path, optional legacy panel, `PlanPill`. **Done:** renders the sample account; countdown ticks with the 60s clock.
- **T5.3 — modify `ContentView.swift`.** Insert `CursorLimitsSectionView()` + `CursorUsageSectionView()` into the `LazyVStack` in **both** the empty and populated branches, after `LMStudioUsageSectionView()`. **Done:** both sections appear whether or not Codex accounts exist; existing sections unchanged.
- **T5.4 — modify `SettingsView.swift`.** Add read-only Cursor rows (API base, Cursor file names under `viewModel.storagePath`, usage-window default). **Done:** Settings shows the Cursor rows; no behavior change to existing rows.

**Wave 6 — Final gate**
- **T6.1 — whole-app verification.** `swift build` + `swift test` green; manual `swift run CodexAccountTracker` shows the two Cursor sections alongside the existing dashboards with no regressions. **Done:** zero new warnings beyond pre-existing baseline; existing `OpencodeUsageStoreTests`/`LMStudioConversationStoreTests`/`LMStudioPricingTests` still pass.

---

## 14. Open Questions / Future Work

- **Multi-account**: stores are already `[Record]` keyed by lowercased email. To extend: detect account switches via the `cursorAuth/cachedEmail` value changing (poll the copied DB like the existing `startAuthFileMonitor()` 2s loop does for `~/.codex/auth.json`), keep a per-email token, and render one `CursorAccountCardView` per account. The cookie/sub flow is per-token, so multi-account = looping the §5.1 sequence per stored token.
- **Live file watching**: replace the 30s usage poll with an `FSEvents`/`DispatchSource` watch on `state.vscdb`(+`-wal`) mtime to refresh the moment Cursor checkpoints, keeping the fingerprint index as the dedupe guard.
- **Per-model token/cost**: Cursor's `usage-summary` exposes only percentages/breakdown, not per-model tokens or USD. If Cursor ever exposes per-model token counts (or the legacy `/api/usage` is revived), add a cost panel like the Azure/LM Studio dashboards (`AzureUsageScanner` pricing); until then, cost is intentionally **omitted** (not estimated) to avoid fabricated numbers.
- **renderer.log as primary model source**: if bubble `modelInfo` ever stops being populated on type-1 bubbles, promote `[buildRequestedModel]` (local-timestamped) from cross-check to primary for "today".
- **Token-expiry UX**: surface JWT `exp` proactively (≈2-month lifetime) with a "re-open Cursor to refresh your session" hint before the badge turns stale.
