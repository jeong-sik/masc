(* RFC-0301 item 6: unit tests for the turn-local generated-media accumulator. *)

open Alcotest

module A = Keeper_stream_media_accum
module Blocks = Masc.Keeper_chat_blocks

let test_image_media_persisted_as_block () =
  let open Agent_sdk.Types in
  let accum = A.create () in
  (* Two chunks across one image block, then its stop. *)
  List.iter
    (A.on_event accum)
    [
      ContentBlockDelta
        {
          index = 0;
          delta = MediaDelta { media_type = "image/png"; source_type = Base64; data = "ab" };
        };
      ContentBlockDelta
        {
          index = 0;
          delta = MediaDelta { media_type = "image/png"; source_type = Base64; data = "cd" };
        };
      ContentBlockStop { index = 0 };
    ];
  let base_dir = Filename.temp_dir "media_accum_test" "" in
  match A.to_chat_blocks ~base_dir accum with
  | [ Blocks.Image { src; cap = None } ] ->
    check
      string
      "image block src is the persisted media URL for the concatenated payload"
      ("/api/v1/media/" ^ Digest.to_hex (Digest.string "abcd"))
      src
  | _ -> fail "expected exactly one Image block for image media"

let test_audio_media_as_voice_block () =
  let open Agent_sdk.Types in
  let accum = A.create () in
  List.iter
    (A.on_event accum)
    [
      ContentBlockDelta
        {
          index = 0;
          delta = MediaDelta { media_type = "audio/mpeg"; source_type = Base64; data = "xy" };
        };
      ContentBlockStop { index = 0 };
    ];
  let base_dir = Filename.temp_dir "media_accum_test" "" in
  match A.to_chat_blocks ~base_dir accum with
  | [ Blocks.Voice { src = Some _; _ } ] -> ()
  | _ -> fail "expected exactly one Voice block for audio media"

let test_open_media_not_finalized () =
  (* A media block whose ContentBlockStop never arrives is not surfaced by the
     turn persist (the bridge's message-end safety net is a separate path). *)
  let open Agent_sdk.Types in
  let accum = A.create () in
  A.on_event
    accum
    (ContentBlockDelta
       {
         index = 0;
         delta = MediaDelta { media_type = "image/png"; source_type = Base64; data = "z" };
       });
  let base_dir = Filename.temp_dir "media_accum_test" "" in
  check int "no finalized media without a block stop" 0
    (List.length (A.to_chat_blocks ~base_dir accum))

let () =
  run
    "keeper_stream_media_accum"
    [
      ( "accum",
        [
          test_case "image media -> Image block" `Quick test_image_media_persisted_as_block;
          test_case "audio media -> Voice block" `Quick test_audio_media_as_voice_block;
          test_case "open media not finalized" `Quick test_open_media_not_finalized;
        ] );
    ]
