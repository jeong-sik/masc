# RFC-0037: Board Multimedia & Vision — Eio/File-Based Adaptation

- **Status**: Draft
- **Author**: vincent (with Claude Opus 4.7)
- **Created**: 2026-05-07
- **Drives**: adaptation of an externally authored 2025-05 plan document for board multimedia + AI vision integration. The external plan as written is not implementable on masc-mcp main; this RFC documents the verified gap and proposes a stack-aligned path.
- **Related**:
  - `docs/rfc/RFC-0008-credential-provider.md` — credential surface that any external API integration (Anthropic / OpenAI) must respect.
  - `lib/board_types/board_types.mli` — current post type SSOT (line 76 onward).
  - `lib/provider_adapter.ml` — existing AI provider abstraction (1626 LOC + 397 mli) that this RFC builds on rather than replacing.
  - `~/me/common/evidence-record.md` — currency policy that any model-id / pricing claim must satisfy at PR time.

## 1. Problem

An external 2025-05 plan document (~2040 lines) proposes adding image / video / YouTube attachments and AI vision analysis (auto-tagging, OCR, ALT text, moderation) to the board surface. Three audit passes against masc-mcp main found the plan substantially non-implementable as written:

| Plan section | Verifiable claims sampled | Stale or unverified |
|---|---|---|
| §1 codebase analysis | 7 | 6 (paths wrong, nonexistent frontend files) |
| §3 architecture stack | 5 | 4 (Dream/Opium → actual httpun, Lwt → actual Eio, Redis/RabbitMQ → unused, PostgreSQL → unused) + 1 ignored existing abstraction (`provider_adapter.ml`) |
| §5 cost / model selection | 7 | 5/5 pricing claims with no Evidence Record + 2/2 model IDs (`claude-3-5-sonnet`, `gpt-4o`) predate Claude 4.X family |
| §6 phase tables | repeats §3 stack | propagates |
| §7.1 frontend file targets | 7 | 3 inexistent (`post-editor.ts`, `comment-form.ts`, `comment-tree.ts`) |
| §7.1 backend file targets | 3 | 2 inexistent (`lib/board_store.ml`, `lib/board_handler.ml`) — actual: `lib/board.ml`, `lib/board_dispatch.ml`, `lib/board_core.ml` |
| §7.2 SQL migration | 4 statements | N/A — board uses file-based store with TTL sweeper, no PostgreSQL |
| §7.3 keeper protocol | 1 | mismatched — `ws://` callback channel proposed; actual: internal masc tool calls + coord broadcast |

The plan's **intent** (give board posts a media surface and automate analysis) is sound and unblocks several user requests. The **prescription** has to be rewritten against masc-mcp's actual stack before any line of code lands.

## 2. Goals / Non-Goals

**Goals**

- G1. Establish a minimal `Board_attachment_meta` carrier that lets a post reference attachments without changing `Board_types.post`, by reusing the existing `meta_json : Yojson.Safe.t option` field (`board_types.mli:83`).
- G2. Build the upload / storage path on the same file-based primitives that already protect post bodies (atomic writes, `expires_at` TTL, sharded paths). No PostgreSQL, no MinIO, no S3 in the initial scope.
- G3. Reach AI vision through `provider_adapter.ml` extension, not a parallel `VisionProvider` hierarchy. Reuse `auth_mode` / `model_family` / `model_policy` SSOTs.
- G4. Treat model IDs and pricing as **fetched at PR time** with Evidence Record entries, not committed in this RFC.

**Non-Goals**

- N1. PostgreSQL schema, migrations, or any DB-backed persistence. The board is file-based; cross-stack rewrites are out of scope.
- N2. MinIO, S3, CloudFront, Cloudflare Images. Cloud storage is a future RFC if production volume justifies it.
- N3. Redis, RabbitMQ, SQS, or any external message broker. masc-mcp's coord broadcast is the existing primitive.
- N4. Python sidecar workers (Sharp, libvips, image-optimization daemon). The OCaml monorepo serves the surface; image variant generation is deferred to a later phase if measured load justifies it.
- N5. Frontend implementation files that the external plan named but that don't exist (`post-editor.ts`, `comment-form.ts`, `comment-tree.ts`). Frontend work goes through actual files (`board-surface.ts`, `post-detail.ts`).
- N6. A `Vision Worker (Python)` cross-language process. provider_adapter is in OCaml.

