(** Tests for trajectory capture and serialization. *)

open Agent_core

let eio_run f = Eio_main.run f

(* ── Test helpers ────────────────────────────────────────────── *)

let make_record
      ~seq
      ~ts
      ~agent_name
      ~record_type
      ?prompt
      ?model
      ?block_kind
      ?assistant_block
      ?tool_use_id
      ?tool_turn
      ?tool_planned_index
      ?tool_name
      ?tool_input
      ?tool_execution_mode
      ?tool_result
      ?tool_error
      ?final_text
      ?stop_reason
      ?error
      ()
  : Raw_trace.record
  =
  { trace_version = Raw_trace.trace_version
  ; worker_run_id = "wr-test-0000"
  ; seq
  ; ts
  ; agent_name
  ; session_id = None
  ; record_type
  ; prompt
  ; model
  ; tool_choice = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; reasoning_effort = None
  ; block_index = None
  ; block_kind
  ; assistant_block
  ; tool_use_id
  ; tool_name
  ; native_tool_identity = None
  ; native_tool_origin = None
  ; tool_input
  ; tool_turn
  ; tool_planned_index
  ; tool_batch_index = None
  ; tool_batch_size = None
  ; tool_execution_mode
  ; tool_result
  ; tool_error
  ; hook_name = None
  ; hook_decision = None
  ; hook_detail = None
  ; final_text
  ; stop_reason
  ; error
  }
;;

(* ── Trajectory from raw records ─────────────────────────────── *)

let test_basic_trajectory () =
  let records =
    [ make_record
        ~seq:1
        ~ts:100.0
        ~agent_name:"test-agent"
        ~record_type:Run_started
        ~prompt:"hello"
        ~model:"glm-5.1"
        ()
    ; make_record
        ~seq:2
        ~ts:100.1
        ~agent_name:"test-agent"
        ~record_type:Assistant_block
        ~block_kind:"thinking"
        ~assistant_block:(`Assoc [ "content", `String "let me think" ])
        ()
    ; make_record
        ~seq:3
        ~ts:100.2
        ~agent_name:"test-agent"
        ~record_type:Assistant_block
        ~block_kind:"text"
        ~assistant_block:(`Assoc [ "text", `String "answer here" ])
        ()
    ; make_record
        ~seq:4
        ~ts:100.3
        ~agent_name:"test-agent"
        ~record_type:Run_finished
        ~final_text:"answer here"
        ()
    ]
  in
  let traj = Trajectory.of_raw_trace_records records in
  Alcotest.(check string) "agent_name" "test-agent" traj.agent_name;
  Alcotest.(check string) "model" "glm-5.1" traj.model;
  Alcotest.(check string) "prompt" "hello" traj.prompt;
  Alcotest.(check bool) "success" true traj.success;
  let think, _act, _obs, respond = Trajectory.count_steps traj in
  Alcotest.(check int) "think steps" 1 think;
  Alcotest.(check int) "respond steps" 1 respond;
  (* final_text matches existing respond step, so no duplicate *)
  ()
;;

