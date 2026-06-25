(** See {!Keeper_vision_ingest} (.mli) for the contract and design trail
    (RFC-keeper-vision-delegation-tool §2.3). *)

module Store = Multimodal.Vision_artifact_store

type mode =
  | Eager
  | Store_only

type image_source_type =
  | Base64_source
  | Unsupported_source of string

(* SSOT placeholder formats. The handle always lets the keeper re-read the
   pixels via the analyze_image tool; the eager [read] text carries the meaning
   so most follow-up turns answer without any further vision call. *)
let image_read_placeholder ~handle ~media_type ~read_text =
  Printf.sprintf
    "[image read: %s | artifact:%s media_type:%s]"
    read_text
    (Store.to_string handle)
    media_type
;;

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

let string_of_mode = function
  | Eager -> "eager"
  | Store_only -> "store_only"
;;

let record_eviction ~mode ~result ~reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string VisionIngestEvictions)
    ~labels:[ "mode", string_of_mode mode; "result", result; "reason", reason ]
    ()
;;

let truncate_read_text text =
  let length = String.length text in
  let max_read_text_chars = Env_config_keeper.KeeperVision.max_read_text_chars () in
  if length <= max_read_text_chars
  then text
  else String.sub text 0 max_read_text_chars ^ "\n[truncated]"
;;

let extraction_query () = Env_config_keeper.KeeperVision.eager_extraction_query ()

let store_dir ~keeper_name = Keeper_vision_tool.vision_store_dir ~keeper_name

let parse_source_type raw =
  match String.lowercase_ascii (String.trim raw) with
  | "base64" -> Base64_source
  | normalized -> Unsupported_source normalized
;;

(* An [Image] block's [data] is the base64 wire payload
   ([Keeper_multimodal_input.normalize_media_payload] guarantees base64); decode
   to the raw bytes the content-addressed store hashes. *)
