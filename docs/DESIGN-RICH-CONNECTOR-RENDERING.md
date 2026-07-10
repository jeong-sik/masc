# MASC Rich Connector Rendering & Turn Lifecycle Projection — Design Review

> Status: design draft
> Scope: MASC (`~/me/workspace/yousleepwhen/masc`) connector ingress/egress, rich output rendering, turn progress projection, and live runtime behavior under `<base-path>/.masc`. OAS boundary respected: no MASC semantics leak into OAS.
> Authors: adversarial review swarm
> Date: 2026-06-20

---

## 1. Executive Summary

MASC is a self-developed parallel multi-agent work and monitoring system built on OCaml 5.x and Eio multi-fiber concurrency. It can start, observe, wait on, poll, and finish turns from several surfaces: Dashboard, Discord, Slack, Telegram, iMessage, CLI, TUI, HTTP APIs, and background runtime loops.

The current rich-content problem is therefore not only a formatting problem. MASC currently renders rich content faithfully only in the Dashboard. Every other surface receives either flattened text or a small subset of events, so markdown, code blocks, tables, images, audio, video, file attachments, SVG/mermaid, callouts, fusion panels, tool results, and turn progress are degraded, stripped, or silently dropped.

This design treats connector rendering as a MASC-owned surface projection layer:

1. Normalize MASC turn lifecycle events into one connector-facing event stream.
2. Carry rich response blocks alongside fallback text.
3. Let each connector render according to an explicit capability manifest.
4. Degrade visibly when a connector cannot render a block or lifecycle event.
5. Keep OAS generic: provider/model transport, generic Agent lifecycle, hooks, and tool-use APIs stay outside MASC-specific connector policy.

---

## 2. System Context

- **MASC repo:** `~/me/workspace/yousleepwhen/masc`
- **OAS repo:** `~/me/workspace/yousleepwhen/oas`
- **Live runtime root:** `<base-path>/.masc` for the active `MASC_BASE_PATH` or `--base-path`.
- **MASC role:** parallel multi-agent execution, keeper/runtime orchestration, board/fusion/dashboard surfaces, connector gates, operational monitoring, and MASC-specific turn projection.
- **OAS role:** OCaml Agent SDK public library: provider/model handling, transport, generic Agent turn lifecycle, hooks, sync/async/batch tool-use systems, and provider-neutral content types.
- **Runtime truth rule:** repo seed config and docs are not proof of live behavior. For live claims, verify the runtime under `<base-path>/.masc` and the health surface before treating a design as deployed.

The design target is the MASC boundary between:

```text
external channel event
  -> MASC channel gate / sidecar
  -> MASC runtime turn request
  -> OAS generic Agent/provider execution
  -> MASC turn lifecycle + rich response projection
  -> connector-specific renderer
```

---

## 3. Scope & Boundary Rules

- **OAS stays generic.** OAS may expose provider-neutral content blocks, transport behavior, and generic Agent response helpers. No keeper, board, fusion, connector, dashboard, live runtime, or MASC channel policy moves into OAS.
- **MASC owns surface projection.** Slack Block Kit, Discord embeds/uploads, Telegram Bot API formatting, iMessage AppleScript, CLI ANSI, TUI layout, Dashboard rendering, polling endpoints, and channel progress messages stay in MASC.
- **MASC owns MASC turn state.** Channel-specific start/ack/wait/poll/finish behavior is MASC runtime behavior, even when the underlying model execution goes through OAS.
- **Single source of truth.** The canonical connector representation is a typed MASC turn surface event stream plus rich content blocks. Each connector translates that stream into its native format.
- **Fallback text is not enough.** Plain `reply` text remains the last-resort representation, not the primary connector contract.

---

## 4. Current-State Capability Matrix