let test_all_withheld_reasoning_kinds_are_activity () =
  let withheld kind seq =
    make_record
      ~seq
      ~ts:(100.0 +. Float.of_int seq)
      ~agent_name:"test-agent"
      ~record_type:Assistant_block
      ~block_kind:kind
      ~assistant_block:
        (`Assoc
          [ "observation", `String "withheld"
          ; "content", `Null
          ])
      ()
  in
  let trajectory =
    Trajectory.of_raw_trace_records
      [ withheld "thinking" 1
      ; withheld "reasoning_details" 2
      ; withheld "redacted_thinking" 3
      ]
  in
  let think, _act, _observe, _respond = Trajectory.count_steps trajectory in
  Alcotest.(check int) "all reasoning variants remain visible as activity" 3 think
;;

let test_tool_call_pairing () =
  let records =
    [ make_record
        ~seq:1
        ~ts:200.0
        ~agent_name:"tool-agent"
        ~record_type:Run_started
        ~prompt:"use a tool"
        ()
    ; make_record
        ~seq:2
        ~ts:200.1
        ~agent_name:"tool-agent"
        ~record_type:Tool_execution_started
        ~tool_use_id:"tu-1"
        ~tool_turn:1 ~tool_planned_index:0
        ~tool_name:"read_file"
        ~tool_input:(`Assoc [ "path", `String "/foo" ])
        ~tool_execution_mode:Tool_contract.Serial
        ()
    ; make_record
        ~seq:3
        ~ts:200.5
        ~agent_name:"tool-agent"
        ~record_type:Tool_execution_finished
        ~tool_use_id:"tu-1"
        ~tool_turn:1 ~tool_planned_index:0
        ~tool_name:"read_file"
        ~tool_result:"file contents here"
        ~tool_error:false
        ()
    ; make_record
        ~seq:4
        ~ts:200.6
        ~agent_name:"tool-agent"
        ~record_type:Run_finished
        ~final_text:"done"
        ()
    ]
  in
  let traj = Trajectory.of_raw_trace_records records in
  let _think, act, obs, respond = Trajectory.count_steps traj in
  Alcotest.(check int) "act steps (tool calls)" 1 act;
  Alcotest.(check int) "observe steps (tool results)" 1 obs;
  Alcotest.(check int) "respond steps" 1 respond;
  Alcotest.(check int) "total tool calls" 1 (Trajectory.total_tool_calls traj);
  Alcotest.(check int) "tool errors" 0 (Trajectory.tool_error_count traj);
  (* Verify tool_call details *)
  let act_step =
    List.find
      (function
        | Trajectory.Act _ -> true
        | _ -> false)
      traj.steps
  in
  match act_step with
  | Trajectory.Act { tool_call; _ } ->
    Alcotest.(check (option int)) "exact raw start sequence" (Some 2) tool_call.source_seq;
    Alcotest.(check string) "tool name" "read_file" tool_call.tool_name;
    Alcotest.(check (option string))
      "tool use id"
      (Some "tu-1")
      tool_call.tool_use_id;
    Alcotest.(check (option string))
      "tool result"
      (Some "file contents here")
      tool_call.tool_result;
    Alcotest.(check bool) "not error" false tool_call.is_error
  | _ -> Alcotest.fail "expected Act step"
;;

let test_error_run () =
  let records =
    [ make_record
        ~seq:1
        ~ts:300.0
        ~agent_name:"fail-agent"
        ~record_type:Run_started
        ~prompt:"do something"
        ()
    ; make_record
        ~seq:2
        ~ts:300.5
        ~agent_name:"fail-agent"
        ~record_type:Run_finished
        ~error:"something went wrong"
        ()
    ]
  in
  let traj = Trajectory.of_raw_trace_records records in
  Alcotest.(check bool) "success" false traj.success;
  Alcotest.(check (option string)) "error" (Some "something went wrong") traj.error;
  Alcotest.(check bool) "has finished_at" true (Option.is_some traj.finished_at)
;;

let test_orphan_tool_finish () =
  (* Tool_execution_finished without matching Started *)
  let records =
    [ make_record
        ~seq:1
        ~ts:400.0
        ~agent_name:"orphan-agent"
        ~record_type:Run_started
        ~prompt:"test"
        ()
    ; make_record
        ~seq:2
        ~ts:400.3
        ~agent_name:"orphan-agent"
        ~record_type:Tool_execution_finished
        ~tool_use_id:"tu-orphan"
        ~tool_turn:1 ~tool_planned_index:0
        ~tool_name:"bash"
        ~tool_result:"ok"
        ~tool_error:false
        ()
    ; make_record ~seq:3 ~ts:400.4 ~agent_name:"orphan-agent" ~record_type:Run_finished ()
    ]
  in
  let traj = Trajectory.of_raw_trace_records records in
  let _think, act, _obs, _respond = Trajectory.count_steps traj in
  (* Orphan finish still creates an Act step *)
  Alcotest.(check int) "act steps from orphan" 1 act
;;

let test_unfinished_tool () =
  (* Tool_execution_started without matching Finished *)
  let records =
    [ make_record
        ~seq:1
        ~ts:500.0
        ~agent_name:"pending-agent"
        ~record_type:Run_started
        ~prompt:"test"
        ()
    ; make_record
        ~seq:2
        ~ts:500.1
        ~agent_name:"pending-agent"
        ~record_type:Tool_execution_started
        ~tool_use_id:"tu-pending"
        ~tool_turn:1 ~tool_planned_index:0
        ~tool_name:"long_op"
        ~tool_input:(`Assoc [])
        ~tool_execution_mode:Tool_contract.Serial
        ()
    ; make_record
        ~seq:3
        ~ts:500.5
        ~agent_name:"pending-agent"
        ~record_type:Run_finished
        ()
    ]
  in
  let traj = Trajectory.of_raw_trace_records records in
  let _think, act, _obs, _respond = Trajectory.count_steps traj in
  Alcotest.(check int) "pending tool flushed as act" 1 act;
  (* The flushed tool has no result *)
  let act_step =
    List.find
      (function
        | Trajectory.Act _ -> true
        | _ -> false)
      traj.steps
  in
  match act_step with
  | Trajectory.Act { tool_call; _ } ->
    Alcotest.(check (option string)) "no result" None tool_call.tool_result;
    Alcotest.(check bool) "no finished_at" true (Option.is_none tool_call.finished_at)
  | _ -> Alcotest.fail "expected Act step"
