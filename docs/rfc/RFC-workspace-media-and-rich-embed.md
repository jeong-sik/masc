---
rfc: "workspace-media-and-rich-embed"
title: "Typed Rich Embeds, Wiki/Artifact Media References, and Attachment GC Coverage"
status: Draft
created: 2026-11-27
updated: 2026-11-28
author: jeong-sik
related: []
---

# RFC workspace-media-and-rich-embed: Typed Rich Embeds, Wiki/Artifact Media References, and Attachment GC Coverage

- Code coordinates audited against `origin/main` (`bc42773a8734a`), building directly on PR #55194 (`Attachment_store` under `.masc/attachments/`, `POST/GET/HEAD /api/v1/attachments`, `/api/v1/media/<id>` delegation, and `Tool_blob_sweep.sweep_attachments`).
- Governance: obeys `docs/constitution.xml` (`closed_sum_over_string`, `strict_parse_no_default`, `no_wall_clock_death`, `legacy_residue`, `effects`, `types`, `hardcoded_path`, `work_unit`).
- Scope: design and wire contract only. Implementation lands in the 4-layer Native GitHub Stack in §7.

## 0. Summary

PR #55194 unified workspace binary attachment storage under `Attachment_store` (`<base_path>/.masc/attachments/`, canonical URL `/api/v1/attachments/att_<64hex>`, with legacy `/api/v1/media/<64hex>` read fallback), added `POST/GET/HEAD /api/v1/attachments`, wired `<AttachmentComposer>`/`<AttachmentGallery>` into Keeper Chat and Board, and added `Tool_blob_sweep.sweep_attachments`.

Four concrete gaps remain across Wiki, Published Artifacts, Tasks, Markdown rendering, and attachment GC reachability:

1. **Wiki, Tasks, Goals, and Published Artifact bodies are invisible to attachment GC**: `Server_tool_blob_scope.workspace` marks `wiki_dirname`, `tasks_dirname`, and `goals_filename` as `Writes_no_reference`, and `Published_artifact_store` JSON only stores `Tool_blob_store` `body.sha256` digests rather than body text. An attachment referenced only in a Wiki page, Task description, Goal, or Published Artifact body is treated as unreferenced and deleted by `Tool_blob_sweep.sweep_attachments` after the grace window.
2. **Wiki and Published Artifacts do not parse or lint media and rich embeds**: `Wiki_link` skips `![alt](...)` and marks `[[...]]` as `Unsupported`, so `![[wiki:<slug>]]`, `![[artifact:<id>]]`, `![[media:<id>]]`, and `![alt](/api/v1/attachments/att_<64hex>)` have no typed representation, no backlink accounting, no broken-embed lint findings, and no `media_refs` projection.
3. **Markdown rendering fires unauthenticated 401 image requests and lacks rich embeds, lightbox, and sandboxed HTML artifact hydration**: `MarkdownContent` inserts raw `<img src="/api/v1/attachments/...">` before `useEffect` swaps the blob URL (firing a 401 in single-user Bearer mode), has no LRU `objectURL` cache or click-to-zoom lightbox, does not render `![[wiki:<slug>]]`/`![[artifact:<id>]]` cards, and `ArtifactsTab` renders `<iframe sandbox="" srcDoc={doc.content}>` whose opaque origin cannot load `/api/v1/attachments/*` or `/api/v1/media/*`.
4. **Wiki and Tasks lack Markdown authoring UX, and `wiki-tab.test.ts` races lazy chunk loading**: `WikiTab` has only a plain `<textarea>` (no split live preview, no Quick Embed Picker, no paste/drop image upload), `TasksTab` has no inline Markdown image paste/drop upload, and `wiki-tab.test.ts` mounts `<KnowledgeWorkspace subroute="wiki">` without awaiting `preloadKnowledgeSubroute('wiki')`.

This RFC specifies a single non-duplicating layer stack on top of `Attachment_store` (`/api/v1/attachments`) — introducing zero competing media stores, zero duplicate upload endpoints, and leaving `BoardTab`'s #55194 attachment UI intact.