| Capability | Dashboard | Discord | Slack (OCaml) | Slack sidecar | Telegram | iMessage | CLI | TUI |
|---|---|---|---|---|---|---|---|---|
| Plain text | ✅ | ✅ (2000-char chunks) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Markdown inline | ✅ | ⚠️ partial | ⚠️ mrkdwn | ⚠️ plain | ❌ | ❌ | ❌ | ❌ |
| Code blocks | ✅ highlighted | ⚠️ fenced, can split | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Lists | ✅ | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Tables | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Callouts / blockquotes | ✅ | ❌ (quote only) | ⚠️ context | ❌ | ❌ | ❌ | ❌ | ❌ |
| Images png/jpg/gif/webp | ✅ | ⚠️ embed if event | ⚠️ block if event | ❌ | ❌ | ❌ | ❌ | ❌ |
| SVG | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Mermaid | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Audio | ✅ player | ❌ raw URL | ❌ link | ❌ | ❌ | ❌ | ❌ | ❌ |
| Video | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Documents pdf/md/txt/csv/json | ⚠️ limited whitelist | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Inbound attachments | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Outbound attachments | ✅ data-URL | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Fusion panels | ✅ card | ❌ raw text | ❌ raw text | ❌ | ❌ | ❌ | ❌ |
| Tool results / blobs | ✅ trace card | ⚠️ embed | ⚠️ context | ❌ | ❌ | ❌ | ❌ |
| Turn progress / status | ✅ typed receipt | ⚠️ text projection | ⚠️ text projection | ❌ | ❌ | ❌ | ⚠️ manual | ⚠️ status only |
| Turn start / ack | ✅ | ⚠️ message only | ⚠️ message only | ⚠️ message only | ⚠️ message only | ⚠️ message only | ✅ | ⚠️ command only |
| Wait / poll status | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ⚠️ manual | ❌ |
| Turn completion / failure identity | ✅ | ⚠️ text only | ⚠️ text only | ⚠️ text only | ⚠️ text only | ⚠️ text only | ⚠️ text only | ⚠️ status only |

Legend: ✅ supported · ⚠️ partial / degraded · ❌ silently dropped / unsupported

---

## 5. Adversarial Findings & Proposed Improvements

### 5.1 Backend block model

**Finding:** `lib/keeper/keeper_chat_blocks.ml` only emits `Text | Image | Link | Fusion`. Code, tables, lists, callouts, mermaid, SVG, and video are flattened before connectors see them.

**Improvement:**
- Extend `chat_block` to `Code | Table | List | Callout | Mermaid | Svg | Video | Audio` with JSON round-trips.
- Keep the parser backward-compatible; Dashboard can still use its local `marked` parser as a fallback, but server-produced blocks become authoritative.
- Update `dashboard/src/api/schemas/keeper-chat-history.ts` to accept the full vocabulary.

---

### 5.2 Discord connector

**Finding:** Message chunking is Unicode-scalar aware but not Markdown-structure aware; code fences, tables, and inline links can be torn across messages. Embed limits (10 embeds, 25 fields, 6000 total chars, 4096 description) are not enforced. Audio/video/file attachments have no upload path. SVG/mermaid are silently dropped.

**Improvements (`lib/keeper/keeper_chat_discord.ml`, `lib/gate/discord_rest_client.ml`):**
- Add Markdown-aware chunking: split on paragraph/code-fence boundaries first; if forced to split inside a fence, close and reopen fences on chunk boundaries.
- Enforce Discord embed limits before sending; overflow becomes additional messages.
- Replace `String.length` with Unicode-scalar counting for all embed fields.
- Add multipart upload helpers and wire audio/video/file blocks to `POST /channels/{id}/messages` with attachments.
- Render SVG/mermaid server-side to PNG (or dashboard deep-link) and send as an image attachment.
- Render Fusion blocks as a link embed to the board post plus a one-line summary.
- Preserve code-block language tags.
- Add structural JSON truncation for tool-result fields so truncated JSON is not emitted inside a code fence.

---

### 5.3 Slack connector

