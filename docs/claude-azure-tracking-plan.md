I have verified everything against the real source. Line numbers, signatures, switch sites, the shared `dashboard()` summary behavior (finding 3 confirmed at `AzureUsageScanner.swift:92-96` + `ContentView.swift:1427`), the grouping key (`:108`), and the initializer shapes all check out. Here is the final corrected plan.

---

# Implementation Plan — "Claude Azure" per-account usage view (FINAL)

All line numbers below were re-verified against the live files on this machine (litellm 1.90.3 at `~/opus-gateway/venv`; tracker at `/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker`). Every review finding is incorporated. Findings 1–2 (token/cache correctness) are resolved by a **convention-independent** callback+store design that is correct whether litellm's `prompt_tokens` is cache-inclusive or cache-exclusive, so it does not depend on a fact we cannot verify without a live request. Findings 3–7 are resolved as noted inline.

## Resolution of every review finding
- **F1 (cache-token shape) — FIXED.** The callback probes *all three* shapes: OpenAI-style `usage.prompt_tokens_details.cached_tokens`, Anthropic-style **public** `usage.cache_read_input_tokens` / `cache_creation_input_tokens`, and the private `_cache_read_input_tokens` / `_cache_creation_input_tokens`, plus dict-key forms.
- **F2 (cache-inclusive vs exclusive `prompt_tokens`) — FIXED without needing to know the truth.** The callback also captures Anthropic native `usage.input_tokens` (the cache-*exclusive* prompt count) as `input_uncached` when present. The Swift store reconstructs a guaranteed cache-inclusive `inputTokens` such that `uncachedInputTokens` can never clamp to 0 (formula in §2). The verification step still asserts the invariant on the first real line as a cross-check.
- **F3 (windowed vs lifetime headline) — ACKNOWLEDGED + DOCUMENTED.** Confirmed: `AzureUsageScanner.dashboard(...)` copies `result.summary` wholesale and only recomputes `eventsCounted`/`earliest`/`latest` (`AzureUsageScanner.swift:92-96`); the headline stat renders `summary.azureSessions` = `providerSessions` (`ContentView.swift:1427`), which is **lifetime**. The per-account "By account" table's request count is `group.totals.eventCount`, which **is** windowed (`ContentView.swift:1040`, built from window-filtered records). The store mirrors the lmStudio template (`providerSessions += 1` per request), so the headline "Claude Azure requests" is a **lifetime** counter — identical behavior to every other provider, not a new bug. The authoritative per-account windowed numbers the user asked for are the table rows. This is stated in the subtitle and Limitations.
- **F4 (model/deployment split) — FIXED.** Both the callback and the store strip a leading `anthropic/` from the model string, so `model`/`deployment` are always the stable literal `claude-opus-4-8` → exactly one row per account.
- **F5 (sync IO on event loop) — ACCEPTED, NOTED.** The single `os.write` of a sub-4 KB line runs post-response; it does not stall the client. Offloading to a thread is unnecessary complexity at personal scale. Noted only.
- **F6 (streaming double-log) — TEST ADDED.** §7 now asserts **exactly one** new line after **one** streamed request.
- **F7 (rollback wording) — FIXED.** §9 now says precisely: 4 edited files reverted + 1 new file deleted, and locates the cache file by globbing.

---

## 1. Gateway component

### 1a. New file: `~/opus-gateway/custom_callbacks.py`

Registration mechanism verified: `config.yaml` `litellm_settings.callbacks` → `proxy_server.py:4270` → `initialize_callbacks_on_proxy` → unknown dotted string → `get_instance_fn("custom_callbacks.usage_account_logger", config_file_path)` splits module `custom_callbacks` + attr `usage_account_logger` and loads `custom_callbacks.py` from the config dir. `run.sh` does `cd "$HOME/opus-gateway"` and passes `--config config.yaml`, so it resolves to `~/opus-gateway/custom_callbacks.py`. **No `run.sh` change needed.** `CustomLogger.__init__` has all-default args, so the instance constructs cleanly at import (no boot crash).

Full contents:

