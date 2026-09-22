**Codex Account Usage Tracker — full review, 21 September 2026**

**Decision: REVISE. The tracker is useful, but its quota labels, usage completeness and cost estimates are not consistently reliable.** Two issues deserve first priority: refreshes permanently missing valid usage, and unsynchronized connection state. The remaining findings affect specific account, pricing, history, persistence and UI paths.

Three review agents worked alongside the primary reviewer. We reviewed the current checkout on main at `9c389b0efc448a5bd21c3328d07efd1ecb6902bb`, including the existing uncommitted bar-chart change. Scope: all 27 application Swift files (10,102 lines), all 10 test files (1,645 lines), package/build scripts, CI, README, all three design/implementation documents, and icon format/dimension checks. We also inspected saved usage data, current transcripts, the current quota response and the running interface.

This was a review, not an implementation. No repository source, preferences, live caches, accounts, credentials or server processes were changed. No app restart, installation, commit or deployment occurred. New verification scripts and this report were created only under `/private/tmp`; no cleanup/deletion commands were run.

**How to read the evidence**

- VERIFIED — live: present in the data inspected during this review.
- VERIFIED — reproduction: reproduced with current source logic in an isolated Swift interpreter harness.
- VERIFIED — source: a concrete failure path is established in code; its production occurrence was not forced.
- UNKNOWN: insufficient evidence to assert that a suspected problem actually occurred.
- P1 means fix first because the defect threatens core completeness or runtime stability. P2 means a real defect under a stated condition. P3 is a smaller usability defect. No critical/P0 finding was established.
- Dollar differences below are calculated API-reference estimates. They are not actual charges for Codex or Claude subscriptions, and current published rates do not establish every historical rate.

**Confirmed findings**

**F01 · P1 · Normal refresh can permanently miss valid usage and corrections**

VERIFIED — source and live. The refresh starts after the newest event across all files. Both scanners then discard events at or before that timestamp, even from a changed file. A late-arriving older request, same-time append or correction can therefore remain missing forever.

One completed Claude request containing **261,432 tokens** exists in both its current transcript and the v3 index but is absent from the saved dashboard cache. It is dated `2026-08-10T09:02:05.144Z`; its source was modified before the September 20 cache save. The current cutoff is already in September, so another ordinary refresh cannot recover it. The request identity begins `msg_011Cdto9u5HooEk9n9gYf29c`; the source session is `80f04f16-0de1-4bfd-9916-c8d6cc360d06`, line 644.

Claude estimation also filters before collecting all content blocks: a later small chunk can replace the earlier whole-request estimate with a smaller partial estimate.

Evidence: [refresh cutoff](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountTrackerViewModel.swift:1001), [Codex exclusion](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AzureUsageScanner.swift:590), [Claude exclusion and grouping](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AzureUsageScanner.swift:769).

Fix: reconcile complete requests from changed files using stable identities; use event timestamps for display filtering, not as proof that all older data has already been collected. Guard with tests for out-of-order files, equal timestamps, corrected final rows and one response spanning multiple refreshes.

**F02 · P1 · Connection state is shared across threads without protection**

VERIFIED — source; no crash was deliberately triggered. The RPC client is declared `@unchecked Sendable`, but request IDs, socket state and the pending-response dictionary are neither actor-isolated nor locked. Async request code mutates them outside the main actor while receive, timeout and disconnect paths also mutate them. Polling and notification-triggered reads can overlap.

Impact: possible crashes, lost requests or incorrect completion of requests. This is a verified unsafe access pattern, not proof that a particular past crash had this cause.

Evidence: [mutable RPC state](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/CodexRPCClient.swift:31), [request registration and timeout](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/CodexRPCClient.swift:98), [response removal](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/CodexRPCClient.swift:197).

Fix: put the entire connection lifecycle and request bookkeeping on one actor/executor. Guard with overlapping requests, notifications, timeouts and disconnects under Thread Sanitizer. Review server restart state against its main-queue callbacks at the same time.

