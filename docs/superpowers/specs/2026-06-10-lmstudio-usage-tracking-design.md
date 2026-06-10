# LM Studio Usage Tracking — Design

Date: 2026-06-10
Status: Approved by user (proceed with build)

## Goal

Show local LM Studio model usage (Qwen 27B/35B and friends) in Codex Account
Tracker as a fourth dashboard section alongside Azure, OpenAI Codex, and
Claude Code.

## Scope

- **In scope:** Usage from the LM Studio chat app, read from
  `~/.lmstudio/conversations/*.conversation.json`.
- **Out of scope (later):** Usage from the local OpenAI-compatible server
  (`localhost:1234`) recorded in `~/.lmstudio/server-logs/` — verbose debug
  logs, fragile to parse. Deliberately deferred.

## Data source

Each conversation file contains `messages[]`; assistant messages carry
`steps[].genInfo.stats`:

```json
{
  "stopReason": "eosFound",
  "tokensPerSecond": 20.77,
  "promptTokensCount": 11,
  "predictedTokensCount": 192,
  "totalTokensCount": 203
}
```

Mapping:

| Conversation field | Usage record field |
|---|---|
| `promptTokensCount` | input tokens (all uncached) |
| `predictedTokensCount` | output tokens |
| cache read / cache write | always 0 (no cache billing locally) |
| model | per-message generation info if present, else conversation `lastUsedModel.identifier` |
| timestamp | per-message timestamp if present, else conversation `assistantLastMessagedAt` / `createdAt` |

Speculative-decoding draft counts (`acceptedDraftTokensCount` etc.) are
ignored — they are already reflected in `predictedTokensCount`.

**Dedupe:** records are identified by (conversation file ID, message ID,
step/version index). Conversation files are rewritten as chats grow, so
rescans must never double-count. Same principle as Claude Code's
`messageId + requestId` dedupe.

## Provider & pricing

- New `CodexLogUsageProvider` case: `lmStudio = "lm-studio"`, display name
  "LM Studio", session counter label "LM Studio chats".
- New provider-driven `costLabel` property: "Est. cost" for existing
  providers, **"Est. saved"** for LM Studio.
- `AzureModelPricing.defaultPricing` gets an LM Studio branch returning
  Claude Sonnet 4.6 reference rates: input $3.00/M, output $15.00/M
  (cache columns unused). Display name marks it as a savings estimate.
  Rationale: 27B–35B-class local models are roughly mid-tier-cloud-class;
  the column is labeled as an estimate.

## Components

1. **`LMStudioConversationStore.swift`** (new) — finds and parses
   conversation files, returns usage records. Pure parsing logic separated
   from file discovery so it is unit-testable with fixture JSON.
2. **`AzureUsageScanner`** — gains an `.lmStudio` scan path that delegates
   to the conversation store (mirrors the Claude Code path).
3. **`AccountTrackerViewModel`** — new published `lmStudioUsage` dashboard,
   `lmStudioLastScannedAt`, scan mode + custom start date, scanner instance,
   cached scan result persisted via the existing usage cache store as
   `lmstudio-usage-cache.json`.
4. **`ContentView`** — fourth dashboard section after Claude Code, reusing
   the existing section view with provider-appropriate labels.

## Error handling

- `~/.lmstudio` or `conversations/` missing → empty dashboard, no warnings.
- Malformed/unreadable conversation file → skip it, surface one warning in
  the dashboard warnings area, continue scanning.
- Messages without `genInfo.stats` (user messages, aborted generations) →
  skipped silently.

## Testing

- New SPM test target with fixture-based unit tests for the parser:
  a stripped real conversation JSON → expected records (token counts, model
  attribution, dedupe keys); malformed JSON → no crash, file skipped.
- Manual verification: dashboard totals vs. the live conversation file
  (current file: 3 assistant replies, 109 prompt / 770 predicted tokens).
