(** Exact-run activity projection guards for Keeper_autonomous_turn_source. *)

open Masc

let keeper_name = "keeper-autonomous-source"
let agent_name = "keeper-autonomous-agent"
let runtime_agent_name = "oas-test-runtime"
let trace_id = "trace-test-0000"

let temp_dir () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_autonomous_turn_source_%d_%d" (Unix.getpid ())
         (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir
;;

let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree dir)
    (fun () -> f (Workspace.default_config dir))
;;

let ensure_trace_dir config =
  let dir = Keeper_types_support.keeper_raw_trace_dir config keeper_name in
  let rec mkdir_p path =
    if not (Sys.file_exists path)
    then (
      mkdir_p (Filename.dirname path);
      try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  mkdir_p dir;
  dir
;;

let raw_record ~worker_run_id ~seq ~ts ~record_type fields =
  `Assoc
    (("trace_version", `Int Agent_sdk.Raw_trace.trace_version)
     :: ("worker_run_id", `String worker_run_id)
     :: ("seq", `Int seq)
     :: ("ts", `Float ts)
     :: ("agent_name", `String runtime_agent_name)
     :: ("session_id", `String trace_id)
     :: ("record_type", `String (Agent_sdk.Raw_trace.record_type_to_string record_type))
     :: fields)
;;

let run_lines ~worker_run_id ~start_seq ~base_ts ~prompt ~final_text =
  [ raw_record ~worker_run_id ~seq:start_seq ~ts:base_ts
      ~record_type:Agent_sdk.Raw_trace.Run_started
      [ "prompt", `String prompt; "model", `String "test-model" ]
  ; raw_record ~worker_run_id ~seq:(start_seq + 1) ~ts:(base_ts +. 1.)
      ~record_type:Agent_sdk.Raw_trace.Assistant_block
      [ "block_index", `Int 0
      ; "block_kind", `String "thinking"
      ; ( "assistant_block"
        , `Assoc
            [ "type", `String "thinking"
            ; "thinking", `String "private chain of thought"
            ] )
      ]
  ; raw_record ~worker_run_id ~seq:(start_seq + 2) ~ts:(base_ts +. 2.)
      ~record_type:Agent_sdk.Raw_trace.Tool_execution_started
      [ "tool_name", `String "Read"
      ; "tool_input", `Assoc [ "path", `String "secret.ml" ]
      ; "tool_use_id", `String ("tool-" ^ worker_run_id)
      ; "tool_turn", `Int 1
      ; "tool_planned_index", `Int 0
      ; "tool_batch_index", `Int 0
      ; "tool_batch_size", `Int 1
      ; "tool_execution_mode", `String "serial"
      ]
  ; raw_record ~worker_run_id ~seq:(start_seq + 3) ~ts:(base_ts +. 3.)
      ~record_type:Agent_sdk.Raw_trace.Tool_execution_finished
      [ "tool_name", `String "Read"
      ; "tool_result", `String {|{"files":["target.ml"]}|}
      ; "tool_error", `Bool false
      ; "tool_use_id", `String ("tool-" ^ worker_run_id)
      ; "tool_turn", `Int 1
      ; "tool_planned_index", `Int 0
      ; "tool_batch_index", `Int 0
      ; "tool_batch_size", `Int 1
      ]
  ; raw_record ~worker_run_id ~seq:(start_seq + 4) ~ts:(base_ts +. 4.)
      ~record_type:Agent_sdk.Raw_trace.Run_finished
      [ "final_text", `String final_text; "stop_reason", `String "end_turn" ]
  ]
;;

let write_lines path lines =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () ->
      List.iter
        (fun line -> output_string oc (Yojson.Safe.to_string line ^ "\n"))
        lines)
;;

let run_ref ~path ~worker_run_id ~start_seq =
  { Turn_record.worker_run_id
  ; path
  ; start_seq
  ; end_seq = start_seq + 4
  ; agent_name = runtime_agent_name
  ; session_id = trace_id
  }
;;

let write_turn_record config ~absolute_turn ~generation ~turn_kind ~raw_trace_run_ref =
  let record : Turn_record.t =
    { execution_ids = []
    ; keeper = keeper_name
    ; agent_name
    ; generation
    ; turn_kind
    ; trace_id
    ; absolute_turn
    ; turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn
    ; blocks = []
    ; input_components = None
    ; runtime_profile = "test-runtime"
    ; model = Some "public-model"
    ; finish_reason = Some "completed"
    ; context_window = None
    ; price_input_per_million = None
    ; price_output_per_million = None
    ; request_latency_ms = None
    ; ttfrc_ms = None
    ; request_wire_observation = None
    ; raw_trace_run_ref
    ; sampling =
        { temperature = None
        ; top_p = None
        ; max_tokens = None
        ; thinking_budget = None
        ; enable_thinking = None
        }
    ; usage =
        { input_tokens = None
        ; output_tokens = None
        ; cache_creation_input_tokens = None
        ; cache_read_input_tokens = None
        }
    ; ts = 1000. +. float_of_int absolute_turn
    }
  in
  Dated_jsonl.append
    (Keeper_types_support.keeper_turn_record_store config keeper_name)
    (Turn_record.to_json record)
