(** Exact-run activity projection guards for Keeper_autonomous_turn_source. *)

open Masc

let keeper_name = "keeper-autonomous-source"
let agent_name = "keeper-autonomous-agent"
let runtime_agent_name = "agent_core-test-runtime"
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
    (("trace_version", `Int Agent_core.Raw_trace.trace_version)
     :: ("worker_run_id", `String worker_run_id)
     :: ("seq", `Int seq)
     :: ("ts", `Float ts)
     :: ("agent_name", `String runtime_agent_name)
     :: ("session_id", `String trace_id)
     :: ("record_type", `String (Agent_core.Raw_trace.record_type_to_string record_type))
     :: fields)
;;

let run_lines ~worker_run_id ~start_seq ~base_ts ~prompt ~final_text =
  [ raw_record ~worker_run_id ~seq:start_seq ~ts:base_ts
      ~record_type:Agent_core.Raw_trace.Run_started
      [ "prompt", `String prompt; "model", `String "test-model" ]
  ; raw_record ~worker_run_id ~seq:(start_seq + 1) ~ts:(base_ts +. 1.)
      ~record_type:Agent_core.Raw_trace.Assistant_block
      [ "block_index", `Int 0
      ; "block_kind", `String "thinking"
      ; ( "assistant_block"
        , `Assoc
            [ "type", `String "thinking"
            ; "thinking", `String "private chain of thought"
            ] )
      ]
  ; raw_record ~worker_run_id ~seq:(start_seq + 2) ~ts:(base_ts +. 2.)
      ~record_type:Agent_core.Raw_trace.Tool_execution_started
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
      ~record_type:Agent_core.Raw_trace.Tool_execution_finished
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
      ~record_type:Agent_core.Raw_trace.Run_finished
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

let write_turn_record config ~absolute_turn ~turn_kind ~raw_trace_run_ref =
  Keeper_turn_record_writer.write
    ~model_input_window:None
    ~config
    ~keeper_name
    ~agent_name
    ~turn_kind
    ~trace_id
    ~absolute_turn
    ~runtime_profile:"test-runtime"
    ~selected_model:(Some "public-model")
    ~finish_reason:(Some "completed")
    ~context_window:None
    ~price_input_per_million:None
    ~price_output_per_million:None
    ~request_latency_ms:None
    ~ttfrc_ms:None
    ~request_wire_observation:None
    ~raw_trace_run_ref
    ~sampling:
      { temperature = None
      ; top_p = None
      ; max_tokens = None
      ; thinking_budget = None
      ; enable_thinking = None
      }
    ~usage:
      { input_tokens = None
      ; output_tokens = None
      ; cache_creation_input_tokens = None
      ; cache_read_input_tokens = None
      ; scope = Runtime_usage_scope.Usage_scope_unavailable
      }
    ~execution_ids:[]
    ~blocks:[]
    ~input_components:None
    ~tool_surface_ref:None
    ()
;;

