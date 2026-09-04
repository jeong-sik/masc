(* RFC-0412 stage 1 — canonical keeper chat event log: codec, journal, and
   golden replay tests. *)

module E = Masc.Keeper_chat_events
module L = Masc.Keeper_chat_event_log
module Blocks = Masc.Keeper_chat_blocks
module Surface = Masc.Keeper_surface_post
module Outcome = Masc.Keeper_turn_outcome

let occurrence : E.tool_stream_occurrence =
  { stream_scope = 7; provider_message_id = Some "pm-1"; block_index = 2 }

let occurrence_anon : E.tool_stream_occurrence =
  { stream_scope = 0; provider_message_id = None; block_index = 0 }

let usage_full : Agent_core.Types.api_usage =
  { input_tokens = 10
  ; output_tokens = 4
  ; cache_creation_input_tokens = 1
  ; cache_read_input_tokens = 2
  ; cost_usd = Some 0.001
  }

let delta_usage_partial : Agent_core.Types.delta_usage =
  { input_tokens = Some 10
  ; output_tokens = None
  ; cache_creation_input_tokens = Some 1
  ; cache_read_input_tokens = None
  }

let protocol_error_full : E.stream_protocol_error =
  { kind = E.Tool_args_without_start
  ; quarantined_occurrence = Some occurrence
  ; index = Some 2
  ; tool_call_id = Some "tc-1"
  ; event_type = Some "content_block_delta"
  ; reason = Some "args before start"
  ; raw_bytes = Some 128
  }

let protocol_error_sparse : E.stream_protocol_error =
  { kind = E.Sse_stream_repeating
  ; quarantined_occurrence = None
  ; index = None
  ; tool_call_id = None
  ; event_type = None
  ; reason = None
  ; raw_bytes = None
  }

(* One instance per [keeper_chat_event] constructor (33 total), covering both
   population variants of every option field. *)
let all_events : E.keeper_chat_event list =
  [ E.Run_started { run_id = "run-1"; thread_id = "thread-1" }
  ; E.Text_message_start { message_id = "msg-1"; role = E.User }
  ; E.Text_message_start { message_id = "msg-2"; role = E.Assistant }
  ; E.Text_delta "hello"
  ; E.Text_message_end
  ; E.External_effect_completed
      { target =
          Surface.Delivered_to_slack { channel_id = "C123"; thread_ts = Some "1700.5" }
      }
  ; E.External_effect_completed { target = Surface.Delivered_to_dashboard }
  ; E.Run_finished { run_id = "run-1" }
  ; E.Event_error { message = "boom" }
  ; E.Reply_details
      { reply = "done"
      ; turn_outcome = Outcome.Visible_reply
      ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:3
      }
  ; E.Continuation_checkpoint { message = "paused"; request_id = Some "req-9" }
  ; E.Continuation_checkpoint { message = "paused"; request_id = None }
  ; E.Agent_core_stream_connected
  ; E.Agent_core_runtime_attempt_started
  ; E.Agent_core_stream_message_start
      { provider_message_id = "pm-1"; model = "kimi-for-coding"; usage = Some usage_full }
  ; E.Agent_core_stream_message_start
      { provider_message_id = "pm-2"; model = "m"; usage = None }
  ; E.Agent_core_stream_message_delta
      { stop_reason = Some Agent_core.Types.EndTurn
      ; usage = Some delta_usage_partial
      }
  ; E.Agent_core_stream_message_delta { stop_reason = None; usage = None }
  ; E.Agent_core_stream_message_stop
  ; E.Agent_core_stream_ping
  ; E.Agent_core_content_block_start
      { index = 0
      ; content_type = "tool_use"
      ; tool_call_id = Some "tc-1"
      ; tool_call_name = Some "read_file"
      }
  ; E.Agent_core_content_block_start
      { index = 1; content_type = "text"; tool_call_id = None; tool_call_name = None }
  ; E.Agent_core_content_block_stop { index = 0 }
  ; E.Agent_core_thinking_delta { index = 3; delta = "pondering" }
  ; E.Agent_core_thinking_signature_delta { index = 3; signature_bytes = 42 }
  ; E.Agent_core_media_delta
      { index = 4
      ; media_type = "image/png"
      ; source_type = Agent_core.Types.Base64
      ; media_ref = "/api/v1/media/tok-1"
      }
  ; E.Agent_core_stream_protocol_error protocol_error_full
  ; E.Agent_core_stream_protocol_error protocol_error_sparse
  ; E.Tool_call_start
      { occurrence; tool_call_id = Some "tc-1"; tool_call_name = "read_file" }
  ; E.Tool_call_args
      { occurrence = occurrence_anon; tool_call_id = None; delta = "{\"path\":" }
  ; E.Tool_call_args_snapshot
      { occurrence; tool_call_id = None; snapshot = "{\"path\":\"/tmp\"}" }
  ; E.Tool_call_end { occurrence; tool_call_id = Some "tc-1" }
  ; E.Tool_approval_requested
      { tool_call_id = "tc-2"
      ; tool_call_name = "bash"
      ; args = "{\"cmd\":\"ls\"}"
      ; question = "allow?"
      ; because = "policy"
      }
  ; E.Tool_approval_settled { tool_call_id = "tc-2"; outcome = "approved" }
  ; E.Tool_result_ready
      { occurrence
      ; tool_call_id = Some "tc-1"
      ; execution_id = Ids.Execution_id.of_string "exec-1"
      }
  ; E.Link_block
      { url = "https://example.com"
      ; title = "Example"
      ; description = Some "desc"
      ; image = None
      }
  ; E.Image_block { url = "https://example.com/i.png"; caption = Some "cap" }
  ; E.Image_block { url = "https://example.com/j.png"; caption = None }
  ; E.Status_block { kind = Blocks.Continuation_checkpoint }
  ; E.Status_block { kind = Blocks.Awaiting_gate_approval }
  ; E.Audio_block
      { token = "aud-1"
      ; mime = "audio/ogg"
      ; message_text = "hi"
      ; duration_sec = Some 1.5
      }
  ; E.Audio_block { token = "aud-2"; mime = "audio/mp3"; message_text = "yo"; duration_sec = None }
  ; E.Tool_context_block
      { tool_call_id = "tc-3"
      ; name = "grep"
      ; args_summary = "pat x"
      ; result_summary = Some "3 hits"
      }
  ]