;;

let trace_path config suffix =
  Filename.concat (ensure_trace_dir config) ("turn-0000000000000-" ^ suffix ^ ".jsonl")
;;

let test_projects_exact_run_outcome_and_activity () =
  with_workspace @@ fun config ->
  let path = trace_path config "exact" in
  let first = run_lines ~worker_run_id:"run-first" ~start_seq:1 ~base_ts:1000.
      ~prompt:"direct user text" ~final_text:"wrong provider attempt" in
  let selected = run_lines ~worker_run_id:"run-selected" ~start_seq:5 ~base_ts:2000.
      ~prompt:Keeper_unified_prompt.autonomous_wake_marker ~final_text:"selected outcome" in
  write_lines path (first @ selected);
  write_turn_record config ~absolute_turn:41 ~generation:9
    ~turn_kind:Turn_record.Autonomous
    ~raw_trace_run_ref:(Some (run_ref ~path ~worker_run_id:"run-selected" ~start_seq:5));
  match Keeper_autonomous_turn_source.load_recent ~config ~keeper_name () with
  | [ turn ] ->
    Alcotest.(check string) "typed turn ref" "trace-test-0000#41" turn.turn_id;
    Alcotest.(check (option string)) "only selected run outcome"
      (Some "selected outcome") turn.final_text;
    Alcotest.(check (float 0.001)) "selected run timestamp" 2000. turn.started_at;
    (match turn.trace with
     | [ Keeper_chat_blocks.Trace_think thinking
       ; Keeper_chat_blocks.Trace_tool tool
       ] ->
       Alcotest.(check string) "thinking content is not public"
         "내부 판단 단계 (내용 비공개)" thinking.text;
       Alcotest.(check string) "tool name" "Read" tool.name;
       Alcotest.(check (option string)) "tool id is not public" None tool.tool_call_id;
       Alcotest.(check (option string)) "tool duration" (Some "1000ms") tool.dur;
       Alcotest.(check bool) "tool input is not public" true (tool.args = None);
       Alcotest.(check bool) "tool result is not public" true (tool.result = None)
     | trace ->
       Alcotest.failf "expected think + tool trace, got %d step(s)"
         (List.length trace))
  | turns -> Alcotest.failf "expected one exact turn, got %d" (List.length turns)
;;

let test_direct_marker_spoof_is_excluded () =
  with_workspace @@ fun config ->
  let path = trace_path config "direct" in
  write_lines path
    (run_lines ~worker_run_id:"run-direct" ~start_seq:1 ~base_ts:3000.
       ~prompt:Keeper_unified_prompt.autonomous_wake_marker ~final_text:"spoof");
  write_turn_record config ~absolute_turn:42 ~generation:9
    ~turn_kind:Turn_record.Direct
    ~raw_trace_run_ref:(Some (run_ref ~path ~worker_run_id:"run-direct" ~start_seq:1));
  Alcotest.(check int) "producer-owned kind excludes direct marker spoof" 0
    (List.length (Keeper_autonomous_turn_source.load_recent ~config ~keeper_name ()))
;;

let test_missing_or_outside_trace_is_skipped () =
  with_workspace @@ fun config ->
  let outside = Filename.concat config.Workspace.base_path "outside.jsonl" in
  write_lines outside
    (run_lines ~worker_run_id:"run-outside" ~start_seq:1 ~base_ts:4000.
       ~prompt:"ignored" ~final_text:"must not leak");
  write_turn_record config ~absolute_turn:43 ~generation:9
    ~turn_kind:Turn_record.Autonomous
    ~raw_trace_run_ref:(Some (run_ref ~path:outside ~worker_run_id:"run-outside" ~start_seq:1));
  Alcotest.(check int) "path outside keeper trace store is rejected" 0
    (List.length (Keeper_autonomous_turn_source.load_recent ~config ~keeper_name ()))
;;