**Finding:** The OCaml adapter only handles `Link_block`, `Image_block`, `Audio_block`, and `Tool_context_block`; plain text is sent as raw fallback. The Python sidecar ignores `GateResponse.structured` entirely and builds a single `section` + `context` block. Block Kit limits (50 blocks, 3000 chars per block text) are not enforced. Mrkdwn metacharacters (`<`, `>`, `&`, `*`) are not escaped. Inbound Slack file attachments are ignored.

**Improvements (`lib/keeper/keeper_chat_slack.ml`, `sidecars/slack-bot/src/formatters.py`, `sidecars/slack-bot/src/bot.py`):**
- On `Run_finished`, parse accumulated text with `content_blocks_of_text`, merge with event blocks, and send a unified Block Kit payload.
- Map `Code` → fenced code `section`, `Table` → fixed-width ASCII code block or file upload, `List` → bullet section, `Callout` → emoji-prefixed section.
- Escape Slack mrkdwn special characters in titles/descriptions.
- Enforce 50-block and 3000-char limits; spill long content into additional messages or file uploads.
- Handle inbound `event["files"]` by downloading/forwarding file metadata or bytes to the gate.
- Implement tool-running/done indicators mirroring Discord (🔄 → ✅/❌).
- Render Fusion blocks as a compact section with a board-post deep link.

---

### 5.4 Telegram / iMessage / CLI sidecars

**Finding:** All three consume only `GateResponse.reply` (plain text) and ignore `GateResponse.structured`. Images embedded as `![alt](url)` are sent as text. Telegram chunking splits inside markdown entities. iMessage has no length guard. CLI prints raw text with no markdown awareness.

**Improvements:**
- **Telegram** (`sidecars/telegram-bot/src/formatters.py`, `bot.py`)
  - Use `parse_mode="HTML"` and convert rich blocks to Telegram HTML (`<b>`, `<i>`, `<code>`, `<pre>`).
  - Detect image URLs/files and send via `send_photo`/`send_document`/`send_audio`.
  - Chunk on codepoint boundaries and avoid splitting inside links/code fences.
  - Convert tables to fixed-width ASCII, callouts to emoji-prefixed bold lines.
- **iMessage** (`sidecars/imessage-bot/src/bot.py`, `imessage_bridge.py`)
  - Extend AppleScript bridge to accept an optional `attachment_path` and send files (images, audio) when supported.
  - Chunk replies at ~4000 characters.
  - Convert markdown to plain-text with `•` lists, backtick code, and ASCII tables.
  - Send a transient “thinking…” message because live editing is unavailable.
- **CLI** (`sidecars/cli-connector/src/bot.py`)
  - Add a lightweight markdown→ANSI renderer (bold, italic, inline code, headings, lists).
  - Render code blocks with syntax highlighting (e.g., `pygments`).
  - Render tables with `rich.table` or `tabulate`.
  - Use terminal inline-image protocols (iTerm2, kitty, sixel) opportunistically for images.
  - Page long output through the user’s pager or truncate with a visible marker.

---

### 5.5 Dashboard chat rendering

**Finding:** Dashboard is the richest surface but still has XSS, truncation, and consistency gaps. `ChatSvgBlock`/`ChatMermaidBlock` use inconsistent DOMPurify configs. `ChatLinkBlock` allows `blob:` URLs. `ChatAttachBlock` accepts `data:image/svg+xml` without sanitization. `repairTruncatedMarkdown` misdiagnoses fences containing triple backticks. `parseMarkdownToBlocks` returns `[]` on any lexer error. Server card blocks and parsed markdown blocks can duplicate content. Tool/shell output is sanitized rather than escaped.