```python
# ~/opus-gateway/custom_callbacks.py
# Crash-proof LiteLLM success callback: append one JSON line per request to
# ~/.opus-gateway/usage.jsonl, tagged with the serving Azure account.
#
# HARD RULE: never raise on import or inside a hook. A raise here can crash-loop
# the launchd-managed gateway or stall requests. Everything is wrapped; logging
# failures are swallowed (best-effort only). Only stdlib + the same CustomLogger
# litellm already imports are used, so import can only fail if litellm itself is
# broken (in which case the gateway is already down).

import json
import os
import time

from litellm.integrations.custom_logger import CustomLogger  # litellm's own loader uses this same import

_USAGE_FILE = os.path.join(os.path.expanduser("~"), ".opus-gateway", "usage.jsonl")

# zelen's Azure host has NO "zelen" substring — match the literal resource host.
# None of these is a substring of another, and the shared bare token "foundry"
# is never used as a needle, so attribution is collision-free.
_ACCOUNT_BY_HOST_SUBSTR = (
    ("best02-foundry-8514", "best02"),
    ("ffola-foundry-12246", "ffola"),
    ("foundry-ai-23928", "zelen"),
)


def _account_for(api_base):
    if not isinstance(api_base, str):
        return "unknown"
    for needle, label in _ACCOUNT_BY_HOST_SUBSTR:
        if needle in api_base:
            return label
    return "unknown"


def _norm_model(model):
    if not isinstance(model, str) or not model:
        return "claude-opus-4-8"
    # litellm is inconsistent about the "anthropic/" provider prefix; strip it so
    # each account collapses to exactly one table row (endpoint|resource|deployment).
    if model.startswith("anthropic/"):
        model = model[len("anthropic/"):]
    return model


def _as_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _get(obj, name):
    """Attr on an object, or key on a dict — whichever the usage shape uses."""
    val = getattr(obj, name, None)
    if val is None and isinstance(obj, dict):
        val = obj.get(name)
    return val


def _usage_of(response_obj):
    usage = getattr(response_obj, "usage", None)
    if usage is None and isinstance(response_obj, dict):
        usage = response_obj.get("usage")
    return usage


def _extract_cache_and_input(response_obj):
    """Return (cache_read, cache_creation, input_uncached_or_None).

    Handles all shapes we might see on the /v1/messages route:
      * OpenAI-normalized litellm Usage: prompt_tokens_details.cached_tokens / .cache_creation_tokens
      * Anthropic-native usage: public cache_read_input_tokens / cache_creation_input_tokens
                                + input_tokens (cache-EXCLUSIVE prompt count)
      * private litellm fields: _cache_read_input_tokens / _cache_creation_input_tokens
    input_uncached is the Anthropic native cache-exclusive prompt count when the
    Anthropic shape is present; None otherwise (the store then derives it).
    """
    cache_read = 0
    cache_creation = 0
    input_uncached = None
    try:
        usage = _usage_of(response_obj)
        if usage is None:
            return 0, 0, None

        details = _get(usage, "prompt_tokens_details")
        if details is not None:
            cache_read = _as_int(_get(details, "cached_tokens"))
            cache_creation = _as_int(_get(details, "cache_creation_tokens"))

        if cache_read == 0:
            cache_read = _as_int(_get(usage, "cache_read_input_tokens"))
        if cache_read == 0:
            cache_read = _as_int(_get(usage, "_cache_read_input_tokens"))

        if cache_creation == 0:
            cache_creation = _as_int(_get(usage, "cache_creation_input_tokens"))
        if cache_creation == 0:
            cache_creation = _as_int(_get(usage, "_cache_creation_input_tokens"))

        # Anthropic native input_tokens = prompt tokens EXCLUDING cache. Only the
        # Anthropic shape has "input_tokens"; the litellm Usage shape uses
        # "prompt_tokens" instead, so its presence is a reliable shape signal.
        native_input = _get(usage, "input_tokens")
        if native_input is not None:
            input_uncached = _as_int(native_input)
    except Exception:
        pass
    return cache_read, cache_creation, input_uncached


class UsageAccountLogger(CustomLogger):
    def _emit(self, kwargs, response_obj, start_time, end_time):
        try:
            slp = kwargs.get("standard_logging_object") or {}
            api_base = slp.get("api_base")

            cache_read, cache_creation, input_uncached = _extract_cache_and_input(response_obj)

            # Prefer the datetime hook arg for the timestamp (units are unambiguous).
            ts = None
            try:
                ts = float(end_time.timestamp())
            except Exception:
                ts = time.time()

            line = {
                "ts": ts,
                "account": _account_for(api_base),
                "model": _norm_model(slp.get("model")),
                "model_id": slp.get("model_id"),
                "api_base": api_base,
                "call_id": slp.get("id") or slp.get("litellm_call_id"),
                # prompt_tokens: litellm's own prompt count. May be cache-inclusive
                # OR cache-exclusive depending on the route; the STORE normalizes.
                "prompt_tokens": _as_int(slp.get("prompt_tokens")),
                # input_uncached: Anthropic native cache-exclusive input, or null.
                "input_uncached": input_uncached,
                "cache_read_tokens": cache_read,
                "cache_creation_tokens": cache_creation,
                "output_tokens": _as_int(slp.get("completion_tokens")),
                "total_tokens": _as_int(slp.get("total_tokens")),
                # litellm's own $ — stored as a cross-check only; NOT read by the app.
                "response_cost": float(slp.get("response_cost") or 0.0),
                "status": slp.get("status") or "success",
            }
            data = (json.dumps(line, separators=(",", ":")) + "\n").encode("utf-8")
            # O_APPEND + a single write() of a <4KB line is atomic across processes.
            fd = os.open(_USAGE_FILE, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            try:
                os.write(fd, data)
            finally:
                os.close(fd)
        except Exception:
            pass  # best-effort; never propagate

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        self._emit(kwargs, response_obj, start_time, end_time)

    def log_success_event(self, kwargs, response_obj, start_time, end_time):
        self._emit(kwargs, response_obj, start_time, end_time)


# Referenced from config.yaml as "custom_callbacks.usage_account_logger".
usage_account_logger = UsageAccountLogger()
```

