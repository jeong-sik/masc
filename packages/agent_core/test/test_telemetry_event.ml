(** Tests for Telemetry_event JSON round-trip and Telemetry_bus
    bounded-buffer behavior.

    Every Telemetry_event.t variant is exercised through yojson
    serialization to ensure the closed variant stays wire-compatible.
    Telemetry_bus delivery is verified without a capacity policy. *)

open Alcotest
open Agent_sdk
open Llm_provider

(* ── Helpers ──────────────────────────────────────────────────────── *)

let roundtrip event =
  let json = Telemetry_event.to_yojson event in
  match Telemetry_event.of_yojson json with
  | Ok ev -> ev
  | Error e -> failwith e
;;

let require_decoded = function
  | Ok event -> event
  | Error (failure : Telemetry_bus.decode_failure) ->
    fail ("unexpected telemetry decode failure: " ^ failure.detail)
;;

let check_float msg expected actual = check (float 0.001) msg expected actual

(* ── JSON round-trip: every variant ───────────────────────────────── *)

let test_streaming_first_chunk () =
  let ev =
    Telemetry_event.Streaming_first_chunk
      { provider = "openai"
      ; model = "gpt-4"
      ; ttfrc_ms = Some 123.456
      ; requested_at = 1000.0
      }
  in
  match roundtrip ev with
  | Telemetry_event.Streaming_first_chunk r ->
    check string "provider" "openai" r.provider;
    check string "model" "gpt-4" r.model;
    check (option (float 0.001)) "ttfrc_ms" (Some 123.456) r.ttfrc_ms;
    check_float "requested_at" 1000.0 r.requested_at
  | _ -> fail "variant mismatch"
;;

let test_streaming_summary () =
  let ev =
    Telemetry_event.Streaming_summary
      { provider = "openai"
      ; model = "gpt-4"
      ; chunk_count = 3
      ; kind_breakdown =
          { thinking = 1
          ; answer = 1
          ; tool_call_start = 0
          ; tool_call_arg_delta = 0
          ; tool_call_complete = 0
          ; substrate = 0
          ; heartbeat = 0
          ; done_ = 1
          }
      ; ttft_ms = Some 12.5
      ; prefill_ms = None
      ; total_ms = Some 120.0
      ; inter_chunk_ms_p50 = Some 20.0
      ; inter_chunk_ms_p95 = Some 40.0
      ; inter_chunk_ms_max = Some 60.0
      ; terminal = Telemetry_event.Terminal_done
      }
  in
  match roundtrip ev with
  | Telemetry_event.Streaming_summary r ->
    check string "provider" "openai" r.provider;
    check string "model" "gpt-4" r.model;
    check int "chunk_count" 3 r.chunk_count;
    check int "thinking chunks" 1 r.kind_breakdown.thinking;
    check_float "ttft_ms" 12.5 (Option.get r.ttft_ms);
    check (option (float 0.001)) "total_ms" (Some 120.0) r.total_ms;
    check (option (float 0.001)) "p95" (Some 40.0) r.inter_chunk_ms_p95;
    (match r.terminal with
     | Telemetry_event.Terminal_done -> ()
     | _ -> fail "terminal mismatch")
  | _ -> fail "variant mismatch"
;;

let test_thinking_complete () =
  let ev =
    Telemetry_event.Thinking_complete
      { provider = "openai"; model = "o3"; thinking_duration_ms = 888.8 }
  in
  match roundtrip ev with
  | Telemetry_event.Thinking_complete r ->
    check_float "thinking_duration_ms" 888.8 r.thinking_duration_ms
  | _ -> fail "variant mismatch"
;;

let test_timeout_no_response () =
  let ev =
    Telemetry_event.Timeout
      { provider = "gemini"; model = "flash"; timeout_type = Telemetry_event.No_response }
  in
  match roundtrip ev with
  | Telemetry_event.Timeout r ->
    check string "provider" "gemini" r.provider;
    (match r.timeout_type with
     | Telemetry_event.No_response -> ()
     | _ -> fail "timeout_type mismatch")
  | _ -> fail "variant mismatch"
;;

let test_timeout_ttft_exceeded () =
  let ev =
    Telemetry_event.Timeout
      { provider = "ollama"
      ; model = "llama3"
      ; timeout_type = Telemetry_event.Ttft_exceeded
      }
  in
  match roundtrip ev with
  | Telemetry_event.Timeout r ->
    (match r.timeout_type with
     | Telemetry_event.Ttft_exceeded -> ()
     | _ -> fail "timeout_type mismatch")
  | _ -> fail "variant mismatch"
;;

let test_prefill_complete () =
  let ev =
    Telemetry_event.Prefill_complete
      { provider = "ollama"
      ; model = "dashscope"
      ; prompt_eval_tokens = 1024
      ; prompt_eval_ms = 55.5
      ; cache_hit = true
      }
  in
  match roundtrip ev with
  | Telemetry_event.Prefill_complete r ->
    check int "prompt_eval_tokens" 1024 r.prompt_eval_tokens;
    check_float "prompt_eval_ms" 55.5 r.prompt_eval_ms;
    check bool "cache_hit" true r.cache_hit
  | _ -> fail "variant mismatch"
;;

let test_wire_observer_failure () =
  let failure : Wire_observer.failure =
    { capture_id = Some "run-1"
    ; provider = "openai"
    ; model = "gpt"
    ; cause = Observer_rejected { reason = "caller queue unavailable" }
    }
  in
  match roundtrip (Telemetry_event.Wire_observer_failure failure) with
  | Telemetry_event.Wire_observer_failure decoded ->
    check
      string
      "typed failure"
      (Wire_observer.show_failure failure)
      (Wire_observer.show_failure decoded)
  | _ -> fail "variant mismatch"
