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
     reload-visible when the provider omits ContentBlockStop. Multiple open
     blocks use their protocol indexes as the terminal-order tie-breaker. *)
  let open Agent_sdk.Types in
  let accum = A.create () in
  let raw_media = "z" in
  List.iter
    (A.on_event accum)
    [ ContentBlockDelta
        { index = 1;
          delta =
            MediaDelta
              { media_type = "audio/mpeg";
                source_type = Base64;
                data = Base64.encode_string "audio"
              }
        }
    ; ContentBlockDelta
        { index = 0;
          delta =
            MediaDelta
              { media_type = "image/png";
                source_type = Base64;
                data = Base64.encode_string raw_media
              }
        }
    ];
  A.on_event accum MessageStop;
  let base_dir = Filename.temp_dir "media_accum_test" "" in
  match A.to_chat_blocks ~base_dir accum with
  | [ Blocks.Image { src; cap = None }; Blocks.Voice { src = Some _; _ } ] ->
      check
        string
        "message stop finalizes open media in block-index order"
        ("/api/v1/media/" ^ expected_token ~media_type:"image/png" raw_media)
        src
  | _ -> fail "expected Image then Voice blocks finalized at message stop"

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

let test_oversize_media_surfaces_as_dropped_placeholder () =
  let cap_env = "MASC_KEEPER_GENERATED_MEDIA_MAX_BYTES" in
  with_env cap_env "4" (fun () ->
    let open Agent_sdk.Types in
    let accum = A.create () in
    let rejected_cap = Masc.Keeper_chat_media_store.max_wire_bytes () in
    let oversized_len = rejected_cap + 1 in
    let oversized = String.make oversized_len 'A' in
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
    (* The placeholder must report the decision-time cap, even if the process
       configuration changes before the turn is persisted. *)
    Unix.putenv cap_env "8";
    let base_dir = Filename.temp_dir "media_accum_test" "" in
    match A.to_chat_blocks ~base_dir accum with
    | [ Blocks.Attach { src = None; mime_type; size_bytes; name; ph; size; _ } ] ->
        check (option string) "placeholder carries the media type"
          (Some "image/png") mime_type;
        check (option int) "placeholder carries the observed byte count"
          (Some oversized_len) size_bytes;
        check string "placeholder reports the decision-time cap"
          (Printf.sprintf
             "generated media unavailable: image/png exceeded the %d-byte wire-carrier cap"
             rejected_cap)
          name;
        check (option string) "placeholder body is explicit"
          (Some "Generated media is unavailable.") ph;
        check (option string) "placeholder distinguishes wire-carrier size"
          (Some (Printf.sprintf "%d wire-carrier bytes observed" oversized_len))
          size
    | [] ->
        fail
          "oversize media vanished: it must surface as a dropped placeholder \
           block, never disappear silently"
    | _ -> fail "expected exactly one dropped-placeholder Attach block")

let test_media_persist_failure_surfaces_as_placeholder () =
  let open Agent_sdk.Types in
  let accum = A.create () in
  let invalid_base64 = "%%%" in
  List.iter
    (A.on_event accum)
    [ ContentBlockDelta
        { index = 0;
          delta =
            MediaDelta
              { media_type = "image/png";
                source_type = Base64;
                data = invalid_base64
              }
        }
    ; ContentBlockStop { index = 0 }
    ];
  let base_dir = Filename.temp_dir "media_accum_test" "" in
  match A.to_chat_blocks ~base_dir accum with
  | [ Blocks.Attach { src = None; mime_type; size_bytes; name; _ } ] ->
      check string "decode failure is reader-visible"
        "generated media unavailable: provider returned invalid base64"
        name;
      check (option string) "decode failure carries media type"
        (Some "image/png") mime_type;
      check (option int) "decode failure carries observed bytes"
        (Some (String.length invalid_base64)) size_bytes
  | _ -> fail "expected one placeholder for a generated-media persist failure"

let test_dropped_and_persisted_media_keep_stream_order () =
  with_env "MASC_KEEPER_GENERATED_MEDIA_MAX_BYTES" "4" (fun () ->
    let open Agent_sdk.Types in
    let accum = A.create () in
    let oversized =
      String.make (Masc.Keeper_chat_media_store.max_wire_bytes () + 1) 'A'
    in
    List.iter
      (A.on_event accum)
      [ ContentBlockDelta
          { index = 0;
            delta =
              MediaDelta
                { media_type = "image/png";
                  source_type = Base64;
                  data = oversized
                }
          }
      ; ContentBlockStop { index = 0 }
      ; ContentBlockDelta
          { index = 1;
            delta =
              MediaDelta
                { media_type = "image/png";
                  source_type = Base64;
                  data = Base64.encode_string "x"
                }
          }
      ; ContentBlockStop { index = 1 }
      ];
    let base_dir = Filename.temp_dir "media_accum_test" "" in
    match A.to_chat_blocks ~base_dir accum with
    | [ Blocks.Attach { src = None; _ }; Blocks.Image _ ] -> ()
    | _ -> fail "dropped and persisted media must retain stream terminal order")

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
          test_case "oversize media surfaces as dropped placeholder" `Quick
            test_oversize_media_surfaces_as_dropped_placeholder;
          test_case "persist failure surfaces as dropped placeholder" `Quick
            test_media_persist_failure_surfaces_as_placeholder;
          test_case "dropped and persisted media retain stream order" `Quick
            test_dropped_and_persisted_media_keep_stream_order;
        ] );
    ]