Hook signatures verified against `integrations/custom_logger.py:134,176`. On the async proxy route only `async_log_success_event` fires (the sync `log_success_event` is gated by `is_sync_request`, False here — dead-but-harmless). Success-only logging means a best02 429 that fails over writes nothing for best02 and one line for the served ffola/zelen call, whose `slp.api_base` reflects the **actually served** deployment → correct account.

### 1b. `~/opus-gateway/config.yaml` edit
The existing `litellm_settings:` block is (verified):
```yaml
litellm_settings:
  forward_client_headers_to_llm_api: false
  num_retries: 2
```
Add exactly one line:
```yaml
litellm_settings:
  forward_client_headers_to_llm_api: false
  num_retries: 2
  callbacks: ["custom_callbacks.usage_account_logger"]
```
No other block changes. `model_list`, `router_settings` (sticky primary + fallbacks), `general_settings` untouched.

### 1c. Reload the gateway (only AFTER the §7 import test passes)
```
launchctl kickstart -k gui/$(id -u)/com.opusgateway.gateway
```
Agent label `com.opusgateway.gateway`, currently `state = running`.

### 1d. usage.jsonl line schema (one JSON object per line)
| field | type | notes |
|---|---|---|
| `ts` | float epoch seconds | from the `end_time` datetime hook arg |
| `account` | `best02`\|`ffola`\|`zelen`\|`unknown` | api_base host substring map |
| `model` | string | `anthropic/` prefix stripped → `claude-opus-4-8` |
| `model_id` | string\|null | per-account litellm hash |
| `api_base` | string | served deployment URL |
| `call_id` | string\|null | |
| `prompt_tokens` | int | litellm's prompt count (cache-in/exclusive — store normalizes) |
| `input_uncached` | int\|null | Anthropic native cache-exclusive input when available |
| `cache_read_tokens` | int | |
| `cache_creation_tokens` | int | |
| `output_tokens` | int | |
| `total_tokens` | int | |
| `response_cost` | float | litellm's own $, cross-check only — **not** parsed by the app |
| `status` | string | |

Example:
```json
{"ts":1751622000.123,"account":"best02","model":"claude-opus-4-8","model_id":"15314168d5605","api_base":"https://best02-foundry-8514.services.ai.azure.com/anthropic","call_id":"chatcmpl-abc","prompt_tokens":18234,"input_uncached":1034,"cache_read_tokens":16000,"cache_creation_tokens":1200,"output_tokens":412,"total_tokens":18646,"response_cost":0.0342,"status":"success"}
```

---

## 2. Tracker: new `ClaudeAzureUsageStore.swift`

New file `Sources/CodexAccountTracker/ClaudeAzureUsageStore.swift`, modeled on `LMStudioConversationStore.swift`. Reads `~/.opus-gateway/usage.jsonl` line-by-line with `JSONSerialization`. Missing file → empty result, no warnings. Malformed line → `malformedEventsSkipped += 1`, skip.

**Grouping** (key = `endpoint|resource|deployment`, `AzureUsageScanner.swift:108`) → one row per account:
- `endpoint = "Claude Azure"`, `resource = <account>`, `deployment = "claude-opus-4-8"`, `model = "claude-opus-4-8"`.

