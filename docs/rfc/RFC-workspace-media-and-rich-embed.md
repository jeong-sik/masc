---
rfc: "workspace-media-and-rich-embed"
title: "Unified Workspace Media Store and Typed Rich Embeds"
status: Draft
created: 2026-11-27
updated: 2026-11-27
author: masc-media-arch
related: []
---

# RFC workspace-media-and-rich-embed: Unified Workspace Media Store and Typed Rich Embeds

- Code coordinates audited against `origin/main` (`a8a00684072d1`).
- Governance: obeys every invariant in `docs/constitution.xml` (`closed_sum_over_string`, `strict_parse_no_default`, `no_wall_clock_death`, `legacy_residue`, `effects`, `types`, `hardcoded_path`, `work_unit`).
- Scope: design and wire SSOT only. Implementation lands in the 5-layer Native GitHub Stack specified in §8.

## 0. Summary

MASC currently treats workspace images as an ad-hoc chat-only byproduct. Model-generated images land in `<base_path>/.masc/media/` without magic-byte verification, disappear after 24 hours regardless of references, fail to load inside Markdown and sandboxed HTML artifacts, and cannot be uploaded from the Dashboard or embedded across Wiki pages and Published Artifacts.

This RFC establishes one unified contract across OCaml server, Wiki/Artifact domain logic, reference-aware GC, and the Preact Dashboard:

1. **One canonical workspace media address**: `/api/v1/media/<sha256>`, where `<sha256>` is the 64-character lowercase hexadecimal SHA-256 digest of the raw payload bytes, stored atomically at `<base_path>/.masc/media/<sha256>.<ext>`.
2. **Strict closed MIME types and magic-byte verification**: closed `raster_mime` (`Image_png | Image_jpeg | Image_gif | Image_webp`) and `media_mime` sum types with real magic-byte sniffing, zero `.bin`/`Other` silent fallback, pure OCaml image dimension parsing, and explicit rejection of `image/svg+xml` (`415 svg_not_allowed`).
3. **Upload and immutable-cache HTTP API with multi-account parity**: raw-binary `POST /api/v1/media` (`CanAdmin` / `Admin_only` + CSRF) and hardened `GET /api/v1/media/<sha256>` (`CanReadState` / `Workspace_read`) moved out of `server_routes_http_routes_voice.ml` into a dedicated media route module plus `server_account_dashboard_bridge.ml`, serving `ETag`, `304 Not Modified`, `Cache-Control: private, max-age=31536000, immutable`, `X-Content-Type-Options: nosniff`, and `Content-Security-Policy: default-src 'none'; sandbox`.
4. **Unified typed embed grammar**: Obsidian-style `![[media:<sha256>|caption]]`, `![[wiki:<slug>|label]]` (plus shorthand `![[<slug>|label]]`), `![[artifact:<id>|label]]`, and Markdown `![alt](/api/v1/media/<sha256>)`, parsed into closed sum types in `Wiki_link`, validated purely in `Wiki_lint`, projected in `GET /api/v1/wiki/:slug` and `GET /api/v1/published-artifacts/:id` without breaking strict TUI decoders, and supported in Keeper authoring tools without raw base64 payloads.
5. **Reference-aware media GC (`no_wall_clock_death`)**: remove blind 24-hour `mtime` deletion from persist paths, classify `.masc/media` in `Server_tool_blob_scope.workspace` so `Tool_blob_sweep` never stalls as `unclassified`, and require any deletion sweeper to run two-pass fail-closed scanning across all durable workspace roots (Chat, Keeper WALs, Multi-account homes, Wiki, Published Artifact bodies, Board posts & comments, Tasks, and Goals).
6. **High-performance Dashboard runtime and authoring UX**: replace per-mount `FileReader.readAsDataURL` with an epoch-fenced, byte-bounded LRU `URL.createObjectURL` cache (`workspace-media-cache.ts`), eliminate 401 image floods in `MarkdownContent`, hydrate `/api/v1/media/<sha256>` inside `<iframe sandbox="" srcDoc>` HTML artifacts via inert `DOMParser` without relaxing `sandbox=""`, and add paste/drop/button upload, split live preview, and a Quick Embed Picker to Wiki and `RichComposer`.

## 1. Current State and Concrete Defects (`a8a00684072d1`)

Direct inspection of `origin/main` surfaces eight structural defects:

| Area | Source Coordinate | Concrete Defect |
|---|---|---|
| Media hashing & MIME trust | `lib/keeper/keeper_chat_media_store.ml:45-112` | Trusts caller `media_type` string with zero magic-byte sniffing, falls back to `.bin` / `Other` / `application/octet-stream`, and hashes `sha256(norm_mime ^ "\000" ^ bytes)` so `"sha256"` diverges from raw content digests and `image/jpg` vs `image/jpeg` produce different tokens for identical bytes. |
| Wall-clock media destruction | `lib/keeper/keeper_chat_media_store.ml:135-192`, `lib/config/env_config_keeper.ml:540-572` | `persist_result` runs `cleanup_old_files_in_dir`, deleting files older than `retention_seconds` (default 24h) or oldest over `dir_max_bytes` (default 500 MiB) without checking references. Violates `no_wall_clock_death` and breaks Wiki/Artifact embeds after 24 hours. |
| Unclassified `.masc/media` stalls tool-blob GC | `lib/server/server_tool_blob_scope.ml:78-205` | `"media"` is absent from `Server_tool_blob_scope.workspace`. Any workspace with `.masc/media/` triggers `Tool_blob_maintenance`'s fail-closed `unclassified` gate and blocks all tool-blob reclamation. |
| Missing upload API, missing multi-account route, missing cache/security headers | `lib/server/server_routes_http_routes_voice.ml:81-108,256-269`, `lib/server/server_account_dashboard_bridge.ml:1311-1494` | No `POST /api/v1/media` endpoint exists. `GET /api/v1/media/<token>` lives in the voice module, omits `ETag`/`304`/`Cache-Control`/`nosniff`/`CSP`, uses `public_read_cors_headers` (raises on multi-`Origin`), and is completely unregistered in `server_account_dashboard_bridge.ml` (404 in multi-account mode). |
| Wiki ignores media and embeds | `lib/wiki_link.ml:15-38,115-156`, `lib/wiki_lint.ml:121-135` | `![alt](target)` is skipped unconditionally, `[[...]]` becomes `Unsupported "wikilink"`, and `/api/v1/media/<sha256>` becomes `Unsupported "path"`. Wiki lint cannot detect broken media, wiki, or artifact embeds. |
| Markdown 401 image flood | `dashboard/src/components/common/markdown-renderer.ts:12-106,140-164` | Renders raw `<img src="/api/v1/media/<sha256>">`. The browser fires an unauthenticated GET immediately (401 in single-user Bearer mode), and `linkUnloadedImages` replaces the image with a broken external link. |
| Sandboxed HTML artifacts cannot load workspace images | `dashboard/src/workspaces/knowledge/artifacts-tab.ts:386-394`, `dashboard/src/components/published-artifacts/artifacts-surface.ts:128-130` | `artifacts-tab.ts` uses `<iframe sandbox="" srcDoc={doc.content}>` (opaque origin cannot send auth headers or resolve relative `/api/v1/media/` URLs). Legacy `artifacts-surface.ts` uses `dangerouslySetInnerHTML={sanitizeHtml(doc.content)}`, losing HTML layout and failing image auth. |
| Chat image memory waste & Wiki authoring friction | `dashboard/src/components/chat/workspace-image.ts:40-104`, `dashboard/src/workspaces/knowledge/wiki-tab.ts:773-929`, `dashboard/src/components/common/rich-composer.ts:1-86` | `WorkspaceChatImage` converts every blob via `FileReader.readAsDataURL` on every mount (33%+ RAM inflation, no cache, no in-flight dedup). Wiki editor has only a bare `<textarea>` with no upload, no live preview, and no embed picker. |

