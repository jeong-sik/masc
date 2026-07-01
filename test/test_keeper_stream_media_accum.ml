(* RFC-0301 item 6: unit tests for the turn-local generated-media accumulator. *)

open Alcotest

module A = Keeper_stream_media_accum
module Blocks = Masc.Keeper_chat_blocks

let expected_token ~media_type data =
  Digest.to_hex
    (Digest.string (String.lowercase_ascii (String.trim media_type) ^ "\000" ^ data))

let test_image_media_persisted_as_block () =
  let open Agent_sdk.Types in
  let accum = A.create () in
  let raw_media = "raw image bytes" in
  let encoded_media = Base64.encode_string raw_media in
  (* One base64 media block, then its stop. *)
  List.iter
    (A.on_event accum)
    [
      ContentBlockDelta
        {
          index = 0;
          delta =
            MediaDelta
              { media_type = "image/png"; source_type = Base64; data = encoded_media };
        };
      ContentBlockStop { index = 0 };
    ];
  let base_dir = Filename.temp_dir "media_accum_test" "" in
  match A.to_chat_blocks ~base_dir accum with
  | [ Blocks.Image { src; cap = None } ] ->
    check
      string
      "image block src is the persisted media URL for the concatenated payload"
      ("/api/v1/media/" ^ expected_token ~media_type:"image/png" raw_media)
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
          delta =
            MediaDelta
              {
                media_type = "audio/mpeg";
                source_type = Base64;
                data = Base64.encode_string "audio bytes";
              };
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
         delta =
           MediaDelta
             {
               media_type = "image/png";
               source_type = Base64;
               data = Base64.encode_string "z";
             };
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
