(** RFC-keeper-vision-delegation-tool §2.3 — write-boundary image eviction.

    Replaces an [Agent_sdk.Types.Image] content block with a text placeholder
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

    Gated by {!Keeper_types_profile.multimodal_policy}: only [Mm_delegate]
    evicts; [Mm_reroute]/[Mm_inherit] are a no-op (safe-by-default). Idempotent:
    a [Text] placeholder is not an [Image], so re-running is a no-op. *)

type mode =
  | Eager  (** site 1: run the vision sub-call now, embed the reading *)
  | Store_only  (** site 2: store + handle-only placeholder, no provider call *)

val extraction_query : string
(** The fixed exhaustive extraction query used by [Eager] (RFC §2.3-eager). *)

val eager_read_eviction_reason_of_outcome
  :  Keeper_vision_tool.vision_outcome
  -> string option
(** Metric reason projection for failed [Eager] vision sub-calls. [Vo_ok] has
    no error reason; every non-ok outcome maps to a finite eviction reason so
    provider failures, timeouts, invalid requests, and invalid structured
    responses do not collapse into one counter bucket. *)

val evict_blocks
  :  mode:mode
  -> policy:Keeper_types_profile.multimodal_policy
  -> keeper_name:string
  -> Agent_sdk.Types.content_block list
  -> Agent_sdk.Types.content_block list
(** Site 1. Evict every [Image] in the list when [policy = Mm_delegate]; return
    the list unchanged otherwise. Images are fail-closed before store on
    base64 payload, size, and media type. The delegate path requires an Eio
    context for durable storage. [Eager] then consults the fiber-local Eio
    context for one bounded sub-call. *)

val evict_message
  :  mode:mode
  -> policy:Keeper_types_profile.multimodal_policy
  -> keeper_name:string
  -> Agent_sdk.Types.message
  -> Agent_sdk.Types.message
(** Site 2. Same transform applied to a message's content blocks at the
    checkpoint write boundary. Use [Store_only] here — checkpoint writes must
    not block the turn fiber on a provider call. *)

module For_testing : sig
  val with_store_artifact :
    (dir:string ->
     string ->
     (Multimodal.Vision_artifact_store.handle, string) result) ->
    (unit -> 'a) ->
    'a
  (** Scope an explicit blocking/failure-injection store for non-Eio tests. *)
end
