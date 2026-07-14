(* RFC-0004 Phase A0.1 PR-1 — byte-equal envelope test.

   Verifies that [Sse_event.agent_started] emits a JSON string that
   is byte-identical to the [runtime_event_bridge.wrap_event] output
   for the AgentStarted arm (lib/runtime/runtime_event_bridge.ml:
   556-560 + wrap_event:507-531 + json_string_opt:25-27).

   The baseline is hand-replicated below using the same algorithm as
   wrap_event/json_string_opt — this avoids linking the heavy
   runtime dependency chain (Agent_sdk, Eio, etc.) into the test
   binary.  In PR-2 (runtime migration) we replace the runtime arm
   itself, at which point the wrap_event replica below is removed
   and the test pins against the runtime output directly. *)

(* === Baseline replica: runtime_event_bridge.wrap_event + json_string_opt === *)

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
      ?caused_by
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
    ; "caused_by", baseline_json_string_opt caused_by
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
  Alcotest.(check string) "agent_started typed == runtime baseline" baseline typed
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
  let tool_names = [ "Read"; "Write"; "Execute"; "Edit" ] in
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

(* === PR-4 byte-equal cases: handoff, context, content_replacement,
   slot_scheduler === *)

let baseline_handoff_requested ~from_agent ~to_agent ~reason =
  let payload =
    `Assoc
      [ "from_agent", `String from_agent
      ; "to_agent", `String to_agent
      ; "reason", `String reason
      ]
  in
  baseline_wrap_event
    ~ts:common_ts
    ~correlation_id:common_corr
    ~run_id:common_run
    ~event_type:"handoff_requested"
    ~payload
    ~agent_name:from_agent
    ()
;;

let baseline_handoff_completed ~from_agent ~to_agent ~elapsed_s =
  let payload =
    `Assoc
      [ "from_agent", `String from_agent
      ; "to_agent", `String to_agent
      ; "elapsed_s", `Float elapsed_s
      ]
  in
  baseline_wrap_event
    ~ts:common_ts
    ~correlation_id:common_corr
    ~run_id:common_run
    ~event_type:"handoff_completed"
    ~payload
    ~agent_name:from_agent
    ()
;;

let baseline_context_compacted
      ~agent_name
      ~before_tokens
      ~after_tokens
      ~phase
  =
  let payload =
    `Assoc
      [ "agent_name", `String agent_name
      ; "before_tokens", `Int before_tokens
      ; "after_tokens", `Int after_tokens
      ; "phase", `String phase
      ]
  in
  baseline_wrap_event
    ~ts:common_ts
    ~correlation_id:common_corr
    ~run_id:common_run
    ~event_type:"context_compacted"
    ~payload
    ~agent_name
    ()
;;

let baseline_context_overflow_imminent
      ~agent_name
      ~estimated_tokens
      ~limit_tokens
      ~ratio
  =
  let payload =
    `Assoc
      [ "agent_name", `String agent_name
      ; "estimated_tokens", `Int estimated_tokens
      ; "limit_tokens", `Int limit_tokens
      ; "ratio", `Float ratio
      ]
  in
  baseline_wrap_event
    ~ts:common_ts
    ~correlation_id:common_corr
    ~run_id:common_run
    ~event_type:"context_overflow_imminent"
    ~payload
    ~agent_name
    ()
;;

let baseline_context_compact_started ~agent_name ~trigger =
  let payload =
    `Assoc
      [ "agent_name", `String agent_name; "trigger", `String trigger ]
  in
  baseline_wrap_event
    ~ts:common_ts
    ~correlation_id:common_corr
    ~run_id:common_run
    ~event_type:"context_compact_started"
    ~payload
    ~agent_name
    ()
;;

let baseline_content_replacement_replaced
      ~tool_use_id
      ~preview
      ~original_chars
      ~seen_count_after
  =
  let payload =
    `Assoc
      [ "tool_use_id", `String tool_use_id
      ; "preview", `String preview
      ; "original_chars", `Int original_chars
      ; "seen_count_after", `Int seen_count_after
      ]
  in
  baseline_wrap_event
    ~ts:common_ts
    ~correlation_id:common_corr
    ~run_id:common_run
    ~event_type:"content_replacement_replaced"
    ~payload
    ()
;;