## 1. Current State and Concrete Defects (`bc42773a8734a`)

| Area | Source Coordinate | Concrete Defect |
|---|---|---|
| Attachment GC blind spots | `lib/server/server_tool_blob_scope.ml:89,112,142,149`, `lib/tool_blob_store/tool_blob_sweep.ml:815-845` | `wiki_dirname`, `tasks_dirname`, and `goals_filename` are `Writes_no_reference` (skipped by `consumer_paths`), and `Published_artifact_store` JSON only holds `body.sha256` pointing into `Tool_blob_store`. `sweep_attachments` can delete live attachments referenced only by Wiki, Tasks, Goals, or Published Artifact bodies. |
| Wiki ignores media and embeds | `lib/wiki_link.ml`, `lib/wiki_lint.ml`, `lib/wiki_graph.ml` | `![alt](...)` is skipped unconditionally; `![[...]]` is not parsed into typed embeds; `Wiki_lint` cannot report broken media, wiki, or artifact embeds; transcluded pages are misclassified as orphans. |
| Artifact media projection | `lib/published_artifact.{ml,mli}`, `lib/published_artifact_store.{ml,mli}`, `lib/server/server_routes_http_routes_published_artifacts.ml` | No pure `media_refs` extractor for Markdown/HTML artifact bodies and no typed `(bool, error) result` existence check for `Wiki_lint`. |
| Markdown 401 flash & missing embeds/lightbox | `dashboard/src/components/common/markdown-renderer.ts:183-231` | Renders raw `<img src="/api/v1/attachments/...">` into `innerHTML` before `useEffect` hydrates it (causing a 401 in single-user Bearer mode), creates uncached per-mount blob URLs, has no lightbox, and does not render `![[wiki:...]]` or `![[artifact:...]]`. |
| Sandboxed HTML artifacts cannot render workspace images | `dashboard/src/workspaces/knowledge/artifacts-tab.ts` | `<iframe sandbox="" srcDoc={doc.content}>` has an opaque origin that cannot resolve relative `/api/v1/attachments/*` or `/api/v1/media/*` URLs or attach auth headers. |
| Wiki/Tasks authoring friction & test race | `dashboard/src/workspaces/knowledge/wiki-tab.ts`, `dashboard/src/workspaces/work/tasks-tab.ts`, `dashboard/src/workspaces/knowledge/wiki-tab.test.ts` | Wiki editor lacks split live preview, Quick Embed Picker, and paste/drop upload; Tasks description lacks inline paste/drop upload; `wiki-tab.test.ts` does not call `preloadKnowledgeSubroute('wiki')` in `beforeAll`, racing `<Suspense fallback={null}>` against cold Vite transforms. |

## 2. Constitution Invariant Alignment

| Constitution Rule | How This Design Enforces It |
|---|---|
| `closed_sum_over_string` | `embed_kind`, `embed_target`, `embed_syntax`, new `Wiki_lint.finding` constructors, and new `Tool_blob_maintenance` classification constructors (`Attachment_references_only`, `Tree_with_blob_bodies`) are closed OCaml variants. |
| `strict_parse_no_default` | `Media_ref_scan` and `Wiki_link` accept only exact canonical `att_<64hex>` / legacy `<64hex>` tokens, valid wiki slugs, and valid `artifact-<32hex>` IDs; invalid or unknown schemes produce explicit `Invalid_embed` / `Unsupported_embed`. |
| `no_wall_clock_death` | Extends `Tool_blob_sweep.scan_attachment_reachability` fail-closed across Wiki, Tasks, Goals, and Published Artifact `Tool_blob_store` bodies so live attachments are never reaped after the grace window. |
| `legacy_residue` | Reuses #55194's `Attachment_store`, `/api/v1/attachments`, `dashboard/src/api/attachments.ts`, and `BoardTab`'s `<AttachmentComposer>` instead of adding a parallel `.masc/media` upload store or duplicate frontend upload client. |
| `effects` | `Media_ref_scan`, `Wiki_link.extract_embeds`, `Wiki_lint.run` (parameterized by `media_exists`/`artifact_exists`), and `Published_artifact.extract_media_refs` are pure; filesystem I/O remains at server/store edges. |
| `work_unit` | Split into 4 strictly disjoint linear Native GitHub Stack layers (§7). |