;;

(* ── event_type_name ──────────────────────────────────────────────── *)

let test_event_type_name () =
  let cases : (Telemetry_event.t * string) list =
    [ ( Streaming_first_chunk
          { provider = ""; model = ""; ttfrc_ms = None; requested_at = 0.0 }
      , "streaming_first_chunk" )
    ; ( Streaming_summary
          { provider = ""
          ; model = ""
          ; chunk_count = 0
          ; kind_breakdown =
              { thinking = 0
              ; answer = 0
              ; tool_call_start = 0
              ; tool_call_arg_delta = 0
              ; tool_call_complete = 0
              ; substrate = 0
              ; heartbeat = 0
              ; done_ = 0
              }
          ; ttft_ms = None
          ; prefill_ms = None
          ; total_ms = None
          ; inter_chunk_ms_p50 = None
          ; inter_chunk_ms_p95 = None
          ; inter_chunk_ms_max = None
          ; terminal = Terminal_done
          }
      , "streaming_summary" )
    ; ( Thinking_complete { provider = ""; model = ""; thinking_duration_ms = 0.0 }
      , "thinking_complete" )
    ; Timeout { provider = ""; model = ""; timeout_type = No_response }, "timeout"
    ; ( Prefill_complete
          { provider = ""
          ; model = ""
          ; prompt_eval_tokens = 0
          ; prompt_eval_ms = 0.0
          ; cache_hit = false
          }
      , "prefill_complete" )
    ; ( Wire_observer_failure
          { capture_id = Some ""
          ; provider = ""
          ; model = ""
          ; cause = Observer_rejected { reason = "" }
          }
      , "wire_observer_failure" )
    ]
  in
  List.iter
    (fun (ev, expected) ->
       check string expected expected (Telemetry_event.event_type_name ev))
    cases
;;

(* ── Telemetry_bus delivery ───────────────────────────────────────── *)

let test_telemetry_bus_preserves_fifo () =
  Eio_main.run
  @@ fun _env ->
  let bus = Telemetry_bus.create () in
  let config =
    Event_bus.subscription_config ~capacity:3 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let sub = Telemetry_bus.subscribe ~config bus in
  Telemetry_bus.publish
    bus
    (Telemetry_event.Streaming_first_chunk
       { provider = "p"; model = "m"; ttfrc_ms = Some 1.0; requested_at = 0.0 });
  Telemetry_bus.publish
    bus
    (Telemetry_event.Streaming_first_chunk
       { provider = "p"; model = "m"; ttfrc_ms = Some 2.0; requested_at = 0.0 });
  Telemetry_bus.publish
    bus
    (Telemetry_event.Streaming_first_chunk
       { provider = "p"; model = "m"; ttfrc_ms = Some 3.0; requested_at = 0.0 });
  let events = Telemetry_bus.drain sub |> List.map require_decoded in
  check int "drained every event" 3 (List.length events);
  match events with
  | [ e1; e2; e3 ] ->
    (match e1 with
     | Telemetry_event.Streaming_first_chunk r ->
       check (option (float 0.001)) "first ttfrc" (Some 1.0) r.ttfrc_ms
     | _ -> fail "expected Streaming_first_chunk");
    (match e2 with
     | Telemetry_event.Streaming_first_chunk r ->
       check (option (float 0.001)) "second ttfrc" (Some 2.0) r.ttfrc_ms
     | _ -> fail "expected Streaming_first_chunk");
    (match e3 with
     | Telemetry_event.Streaming_first_chunk r ->
       check (option (float 0.001)) "third ttfrc" (Some 3.0) r.ttfrc_ms
     | _ -> fail "expected Streaming_first_chunk")
  | _ -> fail "expected exactly 3 events"
;;

let test_telemetry_bus_preserves_decode_failure () =
  Eio_main.run
  @@ fun _env ->
  let event_bus = Event_bus.create () in
  let bus = Telemetry_bus.of_event_bus event_bus in
  let config =
    Event_bus.subscription_config ~capacity:1 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let sub = Telemetry_bus.subscribe ~config bus in
  let malformed = Event_bus.mk_event (Event_bus.Custom ("telemetry_event", `Null)) in
  Event_bus.publish event_bus malformed;
  match Telemetry_bus.drain sub with
  | [ Error { event; detail } ] ->
    check string "event id preserved" malformed.meta.run_id event.meta.run_id;
    check bool "decode detail preserved" true (String.length detail > 0)
  | [ Ok _ ] -> fail "malformed telemetry event must not decode"
  | _ -> fail "expected one explicit decode failure"
;;

(* ── Suite ────────────────────────────────────────────────────────── *)

let () =
  run
    "Telemetry_event"
    [ ( "serialization"
      , [ test_case "Streaming_first_chunk roundtrip" `Quick test_streaming_first_chunk
        ; test_case "Streaming_summary roundtrip" `Quick test_streaming_summary
        ; test_case "Thinking_complete roundtrip" `Quick test_thinking_complete
        ; test_case "Timeout No_response roundtrip" `Quick test_timeout_no_response
        ; test_case "Timeout Ttft_exceeded roundtrip" `Quick test_timeout_ttft_exceeded
        ; test_case "Prefill_complete roundtrip" `Quick test_prefill_complete
        ; test_case "Wire_observer_failure roundtrip" `Quick test_wire_observer_failure
        ] )
    ; "event_type_name", [ test_case "all variants" `Quick test_event_type_name ]
    ; ( "telemetry_bus"
      , [ test_case
            "preserves FIFO without subscriber drain"
            `Quick
            test_telemetry_bus_preserves_fifo
        ; test_case
            "preserves decode failure"
            `Quick
            test_telemetry_bus_preserves_decode_failure
        ] )
    ]
;;
