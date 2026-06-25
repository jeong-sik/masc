(** See {!Keeper_vision_ingest} (.mli) for the contract and design trail
    (RFC-keeper-vision-delegation-tool §2.3). *)

module Store = Multimodal.Vision_artifact_store

type mode =
  | Eager
  | Store_only

(* SSOT placeholder formats. The handle always lets the keeper re-read the
   pixels via the analyze_image tool; the eager [read] text carries the meaning
   so most follow-up turns answer without any further vision call. *)
let image_read_placeholder ~handle ~read_text =
  Printf.sprintf "[image read: %s | artifact:%s]" read_text (Store.to_string handle)
;;

let image_unread_placeholder ~handle ~reason =
  Printf.sprintf
    "[image artifact:%s — %s; call analyze_image to read it]"
    (Store.to_string handle)
    reason
;;

(* Store failure keeps the invariant (no inline pixels in history) by emitting a
   visible marker rather than re-admitting the [Image] block — surfaced, never
   silent. The pixels for this one block are not retained. *)
let image_store_failed_placeholder ~reason =
  Printf.sprintf "[image — could not store for delegation: %s]" reason
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
  match Eio_context.get_net_opt (), Eio_context.get_switch_opt () with
  | Some net, Some sw ->
    let clock = Eio_context.get_clock_opt () in
    (match
       Keeper_vision_tool.run_vision
         ~sw
         ?clock
         ~net
         ~query:extraction_query
         ~media_type
         ~bytes
         ()
     with
     | Keeper_vision_tool.Vo_ok text -> Some (Ok text)
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
let evict_block ~mode ~keeper_name (block : Agent_sdk.Types.content_block) =
  match block with
  | Agent_sdk.Types.Image { media_type; data; _ } ->
    (match raw_bytes_of_image_data data with
     | Error m ->
       Agent_sdk.Types.Text (image_store_failed_placeholder ~reason:("bad base64: " ^ m))
     | Ok bytes ->
       (match Store.store ~dir:(store_dir ~keeper_name) bytes with
        | Error m -> Agent_sdk.Types.Text (image_store_failed_placeholder ~reason:m)
        | Ok handle ->
          (match mode with
           | Store_only ->
             Agent_sdk.Types.Text (image_unread_placeholder ~handle ~reason:"not read")
           | Eager ->
             (match eager_read ~media_type ~bytes with
              | Some (Ok read_text) ->
                Agent_sdk.Types.Text (image_read_placeholder ~handle ~read_text)
              | Some (Error reason) ->
                Agent_sdk.Types.Text (image_unread_placeholder ~handle ~reason)
              | None ->
                Agent_sdk.Types.Text
                  (image_unread_placeholder ~handle ~reason:"not yet read")))))
  | other -> other
;;

let delegating = function
  | Keeper_types_profile.Mm_delegate -> true
  | Keeper_types_profile.Mm_reroute | Keeper_types_profile.Mm_inherit -> false
;;

let evict_blocks ~mode ~policy ~keeper_name blocks =
  if delegating policy then List.map (evict_block ~mode ~keeper_name) blocks else blocks
;;

let evict_message ~mode ~policy ~keeper_name (message : Agent_sdk.Types.message) =
  if delegating policy
  then { message with Agent_sdk.Types.content = List.map (evict_block ~mode ~keeper_name) message.Agent_sdk.Types.content }
  else message
;;