**Improvements (`dashboard/src/components/chat/*.ts`, `common/markdown-renderer.ts`, `common/rich-content*.ts`, `lib/dompurify.ts`):**
- Unify SVG sanitization profile across `ChatSvgBlock`, `ChatMermaidBlock`, and `ChatArtifactPreview`.
- Restrict link cards to `http:`/`https:`; `blob:` allowed only for media `src`.
- Validate attachment MIME types against an explicit whitelist; sanitize SVG attachments before rendering.
- Escape shell/tool output as plain text instead of sanitizing; use JSON/syntax highlighters that do not execute scripts.
- On `parseMarkdownToBlocks` failure, return an escaped fallback paragraph with a visible warning marker.
- Improve `repairTruncatedMarkdown` to handle unclosed `<think>`, tables, and dangling link brackets; use fence-pair counting instead of global backtick counts.
- Merge server card blocks with parsed markdown blocks in order instead of choosing one path.
- Add `alt`/`description` requirements for SVG/mermaid blocks so non-dashboard connectors have a fallback.
- Extend DOMPurify smoke tests to cover event handlers, `data:` HTML blobs, and CSS expression attacks.

---

### 5.6 Board posts / comments / votes

**Finding:** Board attachment meta (`Image | Video | Youtube | External_link`) is stored but never rendered in the dashboard. Video/audio/file kinds are missing. Comments are returned as a flat list and re-treed in every client. Comment/post limits are byte-based, not grapheme-based. Vote UI conflates score and karma. There is no shared board→connector render contract.

**Improvements (`lib/board/board_*.ml`, `dashboard/src/components/board/*.ts`):**
- Extend `board_attachment_meta` with `Audio | File | Gallery` and optional `caption`/`alt_text`.
- Add an `AttachmentGallery` component wired into `board-surface` and `post-detail`.
- Add a server-side nested comment tree serializer (`Board_dispatch.get_post_and_comments_tree`) with pagination and `max_depth`.
- Make limits grapheme-aware using a shared helper.
- Separate score and karma in the UI; document the comment-karma asymmetry or align the policy.
- Introduce a MASC-only `Board_render` module that produces connector-agnostic fragments and per-connector translators (Discord embeds, Slack blocks, plain-text fallback).
- Extend `keeper_surface_post` schema with an optional `board_payload` object so tool-generated board posts carry structured data.

---

### 5.7 TUI / ANSI rendering

**Finding:** TUI uses `String.length` for layout, causing misalignment with CJK/emoji and broken boxes. Color is the only status signal. Message view wraps mid-emoji/mid-URL. No streaming or turn-progress visibility. Rich blocks are not consumed at all.

**Improvements (`bin/masc_tui_ansi.ml`, `bin/masc_tui_render.ml`, `lib/workspace_status_rendering.ml`):**
- Add `display_width` + `strip_ansi` helpers; replace byte-based layout math with display-cell math.
- Add `NO_COLOR` / `MASC_TUI_EMOJI=0` support; pair icons with text labels (`[BUSY] 🔴`).
- Word-wrap messages on display width, preserving word boundaries and URLs.
- Consume AG-UI/SSE events in the TUI and render turn phase + tool progress in a status line.
- Add block renderers for code, tables, callouts, links, images (placeholder), tool results, and fusion panels.
- Allow TUI attachment input (`/attach <file>`) and render attachment placeholders.
- Add `~style:[Unicode | Ascii | Plain]` to `workspace_status_rendering.ml` for non-terminal consumers.

---

### 5.8 Turn lifecycle projection cross-channel

**Finding:** MASC can start and observe turns through multiple channel paths, but those paths do not share one connector-facing turn contract. The composite observer exposes a typed turn FSM, while chat events, AG-UI, Discord, Slack, sidecars, CLI, and TUI receive different partial projections. The SSE adapter explicitly drops `Link_block`, `Image_block`, `Audio_block`, and `Tool_context_block` with the comment “Rich blocks are Discord-specific”. `Tool_context_block` is defined but never published. Sidecars have zero progress visibility and must infer completion from the final `reply` string.