let baseline_content_replacement_kept ~tool_use_id ~seen_count_after =
  let payload =
    `Assoc
      [ "tool_use_id", `String tool_use_id
      ; "seen_count_after", `Int seen_count_after
      ]
  in
  baseline_wrap_event
    ~ts:common_ts
    ~correlation_id:common_corr
    ~run_id:common_run
    ~event_type:"content_replacement_kept"
    ~payload
    ()
;;

let baseline_slot_scheduler_observed
      ~max_slots
      ~active
      ~available
      ~queue_length
      ~state
  =
  let payload =
    `Assoc
      [ "max_slots", `Int max_slots
      ; "active", `Int active
      ; "available", `Int available
      ; "queue_length", `Int queue_length
      ; "state", `String state
      ]
  in
  baseline_wrap_event
    ~ts:common_ts
    ~correlation_id:common_corr
    ~run_id:common_run
    ~event_type:"slot_scheduler_observed"
    ~payload
    ()
;;

let test_handoff_requested_byte_equal () =
  let baseline =
    Yojson.Safe.to_string
      (baseline_handoff_requested
         ~from_agent:"alpha"
         ~to_agent:"beta"
         ~reason:"low_progress")
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.handoff_requested
         ~ts_unix:common_ts
         ~correlation_id:common_corr
         ~run_id:common_run
         ~from_agent:"alpha"
         ~to_agent:"beta"
         ~reason:"low_progress")
  in
  Alcotest.(check string) "handoff_requested typed == baseline" baseline typed
;;

let test_handoff_completed_byte_equal () =
  let baseline =
    Yojson.Safe.to_string
      (baseline_handoff_completed
         ~from_agent:"alpha"
         ~to_agent:"beta"
         ~elapsed_s:1.25)
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.handoff_completed
         ~ts_unix:common_ts
         ~correlation_id:common_corr
         ~run_id:common_run
         ~from_agent:"alpha"
         ~to_agent:"beta"
         ~elapsed_s:1.25)
  in
  Alcotest.(check string) "handoff_completed typed == baseline" baseline typed
;;

let test_context_compacted_byte_equal () =
  let baseline =
    Yojson.Safe.to_string
      (baseline_context_compacted
         ~agent_name:"alpha"
         ~before_tokens:120000
         ~after_tokens:42000
         ~phase:"post_compact")
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.context_compacted
         ~ts_unix:common_ts
         ~correlation_id:common_corr
         ~run_id:common_run
         ~agent_name:"alpha"
         ~before_tokens:120000
         ~after_tokens:42000
         ~phase:"post_compact")
  in
  Alcotest.(check string) "context_compacted typed == baseline" baseline typed
;;

let test_context_overflow_imminent_byte_equal () =
  let baseline =
    Yojson.Safe.to_string
      (baseline_context_overflow_imminent
         ~agent_name:"alpha"
         ~estimated_tokens:180000
         ~limit_tokens:200000
         ~ratio:0.9)
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.context_overflow_imminent
         ~ts_unix:common_ts
         ~correlation_id:common_corr
         ~run_id:common_run
         ~agent_name:"alpha"
         ~estimated_tokens:180000
         ~limit_tokens:200000
         ~ratio:0.9)
  in
  Alcotest.(check string)
    "context_overflow_imminent typed == baseline"
    baseline
    typed
;;

let test_context_compact_started_byte_equal () =
  let baseline =
    Yojson.Safe.to_string
      (baseline_context_compact_started ~agent_name:"alpha" ~trigger:"manual")
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.context_compact_started
         ~ts_unix:common_ts
         ~correlation_id:common_corr
         ~run_id:common_run
         ~agent_name:"alpha"
         ~trigger:"manual")
  in
  Alcotest.(check string)
    "context_compact_started typed == baseline"
    baseline
    typed
;;

let test_content_replacement_replaced_byte_equal () =
  let baseline =
    Yojson.Safe.to_string
      (baseline_content_replacement_replaced
         ~tool_use_id:"tu_1"
         ~preview:"<truncated 1024 chars>"
         ~original_chars:1024
         ~seen_count_after:3)
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.content_replacement_replaced
         ~ts_unix:common_ts
         ~correlation_id:common_corr
         ~run_id:common_run
         ~tool_use_id:"tu_1"
         ~preview:"<truncated 1024 chars>"
         ~original_chars:1024
         ~seen_count_after:3)
  in
  Alcotest.(check string)
    "content_replacement_replaced typed == baseline"
    baseline
    typed
;;

let test_content_replacement_kept_byte_equal () =
  let baseline =
    Yojson.Safe.to_string
      (baseline_content_replacement_kept ~tool_use_id:"tu_1" ~seen_count_after:1)
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.content_replacement_kept
         ~ts_unix:common_ts
         ~correlation_id:common_corr
         ~run_id:common_run
         ~tool_use_id:"tu_1"
         ~seen_count_after:1)
  in
  Alcotest.(check string)
    "content_replacement_kept typed == baseline"
    baseline
    typed
;;

let test_slot_scheduler_observed_byte_equal () =
  let baseline =
    Yojson.Safe.to_string
      (baseline_slot_scheduler_observed
         ~max_slots:8
         ~active:5
         ~available:3
         ~queue_length:0
         ~state:"idle")
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.slot_scheduler_observed
         ~ts_unix:common_ts
         ~correlation_id:common_corr
         ~run_id:common_run
         ~max_slots:8
         ~active:5
         ~available:3
         ~queue_length:0
         ~state:"idle")
  in
  Alcotest.(check string)
    "slot_scheduler_observed typed == baseline"
    baseline
    typed
;;

(* === PR-3b byte-equal cases: agent_completed (Ok + Error), agent_failed.

   These three cases pin the caller-supplied-addendum splice path
   (Sse_event.merge_addendum_into_record) against the pre-PR-3b
   inline `Assoc construction in runtime_event_bridge.ml.  Field
   order is [base record (atd declaration order) @ addendum]. *)

