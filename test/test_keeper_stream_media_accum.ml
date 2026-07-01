(* RFC-0301 item 6: unit tests for the turn-local generated-media accumulator. *)

open Alcotest

module A = Keeper_stream_media_accum
module Blocks = Masc.Keeper_chat_blocks

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some previous -> Unix.putenv key previous
      | None -> Unix.putenv key "")
    (fun () ->
      Unix.putenv key value;
      f ())

let expected_token ~media_type data =
  Digestif.SHA256.(
    digest_string (String.lowercase_ascii (String.trim media_type) ^ "\000" ^ data)
    |> to_hex)

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

let test_open_media_finalized_on_message_stop () =
  (* Mirrors the bridge's message-end safety net: an open media block is still
     reload-visible when the provider omits ContentBlockStop. *)
  let open Agent_sdk.Types in
  let accum = A.create () in
  let raw_media = "z" in
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
               data = Base64.encode_string raw_media;
             };
       });
  A.on_event accum MessageStop;
  let base_dir = Filename.temp_dir "media_accum_test" "" in
  match A.to_chat_blocks ~base_dir accum with
  | [ Blocks.Image { src; cap = None } ] ->
      check
        string
        "message stop finalizes open media"
        ("/api/v1/media/" ^ expected_token ~media_type:"image/png" raw_media)
        src
  | _ -> fail "expected one Image block finalized at message stop"

let test_tool_block_media_not_persisted () =
  let open Agent_sdk.Types in
  let accum = A.create () in
  List.iter
    (A.on_event accum)
    [
      ContentBlockStart
        {
          index = 0;
          content_type = "tool_use";
          tool_id = Some "tc-media-conflict";
          tool_name = Some "keeper_memory_search";
        };
      ContentBlockDelta
        {
          index = 0;
          delta =
            MediaDelta
              {
                media_type = "image/png";
                source_type = Base64;
                data = Base64.encode_string "must not persist";
              };
        };
      ContentBlockStop { index = 0 };
    ];
  let base_dir = Filename.temp_dir "media_accum_test" "" in
  check int "media delta for tool block is not persisted" 0
    (List.length (A.to_chat_blocks ~base_dir accum))

let test_metadata_drift_preserves_first_media_block () =
  let open Agent_sdk.Types in
  let accum = A.create () in
  let raw_media = "first media" in
  List.iter
    (A.on_event accum)
    [
      ContentBlockDelta
        {
          index = 0;
          delta =
            MediaDelta
              {
                media_type = "image/png";
                source_type = Base64;
                data = Base64.encode_string raw_media;
              };
        };
      ContentBlockDelta
        {
          index = 0;
          delta =
            MediaDelta
              {
                media_type = "audio/mpeg";
                source_type = Base64;
                data = Base64.encode_string "drift";
              };
        };
      ContentBlockStop { index = 0 };
    ];
  let base_dir = Filename.temp_dir "media_accum_test" "" in
  match A.to_chat_blocks ~base_dir accum with
  | [ Blocks.Image { src; cap = None } ] ->
      check
        string
        "metadata drift keeps first media block"
        ("/api/v1/media/" ^ expected_token ~media_type:"image/png" raw_media)
        src
  | _ -> fail "expected metadata drift to preserve the first image media block"

let test_oversize_media_not_persisted () =
  with_env "MASC_KEEPER_GENERATED_MEDIA_MAX_BYTES" "4" (fun () ->
    let open Agent_sdk.Types in
    let accum = A.create () in
    let oversized =
      String.make (Masc.Keeper_chat_media_store.max_wire_bytes () + 1) 'A'
    in
    List.iter
      (A.on_event accum)
      [
        ContentBlockDelta
          {
            index = 0;
            delta =
              MediaDelta
                { media_type = "image/png"; source_type = Base64; data = oversized };
          };
        ContentBlockStop { index = 0 };
      ];
    let base_dir = Filename.temp_dir "media_accum_test" "" in
    check int "oversize media is not persisted" 0
      (List.length (A.to_chat_blocks ~base_dir accum)))

let () =
  run
    "keeper_stream_media_accum"
    [
      ( "accum",
        [
          test_case "image media -> Image block" `Quick test_image_media_persisted_as_block;
          test_case "audio media -> Voice block" `Quick test_audio_media_as_voice_block;
          test_case "open media finalized on message stop" `Quick
            test_open_media_finalized_on_message_stop;
          test_case "tool block media not persisted" `Quick
            test_tool_block_media_not_persisted;
          test_case "metadata drift preserves first media block" `Quick
            test_metadata_drift_preserves_first_media_block;
          test_case "oversize media not persisted" `Quick
            test_oversize_media_not_persisted;
        ] );
    ]
