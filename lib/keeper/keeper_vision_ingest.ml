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

let max_eager_reads_per_turn = 1
let max_read_text_chars = 4000

let string_of_mode = function
  | Eager -> "eager"
  | Store_only -> "store_only"
;;

let record_eviction ~keeper_name ~mode ~result ~reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string VisionIngestEvictions)
    ~labels:[ "mode", string_of_mode mode; "result", result; "reason", reason ]
    ();
  (* The operator-facing error counter: per keeper, by the closed reason set.
     The pipeline counter above keeps its mode/result/reason shape; this one
     answers "whose images failed and why" in a single lookup per reason. *)
  if String.equal result "error"
  then
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string VisionIngestErrors)
      ~labels:[ "keeper", keeper_name; "reason", reason ]
      ()
;;

(* Every reason an eviction can fail with, in one list. Closed by
     construction: the store-path literals below and the eager-path mapping
     above are the only producers. Health surfaces aggregate a keeper's
     errors by walking this list, so a reason added here appears there
     without a second edit. *)
let error_reasons =
  [ "bad_base64"
  ; "image_too_large"
  ; "invalid_media_type"
  ; "store_failed"
  ; "eager_empty"
  ; "eager_truncated"
  ; "eager_timeout"
  ; "eager_no_runtime"
  ; "eager_invalid_request"
  ; "eager_invalid_structured_response"
  ; "eager_provider_error"
  ; "eager_read_failed"
  ]
;;

let eager_read_eviction_reason_of_outcome = function
  | Keeper_vision_tool.Vo_ok _ -> None
  | Keeper_vision_tool.Vo_empty -> Some "eager_empty"
  | Keeper_vision_tool.Vo_truncated -> Some "eager_truncated"
  | Keeper_vision_tool.Vo_timeout -> Some "eager_timeout"
  | Keeper_vision_tool.Vo_no_runtime _ -> Some "eager_no_runtime"
  | Keeper_vision_tool.Vo_invalid_request _ -> Some "eager_invalid_request"
  | Keeper_vision_tool.Vo_invalid_structured_response _ ->
    Some "eager_invalid_structured_response"
  | Keeper_vision_tool.Vo_provider _ -> Some "eager_provider_error"
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
   emits an unread placeholder. Provider cancellation, when configured, is
   owned by the shared Provider boundary. *)
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
         ~query:extraction_query
         ~media_type
         ~bytes
         ()
     with
     | Keeper_vision_tool.Vo_ok text -> Some (Ok (truncate_read_text text))
     | outcome ->
       (match eager_read_eviction_reason_of_outcome outcome with
        | Some reason -> Some (Error reason)
        | None -> Some (Error "eager_read_failed")))
  | _ -> None
;;

(* Transform one block. An [Image] is evicted to a text placeholder; everything
   else — including an already-evicted [Text] placeholder — passes through
   unchanged, so re-running on a rehydrated message is a no-op (idempotent: no
   double-store, no double-extract). *)
