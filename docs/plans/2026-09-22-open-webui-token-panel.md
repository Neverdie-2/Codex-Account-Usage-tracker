# Open WebUI (Qwen Image Editor chat) token panel — plan

Operator, 2026-09-22: "we can just make it count the tokens for now with a chart and panel like the rest."

Scope: ONE new panel + history chart, "Open WebUI Usage", counting the tokens of the local chat
assistant that drives the Qwen Image Editor. Image counts and image pricing are OUT of scope
(operator deferred them). Nothing is sent anywhere; the tracker only reads a local SQLite file.

## What is read (LOCAL, read-only)

- `~/Projects/Qwen-Image-2.1/open-webui/data/webui.db`, table `chat`, column `chat` (JSON).
  For every `history.messages[*]` with `role == "assistant"` and a `usage` object → one record.
  Assistant turns with no `usage` (75 today, all `done: false`, no content) are aborted turns and
  are skipped, like opencode's errored turns.
- Prompt text is never read into a record. The store keeps only ids, timestamps and token counts.
- `~/Projects/Qwen-Image-2.1/runtime/chat-assistant-server.json` → `argv` after `--model` → the
  GGUF file name, used as the model label so pricing can match it ("…35B-A3B…" → the existing
  Qwen3.6 35B A3B reference rate). If the file is missing the label falls back to the message's
  model id and pricing is unknown ($0), never guessed.

## Token mapping (VERIFIED against Open WebUI 0.11.4 `utils/response.py`)

`merge_usage` SUMS `input_tokens` / `output_tokens` / `total_tokens` across the tool-call rounds of
one turn, and keeps the LAST round's llama.cpp fields (`prompt_tokens`, `completion_tokens`,
`cache_n`, `prompt_n`). Therefore:

- inputTokens  = `input_tokens` (fallback `prompt_tokens`)
- outputTokens = `output_tokens` (fallback `completion_tokens`)
- cachedInputTokens = `cache_n` ONLY when the turn had a single round (`input_tokens == prompt_tokens`);
  otherwise 0 (earlier rounds' cache hits are unknown → conservative).
- totalTokens = `total_tokens` (fallback input + output)
- timestamp = `timestamp` (epoch seconds) of the assistant message.

Sample turn today: input 16,156 / output 201 / prompt_tokens 8,229 / cache_n 8,071 → two rounds,
cached = 0.

## Code changes (build ONLY these)

1. `CodexLogUsageProvider.openWebUI = "open-webui"` + labels ("Open WebUI", "Open WebUI chats",
   "Est. saved"/"Saved"); every exhaustive `switch` gains the case (scanner: 4 sites + assert).
2. `AzureModelPricing.defaultPricing`: the LM Studio reference-rate block also applies to `.openWebUI`.
3. New `OpenWebUIUsageStore` (mirrors `OpencodeUsageStore`: read-only SQLite open, immutable
   fallback, pure `records(fromChatJSON:)` mapping, `modelLabel(fromStateFile:)`).
4. View model: state vars, `refreshOpenWebUIUsage` (full rescan, saved to the provider cache file
   `open-webui-usage-cache.json`), cache load at launch, rebuild, report lines, collapsible ids,
   refresh on launch (cheap: one small SQLite file).
5. `UsageHistoryPanelConfiguration.openWebUI` (groupings model/project/source, like LM Studio).
6. `ContentView`: `OpenWebUIUsageSectionView` after the LM Studio section, in both layouts.
7. Tests: mapping (multi-round vs single-round cached), skipped aborted turns, model label from
   state-file argv, SQLite read of a temp db.

## Claims ledger

- VERIFIED: db path, schema (`chat.chat` JSON, `history.messages`), 103 turns with usage, usage keys,
  merge semantics (read from the installed package), state-file argv, tracker already links SQLite3.
- ASSUMED: the operator keeps the same data folder; Open WebUI keeps `usage` on assistant messages
  in future versions (it has since 0.6.x).

## Pre-mortem (first end-to-end action: launch → refresh → panel shows totals)

- DB locked by the running Open WebUI (WAL): read-only open sees committed data; immutable-URI
  fallback if `-shm` is unreadable (same guard as opencode). Never opened for write.
- DB missing (folder moved): empty result, no warnings, panel shows its empty text.
- Malformed chat JSON row: skipped; counted in `malformedEventsSkipped`.
- Record id collision across chats: id = `open-webui-<chatID>-<messageID>` (message ids are UUIDs).
- Provider enum grows → old caches decode fine (new raw value, own cache file).
- Wrong label for old turns if the operator swaps the llama-server model later: label is the CURRENT
  model for all turns (documented limitation; same as LM Studio "lastUsedModel" fallback).
- Main-thread freeze: scan runs in `Task.detached(priority: .utility)` like the LM Studio refresh.
