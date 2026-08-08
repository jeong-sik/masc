(** Tests for trajectory capture and serialization. *)

open Agent_sdk

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
  ; thinking_budget = None
  ; reasoning_effort = None
  ; block_index = None
  ; block_kind
  ; assistant_block
  ; tool_use_id
  ; tool_name
  ; tool_input
  ; tool_turn = None
  ; tool_planned_index = None
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
    Alcotest.(check string) "tool name" "read_file" tool_call.tool_name;
    Alcotest.(check string) "tool use id" "tu-1" tool_call.tool_use_id;
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
    { tool_use_id = "tu-step"
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
           (Trajectory.step_ts step2))
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
        ; Alcotest.test_case "tool call pairing" `Quick test_tool_call_pairing
        ; Alcotest.test_case "error run" `Quick test_error_run
        ; Alcotest.test_case "orphan tool finish" `Quick test_orphan_tool_finish
        ; Alcotest.test_case "unfinished tool" `Quick test_unfinished_tool
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