## 2. Constitution Invariant Alignment

| Constitution Rule | How This Design Enforces It |
|---|---|
| `closed_sum_over_string` | `raster_mime`, `media_mime`, `upload_error`, `embed_kind`, `embed_target`, `embed_syntax`, and new `Wiki_lint.finding` constructors are closed OCaml variants; wire strings are mapped at the boundary only. |
| `strict_parse_no_default` | MIME parsers, magic-byte sniffers, and embed parsers return `option`/`result` or explicit `Invalid_embed`/`Unsupported_embed`. Zero `.bin`, `Other`, or silent slug coercion fallbacks. |
| `no_wall_clock_death` | Blind 24h `mtime` eviction is deleted from `persist_result`. Media retention is strictly reference-based via two-pass `Observe_only -> Delete_previous_candidates` GC. |
| `legacy_residue` | Legacy composite `sha256(mime ^ "\000" ^ bytes)` hashing, `.bin`/`Other` fallback arms, and `GET /api/v1/media/` inside `server_routes_http_routes_voice.ml` are deleted rather than shimmed. |
| `effects` | Magic-byte sniffing, dimension parsing, `Wiki_link.extract_embeds`, `Wiki_lint.run` (parameterized by pure `media_exists`/`artifact_exists` predicates), and `Published_artifact.extract_media_refs` are 100% pure. Filesystem and HTTP effects stay at the server/store edge. |
| `hardcoded_path` | Media files live under `Filename.concat (Common.masc_dir_from_base_path ~base_path) media_subdir`; zero absolute paths. |
| `work_unit` | Split into 5 short, strictly disjoint Native GitHub Stack layers (§8). |

## 3. Canonical Workspace Media Store & MIME Policy

### 3.1 Content Addressing & Storage Layout

- **Canonical URL**: `/api/v1/media/<sha256>` built exclusively via `Masc_network_defaults.media_path`.
- **Digest**: `<sha256>` is the 64-character lowercase hexadecimal SHA-256 digest of the **raw payload bytes** (`^[0-9a-f]{64}$`).
  - Why raw bytes instead of `SHA-256(mime ^ "\000" ^ bytes)`:
    - Response field `"sha256"` matches standard `sha256sum` and `Tool_blob_store` digests truthfully.
    - Because canonical `media_mime` is derived deterministically from magic bytes on write, identical raw bytes always resolve to the same canonical extension; no two extensions can collide on one digest.
    - Per `legacy_residue`, no migration code is maintained for pre-release composite hashes.
- **On-disk path**: `<base_path>/.masc/media/<sha256>.<ext>` written via `Fs_compat.save_file_atomic`. Readers verify regular files (`Unix.lstat` / `S_REG`) and reject symlinks and path traversal.
- **Module boundary (`Keeper_chat_media_store`)**:
  - Keep existing exported signatures `val valid_token : string -> bool` and `val file_path_of_token : base_dir:string -> token:string -> string option` intact so downstream modules (`Server_dashboard_http_wiki`, `Tool_wiki`, `Keeper_stream_media_accum`) share one store contract.
  - Export `val media_subdir : string` (`"media"`), `val media_exists : base_dir:string -> token:string -> bool`, closed MIME types, magic-byte sniffers, dimension parser, and typed `persist_raster` / `persist_media` entrypoints.

### 3.2 Closed `media_mime` Variants & Magic-Byte Sniffing

```ocaml
type raster_mime =
  | Image_png
  | Image_jpeg
  | Image_gif
  | Image_webp

type media_mime =
  | Raster of raster_mime
  | Audio_mpeg
  | Audio_wav
  | Audio_ogg
  | Audio_midi
  | Application_pdf
```

Single canonical table (one SSOT for IANA string, file extension, reload `media_category`, and `Content-Disposition`):