**Identity contract:** connector-facing `turn_id` is the serialized `Ids.Turn_ref.t`
from RFC-0233 §7 (`"<trace_id>#<absolute_turn>"`), not a second connector-local
turn identifier. `request_id` exists only before a MASC turn is accepted; the
`Turn_accepted` event binds `request_id` to the canonical `turn_id`. Producers
must derive `turn_id` from the backend-minted `Turn_ref`, and consumers must not
fabricate or reinterpret it.

**Required MASC-owned event envelope:**

```text
Turn_requested        { request_id; channel; actor; thread_ref; created_at }
Turn_accepted         { request_id; turn_id; keeper_id; queue_position option }
Turn_waiting          { turn_id; reason; retry_after_ms option }
Turn_phase_changed    { turn_id; phase; message option }
Tool_call_started     { turn_id; tool_call_id; tool_name; summary }
Tool_call_finished    { turn_id; tool_call_id; status; redacted_summary; blocks }
Content_delta         { turn_id; text_delta }
Content_block         { turn_id; block }
Turn_finished         { turn_id; status; text_fallback; blocks; metrics }
Turn_failed           { turn_id; error_class; user_message; retryable }
Poll_snapshot         { request_id; turn_id option; status; latest_event_seq }
```

**Improvements (`lib/keeper/keeper_chat_events.mli`, `lib/ag_ui/ag_ui.ml`, `lib/server/server_routes_http_keeper_stream.ml`, `lib/gate/*`, dashboard, TUI, sidecars):**
- Add `Turn_requested`, `Turn_accepted`, `Turn_waiting`, `Turn_phase_changed`, `Tool_call_started`, `Tool_call_finished`, `Content_block`, `Turn_finished`, `Turn_failed`, and `Poll_snapshot` equivalents to the MASC connector event stream.
- Use `Ids.Turn_ref` / RFC-0233 §7 as the single cross-surface turn identity; expose it as the connector `turn_id` string and keep raw `keeper_turn_id` as an internal numeric field only where needed.
- Emit events from the runtime boundary once, then project them into AG-UI/SSE, channel gate responses, Discord, Slack, Telegram, iMessage, CLI, TUI, and Dashboard.
- Stop dropping rich blocks in the SSE adapter; serialize them as AG-UI `Custom` payloads until AG-UI-native block support exists.
- Publish `Tool_context_block` / `Tool_call_finished` when a tool call finishes, with a concise redacted summary.
- Add a polling endpoint keyed by `request_id` for sidecars that cannot hold a stream open.
- Add per-channel transient progress behavior: Discord/Slack update messages when possible; Telegram/iMessage send short progress messages; CLI/TUI render a status line.
- Ensure every final connector response carries a stable `turn_id` or `request_id` so retries, failure reports, and follow-up polls can be correlated.

---

### 5.9 OAS boundary and MASC response facade

**Finding:** The current MASC/OAS bridge makes it easy to collapse a provider response into plain text before connector renderers can use structured content. That is a MASC facade problem first. OAS already owns generic provider/model transport, Agent lifecycle, hooks, and tool-use surfaces; it must not grow keeper, board, fusion, connector, live runtime, or dashboard semantics just to satisfy MASC rendering.

**MASC-first improvements:**
- Extend `Agent_sdk_response` facade with MASC-local helpers that preserve the provider response shape available today, while still exposing `text_of_response` as fallback.
- Carry `response_blocks : chat_block list` alongside `response_text` through `keeper_turn.ml` and `keeper_agent_run_response_text.ml`.
- Convert generic OAS content blocks into MASC `chat_block` values at the MASC boundary; never expose `chat_block` back into OAS.
- Store MASC connector artifacts in the MASC blob/artifact store and emit URL-bearing blocks for connectors that can render or link them.
- Add `User_video` / file attachment support in MASC input plumbing only after the provider-generic OAS block exists.

**Optional OAS upstream follow-up, separate from this MASC design:**
- Add provider-neutral helpers such as `fold_content_blocks`, `markdown_of_content`, and `markdown_of_response`.
- Add a generic `Video` content block variant if the provider matrix needs it.
- Persist generic structured tool-result envelopes (`{ content; json; content_blocks }`) only if useful outside MASC.