**Token reconstruction (resolves F1+F2, convention-independent).** For each line, let `cacheSum = cache_read + cache_creation`. Derive the cache-*exclusive* input:
- if `input_uncached` present & > 0 → use it (Anthropic native truth);
- else if `prompt_tokens >= cacheSum` → `prompt_tokens - cacheSum` (litellm was cache-inclusive);
- else → `prompt_tokens` (litellm was cache-exclusive).

Then `inputInclusive = nonCacheInput + cacheSum`. Because `AzureTokenUsage.inputTokens` is cache-inclusive and `uncachedInputTokens = max(0, input − cached − cacheCreation)`, this guarantees `uncachedInputTokens == nonCacheInput` and never clamps to 0.

Verified initializers: `AzureTokenUsage(inputTokens:cachedInputTokens:cacheCreationInputTokens:outputTokens:reasoningOutputTokens:totalTokens:)` (`AzureUsageModels.swift:607`, `cacheCreationInputTokens` has a default), and `AzureUsageRecord(id:sessionID:filePath:timestamp:endpoint:resource:deployment:model:projectPath:projectName?:usage:)` (`:647`, `projectName` optional). `AzureUsageScanResult(provider:)` via synthesized memberwise init (`:791`). Summary fields: `filesScanned/sessionsScanned/providerSessions/eventsCounted/malformedEventsSkipped/earliestEvent/latestEvent/warnings` (`:773-783`).

Full source:

```swift
import Foundation

/// Reads the LiteLLM gateway usage log (~/.opus-gateway/usage.jsonl) — one JSON
/// line per request, tagged with the serving Azure account (best02 / ffola /
/// zelen) — into usage records for the Claude Azure dashboard.
///
/// One record per request, so each request is its own "session": the "By account"
/// table's Events column = per-account request count (windowed). NOTE: the section
/// HEADLINE "Claude Azure requests" renders summary.providerSessions, which the
/// shared dashboard() does not re-window (AzureUsageScanner.swift:92-96), so the
/// headline is a LIFETIME total — same behavior as every other provider. The
/// authoritative windowed per-account numbers are the table rows.
final class ClaudeAzureUsageStore {
    private let usageFileURL: URL
    private let fileManager: FileManager

    init(
        usageFileURL: URL = ClaudeAzureUsageStore.defaultUsageFileURL(),
        fileManager: FileManager = .default
    ) {
        self.usageFileURL = usageFileURL
        self.fileManager = fileManager
    }

    static let endpointName = "Claude Azure"
    static let modelName = "claude-opus-4-8"

    func scan() -> AzureUsageScanResult {
        var result = AzureUsageScanResult(provider: .claudeAzure)

        // Missing file (callback not deployed yet / no requests) → empty, no warnings.
        guard fileManager.fileExists(atPath: usageFileURL.path),
              let data = try? Data(contentsOf: usageFileURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return result
        }
        result.summary.filesScanned = 1

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var index = 0
        for rawLine in lines {
            defer { index += 1 }
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData),
                  let entry = object as? [String: Any]
            else {
                result.summary.malformedEventsSkipped += 1
                continue
            }
            guard let record = Self.record(from: entry, lineIndex: index, filePath: usageFileURL.path) else {
                result.summary.malformedEventsSkipped += 1
                continue
            }
            result.records.append(record)
            result.summary.sessionsScanned += 1
            result.summary.providerSessions += 1   // lifetime request count (see headline note above)
            result.summary.eventsCounted += 1
            result.summary.earliestEvent = Self.minDate(result.summary.earliestEvent, record.timestamp)
            result.summary.latestEvent = Self.maxDate(result.summary.latestEvent, record.timestamp)
        }

        result.records.sort { $0.timestamp < $1.timestamp }
        return result
    }

    static func record(from entry: [String: Any], lineIndex: Int, filePath: String) -> AzureUsageRecord? {
        guard let ts = (entry["ts"] as? NSNumber)?.doubleValue, ts > 0 else { return nil }
        let timestamp = Date(timeIntervalSince1970: ts)

        let rawAccount = (entry["account"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let account = (rawAccount.isEmpty || rawAccount == "unknown") ? "unknown account" : rawAccount

        let model = Self.normalizedModel(entry["model"] as? String)

        let promptTokens = (entry["prompt_tokens"] as? NSNumber)?.intValue ?? 0
        let cacheRead = (entry["cache_read_tokens"] as? NSNumber)?.intValue ?? 0
        let cacheCreation = (entry["cache_creation_tokens"] as? NSNumber)?.intValue ?? 0
        let outputTokens = (entry["output_tokens"] as? NSNumber)?.intValue ?? 0
        let totalTokens = (entry["total_tokens"] as? NSNumber)?.intValue ?? 0
        let inputUncachedRaw = (entry["input_uncached"] as? NSNumber)?.intValue  // nil if null/absent

        let cacheSum = cacheRead + cacheCreation
        // Convention-independent: guarantee inputInclusive >= cacheSum so the app's
        // uncachedInputTokens = input - cached - cacheCreation never clamps to 0.
        let nonCacheInput: Int
        if let uncached = inputUncachedRaw, uncached > 0 {
            nonCacheInput = uncached                        // Anthropic native truth
        } else if promptTokens >= cacheSum {
            nonCacheInput = promptTokens - cacheSum          // litellm was cache-inclusive
        } else {
            nonCacheInput = promptTokens                     // litellm was cache-exclusive
        }
        let inputInclusive = nonCacheInput + cacheSum

        // A request with no tokens at all is not worth a row.
        guard inputInclusive > 0 || outputTokens > 0 else { return nil }

        let resolvedTotal = totalTokens > 0 ? totalTokens : inputInclusive + outputTokens
        let usage = AzureTokenUsage(
            inputTokens: inputInclusive,
            cachedInputTokens: cacheRead,
            cacheCreationInputTokens: cacheCreation,
            outputTokens: outputTokens,
            reasoningOutputTokens: 0,
            totalTokens: resolvedTotal
        )

        let callID = (entry["call_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableID = (callID?.isEmpty == false ? callID! : "claude-azure-\(lineIndex)-\(ts)")

        return AzureUsageRecord(
            id: stableID,
            sessionID: stableID,                 // one request == one "session" (request counter)
            filePath: filePath,
            timestamp: timestamp,
            endpoint: endpointName,
            resource: account,                   // best02 | ffola | zelen | "unknown account"
            deployment: model,                   // stable literal -> one row per account
            model: model,
            projectPath: endpointName,           // per-project unavailable via gateway (see Limitations)
            projectName: endpointName,
            usage: usage
        )
    }

    static func normalizedModel(_ value: String?) -> String {
        var model = (value?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        if model.isEmpty { return modelName }
        if model.hasPrefix("anthropic/") { model = String(model.dropFirst("anthropic/".count)) }
        return model.isEmpty ? modelName : model
    }

    private static func minDate(_ a: Date?, _ b: Date) -> Date { guard let a else { return b }; return min(a, b) }
    private static func maxDate(_ a: Date?, _ b: Date) -> Date { guard let a else { return b }; return max(a, b) }

    static func defaultUsageFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".opus-gateway/usage.jsonl", isDirectory: false)
    }
}
```