let keeper_chat_appended_for expected_name frame =
  match Sse.data_payload_of_frame frame with
  | Error Sse.Missing_data_payload -> false
  | Ok payload ->
    (match Yojson.Safe.from_string payload with
     | `Assoc fields ->
       List.assoc_opt "type" fields = Some (`String "keeper_chat_appended")
       && List.assoc_opt "name" fields = Some (`String expected_name)
     | _ -> false
     | exception Yojson.Json_error _ -> false)
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
  write_turn_record config ~absolute_turn:41 
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
       Alcotest.(check bool) "thinking step declares withheld content" true
         thinking.content_withheld;
       Alcotest.(check string) "thinking content is not public" "" thinking.text;
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
  write_turn_record config ~absolute_turn:42 
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
  write_turn_record config ~absolute_turn:43 
    ~turn_kind:Turn_record.Autonomous
    ~raw_trace_run_ref:(Some (run_ref ~path:outside ~worker_run_id:"run-outside" ~start_seq:1));
  Alcotest.(check int) "path outside keeper trace store is rejected" 0
    (List.length (Keeper_autonomous_turn_source.load_recent ~config ~keeper_name ()))
;;

let replace_raw_field_at ~index ~field ~value records =
  List.mapi
    (fun current record ->
      if current <> index
      then record
      else
        match record with
        | `Assoc fields -> `Assoc ((field, value) :: List.remove_assoc field fields)
        | other -> other)
    records
;;

(* The trace format is a hard cut: a run written with an older
   trace_version can never become readable, so the reader caches the
   rejection per (path, run). The proof is behavioral — after the first
   rejection, overwriting the file with a current-version trace must NOT
   resurrect the run, because the reader never opens the file again. *)
let test_version_rejected_run_is_not_reread () =
  with_workspace @@ fun config ->
  let path = trace_path config "old-version" in
  let records =
    run_lines ~worker_run_id:"run-old" ~start_seq:1 ~base_ts:5000.
      ~prompt:"ignored" ~final_text:"stale"
    |> replace_raw_field_at ~index:0 ~field:"trace_version" ~value:(`Int 3)
  in
  write_lines path records;
  let turn_count () =
    List.length (Keeper_autonomous_turn_source.load_recent ~config ~keeper_name ())
  in
  write_turn_record config ~absolute_turn:47
    ~turn_kind:Turn_record.Autonomous
    ~raw_trace_run_ref:(Some (run_ref ~path ~worker_run_id:"run-old" ~start_seq:1));
  Alcotest.(check int) "old trace_version run is rejected" 0 (turn_count ());
  (* Same path and run id, now with a current-version trace: the cached
     rejection must suppress the re-read. *)
  write_lines path
    (run_lines ~worker_run_id:"run-old" ~start_seq:1 ~base_ts:5000.
       ~prompt:Keeper_unified_prompt.autonomous_wake_marker
       ~final_text:"resurrected");
  Alcotest.(check int) "rejected run is not re-read after rewrite" 0 (turn_count ())
;;

(* Deletion is one-way (hard-cut cleanup, retention pruning): a missing
   referenced file never comes back, so the reader caches the miss per
   (path, run) the same way it caches a version rejection. The proof: a
   record whose trace file never exists, then a valid trace placed at the
   same path -- the second load must still skip it. *)
let test_missing_trace_run_is_not_reread () =
  with_workspace @@ fun config ->
  let path = trace_path config "vanished" in
  let turn_count () =
    List.length (Keeper_autonomous_turn_source.load_recent ~config ~keeper_name ())
  in
  write_turn_record config ~absolute_turn:48
    ~turn_kind:Turn_record.Autonomous
    ~raw_trace_run_ref:(Some (run_ref ~path ~worker_run_id:"run-gone" ~start_seq:1));
  Alcotest.(check int) "missing trace run is rejected" 0 (turn_count ());
  write_lines path
    (run_lines ~worker_run_id:"run-gone" ~start_seq:1 ~base_ts:5000.
       ~prompt:Keeper_unified_prompt.autonomous_wake_marker
       ~final_text:"too late");
  Alcotest.(check int) "missing run is not re-read after the file appears" 0
    (turn_count ())
;;