;;

let test_missing_tool_ids_are_not_correlated () =
  let records =
    [ make_record
        ~seq:1
        ~ts:550.0
        ~agent_name:"missing-id-agent"
        ~record_type:Tool_execution_started
        ~tool_name:"first"
        ~tool_input:(`Assoc [])
        ()
    ; make_record
        ~seq:2
        ~ts:550.1
        ~agent_name:"missing-id-agent"
        ~record_type:Tool_execution_started
        ~tool_use_id:""
        ~tool_name:"second"
        ~tool_input:(`Assoc [])
        ()
    ; make_record
        ~seq:3
        ~ts:550.2
        ~agent_name:"missing-id-agent"
        ~record_type:Tool_execution_finished
        ~tool_use_id:""
        ~tool_name:"finished-without-id"
        ~tool_result:"unattributed"
        ~tool_error:false
        ()
    ]
  in
  let trajectory = Trajectory.of_raw_trace_records records in
  let _think, act, observe, _respond = Trajectory.count_steps trajectory in
  Alcotest.(check int) "each uncorrelated record remains visible" 3 act;
  Alcotest.(check int) "unattributed result is not attached to a start" 0 observe;
  List.iter
    (function
      | Trajectory.Act { tool_call; _ } ->
        Alcotest.(check (option string)) "missing id stays typed" None tool_call.tool_use_id
      | _ -> ())
    trajectory.steps
;;

let tool_calls records =
  (Trajectory.of_raw_trace_records records).steps
  |> List.filter_map (function
      | Trajectory.Act { tool_call; _ } -> Some tool_call
      | _ -> None)
;;

let test_overlapping_provider_ids_pair_exact_occurrences () =
  let start ~seq ~ts ~turn ~index path =
    make_record ~seq ~ts ~agent_name:"parallel-agent"
      ~record_type:Tool_execution_started ~tool_use_id:"provider-reused"
      ~tool_turn:turn ~tool_planned_index:index ~tool_name:"Edit"
      ~tool_input:(`Assoc [ "path", `String path ])
      ~tool_execution_mode:Tool_contract.Concurrent ()
  in
  let finish ~seq ~ts ~turn ~index ~is_error result =
    make_record ~seq ~ts ~agent_name:"parallel-agent"
      ~record_type:Tool_execution_finished ~tool_use_id:"provider-reused"
      ~tool_turn:turn ~tool_planned_index:index ~tool_name:"Edit"
      ~tool_result:result ~tool_error:is_error ()
  in
  let calls = tool_calls
    [ start ~seq:10 ~ts:700.0 ~turn:4 ~index:0 "first.ml"
    ; start ~seq:11 ~ts:701.0 ~turn:4 ~index:1 "second.ml"
    ; start ~seq:12 ~ts:702.0 ~turn:5 ~index:0 "pending.ml"
    ; finish ~seq:13 ~ts:703.0 ~turn:4 ~index:1 ~is_error:true "second failed"
    ; finish ~seq:14 ~ts:706.0 ~turn:4 ~index:0 ~is_error:false "first changed"
    ]
  in
  Alcotest.(check int) "all three invocations survive" 3 (List.length calls);
  let check_call seq path result is_error duration =
    let call = List.find (fun (call : Trajectory.tool_call) ->
        call.source_seq = Some seq) calls in
    Alcotest.(check (option string)) "provider id retained"
      (Some "provider-reused") call.tool_use_id;
    Alcotest.(check string) "invocation input retained" path
      Yojson.Safe.Util.(call.tool_input |> member "path" |> to_string);
    Alcotest.(check (option string)) "correct result" result call.tool_result;
    Alcotest.(check bool) "correct error status" is_error call.is_error;
    Alcotest.(check (option (float 0.001))) "duration uses own start"
      duration (Option.map (fun finished -> finished -. call.started_at) call.finished_at)
  in
  check_call 10 "first.ml" (Some "first changed") false (Some 6.0);
  check_call 11 "second.ml" (Some "second failed") true (Some 2.0);
  check_call 12 "pending.ml" None false None