let baseline_agent_completed ~agent_name ~task_id ~elapsed_s ~result_fields =
  let payload =
    `Assoc
      ([ "agent_name", `String agent_name
       ; "task_id", `String task_id
       ; "elapsed_s", `Float elapsed_s
       ]
       @ result_fields)
  in
  baseline_wrap_event
    ~ts:common_ts
    ~correlation_id:common_corr
    ~run_id:common_run
    ~event_type:"agent_completed"
    ~payload
    ~agent_name
    ~task_id
    ()
;;

let baseline_agent_failed ~agent_name ~task_id ~elapsed_s ~error_fields =
  let payload =
    `Assoc
      ([ "agent_name", `String agent_name
       ; "task_id", `String task_id
       ; "elapsed_s", `Float elapsed_s
       ]
       @ error_fields)
  in
  baseline_wrap_event
    ~ts:common_ts
    ~correlation_id:common_corr
    ~run_id:common_run
    ~event_type:"agent_failed"
    ~payload
    ~agent_name
    ~task_id
    ()
;;

let agent_completed_ok_fields : (string * Yojson.Safe.t) list =
  (* Shape mirrors runtime_event_bridge.agent_completed_result_fields
     for the Ok branch, including the usage tail.  Concrete values are
     arbitrary -- the test pins the byte-equal property, not the
     business meaning. *)
  [ "success", `Bool true
  ; "result", `String "ok"
  ; "response_id", `String "resp_abc"
  ; "model", `String "claude-opus"
  ; "stop_reason", `String "end_turn"
  ; "input_tokens", `Int 1234
  ; "output_tokens", `Int 567
  ; "cost_usd", `Float 0.0125
  ]
;;

let agent_completed_error_fields : (string * Yojson.Safe.t) list =
  [ "success", `Bool false
  ; "result", `String "error"
  ; "error", `String "HookExecutionFailed { hook_name = post_tool_use }"
  ; "usage_reported", `Bool false
  ]
;;

let agent_failed_error : string =
  "HookExecutionFailed { hook_name = post_tool_use }"

let agent_failed_error_domain : string = "agent"
let agent_failed_error_code : string = "hook_execution_failed"
let agent_failed_error_retryable : bool = false

let agent_failed_error_detail : Yojson.Safe.t =
  `Assoc
    [ "variant", `String "hook_execution_failed"
    ; "hook_name", `String "post_tool_use"
    ; "stage", `String "execute"
    ]
;;

let agent_failed_error_fields_sample : (string * Yojson.Safe.t) list =
  [ "error", `String agent_failed_error
  ; "error_domain", `String agent_failed_error_domain
  ; "error_code", `String agent_failed_error_code
  ; "error_retryable", `Bool agent_failed_error_retryable
  ; "error_detail", agent_failed_error_detail
  ]
;;