let test_mismatched_raw_trace_runtime_identity_is_skipped () =  with_workspace @@ fun config ->
  let path = trace_path config "runtime-identity-mismatch" in
  let records =
    run_lines ~worker_run_id:"run-mismatch" ~start_seq:1 ~base_ts:4500.
      ~prompt:"ignored" ~final_text:"must not be attributed"
    |> replace_raw_field_at ~index:3 ~field:"agent_name"
         ~value:(`String "agent_core-other-runtime")
  in
  write_lines path records;
  write_turn_record config ~absolute_turn:44 
    ~turn_kind:Turn_record.Autonomous
    ~raw_trace_run_ref:
      (Some (run_ref ~path ~worker_run_id:"run-mismatch" ~start_seq:1));
  Alcotest.(check int) "raw runtime identity mismatch is rejected" 0
    (List.length (Keeper_autonomous_turn_source.load_recent ~config ~keeper_name ()))
;;

let test_mismatched_raw_trace_session_identity_is_skipped () =
  with_workspace @@ fun config ->
  let path = trace_path config "session-identity-mismatch" in
  let records =
    run_lines ~worker_run_id:"run-mismatch" ~start_seq:1 ~base_ts:4600.
      ~prompt:"ignored" ~final_text:"must not be attributed"
    |> replace_raw_field_at ~index:4 ~field:"session_id"
         ~value:(`String "trace-other-9999")
  in
  write_lines path records;
  write_turn_record config ~absolute_turn:45 
    ~turn_kind:Turn_record.Autonomous
    ~raw_trace_run_ref:
      (Some (run_ref ~path ~worker_run_id:"run-mismatch" ~start_seq:1));
  Alcotest.(check int) "raw session identity mismatch is rejected" 0
    (List.length (Keeper_autonomous_turn_source.load_recent ~config ~keeper_name ()))
;;

let test_since_and_limit_use_current_records () =
  with_workspace @@ fun config ->
  let write index base_ts text =
    let path = trace_path config (string_of_int index) in
    let worker_run_id = "run-" ^ string_of_int index in
    write_lines path
      (run_lines ~worker_run_id ~start_seq:1 ~base_ts ~prompt:"ignored" ~final_text:text);
    write_turn_record config ~absolute_turn:index 
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

let test_committed_autonomous_turn_invalidates_live_chat () =
  with_workspace @@ fun config ->
  let path = trace_path config "live-chat" in
  let worker_run_id = "run-live-chat" in
  write_lines path
    (run_lines ~worker_run_id ~start_seq:1 ~base_ts:6000.
       ~prompt:Keeper_unified_prompt.autonomous_wake_marker
       ~final_text:"visible without reload");
  let visible_turns_at_broadcast = ref None in
  let subscriber_id =
    Printf.sprintf "autonomous-chat-live-%d-%d" (Unix.getpid ())
      (Random.int 1_000_000)
  in
  Eio.Switch.run @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> Sse.unsubscribe_external subscriber_id);
  Sse.subscribe_external ~id:subscriber_id
    ~callback:(fun (ev : Sse.external_event) ->
      let frame = ev.Sse.ext_frame in
      if keeper_chat_appended_for keeper_name frame
      then
        visible_turns_at_broadcast :=
          Some
            (Keeper_autonomous_turn_source.load_recent
               ~config ~keeper_name ()))
    ();
  write_turn_record config ~absolute_turn:46 
    ~turn_kind:Turn_record.Autonomous
    ~raw_trace_run_ref:
      (Some (run_ref ~path ~worker_run_id ~start_seq:1));
  match !visible_turns_at_broadcast with
  | Some [ turn ] ->
    Alcotest.(check (option string)) "committed outcome is readable at broadcast"
      (Some "visible without reload") turn.final_text
  | Some turns ->
    Alcotest.failf "expected one committed turn at broadcast, got %d"
      (List.length turns)
  | None -> Alcotest.fail "committed autonomous turn emitted no chat invalidation"
;;

let test_direct_turn_does_not_duplicate_chat_invalidation () =
  with_workspace @@ fun config ->
  let invalidations = ref 0 in
  let subscriber_id =
    Printf.sprintf "direct-chat-live-%d-%d" (Unix.getpid ())
      (Random.int 1_000_000)
  in
  Eio.Switch.run @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> Sse.unsubscribe_external subscriber_id);
  Sse.subscribe_external ~id:subscriber_id
    ~callback:(fun (ev : Sse.external_event) ->
      let frame = ev.Sse.ext_frame in
      if keeper_chat_appended_for keeper_name frame then incr invalidations)
    ();
  write_turn_record config ~absolute_turn:47 
    ~turn_kind:Turn_record.Direct ~raw_trace_run_ref:None;
  Alcotest.(check int) "direct chat path owns its invalidation" 0 !invalidations
