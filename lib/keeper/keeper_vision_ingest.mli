(** RFC-keeper-vision-delegation-tool §2.3 — write-boundary image eviction.

    Replaces an [Agent_core.Types.Image] content block with a text placeholder
    whose handle keys the raw bytes in the per-keeper
    {!Multimodal.Vision_artifact_store}. Enforced at BOTH ingestion entry sites
    so the persisted checkpoint never holds inline base64 and rehydration
    cannot re-materialise an [Image]:

    - Site 1 (fresh input, [Eager]): the turn caller validates and stores every
      image, then runs at most one bounded [analyze_image] vision sub-call for
      the first valid image and embeds the reading in the placeholder.
    - Site 2 (checkpoint write, [Store_only]): the persistence boundary evicts
      with a handle-only placeholder (no provider call on the turn fiber); also
      migrates images already persisted in pre-existing checkpoints.

    Gated by {!delegates_media} on the assigned lane, not by a stored setting:
    a lane with a candidate that takes provider content blocks and declares
    image input keeps its images (RFC-0265 reroutes there, and seeing the pixels
    beats any reading); a lane with no such candidate evicts instead of letting
    RFC-0265 drop the image. The three CLI executions take a prompt string, so an
    image cannot reach them and they always evict. Idempotent: a [Text]
    placeholder is not an [Image], so re-running is a no-op. *)

type mode =
  | Eager  (** site 1: run the vision sub-call now, embed the reading *)
  | Store_only  (** site 2: store + handle-only placeholder, no provider call *)

val eager_read_eviction_reason_of_outcome
  :  Keeper_vision_tool.vision_outcome
  -> string option
(** Metric reason projection for failed [Eager] vision sub-calls. [Vo_ok] has
    no error reason; every non-ok outcome maps to a finite eviction reason so
    provider failures, timeouts, invalid requests, and invalid structured
    responses do not collapse into one counter bucket. *)

val delegates_media : runtime_id:string -> bool
(** Whether the lane [runtime_id] resolves to needs its images read for it.
    [false] as soon as one candidate takes an [Image] itself — RFC-0265 then
    reroutes the turn to that candidate and the answering model sees the pixels.
    A candidate takes one when its transport carries images (Agent Core content
    blocks, the Claude Code stream-json array, or the Codex turn/start input
    list) AND its model declares image input; Antigravity sends prompt text
    only, so an [Image] cannot reach it whatever the model declares. [true] when no candidate qualifies,
    and for an id that resolves to no lane — evicting keeps the image, and the
    alternative (RFC-0265 [No_capable_runtime]) drops it. *)

val evict_blocks
  :  mode:mode
  -> delegate:bool
  -> keeper_name:string
  -> Agent_core.Types.content_block list
  -> Agent_core.Types.content_block list
(** Site 1. Evict every [Image] in the list when [delegate]; return the list
    unchanged otherwise. Images are fail-closed before store on
    base64 payload, size, and media type. An [Image] whose source is a
    {!Agent_core.Types.media_source_kind} [Url] or [File_id] is a reference,
    not a payload: it passes through unchanged (counted [ok] under reason
    [reference_passthrough]), because the serializers put the reference on the
    wire natively and there are no inline pixels to trade for a handle.
    [Eager] consults the
    fiber-local Eio context for one bounded sub-call; with none present (tests)
    it falls back to an unread placeholder, so eviction still holds. *)

val evict_message
  :  mode:mode
  -> delegate:bool
  -> keeper_name:string
  -> Agent_core.Types.message
  -> Agent_core.Types.message
(** Site 2. Same transform applied to a message's content blocks at the
    checkpoint write boundary. Use [Store_only] here — checkpoint writes must
    not block the turn fiber on a provider call. *)

val error_reasons : string list
(** Every reason an image eviction can fail with. Closed by construction —
    the only producers are the store-path validations and the eager-read
    outcome mapping in this module. Health surfaces aggregate per-keeper
    vision errors by walking this list. *)