(* [keeper_chat_event] has no [equal]; JSON-level round-trip is the equality
   oracle: decode(encode(e)) re-encoded must be byte-identical to encode(e). *)
let test_codec_round_trip_all_constructors () =
  List.iteri
    (fun i event ->
       let encoded = L.keeper_chat_event_to_json event in
       match L.keeper_chat_event_of_json encoded with
       | Error detail ->
         Alcotest.failf "constructor %d failed to decode: %s\njson: %s"
           i detail (Yojson.Safe.to_string encoded)
       | Ok decoded ->
         Alcotest.(check string)
           (Printf.sprintf "constructor %d round-trips" i)
           (Yojson.Safe.to_string encoded)
           (Yojson.Safe.to_string (L.keeper_chat_event_to_json decoded)))
    all_events

let test_envelope_round_trip () =
  let entry : L.journaled_event =
    { seq = 3; ts = 1_762_300_000.25; event = E.Text_delta "hi" }
  in
  let encoded = L.journaled_event_to_json entry in
  match L.journaled_event_of_json encoded with
  | Error detail -> Alcotest.failf "envelope decode failed: %s" detail
  | Ok decoded ->
    Alcotest.(check int) "seq" 3 decoded.seq;
    Alcotest.(check (float 0.0)) "ts" 1_762_300_000.25 decoded.ts;
    Alcotest.(check string)
      "event"
      (Yojson.Safe.to_string (L.keeper_chat_event_to_json entry.event))
      (Yojson.Safe.to_string (L.keeper_chat_event_to_json decoded.event))

let test_envelope_rejects_unknown_version () =
  let json =
    `Assoc
      [ "v", `Int 99
      ; "seq", `Int 0
      ; "ts", `Float 1.0
      ; "event", `Assoc [ "type", `String "text_delta"; "delta", `String "x" ]
      ]
  in
  match L.journaled_event_of_json json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "unknown codec version must be rejected"

let test_codec_rejects_unknown_tag () =
  match L.keeper_chat_event_of_json (`Assoc [ "type", `String "nope" ]) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "unknown event tag must be rejected"

let () =
  Alcotest.run
    "keeper_chat_event_log"
    [ ( "codec"
      , [ Alcotest.test_case
            "round trip all constructors"
            `Quick
            test_codec_round_trip_all_constructors
        ; Alcotest.test_case "envelope round trip" `Quick test_envelope_round_trip
        ; Alcotest.test_case
            "envelope rejects unknown version"
            `Quick
            test_envelope_rejects_unknown_version
        ; Alcotest.test_case
            "codec rejects unknown tag"
            `Quick
            test_codec_rejects_unknown_tag
        ] )
    ]
