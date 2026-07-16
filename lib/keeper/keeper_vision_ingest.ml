(** See {!Keeper_vision_ingest} (.mli) for the contract and design trail
    (RFC-keeper-vision-delegation-tool §2.3). *)

module Store = Multimodal.Vision_artifact_store

let image_unread_placeholder ~handle ~media_type ~reason =
  Printf.sprintf
    "[image artifact:%s media_type:%s - %s; call analyze_image to read it]"
    (Store.to_string handle)
    media_type
    reason
;;

(* Store failure keeps the invariant (no inline pixels in history) by emitting a
   visible marker rather than re-admitting the [Image] block — surfaced, never
   silent. The pixels for this one block are not retained. *)
let image_store_failed_placeholder ~reason =
  Printf.sprintf "[image — could not store for delegation: %s]" reason
;;

let record_eviction ~result ~reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string VisionIngestEvictions)
    ~labels:[ "result", result; "reason", reason ]
    ()
;;

let store_dir ~keeper_name = Keeper_vision_tool.vision_store_dir ~keeper_name

(* An [Image] block's [data] is the base64 wire payload
   ([Keeper_multimodal_input.normalize_media_payload] guarantees base64); decode
   to the raw bytes the content-addressed store hashes. *)
let raw_bytes_of_image_data data =
  match Base64.decode data with
  | Ok bytes -> Ok bytes
  | Error (`Msg m) -> Error m
;;

(* Transform one block. An [Image] is evicted to a text placeholder; everything
   else — including an already-evicted [Text] placeholder — passes through
   unchanged, so re-running on a rehydrated message is a no-op (idempotent: no
   double-store, no double-extract). *)
let evict_block ~keeper_name (block : Agent_sdk.Types.content_block) =
  match block with
  | Agent_sdk.Types.Image { media_type; data; source_type } ->
    (match source_type with
     | Agent_sdk.Types.Url | Agent_sdk.Types.File_id ->
       record_eviction ~result:"error" ~reason:"invalid_source_type";
       Agent_sdk.Types.Text
         (image_store_failed_placeholder ~reason:"unsupported image source")
     | Agent_sdk.Types.Base64 ->
       match raw_bytes_of_image_data data with
      | Error _ ->
        record_eviction ~result:"error" ~reason:"bad_base64";
        Agent_sdk.Types.Text
          (image_store_failed_placeholder ~reason:"invalid image payload")
      | Ok bytes ->
        (match Keeper_vision_tool.validate_image_size bytes with
         | Error _ ->
           record_eviction ~result:"error" ~reason:"image_too_large";
           Agent_sdk.Types.Text
             (image_store_failed_placeholder ~reason:"image too large")
         | Ok () ->
           (match Keeper_vision_tool.validate_media_type media_type with
            | Error _ ->
              record_eviction ~result:"error" ~reason:"invalid_media_type";
              Agent_sdk.Types.Text
                (image_store_failed_placeholder ~reason:"unsupported image media type")
            | Ok media_type ->
              (match
                 Keeper_vision_tool.store_artifact ~dir:(store_dir ~keeper_name) bytes
               with
               | Error _ ->
                 record_eviction ~result:"error" ~reason:"store_failed";
                 Agent_sdk.Types.Text
                   (image_store_failed_placeholder ~reason:"artifact store failed")
               | Ok handle ->
                 record_eviction ~result:"ok" ~reason:"stored";
                 Agent_sdk.Types.Text
                   (image_unread_placeholder
                      ~handle
                      ~media_type
                      ~reason:"awaiting analyze_image tool call")))))
  | other -> other
;;

let delegating = function
  | Keeper_types_profile.Mm_delegate -> true
  | Keeper_types_profile.Mm_reroute | Keeper_types_profile.Mm_inherit -> false
;;

let evict_blocks ~policy ~keeper_name blocks =
  if delegating policy
  then List.map (evict_block ~keeper_name) blocks
  else blocks
;;

let evict_message ~policy ~keeper_name (message : Agent_sdk.Types.message) =
  if delegating policy
  then
    { message with
      Agent_sdk.Types.content =
        evict_blocks ~policy ~keeper_name message.Agent_sdk.Types.content
    }
  else message
;;
