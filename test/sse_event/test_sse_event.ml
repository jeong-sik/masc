(* RFC-0004 Phase A0.1 PR-1 — byte-equal envelope test.

   Verifies that [Sse_event.agent_started] emits a JSON string that
   is byte-identical to the [cascade_event_bridge.wrap_event] output
   for the AgentStarted arm (lib/cascade/cascade_event_bridge.ml:
   556-560 + wrap_event:507-531 + json_string_opt:25-27).

   The baseline is hand-replicated below using the same algorithm as
   wrap_event/json_string_opt — this avoids linking the heavy
   cascade dependency chain (Agent_sdk, Eio, etc.) into the test
   binary.  In PR-2 (cascade migration) we replace the cascade arm
   itself, at which point the wrap_event replica below is removed
   and the test pins against the cascade output directly. *)

(* === Baseline replica: cascade_event_bridge.wrap_event + json_string_opt === *)

let baseline_json_string_opt = function
  | Some value when String.trim value <> "" -> `String value
  | _ -> `Null
;;

let baseline_wrap_event
      ~ts
      ~correlation_id
      ~run_id
      ~event_type
      ~payload
      ?agent_name
      ?task_id
      ?turn
      ?tool_name
      ()
  =
  `Assoc
    [ "type", `String ("oas:" ^ event_type)
    ; "event_type", `String event_type
    ; "ts_unix", `Float ts
    ; "correlation_id", `String correlation_id
    ; "run_id", `String run_id
    ; "agent_name", baseline_json_string_opt agent_name
    ; "task_id", baseline_json_string_opt task_id
    ; ( "turn"
      , Option.fold ~none:`Null ~some:(fun value -> `Int value) turn )
    ; "tool_name", baseline_json_string_opt tool_name
    ; "payload", payload
    ]
;;

let baseline_agent_started ~ts ~correlation_id ~run_id ~agent_name ~task_id =
  let payload =
    `Assoc
      [ "agent_name", `String agent_name; "task_id", `String task_id ]
  in
  baseline_wrap_event
    ~ts
    ~correlation_id
    ~run_id
    ~event_type:"agent_started"
    ~payload
    ~agent_name
    ~task_id
    ()
;;

(* === Tests === *)

let test_agent_started_byte_equal () =
  let ts = 1747460000.5 in
  let correlation_id = "corr-001" in
  let run_id = "run-001" in
  let agent_name = "test_agent" in
  let task_id = "task_42" in
  let baseline =
    Yojson.Safe.to_string
      (baseline_agent_started ~ts ~correlation_id ~run_id ~agent_name ~task_id)
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.agent_started
         ~ts_unix:ts
         ~correlation_id
         ~run_id
         ~agent_name
         ~task_id)
  in
  Printf.printf "\n=== A0.1 PR-1 AgentStarted byte-equal ===\n";
  Printf.printf "  baseline: %s\n" baseline;
  Printf.printf "  typed:    %s\n" typed;
  Printf.printf "  equal: %b\n" (String.equal baseline typed);
  Alcotest.(check string) "agent_started typed == cascade baseline" baseline typed
;;

(* === PR-3 byte-equal cases: tool_called, tool_completed, turn_started,
   turn_completed, turn_ready === *)

let common_ts = 1747460000.5
let common_corr = "corr-001"
let common_run = "run-001"

let baseline_tool_called ~agent_name ~tool_name =
  let payload =
    `Assoc
      [ "agent_name", `String agent_name; "tool_name", `String tool_name ]
  in
  baseline_wrap_event
    ~ts:common_ts
    ~correlation_id:common_corr
    ~run_id:common_run
    ~event_type:"tool_called"
    ~payload
    ~agent_name
    ~tool_name
    ()
;;

let baseline_tool_completed ~agent_name ~tool_name =
  let payload =
    `Assoc
      [ "agent_name", `String agent_name; "tool_name", `String tool_name ]
  in
  baseline_wrap_event
    ~ts:common_ts
    ~correlation_id:common_corr
    ~run_id:common_run
    ~event_type:"tool_completed"
    ~payload
    ~agent_name
    ~tool_name
    ()
;;

let baseline_turn_started ~agent_name ~turn =
  let payload =
    `Assoc [ "agent_name", `String agent_name; "turn", `Int turn ]
  in
  baseline_wrap_event
    ~ts:common_ts
    ~correlation_id:common_corr
    ~run_id:common_run
    ~event_type:"turn_started"
    ~payload
    ~agent_name
    ~turn
    ()
;;