**Non-goal:** OAS must not know MASC keeper phases, channel gates, board posts, fusion panels, dashboard URLs, or `<base-path>/.masc` runtime layout.

---

### 5.10 Inbound / outbound file format support

**Finding:** Gate `inbound_message` only carries a `content` string, so external photos/files/voice cannot become multimodal user blocks. Outbound `structured` blocks are unused by every connector. Dashboard attachment whitelist excludes SVG, PDF, HTML, source-code files, and video.

**Improvements:**
- Extend `Gate_protocol.inbound_message` with `attachments` and `user_blocks`; update `Channel_gate` validation and `Gate_keeper_backend.dispatch` in `lib/gate_keeper_backend.ml`.
- Parse attachment metadata in Discord gateway, Slack events, Telegram messages, and iMessage bridge; download bytes and forward as data URLs or blob-store refs.
- Populate `GateResponse.structured` in `lib/gate_keeper_backend.ml` with parsed `ChatBlock[]`.
- Add a connector capability manifest and fallback policy (see §6).
- Expand dashboard whitelist: add SVG, PDF, HTML, common code MIMEs; add a video bucket with strict size limits; reject archives with a clear message.

---

## 6. Unified Capability Manifest & Fallback Policy

Proposed per-connector declaration:

```text
turn_start        : { none | message | slash_command | api }
turn_ack          : { none | transient | reply | update }
turn_progress     : { none | text | update | stream }
turn_poll         : bool
turn_correlation  : { none | request_id | turn_id }
text_plain        : always
text_markdown     : { none | basic | full }
code_blocks       : { none | inline | fenced }
tables            : { none | ascii | native }
lists             : bool
callouts          : { none | quote | native }
images            : { none | url_unfurl | upload }
svg               : { none | inline_html | upload | link }
mermaid           : { none | rendered_image | link }
audio             : { none | upload | link }
video             : { none | upload | link }
documents         : { none | upload | link }
attachments_in    : bool
attachments_out   : bool
max_chars         : int
max_blocks        : int option
supports_edit     : bool
supports_thread   : bool
```

Fallback order:
1. **Native lifecycle projection** if declared (`stream`, message update, thread reply, or poll snapshot).
2. **Native rich render** if declared.
3. **Markdown / ASCII approximation** (e.g., table → fenced code block, callout → `> **NOTE:** ...`).
4. **Blob + link** for binary content: upload to MASC blob/artifact store, send dashboard URL.
5. **Text summary** when all else fails.
6. **Metric + log** every downgrade or drop (`Channel_gate_metrics`).

A new module `lib/gate/connector_capabilities.ml` (or `config/connector-formats.toml`) owns the SSOT for each connector’s capabilities.

---

## 7. Implementation Priority

### P0 — Runtime safety and visible state
1. Add the MASC-owned turn surface event envelope (`request_id`, RFC-0233 `Turn_ref` as `turn_id`, phase, progress, final status).
2. Stop dropping rich blocks in SSE/AG-UI projection; unknown blocks must become escaped fallback blocks.
3. Add connector capability manifest and downgrade/drop telemetry.
4. Enforce connector size limits before send (Discord, Slack, Telegram, iMessage).
5. Unify Dashboard SVG sanitization and restrict link/blob schemes.
6. Escape shell/tool output as plain text instead of sanitizing.

### P1 — MASC structural parity
7. Extend `keeper_chat_blocks` with `Code | Table | List | Callout | Mermaid | Svg | Video | Audio`.
8. Carry `response_blocks` alongside `response_text` through keeper reply paths.
9. Extend `Gate_protocol.inbound_message` with attachments/user_blocks and plumb through to `keeper_multimodal_input`.
10. Add sidecar polling by `request_id` for channels that cannot stream.
11. Fix TUI width math (`display_width`, `strip_ansi`) so lifecycle/status output is legible with CJK/emoji.