**Cost decision:** reuse `AzureModelPricing`. `dashboard()` calls `defaultPricing(for: record.model, provider: result.provider)` itself (`AzureUsageScanner.swift:102`). With `model="claude-opus-4-8"` and the `.claudeAzure` guard added in §4, it returns the **Claude Opus 4.5+** preset (in $5/M · cached $0.50/M · write $6.25/M · out $25/M) — correct Opus 4.8 rates. The logged `response_cost` is a JSONL cross-check only and is **not** parsed into the record, keeping the cost column identical in provenance to the sibling Azure/Claude dashboards.

---

## 3. Enum & scanner switch arms (compile gate — all 9 required)

`AzureUsageModels.swift`, `enum CodexLogUsageProvider` (@88):
- [ ] **Add case** after line 92: `case claudeAzure = "claude-azure"`
- [ ] `displayName` switch (@94), after line 99: `case .claudeAzure: return "Claude Azure"`
- [ ] `sessionCounterLabel` switch (@103), after line 108: `case .claudeAzure: return "Claude Azure requests"`
- [ ] `costLabel` switch (@115), extend arm @117: `case .azure, .openai, .claudeCode, .claudeAzure: return "Est. cost"`
- [ ] `costShortLabel` switch (@123), extend arm @125: `case .azure, .openai, .claudeCode, .claudeAzure: return "Est."`
- [ ] `unknownEndpointWarning` switch (@130), extend arm @136: `case .claudeCode, .lmStudio, .claudeAzure: return ""`