let evict_block ~mode ~keeper_name ~eager_budget (block : Agent_core.Types.content_block) =
  match block with
  | Agent_core.Types.Image { media_type; data; source_type } ->
    (match source_type with
     | Agent_core.Types.Url | Agent_core.Types.File_id ->
       (* RFC-0430 / #33682: a reference carrier is not an eviction target.
          Evict exists to trade the heavy inline payload for a local artifact
          handle; a URL or Files-API id costs a few dozen bytes of context,
          and the serializers put both on the wire in their native forms
          (#33669). Passing the block through unchanged keeps the reference
          requestable instead of replacing it with a store-failure
          placeholder the reader cannot act on. *)
       record_eviction ~keeper_name ~mode ~result:"ok" ~reason:"reference_passthrough";
       block
     | Agent_core.Types.Base64 ->
       match raw_bytes_of_image_data data with
      | Error _ ->
        record_eviction ~keeper_name ~mode ~result:"error" ~reason:"bad_base64";
        Agent_core.Types.Text
          (image_store_failed_placeholder ~reason:"invalid image payload")
      | Ok bytes ->
        (match Keeper_vision_tool.validate_image_size bytes with
         | Error _ ->
           record_eviction ~keeper_name ~mode ~result:"error" ~reason:"image_too_large";
           Agent_core.Types.Text
             (image_store_failed_placeholder ~reason:"image too large")
         | Ok () ->
           (match Keeper_vision_tool.validate_media_type media_type with
            | Error _ ->
              record_eviction ~keeper_name ~mode ~result:"error" ~reason:"invalid_media_type";
              Agent_core.Types.Text
                (image_store_failed_placeholder ~reason:"unsupported image media type")
            | Ok media_type ->
              (match
                 Keeper_vision_tool.store_artifact ~dir:(store_dir ~keeper_name) bytes
               with
               | Error _ ->
                 record_eviction ~keeper_name ~mode ~result:"error" ~reason:"store_failed";
                 Agent_core.Types.Text
                   (image_store_failed_placeholder ~reason:"artifact store failed")
               | Ok handle ->
                 (match mode with
                  | Store_only ->
                    record_eviction ~keeper_name ~mode ~result:"ok" ~reason:"stored";
                    Agent_core.Types.Text
                      (image_unread_placeholder ~handle ~media_type ~reason:"not read")
                  | Eager when !eager_budget > 0 ->
                    decr eager_budget;
                    (match eager_read ~media_type ~bytes with
                     | Some (Ok read_text) ->
                       record_eviction ~keeper_name ~mode ~result:"ok" ~reason:"eager_read";
                       Agent_core.Types.Text
                         (image_read_placeholder ~handle ~media_type ~read_text)
                     | Some (Error reason) ->
                       record_eviction ~keeper_name ~mode ~result:"error" ~reason;
                       Agent_core.Types.Text
                         (image_unread_placeholder
                            ~handle
                            ~media_type
                            ~reason:"vision read failed")
                     | None ->
                       record_eviction ~keeper_name ~mode ~result:"ok" ~reason:"stored_unread";
                       Agent_core.Types.Text
                         (image_unread_placeholder
                            ~handle
                            ~media_type
                            ~reason:"not yet read"))
                  | Eager ->
                    record_eviction ~keeper_name ~mode ~result:"ok" ~reason:"eager_budget_exhausted";
                    Agent_core.Types.Text
                      (image_unread_placeholder
                         ~handle
                         ~media_type
                         ~reason:"not read"))))))
  | other -> other
;;

(* A runtime takes an image itself only when its transport can carry one AND its
   model declares image input. Both halves are required and neither implies the
   other: Claude Code carries images in its stream-json content-block array and
   Codex in its turn/start input list, but a model that does not declare image
   input is still rejected before dispatch. Antigravity sends prompt text only, so an
   image cannot reach it whatever the model declares. *)
let transport_carries_images = function
  | Runtime_execution.Agent_core _
  | Runtime_execution.Claude_code _
  | Runtime_execution.Codex_app_server _ -> true
  | Runtime_execution.Antigravity_cli _ -> false
;;

let runtime_takes_images_itself id =
  match Runtime.get_runtime_by_id id with
  | None -> false
  | Some (rt : Runtime.t) ->
    transport_carries_images rt.Runtime.execution
    && Runtime_agent.caps_admit_required_modalities
         (Runtime_agent.input_capabilities_of_runtime rt)
         [ "image" ]
;;

(* The whole lane is asked, not just the head. When any candidate takes the
   image, RFC-0265 reroutes the turn there and the answering model sees the
   pixels — better than any reading, and the reason RFC-keeper-vision-delegation
   §2.4 did not want delegation to swallow the reroute case. Delegation is for
   the case where no candidate takes it, which is where RFC-0265 reaches
   [No_capable_runtime] and drops the image instead. An id that resolves to no
   lane delegates for the same reason: reading the image keeps it, dropping it
   does not. *)
let delegates_media ~runtime_id =
  match Runtime.resolve_assignment runtime_id with
  | `Missing -> true
  | `Lane lane ->
    not
      (List.exists
         runtime_takes_images_itself
         (Runtime_lane.ordered_candidates lane))
;;

let evict_blocks ~mode ~delegate ~keeper_name blocks =
  if delegate
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

let evict_message ~mode ~delegate ~keeper_name (message : Agent_core.Types.message) =
  if delegate
  then
    { message with
      Agent_core.Types.content =
        evict_blocks ~mode ~delegate ~keeper_name message.Agent_core.Types.content
    }
  else message
;;