let test_agent_completed_ok_byte_equal () =
  let baseline =
    Yojson.Safe.to_string
      (baseline_agent_completed
         ~agent_name:"alpha"
         ~task_id:"task_42"
         ~elapsed_s:3.5
         ~result_fields:agent_completed_ok_fields)
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.agent_completed
         ~ts_unix:common_ts
         ~correlation_id:common_corr
         ~run_id:common_run
         ~agent_name:"alpha"
         ~task_id:"task_42"
         ~elapsed_s:3.5
         ~result_fields:agent_completed_ok_fields)
  in
  Alcotest.(check string)
    "agent_completed (Ok) typed == baseline"
    baseline
    typed
;;

let test_agent_completed_error_byte_equal () =
  let baseline =
    Yojson.Safe.to_string
      (baseline_agent_completed
         ~agent_name:"alpha"
         ~task_id:"task_42"
         ~elapsed_s:3.5
         ~result_fields:agent_completed_error_fields)
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.agent_completed
         ~ts_unix:common_ts
         ~correlation_id:common_corr
         ~run_id:common_run
         ~agent_name:"alpha"
         ~task_id:"task_42"
         ~elapsed_s:3.5
         ~result_fields:agent_completed_error_fields)
  in
  Alcotest.(check string)
    "agent_completed (Error) typed == baseline"
    baseline
    typed
;;

let test_agent_failed_byte_equal () =
  let baseline =
    Yojson.Safe.to_string
      (baseline_agent_failed
         ~agent_name:"alpha"
         ~task_id:"task_42"
         ~elapsed_s:3.5
         ~error_fields:agent_failed_error_fields_sample)
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.agent_failed
         ~ts_unix:common_ts
         ~correlation_id:common_corr
         ~run_id:common_run
         ~agent_name:"alpha"
         ~task_id:"task_42"
         ~elapsed_s:3.5
         ~error:agent_failed_error
         ~error_domain:agent_failed_error_domain
         ~error_code:agent_failed_error_code
         ~error_retryable:agent_failed_error_retryable
         ~error_detail:agent_failed_error_detail
         ())
  in
  Alcotest.(check string) "agent_failed typed == baseline" baseline typed
;;

let test_agent_completed_empty_addendum_byte_equal () =
  (* Regression guard for the empty-addendum case -- byte-equal
     property must hold even when [result_fields = []], confirming
     the splice helper does not introduce trailing commas / spacing. *)
  let baseline =
    Yojson.Safe.to_string
      (baseline_agent_completed
         ~agent_name:"alpha"
         ~task_id:"task_42"
         ~elapsed_s:0.001
         ~result_fields:[])
  in
  let typed =
    Yojson.Safe.to_string
      (Sse_event.agent_completed
         ~ts_unix:common_ts
         ~correlation_id:common_corr
         ~run_id:common_run
         ~agent_name:"alpha"
         ~task_id:"task_42"
         ~elapsed_s:0.001
         ~result_fields:[])
  in
  Alcotest.(check string)
    "agent_completed (empty addendum) typed == baseline"
    baseline
    typed
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
        ; Alcotest.test_case "handoff_requested" `Quick
            test_handoff_requested_byte_equal
        ; Alcotest.test_case "handoff_completed" `Quick
            test_handoff_completed_byte_equal
        ; Alcotest.test_case "context_compacted" `Quick
            test_context_compacted_byte_equal
        ; Alcotest.test_case "context_overflow_imminent" `Quick
            test_context_overflow_imminent_byte_equal
        ; Alcotest.test_case "context_compact_started" `Quick
            test_context_compact_started_byte_equal
        ; Alcotest.test_case "content_replacement_replaced" `Quick
            test_content_replacement_replaced_byte_equal
        ; Alcotest.test_case "content_replacement_kept" `Quick
            test_content_replacement_kept_byte_equal
        ; Alcotest.test_case "slot_scheduler_observed" `Quick
            test_slot_scheduler_observed_byte_equal
        ; Alcotest.test_case "agent_completed (Ok)" `Quick
            test_agent_completed_ok_byte_equal
        ; Alcotest.test_case "agent_completed (Error)" `Quick
            test_agent_completed_error_byte_equal
        ; Alcotest.test_case "agent_failed" `Quick test_agent_failed_byte_equal
        ; Alcotest.test_case "agent_completed (empty addendum)" `Quick
            test_agent_completed_empty_addendum_byte_equal
        ] )
    ; ( "json_string_opt"
      , [ Alcotest.test_case "Some empty → null" `Quick
            test_json_string_opt_empty_to_null
        ] )
    ]
;;