`AzureUsageScanner.swift` (transcript scanner — never runs for claudeAzure, but switches must stay exhaustive; merge into the `.lmStudio` arms):
- [ ] assert @31: `assert(provider != .lmStudio && provider != .claudeAzure, "Use ClaudeAzureUsageStore for Claude Azure usage")`
- [ ] metadata switch @33, arm @40: `case .lmStudio, .claudeAzure:`
- [ ] fileURLs switch @47, arm @52: `case .lmStudio, .claudeAzure:`
- [ ] scan switch @57, arm @62: `case .lmStudio, .claudeAzure:`
- [ ] appendRecord switch @990, arm @1000: `case .lmStudio, .claudeAzure:`

(The `switch` at `:1064` is over a `String`, not the enum — irrelevant. The `if provider ==` sites at `:349/398/455` are not exhaustive and never block compilation.)

---

## 4. Pricing

Reuse `AzureModelPricing.defaultPricing(for:provider:)`. No new preset. Harden two `if` conditions so a stray non-`claude-` model string still prices/falls-back as Claude:
- [ ] `AzureUsageModels.swift:398`: `if provider == .claudeCode || provider == .claudeAzure || normalized.contains("claude-") {`
- [ ] `AzureUsageModels.swift:455`: `if provider == .claudeCode || provider == .claudeAzure {`

With `model="claude-opus-4-8"` (not fable, not `opus-4-1`, not `claude-opus-4`), this returns the "Claude Opus 4.5+" preset at `:423-431`.

---

## 5. `AccountTrackerViewModel.swift` wiring (mirror lmStudio, verified line numbers)

- [ ] **@Published dashboard** — after `:17` (`lmStudioUsage`): `@Published private(set) var claudeAzureUsage = AzureUsageDashboard.empty`
- [ ] **refreshing flag** — after `:22`: `@Published private(set) var isClaudeAzureRefreshing = false`
- [ ] **lastScannedAt** — after `:27`: `@Published private(set) var claudeAzureLastScannedAt: Date?`
- [ ] **scan-mode + custom-date** — after the lmStudio block (`:71-80`):
  ```swift
  @Published var claudeAzureUsageScanMode: CodexUsageScanMode = .recent24Hours {
      didSet { rebuildClaudeAzureUsageDashboard() }
  }
  @Published var claudeAzureCustomStartDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date() {
      didSet { if claudeAzureUsageScanMode == .sinceDate { rebuildClaudeAzureUsageDashboard() } }
  }
  ```
- [ ] **store instance** — after `:125` (`lmStudioConversationStore`): `private let claudeAzureUsageStore = ClaudeAzureUsageStore()`
- [ ] **scan-result var** — after `:127` (`lmStudioScanResult`): `private var claudeAzureScanResult = AzureUsageScanResult(provider: .claudeAzure)`
- [ ] **refresh method** — after `refreshLMStudioUsage()` (ends `:415`):
  ```swift
  func refreshClaudeAzureUsage() {
      guard !isClaudeAzureRefreshing else { return }
      isClaudeAzureRefreshing = true
      Task { [weak self, claudeAzureUsageStore, usageCacheStore] in
          let scan = await Task.detached(priority: .utility) { claudeAzureUsageStore.scan() }.value
          guard let self else { return }
          defer { isClaudeAzureRefreshing = false }
          let scannedAt = Date()
          claudeAzureScanResult = scan
          claudeAzureLastScannedAt = scannedAt
          usageCacheStore.save(claudeAzureScanResult, scannedAt: scannedAt)
          rebuildClaudeAzureUsageDashboard()
      }
  }
  ```
- [ ] **cache load** — in `loadUsageCaches()` after the lmStudio block (`:527-531`):
  ```swift
  if let claudeAzureCache = usageCacheStore.load(provider: .claudeAzure) {
      claudeAzureScanResult = claudeAzureCache.result
      claudeAzureLastScannedAt = claudeAzureCache.scannedAt
      rebuildClaudeAzureUsageDashboard()
  }
  ```
- [ ] **rebuild method** — after `rebuildLMStudioUsageDashboard()` (`:741-747`):
  ```swift
  private func rebuildClaudeAzureUsageDashboard() {
      claudeAzureUsage = AzureUsageScanner.dashboard(
          from: claudeAzureScanResult,
          window: claudeAzureUsageScanMode.usageWindow,
          customStartDate: claudeAzureCustomStartDate,
          now: displayNow
      )
  }
  ```