**F03 · P2 · Weekly and 30-day quotas are labeled “5-hour”**

VERIFIED — live and source. The UI always titles the primary window “5-hour,” regardless of its actual duration. The current quota response had a primary duration of **10,080 minutes**, with **73% used**, and no secondary window. Saved free accounts also include **43,200-minute** primary windows. These are weekly/30-day windows, respectively.

Evidence: [hardcoded card labels](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/ContentView.swift:276), [hardcoded report labels](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountTrackerViewModel.swift:689).

Fix: label/place each quota according to its reported duration; display unknown durations honestly. Test five-hour, weekly, 30-day, swapped and primary-only responses.

**F04 · P2 · A quota window removed by a full server response remains visible**

VERIFIED — live and reproduction. Applying a snapshot changes only non-nil windows. A full response with `secondary: null` therefore preserves a previously saved secondary quota. The current response had no secondary, but the latest saved account retained a weekly secondary at zero used. Together with F03, real weekly usage can appear under “5-hour” while the stale “Weekly” card looks completely available.

Evidence: [snapshot application](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountRecord.swift:46).

Fix: distinguish full reads from sparse notifications. A full read replaces the complete quota state; a sparse notification merges only provided fields or triggers a full read. Test two windows → one window → no windows, plus sparse updates that must retain unaffected fields.

**F05 · P2 · Other quota buckets can overwrite the core Codex quota**

VERIFIED — source, local protocol and reproduction; a live non-core notification was not observed. The parser accepts a direct/legacy quota before checking `rateLimitsByLimitId.codex` and discards bucket identity. A fixture with a 99%-used non-core bucket and a 73%-used explicitly keyed Codex bucket selected 99%. A non-core notification was accepted too.

Installed Codex protocol metadata distinguishes these buckets and describes notifications as sparse updates. The installed ChatGPT client selects the explicitly keyed Codex bucket first and filters its legacy fallback by identity. Local evidence: [ChatGPT app bundle archive](/Applications/ChatGPT.app/Contents/Resources/app.asar), embedded `webview/assets/app-initial-a498f911edeb.js`; locate the selector containing `rateLimitsByLimitId?.codex`. This is a reference to the installed snapshot.

Evidence: [selection order](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/CodexRPCClient.swift:227), [notification parsing](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/CodexRPCClient.swift:214), [persistence of accepted snapshot](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountTrackerViewModel.swift:1388).

Fix: retain bucket identity, prefer the explicit core bucket and reject/route other buckets. Test conflicting legacy/core data, non-core notifications, compatible identity-free legacy data and sparse core updates.

**F06 · P2 · Several price presets differ from current published prices**

VERIFIED — current source and official rate tables. Values are USD per million tokens; I/C/O means uncached input, cached input and output.

