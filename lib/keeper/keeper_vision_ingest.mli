(** RFC-keeper-vision-delegation-tool §2.3 — write-boundary image eviction.

    Replaces an [Agent_sdk.Types.Image] content block with a text placeholder
    whose handle keys the raw bytes in the per-keeper
    {!Multimodal.Vision_artifact_store}. Enforced at BOTH ingestion entry sites
    so the persisted checkpoint never holds inline base64 and rehydration
    cannot re-materialise an [Image]:

    - Site 1 (fresh input): the turn caller validates and stores every image,
      then emits a handle-only placeholder. The Keeper decides when to call
      [analyze_image]; ingestion never starts a provider call.
    - Site 2 (checkpoint write): the persistence boundary performs the same
      store + handle transform and also migrates images already persisted in
      pre-existing checkpoints.

    Gated by {!Keeper_types_profile.multimodal_policy}: only [Mm_delegate]
    evicts; [Mm_reroute]/[Mm_inherit] are a no-op (safe-by-default). Idempotent:
    a [Text] placeholder is not an [Image], so re-running is a no-op. *)

val evict_blocks
  :  policy:Keeper_types_profile.multimodal_policy
  -> keeper_name:string
  -> Agent_sdk.Types.content_block list
  -> Agent_sdk.Types.content_block list
(** Site 1. Evict every [Image] in the list when [policy = Mm_delegate]; return
    the list unchanged otherwise. Images are fail-closed before store on
    base64 payload, size, and media type. Successful stores always return a
    placeholder that exposes the exact artifact handle to [analyze_image]. *)

val evict_message
  :  policy:Keeper_types_profile.multimodal_policy
  -> keeper_name:string
  -> Agent_sdk.Types.message
  -> Agent_sdk.Types.message
(** Site 2. Same provider-free transform applied to a message's content blocks
    at the checkpoint write boundary. *)
