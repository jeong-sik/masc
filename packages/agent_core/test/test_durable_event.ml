(** Tests for Durable_event — event-sourced agent loop journal. *)

open Alcotest
open Agent_sdk

let ts = 1711234567.0

let append_ok journal event =
  match Durable_event.append journal event with
  | Ok () -> ()
  | Error { exception_; _ } ->
    fail ("unexpected journal observer failure: " ^ Printexc.to_string exception_)
;;

(* ── Journal basics ───────────────────────────────── *)

let test_empty_journal () =
  let j = Durable_event.create () in
  check int "empty length" 0 (Durable_event.length j);
  check (list pass) "empty events" [] (Durable_event.events j);
  check bool "no last_timestamp" true (Option.is_none (Durable_event.last_timestamp j))
;;

let test_append_and_events () =
  let j = Durable_event.create () in
  append_ok j (Turn_started { turn = 1; timestamp = ts });
  append_ok j (Turn_started { turn = 2; timestamp = ts +. 1.0 });
  check int "length 2" 2 (Durable_event.length j);
  let evts = Durable_event.events j in
  (* Chronological order *)
  match evts with
  | [ Durable_event.Turn_started { turn = 1; _ }
    ; Durable_event.Turn_started { turn = 2; _ }
    ] -> ()
  | _ -> fail "expected chronological order"
;;

let test_parallel_append_preserves_all_events () =
  let j = Durable_event.create () in
  let domain_count = 4 in
  let events_per_domain = 250 in
  let workers =
    List.init domain_count (fun domain_idx ->
      Domain.spawn (fun () ->
        for idx = 1 to events_per_domain do
          let turn = (domain_idx * events_per_domain) + idx in
          append_ok j (Turn_started { turn; timestamp = ts +. float_of_int turn })
        done))
  in
  List.iter (fun worker -> Domain.join worker) workers;
  let expected = domain_count * events_per_domain in
  check int "parallel append length" expected (Durable_event.length j);
  check int "parallel append events" expected (List.length (Durable_event.events j))
;;

let test_last_timestamp () =
  let j = Durable_event.create () in
  append_ok j (Turn_started { turn = 1; timestamp = ts });
  append_ok j (Checkpoint_saved { checkpoint_id = "cp1"; timestamp = ts +. 5.0 });
  match Durable_event.last_timestamp j with
  | Some t -> check (float 0.01) "last ts" (ts +. 5.0) t
  | None -> fail "expected timestamp"
;;

(* ── Idempotency ──────────────────────────────────── *)

let test_idempotency_key_deterministic () =
  let k1 = Durable_event.make_idempotency_key ~tool_name:"read" ~input:(`String "a") in
  let k2 = Durable_event.make_idempotency_key ~tool_name:"read" ~input:(`String "a") in
  check string "deterministic" k1 k2;
  check bool "hash tag" true (String.starts_with ~prefix:"read:fnv1a63-v2:" k1)
;;

let test_idempotency_key_unique () =
  let k1 = Durable_event.make_idempotency_key ~tool_name:"read" ~input:(`String "a") in
  let k2 = Durable_event.make_idempotency_key ~tool_name:"write" ~input:(`String "a") in
  check bool "different tools" true (k1 <> k2)
;;

