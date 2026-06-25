(** RFC-keeper-vision-delegation-tool §2.3 (site 1) — fresh-input image ingestion
    for keepers whose {!Keeper_multimodal_policy} is Delegate. Instead of carrying
    a user image through the conversation (which RFC-0265 then reroutes the whole
    turn for), the image is stored and replaced with a text placeholder so the
    keeper reads it on demand via the [analyze_image] tool. *)

val store_dir : keeper_name:string -> string
(** Per-keeper content-addressed vision store directory. MUST match the directory
    [Keeper_vision_tool] reads from, or a stored handle will not resolve. *)

val should_delegate : Keeper_multimodal_policy.t option -> bool
(** [true] iff the (optional, default-resolved via {!Keeper_multimodal_policy})
    policy delegates images. [None] resolves to the system default (Reroute ->
    [false]), so a keeper with no configured policy is unaffected. *)

val intercept_image_blocks
  :  store:(string -> (string, string) result)
  -> Agent_sdk.Types.content_block list
  -> Agent_sdk.Types.content_block list
(** Replace each [Image] block with a [Text] placeholder referencing the handle
    [store] returns for the decoded raw bytes. Fail-open: on a base64-decode or
    [store] error the original [Image] is kept (and a WARN logged), degrading to
    RFC-0265 reroute rather than dropping the user's image. All non-image blocks
    (including any future block variant) pass through unchanged. [store] is
    injectable so the transform is unit-testable without filesystem I/O. *)