- [ ] **start() call** — after `refreshLMStudioUsage()` at `:266`: add `refreshClaudeAzureUsage()` (cheap single-file rescan; always refresh on launch).
- [ ] **Text report (optional)** — after the lmStudio `appendUsageDashboard(...)` block (`:203-212`):
  ```swift
  lines.append("")
  appendUsageDashboard(
      claudeAzureUsage,
      title: "Claude Azure Usage",
      windowLabel: claudeAzureUsageScanMode.label,
      lastScannedAt: claudeAzureLastScannedAt,
      sessionCounterLabel: CodexLogUsageProvider.claudeAzure.sessionCounterLabel,
      costLabel: CodexLogUsageProvider.claudeAzure.costLabel,
      costShortLabel: CodexLogUsageProvider.claudeAzure.costShortLabel,
      to: &lines
  )
  ```
- **Cache filename** — free. `AzureUsageCacheStore.fileURL(for:)` derives `"claude-azure-usage-cache.json"` from `rawValue`. No change.

---

## 6. `ContentView.swift`

Add after `LMStudioUsageSectionView` (ends `:649`). The `endpointLabel` renders only the account (from `group.resource`). Uses the `scanMode:` init overload (`:701`); `costLabel`/`costColumnTitle` keep their "Est." defaults, matching Opus pricing.

```swift
private struct ClaudeAzureUsageSectionView: View {
    @EnvironmentObject private var viewModel: AccountTrackerViewModel

    var body: some View {
        CodexLogUsageSectionView(
            title: "Claude Azure Usage",
            subtitle: "Per-account usage from the local LiteLLM gateway — best02 / ffola / zelen. Table request/token counts follow the window; the headline count is lifetime.",
            dashboard: viewModel.claudeAzureUsage,
            isRefreshing: viewModel.isClaudeAzureRefreshing,
            lastScannedAt: viewModel.claudeAzureLastScannedAt,
            scanMode: $viewModel.claudeAzureUsageScanMode,
            customStartDate: $viewModel.claudeAzureCustomStartDate,
            sessionCounterLabel: CodexLogUsageProvider.claudeAzure.sessionCounterLabel,
            endpointTableTitle: "By account",
            emptyText: "No Claude Azure requests logged yet. Use claude-azure, then click Refresh.",
            endpointLabel: { group in group.resource },   // account name only
            refresh: viewModel.refreshClaudeAzureUsage
        )
    }
}
```

- [ ] Insert `ClaudeAzureUsageSectionView()` immediately after `ClaudeCodeUsageSectionView()` in **both** section lists: `:18` (empty-state list) and `:43` (accounts list).

---

## 7. Test / verification plan

**Gateway (prove it logs without bricking):**
1. Syntax check (before reload): `~/opus-gateway/venv/bin/python -c "import ast; ast.parse(open('$HOME/opus-gateway/custom_callbacks.py').read())"`
2. **Import check (MANDATORY before kickstart — the only boot-kill vector):** `cd ~/opus-gateway && ./venv/bin/python -c "import custom_callbacks; print(type(custom_callbacks.usage_account_logger).__mro__)"` — confirm `CustomLogger` is in the MRO.
3. Reload: `launchctl kickstart -k gui/$(id -u)/com.opusgateway.gateway`; then `launchctl print gui/$(id -u)/com.opusgateway.gateway | grep 'state ='` → `running`, and `curl -s http://localhost:4000/health/liveliness`; tail `~/.opus-gateway/gateway.log` for a clean boot (no callback import error).
4. **Single-emit assertion (F6):** record `wc -l ~/.opus-gateway/usage.jsonl` (0 if new), drive **one** streamed `claude-azure` request (Claude Code always streams), then assert the count increased by **exactly 1** — not merely "a line appeared."
5. **Field validity:** `tail -1 ~/.opus-gateway/usage.jsonl` → one well-formed JSON object with `account` ∈ {best02,ffola,zelen} and non-zero tokens. Whole-file parse: `~/opus-gateway/venv/bin/python -c "import json;[json.loads(l) for l in open('$HOME/.opus-gateway/usage.jsonl')]"`
6. **Token invariant cross-check (F1+F2):** on a cached turn's line, assert `cache_read_tokens > 0` (proves the cache extractor matched the live shape) and that reconstruction holds: `prompt_tokens >= cache_read_tokens + cache_creation_tokens` OR `input_uncached` is a positive int. If neither, the store's third branch still keeps `uncachedInputTokens` ≥ 0 — but investigate which shape the route emits and confirm the columns look sane.