let test_find_completed_activity () =
  let j = Durable_event.create () in
  let key = Durable_event.make_idempotency_key ~tool_name:"calc" ~input:(`Int 42) in
  append_ok
    j
    (Tool_called
       { turn = 1
       ; tool_name = "calc"
       ; idempotency_key = key
       ; input_hash = "h"
       ; timestamp = ts
       });
  append_ok
    j
    (Tool_completed
       { turn = 1
       ; tool_name = "calc"
       ; idempotency_key = key
       ; output_json = `String "result"
       ; is_error = false
       ; duration_ms = 10.0
       ; timestamp = ts +. 0.01
       });
  (match Durable_event.find_completed_activity j key with
   | Some (`String "result") -> ()
   | _ -> fail "expected cached result");
  (* Non-existent key *)
  check
    bool
    "missing key"
    true
    (Option.is_none (Durable_event.find_completed_activity j "nonexistent"))
;;

(* ── Replay summary ───────────────────────────────── *)

let test_replay_summary () =
  let j = Durable_event.create () in
  append_ok j (Turn_started { turn = 1; timestamp = ts });
  append_ok j (Llm_request { turn = 1; model = "test"; timestamp = ts });
  append_ok
    j
    (Llm_response
       { turn = 1
       ; input_tokens = Some 100
       ; output_tokens = Some 50
       ; stop_reason = "end_turn"
       ; duration_ms = 200.0
       ; timestamp = ts
       });
  append_ok
    j
    (Tool_completed
       { turn = 1
       ; tool_name = "read"
       ; idempotency_key = "k1"
       ; output_json = `Null
       ; is_error = false
       ; duration_ms = 5.0
       ; timestamp = ts
       });
  append_ok
    j
    (State_transition
       { from_state = "running"; to_state = "idle"; reason = "done"; timestamp = ts });
  append_ok
    j
    (Error_occurred { turn = 1; error_domain = "Api"; detail = "timeout"; timestamp = ts });
  append_ok j (Turn_started { turn = 2; timestamp = ts });
  let s = Durable_event.replay_summary j in
  check int "last_turn" 2 s.last_turn;
  check int "completed tools" 1 (List.length s.completed_tools);
  check string "last_state" "idle" s.last_state;
  check (option int) "input_tokens" (Some 100) s.total_input_tokens;
  check (option int) "output_tokens" (Some 50) s.total_output_tokens;
  check int "errors" 1 s.error_count
;;

(* ── Events for turn ──────────────────────────────── *)

let test_events_for_turn () =
  let j = Durable_event.create () in
  append_ok j (Turn_started { turn = 1; timestamp = ts });
  append_ok j (Llm_request { turn = 1; model = "m"; timestamp = ts });
  append_ok j (Turn_started { turn = 2; timestamp = ts });
  append_ok j (Llm_request { turn = 2; model = "m"; timestamp = ts });
  let t1 = Durable_event.events_for_turn j 1 in
  check int "turn 1 events" 2 (List.length t1);
  let t2 = Durable_event.events_for_turn j 2 in
  check int "turn 2 events" 2 (List.length t2)
;;

(* ── JSON round-trip ──────────────────────────────── *)

let test_json_roundtrip () =
  let j = Durable_event.create () in
  append_ok j (Turn_started { turn = 1; timestamp = ts });
  append_ok
    j
    (Tool_completed
       { turn = 1
       ; tool_name = "read"
       ; idempotency_key = "k"
       ; output_json = `String "ok"
       ; is_error = false
       ; duration_ms = 5.0
       ; timestamp = ts
       });
  append_ok
    j
    (Error_occurred { turn = 1; error_domain = "Api"; detail = "err"; timestamp = ts });
  let json = Durable_event.journal_to_json j in
  match Durable_event.journal_of_json json with
  | Ok j2 -> check int "same length" (Durable_event.length j) (Durable_event.length j2)
  | Error e -> fail (Printf.sprintf "roundtrip failed: %s" e)
;;

let test_event_json_roundtrip_all_types () =
  let events =
    [ Durable_event.Turn_started { turn = 1; timestamp = ts }
    ; Llm_request { turn = 1; model = "m"; timestamp = ts }
    ; Llm_response
        { turn = 1
        ; input_tokens = Some 10
        ; output_tokens = Some 5
        ; stop_reason = "end"
        ; duration_ms = 1.0
        ; timestamp = ts
        }
    ; Tool_called
        { turn = 1
        ; tool_name = "t"
        ; idempotency_key = "k"
        ; input_hash = "h"
        ; timestamp = ts
        }
    ; Tool_completed
        { turn = 1
        ; tool_name = "t"
        ; idempotency_key = "k"
        ; output_json = `Null
        ; is_error = false
        ; duration_ms = 1.0
        ; timestamp = ts
        }
    ; State_transition { from_state = "a"; to_state = "b"; reason = "r"; timestamp = ts }
    ; Checkpoint_saved { checkpoint_id = "c"; timestamp = ts }
    ; Error_occurred { turn = 1; error_domain = "d"; detail = "e"; timestamp = ts }
    ]
  in
  List.iter
    (fun evt ->
       let json = Durable_event.event_to_json evt in
       match Durable_event.event_of_json json with
       | Ok _ -> ()
       | Error e -> fail (Printf.sprintf "roundtrip failed: %s" e))
    events
;;

(* ── JSON schema exactness ────────────────────────── *)

let check_event_json_error expected json =
  match Durable_event.event_of_json json with
  | Ok _ -> fail (Printf.sprintf "expected parse error: %s" expected)
  | Error actual -> check string "explicit parse error" expected actual