let raw_bytes_of_image_data data =
  match Base64.decode data with
  | Ok bytes -> Ok bytes
  | Error (`Msg m) -> Error m
;;

(* Eager extraction through the shared vision core, only when an Eio context is
   present (prod turn). Absent (tests / pre-bootstrap) -> [None]; the caller then
   emits an unread placeholder. Bounded by [run_vision]'s [with_timeout]. *)
let eager_read ~media_type ~bytes : (string, string) result option =
  match
    Eio_context.get_net_opt (), Eio_context.get_switch_opt (), Eio_context.get_clock_opt ()
  with
  | Some net, Some sw, Some clock ->
    (match
       Keeper_vision_tool.run_vision
         ~sw
         ~clock
         ~net
         ~timeout_sec:(Env_config_keeper.KeeperVision.eager_timeout_sec ())
         ~query:(extraction_query ())
         ~media_type
         ~bytes
         ()
     with
     | Keeper_vision_tool.Vo_ok text -> Some (Ok (truncate_read_text text))
     | Keeper_vision_tool.Vo_empty -> Some (Error "vision returned no text")
     | Keeper_vision_tool.Vo_truncated -> Some (Error "vision reply truncated")
     | Keeper_vision_tool.Vo_timeout -> Some (Error "vision sub-call timed out")
     | Keeper_vision_tool.Vo_no_runtime msg -> Some (Error ("no vision runtime: " ^ msg))
     | Keeper_vision_tool.Vo_invalid_request msg ->
       Some (Error ("invalid vision request: " ^ msg))
     | Keeper_vision_tool.Vo_provider { detail; _ } ->
       Some (Error ("vision provider error: " ^ detail)))
  | _ -> None
;;

(* Transform one block. An [Image] is evicted to a text placeholder; everything
   else — including an already-evicted [Text] placeholder — passes through
   unchanged, so re-running on a rehydrated message is a no-op (idempotent: no
   double-store, no double-extract). *)
let rec evict_block
    ~mode
    ~keeper_name
    ~eager_budget
    (block : Agent_sdk.Types.content_block) =
  match block with
  | Agent_sdk.Types.Image { media_type; data; source_type } ->
    (match parse_source_type source_type with
     | Unsupported_source _ ->
      record_eviction ~mode ~result:"error" ~reason:"invalid_source_type";
      ( Agent_sdk.Types.Text
          (image_store_failed_placeholder ~reason:"unsupported image source")
      , eager_budget )
     | Base64_source ->
      match raw_bytes_of_image_data data with
      | Error _ ->
        record_eviction ~mode ~result:"error" ~reason:"bad_base64";
        ( Agent_sdk.Types.Text
            (image_store_failed_placeholder ~reason:"invalid image payload")
        , eager_budget )
      | Ok bytes ->
        (match Keeper_vision_tool.validate_image_size bytes with
         | Error _ ->
           record_eviction ~mode ~result:"error" ~reason:"image_too_large";
           ( Agent_sdk.Types.Text
               (image_store_failed_placeholder ~reason:"image too large")
           , eager_budget )
         | Ok () ->
           (match Keeper_vision_tool.validate_media_type media_type with
            | Error _ ->
              record_eviction ~mode ~result:"error" ~reason:"invalid_media_type";
              ( Agent_sdk.Types.Text
                  (image_store_failed_placeholder
                     ~reason:"unsupported image media type")
              , eager_budget )
            | Ok media_type ->
              (match
                 Keeper_vision_tool.store_artifact ~dir:(store_dir ~keeper_name) bytes
               with
               | Error _ ->
                 record_eviction ~mode ~result:"error" ~reason:"store_failed";
                 ( Agent_sdk.Types.Text
                     (image_store_failed_placeholder ~reason:"artifact store failed")
                 , eager_budget )
               | Ok handle ->
                 (match mode with
                  | Store_only ->
                    record_eviction ~mode ~result:"ok" ~reason:"stored";
                    ( Agent_sdk.Types.Text
                        (image_unread_placeholder
                           ~handle
                           ~media_type
                           ~reason:"not read")
                    , eager_budget )
                  | Eager when eager_budget > 0 ->
                    let eager_budget = eager_budget - 1 in
                    (match eager_read ~media_type ~bytes with
                     | Some (Ok read_text) ->
                       record_eviction ~mode ~result:"ok" ~reason:"eager_read";
                       ( Agent_sdk.Types.Text
                           (image_read_placeholder ~handle ~media_type ~read_text)
                       , eager_budget )
                     | Some (Error _reason) ->
                       record_eviction ~mode ~result:"error" ~reason:"eager_read_failed";
                       ( Agent_sdk.Types.Text
                           (image_unread_placeholder
                              ~handle
                              ~media_type
                              ~reason:"vision read failed")
                       , eager_budget )
                     | None ->
                       record_eviction ~mode ~result:"ok" ~reason:"stored_unread";
                       ( Agent_sdk.Types.Text
                           (image_unread_placeholder
                              ~handle
                              ~media_type
                              ~reason:"not yet read")
                       , eager_budget ))
                  | Eager ->
                    record_eviction ~mode ~result:"ok" ~reason:"eager_budget_exhausted";
                    ( Agent_sdk.Types.Text
                        (image_unread_placeholder
                           ~handle
                           ~media_type
                           ~reason:"not read")
                    , eager_budget ))))))
  | Agent_sdk.Types.ToolResult
      { tool_use_id; content; is_error; json; content_blocks = Some nested } ->
    let nested, eager_budget =
      evict_block_list ~mode ~keeper_name ~eager_budget nested
    in
    ( Agent_sdk.Types.ToolResult
        { tool_use_id; content; is_error; json; content_blocks = Some nested }
    , eager_budget )
  | other -> other, eager_budget

and evict_block_list ~mode ~keeper_name ~eager_budget blocks =
  let blocks_rev, eager_budget =
    List.fold_left
      (fun (acc, eager_budget) block ->
        let block, eager_budget = evict_block ~mode ~keeper_name ~eager_budget block in
        block :: acc, eager_budget)
      ([], eager_budget)
      blocks
  in
  List.rev blocks_rev, eager_budget
;;

let delegating = function
  | Keeper_types_profile.Mm_delegate -> true
  | Keeper_types_profile.Mm_reroute | Keeper_types_profile.Mm_inherit -> false
;;

let evict_blocks ~mode ~policy ~keeper_name blocks =
  if delegating policy
  then (
    let eager_budget =
      match mode with
      | Eager -> Env_config_keeper.KeeperVision.max_eager_reads_per_turn ()
      | Store_only -> 0
    in
    fst (evict_block_list ~mode ~keeper_name ~eager_budget blocks))
  else blocks
;;

let evict_message ~mode ~policy ~keeper_name (message : Agent_sdk.Types.message) =
  if delegating policy
  then
    { message with
      Agent_sdk.Types.content =
        evict_blocks ~mode ~policy ~keeper_name message.Agent_sdk.Types.content
    }
  else message
;;