### P2 — Connector enrichment
12. Implement Markdown-aware chunking in Discord; add multipart upload for audio/video/files.
13. Build unified Slack Block Kit mapping for the full block vocabulary and progress updates.
14. Teach Telegram sidecar HTML/MarkdownV2 + photo/document/audio dispatch.
15. Add iMessage file-sending, length guards, and plain-text markdown conversion.
16. Add CLI ANSI markdown renderer and terminal image protocols.
17. Add TUI block renderers and SSE/poll progress.

### P3 — Board, artifacts, and observability
18. Render board attachment meta in Dashboard; add `Board_render` shared contract.
19. Expand Dashboard attachment whitelist and add video handling with strict size limits.
20. Add runtime health/dashboard evidence showing connector capability config loaded from the live runtime.

### P4 — Optional OAS generic upstream
21. Add provider-neutral OAS helpers only after the MASC boundary proves which generic blocks are actually missing.
22. Keep OAS changes in a separate PR and separate validation path.

---

## 8. Adversarial Test Plan

Create fixtures under `test/fixtures/rich_content/`:

| Fixture | Purpose |
|---|---|
| `full_markdown.md` | Headings, lists, code, table, callout, mermaid, image, link |
| `long_code_fence.md` | 3000-char code block crossing chunk boundaries |
| `truncated_fence.md` | Unclosed code fence and unmatched backticks |
| `xss_payload.md` | `<script>`, `javascript:`, onerror SVG, malformed `data:` |
| `slack_metacharacters.md` | `<@U123>`, `&`, `*bold*` |
| `fusion_ref.json` | Fusion block with valid/missing/expired `board_post_id` |
| `tool_image_result.json` | Tool result containing an OAS `Image` block |
| `attachments.json` | Image data URL, audio data URL, 11 MB file, `.mov` |
| `turn_lifecycle.jsonl` | Requested, accepted, waiting, progress, tool, finished, failed, and poll snapshot events |
| `connector_capabilities.toml` | Per-connector lifecycle/render limits and downgrade expectations |

Add tests:
- `test_keeper_chat_blocks.ml` — parse code/table/callout blocks.
- `test_keeper_chat_events.ml` — turn lifecycle event JSON round-trip and stable `request_id`/RFC-0233 `Turn_ref` correlation.
- `test_keeper_chat_discord.ml` — chunk boundary preserves code fences; embed budget splits messages.
- `test_keeper_chat_slack.ml` — inline image → Block Kit image block; mrkdwn escape; long reply chunks.
- `test_channel_gate_metrics.ml` — every unsupported block emits a downgrade/drop metric.
- `test_gate_keeper_backend.ml` — `GateResponse.structured` includes final blocks and correlation ids.
- `sidecars/telegram-bot/tests/test_formatters.py` — MarkdownV2 escape; scalar-aware chunking.
- `sidecars/slack-bot/tests/test_formatters.py` — chunking preserves code fences.
- `sidecars/shared/tests/test_gate_response.py` — structured event/poll payload parsing remains backward-compatible.
- `dashboard/src/components/chat/markdown-blocks.test.ts` — ordered list, empty table header, unmatched backticks.
- `dashboard/src/components/common/markdown-renderer.test.ts` — XSS sanitization, fence repair correctness.
- `dashboard/src/components/chat/attachments.test.ts` — video rejection, audio metadata.

Acceptance criteria:
- Every connector final response includes a stable `request_id` or RFC-0233 `Turn_ref`-derived `turn_id`.
- Waiting/polling flows can report progress without inventing connector-local state.
- No silent truncation; truncation is chunked or visibly marked.
- Code fences are never split without fence repair.
- XSS payloads are sanitized before DOM insertion.
- Provider limits (Discord 2000/10 embeds, Slack 4000/50 blocks, Telegram 4096) are explicitly tested and never violated.
- Tool results containing generic OAS image blocks render in MASC surfaces without adding MASC concepts to OAS.
- Unsupported blocks produce a visible fallback plus a metric/log entry.