| Variant | Canonical IANA MIME | Accepted Declared Aliases | Ext | Magic Bytes (offset 0 unless noted) | `GET` `Content-Disposition` | Allowed on `POST /api/v1/media` |
|---|---|---|---|---|---|---|
| `Raster Image_png` | `image/png` | `image/png` | `png` | `89 50 4E 47 0D 0A 1A 0A` (8B) | `inline` | Yes |
| `Raster Image_jpeg` | `image/jpeg` | `image/jpeg`, `image/jpg` | `jpg` | `FF D8 FF` (3B) | `inline` | Yes |
| `Raster Image_gif` | `image/gif` | `image/gif` | `gif` | `GIF87a` or `GIF89a` (6B) | `inline` | Yes |
| `Raster Image_webp` | `image/webp` | `image/webp` | `webp` | `RIFF` (0..3) and `WEBP` (8..11) (12B) | `inline` | Yes |
| `Audio_mpeg` | `audio/mpeg` | `audio/mpeg`, `audio/mp3` | `mp3` | `ID3` (0..2) or valid MPEG frame sync `b0=0xFF && (b1 land 0xE0)=0xE0 && (b1 land 0x18)<>0x08 && (b1 land 0x06)<>0x00` (checked after `Raster`) | `inline` | No (model stream only) |
| `Audio_wav` | `audio/wav` | `audio/wav`, `audio/x-wav` | `wav` | `RIFF` (0..3) and `WAVE` (8..11) (12B) | `inline` | No (model stream only) |
| `Audio_ogg` | `audio/ogg` | `audio/ogg` | `ogg` | `OggS` (0..3) | `inline` | No (model stream only) |
| `Audio_midi` | `audio/midi` | `audio/midi`, `audio/x-midi` | `mid` | `MThd` (0..3) | `inline` | No (model stream only) |
| `Application_pdf` | `application/pdf` | `application/pdf` | `pdf` | `%PDF-` (0..4) | `attachment` | No (model stream only) |

Strict parsing rules:
- `raster_mime_of_string : string -> raster_mime option` and `media_mime_of_string : string -> media_mime option` strip optional `; ...` parameters, trim/lowercase the essence, and return `None` on any unknown type.
- `sniff_raster_mime : string -> raster_mime option` and `sniff_media_mime : string -> media_mime option` inspect raw payload bytes only.
- On `POST /api/v1/media`, both the declared `Content-Type` header and the sniffed bytes must agree on the same `raster_mime`. Spoofed headers (`Content-Type: image/png` with JPEG bytes) or polyglot/unknown payloads fail closed with `415`.
- On model-generated `AGENT_CORE` media (`persist_media_source_result`), declared `media_type` and sniffed bytes must both resolve to a valid `media_mime` and match; unknown types return a typed `persist_error` (`Unsupported_media_type` / `Mime_mismatch`) rather than writing `.bin`.

### 3.3 Explicit SVG Policy

- `image/svg+xml` is **explicitly disallowed** in the workspace media store.
- Why: SVG is an executable XML document (`<script>`, `<foreignObject>`, inline event handlers, external entity references). Serving arbitrary uploaded SVGs from the MASC origin creates a same-origin stored XSS surface on top-level navigation.
- Enforcement:
  - Server: `POST /api/v1/media` checks declared `image/svg+xml` AND leading XML/SVG markers (`<?xml`, `<svg` after optional UTF-8 BOM and ASCII whitespace) and rejects with `415 Unsupported Media Type` (`code: "svg_not_allowed"`).
  - Client upload (`workspace-media-upload.ts`): rejects `image/svg+xml` and `.svg` before network dispatch with an explicit Korean error message.
  - Client render (`keeper-media.ts` / `workspace-media-cache.ts`): `isWorkspaceRasterMime` accepts only `image/png`, `image/jpeg`, `image/gif`, `image/webp`.
- Diagram authoring alternative: authors and Keepers write text-first `mermaid`, `pele`, or `alphatex` fenced code blocks, which `rich-code-preview.ts` renders locally into sanitized SVG or `<img src="data:image/svg+xml,...">`.

### 3.4 Pure OCaml Header Dimension Extraction

To prevent Cumulative Layout Shift (CLS) on upload insertion and metadata inspection without adding C/native image dependencies, `parse_raster_dimensions : raster_mime -> string -> (int * int) option` parses binary headers purely:

- **PNG**: verify `"IHDR"` at bytes `12..15` (length >= 24), read big-endian uint32 `width` at `16..19`, `height` at `20..23`.
- **GIF**: length >= 10, read little-endian uint16 `width` at `6..7`, `height` at `8..9`.
- **JPEG**: walk marker segments starting at offset 2 (`0xFF` prefix, skip padding `0xFF` bytes, stop on SOS `0xDA` / EOI `0xD9` / truncated length / step cap); on SOF0..SOF3, SOF5..SOF7, SOF9..SOF11, SOF13..SOF15 with segment length >= 8, read big-endian uint16 `height` at `+5` and `width` at `+7` relative to the `0xFF <SOF>` marker pair.
- **WebP**: inspect chunk FourCC at bytes `12..15`:
  - `"VP8 "` (lossy): length >= 30, verify keyframe start code `9D 01 2A` at `23..25`, 14-bit LE `width` (`& 0x3FFF`) at `26..27`, `height` at `28..29`.
  - `"VP8L"` (lossless): length >= 25, verify signature `0x2F` at byte 20, unpack 14-bit `width = (bits & 0x3FFF) + 1`, `height = ((bits >> 14) & 0x3FFF) + 1` from bytes `21..24`.
  - `"VP8X"` (extended): length >= 30, 24-bit LE `width = u24(24..26) + 1`, `height = u24(27..29) + 1`.
- Dimensions outside `[1, 16777216]` or malformed headers return `None` (serialized as `null`).

## 4. HTTP Media API Contract

Media routes move out of `lib/server/server_routes_http_routes_voice.ml` into a dedicated `lib/server/server_routes_http_routes_media.{ml,mli}` registered in `lib/server/server_routes_http.ml`, and are mirrored in `lib/server/server_account_dashboard_bridge.ml` for multi-account deployments.

### 4.1 `POST /api/v1/media`

- **Transport**: Raw binary request body (matching `POST /api/v1/artifacts` in `server_routes_http_routes_artifacts.ml:239-265` and `POST /api/v1/voice/transcribe`, avoiding multipart parser complexity and base64 overhead).
- **Authentication**:
  - Single-user: `Server_route.Token_permission Masc_domain.CanAdmin` (`Authorization: Bearer <token>`).
  - Multi-account (`server_account_dashboard_bridge.ml`): `tier: Admin_only` (browser session cookie + `x-masc-csrf-token`, `credentials: 'same-origin'`).
  - Rationale: matches `PUT /api/v1/wiki/:slug` and `POST /api/v1/artifacts` (`CanAdmin` / `Admin_only`), keeping workspace write authority unified without introducing an unreviewed privilege tier in `server_account_dashboard_bridge.ml`.
