# Plan — refresh completeness (Batch 1) and per-request pricing (Batch 2)

Date: 2026-09-21 · Branch: `fix/refresh-completeness-and-pricing` · Author: Claude (for the operator)
Source review: `docs/reviews/codex-account-tracker-review-2026-09-21.md` (F01, F06, F07, F08; F09 is fixed as a side effect).
Everything in this plan is LOCAL: the tracker reads log files on this Mac and its own cache files. No network calls are added or changed.

Operator decisions quoted verbatim (2026-09-21):
- "we should jsut count it at 2.5x token price for astra"
- "for sub agents yeah they inherit the fast mode from the parent"

Build / test command (xcode-select points at CommandLineTools, which has no XCTest):
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

Hard limits for implementers:
- Do NOT touch `~/Library/Application Support/CodexAccountTracker/` (the live caches), do NOT install or launch the app, do NOT run `scripts/package_app.sh`.
- `Sources/CodexAccountTracker/UsageHistoryChartView.swift` has an uncommitted change that belongs to the operator. Do not edit, stage, commit, stash or revert it.
- Commit only your own files, on the current branch. Do not push.

---

## Batch 1 — a refresh must never lose usage

### What is broken (F01, F08)
`AccountTrackerViewModel.incrementalUsageRefreshStartDate` (≈line 1001) returns the timestamp of the newest record already known, across ALL chats. The scanner then skips every event at or before that moment (`AzureUsageScanner.processCodexLocalSession` ≈line 590, `scanClaudeCodeSessions` ≈line 770). With several agents writing at once, an agent's record written a moment late — but stamped earlier than another agent's newest record — is skipped on every later refresh. "All time" reuses the same cutoff (`windowAwareRefreshStartDate`, ≈line 1029), so it cannot recover it either.

### Live-state fact that shapes the fix (VERIFIED 2026-09-21, python over the live cache files)
Cached records whose source log file no longer exists on disk:
- Claude Code: 146,043 of 207,168 records (6,207 of 7,524 files gone — Claude Code deletes old transcripts)
- Codex (OpenAI): 163 of 81,048 · Codex Azure: 98 of 10,670

So any path that REPLACES the cached result with a fresh scan erases ~70% of the Claude history. The existing "full rebuild" path does exactly that today (`azureScanResult = needsFullRebuild ? result : merged`). Batch 2 needs a one-time full re-read, so this must be fixed first.

### The fix — one rule for every refresh
"Whatever is still on disk is re-derived from scratch; whatever is gone from disk is kept as it was."

1.1 **View model: always scan with no cutoff.** In `refreshAzureUsage`, `refreshOpenAIUsage`, `refreshClaudeCodeUsage` pass `nil` to `scan(since:)`. This is cheap: both scanners already keep a per-file index keyed by size+mtime (`CodexLocalUsageIndexStore`, `ClaudeCodeUsageIndexStore`), so unchanged files are not re-parsed; the Codex scanner already enumerates every file on every refresh. Remove the now-unused `incrementalUsageRefreshStartDate`, `openAIUsageRefreshStartDate`, `windowAwareRefreshStartDate`. Leave `scan(since:)` and the scanner's cutoff code untouched (existing tests cover it).
   Fixes: F01, F08. Side effect: F09 (old placeholder output counts are re-estimated for files still on disk).