;;

(* The AGENT_CORE runtime identity is opaque here. The reader validates it against
   the selected raw rows without comparing it to the Keeper identity. *)
let agent_core_run_ref ~agent_name ~session_id : Agent_core.Raw_trace.run_ref =
  { worker_run_id = "wr-exact-run"
  ; path = "/keepers/" ^ keeper_name ^ "/raw-traces/turn-exact.jsonl"
  ; start_seq = 1
  ; end_seq = 4
  ; agent_name
  ; session_id
  }
;;

let test_runtime_identity_is_recorded_not_compared () =
  let runtime_agent_name = "agent_core-ollama_cloud.deepseek-v4-flash" in
  match
    Keeper_agent_run.For_testing.turn_record_raw_trace_run_ref
      ~expected_session_id:trace_id
      (agent_core_run_ref ~agent_name:runtime_agent_name ~session_id:(Some trace_id))
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
      (agent_core_run_ref ~agent_name ~session_id:(Some trace_id))
  with
  | Error detail -> Alcotest.failf "expected the reference to be recorded: %s" detail
  | Ok (recorded : Turn_record.raw_trace_run_ref) ->
    Alcotest.(check string) "records the supplied identity" agent_name recorded.agent_name
;;

let test_session_identity_mismatch_is_rejected () =
  match
    Keeper_agent_run.For_testing.turn_record_raw_trace_run_ref
      ~expected_session_id:trace_id
      (agent_core_run_ref ~agent_name ~session_id:(Some "trace-other-9999"))
  with
  | Ok _ -> Alcotest.fail "a foreign session identity was recorded"
  | Error _ -> ()
;;

let test_absent_session_identity_is_rejected () =
  match
    Keeper_agent_run.For_testing.turn_record_raw_trace_run_ref
      ~expected_session_id:trace_id
      (agent_core_run_ref ~agent_name ~session_id:None)
  with
  | Ok _ -> Alcotest.fail "a reference without session identity was recorded"
  | Error _ -> ()
;;

(* The wake prompt is the user turn every autonomous cycle is woken with, and
   it is kept by the durable checkpoint, so it is worth bounding: its cost
   recurs on every later turn that replays the history. *)

let test_wake_prompt_validation_rejects_blank_and_unbounded () =
  let validate = Env_config_keeper.KeeperAutonomous.validate_wake_prompt in
  Alcotest.(check bool)
    "blank is rejected rather than folded into the default"
    true
    (Result.is_error (validate "   "));
  Alcotest.(check bool) "empty is rejected" true (Result.is_error (validate ""));
  let bound = Env_config_keeper.KeeperAutonomous.max_wake_prompt_bytes in
  Alcotest.(check bool)
    "a value at the bound is admitted"
    true
    (Result.is_ok (validate (String.make bound 'x')));
  Alcotest.(check bool)
    "one byte over the bound is rejected"
    true
    (Result.is_error (validate (String.make (bound + 1) 'x')));
  match validate "  ask a better question  " with
  | Error reason -> Alcotest.failf "a valid prompt was rejected: %s" reason
  | Ok value ->
    Alcotest.(check string) "surrounding whitespace is trimmed"
      "ask a better question" value
;;