## 3. Verified state of board surface as of 2026-05-07

| Concern | Reality (file:line) |
|---|---|
| HTTP framework | `httpun` via `Http.Router` (e.g. `lib/server/server_routes_http_routes_dashboard.ml`) |
| Concurrency | Eio (50+ files reference `Eio.*`; `rg '\bLwt\.' lib/` returns 0 hits) |
| Storage | File-based with `expires_at` TTL sweeper, atomic writes (see `board_types.mli:7-13`) |
| Post type | `board_types.mli:76-93` — 16 fields including `meta_json : Yojson.Safe.t option` (line 83) |
| Comment type | `board_types.mli:95-105` — analogous structure, no `meta_json` field today |
| API dispatch | `lib/board_dispatch.ml`, `lib/board.ml`, `lib/board_core.ml` |
| AI provider abstraction | `lib/provider_adapter.ml` (1626 LOC + 397 mli) — `runtime_kind` (Local / Cli_agent / Direct_api), `auth_mode`, `model_family`, `model_policy` |
| OpenAI compat surface | `lib/server/server_openai_compat.ml` — receives OpenAI-style requests but is not vision-aware today |
| Frontend board components | 12 files in `dashboard/src/components/board/` — board-state, board-surface (863 LOC), post-detail (538 LOC), mention-inbox, message-room-timeline, board-curation-panel, board-karma-panel, reaction-bar, state-block-messages, sub-board-surface, index, plus tests |

## 4. Phased proposal

### 4.1 Phase A0 — `Board_attachment_meta` carrier (foundation)

Pure-data module, no I/O.

```ocaml
(* lib/board_attachment_meta.mli *)

type kind =
  | Image
  | Video
  | Youtube
  | External_link

type id  (* opaque *)

module Id : sig
  val of_string : string -> (id, Board_types.board_error) result
  val to_string : id -> string
  val generate : unit -> id  (* crypto random, prefix "a-" *)
end

type t = {
  id : id;
  kind : kind;
  origin_url : string;
  origin_name : string;
  origin_size_bytes : int;
  mime_type : string;
  width : int option;
  height : int option;
  created_at : float;
}

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

val attach_to_post_meta :
  existing:Yojson.Safe.t option -> t list -> Yojson.Safe.t
val attachments_of_post_meta :
  Yojson.Safe.t option -> t list  (* total — unknown shapes return [] *)
```

**Properties**

- `Id` is opaque + parsed (matches `Post_id` / `Comment_id` discipline at `board_types.mli:33-49`).
- `of_yojson` is total: an unknown JSON shape returns `Error`, never throws.
- `attach_to_post_meta` preserves any keys in `meta_json` other than the attachments slot, so this module can coexist with future `meta_json` users.
- No file I/O, no network, no Eio — pure data. Trivial to test.

**Tests** (`test/test_board_attachment_meta.ml`):
- Round-trip `to_yojson` / `of_yojson` for every `kind`.
- Unknown / malformed JSON returns `Error`.
- Multiple-attachment ordering is stable.
- `attach_to_post_meta` does not clobber unrelated `meta_json` keys.
- `Id.of_string` rejects path traversal (`..`, `/`) and length > 64.

**Estimated diff**: 1 module + .mli + tests, ~250-300 LOC.

### 4.2 Phase A1 — file-based attachment store

`lib/board_attachment_store.ml` + `.mli`.

- Storage path: `<base_path>/.masc/board/attachments/<sharded-prefix>/<id>` (matches existing board file store sharding pattern).
- API:
  ```ocaml
  val put :
    sw:Eio.Switch.t ->
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    bytes:string ->
    origin:string ->
    (Board_attachment_meta.t, error) result
  ```
- Magic-bytes verification at the boundary, explicit union (PNG / JPEG / WebP / GIF / MP4). No extension-trust.
- Size cap: 20 MB initial, configurable via env (NOT a hardcoded literal — follows the SSOT pattern memorialized in past audits: `feedback_pr_13221_cache_poisoning_misanalysis`).
- TTL: same `expires_at` semantics as posts.

### 4.3 Phase B — vision via `provider_adapter` extension

The plan proposes a separate `VisionProvider` module hierarchy (with its own `name`, `analyze`, `cost_estimate`). This RFC instead extends `provider_adapter.ml`:

- Add a `vision_capability` flag onto the existing adapter records.
- Add a typed dispatch:
  ```ocaml
  type vision_task =
    | Tagging
    | Ocr
    | Caption
    | Moderation
    | Qa of string
  
  val analyze_image :
    adapter ->
    image_path:string ->
    task:vision_task ->
    (Yojson.Safe.t, error) result
  ```
- Reuse existing `auth_mode` (`Api_key` / `Vertex_adc`) — no new credential paths.

**Currency placeholder**: model selection is deferred to PR-time fetch of the official Anthropic and OpenAI model lists, with Evidence Record entries created per `~/me/common/evidence-record.md`. This RFC explicitly does **not** commit to specific model strings.

### 4.4 Phase C — deferred

Before-after slider, image lightbox, blurhash placeholder, AI-generated metadata panel, image-pin annotation. All frontend ergonomics. Sequenced behind A/B verification that the attachment data path is correct in production.

## 5. Migration impact

| Surface | Impact |
|---|---|
| `Board_types.post` struct | **No change.** Attachments live in `meta_json`. |
| Existing post serializers | Compatible — `meta_json` is already serialized; readers that don't know about attachments see them as unknown JSON keys, which is the existing behaviour. |
| Existing post readers in dashboard | No change required for backwards display. Attachment-aware rendering is a new code path. |
| API responses | New optional fields; old clients ignore them. |

The `meta_json`-as-carrier choice is what makes Phase A0 zero-migration. Phase A1+ adds new modules but does not refactor existing ones.

## 6. Open questions (require user decision before Phase A0 PR)

1. **Phase A0 module placement**: `lib/board_attachment_meta.ml` (top-level masc_mcp) versus `lib/board_types/board_attachment_meta.ml` (sub-module of board_types). Sub-module is cleaner if attachments are conceptually part of the board type SSOT; top-level is cleaner if attachments may be reused by non-board surfaces (e.g. keeper artefact attachments) in future.
2. **Attachment_id prefix**: `a-` (consistent with `p-` for posts, `c-` for comments) or `att-` (more descriptive but breaks the one-letter convention).
3. **Phase B model commitment**: do we decide on a Claude-family default upfront (with provider_adapter routing as the override), or stay provider-agnostic and let the adapter pick at call-time? Latter has lower lock-in but harder to reason about cost.
4. **Frontend scope**: extend `post-detail.ts` (538 LOC, already complex) versus add a new sibling component for media-aware rendering. The plan named `post-editor.ts` — that file does not exist, so this is a real decision.

## 7. Out of scope for this RFC

- Code changes (this is a doc-only RFC).
- Specific model strings or pricing numbers.
- Cloud storage architecture.
- Frontend implementation file structure beyond Q4 above.

## 8. Risk register

| Risk | Mitigation |
|---|---|
| `meta_json` schema drift across writers | Define the attachments slot as an explicit JSON schema at the boundary (`Board_attachment_meta.attach_to_post_meta` is the only writer). Audit-time check: `rg '"attachments"' lib/` returns one writer + readers. |
| `Board_attachment_meta` module placement decided wrong, requires move | Phase A0 is pure data and < 300 LOC; a future `git mv` is cheap. |
| Vision integration creates a new credential path | Bound by Goal G3 — must reuse `auth_mode`. Reviewer checklist on Phase B PR enforces this. |
| Plan author may push back on Phase B / C deferrals | This RFC documents the verified gap. Plan-as-written cannot land; alternative is to abandon the work. |

## 9. Acceptance for this RFC

This RFC is approved when the user responds to the four open questions in §6 (or explicitly defers them to PR-time). On approval, this RFC moves from Draft to Active and Phase A0 PR opens with `[RFC-0037 PR-1]` prefix.

If the user prefers to abandon the work entirely, this RFC is closed as "alternative not pursued" and the external plan document is archived in `~/me/knowledge/research/` with a pointer to this audit.

## 10. Audit artefacts

The three loop iterations that informed this RFC live in `~/me/planning/media-vision-loop/` (not in this repo, since they reference a user-local downloaded plan):

- `iter1-claim-verification.md` — §1 codebase analysis (6/7 stale)
- `iter2-architecture-currency.md` — §3 architecture (4/5 stale) + §5 currency (5/5 + 2/2)
- `iter3-rfc-0037-draft.md` — §6/§7 read + first draft of this RFC