- **Body size & truncation guard**:
  - Both single-user (`Server_routes_http_routes_media`) and multi-account (`Server_account_dashboard_bridge`) **must** read the body via `Http.Request.read_body_async_with_limit` through one shared JSON upload handler against `Env_config_keeper.KeeperGeneratedMedia.max_bytes ()` (default 10 MiB, operator ceiling 50 MiB), independent of `MASC_MAX_BODY_BYTES`.
  - **Do not** use `Server_login_http.with_body` (`lib/server/server_login_http.ml:123-134`), which answers `Too_large` and `Internal` with `text/plain` instead of structured `Cache-Control: no-store` JSON.
  - When `Content-Length` is present and `received <> declared`, refuse with `400 truncated_upload`.
- **Success Response (`201 Created`)**:
  - Headers: `Content-Type: application/json; charset=utf-8`, `Cache-Control: no-store`, `Server_auth.admitted_cors_headers request`.
  - Flat JSON envelope (idempotent content-addressed write always returns `201 Created`):
    ```json
    {
      "path": "/api/v1/media/<64-hex-sha256>",
      "sha256": "<64-hex-sha256>",
      "mime": "image/png",
      "bytes": 12345,
      "width": 800,
      "height": 600
    }
    ```
    (`width` and `height` are positive integers or `null`.)
- **Error Responses** (flat JSON `{ "error": "<human message>", "code": "<closed_code>", ... }`, `Cache-Control: no-store`):

| HTTP Status | `code` | Extra Fields | Condition |
|---|---|---|---|
| `400 Bad Request` | `empty_upload` | — | 0-byte body |
| `400 Bad Request` | `truncated_upload` | `declared_bytes`, `received_bytes` | `Content-Length` header disagrees with received body length |
| `401 Unauthorized` | (from `Server_auth` / `Auth_gate`) | — | Missing or invalid credential |
| `403 Forbidden` | (from `Server_auth` / `Auth_gate`) | — | Insufficient role or invalid/missing CSRF token |
| `413 Payload Too Large` | `media_too_large` | `max_bytes`, optional `size_bytes` | Payload exceeds `KeeperGeneratedMedia.max_bytes ()` |
| `415 Unsupported Media Type` | `svg_not_allowed` | — | Declared `image/svg+xml` or sniffed XML/SVG payload |
| `415 Unsupported Media Type` | `unsupported_media_type` | — | Missing/unknown `Content-Type` or unrecognized magic bytes |
| `415 Unsupported Media Type` | `mime_mismatch` | — | Declared `raster_mime` disagrees with sniffed `raster_mime` |
| `500` / `503` | `media_store_failed` | — | Atomic write or filesystem failure (internal paths masked from response) |

### 4.2 `GET /api/v1/media/<sha256>`

- **Authentication**:
  - Single-user: `Server_route.Permission Masc_domain.CanReadState`.
  - Multi-account (`server_account_dashboard_bridge.ml`): `tier: Workspace_read` (Admin + Worker session cookie).
  - Content hashes are authenticated locators, never bearer capabilities.
- **Validation & Conditional GET order**:
  1. Missing or non-64-lowercase-hex token -> `400 Bad Request` (`code: "invalid_token"`).
  2. Resolve file under `<base_path>/.masc/media/` via `file_path_of_token`; absent -> `404 Not Found` (`code: "not_found"`).
  3. Check `Fs_compat.file_size path`; exceeding `max_bytes ()` -> `413 Payload Too Large` (`code: "media_too_large"`, `max_bytes`, `size_bytes`).
  4. Check `Http.Response.request_holds_tag ~etag:sha256 request` **before** loading file bytes from disk. If matched, answer `304 Not Modified` via `Http.Response.not_modified ~headers` (`lib/http_server_eio.ml:400`) with empty body. **Do not** use `Http.Response.bytes_not_modified` (`lib/http_server_eio.ml:407-412`), which drops `scoped_headers()` (workspace receipt), CORS, `Vary`, `CSP`, and `X-Content-Type-Options`.
  5. Otherwise load bytes and answer `200 OK` (`Http.Response.bytes ~content_type ~headers`).
- **Response Headers (present on both `200 OK` and `304 Not Modified`)**:
  - `ETag: "<sha256>"` (strong validator)
  - `Cache-Control: private, max-age=31536000, immutable` (`private` is mandatory because reads are auth-gated)
  - `X-Content-Type-Options: nosniff`
  - `Content-Security-Policy: default-src 'none'; sandbox`
  - `Content-Disposition`: `inline; filename="<sha256>.<ext>"` for `Raster _`, `Audio_mpeg`, `Audio_wav`, `Audio_ogg`, and `Audio_midi`; `attachment; filename="<sha256>.<ext>"` for `Application_pdf`.
  - `Vary: Origin, Authorization, Cookie`: filter `"vary"` out of `Server_auth.admitted_cors_headers request` (`lib/server/server_auth.ml:850,859-865`) and emit **one** merged `("vary", "Origin, Authorization, Cookie")` header (fail-closed on multi-`Origin`, no duplicate `Vary` headers; update `test/test_artifacts_endpoint.ml:389` assertion accordingly).

### 4.3 Security Boundary for `shared=true` Published Artifacts

`GET /api/v1/published-artifacts/:id` is capability-addressed when `shared=true` (`server_routes_http_routes_published_artifacts.ml:214-228`), whereas `GET /api/v1/media/<sha256>` always requires `CanReadState` / `Workspace_read`. Publishing or sharing an artifact must never turn a workspace media SHA-256 into an unauthenticated public capability. Authenticated Dashboard sessions hydrate embedded media via `workspace-media-cache.ts`; unauthenticated viewers of a shared artifact do not receive workspace media bytes.

## 5. Unified Typed Embed Grammar, Wiki & Published Artifacts

### 5.1 Grammar (OCaml and Dashboard SSOT)

All embed forms are skipped inside fenced code blocks (backtick or tilde fences) and inline code spans.

- **Canonical authoring syntax** (emitted by Dashboard upload insertion, Quick Embed Picker, and Keeper tools):
  - Markdown image upload: `![caption](/api/v1/media/<sha256>)`
  - Media embed: `![[media:<sha256>]]` or `![[media:<sha256>|caption]]`
  - Wiki embed: `![[wiki:<slug>]]` or `![[wiki:<slug>|label]]`
  - Artifact embed: `![[artifact:<id>]]` or `![[artifact:<id>|label]]`