## 3. Canonical Media Address Compatibility & Unified Reference Rules

- **Primary canonical write address**: `/api/v1/attachments/att_<64hex>` (`Attachment_store.url_prefix ^ Attachment_store.id_prefix ^ sha256`), emitted by Dashboard uploads (`uploadAttachment`) and Keeper authoring tools.
- **Read, scan, and lint compatibility**:
  - `Media_ref_scan` and `Wiki_link` accept both:
    - `/api/v1/attachments/att_<64hex>` (with optional query parameters such as `?max_px=640`, stripped before token validation),
    - legacy `/api/v1/media/<64hex>` and `/api/v1/media/att_<64hex>`,
    - Obsidian `![[media:att_<64hex>|caption]]` and `![[media:<64hex>|caption]]`.
  - Normalized internal token for `Media_embed`, `media_refs`, and existence lookup is the bare 64-character lowercase hexadecimal SHA-256 (`Attachment_store.parse_id_or_sha256`).
  - Media existence at the server/tool edge checks `Attachment_store.get_meta_by_sha256` first and falls back to `Keeper_chat_media_store.file_path_of_token` only when absent, matching `server_routes_http_routes_voice.ml`.

## 4. Attachment GC Reachability Coverage (`Tool_blob_maintenance`, `Tool_blob_sweep`, `Server_tool_blob_scope`)

- **Problem**: `Tool_blob_maintenance` JSON-parses `In_scope Tree` directories for tool-blob markers, so plain Markdown directories (`wiki/`) cannot be `In_scope Tree`. Conversely, `Published_artifact_store` JSON files under `.masc/published_artifacts/` only hold `body.sha256` pointing to `Tool_blob_store`, so scanning the JSON alone never sees `att_<64hex>` inside the Markdown/HTML artifact body.
- **Typed Scope Extension**:
  - Add `Attachment_references_only` to `Tool_blob_maintenance.exclusion`: excluded from JSON tool-blob scanning (zero change to tool-blob parsing), included in `Tool_blob_maintenance.attachment_consumer_paths`.
  - Add `Tree_with_blob_bodies` to `Tool_blob_maintenance.source`: identical to `Tree` for tool-blob reference collection, and additionally exposed via `Tool_blob_maintenance.blob_body_consumer_paths` so `Tool_blob_sweep.scan_attachment_reachability` dereferences every referenced `Tool_blob_store` blob under those trees and scans its bytes with `Attachment_store.referenced_sha256_of_json_text`.
  - Any unreadable file or missing/corrupt `Tool_blob_store` body referenced by a `Tree_with_blob_bodies` record returns `Error` from `scan_attachment_reachability` (fail-closed: `sweep_attachments` deletes nothing).
- **Server Scope Mapping (`Server_tool_blob_scope.workspace`)**:
  - `Published_artifact_store.dirname` -> `In_scope Tree_with_blob_bodies`
  - `Config_dir_resolver.wiki_dirname` -> `Excluded Attachment_references_only`
  - `Workspace_utils_paths_backend.tasks_dirname` -> `Excluded Attachment_references_only`
  - `Goal_store.goals_filename` -> `Excluded Attachment_references_only`

## 5. Unified Typed Embed Grammar, Wiki & Published Artifacts

### 5.1 Grammar (OCaml and Dashboard SSOT)

All embed forms are skipped inside fenced code blocks (backtick or tilde fences) and inline code spans.

