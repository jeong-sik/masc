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
      | None -> Unix.unsetenv key)
    (fun () ->
      Unix.putenv key value;
      f ())

let expected_token ~media_type data =
  Digestif.SHA256.(
    digest_string (String.lowercase_ascii (String.trim media_type) ^ "\000" ^ data)
    |> to_hex)

let test_image_media_persisted_as_block () =
  let open Agent_core.Types in
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
  let open Agent_core.Types in
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

let test_runtime_attempt_discards_unfinished_media () =
  let open Agent_core.Types in
  let accum = A.create () in
  A.start_runtime_attempt accum;
  A.on_event accum
    (ContentBlockDelta
       { index = 0
       ; delta =
           MediaDelta
             { media_type = "image/png"
             ; source_type = Base64
             ; data = Base64.encode_string "stale"
             }
       });
  A.start_runtime_attempt accum;
  let fresh = "fresh" in
  A.on_event accum
    (ContentBlockDelta
       { index = 0
       ; delta =
           MediaDelta
             { media_type = "image/png"
             ; source_type = Base64
             ; data = Base64.encode_string fresh
             }
       });
  A.on_event accum (ContentBlockStop { index = 0 });
  let base_dir = Filename.temp_dir "media_accum_test" "" in
  match A.to_chat_blocks ~base_dir accum with
  | [ Blocks.Image { src; _ } ] ->
    check string "fallback media excludes failed-attempt chunks"
      ("/api/v1/media/" ^ expected_token ~media_type:"image/png" fresh)
      src
  | _ -> fail "expected only the fallback attempt image"
;;

(* A liveness timeout ends the attempt like a provider failure. The media block
   it left open is discarded, so a stop for that index afterwards completes
   nothing and the fallback carries no image from the timed-out attempt. *)
let test_timeout_discards_unfinished_media () =
  let open Agent_core.Types in
  let accum = A.create () in
  A.start_runtime_attempt accum;
  A.on_event accum
    (ContentBlockDelta
       { index = 0
       ; delta =
           MediaDelta
             { media_type = "image/png"
             ; source_type = Base64
             ; data = Base64.encode_string "timed out"
             }
       });
  A.on_event accum (Timeout "idle timeout after 120.0s");
  A.on_event accum (ContentBlockStop { index = 0 });
  let base_dir = Filename.temp_dir "media_accum_test" "" in
  check int "no media block from the timed-out attempt" 0
    (List.length (A.to_chat_blocks ~base_dir accum))
;;

let test_open_media_finalized_on_message_stop () =
  (* Mirrors the bridge's message-end safety net: an open media block is still
     reload-visible when the provider omits ContentBlockStop. Multiple open
     blocks use their protocol indexes as the terminal-order tie-breaker. *)
  let open Agent_core.Types in
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

let test_stop_reason_finalizes_media_until_next_exact_scope () =
  let open Agent_core.Types in
  let accum = A.create () in
  A.on_event ~stream_scope:0 accum
    (ContentBlockDelta
       { index = 0
       ; delta =
           MediaDelta
             { media_type = "image/png"
             ; source_type = Base64
             ; data = Base64.encode_string "first"
             }
       });
  A.on_event ~stream_scope:0 accum
    (MessageDelta { stop_reason = Some EndTurn; usage = None });
  A.on_event ~stream_scope:0 accum
    (ContentBlockDelta
       { index = 0
       ; delta =
           MediaDelta
             { media_type = "image/png"
             ; source_type = Base64
             ; data = Base64.encode_string "late"
             }
       });
  A.on_event ~stream_scope:1 accum
    (ContentBlockDelta
       { index = 0
       ; delta =
           MediaDelta
             { media_type = "image/png"
             ; source_type = Base64
             ; data = Base64.encode_string "second"
             }
       });
  A.on_event ~stream_scope:1 accum (ContentBlockStop { index = 0 });
  let base_dir = Filename.temp_dir "media_accum_test" "" in
  match A.to_chat_blocks ~base_dir accum with
  | [ Blocks.Image { src = first; _ }; Blocks.Image { src = second; _ } ] ->
    check string "terminal media excludes late bytes"
      ("/api/v1/media/" ^ expected_token ~media_type:"image/png" "first")
      first;
    check string "new exact scope may reuse the index"
      ("/api/v1/media/" ^ expected_token ~media_type:"image/png" "second")
      second
  | _ -> fail "expected one finalized image per exact stream scope"
;;

let test_tool_block_media_not_persisted () =
  let open Agent_core.Types in
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
  let open Agent_core.Types in
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
    let open Agent_core.Types in
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
  let open Agent_core.Types in
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
    let open Agent_core.Types in
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

(* Follow the HTTP collector callbacks into actual media and failed-request
   transcript storage. This does not invoke the HTTP route or a provider. *)