- **Parser acceptance rules** (optional label splits on the first `|`, trimmed; empty label becomes `None`):
  1. `![[media:<raw>]]` -> `Media_embed sha256` if `Keeper_chat_media_store.valid_token raw`, else `Invalid_embed { kind = Embed_media; raw }`.
  2. `![[wiki:<raw>]]` or bare `![[<raw>]]` (no `:` in `<raw>`) -> `Wiki_embed slug` if `Wiki_page_name.validate_page_name raw = Ok slug`, else `Invalid_embed { kind = Embed_wiki; raw }`.
  3. `![[artifact:<raw>]]` -> `Artifact_embed id` if `Published_artifact.valid_id raw` (`^artifact-[0-9a-f]{32}$`), else `Invalid_embed { kind = Embed_artifact; raw }`.
  4. `![[<scheme>:<raw>]]` for any other `<scheme>` -> `Unsupported_embed { scheme; raw }` (strict parse; never coerced to a wiki slug).
  5. `![alt](/api/v1/media/<raw>)` -> `Media_embed sha256` (syntax `Markdown_media`, label from trimmed non-empty `alt`) if `valid_token raw`, else `Invalid_embed { kind = Embed_media; raw }`. Non-media `![alt](...)` remains ignored by the wiki link/embed graph.

### 5.2 OCaml Types (`Wiki_link`, `Wiki_graph`, `Wiki_lint`, `Wiki_lint_report`)

```ocaml
(* lib/wiki_link.mli *)
type embed_kind =
  | Embed_media
  | Embed_wiki
  | Embed_artifact

type embed_target =
  | Media_embed of string
  | Wiki_embed of string
  | Artifact_embed of string
  | Invalid_embed of { kind : embed_kind; raw : string }
  | Unsupported_embed of { scheme : string; raw : string }

type embed_syntax =
  | Obsidian_embed
  | Markdown_media

type embed =
  { label : string option
  ; target : embed_target
  ; syntax : embed_syntax
  ; raw : string
  ; line : int
  }

val extract_embeds : string -> embed list
```

- **Backward compatibility for `Wiki_link.extract` and TUI wire decoders**:
  - `Wiki_link.extract : string -> link list` skips `![[...]]` (just as it skips `![alt](...)`) so `![[...]]` never leaks as `Unsupported "wikilink"` and existing `outgoing_links` wire values stay within the exact 9 spellings decoded by `lib/masc_tui/protocol/wire_knowledge.ml:943-964`.
- **`Wiki_graph`**:
  - `Wiki_graph.Readable` adds `embeds : Wiki_link.embed list` (or exposes `embeds_of : t -> string -> Wiki_link.embed list`).
  - `Wiki_graph.incoming` counts both `Wiki_link.Page slug` links and `Wiki_link.Wiki_embed slug` embeds (deduplicated per referencing page, excluding self-references) so transcluded pages are not falsely flagged as `Orphan`.
- **Pure `Wiki_lint`**:
  - Add closed finding constructors to `Wiki_lint.finding`:
    - `Broken_media_embed of { page : string; line : int; sha256 : string; raw : string }` (`"broken_media_embed"`)
    - `Broken_wiki_embed of { page : string; line : int; target : string; raw : string }` (`"broken_wiki_embed"`)
    - `Broken_artifact_embed of { page : string; line : int; artifact_id : string; raw : string }` (`"broken_artifact_embed"`)
    - `Invalid_embed of { page : string; line : int; kind : string; raw : string }` (`"invalid_embed"`)
    - `Unsupported_embed of { page : string; line : int; scheme : string; raw : string }` (`"unsupported_embed"`)
  - `Wiki_lint.run` stays 100% pure by accepting optional predicates `?media_exists:(string -> bool)` and `?artifact_exists:(string -> bool)`. Callers at the I/O edge (`Server_dashboard_http_wiki`, `Tool_wiki.handle_lint`) supply `fun token -> Option.is_some (Keeper_chat_media_store.file_path_of_token ~base_dir:base_path ~token)` and artifact store existence checks.
  - **TUI lint wire compatibility (`lib/masc_tui/protocol/wire_knowledge.ml:803-828`)**: every new embed finding must emit non-blank `"subject"` (the page slug), `"page"`, `"line"`, and `"target"` (sha256, slug, artifact ID, or raw string) in **both** `Server_dashboard_http_wiki.finding_to_json` and `Wiki_lint_report.finding_to_json`.
  - Update `lib/wiki_lint_report.ml` and `config/tools/masc_wiki_lint.toml` in lockstep with `Wiki_lint.all_kinds` so exhaustive pattern matches and `test_enum_mirror_sync` pass.

### 5.3 `GET /api/v1/wiki/:slug` Additive Wire Contract

Inside `V2Envelope.data`, keep all existing fields untouched and add:

```json
{
  "embeds": [
    {
      "kind": "media",
      "target": "<64-hex-sha256>",
      "label": "Architecture diagram",
      "syntax": "markdown_media",
      "raw": "![Architecture diagram](/api/v1/media/<64-hex-sha256>)",
      "line": 14,
      "exists": true
    }
  ],
  "media_refs": ["<64-hex-sha256>"]
}
```

- `kind` is one of `"media" | "wiki" | "artifact" | "invalid" | "unsupported"`.
- `syntax` is `"obsidian" | "markdown_media"`.
- `media_refs` is sorted and deduplicated across both `Obsidian_embed` (`![[media:...]]`) and `Markdown_media` (`![...](/api/v1/media/...)`).

### 5.4 Published Artifacts & Keeper Authoring Tools

- **Pure extraction without breaking `Published_artifact.revision`**:
  - Keep the `Published_artifact.revision` record fields unchanged (preserving `test/masc_tui_v2/protocol_net/test_server_wire_roundtrip.ml:584` and avoiding disk metadata migration).
  - Add pure `Published_artifact.extract_media_refs : format -> string -> string list`:
    - `Markdown`: extracts every validated 64-hex token from `Wiki_link.extract_embeds` (`Media_embed`).
    - `Html`: scans HTML `src="..."` / `src='...'` attributes (outside `<script>`/`<style>`) for exact `/api/v1/media/<64-hex>` paths.
    - Returns a sorted, deduplicated list of lowercase 64-hex tokens.
  - `GET /api/v1/published-artifacts/:id` adds top-level `"media_refs": [...]` computed from `(selected.format, content)`.
  - `Published_artifact_store.referenced_media_tokens : base_path:string -> (string list, error) result` scans every revision of every published artifact fail-closed (returning `Error` if any metadata file or revision blob is unreadable so GC never deletes live media).
  - `GET /api/v1/published-artifacts` authorization remains single-user `Token_permission CanAdmin` in this stack.