- **Canonical authoring syntax**:
  - Markdown image upload: `![caption](/api/v1/attachments/att_<64hex>)`
  - Media embed: `![[media:att_<64hex>]]` or `![[media:att_<64hex>|caption]]` (legacy bare `<64hex>` also accepted)
  - Wiki embed: `![[wiki:<slug>]]` or `![[wiki:<slug>|label]]` (bare `![[<slug>|label]]` accepted when no `:` is present)
  - Artifact embed: `![[artifact:<id>]]` or `![[artifact:<id>|label]]`
- **Strict parsing rules** (optional label splits on the first `|`, trimmed; empty label becomes `None`):
  1. `![[media:<raw>]]` -> `Media_embed sha256` if `Attachment_store.parse_id_or_sha256 raw = Ok sha256`, else `Invalid_embed { kind = Embed_media; raw }`.
  2. `![[wiki:<raw>]]` or bare `![[<raw>]]` -> `Wiki_embed slug` if `Wiki_page_name.validate_page_name raw = Ok slug`, else `Invalid_embed { kind = Embed_wiki; raw }`.
  3. `![[artifact:<raw>]]` -> `Artifact_embed id` if `Published_artifact.valid_id raw` (`^artifact-[0-9a-f]{32}$`), else `Invalid_embed { kind = Embed_artifact; raw }`.
  4. `![[<scheme>:<raw>]]` for any other `<scheme>` -> `Unsupported_embed { scheme; raw }`.
  5. `![alt](/api/v1/attachments/<raw>)` or `![alt](/api/v1/media/<raw>)` -> `Media_embed sha256` (syntax `Markdown_media`, label from trimmed non-empty `alt`) when `raw` (before optional `?query`) passes `parse_id_or_sha256`, else `Invalid_embed { kind = Embed_media; raw }`. Non-workspace `![alt](...)` remains ignored by the wiki link/embed graph.

### 5.2 OCaml Types (`Media_ref_scan`, `Wiki_link`, `Wiki_graph`, `Wiki_lint`, `Published_artifact`)

- Cycle-free leaf scanner `lib/media_ref_scan.{ml,mli}` shared by `Wiki_link` and `Published_artifact`:
  - Provides Markdown fence/code-span blanking, Obsidian embed splitting, and HTML comment + `<script>` blanking (preserving `<style>` CSS `url(...)`).
  - Extracts normalized 64-hex SHA-256 tokens from `/api/v1/attachments/att_<64hex>` (with optional query), `/api/v1/media/<64hex>` (or `att_<64hex>`), and `![[media:...]]`.
- `Wiki_link`:
  - `Wiki_link.extract` skips `![[...]]` so existing `outgoing_links` stays within the 9 closed kinds decoded by `lib/masc_tui/protocol/wire_knowledge.ml`.
  - Adds `embed_kind`, `embed_target`, `embed_syntax`, `embed`, and `extract_embeds : string -> embed list`.
- `Wiki_graph`:
  - Stores `embeds` per readable page and counts `Wiki_embed slug` alongside `Page slug` in `incoming` (excluding self-embeds) so transcluded pages are not flagged as `Orphan`.
- `Wiki_lint`:
  - Adds `Broken_media_embed`, `Broken_wiki_embed`, `Broken_artifact_embed`, `Invalid_embed`, and `Unsupported_embed` to `Wiki_lint.finding`, updating `Wiki_lint_report` and `config/tools/masc_wiki_lint.toml` in lockstep.
  - Parameterized by pure `?media_exists:(string -> bool)` and `?artifact_exists:(string -> (bool, string) result)` so store I/O errors are never misreported as `Broken_artifact_embed`.
- `Published_artifact` & `Published_artifact_store`:
  - Keeps `Published_artifact.revision` disk fields unchanged.
  - Adds `Published_artifact.extract_media_refs : format -> string -> string list` and `Published_artifact_store.exists : base_path:string -> id:string -> (bool, error) result`.
  - `GET /api/v1/wiki/:slug` adds additive `"embeds"` and `"media_refs"`; `GET /api/v1/published-artifacts/:id` adds additive `"media_refs"`.
  - Keeper tools (`masc_wiki_create`, `masc_wiki_update`, `keeper_artifact_publish`) document `/api/v1/attachments/att_<64hex>` and `![[...]]` syntax and return `"media_refs"` and `"missing_media_refs"`.

