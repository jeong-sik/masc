(* Keeper_vision_tool pure-core tests — RFC-keeper-vision-delegation-tool §2.6.

   Locks the two contract-critical pure pieces:
   - stop_reason -> truncated mapping (the 2026-06-25 gemma4 finding: MaxTokens
     means the reply truncated, distinct from an empty/refusal reply);
   - the one-shot message build (image bytes MUST be base64-encoded for the wire
     serializer, which emits data:<media_type>;base64,<data>).

   The I/O orchestration (handle: load + runtime select + provider sub-call) is
   exercised by the env-gated live smoke, not here — it needs global Runtime
   state, an Eio net, and a populated store dir. The early no-Eio branches are
   covered below. *)

module Vt = Masc.Keeper_vision_tool
module Va = Multimodal.Vision_analyze

(* Only MaxTokens -> true. Exhaustive over all 9 SDK variants so a new one forces
   a decision rather than silently bucketing to false. *)
let test_truncated_of_stop_reason () =
  assert (Vt.truncated_of_stop_reason Agent_sdk.Types.MaxTokens = true);
  List.iter
    (fun r -> assert (Vt.truncated_of_stop_reason r = false))
    [ Agent_sdk.Types.EndTurn
    ; Agent_sdk.Types.StopToolUse
    ; Agent_sdk.Types.StopSequence
    ; Agent_sdk.Types.Refusal
    ; Agent_sdk.Types.PauseTurn
    ; Agent_sdk.Types.Compaction
    ; Agent_sdk.Types.ContextWindowExceeded
    ; Agent_sdk.Types.Unknown "content_filter"
    ]

(* One User message [text query; image]; image data is base64 of the raw bytes
   (NOT the raw bytes), media_type preserved, source_type "base64". *)
let test_message_of_request () =
  let bytes = "\x89PNG\r\n\x1a\n\x00raw\xffbytes" in
  match
    Va.make_request ~query:"what color?" ~image_media_type:"image/png"
      ~image_bytes:bytes
  with
  | Error e -> failwith e
  | Ok req ->
    let msg = Vt.message_of_request req in
    assert (msg.Agent_sdk.Types.role = Agent_sdk.Types.User);
    (match msg.Agent_sdk.Types.content with
     | [ Agent_sdk.Types.Text q; Agent_sdk.Types.Image img ] ->
       assert (String.equal q "what color?");
       assert (String.equal img.media_type "image/png");
       assert (String.equal img.source_type "base64");
       assert (String.equal img.data (Base64.encode_string bytes));
       assert (not (String.equal img.data bytes))
     | _ -> assert false)

(* first_vision_runtime_id returns a typed result either way (no exception). With
   no runtime cache loaded in this unit context it is Error; the value is what
   matters (never raises). *)
let test_first_vision_runtime_id_total () =
  match Vt.first_vision_runtime_id () with
  | Ok _ | Error _ -> ()

let () =
  test_truncated_of_stop_reason ();
  test_message_of_request ();
  test_first_vision_runtime_id_total ();
  print_endline "test_keeper_vision_tool: all assertions passed"