- **Keeper tools (`Tool_wiki`, `Tool_schemas_wiki`, `Keeper_artifact_publish`, `config/tools/*.toml`)**:
  - Keepers reference workspace media exclusively by canonical `/api/v1/media/<sha256>` or `![[media:<sha256>|caption]]` (never raw base64 inside tool arguments or document bodies).
  - `masc_wiki_create`, `masc_wiki_update`, and `keeper_artifact_publish` document this syntax in their tool schemas and return `"media_refs"` (plus `"missing_media_refs"` if any referenced token is currently absent from `.masc/media/`, giving Keepers immediate factual feedback without silently rewriting content).

## 6. Reference-Aware Media GC & `Server_tool_blob_scope` Safety

### 6.1 Fixing `Server_tool_blob_scope.ml`

- Classify `<base_path>/.masc/media` (`"media"`) as `excluded M.Other_media_store` in `Server_tool_blob_scope.workspace`.
- **No phantom exclusions (`legacy_residue`)**: do **not** add a `.masc/media_sweep` entry to `Server_tool_blob_scope.workspace` unless a real sweeper module that creates and owns `.masc/media_sweep` lands in the same change.
- Keep `Config_dir_resolver.wiki_dirname` as `no_reference` for `Tool_blob_store`, because wiki `.md` files reference `/api/v1/media/<sha256>`, not `[masc:blob ...]` markers; `Tool_blob_maintenance` only parses JSON/JSONL/blob markers and would fail on raw Markdown if `wiki` were marked `Tree`.

### 6.2 Eliminating Wall-Clock Media Death

- Delete `cleanup_old_files_in_dir` from `Keeper_chat_media_store.persist_result`. Persisting a new image must never evict existing media by `mtime` or directory-size FIFO.
- `Env_config_keeper.KeeperGeneratedMedia.max_bytes ()` remains the authoritative per-file upload and serve ceiling. Because `lib/config/env_config_keeper.{ml,mli}` and `lib/config/keeper_runtime_setting_registry.ml` sit outside Layer 2's strict file boundary, retiring the now-unused `MASC_KEEPER_GENERATED_MEDIA_RETENTION_SEC` and `MASC_KEEPER_GENERATED_MEDIA_DIR_MAX_BYTES` definitions (and their config/registry tests) is tracked as a dedicated follow-up cleanup PR per `legacy_residue` and `env_var_sprawl`.
- Any future or integrated two-pass reference-aware media sweeper (`Observe_only | Delete_previous_candidates`, mirroring `Tool_blob_maintenance`) **must** satisfy both invariants before enabling `Delete_previous_candidates`:
  1. **Complete Durable Reference Roots** (every root must be read completely; any unreadable or undecodable root aborts deletion fail-closed and deletes nothing):
     - **Keeper Chat & Runtime Stores**: `<base_path>/.masc/chat/`, `<base_path>/.masc/keepers/`, and `<base_path>/.masc/messages/`.
     - **Keeper Config SQLite WALs**: `<config_keepers>/*` compaction and canonical turn databases (`lib/server/server_tool_blob_scope.ml:268-283`).
     - **Multi-Account Homes**: `<base_path>/.masc/accounts/` (`Runtime_account_home_layout.accounts_dir`).
     - **Wiki Pages**: `<base_path>/.masc/wiki/*.md` via `Wiki_link.extract_embeds` (`Media_embed`).
     - **Published Artifacts**: `<base_path>/.masc/published_artifacts/*.json` with every revision body resolved from `Tool_blob_store` via `Published_artifact_store.referenced_media_tokens` (metadata JSON alone carries only `Tool_output.artifact_ref`, not body text).
     - **Board Posts & Comments**: `<base_path>/.masc/board_posts.jsonl` and `<base_path>/.masc/board_comments.jsonl` (`lib/board/board_paths.ml:25-26`).
     - **Tasks & Goals**: `<base_path>/.masc/tasks/` (`lib/workspace/workspace_utils_paths_backend.ml:46`, written by `RichComposer` via `task-create-form.ts`) and `<base_path>/.masc/goals.json` (`Goal_store.goals_filename`).
  2. **Two-Pass Reclamation**:
     - `Observe_only` writes the set of currently unreferenced `<sha256>` tokens to `<base_path>/.masc/media_sweep/candidates.json` (adding `"media_sweep"` to `Server_tool_blob_scope.workspace` as `Sweep_record` in the same PR that implements the sweeper) and deletes nothing.
     - `Delete_previous_candidates` deletes only tokens present in the previous candidate snapshot that remain unreferenced in the fresh complete scan, preventing TOCTOU deletion of an image uploaded just before its Wiki page, Artifact, Comment, or Task save commits.

## 7. Dashboard Runtime, Safe `sandbox=""` Hydration & Authoring UX

### 7.1 Shared Media Cache (`dashboard/src/lib/workspace-media-cache.ts`)

- Replaces per-component `FileReader.readAsDataURL` (eliminating 33%+ base64 RAM inflation and duplicate fetches across virtualized remounts).
- **Epoch-fenced**: cache keys are scoped by `sessionEpoch` (`${epoch}:${path}`). Subscribing to `sessionEpoch` immediately aborts prior-epoch in-flight fetches and revokes all prior-epoch `blob:` object URLs on workspace switch, account switch, or token rotation.
- **In-flight deduplication**: concurrent callers for `(epoch, path)` share one `fetch` request.
- **Byte-bounded LRU + ref-counted `objectURL` lifecycle**:
  - Bounds: **64 MiB** total cached bytes and **128** max entries.
  - `acquireObjectUrl(path, { epoch, signal }) -> Promise<{ url: string; release: () => void } | null>`: increments entry `refCount`. LRU eviction removes entries from the index and calls `URL.revokeObjectURL(url)` only once `refCount === 0` (deferred revocation if still mounted, executed immediately on the final `release()` or epoch bump).
  - `acquireDataUrl(path, { epoch, signal }) -> Promise<string | null>`: converts a cached `Blob` to a `data:` URI **only** for `<iframe sandbox="" srcDoc>` HTML hydration; never stored in the primary LRU cache.