;;

let test_incomplete_coordinates_remain_unpaired () =
  let record ~seq ~record_type ?tool_turn ?tool_planned_index ?tool_result () =
    make_record ~seq ~ts:(800.0 +. Float.of_int seq) ~agent_name:"partial-agent"
      ~record_type ~tool_use_id:"same-id" ~tool_name:"Edit"
      ?tool_turn ?tool_planned_index ?tool_result ()
  in
  List.iter (fun (turn, index) ->
    let calls = tool_calls
      [ record ~seq:1 ~record_type:Tool_execution_started
          ?tool_turn:turn ?tool_planned_index:index ()
      ; record ~seq:2 ~record_type:Tool_execution_finished
          ?tool_turn:turn ?tool_planned_index:index ~tool_result:"unattributed" ()
      ] in
    match calls with
    | [ start; finish ] ->
      Alcotest.(check (option int)) "start sequence retained" (Some 1) start.source_seq;
      Alcotest.(check (option string)) "id alone does not attach result" None start.tool_result;
      Alcotest.(check (option (float 0.001))) "start remains pending" None start.finished_at;
      Alcotest.(check (option int)) "finish has no source start" None finish.source_seq;
      Alcotest.(check (option string)) "unpaired finish retains result"
        (Some "unattributed") finish.tool_result
    | _ -> Alcotest.fail "incomplete coordinates must preserve both records")
    [ None, None; Some 1, None; None, Some 0 ]
;;

let test_finish_before_start_is_not_backfilled () =
  let record ~seq ~record_type ?tool_result () =
    make_record ~seq ~ts:(900.0 +. Float.of_int seq) ~agent_name:"out-of-order"
      ~record_type ~tool_use_id:"same-id" ~tool_turn:1 ~tool_planned_index:0
      ~tool_name:"Edit" ?tool_result ()
  in
  match tool_calls
    [ record ~seq:1 ~record_type:Tool_execution_finished ~tool_result:"early" ()
    ; record ~seq:2 ~record_type:Tool_execution_started ()
    ] with
  | [ finish; start ] ->
    Alcotest.(check (option int)) "early finish remains unmatched" None finish.source_seq;
    Alcotest.(check (option int)) "later start remains visible" (Some 2) start.source_seq;
    Alcotest.(check (option string)) "later start gets no earlier result" None start.tool_result;
    Alcotest.(check (option (float 0.001))) "later start remains pending" None start.finished_at
  | _ -> Alcotest.fail "out-of-order records must remain separate"
;;

let test_ambiguous_starts_remain_unpaired () =
  let record ~seq ~record_type ?tool_result () =
    make_record ~seq ~ts:(950.0 +. Float.of_int seq) ~agent_name:"ambiguous"
      ~record_type ~tool_use_id:"same-id" ~tool_turn:1 ~tool_planned_index:0
      ~tool_name:"Edit" ?tool_result ()
  in
  let calls = tool_calls
    [ record ~seq:1 ~record_type:Tool_execution_started ()
    ; record ~seq:2 ~record_type:Tool_execution_started ()
    ; record ~seq:3 ~record_type:Tool_execution_finished ~tool_result:"ambiguous" ()
    ] in
  match calls with
  | [ first; second; finish ] ->
    Alcotest.(check (option int)) "first start retained" (Some 1) first.source_seq;
    Alcotest.(check (option int)) "second start retained" (Some 2) second.source_seq;
    Alcotest.(check (option string)) "first remains unpaired" None first.tool_result;
    Alcotest.(check (option string)) "second remains unpaired" None second.tool_result;
    Alcotest.(check (option int)) "finish cannot choose between starts" None finish.source_seq
  | _ -> Alcotest.fail "ambiguous occurrences must not overwrite starts"