let test_since_and_limit_use_current_records () =
  with_workspace @@ fun config ->
  let write index base_ts text =
    let path = trace_path config (string_of_int index) in
    let worker_run_id = "run-" ^ string_of_int index in
    write_lines path
      (run_lines ~worker_run_id ~start_seq:1 ~base_ts ~prompt:"ignored" ~final_text:text);
    write_turn_record config ~absolute_turn:index ~generation:9
      ~turn_kind:Turn_record.Autonomous
      ~raw_trace_run_ref:(Some (run_ref ~path ~worker_run_id ~start_seq:1))
  in
  write 1 1000. "older";
  write 2 5000. "newer";
  let turns =
    Keeper_autonomous_turn_source.load_recent ~config ~keeper_name ~limit:1 ~since:2000. ()
  in
  Alcotest.(check (list (option string))) "newest exact record only"
    [ Some "newer" ]
    (List.map (fun (turn : Keeper_autonomous_turn_source.turn) -> turn.final_text) turns)
;;

(* The reader above can only project turns whose record carries an exact run
   reference, so the writer-side acceptance rule belongs to the same guard set.
   [Keeper_turn_driver] mints the OAS runtime identity as "oas-<runtime_id>",
   which never equals the keeper agent identity; comparing the two rejected
   every reference and left every autonomous turn unprojectable. *)
let sdk_run_ref ~agent_name ~session_id : Agent_sdk.Raw_trace.run_ref =
  { worker_run_id = "wr-exact-run"
  ; path = "/keepers/" ^ keeper_name ^ "/raw-traces/turn-exact.jsonl"
  ; start_seq = 1
  ; end_seq = 4
  ; agent_name
  ; session_id
  }
;;

let test_runtime_identity_is_recorded_not_compared () =
  let runtime_agent_name = "oas-ollama_cloud.deepseek-v4-flash" in
  match
    Keeper_agent_run.For_testing.turn_record_raw_trace_run_ref
      ~expected_session_id:trace_id
      (sdk_run_ref ~agent_name:runtime_agent_name ~session_id:(Some trace_id))
  with
  | Error detail -> Alcotest.failf "runtime identity was compared, not recorded: %s" detail
  | Ok (recorded : Turn_record.raw_trace_run_ref) ->
    Alcotest.(check string) "records the runtime identity verbatim" runtime_agent_name
      recorded.agent_name;
    Alcotest.(check string) "records the keeper session identity" trace_id
      recorded.session_id
;;

let test_keeper_agent_identity_is_also_accepted () =
  match
    Keeper_agent_run.For_testing.turn_record_raw_trace_run_ref
      ~expected_session_id:trace_id
      (sdk_run_ref ~agent_name ~session_id:(Some trace_id))
  with
  | Error detail -> Alcotest.failf "expected the reference to be recorded: %s" detail
  | Ok (recorded : Turn_record.raw_trace_run_ref) ->
    Alcotest.(check string) "records the supplied identity" agent_name recorded.agent_name
;;

let test_session_identity_mismatch_is_rejected () =
  match
    Keeper_agent_run.For_testing.turn_record_raw_trace_run_ref
      ~expected_session_id:trace_id
      (sdk_run_ref ~agent_name ~session_id:(Some "trace-other-9999"))
  with
  | Ok _ -> Alcotest.fail "a foreign session identity was recorded"
  | Error _ -> ()
;;

let test_absent_session_identity_is_rejected () =
  match
    Keeper_agent_run.For_testing.turn_record_raw_trace_run_ref
      ~expected_session_id:trace_id
      (sdk_run_ref ~agent_name ~session_id:None)
  with
  | Ok _ -> Alcotest.fail "a reference without session identity was recorded"
  | Error _ -> ()
;;

let () =
  Alcotest.run "keeper_autonomous_turn_source"
    [ ( "load_recent"
      , [ Alcotest.test_case "projects exact run outcome and activity" `Quick
            test_projects_exact_run_outcome_and_activity
        ; Alcotest.test_case "typed direct kind defeats marker spoof" `Quick
            test_direct_marker_spoof_is_excluded
        ; Alcotest.test_case "rejects trace paths outside keeper store" `Quick
            test_missing_or_outside_trace_is_skipped
        ; Alcotest.test_case "since and limit use current records" `Quick
            test_since_and_limit_use_current_records
        ] )
    ; ( "exact_run_reference"
      , [ Alcotest.test_case "records the OAS runtime identity" `Quick
            test_runtime_identity_is_recorded_not_compared
        ; Alcotest.test_case "records a keeper-shaped identity" `Quick
            test_keeper_agent_identity_is_also_accepted
        ; Alcotest.test_case "rejects a foreign session identity" `Quick
            test_session_identity_mismatch_is_rejected
        ; Alcotest.test_case "rejects an absent session identity" `Quick
            test_absent_session_identity_is_rejected
        ] )
    ]