**Tracker (prove compile + rows):**
1. Repo root: `swift build` must succeed — satisfying the 9 switch arms in §3 is the compile gate.
2. `swift run`; with ≥1 request logged per account, the "Claude Azure Usage" section shows the **By account** table with separate **best02 / ffola / zelen** rows, each with Events (request count), Input/Cached/Uncached/Output/Total tokens, and Est. $ at Opus 4.5+ rates. Change the window control → the table Events/token columns re-filter. (The headline "Claude Azure requests" stays at the lifetime total by design — see F3.) Click Refresh after another request → new rows/counts.
3. Order-of-magnitude cross-check: sum of displayed per-account Est. $ ≈ sum of `response_cost` in usage.jsonl (won't match exactly — app uses preset rates, gateway uses litellm's — but same order confirms token mapping is right).

---

## 8. Batching (parallel vs sequential)

- **Batch A — Gateway** (`~/opus-gateway/custom_callbacks.py` new + `config.yaml` 1-line add + import test → kickstart → verify). Different directory, zero overlap with Swift. **PARALLEL** with all Swift work.
- **Batch B — Swift enum foundation** (`AzureUsageModels.swift` §3 arms + §4 pricing; `AzureUsageScanner.swift` §3 arms). Compile-blocking prerequisite (the new case breaks exhaustiveness until every arm exists). **Sequential, first among Swift.**
- **Batch C — new store** (`ClaudeAzureUsageStore.swift`, brand-new file). Depends only on B's enum case. **PARALLEL with D** once B lands (disjoint files).
- **Batch D — ViewModel + ContentView** (`AccountTrackerViewModel.swift` §5, `ContentView.swift` §6). References `.claudeAzure` (B) and `ClaudeAzureUsageStore` (C). **Last.**
- **Final:** `swift build` then `swift run` after B+C+D.

Recommended order: **A ∥ (B → {C ∥ D})**. Enforce ordering by symbol dependency, not file locking; the Swift files are disjoint.

---

## 9. Rollback

**Gateway (independent):** remove the `callbacks: [...]` line from `~/opus-gateway/config.yaml`; delete `~/opus-gateway/custom_callbacks.py`; `launchctl kickstart -k gui/$(id -u)/com.opusgateway.gateway`. Optionally delete `~/.opus-gateway/usage.jsonl`. Gateway returns to exact prior behavior; both files are user-owned and survive litellm upgrades.

**Tracker (independent):** revert the **4 edited files** — `AzureUsageModels.swift`, `AzureUsageScanner.swift`, `AccountTrackerViewModel.swift`, `ContentView.swift` — and **delete the 1 new file** `ClaudeAzureUsageStore.swift`. Delete the derived cache by globbing (path not assumed): `find ~/Library -name 'claude-azure-usage-cache.json' -delete`. `swift build` returns green with the feature gone; no other provider's data/cache is touched (cache files are per-provider by filename).

**Safety:** the two halves roll back independently — reverting the app leaves the gateway harmlessly logging to usage.jsonl; reverting the gateway leaves the app showing an empty Claude Azure section (empty result, no crash).

---

## Known limitations (surface to the user)
1. **No per-project breakdown** via the gateway — Claude Code doesn't send the project path to the API; `projectPath` is fixed to "Claude Azure". Per-account is what was requested; per-project is out of scope.
2. The existing **"Claude Code" dashboard keeps counting claude-azure sessions** too (both write to `~/.claude/projects`). Fully separating would require `CLAUDE_CONFIG_DIR`, sacrificing shared skills/MCP/history — not done. The new gateway-fed view is the authoritative per-account Azure view.
3. **The "Claude Azure requests" headline is a lifetime total**, not windowed (shared-dashboard quirk, consistent with all other providers). The windowed per-account request counts are the "By account" table's Events column — that is the number the user asked for.
4. **Forward-looking only** — logging begins when the callback deploys; past usage is not backfilled.
5. **usage.jsonl grows unbounded** — fine at personal scale; rotation is a future nicety.

Relevant absolute paths: gateway `/Users/angelatanasov/opus-gateway/{config.yaml,run.sh,custom_callbacks.py(new)}`, log `/Users/angelatanasov/.opus-gateway/usage.jsonl(new)`; tracker sources under `/Users/angelatanasov/Desktop/Codex-Account-Usage-tracker/Sources/CodexAccountTracker/` (`AzureUsageModels.swift`, `AzureUsageScanner.swift`, `AccountTrackerViewModel.swift`, `ContentView.swift`, new `ClaudeAzureUsageStore.swift`).