let test_failed_request_reloads_completed_media_across_attempts () =
  with_env "MASC_KEEPER_GENERATED_MEDIA_MAX_BYTES" "1024" @@ fun () ->
  with_env "MASC_KEEPER_GENERATED_MEDIA_DIR_MAX_BYTES" "1024" @@ fun () ->
  with_env "MASC_KEEPER_GENERATED_MEDIA_RETENTION_SEC" "86400" @@ fun () ->
  let open Agent_core.Types in
  let module Tool = Masc.Keeper_stream_tool_accum in
  let module Media = Masc.Keeper_chat_media_store in
  let module Store = Masc.Keeper_chat_store in
  let module Delivery = Keeper_chat_delivery_identity in
  let require label = function
    | Ok value -> value
    | Error error -> failf "%s: %s" label error
  in
  let rec remove path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path
    | _ -> Unix.unlink path
  in
  let previous_fs = Fs_compat.get_fs_opt () in
  let base_dir = Filename.temp_dir "media_accum_failure_reload_" "" in
  Fun.protect
    ~finally:(fun () ->
      (match previous_fs with
       | Some fs -> Fs_compat.set_fs fs
       | None -> Fs_compat.clear_fs ());
      remove base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let media = A.create () in
      let tools = Tool.create () in
      (* HTTP marks the media attempt first, then the exact scope owner. *)
      let start_attempt () =
        A.start_runtime_attempt media;
        ignore (Tool.start_runtime_attempt tools)
      in
      (* HTTP delivers each raw event to the scope owner before media. *)
      let on_event event =
        Tool.on_event tools event;
        let stream_scope = Tool.current_stream_scope tools in
        A.on_event ~stream_scope media event
      in
      let media_type = "image/png" in
      let image ~index raw =
        on_event
          (ContentBlockStart
             { index; content_type = "image"; tool_id = None; tool_name = None });
        let encoded = Base64.encode_string raw in
        let split = String.length encoded / 2 in
        List.iter
          (fun data ->
            on_event
              (ContentBlockDelta
                 { index; delta = MediaDelta { media_type; source_type = Base64; data } }))
          [ String.sub encoded 0 split
          ; String.sub encoded split (String.length encoded - split)
          ]
      in
      let raw_a = "\000completed-A\255" in
      let raw_b = "\000unfinished-B\255" in
      let raw_c = "\000completed-C\255" in
      let prelude =
        MessageStart { id = "reused-provider-message"; model = "media-fixture"; usage = None }
      in
      start_attempt ();
      on_event prelude;
      image ~index:0 raw_a;
      on_event (ContentBlockStop { index = 0 });
      image ~index:1 raw_b;
      on_event (Timeout "first runtime attempt failed");
      start_attempt ();
      on_event prelude;
      image ~index:0 raw_c;
      let terminal = MessageDelta { stop_reason = Some Refusal; usage = None } in
      List.iter on_event
        [ terminal; terminal; MessageStop; MessageStop; terminal; MessageStop
        ; Timeout "final runtime attempt failed"
        ];
      let blocks = A.to_chat_blocks ~base_dir media in
      let image_sources =
        List.map (function
          | Blocks.Image { src; cap = None } -> src
          | _ -> fail "expected completed image blocks without captions")
      in
      let token raw = expected_token ~media_type raw in
      let expected_sources =
        List.map (fun raw -> "/api/v1/media/" ^ token raw) [ raw_a; raw_c ]
      in
      check (list string) "completed A/C remain ordered without terminal duplicates"
        expected_sources (image_sources blocks);
      List.iter
        (fun (label, raw) ->
          match Media.file_path_of_token ~base_dir ~token:(token raw) with
          | None -> failf "%s media file is absent" label
          | Some path ->
              check string (label ^ " file contains the decoded bytes") raw
                (In_channel.with_open_bin path In_channel.input_all))
        [ "A", raw_a; "C", raw_c ];
      check (option string) "unfinished B never becomes a media file" None
        (Media.file_path_of_token ~base_dir ~token:(token raw_b));
      let keeper_name = "media-failure-reload" in
      let operation_id =
        Delivery.Request_id.of_string "media-failure-operation"
        |> require "operation identity"
      in
      let failure = "Runtime attempts failed after producing completed media." in
      Server_keeper_operation_transcript.persist ~base_dir ~keeper_name ~operation_id
        ~resumed_from:None
        ~settlement:(Server_keeper_operation_transcript.Request_failed failure)
        ~tool_calls:[] ~blocks ()
      |> require "failed-request transcript persistence";
      let rows =
        match Store.load_all_result ~base_dir ~keeper_name with
        | Ok rows -> rows
        | Error error ->
          failf "strict transcript reload: %s"
            (Store.strict_decode_error_to_string error)
      in
      match rows with
      | [ row ] ->
          check bool "reload retains the server failure role" true
            (Store.Role.equal row.role Store.Role.Request_failure);
          check string "failure content survives reload" failure row.content;
          (match row.blocks with
           | Some reloaded ->
               check (list string) "durable failure retains only ordered completed A/C"
                 expected_sources (image_sources reloaded)
           | None -> fail "failed-request transcript lost its completed media");
          let expected_provenance : Delivery.delivery_provenance =
            { delivery_key = Delivery.Operation operation_id
            ; transcript_slot = Delivery.Terminal_result
            }
          in
          check bool "failure belongs to the exact operation terminal slot" true
            (Option.equal Delivery.delivery_provenance_equal
               (Some expected_provenance) row.delivery_provenance)
      | rows -> failf "expected one failed-request row, found %d" (List.length rows))

let () =
  run
    "keeper_stream_media_accum"
    [
      ( "accum",
        [
          test_case "image media -> Image block" `Quick test_image_media_persisted_as_block;
          test_case "audio media -> Voice block" `Quick test_audio_media_as_voice_block;
          test_case "runtime attempt discards unfinished media" `Quick
            test_runtime_attempt_discards_unfinished_media;
          test_case "liveness timeout discards unfinished media" `Quick
            test_timeout_discards_unfinished_media;
          test_case "open media finalized on message stop" `Quick
            test_open_media_finalized_on_message_stop;
          test_case "stop reason freezes media until next exact scope" `Quick
            test_stop_reason_finalizes_media_until_next_exact_scope;
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
          test_case "failed request reloads completed media across runtime attempts" `Quick
            test_failed_request_reloads_completed_media_across_attempts;
        ] );
    ]