- **Auth & MIME defense**:
  - `mode: 'same-origin'`, `credentials: 'same-origin'`, `redirect: 'error'`, same-origin URL check via `parseUrl(resolveWorkspaceUrl(path), window.location.origin)`.
  - Sends `Authorization: Bearer <token>` in single-user mode; omits `Authorization` in `multi_account_signed_in`.
  - Rejects any response whose `Content-Type` fails `isWorkspaceRasterMime` (strictly PNG/JPEG/GIF/WebP; never SVG) or whose streamed byte count exceeds 50 MiB.
- `dashboard/src/lib/keeper-media.ts` preserves `isWorkspaceMediaPath` and `isWorkspaceRasterMime` exports as the shared client SSOT.

### 7.2 Unified `MarkdownContent` (`dashboard/src/components/common/markdown-renderer.ts`)

- **XSS defenses preserved**: keep `FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form']` and set `ALLOW_DATA_ATTR: false` in **both** `renderMarkdown` and `renderMarkdownDocument` (`dashboard/src/components/common/markdown-renderer.ts:34-47,100-103`, verified by unit test). Explicitly allowlist only our controlled slot attributes (`data-masc-media-src`, `data-masc-media-alt`, `data-masc-embed-kind`, `data-masc-embed-target`, `data-masc-embed-label`) in DOMPurify config — zero post-sanitize innerHTML regex rewriting.
- **Zero-401 media slot hydration (Markdown AND raw HTML `<img>`)**:
  - In the `marked` `image` renderer, when `isWorkspaceMediaPath(href)` matches, emit `<span class="masc-media-slot" data-masc-media-src="/api/v1/media/<sha256>" data-masc-media-alt="...">` instead of a bare `<img src="/api/v1/media/...">`.
  - Inside the inert `<template>` post-sanitize normalizer, rewrite any surviving raw HTML `<img src="/api/v1/media/<64-hex>">` (which bypasses `marked`'s `renderer.image`) into the identical `<span class="masc-media-slot" ...>` before `dangerouslySetInnerHTML` mounts it. No unauthenticated browser fetch ever fires.
  - In `useEffect`, strictly re-validate every DOM attribute value read from a slot or embed (`isWorkspaceMediaPath`, wiki slug `^[a-z0-9]+(?:-[a-z0-9]+)*$`, artifact ID `^artifact-[0-9a-f]{32}$`) before fetching or linking so raw HTML containing allowlisted `data-masc-*` attributes cannot smuggle arbitrary paths or schemes.
  - An `IntersectionObserver` (`rootMargin: '200px'`) hydrates visible slots via `workspace-media-cache.ts` (`acquireObjectUrl`), renders `<img decoding="async">` with skeleton placeholder, click-to-zoom lightbox (`ChatPreviewModal`), and retry button on failure, and calls `release()` on cleanup.
- **Typed `mascEmbed` Marked extension**:
  - Parses `![[media:<sha256>|caption]]`, `![[wiki:<slug>|label]]`, `![[<slug>|label]]`, and `![[artifact:<id>|label]]` prior to sanitization (skipping code fences and code spans).
  - `media` embeds render through the same authenticated `masc-media-slot` hydrator.
  - `wiki` and `artifact` embeds render interactive cards navigating to `#/knowledge/wiki/<slug>` and `#/knowledge/artifacts/<id>` (existing `followDocumentFragment` already passes `#/...` routes through to the router; optional `onNavigate?: (path: string) => void` prop stays backward-compatible).
- **Performance**: co-located `markdown-embeds.css` applies `content-visibility: auto; contain-intrinsic-size: auto 240px;` on media slots and embed cards for 60fps scrolling on long documents.
- `WorkspaceChatImage` (`dashboard/src/components/chat/workspace-image.ts`) migrates onto `workspace-media-cache.ts` while keeping lazy observation, zoom modal, and retry UX.

### 7.3 Safe `sandbox=""` HTML Artifact Hydration

- **Invariant**: `<iframe sandbox="" srcDoc={hydratedHtml}>` in `artifacts-tab.ts` (and upgraded `artifacts-surface.ts`) must never add `allow-scripts`, `allow-same-origin`, `allow-forms`, or `allow-popups`.
- **Hydration flow**:
  1. Whenever `doc.content` references `/api/v1/media/`, **gate `<iframe sandbox="" srcDoc={...}>` rendering** (display a loading placeholder instead of mounting raw `doc.content`) until async hydration resolves, preventing an immediate opaque-origin 401 flash on first mount.
  2. Parse `doc.content` using `new DOMParser().parseFromString(html, 'text/html')` (inert document: scripts never execute, external resources never fetch).
  3. Match `img[src]` elements using raw `el.getAttribute('src')?.trim()` (never resolved `el.src`) passing `isWorkspaceMediaPath(rawSrc)`, bounded at **32 unique workspace images** and **32 MiB cumulative inlined bytes** per artifact.
  4. Resolve each unique path via `workspace-media-cache.ts` `acquireDataUrl(path, { epoch, signal })` under a per-selection `AbortController` + `sessionEpoch` fence.
  5. Rewrite matched `img` `src` attributes to verified raster `data:` URIs (leaving failed or over-budget images safely unhydrated with descriptive fallback `alt` text).
  6. Preserve `<!DOCTYPE html>` explicitly when serializing `DOMParser` output (`<!DOCTYPE html>\n${parsed.documentElement.outerHTML}`) so HTML5 artifacts stay in standards mode rather than quirks mode.
- **`artifacts-surface.ts` disposition**: `components/work.ts:43` still dynamically imports `artifacts-surface.ts` (referenced by `work.test.ts` and `section-nav-reachability.test.ts`), and `components/work.ts` sits outside this stack's file boundary. Therefore Layer 4 upgrades `artifacts-surface.ts` to strict `sandbox=""` + shared hydration rather than breaking `tsc`; retiring dead `components/work.ts` + `artifacts-surface.ts` is deferred to a dedicated cleanup PR.

### 7.4 Authoring Productivity UX (`workspace-media-upload.ts`, `wiki-tab.ts`, `rich-composer.ts`)

- **`dashboard/src/lib/workspace-media-upload.ts`**:
  - Typed client for raw-binary `POST /api/v1/media` returning `Result<UploadedWorkspaceMedia, MediaUploadError>`.
  - Pre-checks file bytes (first 12 bytes magic-byte sniff + MIME check, explicitly rejecting SVG before network send, soft <= 50 MiB guard while honoring server `413` `max_bytes`).
  - Uses `resolveWorkspaceUrl`, `sessionEpoch` fence, `AbortSignal`, single-user `Authorization: Bearer` + `same-origin`, and multi-account `credentials: 'same-origin'` + `x-masc-csrf-token` (with one 403 CSRF refresh retry).
- **Wiki Editor (`dashboard/src/workspaces/knowledge/wiki-tab.ts` + `wiki-embed-picker.ts` + `wiki-editor.css`)**:
  - Clipboard image paste (`onPaste`), drag-and-drop overlay (`onDragOver`/`onDrop`), and toolbar **이미지 첨부** button upload via `workspace-media-upload.ts` and insert `![caption](/api/v1/media/<sha256>)` at cursor position with progress indicator and error toast.
  - Split / Toggle Live Preview using `<MarkdownContent text={editBody} document />`.
  - Quick Embed Picker (`위키·아티팩트 삽입` popover) inserting `![[wiki:<slug>]]` from loaded `wikiIndex.pages` and `![[artifact:<id>]]` from `/api/v1/published-artifacts` (Artifacts tab shown when `canUseSingleUserTokenAdmin(session)` is true).
- **`RichComposer` (`dashboard/src/components/common/rich-composer.ts`)**:
  - Wires paste/drop + attach button through `workspace-media-upload.ts` via wrapper handlers and `inputRef` (without modifying `components/common/input.ts` or breaking the 2 `.rich-composer-tab` buttons pinned by `rich-composer.test.ts:22`).

## 8. Native GitHub Stack Plan & Verification

All changes land as one linear 5-layer Native GitHub Stack off `main` (`gh stack`, squash-only per `docs/guides/NATIVE-GITHUB-STACKS.md`), with zero file overlap across layers:

| Layer | Branch | Owner | Owned Files | Verification Gate |
|---|---|---|---|---|
| L1 | `rfc/workspace-media-and-rich-embed` | `@masc-media-arch` | `docs/rfc/RFC-workspace-media-and-rich-embed.md` | `python3 scripts/rfc-generate-index.py --check`, adversarial RFC audit |
| L2 | `feat/workspace-media-core` | `@masc-media-server` | `lib/keeper/keeper_chat_media_store.{ml,mli}`, callers (`keeper_chat_agent_core_stream_bridge.ml`, `keeper_stream_media_accum.ml`), `lib/server/server_routes_http_routes_media.{ml,mli}`, `lib/server/server_routes_http_routes_voice.ml`, `lib/server/server_routes_http.ml`, `lib/server/server_account_dashboard_bridge.ml`, media unit/endpoint tests (including updating `test/test_artifacts_endpoint.ml:328,333,369,377,389` for new router, valid RIFF/WAVE bytes, and merged `Vary`) | PR `changes` + `type-check` (`dune build @check`), consumer trace, `@masc-verifier` audit |
| L3 | `feat/wiki-artifact-embed-core` | `@masc-wiki-core` | `lib/wiki_link.{ml,mli}`, `lib/wiki_graph.{ml,mli}`, `lib/wiki_lint.{ml,mli}`, `lib/wiki_lint_report.ml`, `lib/server/server_dashboard_http_wiki.{ml,mli}`, `lib/published_artifact.{ml,mli}`, `lib/published_artifact_store.{ml,mli}`, `lib/server/server_routes_http_routes_published_artifacts.{ml,mli}`, `lib/server/server_tool_blob_scope.ml`, workspace media GC module, `lib/tool_wiki.{ml,mli}`, `lib/tool_schemas/tool_schemas_wiki.ml`, `lib/keeper/keeper_artifact_publish.{ml,mli}`, `config/tools/masc_wiki_*.toml`, `config/tools/keeper_artifact_publish.toml`, focused OCaml tests | PR `changes` + `type-check`, `test_enum_mirror_sync` consistency, consumer trace, `@masc-verifier` audit |
| L4 | `feat/dashboard-rich-embed-runtime` | `@masc-embed-ui` | `dashboard/src/lib/workspace-media-cache.ts` (+ tests), `dashboard/src/lib/keeper-media.ts`, `dashboard/src/components/chat/workspace-image.ts` (+ tests), `dashboard/src/components/common/markdown-renderer.ts` (+ tests + `markdown-embeds.css`), `dashboard/src/components/common/rich-code-preview.ts`, `dashboard/src/workspaces/knowledge/artifacts-tab.ts` (+ tests), `dashboard/src/components/published-artifacts/artifacts-surface.ts` | `pnpm --dir dashboard typecheck`, focused `vitest run`, memory/revoke/sandbox audit |
| L5 | `feat/dashboard-wiki-media-ux` | `@masc-editor-ux` | `dashboard/src/lib/workspace-media-upload.ts` (+ tests), `dashboard/src/workspaces/knowledge/wiki-tab.ts` (+ tests), `dashboard/src/workspaces/knowledge/wiki-embed-picker.ts`, `dashboard/src/workspaces/knowledge/wiki-editor.css`, `dashboard/src/components/common/rich-composer.ts` (+ tests) | `pnpm --dir dashboard typecheck`, focused `vitest run`, `@masc-verifier` audit |

Cross-layer symbol stability guarantees:
- Layer 2 preserves `Keeper_chat_media_store.valid_token` and `Keeper_chat_media_store.file_path_of_token` signatures and exposes `val media_subdir : string` (`"media"`). Because `media_subdir` is not exposed in `.mli` on `origin/main` yet, Layer 3 uses a local `media_subdir = "media"` binding in `Server_tool_blob_scope.ml` while branched off `origin/main` (switching to `Keeper_chat_media_store.media_subdir` once stacked atop Layer 2) so both standalone and stacked builds pass `dune build @check`.
- Layer 4 preserves `keeper-media.ts` exports (`isWorkspaceMediaPath`, `isWorkspaceRasterMime`) and `MarkdownContent`'s existing prop signature so Layer 5 compiles cleanly both standalone and stacked on Layer 4.
