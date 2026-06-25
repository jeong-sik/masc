(** RFC-keeper-vision-delegation-tool §2.3 — write-boundary image eviction.

    Replaces an [Agent_sdk.Types.Image] content block with a text placeholder
    whose handle keys the raw bytes in the per-keeper
    {!Multimodal.Vision_artifact_store}. Enforced at BOTH ingestion entry sites
    so the persisted checkpoint never holds inline base64 and rehydration
    cannot re-materialise an [Image]:

    - Site 1 (fresh input, [Eager]): the turn caller validates and stores every
      image, then may run bounded [analyze_image] vision sub-calls up to the
      operator-configured eager budget and embeds each reading in its
      placeholder.
    - Site 2 (checkpoint write, [Store_only]): the persistence boundary evicts
      with a handle-only placeholder (no provider call on the turn fiber); also
      migrates images already persisted in pre-existing checkpoints.

    Gated by {!Keeper_types_profile.multimodal_policy}: only [Mm_delegate]
    evicts; [Mm_reroute]/[Mm_inherit] are a no-op (safe-by-default). Idempotent:
    a [Text] placeholder is not an [Image], so re-running is a no-op.
    Structured images nested inside [ToolResult.content_blocks] are evicted by
    the same transform so checkpoint writes cannot retain inline image blocks
    through tool-result nesting. *)

type mode =
  | Eager  (** site 1: optionally run bounded vision sub-calls, embed readings *)
  | Store_only  (** site 2: store + handle-only placeholder, no provider call *)

val extraction_query : unit -> string
(** Operator-configurable extraction query used by optional [Eager] reads. *)

val evict_blocks
  :  mode:mode
  -> policy:Keeper_types_profile.multimodal_policy
  -> keeper_name:string
  -> Agent_sdk.Types.content_block list
  -> Agent_sdk.Types.content_block list
(** Site 1. Evict every [Image] in the list when [policy = Mm_delegate]; return
    the list unchanged otherwise. Images are fail-closed before store on
    source_type, base64 payload, size, and media type. [Eager] consults the
    fiber-local Eio context for bounded sub-calls only when its configured
    budget is positive; with none present (tests) it falls back to an unread
    placeholder, so eviction still holds. *)

val evict_message
  :  mode:mode
  -> policy:Keeper_types_profile.multimodal_policy
  -> keeper_name:string
  -> Agent_sdk.Types.message
  -> Agent_sdk.Types.message
(** Site 2. Same transform applied to a message's content blocks at the
    checkpoint write boundary. Use [Store_only] here — checkpoint writes must
    not block the turn fiber on a provider call. *)