## 6. Dashboard Runtime, Safe `sandbox=""` Hydration & Authoring UX

### 6.1 Shared LRU Media Cache (`dashboard/src/lib/workspace-media-cache.ts`)

- Delegates authenticated binary fetching directly to #55194's `fetchAttachmentBlob` (`dashboard/src/api/attachments.ts`) — zero duplicate auth/CSRF/workspace-URL transport code.
- Scoped by `sessionEpoch` (`${epoch}:${path}`), deduplicating concurrent fetches and revoking prior-epoch `blob:` URLs on epoch bump.
- Byte-bounded LRU (64 MiB / 128 entries) with ref-counted `acquireObjectUrl` and on-demand `acquireDataUrl` (for sandboxed HTML artifacts only, never cached in the primary LRU).
- `WorkspaceChatImage` (`dashboard/src/components/chat/workspace-image.ts`) migrates onto `workspace-media-cache.ts` for shared caching across chat remounts while preserving `#55194`'s `?max_px=` thumbnails and lightbox behavior.

### 6.2 Zero-401 `MarkdownContent` & Rich Embed Runtime (`markdown-renderer.ts`, `markdown-embed-runtime.ts`, `markdown-embeds.css`)

- Preserves `FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form']` and `ALLOW_DATA_ATTR: false`, allowlisting only `data-masc-media-src`, `data-masc-media-alt`, `data-masc-embed-kind`, `data-masc-embed-target`, `data-masc-embed-label`.
- Replaces #55194's raw `<img src="/api/v1/attachments/...">` DOM mount with `<span class="masc-media-slot" data-masc-media-src="...">` placeholders (both in the Marked `image` renderer and in the inert `<template>` normalizer for raw HTML `<img>` tags), eliminating unauthenticated 401 requests in single-user Bearer mode.
- Hydrates visible slots via `IntersectionObserver` (`rootMargin: '200px'`) + `workspace-media-cache.ts` (`?max_px=640` for inline preview, full resolution on click-to-zoom `MarkdownImageLightbox` backed by `components/common/dialog.ts`, removing `dialog.ts` from `dashboard/scripts/check-unreached-modules.mjs` `PENDING`).
- Parses `![[media:...]]`, `![[wiki:<slug>|label]]`, `![[<slug>|label]]`, and `![[artifact:<id>|label]]` outside code fences/spans, hydrating live Wiki and Artifact embed cards through `resourceCache.fetch` (`ttlMs: 15_000`, invalidated by `'wiki'`/`'wiki_updated'` and `'artifacts'`/`'artifact_published'` SSE topics) and clearing stale `.masc-embed-missing` markers on refresh.

### 6.3 Safe `sandbox=""` HTML Artifact Hydration (`artifacts-tab.ts`)

- Preserves `<iframe sandbox="" srcDoc={hydratedHtml}>` with zero sandbox relaxation.
- When `doc.content` references `/api/v1/attachments/` or `/api/v1/media/`, gates iframe mount behind a loading placeholder until inert `DOMParser` rewrites matched `img[src]` attributes to verified raster `data:` URIs (bounded at 32 unique images / 32 MiB cumulative bytes).
- Strips `src` on failed or over-budget images (`data-masc-media-unhydrated`) and preserves `<!DOCTYPE html>` so HTML5 artifacts remain in standards mode.

### 6.4 Wiki & Tasks Authoring UX (`use-workspace-media-composer.ts`, `wiki-tab.ts`, `wiki-embed-picker.ts`, `tasks-tab.ts`)