let baseline_turn_completed ~agent_name ~turn =
  let payload =
    `Assoc [ "agent_name", `String agent_name; "turn", `Int turn ]
  in
  baseline_wrap_event
    ~ts:common_ts
    ~correlation_id:common_corr
    ~run_id:common_run
    ~event_type:"turn_completed"
    ~payload
    ~agent_name
    ~turn
    ()
;;

let baseline_turn_ready ~agent_name ~turn ~tool_names =
  let names_hash =
    Digest.to_hex (Digest.string (String.concat "\n" tool_names))
  in
  let payload =
    `Assoc
      [ "agent_name", `String agent_name
      ; "turn", `Int turn
      ; "count", `Int (List.length tool_names)
      ; "names_hash", `String (String.sub names_hash 0 16)
      ; ( "tool_names"
        , `List (List.map (fun name -> `String name) tool_names) )
      ]
  in
  baseline_wrap_event
    ~ts:common_ts
    ~correlation_id:common_corr
    ~run_id:common_run
    ~event_type:"turn_ready"
    ~payload
    ~agent_name
    ~turn
    ()
;;

let test_tool_called_byte_equal () =
  let baseline =
    Yojson.Safe.to_string
      (baseline_tool_called ~agent_name:"alpha" ~tool_name:"Read")
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.tool_called
         ~ts_unix:common_ts
         ~correlation_id:common_corr
         ~run_id:common_run
         ~agent_name:"alpha"
         ~tool_name:"Read")
  in
  Alcotest.(check string) "tool_called typed == baseline" baseline typed
;;

let test_tool_completed_byte_equal () =
  let baseline =
    Yojson.Safe.to_string
      (baseline_tool_completed ~agent_name:"alpha" ~tool_name:"Read")
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.tool_completed
         ~ts_unix:common_ts
         ~correlation_id:common_corr
         ~run_id:common_run
         ~agent_name:"alpha"
         ~tool_name:"Read")
  in
  Alcotest.(check string) "tool_completed typed == baseline" baseline typed
;;

let test_turn_started_byte_equal () =
  let baseline =
    Yojson.Safe.to_string (baseline_turn_started ~agent_name:"alpha" ~turn:3)
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.turn_started
         ~ts_unix:common_ts
         ~correlation_id:common_corr
         ~run_id:common_run
         ~agent_name:"alpha"
         ~turn:3)
  in
  Alcotest.(check string) "turn_started typed == baseline" baseline typed
;;

let test_turn_completed_byte_equal () =
  let baseline =
    Yojson.Safe.to_string (baseline_turn_completed ~agent_name:"alpha" ~turn:3)
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.turn_completed
         ~ts_unix:common_ts
         ~correlation_id:common_corr
         ~run_id:common_run
         ~agent_name:"alpha"
         ~turn:3)
  in
  Alcotest.(check string) "turn_completed typed == baseline" baseline typed
;;

let test_turn_ready_byte_equal () =
  let tool_names = [ "Read"; "Write"; "Bash"; "Edit" ] in
  let baseline =
    Yojson.Safe.to_string
      (baseline_turn_ready ~agent_name:"alpha" ~turn:3 ~tool_names)
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.turn_ready
         ~ts_unix:common_ts
         ~correlation_id:common_corr
         ~run_id:common_run
         ~agent_name:"alpha"
         ~turn:3
         ~tool_names)
  in
  Alcotest.(check string) "turn_ready typed == baseline" baseline typed
;;

let test_json_string_opt_empty_to_null () =
  (* Regression guard for the empty-string-coerced-to-null semantics
     that atd's default nullable does NOT express. *)
  Alcotest.(check (testable (Fmt.of_to_string Yojson.Safe.to_string) ( = )))
    "Some \"\" → `Null"
    `Null
    (Sse_event.json_string_opt (Some ""));
  Alcotest.(check (testable (Fmt.of_to_string Yojson.Safe.to_string) ( = )))
    "Some \"  \" → `Null"
    `Null
    (Sse_event.json_string_opt (Some "  "));
  Alcotest.(check (testable (Fmt.of_to_string Yojson.Safe.to_string) ( = )))
    "Some \"text\" → `String"
    (`String "text")
    (Sse_event.json_string_opt (Some "text"));
  Alcotest.(check (testable (Fmt.of_to_string Yojson.Safe.to_string) ( = )))
    "None → `Null"
    `Null
    (Sse_event.json_string_opt None)
;;

let () =
  Alcotest.run
    "sse_event"
    [ ( "byte_equal"
      , [ Alcotest.test_case "agent_started full envelope" `Quick
            test_agent_started_byte_equal
        ; Alcotest.test_case "tool_called" `Quick test_tool_called_byte_equal
        ; Alcotest.test_case "tool_completed" `Quick
            test_tool_completed_byte_equal
        ; Alcotest.test_case "turn_started" `Quick test_turn_started_byte_equal
        ; Alcotest.test_case "turn_completed" `Quick
            test_turn_completed_byte_equal
        ; Alcotest.test_case "turn_ready" `Quick test_turn_ready_byte_equal
        ] )
    ; ( "json_string_opt"
      , [ Alcotest.test_case "Some empty → null" `Quick
            test_json_string_opt_empty_to_null
        ] )
    ]
;;