;;

let llm_response_json token_fields =
  `Assoc
    ([ "type", `String "llm_response"
     ; "turn", `Int 1
     ; "stop_reason", `String "end"
     ; "duration_ms", `Float 1.0
     ; "timestamp", `Float ts
     ]
     @ token_fields)
;;

let test_llm_request_rejects_legacy_input_tokens () =
  check_event_json_error
    "llm_request does not accept legacy field \"input_tokens\""
    (`Assoc
        [ "type", `String "llm_request"
        ; "turn", `Int 1
        ; "model", `String "m"
        ; "input_tokens", `Int 10
        ; "timestamp", `Float ts
        ])
;;

let test_llm_response_requires_input_tokens () =
  check_event_json_error
    "llm_response requires field \"input_tokens\""
    (llm_response_json [ "output_tokens", `Int 5 ])
;;

let test_llm_response_requires_output_tokens () =
  check_event_json_error
    "llm_response requires field \"output_tokens\""
    (llm_response_json [ "input_tokens", `Int 10 ])
;;

let test_llm_response_accepts_explicit_null_usage () =
  match
    Durable_event.event_of_json
      (llm_response_json [ "input_tokens", `Null; "output_tokens", `Null ])
  with
  | Ok (Llm_response { input_tokens = None; output_tokens = None; _ }) -> ()
  | Ok _ -> fail "expected llm_response with explicitly absent usage"
  | Error error -> fail (Printf.sprintf "unexpected parse error: %s" error)
;;

let test_llm_response_rejects_invalid_usage_type () =
  check_event_json_error
    "llm_response field \"input_tokens\" must be an integer or null"
    (llm_response_json [ "input_tokens", `String "unknown"; "output_tokens", `Int 5 ])
;;

(* ── Tool completions query ───────────────────────── *)

let test_tool_completions () =
  let j = Durable_event.create () in
  append_ok
    j
    (Tool_completed
       { turn = 1
       ; tool_name = "a"
       ; idempotency_key = "k1"
       ; output_json = `Int 1
       ; is_error = false
       ; duration_ms = 1.0
       ; timestamp = ts
       });
  append_ok j (Turn_started { turn = 2; timestamp = ts });
  append_ok
    j
    (Tool_completed
       { turn = 2
       ; tool_name = "b"
       ; idempotency_key = "k2"
       ; output_json = `Int 2
       ; is_error = true
       ; duration_ms = 2.0
       ; timestamp = ts
       });
  let completions = Durable_event.tool_completions j in
  check int "2 completions" 2 (List.length completions)
;;

(* ── on_append callback ───────────────────────────── *)

let test_on_append_fires () =
  let captured = ref [] in
  let j = Durable_event.create ~on_append:(fun evt -> captured := evt :: !captured) () in
  append_ok j (Turn_started { turn = 1; timestamp = ts });
  append_ok j (Llm_request { turn = 1; model = "m"; timestamp = ts });
  check int "callback count" 2 (List.length !captured);
  check int "journal length" 2 (Durable_event.length j)
;;

let test_no_callback_default () =
  let j = Durable_event.create () in
  append_ok j (Turn_started { turn = 1; timestamp = ts });
  check int "still appends" 1 (Durable_event.length j)
;;

let test_callback_exception_is_explicit_after_append () =
  let j =
    Durable_event.create
      ~on_append:(fun _event -> failwith "projection sink unavailable")
      ()
  in
  (match Durable_event.append j (Turn_started { turn = 1; timestamp = ts }) with
   | Error { exception_ = Failure detail; backtrace }
     when String.equal detail "projection sink unavailable" ->
     check
       bool
       "raw backtrace retained"
       true
       (not (Printexc.raw_backtrace_to_string backtrace = ""))
   | Ok () -> fail "expected explicit callback failure"
   | Error { exception_; _ } ->
     fail ("unexpected callback failure: " ^ Printexc.to_string exception_));
  check int "journal still records event" 1 (Durable_event.length j);
  match Durable_event.events j with
  | [ Durable_event.Turn_started { turn = 1; _ } ] -> ()
  | _ -> fail "expected appended event to remain visible"
;;

let test_callback_cancelled_propagates_after_append () =
  let j =
    Durable_event.create ~on_append:(fun _event -> raise (Eio.Cancel.Cancelled Exit)) ()
  in
  (match Durable_event.append j (Turn_started { turn = 1; timestamp = ts }) with
   | Ok () | Error _ -> fail "expected callback cancellation to propagate"
   | exception Eio.Cancel.Cancelled _ -> ());
  check int "journal still records cancelled callback event" 1 (Durable_event.length j)