---

## 9. Files to Modify (high-level)

### MASC OCaml
- `lib/keeper/keeper_chat_blocks.ml{,i}`
- `lib/keeper/keeper_chat_events.ml{,i}`
- `lib/keeper/keeper_chat_discord.ml`
- `lib/keeper/keeper_chat_slack.ml`
- `lib/gate/discord_rest_client.ml`
- `lib/gate/connector_capabilities.ml{,i}` or `config/connector-formats.toml`
- `lib/gate/gate_protocol.ml{,i}`
- `lib/gate/channel_gate.ml`
- `lib/gate/channel_gate_*_state.ml{,i}`
- `lib/gate/channel_gate_metrics.ml{,i}`
- `lib/gate/channel_gate_connector.ml{,i}`
- `lib/gate_keeper_backend.ml`
- `lib/keeper/keeper_multimodal_input.ml{,i}`
- `lib/agent_sdk_response.ml{,i}`
- `lib/keeper/keeper_turn.ml`
- `lib/keeper/keeper_agent_run_response_text.ml`
- `lib/server/server_routes_http_keeper_stream.ml`
- `lib/ag_ui/ag_ui.ml`
- `lib/board/board_attachment_meta.ml{,i}`
- `lib/board/board_core.ml`, `board_core_persist.ml`, `board_dispatch.ml`
- `bin/masc_tui_ansi.ml`, `bin/masc_tui_render.ml`, `bin/masc_tui.ml`
- `lib/workspace_status_rendering.ml`

### MASC Python sidecars
- `sidecars/shared/gate_shared/gate_response.py`
- `sidecars/shared/gate_shared/gate_client_base.py`
- `sidecars/slack-bot/src/formatters.py`, `bot.py`
- `sidecars/telegram-bot/src/formatters.py`, `bot.py`
- `sidecars/imessage-bot/src/bot.py`, `imessage_bridge.py`
- `sidecars/cli-connector/src/bot.py`

### MASC Dashboard
- `dashboard/src/components/chat/markdown-blocks.ts`
- `dashboard/src/components/chat/primitives.ts`
- `dashboard/src/components/chat/artifact-panel.ts`
- `dashboard/src/components/chat/attachments.ts`
- `dashboard/src/components/common/markdown-renderer.ts`
- `dashboard/src/components/common/rich-content.ts`
- `dashboard/src/components/common/rich-content-utils.ts`
- `dashboard/src/lib/dompurify.ts`
- `dashboard/src/components/board/board-surface.ts`
- `dashboard/src/components/board/post-detail.ts`
- `dashboard/src/api/schemas/keeper-chat-history.ts`
- Dashboard API schemas for gate responses, poll snapshots, and turn lifecycle events.

### Optional OAS generic follow-up, separate PR
- `lib/llm_provider/types.ml`
- `lib/llm_provider/api_common.ml`
- `lib/tool_result_store.ml`

---

## 10. Boundary Checklist

- [ ] No keeper phase, board semantics, fusion concept, or connector policy is added to OAS.
- [ ] OAS changes, if any, are limited to generic multimodal blocks, content folding, and structured tool-result storage that are useful outside MASC.
- [ ] MASC connector event names, `request_id`, RFC-0233 `Turn_ref`-derived `turn_id`, polling, sidecar progress, and live runtime paths remain in MASC.
- [ ] All connector-specific rendering stays under `masc/lib/keeper`, `masc/lib/gate`, `masc/sidecars`, `masc/dashboard`, and `masc/bin`.
- [ ] The shared block schema is owned by MASC; OAS continues to use its own `content_block` sum.
- [ ] Live runtime claims are checked against `<base-path>/.masc` before being described as deployed.
- [ ] Fallback text is present for every rich block and lifecycle event that a connector cannot render.