;;

(* ── JSON round-trip ─────────────────────────────────────────── *)

let test_json_roundtrip () =
  let records =
    [ make_record
        ~seq:1
        ~ts:600.0
        ~agent_name:"json-agent"
        ~record_type:Run_started
        ~prompt:"roundtrip test"
        ()
    ; make_record
        ~seq:2
        ~ts:600.1
        ~agent_name:"json-agent"
        ~record_type:Assistant_block
        ~block_kind:"thinking"
        ~assistant_block:(`Assoc [ "content", `String "hmm" ])
        ()
    ; make_record
        ~seq:3
        ~ts:600.2
        ~agent_name:"json-agent"
        ~record_type:Tool_execution_started
        ~tool_use_id:"tu-rt"
        ~tool_turn:1 ~tool_planned_index:0
        ~tool_name:"search"
        ~tool_input:(`Assoc [ "q", `String "test" ])
        ~tool_execution_mode:Tool_contract.Concurrent
        ()
    ; make_record
        ~seq:4
        ~ts:600.3
        ~agent_name:"json-agent"
        ~record_type:Tool_execution_finished
        ~tool_use_id:"tu-rt"
        ~tool_turn:1 ~tool_planned_index:0
        ~tool_name:"search"
        ~tool_result:"found it"
        ~tool_error:false
        ()
    ; make_record
        ~seq:5
        ~ts:600.4
        ~agent_name:"json-agent"
        ~record_type:Assistant_block
        ~block_kind:"text"
        ~assistant_block:(`Assoc [ "text", `String "result is here" ])
        ()
    ; make_record
        ~seq:6
        ~ts:600.5
        ~agent_name:"json-agent"
        ~record_type:Run_finished
        ~final_text:"result is here"
        ()
    ]
  in
  let traj = Trajectory.of_raw_trace_records records in
  let json = Trajectory.to_json traj in
  let json_str = Yojson.Safe.to_string json in
  (* Parse it back *)
  let json2 = Yojson.Safe.from_string json_str in
  match Trajectory.of_json json2 with
  | Error e -> Alcotest.fail (Printf.sprintf "JSON parse failed: %s" e)
  | Ok traj2 ->
    Alcotest.(check string) "agent_name roundtrip" traj.agent_name traj2.agent_name;
    Alcotest.(check string) "model roundtrip" traj.model traj2.model;
    Alcotest.(check string) "prompt roundtrip" traj.prompt traj2.prompt;
    Alcotest.(check bool) "success roundtrip" traj.success traj2.success;
    let th1, ac1, ob1, re1 = Trajectory.count_steps traj in
    let th2, ac2, ob2, re2 = Trajectory.count_steps traj2 in
    Alcotest.(check int) "think count" th1 th2;
    Alcotest.(check int) "act count" ac1 ac2;
    Alcotest.(check int) "observe count" ob1 ob2;
    Alcotest.(check int) "respond count" re1 re2
;;

let test_step_json_roundtrip () =
  let tc : Trajectory.tool_call =
    { tool_use_id = Some "tu-step"
    ; source_seq = Some 7
    ; tool_name = "grep"
    ; tool_input = `Assoc [ "pattern", `String "foo" ]
    ; tool_result = Some "match found"
    ; is_error = false
    ; started_at = 1.0
    ; finished_at = Some 2.0
    }
  in
  let steps =
    [ Trajectory.Think { content = "thinking"; ts = 0.5 }
    ; Trajectory.Act { tool_call = tc; ts = 1.0 }
    ; Trajectory.Observe { content = "saw result"; ts = 2.0 }
    ; Trajectory.Respond { content = "done"; ts = 3.0 }
    ]
  in
  List.iter
    (fun step ->
       let json = Trajectory.step_to_json step in
       match Trajectory.step_of_json json with
       | Error e -> Alcotest.fail (Printf.sprintf "step roundtrip failed: %s" e)
       | Ok step2 ->
         (* Compare timestamps as a basic check *)
         Alcotest.(check (float 0.001))
           "ts roundtrip"
           (Trajectory.step_ts step)
           (Trajectory.step_ts step2);
         (match step, step2 with
          | Trajectory.Act { tool_call = before; _ }, Trajectory.Act { tool_call = after; _ } ->
            Alcotest.(check (option int)) "source sequence roundtrip"
              before.source_seq after.source_seq
          | _ -> ()))
    steps