;;

(* ── Persistence ──────────────────────────────────── *)

let test_save_and_load_roundtrip () =
  let j = Durable_event.create () in
  append_ok j (Turn_started { turn = 1; timestamp = ts });
  append_ok j (Llm_request { turn = 1; model = "q"; timestamp = ts });
  append_ok
    j
    (Error_occurred { turn = 1; error_domain = "Api"; detail = "boom"; timestamp = ts });
  let path = Filename.temp_file "durable_event" ".jsonl" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | _ -> ())
    (fun () ->
       (match Durable_event.save_to_file j path with
        | Ok () -> ()
        | Error e -> fail (Printf.sprintf "save failed: %s" e));
       match Durable_event.load_from_file path with
       | Error e -> fail (Printf.sprintf "load failed: %s" e)
       | Ok j' ->
         check int "length" 3 (Durable_event.length j');
         let summary = Durable_event.replay_summary j' in
         check (option int) "total input tokens" (Some 0) summary.total_input_tokens;
         check int "error count" 1 summary.error_count)
;;

let test_load_missing_file_is_empty () =
  let missing =
    "/tmp/definitely-does-not-exist-" ^ string_of_float (Unix.gettimeofday ())
  in
  match Durable_event.load_from_file missing with
  | Ok j -> check int "empty journal" 0 (Durable_event.length j)
  | Error e -> fail (Printf.sprintf "expected Ok, got: %s" e)
;;

let test_load_malformed_returns_error () =
  let path = Filename.temp_file "durable_bad" ".jsonl" in
  let oc = open_out path in
  output_string oc "not json\n";
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | _ -> ())
    (fun () ->
       match Durable_event.load_from_file path with
       | Ok _ -> fail "expected Error"
       | Error _ -> ())
;;

(* ── Suite ────────────────────────────────────────── *)

let () =
  run
    "Durable_event"
    [ ( "journal"
      , [ test_case "empty" `Quick test_empty_journal
        ; test_case "append and events" `Quick test_append_and_events
        ; test_case
            "parallel append preserves all events"
            `Quick
            test_parallel_append_preserves_all_events
        ; test_case "last_timestamp" `Quick test_last_timestamp
        ] )
    ; ( "on_append"
      , [ test_case "callback fires" `Quick test_on_append_fires
        ; test_case "no callback default" `Quick test_no_callback_default
        ; test_case
            "callback exception is explicit after append"
            `Quick
            test_callback_exception_is_explicit_after_append
        ; test_case
            "callback cancellation propagates after append"
            `Quick
            test_callback_cancelled_propagates_after_append
        ] )
    ; ( "idempotency"
      , [ test_case "deterministic key" `Quick test_idempotency_key_deterministic
        ; test_case "unique keys" `Quick test_idempotency_key_unique
        ; test_case "find completed" `Quick test_find_completed_activity
        ] )
    ; ( "replay"
      , [ test_case "summary" `Quick test_replay_summary
        ; test_case "events for turn" `Quick test_events_for_turn
        ] )
    ; ( "serialization"
      , [ test_case "journal roundtrip" `Quick test_json_roundtrip
        ; test_case "all event types" `Quick test_event_json_roundtrip_all_types
        ; test_case
            "llm request rejects legacy input tokens"
            `Quick
            test_llm_request_rejects_legacy_input_tokens
        ; test_case
            "llm response requires input tokens"
            `Quick
            test_llm_response_requires_input_tokens
        ; test_case
            "llm response requires output tokens"
            `Quick
            test_llm_response_requires_output_tokens
        ; test_case
            "llm response accepts explicit null usage"
            `Quick
            test_llm_response_accepts_explicit_null_usage
        ; test_case
            "llm response rejects invalid usage type"
            `Quick
            test_llm_response_rejects_invalid_usage_type
        ] )
    ; "queries", [ test_case "tool completions" `Quick test_tool_completions ]
    ; ( "persistence"
      , [ test_case "save/load roundtrip" `Quick test_save_and_load_roundtrip
        ; test_case "missing file empty" `Quick test_load_missing_file_is_empty
        ; test_case "malformed returns error" `Quick test_load_malformed_returns_error
        ] )
    ]
;;