| Model | Tracker I/C/O | Current Standard short-context reference I/C/O | Source |
|---|---|---|---|
| GPT-5.6 Sol | 5 / 0.50 / 30 | 4 / 0.40 / 20 | [OpenAI pricing](https://developers.openai.com/api/docs/pricing) |
| GPT-5.6 Terra | 2.50 / 0.25 / 15 | 2 / 0.20 / 12 | [OpenAI pricing](https://developers.openai.com/api/docs/pricing) |
| GPT-5.6 Luna | 1 / 0.10 / 6 | 0.20 / 0.02 / 1.20 | [OpenAI pricing](https://developers.openai.com/api/docs/pricing) |
| Claude Fable 5.1 | 10 / 1 / 50 | 10 / 0.25 / 50 | [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing) |

All four models occur in current cached usage. For Fable 5.1, the cache contains **542,066,783 cached tokens** across **1,895 records**. Applying today's published reference gives a **calculated $406.55 reduction** in the cached-input estimate: `542,066,783 / 1,000,000 × (1 − 0.25)`. Historical effective dates were not established, so this is not a claim of a $406.55 historical billing error.

Additional model matching defects reproduced: dated Opus 4 receives the modern $5/$25 input/output rates instead of the legacy $15/$75 rates; Haiku 3.5 receives $1/$5 instead of $0.80/$4. Those model names were absent from the inspected cache. [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing).

The LM Qwen3.6 35B savings reference also uses $0.14/$1 input/output while the code's declared OpenRouter reference currently advertises a starting $0.05/$0.70. OpenRouter is the API marketplace source here, not a universal manufacturer price; its listed providers differ. This reference needs a named provider/basis and date. [OpenRouter pricing](https://openrouter.ai/qwen/qwen3.6-35b-a3b).

Evidence: [Fable branch](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AzureUsageModels.swift:421), [GPT-5.6 branches](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AzureUsageModels.swift:537).

Fix: exact family/version matching and dated, sourced pricing presets; state whether history uses historical or current-reference rates. Tests must compare against independently sourced rates rather than repeat implementation constants.

**F07 · P2 · Long-context Astra usage receives the cheaper price tier**

VERIFIED — live data and source. The code assumes Codex requests never exceed the threshold. The OpenAI cache contains **64 Astra records** above **272,000 input tokens**, reaching **335,655**. OpenAI specifies doubled input/cache rates and 1.5× output rates above that threshold. [Astra pricing rules](https://developers.openai.com/api/docs/models/gpt-6-astra).

These records contain 155,945 uncached input, 19,118,592 cached input and 28,170 output tokens. The calculated Standard-reference estimate is **$22.09 currently versus $43.47 with the size tier**, a **$21.38 underestimate**. Calculation: short=`155945×10/1e6 + 19118592×1/1e6 + 28170×50/1e6`; long uses 20, 2 and 75 respectively. This compares reference estimates, not subscription bills.

Evidence: [fixed Astra pricing](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AzureUsageModels.swift:519), [cost calculation](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AzureUsageModels.swift:299).

Fix: select the rate per request before aggregation. Test the 272,000/272,001 boundary, cache/output components and mixed short/long requests.

**F08 · P2 · “All time” cannot backfill an earlier partial scan**

VERIFIED — source. After a first OpenAI scan in Last 24 hours, selecting All time and refreshing still uses the newest cached event as the cutoff. Historical records remain excluded despite being available in the index. Claude is vulnerable with a partial cache too, although its first-install Foundry backfill normally forces a full scan.

Evidence: [nil window returns the incremental cutoff](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountTrackerViewModel.swift:1029).

Fix: track which time intervals have actually been scanned, separately from the earliest/latest event returned, and backfill missing coverage. Test fresh limited scan → All time and widening an incomplete history.

**F09 · P2 · The output-estimator upgrade leaves old placeholder counts untouched**

VERIFIED — source and live. The Claude index version changes for output estimation, but the dashboard result cache has no matching derivation migration. Ordinary refresh still excludes historical rows.

The current index contains **209 incomplete requests** with at least 1,000 recorded characters each whose cached output remains five tokens or fewer: **552 cached output tokens for 847,567 characters**. Even the estimator's minimum ratio implies approximately **127,136 estimated output tokens**. That is a discrepancy against the app's own estimator, not a measurement of actual output.

Evidence: [index version](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/ClaudeCodeUsageIndexStore.swift:4), [rebuild decisions](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountTrackerViewModel.swift:463).

Fix: version derived results as well as parsed indexes and reprocess affected history. Test upgrading a pre-estimator result cache after older migration flags are already complete.

**F10 · P2 · Copied transcript blocks inflate output estimation**

VERIFIED — source and live input. Usage is deduplicated, but character counts are summed for every row with a shared request identity. The index discards the row UUID needed to recognize identical copies.

A real request has 646 thinking characters and 105 text characters. The same two blocks, with matching UUIDs/timestamps, appear three times in one transcript and twice in another. Estimation receives **2,253 characters instead of 751**; the cross-file maximum retains the inflated count. The current cache still holds an old three-token placeholder for this example, so the displayed estimate was not claimed to be tripled already. Repeated completed blocks also distort calibration.

Evidence: [character accumulation](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AzureUsageScanner.swift:788), [index row fields](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/ClaudeCodeUsageIndexStore.swift:69).

Fix: preserve stable content-row identity, remove exact copies and then sum distinct blocks. Test repeated UUIDs, copied files and genuinely different blocks from one response.

**F11 · P2 · Refresh removes the warning that token counts are estimated**

VERIFIED — source and current cache. The merged summary does not carry `incompleteOutputEvents` or `estimatedOutputTokens`. The dashboard copies that summary and the UI hides its disclosure when the count is zero, even though estimated usage remains. Both fields are zero in the inspected Claude cache. Full-scan summaries also are not recomputed for the chosen window or gateway exclusions.

Evidence: [summary merge](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountTrackerViewModel.swift:1049), [dashboard summary copy](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AzureUsageScanner.swift:102), [disclosure condition](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/ContentView.swift:1661).

Fix: store estimate provenance per record and derive disclosure from the effective, filtered records. Test no-op and measured-only incremental refreshes, window changes and gateway exclusions.

**F12 · P2 · Charts and headline totals drift apart while the app is idle**

VERIFIED — source and reproduction. The display clock advances chart cutoffs every minute without rebuilding the dashboard totals. A 100-token event at 11:00:30 appears in Last 1h at 12:00; at 12:01 the chart excludes it while the headline still includes it.

Evidence: [clock](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountTrackerViewModel.swift:1063), [chart dates](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/ContentView.swift:653).

Fix: use the same effective timestamp and record selection for both, or update both together. Test clock advancement across a boundary without rescanning logs.

**F13 · P2 · Charts merge unrelated projects with the same folder name**

VERIFIED — reproduction and data. Tables group by full path; chart series and filters use only the display name. `/project-a/backend` and `/project-b/backend` produce two table groups but one chart group. The Claude cache contains **29 distinct paths named backend**, nine named src and nine named frontend. Filtering cannot separate them.

Evidence: [chart identity](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/UsageHistory.swift:321), [project filter](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/UsageHistory.swift:435), [name helper](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AzureUsageScanner.swift:221).

Fix: retain full-path identity separately from a readable label. Test equal basenames in different paths and independent filtering.

**F14 · P2 · Hiding every chart series also hides the way to restore them**

VERIFIED — source. The empty-visible-series branch says to select a legend item, but the legend is rendered only when at least one series is visible. Hidden IDs survive collapse/reopen and ordinary metric changes.

Evidence: [conditional legend](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/UsageHistoryChartView.swift:88).

Fix: always show the legend when series exist, or add Show all. Test hide-all → restore-one without replacing the dataset/grouping.

**F15 · P2 · Five-minute history misplaces usage in the repeated daylight-saving hour**

VERIFIED — Foundation reproduction using Europe/Sofia. On 25 October 2026, events at 00:31Z and 01:31Z both map to 00:30Z. A range beginning at 01:30Z can place its event outside the selected range. Rebuilding a date from local hour/minute fields loses which repeated hour it belongs to.

Evidence: [bucket rounding](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/UsageHistory.swift:99).

Fix: round within the actual absolute hour interval. Test both repeated hours and a range beginning in the second; existing spring/hourly coverage does not catch this.

**F16 · P2 · Canceled connection work can turn monitoring back on**

VERIFIED — source interleaving. Disconnect schedules a delayed reconnect. Changing the endpoint cancels that task, but `try?` swallows the sleep cancellation and the task still calls start, which sets monitoring intent back to true. Stop Live during account-switch recovery has a similar continuation-after-stop path.

Evidence: [reconnect sleep](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountTrackerViewModel.swift:1275), [auth recovery continuation](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountTrackerViewModel.swift:1599).

Fix: retain/cancel startup and recovery tasks, and check cancellation plus a connection-generation token after every suspension. Test stopping during sleep/recovery and changing endpoints mid-connect.

**F17 · P2 · Stop Server can automatically restart the server**

VERIFIED — source. The button stops the process while leaving live-monitor intent enabled. The resulting socket disconnect schedules a reconnect; the private-server path starts it again.

Evidence: [button](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/ContentView.swift:107), [stop implementation](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountTrackerViewModel.swift:1330).

Fix: an intentional stop must revoke automatic monitoring/restart intent first. Test that advancing past reconnect delay does not create a new connection or process.

**F18 · P2 · Authentication recovery can terminate a server owned by another app**

VERIFIED — source. Invalid-token recovery restarts the configured endpoint without the ownership check used by normal startup. Restart uses `pkill -f` on the endpoint command, so a configured shared server can be stopped and replaced even when the tracker only connected to it.

Evidence: [one-shot recovery](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountTrackerViewModel.swift:1424), [live recovery](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountTrackerViewModel.swift:1445), [process matching](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/CodexServerManager.swift:111).

Fix: restart only a process the tracker owns; report authentication failure for connect-only endpoints. Prefer tracked process identity. Test a shared endpoint returning an invalid-token error with no process-control calls allowed.

**F19 · P2 · An account-file read failure can lead to overwriting saved accounts**

VERIFIED — source. A missing file and a failed decode both return an empty account list. If one record is malformed, startup loses access to every record, then normal automatic refresh can overwrite the file with only the active account. Saved accounts and manual subscription dates would be lost.

Evidence: [load failure becomes empty](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountStore.swift:14), [subsequent save](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountTrackerViewModel.swift:1358).

Fix: distinguish absent storage from failed loading, expose the error and prevent destructive replacement of an unsuccessfully loaded store. Test one malformed record and transient read failure while asserting original bytes remain intact.

**F20 · P2 · Failed saves are presented as successful**

VERIFIED — source. Account saves catch errors and return no status; callers can announce Saved or accept an edit/deletion even though nothing persisted. Usage-cache saves similarly only print errors while refresh marks the scan complete and advances migration flags.

Evidence: [account save](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountStore.swift:28), [success status](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountTrackerViewModel.swift:1144), [cache save](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AzureUsageCacheStore.swift:29).

Fix: propagate persistence results, show failures and distinguish in-memory updates from saved state. Test injected permission/disk-write failure and successful retry without losing edits or migration work.

**F21 · P2 · Desktop chat records invent a precise model and token split**

VERIFIED — source and presence of daily records. The Desktop source supplies a daily token total. The tracker assigns every total to Opus 4.7, estimates 90% input/10% output, assumes no cache, and merges it into ordinary Claude model/token totals without record-level estimate attribution. The inspected Desktop cache contains **68 daily entries and 12,557,483 total tokens**. These totals do not prove the hardcoded model or split.

Evidence: [synthetic record construction](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/ClaudeDesktopChatStore.swift:40), [dashboard append](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountTrackerViewModel.swift:887).

Fix: preserve the observed daily total and label unknown/estimated dimensions explicitly; do not present the model as measured. Test that total-only source data cannot silently become exact model/input/output/cache counts. Whether Desktop totals overlap separate transcripts remains UNKNOWN.

**F22 · P2 · Desktop daily timestamps break short windows and chart parity**

VERIFIED — source. Each whole daily total is timestamped at local 23:59:59. Today's record is therefore in the future. The dashboard only checks the lower time bound and includes it in Last 1h, while the chart also checks the upper bound and excludes it until the day ends. Just after midnight, yesterday's entire day can be counted as recent hourly usage.

Evidence: [end-of-day timestamp](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/ClaudeDesktopChatStore.swift:116), [dashboard lower-bound filter](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AzureUsageScanner.swift:95), [chart bounds](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/UsageHistory.swift:318).

Fix: represent daily aggregates as intervals and disclose their available granularity. Use a common inclusion policy for totals/charts; an exact hourly split cannot be recovered from a daily total. Test midday, midnight and Last 1h/24h behavior.

**F23 · P2 · Breakdown tables silently omit data beyond fixed row limits**

VERIFIED — source and cached data. Model/endpoint tables show eight rows; projects and nested sessions show twelve, with no Show more, remainder or truncation notice. In the inspected OpenAI All time data, four model rows containing **227,976,519 tokens** fall beyond the model display limit. Totals still include them; they are hidden, not missing from the total.

Evidence: [model/endpoint limit](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/ContentView.swift:1196), [project limit](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/ContentView.swift:1369), [nested limits](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/ContentView.swift:1458).

Fix: pagination/Show all or an explicit remainder, including sessions. Test nine models, thirteen projects and thirteen sessions; users must be able to reconcile displayed rows with the total. The dormant text-report helper repeats these limits.

**F24 · P2 · Custom date filtering includes a hidden time of day**

VERIFIED — source. Custom dates initialize as current time minus a number of days, but the picker displays only the date. Selecting Custom uses that full timestamp unchanged, so the first part of the shown date is excluded. A displayed start date is therefore insufficient to know the actual filter boundary.

Evidence: [default custom timestamp](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountTrackerViewModel.swift:129), [date-only picker](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/ContentView.swift:968), [unmodified cutoff](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AzureUsageModels.swift:84).

Fix: normalize date-only selections to local start of day, or expose the time explicitly. Test selecting Custom without editing its default and events before/after the hidden time.

**F25 · P3 · Table values are clipped at ordinary window widths**

VERIFIED — running screenshot and layout code. Two wide fixed-column tables sit side by side. In the inspected running window, input/cached numbers and model/rate names were visibly abbreviated with ellipses, making exact figures hard to audit. Numeric text selection does not make the visible table readable.

Evidence: [side-by-side tables](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/ContentView.swift:1018), [fixed widths](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/ContentView.swift:1133), [single-line numeric cells](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/ContentView.swift:1252).

Fix: adaptive stacking or horizontal scrolling with sufficient numeric width/full-value help. Visually test long names and billion-token values at the supported minimum window size.

**Dormant feature defect — do not confuse it with the active panels**

The API billing response decoder combines `.convertFromSnakeCase` with explicit snake-case CodingKeys. A populated response reproduced nil input/output/cache/request fields and project/key IDs, subsequently mapped to zero/unknown. Cost amounts survive, attribution does not. Evidence: [decoder](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/OpenAIAPIBillingClient.swift:139), [usage keys](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/OpenAIAPIBillingClient.swift:216), [cost keys](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/OpenAIAPIBillingClient.swift:244). Fix the coding strategy and test real-shaped usage/cost responses before exposing billing. Billing refresh/admin-key editing have no current UI callers; Keychain error handling and billing cache/account scope also need validation before enabling them.

**Unresolved questions and intentional limitations**

- **Retained historical cache is not proven false usage.** An identity-aware read of 1,357 current Claude JSONL files found 145,370 cached identities, representing 17,296,398,899 cached tokens, absent from current transcripts. This proves retained history that cannot currently be verified against those files. It does not prove duplication or that the usage never occurred. Decide and expose an archive/retention policy before pruning anything. No data was deleted in this review.
- **Gateway exclusions are at session level.** Two matching gateway requests can classify an entire transcript session; all its records are then removed from Claude Code. A resumed session mixing native/gateway use would lose native records. Current correlation excludes 16,636 records across 73 sessions; 2,203 lack an exact gateway twin. Their actual provider and any lost-token amount remain UNKNOWN. Use request-level provenance/deduplication and test mixed sessions and weak fingerprint collisions. Evidence: [classification](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/ClaudeAzureTranscriptCorrelator.swift:125), [whole-session exclusion](/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/AccountTrackerViewModel.swift:869).
- **Account switching:** identity and quota are fetched separately, and a queued notification is applied to the account returned by a later read. A controlled protocol test is needed to prove reachable wrong-account ordering. No wrong-account write was observed or intentionally triggered.
- **Inferred resets:** saved quotas are deliberately reset locally to 100% available and future reset timestamps are projected without a fresh server response. This is an estimate of availability, not live proof. The UI does not mark it inferred; README still incorrectly says the original reset timestamp is retained. Preserve the raw observation and distinguish inference if this policy remains desired.
- **Unavailable-source scans:** scanner results do not consistently distinguish missing/failed/partial reads from a successful empty dataset. Rebuilds/full refreshes can replace good caches and finish migration flags after a failure. Fault-injected tests are needed before asserting the actual extent of data loss; none were run against live data.
- **Gateway token convention:** all 22,286 inspected log lines omit native `input_uncached`, but their totals agreed with current reconstruction and call IDs were unique. The fallback cannot mathematically distinguish every inclusive/exclusive prompt convention; an explicit zero is also not preferred. This is an unproven-format edge, not an observed current token mismatch.
- **Known source limits:** gateway history begins when logging started; generic LM Studio server logs are intentionally unsupported. LM Studio chat files plus opencode are supported. Gateway lifetime headline counts versus window-filtered table counts are explicitly documented behavior. Unknown startup models remain unknown; later model context does not prove earlier identity.
- **Pricing scope:** exact historical discounts, fast/priority service, regional premiums, cache TTL and all provider-specific billing adjustments were not established. The app's fixed reference rates cannot be treated as invoices.
- **Lifecycle gaps:** auth-file disappearance/throttling and opening another app window while work is running need controlled tests. Each new window can call the shared model's start path again. No associated leak or corruption was reproduced.
- **Documentation:** the three plans are historical and contain superseded details about LM pricing and gateway attribution. The gateway plan's claim that stopping logging yields an empty panel is wrong when the existing usage log remains. Treat it as history, not a current rollback runbook. Packaging scripts contain explicit removal commands and were reviewed only, never executed.

**Coverage and verification**

| Area | Files reviewed | Work performed |
|---|---|---|
| App/UI/preferences | CodexAccountTrackerApp, ContentView, SettingsView, AppPreferences, UsageHistoryChartView | Startup wiring, all panels/controls, date/collapse/filter state, account editing/deletion, visible layout, dirty chart change |
| State/composition | AccountTrackerViewModel | All refresh, merge, migration, cache, source-combination, correlation, clock, report, account and server paths |
| Accounts/security/processes | AccountRecord, AccountStore, KeychainSecretStore, CodexRPCClient, CodexServerManager, ManagedServerRestartPolicy | Quota contracts, persistence failures, resets, requests, notifications, cancellation, ownership, reconnect/backoff and auth changes |
| Ingestion/indexing | AzureUsageScanner, AzureUsageCacheStore, CodexLocalUsageIndexStore, ClaudeCodeUsageIndexStore | Provider eligibility, dated discovery, fingerprints, migrations, parsing, deduplication/replay, cutoff behavior, identity and metadata |
| Claude adapters | ClaudeAzureUsageStore, ClaudeAzureTranscriptCorrelator, ClaudeDesktopChatStore, ClaudeCodeOutputEstimator | Token conventions, identities, gateway exclusion/project attribution, daily aggregates, estimation and copied content |
| Models/history/local usage | AzureUsageModels, UsageHistory, LMStudioConversationStore, OpencodeUsageStore | Arithmetic/prices, grouping, time boundaries/DST, all supported mappings, SQLite reading, model/timestamp/step identities |
| Dormant billing | OpenAIAPIBillingClient, OpenAIAPIBillingModels, OpenAIAPIBillingCacheStore | Response decoding, pagination/grouping, cache and reachability |
| Tests/tooling/docs/assets | All 10 test files; Package.swift; both scripts; .github/workflows/build.yml; .gitignore; README; all three docs; icon files | Test gaps, build/release paths, historical intent, artifact formats/dimensions |

**73 existing focused tests passed, zero failures**, run using copied current source in an isolated Swift interpreter harness. Counts: pricing 17, history axis 9, history builder 14, estimator 11, restart policy 7, opencode 8, LM parser 7. The harness copies relevant source logic, replaces the test module import and supplies limited non-mutating dependencies; this is not a full application build or full SwiftPM suite. One UserDefaults-writing test, the deleting LM scan test, and the filesystem scanner suite were not executed. All test source was reviewed. Passing price tests merely confirms consistency with their expected constants; it does not validate those constants against today's official prices.

Separate current-source reproductions confirmed billing decoding, project-name collision, rolling-window drift, repeated-hour buckets, model aliases, absent-window retention and wrong-bucket selection. Read-only metadata checks found six LM conversation files with thirteen generations and no duplicate step identities; opencode contained 844 positive-usage LM messages without duplicate usage signatures. Its normalization was also checked against the [upstream implementation](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/session/session.ts).

The current Claude transcript audit read approximately 1.23 GB without printing conversation content. Counts from different caches/logs were captured at different times while the user's apps remained running; they are separate snapshots, not an atomic whole-system measurement. Of 133 initially unmatched current Claude identities, 132 postdated the cache and were correctly excluded from defect claims.

The running UI was inspected read-only, but its installed binary was not proven byte-identical to this checkout. Interactive stop/restart/auth flows were intentionally not exercised. No crash reproduction, Thread Sanitizer run, full release build, end-to-end lifecycle suite, packaging or installation was performed. Process inventory via `ps` was sandbox-blocked; the running app was located through the permitted UI tool instead.

Key missing regression coverage: account/RPC/persistence integration, Claude scanner-to-dashboard behavior, late/corrected events, partial-to-All-time coverage, output-estimator migration, copied content UUIDs, gateway correlation, Desktop daily integration, failed/partial scans and chart UI state. CI currently builds release but does not execute tests.

Review artifacts: [safe test harness](/private/tmp/tracker-safe-tests-20260921.swift), [pricing/history reproductions](/private/tmp/tracker-pricing-history-audit-v2-20260921.swift), [account parsing reproductions](/private/tmp/tracker-account-pure-repro-20260921.swift). These were left in place to respect the deletion rule.

**Recommended repair order**

1. Correct record reconciliation and coverage/migrations; add regression cases before rebuilding any real cache.
2. Isolate RPC/server lifecycle state and make stop/cancellation/ownership reliable.
3. Fix quota duration labels, bucket identity and full-versus-sparse update handling.
4. Correct/version pricing and estimate provenance, then make chart/table/time selection agree.
5. Harden persistence failures and finish UI/docs/dormant-feature fixes.

Preserve existing cached history during the repair. Missing raw files are not authorization or evidence to erase historical usage. No fixes were implemented as part of this review.

**Sources:**

- [OpenAI API pricing — current Standard model prices](https://developers.openai.com/api/docs/pricing)
- [GPT-6 Astra — request-size pricing rules](https://developers.openai.com/api/docs/models/gpt-6-astra)
- [Anthropic pricing — current and legacy Claude rates](https://platform.claude.com/docs/en/about-claude/pricing)
- [OpenRouter Qwen3.6 35B — marketplace reference and provider prices](https://openrouter.ai/qwen/qwen3.6-35b-a3b)
- [Opencode upstream — token normalization implementation](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/session/session.ts)