;;

(* ── count_steps ─────────────────────────────────────────────── *)

let test_count_steps_empty () =
  let traj : Trajectory.trajectory =
    { agent_name = "empty"
    ; model = "m"
    ; prompt = ""
    ; steps = []
    ; started_at = 0.0
    ; finished_at = None
    ; success = true
    ; metrics = None
    ; error = None
    }
  in
  let th, ac, ob, re = Trajectory.count_steps traj in
  Alcotest.(check int) "think" 0 th;
  Alcotest.(check int) "act" 0 ac;
  Alcotest.(check int) "observe" 0 ob;
  Alcotest.(check int) "respond" 0 re
;;

(* ── elapsed_s ───────────────────────────────────────────────── *)

let test_elapsed_s () =
  let traj : Trajectory.trajectory =
    { agent_name = "t"
    ; model = "m"
    ; prompt = ""
    ; steps = []
    ; started_at = 100.0
    ; finished_at = Some 105.5
    ; success = true
    ; metrics = None
    ; error = None
    }
  in
  Alcotest.(check (option (float 0.001))) "elapsed" (Some 5.5) (Trajectory.elapsed_s traj)
;;

let test_elapsed_s_none () =
  let traj : Trajectory.trajectory =
    { agent_name = "t"
    ; model = "m"
    ; prompt = ""
    ; steps = []
    ; started_at = 100.0
    ; finished_at = None
    ; success = true
    ; metrics = None
    ; error = None
    }
  in
  Alcotest.(check (option (float 0.001))) "no elapsed" None (Trajectory.elapsed_s traj)
;;

(* ── Test suite ──────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "trajectory"
    [ ( "trajectory"
      , [ Alcotest.test_case "basic trajectory from records" `Quick test_basic_trajectory
        ; Alcotest.test_case
            "all withheld reasoning kinds remain activity"
            `Quick
            test_all_withheld_reasoning_kinds_are_activity
        ; Alcotest.test_case "tool call pairing" `Quick test_tool_call_pairing
        ; Alcotest.test_case "overlapping provider ids pair exact occurrences" `Quick
            test_overlapping_provider_ids_pair_exact_occurrences
        ; Alcotest.test_case "incomplete coordinates remain unpaired" `Quick
            test_incomplete_coordinates_remain_unpaired
        ; Alcotest.test_case "finish before start is not backfilled" `Quick
            test_finish_before_start_is_not_backfilled
        ; Alcotest.test_case "ambiguous starts remain unpaired" `Quick
            test_ambiguous_starts_remain_unpaired
        ; Alcotest.test_case "error run" `Quick test_error_run
        ; Alcotest.test_case "orphan tool finish" `Quick test_orphan_tool_finish
        ; Alcotest.test_case "unfinished tool" `Quick test_unfinished_tool
        ; Alcotest.test_case
            "missing tool ids are not correlated"
            `Quick
            test_missing_tool_ids_are_not_correlated
        ] )
    ; ( "json"
      , [ Alcotest.test_case "trajectory json roundtrip" `Quick test_json_roundtrip
        ; Alcotest.test_case "step json roundtrip" `Quick test_step_json_roundtrip
        ] )
    ; ( "analysis"
      , [ Alcotest.test_case "count_steps empty" `Quick test_count_steps_empty
        ; Alcotest.test_case "elapsed_s" `Quick test_elapsed_s
        ; Alcotest.test_case "elapsed_s none" `Quick test_elapsed_s_none
        ] )
    ]
;;