- `useWorkspaceMediaComposer` delegates uploads directly to #55194's `uploadAttachment` (`POST /api/v1/attachments`) and `validateAttachmentFile` (strictly rejecting SVG/HTML before network dispatch), inserting canonical `![alt](/api/v1/attachments/att_<sha256>)` at the cursor with synchronous `useLayoutEffect` `draftKey`/`disabled` abort fences.
- `WikiTab`: split / write / preview live Markdown editor (150ms debounced), save blocked while uploads are in flight, right-aligned `WikiEmbedPicker` over unfiltered Wiki pages (with `+N건 더 있음` outside `role="list"` beyond 40 items) and shared `kn:artifacts:list` fetcher.
- `TasksTab`: inline Markdown paste/drop/picker image upload wired into task description creation/editing.
- `BoardTab`: untouched (retains #55194's `<AttachmentComposer>` and `<AttachmentGallery>` without duplicate upload UX).
- `wiki-tab.test.ts`: adds `beforeAll(() => preloadKnowledgeSubroute('wiki'))` matching `knowledge.test.ts`, eliminating the cold dynamic-import `<Suspense>` race.

## 7. Native GitHub Stack Plan & Verification

All changes land as one linear 4-layer Native GitHub Stack off `main` (`bc42773a8734a`) with zero file overlap across layers:

| Layer | Branch | Owned Files | Verification Gate |
|---|---|---|---|
| L1 | `rfc/rich-embed-wiki-artifact-media` | `docs/rfc/RFC-workspace-media-and-rich-embed.md` | `python3 scripts/rfc-generate-index.py --check` |
| L2 | `feat/wiki-artifact-rich-embed-core` | `lib/media_ref_scan.{ml,mli}`, `lib/wiki_link.{ml,mli}`, `lib/wiki_graph.{ml,mli}`, `lib/wiki_lint.{ml,mli}`, `lib/wiki_lint_report.ml`, `lib/published_artifact.{ml,mli}`, `lib/published_artifact_store.{ml,mli}`, `lib/tool_blob_store/tool_blob_maintenance.{ml,mli}`, `lib/tool_blob_store/tool_blob_sweep.ml`, `lib/server/server_tool_blob_scope.ml`, `lib/server/server_dashboard_http_wiki.ml`, `lib/server/server_routes_http_routes_published_artifacts.ml`, `lib/tool_wiki.ml`, `lib/keeper/keeper_artifact_publish.ml`, `config/tools/*.toml`, OCaml unit tests | PR `type-check` (`dune build @check`), targeted `test.yml` runtime verification |
| L3 | `feat/dashboard-rich-embed-runtime-v2` | `dashboard/src/lib/keeper-media.ts`, `dashboard/src/lib/workspace-media-cache.{ts,test.ts}`, `dashboard/src/components/chat/workspace-image.{ts,test.ts}`, `dashboard/src/components/common/markdown-renderer.{ts,test.ts,a11y.test.ts}`, `dashboard/src/components/common/markdown-embed-runtime.ts`, `dashboard/src/components/common/markdown-embeds.css`, `dashboard/src/components/common/rich-code-preview.ts`, `dashboard/src/workspaces/knowledge/artifacts-tab.{ts,test.ts}`, `dashboard/scripts/check-unreached-modules.mjs` | `pnpm typecheck`, `pnpm lint`, `node scripts/check-unreached-modules.mjs`, Vitest suites, PR `dashboard` CI |
| L4 | `feat/dashboard-wiki-tasks-media-ux` | `dashboard/src/lib/use-workspace-media-composer.{ts,test.ts}`, `dashboard/src/workspaces/knowledge/wiki-embed-picker.{ts,test.ts}`, `dashboard/src/workspaces/knowledge/wiki-editor.css`, `dashboard/src/workspaces/knowledge/wiki-tab.{ts,test.ts}`, `dashboard/src/workspaces/knowledge/wiki-tab-media.test.ts`, `dashboard/src/workspaces/work/tasks-tab.ts` | `pnpm typecheck`, `pnpm lint`, `node scripts/check-unreached-modules.mjs`, Vitest suites (`wiki-tab.test.ts` standalone + `workspaces/knowledge/`), PR `dashboard` CI |