1.2 **One merge rule for refresh AND rebuild.** Replace the `needsFullRebuild ? result : mergedUsageResult(...)` choice at all three sites with a single static function (testable, `internal` not `private`):
   `mergedPreservingVanishedFiles(previous:fresh:fileExists:) -> AzureUsageScanResult`
   - result records = every `fresh` record + every `previous` record whose `id` is not in `fresh` AND whose `filePath` does not exist on disk (`fileExists` injected; default `FileManager.default.fileExists(atPath:)`). Cache the existence check per distinct path — there are thousands of paths, not hundreds of thousands.
   - Azure sticky labels kept: when provider is `.azure` and an id is in both, keep the previous record's `endpoint`/`resource`/`deployment` (same as today's `mergedUsageResult`).
   - **Failed-scan guard:** if `fresh.records` is empty and `previous.records` is not, return `previous` unchanged.
   - summary: reuse the existing `mergedUsageSummary` logic.
   - Sorting as today (timestamp, then id).
   Keep `mergedUsageResult` for the LM Studio call site only.
   Fixes: the history-erasing rebuild (needed by Batch 2's migration).

1.3 **Tests** (new file `RefreshCompletenessTests.swift`):
   - late-written record: previous result's newest event is T3; a fresh scan contains an event at T2 < T3 that previous lacks → it is present after merge. (Scanner-level: two session files, second scan after appending an earlier-stamped event to file A while file B holds the newest event, scanning with `since: nil` → event counted.)
   - vanished file: previous has records for path P (fileExists → false) and fresh lacks them → kept. Same but fileExists → true → dropped.
   - failed-scan guard: fresh empty → previous returned.
   - Azure sticky labels survive.
   - input-cardinality assertion: merged count == fresh count + kept-vanished count.

### Not covered by Batch 1
Records from vanished files keep whatever was stored for them (cannot be re-derived). Stated in the Batch 2 notes.

---

## Batch 2 — price each request by what it actually was

All pricing flows through one choke point: `AzureModelPricing.defaultPricing(for:provider:)` → `estimatedCost(for: AzureTokenUsage)`. Cost is computed at display time from each record's `model` + `usage`, so price-table changes apply to history immediately; only NEW per-request facts need a re-read of the logs.

### 2.1 New per-request facts on `AzureTokenUsage`
- `cacheCreation1hInputTokens: Int` (default 0) — the part of `cacheCreationInputTokens` written to the 1-hour cache.
- `speed: AzureUsageSpeed` — `standard | fast | unknown` (String enum, Codable). Decoding a record that lacks the field gives `.unknown`. Constructors default to `.standard`.
- Both decoded with `decodeIfPresent`. `signature` and `isZero` stay exactly as they are (dedupe keys must not change meaning).

### 2.2 New optional fields on `AzureModelPricing` (all `decodeIfPresent`)
- `cacheWrite1hPerMillionUSD: Double?`
- `longContext: AzureLongContextRates?` = { `thresholdInputTokens`, input, cachedInput, cacheWrite (optional), output }
- `fastModeMultiplier: Double?`
`estimatedCost(for:)` becomes: pick long-context rates when `longContext != nil && usage.inputTokens > thresholdInputTokens` (272,000 → short; 272,001 → long; the whole request bills at the long rate); cost = uncached×in + (cacheCreation − 1h)×write + 1h×(write1h ?? write) + cached×cachedRate + output×out; then × `fastModeMultiplier` when `usage.speed == .fast` and a multiplier exists. Add `estimatedCostIfFast(for:)` (same, multiplier forced on) for 2.7.

### 2.3 Price table corrections (VERIFIED today at the primary pages; USD per 1M tokens: input / cached / cache-write / output)
OpenAI — https://developers.openai.com/api/docs/pricing
| Model | Short | Long (> 272K input) |
|---|---|---|
| gpt-6-astra | 10 / 1 / 12.50 / 50 (already right) | 20 / 2 / 25 / 75 |
| gpt-5.6-sol (and bare gpt-5.6) | 4 / 0.40 / 5 / 20 | 8 / 0.80 / 10 / 30 |
| gpt-5.6-terra | 2 / 0.20 / 2.50 / 12 | 4 / 0.40 / 5 / 18 |
| gpt-5.6-luna | 0.20 / 0.02 / 0.25 / 1.20 | 0.40 / 0.04 / 0.50 / 1.80 |
| gpt-5.5 | 5 / 0.50 / — / 30 (already right) | 10 / 1 / — / 45 |
| gpt-5.5-pro | 30 / (tracker's 3.00) / — / 180 | 60 / 6.00 (ASSUMED: page lists no cached price) / — / 270 |
| gpt-5.4 | 2.50 / 0.25 / — / 15 (already right) | 5 / 0.50 / — / 22.50 |
Sol note, quoted: "GPT-5.6 Sol's promotional pricing is available at least through November 21, 2026." The page lists NO regular price, so none is invented: Sol stays at the promotional price, and 2.7 adds a dashboard warning when Sol records dated after 2026-11-21 are in view. Put the quote and date in a code comment.
Long-context rates apply for both `.openai` and `.azure` providers. Rewrite the stale Astra comment that says Codex never exceeds 272K (VERIFIED false: 476 such requests in Sept).

Anthropic — https://platform.claude.com/docs/en/about-claude/pricing
- 1-hour cache write = 2× base input for EVERY Claude preset ("1-hour cache write | 2x base input price"): Fable/Mythos 20, Opus 4.5+/5 10, Opus 4/4.1 30, Sonnet 5 4, Sonnet 4.x 6, Haiku 4.5 2, Haiku 3.5 1.60, Haiku 3 0.60.
- Fable 5.1 and Mythos 5.1: cache hit 0.25 ("0.025x"). Fable 5 and Mythos 5: cache hit stays 1.00. Match `fable-5-1` / `mythos-5-1` (after the existing `.`→`-` normalisation) for the cheap rate; bare `fable` / `mythos` otherwise. "mythos" is not matched at all today → add it with Fable's rates.
- Dated Opus 4 ids (e.g. `claude-opus-4-20250514`) must hit the legacy 15 / 1.50 / 18.75 / 75 tier: treat `opus-4` followed by end-of-string or `-` + 8 digits as legacy. `opus-4-5`…`opus-4-8` and `opus-5` stay at 5 / 25.
- Haiku 3.5 (`haiku-3-5` or `3-5-haiku`): 0.80 / 0.08 / 1.00 / 4, checked BEFORE the Haiku 3 branch.
- No long-context tier for Claude: "Claude 4.6 and later models … include the full 1M token context window at standard pricing."

### 2.4 Fast mode (Codex on the ChatGPT plan only)
`fastModeMultiplier` is set only when `provider == .openai`: 2.5 for gpt-6-astra, gpt-5.6 (sol/terra/luna), gpt-5.5; 2.0 for gpt-5.4 (not mini/nano/pro). Source: learn.chatgpt.com/docs/agent-configuration/speed — "Fast mode consumes credits at 2.5x the Standard rate" (VERIFIED 2026-09-21 earlier this session). It stacks on top of long-context rates. Not applied to `.azure` (whether Azure honours `service_tier` is UNVERIFIED — see notes).

### 2.5 Codex scanner: read the tier, the parent, and cache writes
In `parseCodexLocalFile`:
- add `"thread_settings_applied"` to `codexLocalRelevantLinePatterns`; in `consume`, test for it BEFORE the `turn_context` test (these lines embed long instruction text that can contain other keywords). Read `service_tier` (`"priority"` → fast, `"default"` → standard, anything else → leave unchanged). It is a state change: each later `token_count` event gets the tier in force at that point; events before the first tier record in the file get `nil`.
  VERIFIED live: line shape `{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":…,"thread_settings":{…,"service_tier":"default",…}}}`; in a sampled day all 34 such lines carried the file's own thread id.
- session_meta: read `parent_thread_id` (VERIFIED present on sub-agent files, equal to the parent's `id`).
- `extractTokenUsage`: read `cache_write_input_tokens` (fallback `cache_creation_input_tokens`) into `cacheCreationInputTokens`, clamped so cached + cacheWrite ≤ input. VERIFIED live: it is a subset of `input_tokens` (totals 218.05M input ⊇ 206.54M cached + 11.21M cache-write); 33,746 Sept events have it non-zero and are priced as plain input today ($10 instead of $12.50).
Index: `CodexLocalUsageIndexedEvent` gains optional `speed` (key `"st"`); `CodexLocalUsageIndexedSession` gains optional `parentThreadID` (key `"pt"`) and `tierChanges: [(timestamp, speed)]` (key `"tc"`). Bump `CodexLocalUsageIndexStore.currentVersion` 2 → 3.
In `scanCodexLocalSessions`, before processing: build `[sessionID: session]` over ALL sessions (target or not). For an event whose `speed` is nil: if the session has a `parentThreadID`, use the parent's tier in force at the child's `metaTimestamp` (walk up at most 5 levels; the parent may itself inherit); otherwise `.unknown`. Write the resolved speed into the record's `usage.speed`.

### 2.6 Claude Code scanner: read the 1-hour split
`claudeCodeTokenUsage`: `cacheCreation1hInputTokens = usage.cache_creation.ephemeral_1h_input_tokens` (0 if absent), clamped to ≤ `cache_creation_input_tokens`; `speed = .standard`. VERIFIED live shape: `"cache_creation":{"ephemeral_1h_input_tokens":24850,"ephemeral_5m_input_tokens":0}`. Bump `ClaudeCodeUsageIndexStore.currentVersion` 3 → 4. `replacingOutputTokens` must carry both new fields through.
The Claude Azure gateway log (`~/.opus-gateway/usage.jsonl`) has no 1h/5m split (VERIFIED: fields are `cache_creation_tokens` only) → unchanged.

### 2.7 Surfacing, in the existing warnings list only (no new UI)
In `AzureUsageScanner.dashboard(from:…)`, over the records in the selected window:
- if any record has `speed == .unknown` and its pricing has a `fastModeMultiplier`: "N requests have no recorded speed setting and are priced at Standard; if all of them ran in Fast mode the estimate would be $X higher."
- if any gpt-5.6-sol record is dated after 2026-11-21: "GPT-5.6 Sol is priced at its promotional rate, which OpenAI guaranteed only through November 21, 2026 — check the current price."
`AzureUsageTokenTotals` does not change shape.

### 2.8 One-time re-read (migration)
Bump the three preference keys so each provider does one full re-read on next launch: `openAICodexForkReplayBackfillDone.v6`→`.v7`, `azureCodexForkReplayBackfillDone.v5`→`.v6`, `claudeCodeProjectRootBackfillDone.v1`→`.v2`. With Batch 1.2 this re-read REPLACES records for files on disk and KEEPS records for vanished files.

### 2.9 Tests
Expected values typed from the price pages above, never computed from the implementation's constants:
- 272,000 vs 272,001 input boundary for Astra (short vs long), incl. cached/cache-write/output components; mixed short+long totals.
- fast: Astra `.openai` fast = 2.5× standard; `.azure` fast = 1×; long + fast stack (e.g. 1M output tokens, 300K input → 75 × 2.5).
- Sol/Terra/Luna short prices; bare `gpt-5.6` = Sol.
- Claude: 1M one-hour write tokens on Fable 5.1 = $20, five-minute = $12.50, mixed; Fable 5.1 cached $0.25 vs Fable 5 $1.00; `claude-opus-4-20250514` legacy, `claude-opus-4-8` modern; Haiku 3.5.
- scanner: tier replay inside one file (default → priority mid-file); sub-agent inherits parent's tier at spawn; no parent + no tier → `.unknown`; `cache_write_input_tokens` lands in `cacheCreationInputTokens`; Claude 1h split parsed.
- decoding: an old cached `AzureTokenUsage` JSON without the new keys decodes (speed `.unknown`, 1h 0); an old `AzureModelPricing` JSON decodes.
- unknown-speed warning counts N correctly (input cardinality) and X = Σ(costIfFast − cost).

---

## Pre-mortem

First real action after shipping: operator installs the build and launches it. Trace: `start()` → `loadUsageCaches()` decodes three big JSON caches with the NEW `AzureTokenUsage` decoder → flags set from bumped preference keys → `refresh*Usage()` → `scan(since: nil)` → index load: version mismatch → empty index → every file re-parsed once (Codex index is 193 MB, 1,357 files; expect a slow first refresh) → `mergedPreservingVanishedFiles` → `usageCacheStore.save`.
Gates that can throw/block: (a) cache decode — a non-optional new key would throw and `load` would return nil → empty previous → vanished history lost. Guard: `decodeIfPresent` + the decoding test in 2.9. (b) index decode of old version — header check returns an empty index, fine. (c) second action (ordinary refresh) — same path, index warm.

Failure taxonomy:
1. Hand-maintained lists: the price branches in `defaultPricing`; the relevant-line patterns; the three preference keys; `CodingKeys` of the compact index structs (custom encode/decode — new keys must be added in BOTH directions). All listed above.
2. Live-state divergence: log shapes and vanished-file counts were probed on the live machine today (see ledger). Prices read from the live pages today.
3. Silent fallbacks: missing tier → `.unknown` (surfaced by the 2.7 warning, not silent); missing 1h split → 0 → 5-minute rate (old records from vanished files — stated in notes); unknown model → $0 (existing warning).
4. Deploy mechanics: index version bumps + preference-key bumps force the one-time re-read; ordering matters — Batch 1.2 must be in the same build, otherwise the re-read erases history. Rollback: operator backs up the cache folder before first launch (manual step below).
5. Manual operator steps: (i) before first launch of the new build, copy `~/Library/Application Support/CodexAccountTracker` to a backup folder; (ii) build + install as in memory `usage-tracker-astra-fix`.
6. Cross-component: `UsageHistory.swift:325`, `claudeCodeRowWins`, `AzureUsageProjectSessionAccumulator`, `ClaudeAzureTranscriptCorrelator`, `ClaudeDesktopChatStore`, `LMStudioConversationStore`, `OpencodeUsageStore`, `ClaudeAzureUsageStore` all construct or price `AzureTokenUsage` — defaults on the initialiser keep them compiling; none needs a behaviour change.
7. Uncounted drops: Batch 1 exists to remove one; 1.3 asserts merged cardinality. The failed-scan guard prevents an empty scan from wiping records. Unknown-speed requests are counted in the warning.
8. Coverage-narrowing: none. `since` is no longer used by the view model, which widens coverage. The Azure fast-mode exclusion is a pricing choice, flagged for the operator.

## Claims ledger
| Claim | Status | Evidence |
|---|---|---|
| Refresh cutoff = newest event across all files; events ≤ cutoff skipped | VERIFIED | ViewModel ≈1001–1042; Scanner ≈590, ≈770 |
| Codex scan already enumerates all files and caches parses by size+mtime | VERIFIED | Scanner `jsonlFileURLs()` call ≈58, index use ≈413–441 |
| Cost is computed at display time from record.model + usage (no stored cost per record) | VERIFIED | `dashboard(from:)` ≈111, `UsageHistory.swift:325` |
| 146,043 / 207,168 cached Claude records come from files no longer on disk | VERIFIED | python over live cache, 2026-09-21 |
| Full-rebuild path replaces the cached result | VERIFIED | ViewModel ≈405, ≈442, ≈483 |
| `thread_settings_applied.thread_settings.service_tier` = default/priority; lines belong to the file's own thread | VERIFIED (one sampled day, 34 lines) | live probe |
| Sub-agent `session_meta` has `parent_thread_id` = parent's `id` | VERIFIED | live probe |
| Codex `cache_write_input_tokens` is a subset of `input_tokens` | VERIFIED | live totals |
| Claude transcripts carry `cache_creation.ephemeral_1h_input_tokens` | VERIFIED | live probe |
| All prices in 2.3 | VERIFIED | primary pages, fetched 2026-09-21 |
| Fast = 2.5× (Astra/5.6/5.5), 2× (5.4) on ChatGPT plan | VERIFIED | learn.chatgpt.com speed doc (earlier this session) |
| gpt-5.5-pro long-context cached rate 6.00 | ASSUMED | page lists none |
| Azure Foundry long-context rates equal OpenAI's | ASSUMED | only short Global Standard parity was checked |
| Azure ignores / does not bill `service_tier: priority` | ASSUMED | unverified → no fast multiplier on `.azure` |
| Sol's price before the promotion started, and after 2026-11-21 | UNKNOWN | page lists neither |
| First full re-read completes in acceptable time with a cold 193 MB index | ASSUMED | not measured |
| `id` extraction is not confused by `session_id` appearing first in session_meta | VERIFIED | pattern is `"id":"` with leading quote; `"session_id":"` does not contain it |

## Class-kill guards
- Usage loss by cutoff → there is no cutoff any more; merge is by record id.
- History loss by rebuild → one merge rule used by every path + failed-scan guard + cardinality test.
- Price drift → tests hold independently typed expected prices with the source URL and date in a comment; Sol warning fires by date.
- Silent tier gaps → counted in a visible warning with the dollar effect.

## Notes for the operator (not in this plan)
- Records from transcript files Claude Code has already deleted (≈70% of Claude history) have no 1-hour split recorded; they stay priced at the 5-minute rate. Recent data is 99.5% one-hour writes, so that older history is probably under-priced. Option later: treat unknown-split Claude cache writes as 1-hour. Needs your call.
- Whether fast mode costs more on the Azure path is unverified.
- LM Studio Qwen reference price (review F06, last paragraph) not touched.

---

## Addendum after the Opus 5 review (2026-09-21, ~04:30)

Reviewer verdict: "fix first". Dry run on a copy of the live caches: all three caches decode with identical record counts (Claude 207,168 · OpenAI 81,362 · Azure 10,670). Claude and Azure merges were sound, but the OpenAI merge dropped 20,456 cached records (−$762) whose files STILL EXIST.

Root cause (traced by the planner, VERIFIED on live files): Codex rewrites its own rollout files. Example: a sub-agent file last modified 2026-08-17 19:31 now holds 87 token events, all from the 11:03:47 start-up burst, while the cache holds 743 records from that file spanning 11:03–19:31 with event indexes up to 1034. 17,777 cached OpenAI records have an event index beyond what their file now contains (436 files, 15,421 of them from August 2026). So "the file still exists" does NOT mean a cached record can be re-derived.

Changes made (commit after 99a55ce):
1. Merge rule 1.2 is now: a refresh adds and updates, and NEVER drops a cached record (the `fileExists` condition is removed). This also closes the reviewer's finding 2 (a partial scan failure erased 61,115 Claude records in simulation).
   Cost accepted: a genuinely wrong old record is never shed automatically — the same as the tracker's behaviour before this branch. F09 still improves, because records a fresh scan DOES reproduce are updated.
2. Haiku 3 one-hour cache write 0.60 → 0.50 (2 × $0.25; planner's arithmetic slip) + added to the 2×-rule test.
3. Cache files are no longer pretty-printed (reviewer finding 6: smaller file, faster save; no behaviour change).

Ledger corrections: the "33,746 Sept events with cache writes" are almost all on the Azure path (reviewer counted 6,088 of 6,092 over all session files), so item 2.5's cache-write pricing raises the Codex AZURE estimate (≈ $1,975 → $2,062), not the OpenAI one. The "99.5% of cache writes are one-hour" note held for the last 40 transcripts only; over all transcripts on disk the one-hour share is ≈ 48%.

Left open (reviewer findings not fixed here): #4 Codex record ids collide when two files share a session id (1,460 collisions in an Azure scan; pre-existing) · #5 about a third of Codex requests have no recorded speed setting (logs older than the tier record) — the warning states the dollar band · #6 merge/save/dashboard still run on the main thread (≈ 8 s freeze per Claude refresh; first launch re-read ≈ 4–5 min in the background) · #7 one-hour write rate is not scaled inside the long-context tier (no preset has both today).
