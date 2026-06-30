(** See {!Keeper_vision_ingest} (.mli) for the contract and design trail
    (RFC-keeper-vision-delegation-tool §2.3). *)

module Store = Multimodal.Vision_artifact_store

type mode =
  | Eager
  | Store_only

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

let eager_timeout_sec = 30.0
let max_eager_reads_per_turn = 1
let max_read_text_chars = 4000

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
  if length <= max_read_text_chars
  then text
  else String.sub text 0 max_read_text_chars ^ "\n[truncated]"
;;

(* Operator decision (2026-06-25, RFC §2.3-eager): exhaustive description, so a
   later text-only turn rarely needs to re-read the pixels. *)
let extraction_query =
  "Describe everything in this image: transcribe all text verbatim, and list \
   every UI element, the layout, colors, state, errors, and numbers. Be \
   exhaustive — the reader cannot see the image, only your description."
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
         ~timeout_sec:eager_timeout_sec
         ~query:extraction_query
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
     | Keeper_vision_tool.Vo_invalid_structured_response detail ->
       Some (Error ("vision invalid structured response: " ^ detail))
     | Keeper_vision_tool.Vo_provider { detail; _ } ->
       Some (Error ("vision provider error: " ^ detail)))
  | _ -> None
;;

(* Transform one block. An [Image] is evicted to a text placeholder; everything
   else — including an already-evicted [Text] placeholder — passes through
   unchanged, so re-running on a rehydrated message is a no-op (idempotent: no
   double-store, no double-extract). *)
let evict_block ~mode ~keeper_name ~eager_budget (block : Agent_sdk.Types.content_block) =
  match block with
  | Agent_sdk.Types.Image { media_type; data; source_type } ->
    (match source_type with
     | Agent_sdk.Types.Url | Agent_sdk.Types.File_id ->
       record_eviction ~mode ~result:"error" ~reason:"invalid_source_type";
       Agent_sdk.Types.Text
         (image_store_failed_placeholder ~reason:"unsupported image source")
     | Agent_sdk.Types.Base64 ->
       match raw_bytes_of_image_data data with
      | Error _ ->
        record_eviction ~mode ~result:"error" ~reason:"bad_base64";
        Agent_sdk.Types.Text
          (image_store_failed_placeholder ~reason:"invalid image payload")
      | Ok bytes ->
        (match Keeper_vision_tool.validate_image_size bytes with
         | Error _ ->
           record_eviction ~mode ~result:"error" ~reason:"image_too_large";
           Agent_sdk.Types.Text
             (image_store_failed_placeholder ~reason:"image too large")
         | Ok () ->
           (match Keeper_vision_tool.validate_media_type media_type with
            | Error _ ->
              record_eviction ~mode ~result:"error" ~reason:"invalid_media_type";
              Agent_sdk.Types.Text
                (image_store_failed_placeholder ~reason:"unsupported image media type")
            | Ok media_type ->
              (match
                 Keeper_vision_tool.store_artifact ~dir:(store_dir ~keeper_name) bytes
               with
               | Error _ ->
                 record_eviction ~mode ~result:"error" ~reason:"store_failed";
                 Agent_sdk.Types.Text
                   (image_store_failed_placeholder ~reason:"artifact store failed")
               | Ok handle ->
                 (match mode with
                  | Store_only ->
                    record_eviction ~mode ~result:"ok" ~reason:"stored";
                    Agent_sdk.Types.Text
                      (image_unread_placeholder ~handle ~media_type ~reason:"not read")
                  | Eager when !eager_budget > 0 ->
                    decr eager_budget;
                    (match eager_read ~media_type ~bytes with
                     | Some (Ok read_text) ->
                       record_eviction ~mode ~result:"ok" ~reason:"eager_read";
                       Agent_sdk.Types.Text
                         (image_read_placeholder ~handle ~media_type ~read_text)
                     | Some (Error _reason) ->
                       record_eviction ~mode ~result:"error" ~reason:"eager_read_failed";
                       Agent_sdk.Types.Text
                         (image_unread_placeholder
                            ~handle
                            ~media_type
                            ~reason:"vision read failed")
                     | None ->
                       record_eviction ~mode ~result:"ok" ~reason:"stored_unread";
                       Agent_sdk.Types.Text
                         (image_unread_placeholder
                            ~handle
                            ~media_type
                            ~reason:"not yet read"))
                  | Eager ->
                    record_eviction ~mode ~result:"ok" ~reason:"eager_budget_exhausted";
                    Agent_sdk.Types.Text
                      (image_unread_placeholder
                         ~handle
                         ~media_type
                         ~reason:"not read"))))))
  | other -> other
;;

let delegating = function
  | Keeper_types_profile.Mm_delegate -> true
  | Keeper_types_profile.Mm_reroute | Keeper_types_profile.Mm_inherit -> false
;;

let evict_blocks ~mode ~policy ~keeper_name blocks =
  if delegating policy
  then (
    let eager_budget =
      ref
        (match mode with
         | Eager -> max_eager_reads_per_turn
         | Store_only -> 0)
    in
    List.map (evict_block ~mode ~keeper_name ~eager_budget) blocks)
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