(* Ordering matters: the literal case must run before this process sets the
   fleet variable, because OCaml's Unix has no unsetenv to undo it. *)
let test_wake_prompt_resolution_order () =
  let resolve () = Env_config_keeper.KeeperAutonomous.wake_prompt () in
  Alcotest.(check string)
    "no fleet value resolves to the literal"
    Keeper_unified_prompt.autonomous_wake_marker
    (resolve ());
  Unix.putenv "MASC_KEEPER_AUTONOMOUS_WAKE_PROMPT" "fleet asks";
  Alcotest.(check string)
    "a set fleet value is used"
    "fleet asks"
    (resolve ());
  (* A set-but-invalid fleet value must surface, not silently restore the
     default -- otherwise a typo reads as "configuration had no effect". *)
  Unix.putenv "MASC_KEEPER_AUTONOMOUS_WAKE_PROMPT" "   ";
  Alcotest.check_raises
    "a blank fleet value raises instead of falling back"
    (Env_config_core.Config_error
       "MASC_KEEPER_AUTONOMOUS_WAKE_PROMPT: autonomous wake prompt must not be blank")
    (fun () -> ignore (resolve ()))
;;

(* The dashboard history schema (keeper-chat-history.ts) requires [id] on every
   row and silently drops any row without one. A projected autonomous turn
   without [id] would therefore never reach the transcript. *)
let test_dashboard_history_autonomous_rows_carry_id () =
  with_workspace @@ fun config ->
  let path = trace_path config "history-id" in
  let worker_run_id = "run-history-id" in
  write_lines path
    (run_lines ~worker_run_id ~start_seq:1 ~base_ts:7000.
       ~prompt:Keeper_unified_prompt.autonomous_wake_marker
       ~final_text:"visible in history");
  write_turn_record config ~absolute_turn:48 
    ~turn_kind:Turn_record.Autonomous
    ~raw_trace_run_ref:(Some (run_ref ~path ~worker_run_id ~start_seq:1));
  match
    Server_dashboard_http_keeper_api.keeper_chat_history_json config keeper_name
  with
  | `List rows ->
    Alcotest.(check int) "one autonomous row in history" 1 (List.length rows);
    List.iter
      (fun row ->
        match row with
        | `Assoc fields ->
          (match List.assoc_opt "id" fields with
           | Some (`String id) when String.length id > 0 ->
             Alcotest.(check string) "id is namespaced off the turn ref"
               "autonomous:trace-test-0000#48" id
           | _ ->
             Alcotest.fail
               "autonomous history row without id is dropped by the dashboard schema")
        | _ -> Alcotest.fail "history row is not an object")
      rows
  | _ -> Alcotest.fail "history body is not a list"
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
        ; Alcotest.test_case "rejects mismatched raw runtime identity" `Quick
            test_mismatched_raw_trace_runtime_identity_is_skipped
        ; Alcotest.test_case "version-rejected run is not re-read" `Quick
            test_version_rejected_run_is_not_reread
        ; Alcotest.test_case "missing-trace run is not re-read" `Quick
            test_missing_trace_run_is_not_reread
        ; Alcotest.test_case "rejects mismatched raw session identity" `Quick
            test_mismatched_raw_trace_session_identity_is_skipped
        ; Alcotest.test_case "since and limit use current records" `Quick
            test_since_and_limit_use_current_records
        ; Alcotest.test_case "committed autonomous turn invalidates live chat" `Quick
            test_committed_autonomous_turn_invalidates_live_chat
        ; Alcotest.test_case "direct turn does not duplicate chat invalidation" `Quick
            test_direct_turn_does_not_duplicate_chat_invalidation
        ] )
    ; ( "exact_run_reference"
      , [ Alcotest.test_case "records the AGENT_CORE runtime identity" `Quick
            test_runtime_identity_is_recorded_not_compared
        ; Alcotest.test_case "records a keeper-shaped identity" `Quick
            test_keeper_agent_identity_is_also_accepted
        ; Alcotest.test_case "rejects a foreign session identity" `Quick
            test_session_identity_mismatch_is_rejected
        ; Alcotest.test_case "rejects an absent session identity" `Quick
            test_absent_session_identity_is_rejected
        ] )
    ; ( "dashboard_history"
      , [ Alcotest.test_case "autonomous rows carry a schema-required id" `Quick
            test_dashboard_history_autonomous_rows_carry_id
        ] )
    ; ( "wake_prompt"
      , [ Alcotest.test_case "rejects blank and over-bound values" `Quick
            test_wake_prompt_validation_rejects_blank_and_unbounded
        ; Alcotest.test_case "fleet value then literal" `Quick
            test_wake_prompt_resolution_order
        ] )
    ]
