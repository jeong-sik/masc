open Alcotest

module Workspace = Masc.Workspace
module Consumer = Masc.Keeper_librarian_durable_consumer
module Queue_refresh = Masc.Keeper_librarian_queue_refresh
module Boundaries = Masc.Keeper_turn_boundaries
module Progress = Masc.Keeper_librarian_progress
module Store = Masc.Keeper_checkpoint_store
module Keeper_chat_store = Masc.Keeper_chat_store
module Keeper_external_attention = Masc.Keeper_external_attention
module Keeper_counterpart_observation = Masc.Keeper_counterpart_observation

let keeper_name = "durable-reader"

let config_in_cluster config cluster_name =
  { config with
    Workspace.backend_config = { config.Workspace.backend_config with cluster_name }
  }
;;

let write_keeper_declaration config =
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:config.Workspace.base_path
  in
  Fs_compat.mkdir_p keepers_dir;
  Fs_compat.mkdir_p (Filename.concat keepers_dir keeper_name);
  let path = Filename.concat keepers_dir (keeper_name ^ ".toml") in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
       Printf.fprintf
         oc
         "[keeper]\nname = %S\ninstructions = %S\nsandbox_profile = %S\n"
         keeper_name
         "test durable Librarian"
         "docker");
  Masc.Keeper_types_profile.invalidate_keeper_profile_defaults_cache keeper_name
;;

let with_workspace f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Eio_main.run @@ fun _env ->
  let base_path = Filename.temp_dir "librarian-durable-consumer-" "" in
  Config_dir_resolver.reset ();
  Fun.protect
    ~finally:(fun () ->
      Config_dir_resolver.reset ();
      Fs_compat.remove_tree base_path)
    (fun () ->
       let config = Workspace.default_config base_path in
       let (_ : string) = Workspace.init config ~agent_name:None in
       write_keeper_declaration config;
       f config)
;;

let meta ?current_task_id trace_id =
  let fields = [ "name", `String keeper_name; "trace_id", `String trace_id ] in
  let fields =
    match current_task_id with
    | None -> fields
    | Some task_id -> ("current_task_id", `String task_id) :: fields
  in
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc fields)
  with
  | Ok meta -> meta
  | Error detail -> failf "fixture metadata: %s" detail
;;

let write_meta ?current_task_id config trace_id =
  match
    Masc.Keeper_meta_store.replace_snapshot config (meta ?current_task_id trace_id)
  with
  | Ok () -> ()
  | Error detail -> failf "write metadata: %s" detail
;;

let message marker =
  Agent_core.Types.make_message
    ~role:Agent_core.Types.User
    [ Agent_core.Types.Text marker ]
;;

let checkpoint ~trace_id messages turn_count : Agent_core.Checkpoint.t =
  { version = Agent_core.Checkpoint.checkpoint_version
  ; session_id = trace_id
  ; agent_name = keeper_name
  ; model = "fixture-model"
  ; system_prompt = None
  ; messages
  ; usage = Agent_core.Types.empty_usage
  ; turn_count
  ; created_at = Float.of_int turn_count
  ; tools = []
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; reasoning_effort = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Agent_core.Types.Off
  ; cache_system_prompt = false
  ; context = Agent_core.Context.create_sync ()
  ; mcp_sessions = []
  ; working_context = None
  }
;;

let save_checkpoint config ~trace_id messages turn_count =
  let session_dir = Masc.Keeper_fs.keeper_session_dir config trace_id in
  match
    Store.save_agent_core_classified
      ~session_dir
      ~history_retained:0
      (checkpoint ~trace_id messages turn_count)
  with
  | Ok (Store.Saved _) -> ()
  | Ok (Store.Stale_noop _) -> fail "fixture checkpoint was stale"
  | Error detail -> failf "save checkpoint: %s" detail
;;

let append_boundary ?history_at_start config ~trace_id ~turn ~recorded_at messages =
  let position =
    match Boundaries.position_of_messages messages with
    | Ok position -> position
    | Error detail -> failf "boundary position: %s" detail
  in
  let record : Boundaries.record =
    { recorded_at
    ; event =
        Boundaries.Turn_ended
          { turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:turn
          ; history_at_start =
              (match history_at_start with
               | Some history_at_start -> history_at_start
               | None ->
                 if turn = 1
                 then Boundaries.Fresh_history
                 else Boundaries.Continued_history)
          ; position
          }
    }
  in
  match
    Boundaries.append
      ~keepers_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_id:keeper_name
      record
  with
  | Ok () -> ()
  | Error error -> fail (Boundaries.append_error_to_string error)
;;

let read_progress config =
  match
    Progress.read
      ~keepers_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_id:keeper_name
  with
  | Ok progress -> progress
  | Error error -> fail (Progress.read_error_to_string error)
;;

let text_markers (input : Masc.Keeper_librarian.input) =
  List.concat_map
    (fun (message : Agent_core.Types.message) ->
       List.filter_map
         (function
           | Agent_core.Types.Text text -> Some text
           | Agent_core.Types.Thinking _
           | Agent_core.Types.ReasoningDetails _
           | Agent_core.Types.RedactedThinking _
           | Agent_core.Types.ToolUse _
           | Agent_core.Types.ToolResult _
           | Agent_core.Types.Image _
           | Agent_core.Types.Document _
           | Agent_core.Types.Audio _ -> None)
         message.content)
    input.messages
;;

let consume config commit =
  match Consumer.consume_one ~config ~keeper_name ~commit with
  | Ok outcome -> outcome
  | Error error -> fail (Consumer.error_to_string error)
;;

let establish_progress config ~trace_id first =
  write_meta config trace_id;
  save_checkpoint config ~trace_id [ message first ] 1;
  append_boundary config ~trace_id ~turn:1 ~recorded_at:1.0 [ message first ];
  match consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> true) with
  | Consumer.Baseline_advanced progress | Consumer.Progress_advanced progress ->
    check int "initial end" 1 progress.position.end_atom
  | Consumer.Nothing_to_read
  | Consumer.Official_advanced _
  | Consumer.Memory_not_committed -> fail "initial range did not advance"
;;

let test_agent_core_handoff_retains_pending_official_evidence () =
  with_workspace @@ fun config ->
  let trace_id = "trace-official-to-agent-core" in
  let attempts = ref 0 in
  Queue_refresh.remember_turn
    ~base_path:config.Workspace.base_path
    ~keeper_name
    ~trace_id
    (fun ~meta:_ _trigger ->
      incr attempts;
      if !attempts = 1 then raise Exit;
      Queue_refresh.Entered);
  Queue_refresh.forget_turn
    ~base_path:config.Workspace.base_path
    ~keeper_name;
  (match
     Queue_refresh.For_testing.attempt_remembered
       ~base_path:config.Workspace.base_path
       ~keeper_name
       ~trace_id
       ~meta:(meta trace_id)
       ~sources_changed:false
       ~trigger:Masc.Keeper_librarian_runtime.Conversation_completed
   with
   | _ -> fail "cancelled official evidence attempt did not escape"
   | exception Exit -> ());
  check int "cancelled attempt retains its evidence" 1 !attempts;
  let handled =
    Queue_refresh.For_testing.attempt_remembered
      ~base_path:config.Workspace.base_path
      ~keeper_name
      ~trace_id
      ~meta:(meta trace_id)
      ~sources_changed:false
      ~trigger:Masc.Keeper_librarian_runtime.Conversation_completed
  in
  check bool "pending official evidence survives Agent-Core handoff" true handled;
  check int "pending official evidence succeeds on retry" 2 !attempts;
  check bool
    "handoff evidence retires immediately after its attempt"
    false
    (Queue_refresh.For_testing.attempt_remembered
       ~base_path:config.Workspace.base_path
       ~keeper_name
       ~trace_id
       ~meta:(meta trace_id)
       ~sources_changed:false
       ~trigger:Masc.Keeper_librarian_runtime.Conversation_completed)
;;

let test_n_tick_reads_every_intermediate_turn () =
  with_workspace @@ fun config ->
  let trace_id = "trace-n-tick" in
  establish_progress config ~trace_id "turn-1";
  let first_two = [ message "turn-1"; message "turn-2" ] in
  let messages = first_two @ [ message "turn-3" ] in
  append_boundary config ~trace_id ~turn:2 ~recorded_at:2.0 first_two;
  append_boundary config ~trace_id ~turn:3 ~recorded_at:3.0 messages;
  save_checkpoint config ~trace_id messages 3;
  let carried = ref [] in
  (match
     consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
       carried := text_markers input;
       true)
   with
   | Consumer.Progress_advanced progress ->
     check int "all three turns reached" 3 progress.position.end_atom
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Official_advanced _
   | Consumer.Memory_not_committed -> fail "unread range did not commit");
  check (list string) "both unread turns are delivered" [ "turn-2"; "turn-3" ] !carried
;;

(* RFC §4.9, invariant I4. The count is read-only and comes from the same
   files a pass reads: two turns end after the position, so two are behind,
   and a pass that reads them leaves none. *)
let test_unread_turns_counts_what_a_pass_has_left () =
  with_workspace @@ fun config ->
  let trace_id = "trace-unread" in
  establish_progress config ~trace_id "turn-1";
  let first_two = [ message "turn-1"; message "turn-2" ] in
  let messages = first_two @ [ message "turn-3" ] in
  append_boundary config ~trace_id ~turn:2 ~recorded_at:2.0 first_two;
  append_boundary config ~trace_id ~turn:3 ~recorded_at:3.0 messages;
  save_checkpoint config ~trace_id messages 3;
  (match Consumer.unread_turns ~config ~keeper_name with
   | Ok { atoms; official } ->
     check int "two turns are behind" 2 atoms;
     check int "no official turn" 0 official
   | Error error -> fail (Consumer.error_to_string error));
  (match consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> true) with
   | Consumer.Progress_advanced _ -> ()
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Official_advanced _
   | Consumer.Memory_not_committed -> fail "unread range did not commit");
  match Consumer.unread_turns ~config ~keeper_name with
  | Ok { atoms; official } ->
    check int "nothing is behind after the pass" 0 atoms;
    check int "and no official turn" 0 official
  | Error error -> fail (Consumer.error_to_string error)
;;

let test_failed_commit_and_restart_retry_the_same_range () =
  with_workspace @@ fun config ->
  let trace_id = "trace-retry" in
  establish_progress config ~trace_id "before";
  let messages = [ message "before"; message "retry-me" ] in
  append_boundary config ~trace_id ~turn:2 ~recorded_at:2.0 messages;
  save_checkpoint config ~trace_id messages 2;
  let first = ref [] in
  (match
     consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
       first := text_markers input;
       false)
   with
   | Consumer.Memory_not_committed -> ()
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Official_advanced _
   | Consumer.Progress_advanced _ -> fail "failed commit advanced the pass");
  let after_failure = read_progress config in
  (match after_failure with
   | Some progress -> check int "failed commit keeps progress" 1 progress.position.end_atom
   | None -> fail "failed commit removed existing progress");
  let after_restart = ref [] in
  (match
     consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
       after_restart := text_markers input;
       true)
   with
   | Consumer.Progress_advanced progress ->
     check int "restart reaches retried turn" 2 progress.position.end_atom
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Official_advanced _
   | Consumer.Memory_not_committed -> fail "restart did not retry unread range");
  check (list string) "restart reads identical range" !first !after_restart
;;

let test_committed_range_recovers_after_progress_write_failure () =
  with_workspace @@ fun config ->
  let module Current = Masc.Keeper_memory_os_current in
  let module Memory = Masc.Keeper_memory_os_types in
  let trace_id = "trace-post-commit-progress" in
  establish_progress config ~trace_id "before";
  let through_a = [ message "before"; message "commit-a" ] in
  append_boundary config ~trace_id ~turn:2 ~recorded_at:2.0 through_a;
  save_checkpoint config ~trace_id through_a 2;
  let memory_keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:config.Workspace.base_path
  in
  let commits = ref 0 in
  let committed_inputs = ref [] in
  let attempted_range = ref None in
  let commit ~expected_revision:_ ~range_id ~official_range_id input =
    incr commits;
    committed_inputs := !committed_inputs @ [ text_markers input ];
    attempted_range := range_id;
    match
      Current.apply_disposition
        ?durable_range_id:range_id
        ?official_range_id
        ~absorbed:[]
        ~keepers_dir:memory_keepers_dir
        ~keeper_id:keeper_name
        ~now:(Float.of_int !commits)
        ~source:
          { kind = Current.Librarian
          ; trace_id = Ids.Turn_ref.trace_id input.Masc.Keeper_librarian.turn_ref
          }
        ~new_claims:[]
        ()
    with
    | Ok _ -> true
    | Error detail -> fail detail
  in
  let fail_progress ~keepers_dir:_ ~keeper_id:_ _ =
    Error
      (Progress.Write_failed
         { path = "injected-progress-write"; message = "post-commit failure" })
  in
  (match
     Consumer.For_testing.consume_one_with_progress_writer
       ~write_progress_store:fail_progress
       ~write_official_progress_store:Masc.Keeper_librarian_official_progress.write
       ~config
       ~keeper_name
       ~commit
   with
   | Error (Consumer.Progress_write_failed _) -> ()
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "read progress unexpectedly advanced after its write failed");
  check int "Memory disposition committed once" 1 !commits;
  (match read_progress config with
   | Some progress -> check int "failed write keeps old progress" 1 progress.position.end_atom
   | None -> fail "failed progress write removed the old position");
  let committed_a =
    match !attempted_range with
    | Some range_id -> range_id
    | None -> fail "Memory commit did not receive a range identity"
  in
  let receipt_after_commit =
    match
      Current.committed_durable_range
        ~keepers_dir:memory_keepers_dir
        ~keeper_id:keeper_name
        ~receipt_scope:(Workspace.keepers_runtime_dir config)
    with
    | Ok receipt -> receipt
    | Error detail -> fail detail
  in
  (match receipt_after_commit with
   | Some range_id ->
     check int "receipt names range A" committed_a.end_atom range_id.end_atom
   | None -> fail "Memory receipt did not retain range A");
  let unrelated =
    Memory.observed
      ~claim:"unrelated writer"
      ~category:Memory.Fact
      ~now:3.0
      ~origin:{ kind = Memory.Authored; trace_id }
  in
  (match
     Current.upsert_fact
       ~keepers_dir:memory_keepers_dir
       ~keeper_id:keeper_name
       ~now:3.0
       ~source:{ kind = Current.Explicit_write; trace_id }
       unrelated
   with
   | Ok _ -> ()
   | Error error -> fail (Current.upsert_error_to_string error));
  (match
     Current.committed_durable_range
       ~keepers_dir:memory_keepers_dir
       ~keeper_id:keeper_name
       ~receipt_scope:(Workspace.keepers_runtime_dir config)
   with
   | Ok (Some range_id) ->
     check int "explicit write preserves range A" committed_a.end_atom range_id.end_atom
   | Ok None -> fail "a later Memory write erased the committed range receipt"
   | Error detail -> fail detail);
  let through_b = through_a @ [ message "commit-b" ] in
  append_boundary config ~trace_id ~turn:3 ~recorded_at:3.0 through_b;
  save_checkpoint config ~trace_id through_b 3;
  Consumer.For_testing.reset_process_state ();
  (match
     Consumer.consume_one
       ~config
       ~keeper_name
       ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
         fail "restart submitted an already committed range again")
   with
   | Ok (Consumer.Progress_advanced progress) ->
     check int "restart repairs only committed range A" 2 progress.position.end_atom
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "restart did not repair the committed range progress");
  check int "restart does not write Memory again" 1 !commits;
  let after_recovery =
    match Current.read_for_keepers_dir ~keepers_dir:memory_keepers_dir ~keeper_id:keeper_name with
    | Ok (Some snapshot) -> snapshot
    | Ok None -> fail "Memory disappeared during progress recovery"
    | Error detail -> fail detail
  in
  check int "progress recovery writes no Memory revision" 2 after_recovery.revision;
  (match
     Consumer.consume_one ~config ~keeper_name ~commit
   with
   | Ok (Consumer.Progress_advanced progress) ->
     check int "next pass commits range B" 3 progress.position.end_atom
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "range B was not committed after A recovery");
  check int "range B adds exactly one model commit" 2 !commits;
  check (list (list string))
    "model sees A once and then only B"
    [ [ "commit-a" ]; [ "commit-b" ] ]
    !committed_inputs
;;

let test_committed_wide_range_recovers_before_retry_narrowing () =
  with_workspace @@ fun config ->
  let module Current = Masc.Keeper_memory_os_current in
  let trace_id = "trace-wide-receipt-recovery" in
  establish_progress config ~trace_id "turn-1";
  let first_two = [ message "turn-1"; message "turn-2" ] in
  let first_three = first_two @ [ message "turn-3" ] in
  append_boundary config ~trace_id ~turn:2 ~recorded_at:2.0 first_two;
  append_boundary config ~trace_id ~turn:3 ~recorded_at:3.0 first_three;
  save_checkpoint config ~trace_id first_three 3;
  let memory_keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:config.Workspace.base_path
  in
  let commits = ref 0 in
  let commit ~expected_revision:_ ~range_id ~official_range_id input =
    incr commits;
    match
      Current.apply_disposition
        ?durable_range_id:range_id
        ?official_range_id
        ~absorbed:[]
        ~keepers_dir:memory_keepers_dir
        ~keeper_id:keeper_name
        ~now:(Float.of_int !commits)
        ~source:
          { kind = Current.Librarian
          ; trace_id = Ids.Turn_ref.trace_id input.Masc.Keeper_librarian.turn_ref
          }
        ~new_claims:[]
        ()
    with
    | Ok _ -> true
    | Error detail -> fail detail
  in
  let fail_progress ~keepers_dir:_ ~keeper_id:_ _ =
    Error
      (Progress.Write_failed
         { path = "injected-progress-write"; message = "post-commit failure" })
  in
  (match
     Consumer.For_testing.consume_one_with_progress_writer
       ~write_progress_store:fail_progress
       ~write_official_progress_store:Masc.Keeper_librarian_official_progress.write
       ~config
       ~keeper_name
       ~commit
   with
   | Error (Consumer.Progress_write_failed _) -> ()
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "wide committed range did not hit progress failure");
  check int "wide range committed once" 1 !commits;
  (match
     Consumer.consume_one ~config ~keeper_name
       ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
         fail "narrow retry recommitted the already committed wide range")
   with
   | Ok (Consumer.Progress_advanced progress) ->
     check int "receipt repairs the wide endpoint" 3 progress.position.end_atom
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "wide receipt was not recovered before narrowing");
  check int "receipt recovery performs no second Memory commit" 1 !commits
;;

let test_receipt_does_not_cross_restarted_history_with_repeated_endpoint () =
  with_workspace @@ fun config ->
  let module Current = Masc.Keeper_memory_os_current in
  let trace_id = "trace-repeated-restart" in
  let memory_keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:config.Workspace.base_path
  in
  establish_progress config ~trace_id "old";
  let repeated = [ message "repeated" ] in
  append_boundary
    ~history_at_start:Boundaries.Fresh_history
    config
    ~trace_id
    ~turn:2
    ~recorded_at:2.0
    repeated;
  save_checkpoint config ~trace_id repeated 2;
  let commits = ref 0 in
  let commit ~expected_revision:_ ~range_id ~official_range_id input =
    incr commits;
    match
      Current.apply_disposition
        ?durable_range_id:range_id
        ?official_range_id
        ~absorbed:[]
        ~keepers_dir:memory_keepers_dir
        ~keeper_id:keeper_name
        ~now:(Float.of_int !commits)
        ~source:
          { kind = Current.Librarian
          ; trace_id = Ids.Turn_ref.trace_id input.Masc.Keeper_librarian.turn_ref
          }
        ~new_claims:[]
        ()
    with
    | Ok _ -> true
    | Error detail -> fail detail
  in
  let fail_progress ~keepers_dir:_ ~keeper_id:_ _ =
    Error
      (Progress.Write_failed
         { path = "injected-progress-write"; message = "post-commit failure" })
  in
  (match
     Consumer.For_testing.consume_one_with_progress_writer
       ~write_progress_store:fail_progress
       ~write_official_progress_store:Masc.Keeper_librarian_official_progress.write
       ~config
       ~keeper_name
       ~commit
   with
   | Error (Consumer.Progress_write_failed _) -> ()
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "first restarted history did not hit injected progress failure");
  check int "first restarted history committed" 1 !commits;
  append_boundary
    ~history_at_start:Boundaries.Fresh_history
    config
    ~trace_id
    ~turn:3
    ~recorded_at:3.0
    repeated;
  save_checkpoint config ~trace_id repeated 3;
  Consumer.For_testing.reset_process_state ();
  (match Consumer.consume_one ~config ~keeper_name ~commit with
   | Ok (Consumer.Progress_advanced progress) ->
     check int "new restarted history advances its own endpoint" 1
       progress.position.end_atom
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "new restarted history was mistaken for the old receipt");
  check int "same atom and digest in a new history commits again" 2 !commits
;;

let check_progress_end config expected =
  match read_progress config with
  | Some progress -> check int "durable progress end" expected progress.position.end_atom
  | None -> fail "durable progress is missing"
;;

let check_no_task label = function
  | Masc.Keeper_librarian.No_task -> ()
  | Masc.Keeper_librarian.Task_goals { task_id; _ } ->
    failf "%s borrowed current task %s" label task_id
;;

let test_historical_range_does_not_borrow_the_current_task () =
  with_workspace @@ fun config ->
  let trace_id = "trace-historical-goal-context" in
  establish_progress config ~trace_id "before";
  write_meta ~current_task_id:"task-current-a" config trace_id;
  let messages = [ message "before"; message "historical" ] in
  append_boundary config ~trace_id ~turn:2 ~recorded_at:2.0 messages;
  save_checkpoint config ~trace_id messages 2;
  let first_context = ref None in
  (match
     consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
       first_context := Some input.Masc.Keeper_librarian.goal_context;
       false)
   with
   | Consumer.Memory_not_committed -> ()
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Official_advanced _
   | Consumer.Progress_advanced _ -> fail "failed historical commit advanced");
  (match !first_context with
   | Some context -> check_no_task "first catch-up" context
   | None -> fail "historical catch-up did not reach the commit boundary");
  check_progress_end config 1;
  write_meta ~current_task_id:"task-current-b" config trace_id;
  let retry_context = ref None in
  (match
     consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
       retry_context := Some input.Masc.Keeper_librarian.goal_context;
       true)
   with
   | Consumer.Progress_advanced progress ->
     check int "retried historical range advances" 2 progress.position.end_atom
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Official_advanced _
   | Consumer.Memory_not_committed -> fail "historical retry did not advance");
  (match !retry_context with
   | Some context -> check_no_task "retried catch-up" context
   | None -> fail "historical retry did not reach the commit boundary");
  write_meta ~current_task_id:"task-current-c" config trace_id;
  (match consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> fail "quiet tick recommitted") with
   | Consumer.Nothing_to_read -> ()
   | Consumer.Baseline_advanced _
   | Consumer.Memory_not_committed
   | Consumer.Official_advanced _
   | Consumer.Progress_advanced _ -> fail "quiet tick did not stay quiet")
;;

let prepare_three_unread_turns config ~trace_id =
  establish_progress config ~trace_id "turn-1";
  let first_two = [ message "turn-1"; message "turn-2" ] in
  let first_three = first_two @ [ message "turn-3" ] in
  let first_four = first_three @ [ message "turn-4" ] in
  append_boundary config ~trace_id ~turn:2 ~recorded_at:2.0 first_two;
  append_boundary config ~trace_id ~turn:3 ~recorded_at:3.0 first_three;
  append_boundary config ~trace_id ~turn:4 ~recorded_at:4.0 first_four;
  save_checkpoint config ~trace_id first_four 4
;;

(* These cases call the production wake body with only its Memory commit
   result controlled. Boundaries, checkpoint, selection and progress use the
   real stores; no provider or Memory snapshot write is simulated as proof.
   Empty working-context sources rule out a separate queue signal continuing
   the drain on the production loop's behalf. *)
let markers_without_working_sources (input : Masc.Keeper_librarian.input) =
  check int "no working-context source can schedule another wake" 0
    (List.length input.working_context.sources);
  text_markers input
;;

let test_one_wake_stops_on_failure_then_drains_successful_cuts () =
  Masc_test_deps.with_process_env Env_config.KeeperMemoryOs.librarian_env_key
    (Some "true")
  @@ fun () ->
  with_workspace @@ fun config ->
  prepare_three_unread_turns config ~trace_id:"trace-wake-retry";
  let failed_calls = ref [] in
  Queue_refresh.For_testing.run_durable_with_commit ~config ~keeper_name
    ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
      failed_calls := markers_without_working_sources input :: !failed_calls;
      false);
  check (list (list string)) "a refused commit ends this wake after one attempt"
    [ [ "turn-2"; "turn-3"; "turn-4" ] ] (List.rev !failed_calls);
  check_progress_end config 1;
  let committed_calls = ref [] in
  let commit ~expected_revision:_ ~range_id:_ ~official_range_id:_ input =
    committed_calls := markers_without_working_sources input :: !committed_calls;
    true
  in
  Queue_refresh.For_testing.run_durable_with_commit ~config ~keeper_name ~commit;
  check (list (list string)) "one later wake drains all successful small cuts"
    [ [ "turn-2" ]; [ "turn-3" ]; [ "turn-4" ] ] (List.rev !committed_calls);
  check_progress_end config 4;
  Queue_refresh.For_testing.run_durable_with_commit ~config ~keeper_name ~commit;
  check int "an empty backlog is not committed again" 3 (List.length !committed_calls)
;;

let test_one_wake_continues_after_an_initial_baseline () =
  Masc_test_deps.with_process_env Env_config.KeeperMemoryOs.librarian_env_key
    (Some "true")
  @@ fun () ->
  with_workspace @@ fun config ->
  let trace_id = "trace-wake-baseline" in
  write_meta config trace_id;
  let first = [ message "recorded-1" ] in
  let first_two = first @ [ message "recorded-2" ] in
  let all = first_two @ [ message "recorded-3" ] in
  append_boundary ~history_at_start:Boundaries.Continued_history config
    ~trace_id ~turn:1 ~recorded_at:1.0 first;
  append_boundary config ~trace_id ~turn:2 ~recorded_at:2.0 first_two;
  append_boundary config ~trace_id ~turn:3 ~recorded_at:3.0 all;
  save_checkpoint config ~trace_id all 3;
  check bool "this Keeper has no read position yet" true
    (Option.is_none (read_progress config));
  let calls = ref [] in
  Queue_refresh.For_testing.run_durable_with_commit ~config ~keeper_name
    ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
      calls := markers_without_working_sources input :: !calls;
      true);
  check (list (list string)) "baseline is skipped and the same wake commits unread turns"
    [ [ "recorded-2"; "recorded-3" ] ] (List.rev !calls);
  check_progress_end config 3
;;

let test_disabling_between_cuts_stops_until_a_new_enabled_wake () =
  let env_key = Env_config.KeeperMemoryOs.librarian_env_key in
  Masc_test_deps.with_process_env env_key (Some "true") @@ fun () ->
  with_workspace @@ fun config ->
  prepare_three_unread_turns config ~trace_id:"trace-wake-disable";
  Queue_refresh.For_testing.run_durable_with_commit ~config ~keeper_name
    ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
      ignore (markers_without_working_sources input : string list);
      false);
  check_progress_end config 1;
  let before_disable = ref [] in
  Queue_refresh.For_testing.run_durable_with_commit ~config ~keeper_name
    ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
      before_disable := markers_without_working_sources input :: !before_disable;
      Unix.putenv env_key "false";
      true);
  check (list (list string)) "turning off prevents the next cut in the same wake"
    [ [ "turn-2" ] ] (List.rev !before_disable);
  check_progress_end config 2;
  Unix.putenv env_key "true";
  let after_enable = ref [] in
  Queue_refresh.For_testing.run_durable_with_commit ~config ~keeper_name
    ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
      after_enable := markers_without_working_sources input :: !after_enable;
      true);
  check (list (list string)) "a separate enabled wake drains the remaining cuts"
    [ [ "turn-3" ]; [ "turn-4" ] ] (List.rev !after_enable);
  check_progress_end config 4
;;

let test_unchanged_boundaries_do_not_require_checkpoint () =
  with_workspace @@ fun config ->
  let trace_id = "trace-no-new-boundary" in
  establish_progress config ~trace_id "before";
  let session_dir = Masc.Keeper_fs.keeper_session_dir config trace_id in
  Sys.remove (Store.agent_core_checkpoint_path ~session_dir ~session_id:trace_id);
  match consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> fail "commit was called") with
  | Consumer.Nothing_to_read -> ()
  | Consumer.Baseline_advanced _
  | Consumer.Memory_not_committed
  | Consumer.Official_advanced _
  | Consumer.Progress_advanced _ -> fail "unchanged boundaries did not stop before checkpoint"
;;

let test_caught_up_prior_trace_transitions_to_current_trace () =
  with_workspace @@ fun config ->
  let trace_a = "trace-preflight-a" in
  establish_progress config ~trace_id:trace_a "a";
  let trace_b = "trace-preflight-b" in
  let messages_b = [ message "b" ] in
  append_boundary config ~trace_id:trace_b ~turn:1 ~recorded_at:2.0 messages_b;
  let progress_a =
    match read_progress config with
    | Some progress -> progress
    | None -> fail "trace-change fixture lost progress"
  in
  (match
     Progress.write
       ~keepers_dir:(Workspace.keepers_runtime_dir config)
       ~keeper_id:keeper_name
       { progress_a with boundary_lines_seen = 2 }
   with
   | Ok () -> ()
   | Error error -> fail (Progress.write_error_to_string error));
  write_meta config trace_b;
  save_checkpoint config ~trace_id:trace_b messages_b 1;
  let carried = ref [] in
  match
    Consumer.consume_one
      ~config
      ~keeper_name
      ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
        carried := text_markers input;
        true)
  with
  | Error error -> fail (Consumer.error_to_string error)
  | Ok (Consumer.Progress_advanced progress) ->
    check string "progress transitions to current trace" trace_b progress.position.trace_id;
    check (list string) "current trace starts at its fresh boundary" [ "b" ] !carried
  | Ok _ -> fail "caught-up prior trace did not transition"
;;

let test_absent_prior_checkpoint_transitions_to_current_trace () =
  with_workspace @@ fun config ->
  let trace_a = "trace-removed-a" in
  establish_progress config ~trace_id:trace_a "a";
  let old_session_dir = Masc.Keeper_fs.keeper_session_dir config trace_a in
  Sys.remove (Store.agent_core_checkpoint_path ~session_dir:old_session_dir ~session_id:trace_a);
  let trace_b = "trace-removed-b" in
  let messages_b = [ message "b" ] in
  append_boundary config ~trace_id:trace_b ~turn:1 ~recorded_at:2.0 messages_b;
  write_meta config trace_b;
  save_checkpoint config ~trace_id:trace_b messages_b 1;
  let carried = ref [] in
  match
    Consumer.consume_one ~config ~keeper_name
      ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
        carried := text_markers input;
        true)
  with
  | Error error -> fail (Consumer.error_to_string error)
  | Ok (Consumer.Progress_advanced progress) ->
    check string "removed trace is retired" trace_b progress.position.trace_id;
    check (list string) "new trace remains readable" [ "b" ] !carried
  | Ok _ -> fail "missing prior checkpoint left progress on the old trace"
;;

let test_absent_prior_checkpoint_requires_current_history_start () =
  with_workspace @@ fun config ->
  let trace_a = "trace-unwitnessed-a" in
  establish_progress config ~trace_id:trace_a "a";
  let old_session_dir = Masc.Keeper_fs.keeper_session_dir config trace_a in
  Sys.remove (Store.agent_core_checkpoint_path ~session_dir:old_session_dir ~session_id:trace_a);
  let trace_b = "trace-unwitnessed-b" in
  let messages_b = [ message "b" ] in
  append_boundary
    ~history_at_start:Boundaries.Continued_history
    config
    ~trace_id:trace_b
    ~turn:1
    ~recorded_at:2.0
    messages_b;
  write_meta config trace_b;
  save_checkpoint config ~trace_id:trace_b messages_b 1;
  (match
     Consumer.consume_one ~config ~keeper_name
       ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
         fail "unwitnessed trace transition called commit")
   with
   | Error (Consumer.Position_in_other_trace position) ->
     check string "old trace stays authoritative" trace_a position.trace_id
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "continued-only trace silently retired the old cursor");
  match read_progress config with
  | Some progress -> check string "old progress is unchanged" trace_a progress.position.trace_id
  | None -> fail "unwitnessed transition removed progress"
;;

let test_unread_prior_trace_finishes_before_current_trace () =
  with_workspace @@ fun config ->
  let trace_a = "trace-unread-a" in
  establish_progress config ~trace_id:trace_a "a-1";
  let messages_a = [ message "a-1"; message "a-2" ] in
  append_boundary config ~trace_id:trace_a ~turn:2 ~recorded_at:2.0 messages_a;
  save_checkpoint config ~trace_id:trace_a messages_a 2;
  let trace_b = "trace-unread-b" in
  let messages_b = [ message "b-1" ] in
  append_boundary config ~trace_id:trace_b ~turn:1 ~recorded_at:3.0 messages_b;
  write_meta config trace_b;
  save_checkpoint config ~trace_id:trace_b messages_b 1;
  let carried = ref [] in
  let commit ~expected_revision:_ ~range_id:_ ~official_range_id:_ input =
    carried := !carried @ [ text_markers input ];
    true
  in
  (match Consumer.consume_one ~config ~keeper_name ~commit with
   | Ok (Consumer.Progress_advanced progress) ->
     check string "prior trace remains first" trace_a progress.position.trace_id
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "unread prior trace did not advance");
  (match Consumer.consume_one ~config ~keeper_name ~commit with
   | Ok (Consumer.Progress_advanced progress) ->
     check string "current trace follows" trace_b progress.position.trace_id
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "current trace did not follow prior trace");
  check (list (list string))
    "each trace is carried once in order"
    [ [ "a-2" ]; [ "b-1" ] ]
    !carried
;;

let test_failed_long_range_retries_only_oldest_cut_point () =
  with_workspace @@ fun config ->
  let trace_id = "trace-bounded-retry" in
  establish_progress config ~trace_id "turn-1";
  let first_two = [ message "turn-1"; message "turn-2" ] in
  append_boundary config ~trace_id ~turn:2 ~recorded_at:2.0 first_two;
  save_checkpoint config ~trace_id first_two 2;
  (match consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> false) with
   | Consumer.Memory_not_committed -> ()
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Official_advanced _
   | Consumer.Progress_advanced _ -> fail "failed range unexpectedly advanced");
  let first_four = first_two @ [ message "turn-3"; message "turn-4" ] in
  append_boundary config ~trace_id ~turn:3 ~recorded_at:3.0
    (first_two @ [ message "turn-3" ]);
  append_boundary config ~trace_id ~turn:4 ~recorded_at:4.0 first_four;
  save_checkpoint config ~trace_id first_four 4;
  let retry = ref [] in
  (match
     consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
       retry := text_markers input;
       true)
   with
   | Consumer.Progress_advanced progress ->
     check int "bounded retry reaches oldest cut" 2 progress.position.end_atom
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Official_advanced _
   | Consumer.Memory_not_committed -> fail "bounded retry did not advance");
  check (list string) "retry does not grow with later turns" [ "turn-2" ] !retry;
  let remaining = ref [] in
  (match
     consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
       remaining := text_markers input;
       true)
   with
   | Consumer.Progress_advanced progress ->
     check int "bounded catch-up reaches next cut" 3 progress.position.end_atom
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Official_advanced _
   | Consumer.Memory_not_committed -> fail "remaining range did not advance");
  check (list string) "bounded catch-up remains active" [ "turn-3" ] !remaining;
  let final = ref [] in
  (match
     consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
       final := text_markers input;
       true)
   with
   | Consumer.Progress_advanced progress ->
     check int "bounded catch-up reaches final cut" 4 progress.position.end_atom
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Official_advanced _
   | Consumer.Memory_not_committed -> fail "final range did not advance");
  check (list string) "final turn remains readable" [ "turn-4" ] !final;
  (match consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> fail "empty range called commit") with
   | Consumer.Nothing_to_read -> ()
   | Consumer.Baseline_advanced _
   | Consumer.Progress_advanced _
   | Consumer.Official_advanced _
   | Consumer.Memory_not_committed -> fail "empty pass did not clear bounded catch-up")
;;

let test_last_matching_boundary_wins_when_clock_moves_backward () =
  with_workspace @@ fun config ->
  let trace_id = "trace-clock-regression" in
  establish_progress config ~trace_id "before";
  let messages = [ message "before"; message "after" ] in
  append_boundary config ~trace_id ~turn:2 ~recorded_at:20.0 messages;
  append_boundary config ~trace_id ~turn:3 ~recorded_at:10.0 messages;
  save_checkpoint config ~trace_id messages 3;
  let selected_turn = ref None in
  (match
     consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
       selected_turn := Some (Ids.Turn_ref.absolute_turn input.turn_ref);
       true)
   with
   | Consumer.Progress_advanced _ -> ()
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Official_advanced _
   | Consumer.Memory_not_committed -> fail "clock regression range did not advance");
  check (option int) "last appended boundary is authoritative" (Some 3) !selected_turn
;;

let test_distinct_boundaries_reject_non_monotone_counterpart_interval () =
  with_workspace @@ fun config ->
  let trace_id = "trace-non-monotone-counterpart" in
  write_meta config trace_id;
  let first = [ message "turn-1" ] in
  save_checkpoint config ~trace_id first 1;
  append_boundary config ~trace_id ~turn:1 ~recorded_at:20.0 first;
  (match consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> true) with
   | Consumer.Baseline_advanced _ | Consumer.Progress_advanced _ -> ()
   | Consumer.Nothing_to_read
   | Consumer.Official_advanced _
   | Consumer.Memory_not_committed -> fail "fixture progress did not advance");
  let messages = first @ [ message "turn-2" ] in
  append_boundary config ~trace_id ~turn:2 ~recorded_at:10.0 messages;
  save_checkpoint config ~trace_id messages 2;
  let commit_called = ref false in
  (match
     Consumer.consume_one ~config ~keeper_name
       ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
         commit_called := true;
         true)
   with
   | Error (Consumer.Counterpart_interval_non_monotone { after; before }) ->
     check (float 0.001) "prior boundary time" 20.0 after;
     check (float 0.001) "range end time" 10.0 before
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "non-monotone interval advanced as empty evidence");
  check bool "memory commit is not attempted" false !commit_called;
  match read_progress config with
  | Some progress -> check int "cursor stays before rejected range" 1 progress.position.end_atom
  | None -> fail "rejected interval removed progress"
;;

let test_equal_boundary_timestamps_form_an_empty_counterpart_interval () =
  with_workspace @@ fun config ->
  let trace_id = "trace-equal-counterpart-boundary" in
  write_meta config trace_id;
  let first = [ message "turn-1" ] in
  save_checkpoint config ~trace_id first 1;
  append_boundary config ~trace_id ~turn:1 ~recorded_at:20.0 first;
  (match consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> true) with
   | Consumer.Baseline_advanced _ | Consumer.Progress_advanced _ -> ()
   | Consumer.Nothing_to_read
   | Consumer.Official_advanced _
   | Consumer.Memory_not_committed -> fail "fixture progress did not advance");
  let messages = first @ [ message "turn-2" ] in
  append_boundary config ~trace_id ~turn:2 ~recorded_at:20.0 messages;
  save_checkpoint config ~trace_id messages 2;
  let chat_path =
    Keeper_chat_store.chat_path
      ~base_dir:config.Workspace.base_path
      ~keeper_name
  in
  Fs_compat.mkdir_p (Filename.dirname chat_path);
  Fs_compat.save_file
    chat_path
    ({|{"id":"outside-empty-interval","role":"user","content":"must not be read","ts":19.0,"speaker_authority":"unknown"}|}
     ^ "\n");
  let observed = ref None in
  (match
     Consumer.consume_one ~config ~keeper_name
       ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
         observed := Some input.Masc.Keeper_librarian.counterpart_observations;
         true)
   with
   | Ok (Consumer.Progress_advanced progress) ->
     check int "equal interval advances" 2 progress.position.end_atom
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "equal interval did not advance");
  match !observed with
  | Some observations -> check int "equal interval is empty" 0 (List.length observations)
  | None -> fail "equal interval did not reach commit"
;;

let test_unknown_speaker_authority_does_not_advance_progress () =
  with_workspace @@ fun config ->
  let trace_id = "trace-unknown-speaker-authority" in
  establish_progress config ~trace_id "before";
  let messages = [ message "before"; message "after" ] in
  append_boundary config ~trace_id ~turn:2 ~recorded_at:2.0 messages;
  save_checkpoint config ~trace_id messages 2;
  let chat_path =
    Keeper_chat_store.chat_path
      ~base_dir:config.Workspace.base_path
      ~keeper_name
  in
  Fs_compat.mkdir_p (Filename.dirname chat_path);
  (match
     Fs_compat.save_file_atomic_strict
       chat_path
       ({|{"id":"unknown-authority","role":"user","content":"do not lose me","ts":1.5,"speaker_authority":"admin"}|}
        ^ "\n")
   with
   | Ok () -> ()
   | Error detail -> failf "write chat fixture: %s" detail);
  let commit_called = ref false in
  (match
     Consumer.consume_one
       ~config
       ~keeper_name
       ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
         commit_called := true;
         true)
   with
   | Error
       (Consumer.Counterpart_observations_unreadable
          (Masc.Keeper_librarian_input_sources.Chat_store_unreadable _)) ->
     ()
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "unknown speaker authority advanced as absent evidence");
  check bool "memory commit is not attempted" false !commit_called;
  match read_progress config with
  | Some progress ->
    check int
      "cursor stays before the unreadable counterpart row"
      1
      progress.position.end_atom
  | None -> fail "unreadable counterpart row removed progress"
;;

let test_missing_speaker_authority_does_not_advance_progress () =
  with_workspace @@ fun config ->
  let trace_id = "trace-missing-speaker-authority" in
  establish_progress config ~trace_id "before";
  let messages = [ message "before"; message "after" ] in
  append_boundary config ~trace_id ~turn:2 ~recorded_at:2.0 messages;
  save_checkpoint config ~trace_id messages 2;
  let chat_path =
    Keeper_chat_store.chat_path
      ~base_dir:config.Workspace.base_path
      ~keeper_name
  in
  Fs_compat.mkdir_p (Filename.dirname chat_path);
  (match
     Fs_compat.save_file_atomic_strict
       chat_path
       ({|{"id":"missing-authority","role":"user","content":"do not lose me","ts":1.5,"speaker_id":"speaker-7"}|}
        ^ "\n")
   with
   | Ok () -> ()
   | Error detail -> failf "write chat fixture: %s" detail);
  let commit_called = ref false in
  (match
     Consumer.consume_one
       ~config
       ~keeper_name
       ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
         commit_called := true;
         true)
   with
   | Error
       (Consumer.Counterpart_observations_unreadable
          (Masc.Keeper_librarian_input_sources.Chat_store_unreadable _)) ->
     ()
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "missing speaker authority advanced as absent evidence");
  check bool "memory commit is not attempted" false !commit_called;
  check_progress_end config 1
;;

let test_torn_external_tail_retries_the_same_range_once () =
  with_workspace @@ fun config ->
  let trace_id = "trace-torn-external-tail" in
  establish_progress config ~trace_id "before";
  let messages = [ message "before"; message "after" ] in
  append_boundary config ~trace_id ~turn:2 ~recorded_at:2.0 messages;
  save_checkpoint config ~trace_id messages 2;
  let external_item : Keeper_external_attention.item =
    { event_id = Keeper_external_attention.event_id_of_dedupe_key "torn:consumer"
    ; dedupe_key = "torn:consumer"
    ; keeper_name
    ; conversation =
        { conversation_id = "agent:torn"
        ; surface = Keeper_external_attention.Agent
        }
    ; external_message = None
    ; source_label = "agent"
    ; actor =
        { actor_id = Some "external"
        ; display_name = Some "External"
        ; authority = Keeper_chat_store.External
        }
    ; urgency = Keeper_external_attention.Ambient
    ; content_preview = "recover-after-newline"
    ; content_ref = None
    ; received_at = 1.5
    ; metadata = []
    }
  in
  let line =
    Yojson.Safe.to_string
      (Keeper_external_attention.event_to_json
         (Keeper_external_attention.Recorded external_item))
  in
  let path =
    Keeper_external_attention.attention_path
      ~base_path:config.Workspace.base_path
      ~keeper_name
  in
  Fs_compat.mkdir_p (Filename.dirname path);
  let write contents =
    match Fs_compat.save_file_atomic_strict path contents with
    | Ok () -> ()
    | Error detail -> failf "write external attention fixture: %s" detail
  in
  write line;
  let commits = ref 0 in
  (match
     Consumer.consume_one
       ~config
       ~keeper_name
       ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
         incr commits;
         true)
   with
   | Error
       (Consumer.Counterpart_observations_unreadable
          (Masc.Keeper_librarian_input_sources.External_attention_unreadable
             (Keeper_external_attention.Incomplete_tail _))) ->
     ()
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "torn external tail advanced as complete evidence");
  check int "torn tail does not call Memory commit" 0 !commits;
  check_progress_end config 1;
  write (line ^ "\n");
  let observations = ref [] in
  (match
     Consumer.consume_one
       ~config
       ~keeper_name
       ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
         incr commits;
         observations :=
           List.map
             (fun (observation : Keeper_counterpart_observation.t) ->
                observation.content)
             input.counterpart_observations;
         true)
   with
   | Ok (Consumer.Progress_advanced progress) ->
     check int "repaired range advances once" 2 progress.position.end_atom
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "repaired external row did not advance the same range");
  check (list string)
    "repaired row reaches the retried range"
    [ "recover-after-newline" ]
    !observations;
  (match
     Consumer.consume_one
       ~config
       ~keeper_name
       ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
         incr commits;
         true)
   with
   | Ok Consumer.Nothing_to_read -> ()
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "settled range was consumed more than once");
  check int "Memory commit runs exactly once" 1 !commits
;;

let test_torn_chat_tail_retries_the_same_range_once () =
  with_workspace @@ fun config ->
  let trace_id = "trace-torn-chat-tail" in
  establish_progress config ~trace_id "before";
  let messages = [ message "before"; message "after" ] in
  append_boundary config ~trace_id ~turn:2 ~recorded_at:2.0 messages;
  save_checkpoint config ~trace_id messages 2;
  let path =
    Keeper_chat_store.chat_path
      ~base_dir:config.Workspace.base_path
      ~keeper_name
  in
  Fs_compat.mkdir_p (Filename.dirname path);
  let complete_prefix =
    {|{"id":"complete-prefix","role":"user","content":"complete-prefix","ts":0.5,"speaker_authority":"owner"}|}
    ^ "\n"
  in
  let torn_row =
    {|{"id":"torn-chat","role":"user","content":"recover-after-newline","ts":1.5,"speaker_authority":"owner"}|}
  in
  let write contents =
    match Fs_compat.save_file_atomic_strict path contents with
    | Ok () -> ()
    | Error detail -> failf "write chat fixture: %s" detail
  in
  write (complete_prefix ^ torn_row);
  (match Keeper_chat_store.load_all ~base_dir:config.Workspace.base_path ~keeper_name with
   | [ prefix ] ->
     check string "permissive reader keeps complete prefix" "complete-prefix" prefix.content
   | rows -> failf "expected one complete permissive row, got %d" (List.length rows));
  let commits = ref 0 in
  (match
     Consumer.consume_one
       ~config
       ~keeper_name
       ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
         incr commits;
         true)
   with
   | Error
       (Consumer.Counterpart_observations_unreadable
          (Masc.Keeper_librarian_input_sources.Chat_store_unreadable _)) ->
     ()
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "torn chat tail advanced as complete evidence");
  check int "torn chat tail does not call Memory commit" 0 !commits;
  check_progress_end config 1;
  write (complete_prefix ^ torn_row ^ "\n");
  let observations = ref [] in
  (match
     Consumer.consume_one
       ~config
       ~keeper_name
       ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
         incr commits;
         observations :=
           List.map
             (fun (observation : Keeper_counterpart_observation.t) ->
                observation.content)
             input.counterpart_observations;
         true)
   with
   | Ok (Consumer.Progress_advanced progress) ->
     check int "repaired range advances once" 2 progress.position.end_atom
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "repaired chat row did not advance the same range");
  check (list string)
    "repaired row reaches the retried range"
    [ "recover-after-newline" ]
    !observations;
  (match
     Consumer.consume_one
       ~config
       ~keeper_name
       ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
         incr commits;
         true)
   with
   | Ok Consumer.Nothing_to_read -> ()
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "settled range was consumed more than once");
  check int "Memory commit runs exactly once" 1 !commits
;;

let test_restart_cut_never_commits_a_current_unfinished_turn () =
  with_workspace @@ fun config ->
  let module Current = Masc.Keeper_memory_os_current in
  let module Memory = Masc.Keeper_memory_os_types in
  let trace_id = "trace-restart-cut" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:config.Workspace.base_path in
  establish_progress config ~trace_id "old first";
  let write_claims claims =
    let facts = List.map (fun claim -> Memory.observed ~claim ~category:Memory.Fact
        ~now:1. ~origin:{ kind = Memory.Authored; trace_id }) claims in
    match Current.apply_disposition ~keepers_dir ~keeper_id:keeper_name ~now:1.
        ~source:{ kind = Current.Librarian; trace_id } ~new_claims:facts ~absorbed:[] () with
    | Ok snapshot -> snapshot | Error detail -> fail detail in
  let seed = write_claims ["seed fact"] in
  check int "seed revision" 1 seed.revision;
  let old = List.map message ["old first"; "old middle"; "repeated endpoint"] in
  save_checkpoint config ~trace_id old 2;
  append_boundary config ~trace_id ~turn:2 ~recorded_at:2. old;
  save_checkpoint config ~trace_id [] 3;
  let append event recorded_at =
    match Boundaries.append ~keepers_dir:(Workspace.keepers_runtime_dir config)
        ~keeper_id:keeper_name { Boundaries.recorded_at; event } with
    | Ok () -> () | Error error -> fail (Boundaries.append_error_to_string error) in
  append (Boundaries.History_restarted { trace_id }) 3.;
  let completed = [message "new completed"] in
  save_checkpoint config ~trace_id completed 4;
  let position = match Boundaries.position_of_messages completed with
    | Ok position -> position | Error detail -> fail detail in
  append (Boundaries.Turn_ended
      { turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:3;
        history_at_start = Boundaries.Fresh_history; position }) 4.;
  let in_flight = completed @ List.map message ["new unfinished"; "repeated endpoint"] in
  save_checkpoint config ~trace_id in_flight 5;
  let inputs = ref [] in
  let commit ~expected_revision:_ ~range_id:_ ~official_range_id:_ input =
    let markers = text_markers input in
    inputs := !inputs @ [markers];
    let (_ : Current.t) = write_claims markers in
    true in
  let cursor () = match read_progress config with
    | Some progress -> progress.position.end_atom | None -> fail "missing progress" in
  let snapshot () =
    match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name with
    | Ok (Some snapshot) -> snapshot | Ok None -> fail "missing Memory"
    | Error detail -> fail detail in
  (match consume config commit with
   | Consumer.Progress_advanced _ -> () | _ -> fail "current completed turn not consumed");
  let committed = snapshot () in
  check (triple (list (list string)) int (list string))
    "only completed current input reaches actual Memory and progress"
    ([["new completed"]], 1, ["new completed"; "seed fact"])
    (!inputs, cursor (), List.map (fun (fact : Memory.fact) -> fact.claim) committed.facts
                         |> List.sort String.compare);
  check int "one Memory commit" 2 committed.revision;
  (match consume config commit with
   | Consumer.Nothing_to_read -> () | _ -> fail "unfinished turn was consumed on next tick");
  check int "no Memory commit while current turn remains unfinished" 2 (snapshot ()).revision;
  append_boundary config ~trace_id ~turn:4 ~recorded_at:6. in_flight;
  (match consume config commit with
   | Consumer.Progress_advanced _ -> () | _ -> fail "newly completed turn not consumed");
  check (list (list string)) "each current message is consumed after its own turn ends"
    [["new completed"]; ["new unfinished"; "repeated endpoint"]] !inputs;
  check int "all current atoms now acknowledged" 3 (cursor ());
  check int "one further Memory commit" 3 (snapshot ()).revision
;;

(* Establish real durable progress in a shorter restarted history. Setup uses
   the commit result seam; checkpoint access below is the production store path. *)
let with_consumed_shorter_history f =
  with_workspace @@ fun config ->
  let trace_id = "trace-preflight-restarted" in
  let old = List.map message ["old first"; "old middle"; "old end"] in
  write_meta config trace_id;
  save_checkpoint config ~trace_id old 1;
  append_boundary config ~trace_id ~turn:1 ~recorded_at:1. old;
  (match consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> true) with
   | Consumer.Progress_advanced _ -> () | _ -> fail "old history was not consumed");
  save_checkpoint config ~trace_id [] 2;
  let current = [message "current"] in
  save_checkpoint config ~trace_id current 3;
  let position = match Boundaries.position_of_messages current with
    | Ok position -> position | Error detail -> fail detail in
  (match Boundaries.append ~keepers_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_id:keeper_name
      { recorded_at = 3.; event = Boundaries.Turn_ended
          { turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:2;
            history_at_start = Boundaries.Fresh_history; position } } with
   | Ok () -> () | Error error -> fail (Boundaries.append_error_to_string error));
  (match consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> true) with
   | Consumer.Progress_advanced progress ->
     check int "shorter current history consumed" 1 progress.position.end_atom;
     check int "both boundary lines seen" 2 progress.boundary_lines_seen
   | _ -> fail "current history was not consumed");
  let session_dir = Masc.Keeper_fs.keeper_session_dir config trace_id in
  let checkpoint_path = Store.agent_core_checkpoint_path ~session_dir ~session_id:trace_id in
  f config trace_id current session_dir checkpoint_path
;;

type checkpoint_fault = Missing_checkpoint | Corrupt_checkpoint

let damage_checkpoint fault ~session_dir ~trace_id checkpoint_path =
  (match fault with
   | Missing_checkpoint -> Sys.remove checkpoint_path
   | Corrupt_checkpoint ->
     (match Fs_compat.save_file_atomic checkpoint_path "{" with
      | Ok () -> () | Error detail -> fail detail));
  (* Positive control: loading this very file through the real store fails.
     A quiet consumer tick must stop before that loader, not hide its error. *)
  match fault, Store.load_agent_core ~session_dir ~session_id:trace_id with
  | Missing_checkpoint, Error Store.Not_found
  | Corrupt_checkpoint, Error (Store.Parse_error _) -> ()
  | _, Error error -> fail (Store.checkpoint_load_error_to_string error)
  | _, Ok _ -> fail "damaged checkpoint unexpectedly loaded"
;;

let test_seen_restart_skips_checkpoint fault () =
  with_consumed_shorter_history @@ fun config trace_id _current session_dir path ->
  damage_checkpoint fault ~session_dir ~trace_id path;
  let progress_path = Progress.path_for_keepers_dir
      ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name in
  let before = Fs_compat.load_file progress_path in
  List.iter (fun _tick ->
      (match Consumer.consume_one ~config ~keeper_name
          ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> fail "quiet tick called commit") with
       | Ok Consumer.Nothing_to_read -> ()
       | Ok _ -> fail "quiet tick changed progress"
       | Error error -> fail (Consumer.error_to_string error));
      (match Consumer.unread_turns ~config ~keeper_name with
       | Ok { atoms = 0; official = 0 } -> ()
       | Ok _ -> fail "quiet count reports unread history"
       | Error error -> fail (Consumer.error_to_string error));
      check string "quiet tick preserves actual progress bytes" before
        (Fs_compat.load_file progress_path)) [1; 2; 3]
;;

let test_new_completed_cut_still_reads_checkpoint () =
  with_consumed_shorter_history @@ fun config trace_id current session_dir path ->
  damage_checkpoint Corrupt_checkpoint ~session_dir ~trace_id path;
  append_boundary config ~trace_id ~turn:3 ~recorded_at:4.
    (current @ [message "next completed"]);
  match Consumer.consume_one ~config ~keeper_name
      ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> fail "corrupt checkpoint called commit") with
  | Error (Consumer.Checkpoint_unreadable (Store.Parse_error _)) -> ()
  | Error error -> fail (Consumer.error_to_string error)
  | Ok _ -> fail "new completed cut skipped checkpoint validation"
;;

let test_unseen_restart_still_reads_checkpoint () =
  with_consumed_shorter_history @@ fun config trace_id _current session_dir path ->
  damage_checkpoint Corrupt_checkpoint ~session_dir ~trace_id path;
  (match Boundaries.append ~keepers_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_id:keeper_name
      { recorded_at = 4.; event = Boundaries.History_restarted { trace_id } } with
   | Ok () -> () | Error error -> fail (Boundaries.append_error_to_string error));
  match Consumer.consume_one ~config ~keeper_name
      ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> fail "unreadable restart called commit") with
  | Error (Consumer.Checkpoint_unreadable (Store.Parse_error _)) -> ()
  | Error error -> fail (Consumer.error_to_string error)
  | Ok _ -> fail "unseen restart skipped checkpoint validation"
;;

let test_trace_change_without_history_witness_keeps_prior_progress () =
  with_consumed_shorter_history @@ fun config trace_id _current _session_dir _path ->
  write_meta config "trace-preflight-new";
  match Consumer.consume_one ~config ~keeper_name
      ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> fail "missing trace checkpoint called commit") with
  | Error (Consumer.Position_in_other_trace position) ->
    check string "prior trace remains authoritative" trace_id position.trace_id;
    check int "prior trace position remains authoritative" 1 position.end_atom
  | Error error -> fail (Consumer.error_to_string error)
  | Ok _ -> fail "trace change without a history witness discarded prior progress"
;;

let test_new_unreadable_boundary_is_not_hidden_by_preflight () =
  with_consumed_shorter_history @@ fun config _trace_id _current _session_dir _path ->
  let path = Boundaries.path_for_keepers_dir
      ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name in
  let oc = open_out_gen [Open_wronly; Open_append; Open_binary] 0o600 path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc "{\n");
  match Consumer.consume_one ~config ~keeper_name
      ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> fail "unreadable boundary called commit") with
  | Error (Consumer.Range_stopped (Masc.Keeper_librarian_range.Unreadable_line
      { line = 3; error = Boundaries.Not_json _ })) -> ()
  | Error error -> fail (Consumer.error_to_string error)
  | Ok _ -> fail "new unreadable boundary was hidden as a quiet tick"
;;

let test_same_name_clusters_keep_independent_ranges () =
  with_workspace @@ fun default ->
  let a = config_in_cluster default "Durable/A" in
  let b = config_in_cluster default "Durable/B" in
  let run config trace_id marker =
    establish_progress config ~trace_id (marker ^ "-before");
    let messages = [ message (marker ^ "-before"); message marker ] in
    append_boundary config ~trace_id ~turn:2 ~recorded_at:2.0 messages;
    save_checkpoint config ~trace_id messages 2;
    let carried = ref [] in
    (match
       consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
         carried := text_markers input;
         true)
     with
     | Consumer.Progress_advanced _ -> ()
     | Consumer.Nothing_to_read
     | Consumer.Baseline_advanced _
     | Consumer.Official_advanced _
     | Consumer.Memory_not_committed -> fail "cluster range did not advance");
    !carried
  in
  let a_carried = run a "trace-a" "cluster-a" in
  let b_carried = run b "trace-b" "cluster-b" in
  check (list string) "A reads only A" [ "cluster-a" ] a_carried;
  check (list string) "B reads only B" [ "cluster-b" ] b_carried;
  check bool "cluster progress paths differ" false
    (String.equal
       (Progress.path_for_keepers_dir
          ~keepers_dir:(Workspace.keepers_runtime_dir a)
          ~keeper_id:keeper_name)
       (Progress.path_for_keepers_dir
          ~keepers_dir:(Workspace.keepers_runtime_dir b)
          ~keeper_id:keeper_name))
;;

let test_same_name_clusters_keep_independent_commit_receipts () =
  with_workspace @@ fun default ->
  let module Current = Masc.Keeper_memory_os_current in
  let a = config_in_cluster default "Receipt/A" in
  let b = config_in_cluster default "Receipt/B" in
  let memory_keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:default.Workspace.base_path
  in
  let prepare config trace_id marker =
    establish_progress config ~trace_id (marker ^ "-before");
    let messages = [ message (marker ^ "-before"); message marker ] in
    append_boundary config ~trace_id ~turn:2 ~recorded_at:2.0 messages;
    save_checkpoint config ~trace_id messages 2
  in
  prepare a "trace-receipt-a" "cluster-a";
  prepare b "trace-receipt-b" "cluster-b";
  let commits = ref 0 in
  let commit ~expected_revision:_ ~range_id ~official_range_id input =
    incr commits;
    match
      Current.apply_disposition
        ?durable_range_id:range_id
        ?official_range_id
        ~absorbed:[]
        ~keepers_dir:memory_keepers_dir
        ~keeper_id:keeper_name
        ~now:(Float.of_int !commits)
        ~source:
          { kind = Current.Librarian
          ; trace_id = Ids.Turn_ref.trace_id input.Masc.Keeper_librarian.turn_ref
          }
        ~new_claims:[]
        ()
    with
    | Ok _ -> true
    | Error detail -> fail detail
  in
  let fail_progress ~keepers_dir:_ ~keeper_id:_ _ =
    Error
      (Progress.Write_failed
         { path = "injected-progress-write"; message = "post-commit failure" })
  in
  let commit_without_progress config trace_id =
    write_meta config trace_id;
    match
      Consumer.For_testing.consume_one_with_progress_writer
        ~write_progress_store:fail_progress
        ~write_official_progress_store:Masc.Keeper_librarian_official_progress.write
        ~config
        ~keeper_name
        ~commit
    with
    | Error (Consumer.Progress_write_failed _) -> ()
    | Error error -> fail (Consumer.error_to_string error)
    | Ok _ -> fail "cluster commit did not reach injected progress failure"
  in
  commit_without_progress a "trace-receipt-a";
  commit_without_progress b "trace-receipt-b";
  check int "both clusters committed Memory once" 2 !commits;
  let recover config trace_id =
    write_meta config trace_id;
    match
      Consumer.consume_one ~config ~keeper_name
        ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
          fail "cluster receipt recovery replayed Memory commit")
    with
    | Ok (Consumer.Progress_advanced progress) -> progress
    | Error error -> fail (Consumer.error_to_string error)
    | Ok _ -> fail "cluster receipt did not repair progress"
  in
  let a_progress = recover a "trace-receipt-a" in
  let b_progress = recover b "trace-receipt-b" in
  check string "A recovers its own receipt" "trace-receipt-a" a_progress.position.trace_id;
  check string "B recovers its own receipt" "trace-receipt-b" b_progress.position.trace_id;
  check int "receipt recovery performs no replay commits" 2 !commits
;;

let test_selected_range_bypasses_recent_window () =
  let messages = List.init 80 (fun index -> message (string_of_int index)) in
  let input : Masc.Keeper_librarian.input =
    { turn_ref = Ids.Turn_ref.make ~trace_id:"projection" ~absolute_turn:1
    ; goal_context = Masc.Keeper_librarian.No_task
    ; keeper_instructions = ""
    ; current = None
    ; working_context = Masc.Keeper_librarian_context.empty
    ; messages
    ; tool_observations = []
    ; counterpart_observations = []
    }
  in
  let projected =
    Masc.Keeper_librarian_runtime.For_testing.input_for_projection
      Masc.Keeper_librarian_runtime.Already_selected_range
      input
  in
  check int "durable range keeps every selected message" 80
    (List.length projected.messages)
;;

let test_counterpart_range_reads_beyond_recent_windows () =
  with_workspace @@ fun config ->
  let base_dir = config.Workspace.base_path in
  let speaker : Keeper_chat_store.speaker =
    { speaker_id = Some "owner"
    ; speaker_name = Some "Owner"
    ; speaker_authority = Keeper_chat_store.Owner
    }
  in
  List.iter
    (fun index ->
       Keeper_chat_store.append_user_message
         ~base_dir
         ~keeper_name
         ~content:(Printf.sprintf "chat-%03d" index)
         ~speaker
         ())
    (List.init 105 Fun.id);
  let payload = String.make (1024 * 1024) 'x' in
  let external_contents =
    List.init 5 (fun index -> Printf.sprintf "external-%d:%s" index payload)
  in
  List.iteri
    (fun index content_preview ->
       let surface = Keeper_external_attention.Agent in
       let dedupe_key = Printf.sprintf "complete-range-%d" index in
       let item : Keeper_external_attention.item =
         { event_id = Keeper_external_attention.event_id_of_dedupe_key dedupe_key
         ; dedupe_key
         ; keeper_name
         ; conversation = { conversation_id = "agent:test"; surface }
         ; external_message = None
         ; source_label = "agent"
         ; actor =
             { actor_id = Some "external"
             ; display_name = Some "External"
             ; authority = Keeper_chat_store.External
             }
         ; urgency = Keeper_external_attention.Ambient
         ; content_preview
         ; content_ref = None
         ; received_at = Float.of_int (index + 1)
         ; metadata = []
         }
       in
       match Keeper_external_attention.record ~base_path:base_dir item with
       | `Recorded -> ()
       | `Duplicate _ -> fail "unexpected duplicate external fixture"
       | `Error detail -> fail detail)
    external_contents;
  let observations =
    match
      Masc.Keeper_librarian_input_sources.counterpart_observations_between_offloaded
        ~base_dir
        ~keeper_name
        ~after:None
        ~before:(Time_compat.now () +. 100.)
    with
    | Ok observations -> observations
    | Error error ->
      fail (Masc.Keeper_librarian_input_sources.read_error_to_string error)
  in
  let contents =
    List.map (fun (observation : Keeper_counterpart_observation.t) -> observation.content)
      observations
  in
  List.iter
    (fun expected ->
       check bool expected true (List.exists (String.equal expected) contents))
    [ "chat-000"; "chat-052"; "chat-104" ];
  List.iter
    (fun index ->
       let expected = List.nth external_contents index in
       check bool (Printf.sprintf "external-%d" index) true
         (List.exists (String.equal expected) contents))
    [ 0; 2; 4 ]
;;

let test_counterpart_range_includes_upper_boundary_once () =
  with_workspace @@ fun config ->
  let base_dir = config.Workspace.base_path in
  let record ~dedupe_key ~content_preview ~received_at =
    let surface = Keeper_external_attention.Agent in
    let item : Keeper_external_attention.item =
      { event_id = Keeper_external_attention.event_id_of_dedupe_key dedupe_key
      ; dedupe_key
      ; keeper_name
      ; conversation = { conversation_id = "agent:boundary"; surface }
      ; external_message = None
      ; source_label = "agent"
      ; actor =
          { actor_id = Some "external"
          ; display_name = Some "External"
          ; authority = Keeper_chat_store.External
          }
      ; urgency = Keeper_external_attention.Ambient
      ; content_preview
      ; content_ref = None
      ; received_at
      ; metadata = []
      }
    in
    match Keeper_external_attention.record ~base_path:base_dir item with
    | `Recorded -> ()
    | `Duplicate _ -> fail "unexpected duplicate external fixture"
    | `Error detail -> fail detail
  in
  record ~dedupe_key:"at-lower" ~content_preview:"at-lower" ~received_at:1.;
  record ~dedupe_key:"at-upper" ~content_preview:"at-upper" ~received_at:2.;
  let observations =
    match
      Masc.Keeper_librarian_input_sources.counterpart_observations_between
        ~base_dir
        ~keeper_name
        ~after:(Some 1.)
        ~before:2.
    with
    | Ok observations -> observations
    | Error error ->
      fail (Masc.Keeper_librarian_input_sources.read_error_to_string error)
  in
  check
    (list string)
    "range is open after and closed before"
    [ "at-upper" ]
    (List.map
       (fun (observation : Keeper_counterpart_observation.t) -> observation.content)
       observations)
;;

let test_external_chat_pair_straddling_a_boundary_is_not_duplicated () =
  with_workspace @@ fun config ->
  let base_dir = config.Workspace.base_path in
  let surface = Keeper_external_attention.Agent in
  let conversation_id = "agent:boundary-dedup" in
  let message_id = "external-boundary-message" in
  let received_at = Time_compat.now () -. 10.0 in
  let boundary = received_at +. 1.0 in
  let item : Keeper_external_attention.item =
    { event_id = Keeper_external_attention.event_id_of_dedupe_key message_id
    ; dedupe_key = message_id
    ; keeper_name
    ; conversation = { conversation_id; surface }
    ; external_message =
        Some { surface; message_id; reply_to_message_id = None }
    ; source_label = "agent"
    ; actor =
        { actor_id = Some "external"
        ; display_name = Some "External"
        ; authority = Keeper_chat_store.External
        }
    ; urgency = Keeper_external_attention.Ambient
    ; content_preview = "delivered once"
    ; content_ref = None
    ; received_at
    ; metadata = []
    }
  in
  (match Keeper_external_attention.record ~base_path:base_dir item with
   | `Recorded -> ()
   | `Duplicate _ -> fail "unexpected duplicate external fixture"
   | `Error detail -> fail detail);
  let read ~after ~before =
    match
      Masc.Keeper_librarian_input_sources.counterpart_observations_between
        ~base_dir
        ~keeper_name
        ~after
        ~before
    with
    | Ok observations -> observations
    | Error error ->
      fail (Masc.Keeper_librarian_input_sources.read_error_to_string error)
  in
  check
    (list string)
    "the first range emits the external delivery"
    [ "delivered once" ]
    (List.map
       (fun (observation : Keeper_counterpart_observation.t) -> observation.content)
       (read ~after:None ~before:boundary));
  let speaker : Keeper_chat_store.speaker =
    { speaker_id = Some "external"
    ; speaker_name = Some "External"
    ; speaker_authority = Keeper_chat_store.External
    }
  in
  Keeper_chat_store.append_user_message
    ~base_dir
    ~keeper_name
    ~content:"delivered once"
    ~conversation_id
    ~external_message_id:message_id
    ~speaker
    ();
  check
    (list string)
    "the later chat projection is not emitted a second time"
    []
    (List.map
       (fun (observation : Keeper_counterpart_observation.t) -> observation.content)
       (read ~after:(Some boundary) ~before:(Time_compat.now () +. 10.0)))
;;

(* {1 Official-client turns (RFC §10-3)} *)

module Official = Masc.Keeper_librarian_official_progress
module History = Masc.Keeper_context_core_history

let append_official_boundary config ~trace_id ~turn ~recorded_at =
  let record : Boundaries.record =
    { recorded_at
    ; event =
        Boundaries.Turn_ended
          { turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:turn
          ; history_at_start = Boundaries.Continued_history
          ; position = Boundaries.No_atom_history
          }
    }
  in
  match
    Boundaries.append
      ~keepers_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_id:keeper_name
      record
  with
  | Ok () -> ()
  | Error error -> fail (Boundaries.append_error_to_string error)
;;

let session config trace_id =
  Masc.Keeper_context_core.create_session
    ~session_id:trace_id
    ~base_dir:(Masc.Keeper_fs.session_store_path config)
;;

(* The lines an official-client turn leaves: the user's line, the assistant's,
   and one observation per tool call. *)
let write_official_turn config ~trace_id ~turn ~user ~assistant ~tools =
  let turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:turn in
  let session = session config trace_id in
  History.persist_message ~keeper_name ~turn_ref ~source:"direct_user" session (message user);
  History.persist_message ~keeper_name ~turn_ref ~source:"direct_assistant" session
    (Agent_core.Types.make_message
       ~role:Agent_core.Types.Assistant
       [ Agent_core.Types.Text assistant ]);
  List.iter
    (fun tool_name ->
       History.persist_tool_observation ~keeper_name ~turn_ref session ~tool_name
         ~outcome:Tool_result.Ok)
    tools
;;

let read_official config =
  match
    Official.read ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name
  with
  | Ok cursor -> cursor
  | Error error -> fail (Official.read_error_to_string error)
;;

(* Official boundaries never require reopening an unchanged atom checkpoint.
   A broken checkpoint is a positive control: the next atom boundary must
   still expose its error rather than silently hiding unread atom work. *)
let test_official_turns_skip_unchanged_atom_checkpoint ~with_atoms () =
  let exercise config trace_id current session_dir path =
    damage_checkpoint Corrupt_checkpoint ~session_dir ~trace_id path;
    let before = read_progress config in
    let commits = ref 0 in
    List.iter (fun turn ->
      let user = Printf.sprintf "official-q%d" turn in
      let assistant = Printf.sprintf "official-a%d" turn in
      write_official_turn config ~trace_id ~turn ~user ~assistant ~tools:[];
      append_official_boundary config ~trace_id ~turn ~recorded_at:(Float.of_int turn);
      (match consume config (fun ~expected_revision:_ ~range_id ~official_range_id input ->
          incr commits;
          check bool "no atom receipt" true (Option.is_none range_id);
          check bool "official receipt retained" true (Option.is_some official_range_id);
          check (list string) "only the new official turn" [user; assistant]
            (text_markers input);
          true) with
       | Consumer.Official_advanced { atom = None; _ } -> ()
       | _ -> fail "official turn did not advance independently of the checkpoint");
      check bool "atom position is unchanged" true (read_progress config = before);
      (match consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
          fail "quiet wake repeated an official commit") with
       | Consumer.Nothing_to_read -> ()
       | _ -> fail "quiet wake changed progress")) [3; 4; 5];
    check int "each official turn is committed once" 3 !commits;
    append_boundary config ~trace_id ~turn:6 ~recorded_at:6.
      (current @ [message "new atom turn"]);
    match Consumer.consume_one ~config ~keeper_name
        ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
          fail "corrupt atom checkpoint reached commit") with
    | Error (Consumer.Checkpoint_unreadable (Store.Parse_error _)) -> ()
    | Error error -> fail (Consumer.error_to_string error)
    | Ok _ -> fail "new atom boundary did not reopen checkpoint"
  in
  if with_atoms then with_consumed_shorter_history exercise
  else with_workspace (fun config ->
    let trace_id = "official-with-unused-checkpoint" in
    write_meta config trace_id;
    save_checkpoint config ~trace_id [] 0;
    let session_dir = Masc.Keeper_fs.keeper_session_dir config trace_id in
    let path = Store.agent_core_checkpoint_path ~session_dir ~session_id:trace_id in
    exercise config trace_id [] session_dir path)
;;

(* A keeper that only ever ran on official-client runtimes: no checkpoint, no
   atom position. Its turns are read from their fragments, in order, and the
   official position moves to the last line read. *)
let test_an_official_only_keeper_is_read_from_its_fragments () =
  with_workspace
  @@ fun config ->
  let trace_id = "trace-official-only" in
  write_meta config trace_id;
  write_official_turn config ~trace_id ~turn:1 ~user:"q1" ~assistant:"a1" ~tools:[ "masc_tasks" ];
  append_official_boundary config ~trace_id ~turn:1 ~recorded_at:1.0;
  write_official_turn config ~trace_id ~turn:2 ~user:"q2" ~assistant:"a2" ~tools:[];
  append_official_boundary config ~trace_id ~turn:2 ~recorded_at:2.0;
  let carried = ref [] in
  let tools = ref [] in
  let commits = ref 0 in
  (match
     consume config (fun ~expected_revision:_ ~range_id ~official_range_id input ->
       incr commits;
       check bool "official receipt is carried" true (Option.is_some official_range_id);
       carried := text_markers input;
       tools :=
         List.map
           (fun (o : Masc.Keeper_librarian.tool_observation) -> o.tool_name)
           input.tool_observations;
       check bool "an official-only pass carries no atom receipt" true (Option.is_none range_id);
       true)
   with
   | Consumer.Official_advanced { atom = None; official } ->
     check int "the official position is the last line read" 2 official.boundary_line
   | Consumer.Official_advanced { atom = Some _; _ } -> fail "an atom position appeared from nowhere"
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Progress_advanced _
   | Consumer.Memory_not_committed -> fail "official turns were not read");
  check (list string) "both turns, each in its order" [ "q1"; "a1"; "q2"; "a2" ] !carried;
  check (list string) "the tool the first turn called" [ "masc_tasks" ] !tools;
  check int "one Memory commit" 1 !commits;
  (match read_official config with
   | Some { Official.boundary_line = 2 } -> ()
   | Some { Official.boundary_line } -> failf "official position at line %d" boundary_line
   | None -> fail "no official position was written");
  match consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> fail "a second pass read again") with
  | Consumer.Nothing_to_read -> ()
  | Consumer.Official_advanced _
  | Consumer.Baseline_advanced _
  | Consumer.Progress_advanced _
  | Consumer.Memory_not_committed -> fail "read turns were read again"
;;

(* RFC §10-3's counterexample: T1 Agent-Core, T2 official-client, T3
   Agent-Core. One pass hands the Librarian T2 then T3, by the order of
   their end lines, and moves both positions. *)
let test_a_mixed_keeper_is_read_in_line_order () =
  with_workspace
  @@ fun config ->
  let trace_id = "trace-mixed" in
  establish_progress config ~trace_id "t1";
  write_official_turn config ~trace_id ~turn:2 ~user:"q2" ~assistant:"a2" ~tools:[];
  append_official_boundary config ~trace_id ~turn:2 ~recorded_at:2.0;
  let messages = [ message "t1"; message "t3" ] in
  append_boundary config ~trace_id ~turn:3 ~recorded_at:3.0 messages;
  save_checkpoint config ~trace_id messages 3;
  let carried = ref [] in
  (match
     consume config (fun ~expected_revision:_ ~range_id ~official_range_id input ->
       carried := text_markers input;
       check bool "the atoms of the pass carry a receipt" true (Option.is_some range_id);
       check bool "the official turns carry a receipt" true (Option.is_some official_range_id);
       true)
   with
   | Consumer.Official_advanced { atom = Some atom; official } ->
     check int "the atom position reaches T3" 2 atom.position.end_atom;
     check int "the official position reaches T2's line" 2 official.boundary_line
   | Consumer.Official_advanced { atom = None; _ } -> fail "T3's atoms were not read"
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Progress_advanced _
   | Consumer.Memory_not_committed -> fail "the mixed pass did not advance");
  check (list string) "T2 before T3, T1 not again" [ "q2"; "a2"; "t3" ] !carried
;;

(* Lines whose fragments predate turn-named history are passed without a
   model call; the position still moves so they are not asked for again. *)
let test_official_commit_recovers_without_resynthesis ?(through_queue = false) ~mixed ~cancel_after_save () =
  Masc_test_deps.with_process_env Env_config.KeeperMemoryOs.librarian_env_key (Some "true") @@ fun () ->
  with_workspace @@ fun config ->
  let module Current = Masc.Keeper_memory_os_current in
  let trace_id = "trace-official-commit-recovery" in
  if mixed then establish_progress config ~trace_id "t1"
  else write_meta config trace_id;
  write_official_turn config ~trace_id ~turn:2 ~user:"q2" ~assistant:"a2" ~tools:[];
  append_official_boundary config ~trace_id ~turn:2 ~recorded_at:2.0;
  write_official_turn config ~trace_id ~turn:3 ~user:"q3" ~assistant:"a3" ~tools:[];
  append_official_boundary config ~trace_id ~turn:3 ~recorded_at:3.0;
  if mixed then (
    let messages = [ message "t1"; message "t4" ] in
    append_boundary config ~trace_id ~turn:4 ~recorded_at:4.0 messages;
    save_checkpoint config ~trace_id messages 4);
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path in
  let commits = ref 0 in
  let commit ~expected_revision:_ ~range_id ~official_range_id input =
    incr commits;
    check bool "official commit has a durable identity" true (Option.is_some official_range_id);
    (match Current.apply_disposition ?durable_range_id:range_id ?official_range_id
      ~absorbed:[] ~keepers_dir ~keeper_id:keeper_name ~now:4.
      ~source:{ kind = Current.Librarian; trace_id = Ids.Turn_ref.trace_id input.Masc.Keeper_librarian.turn_ref }
      ~new_claims:[] () with
     | Ok _ -> ()
     | Error detail -> fail detail);
    if cancel_after_save then raise (Eio.Cancel.Cancelled Exit);
    true
  in
  let fail_official ~keepers_dir:_ ~keeper_id:_ _ =
    Error (Official.Write_failed { path = "injected-official-progress"; message = "write failed after Memory commit" })
  in
  (match Consumer.For_testing.consume_one_with_progress_writer
      ~write_progress_store:Progress.write ~write_official_progress_store:fail_official
      ~config ~keeper_name ~commit with
   | Error (Consumer.Official_progress_write_failed _) when not cancel_after_save -> ()
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "expected interruption between Memory and official progress"
   | exception Eio.Cancel.Cancelled _ when cancel_after_save -> ());
  check int "one Memory commit before interruption" 1 !commits;
  check bool "official cursor was not saved" true (Option.is_none (read_official config));
  (* Recover both with the process-local narrow-retry marker and after restart.
     Neither may submit the already-saved official turns again. *)
  if cancel_after_save then Consumer.For_testing.reset_process_state ();
  let no_commit ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ =
    fail "saved input was sent for synthesis again"
  in
  if through_queue then (
    Queue_refresh.For_testing.run_durable_with_commit ~config ~keeper_name ~commit:no_commit;
    (match read_official config with
     | Some official -> check int "queue restores official cursor" (if mixed then 3 else 2) official.boundary_line
     | None -> fail "queue left official cursor behind");
    if mixed then check_progress_end config 2)
  else (
  (match consume config no_commit with
   | Consumer.Official_advanced { official; _ } ->
     check int "official range restored in full" (if mixed then 3 else 2) official.boundary_line
   | _ -> fail "official commit receipt was not recovered");
  if mixed && cancel_after_save then (
    match consume config no_commit with
    | Consumer.Progress_advanced progress -> check int "atom cursor restored separately" 2 progress.position.end_atom
    | _ -> fail "mixed atom receipt was lost"));
  (match consume config no_commit with
   | Consumer.Nothing_to_read -> ()
   | _ -> fail "receipt recovery left input to read again");
  (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name with
   | Ok (Some snapshot) -> check int "recovery did not rewrite Memory" 1 snapshot.revision
   | Ok None -> fail "committed Memory disappeared"
   | Error detail -> fail detail)
;;

let test_official_receipt_rejects_replaced_history () =
  with_workspace @@ fun config ->
  let module Current = Masc.Keeper_memory_os_current in
  let trace_id = "new-official-history" in
  write_meta config trace_id;
  write_official_turn config ~trace_id ~turn:1 ~user:"new question" ~assistant:"new answer" ~tools:[];
  append_official_boundary config ~trace_id ~turn:1 ~recorded_at:1.;
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path in
  let official_range_id : Current.official_range_id =
    { receipt_scope = Workspace.keepers_runtime_dir config
    ; after_boundary_line = 0
    ; turns = [ 1, Ids.Turn_ref.make ~trace_id:"old-official-history" ~absolute_turn:1 ]
    }
  in
  (match Current.apply_disposition ~official_range_id ~absorbed:[] ~keepers_dir
    ~keeper_id:keeper_name ~now:1. ~source:{ kind = Current.Librarian; trace_id }
    ~new_claims:[] () with
   | Ok _ -> ()
   | Error detail -> fail detail);
  (match Consumer.consume_one ~config ~keeper_name
    ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> fail "mismatched receipt admitted synthesis") with
   | Error Consumer.Committed_official_range_mismatch -> ()
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "old receipt advanced over replacement content");
  check bool "replacement content is not marked read" true (Option.is_none (read_official config))
;;

let test_untagged_fragments_are_passed_without_a_commit () =
  with_workspace
  @@ fun config ->
  let trace_id = "trace-untagged" in
  write_meta config trace_id;
  let path =
    Masc.Keeper_turn_fragments.path
      ~session_dir:(Masc.Keeper_fs.keeper_session_dir config trace_id)
      Masc.Keeper_turn_fragments.Main
  in
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc ->
    Out_channel.output_string oc
      {|{"ts_unix":1.0,"role":"user","content_blocks":[{"type":"text","text":"old"}]}
|});
  append_official_boundary config ~trace_id ~turn:1 ~recorded_at:1.0;
  match consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> fail "nothing to commit") with
  | Consumer.Official_advanced { atom = None; official } ->
    check int "the position passes the line" 1 official.boundary_line
  | Consumer.Official_advanced { atom = Some _; _ }
  | Consumer.Nothing_to_read
  | Consumer.Baseline_advanced _
  | Consumer.Progress_advanced _
  | Consumer.Memory_not_committed -> fail "the untagged line was not passed"
;;

(* A history line the decoder refuses, after the first named one, stops the
   pass with a typed error naming the line; nothing is skipped. *)
let test_a_refused_fragment_line_stops_the_pass () =
  with_workspace
  @@ fun config ->
  let trace_id = "trace-refused-fragment" in
  write_meta config trace_id;
  write_official_turn config ~trace_id ~turn:1 ~user:"q1" ~assistant:"a1" ~tools:[];
  let path =
    Masc.Keeper_turn_fragments.path
      ~session_dir:(Masc.Keeper_fs.keeper_session_dir config trace_id)
      Masc.Keeper_turn_fragments.Main
  in
  Out_channel.with_open_gen [ Open_wronly; Open_append ] 0o600 path (fun oc ->
    Out_channel.output_string oc "not json\n");
  append_official_boundary config ~trace_id ~turn:1 ~recorded_at:1.0;
  (match
     Consumer.consume_one ~config ~keeper_name ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
       fail "a refused line reached the model")
   with
   | Error (Consumer.Fragment_line_unreadable { line = 3; file = Masc.Keeper_turn_fragments.Main; _ }) -> ()
   | Error error -> fail (Consumer.error_to_string error)
   | Ok _ -> fail "the pass read past a refused line");
  check bool "no official position was written" true (Option.is_none (read_official config))
;;

(* An official line older than the atom baseline: the baseline pass passes
   over it, the next pass reads it, and the atom position set after it does
   not turn the counterpart interval backwards. *)
let test_an_official_line_older_than_the_baseline_is_read () =
  with_workspace
  @@ fun config ->
  let trace_id = "trace-official-before-baseline" in
  write_meta config trace_id;
  write_official_turn config ~trace_id ~turn:1 ~user:"q1" ~assistant:"a1" ~tools:[];
  append_official_boundary config ~trace_id ~turn:1 ~recorded_at:1.0;
  save_checkpoint config ~trace_id [ message "t2" ] 2;
  append_boundary config ~trace_id ~turn:2 ~recorded_at:2.0 [ message "t2" ];
  (match consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ -> fail "a baseline commits nothing") with
   | Consumer.Baseline_advanced progress -> check int "the atom baseline" 1 progress.position.end_atom
   | Consumer.Nothing_to_read
   | Consumer.Progress_advanced _
   | Consumer.Official_advanced _
   | Consumer.Memory_not_committed -> fail "the first pass did not set the baseline");
  let carried = ref [] in
  match
    consume config (fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ input ->
      carried := text_markers input;
      true)
  with
  | Consumer.Official_advanced { atom = None; official } ->
    check int "the official position reaches the older line" 1 official.boundary_line;
    check (list string) "the older official turn is read" [ "q1"; "a1" ] !carried
  | Consumer.Official_advanced { atom = Some _; _ }
  | Consumer.Nothing_to_read
  | Consumer.Baseline_advanced _
  | Consumer.Progress_advanced _
  | Consumer.Memory_not_committed -> fail "the older official line was not read"
;;

(* A refused boundary line beyond the official position stops the pass and
   keeps stopping it: the line may be an official turn's end line, whose
   words are still on disk, so no later restart lifts it the way one lifts
   the atom stop (row 2c'). The keeper waits for a purge; the lag shows. *)
let test_a_refused_boundary_line_is_not_lifted_for_official_turns () =
  with_workspace
  @@ fun config ->
  let trace_id = "trace-refused-then-restart" in
  establish_progress config ~trace_id "t1";
  let path =
    Boundaries.path_for_keepers_dir
      ~keepers_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_id:keeper_name
  in
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_binary ] 0o600 path (fun oc ->
    Out_channel.output_string oc "{\n");
  (match
     Boundaries.append
       ~keepers_dir:(Workspace.keepers_runtime_dir config)
       ~keeper_id:keeper_name
       { Boundaries.recorded_at = 3.0; event = Boundaries.History_restarted { trace_id } }
   with
   | Ok () -> ()
   | Error error -> fail (Boundaries.append_error_to_string error));
  save_checkpoint config ~trace_id [ message "fresh" ] 3;
  append_boundary ~history_at_start:Boundaries.Fresh_history config ~trace_id ~turn:3
    ~recorded_at:4.0 [ message "fresh" ];
  match
    Consumer.consume_one ~config ~keeper_name ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
      fail "a pass read past a refused boundary line")
  with
  | Error (Consumer.Official_range_stopped { line = 2; error = Boundaries.Not_json _ }) -> ()
  | Error error -> fail (Consumer.error_to_string error)
  | Ok _ -> fail "the restart lifted the official stop"
;;

let () =
  run
    "Keeper Librarian durable consumer"
    [ ( "range lifecycle"
      , [ test_case "N ticks retain intermediate turns" `Quick
            test_n_tick_reads_every_intermediate_turn
        ; test_case "Agent-Core handoff retains pending official evidence" `Quick
            test_agent_core_handoff_retains_pending_official_evidence
        ; test_case "unread turns counts what a pass has left" `Quick
            test_unread_turns_counts_what_a_pass_has_left
        ; test_case "failed commit and restart retry exact range" `Quick
            test_failed_commit_and_restart_retry_the_same_range
        ; test_case "committed range repairs failed progress after restart" `Quick
            test_committed_range_recovers_after_progress_write_failure
        ; test_case "committed wide range repairs before retry narrowing" `Quick
            test_committed_wide_range_recovers_before_retry_narrowing
        ; test_case "receipt does not cross a restarted repeated endpoint" `Quick
            test_receipt_does_not_cross_restarted_history_with_repeated_endpoint
        ; test_case "historical range does not borrow current task" `Quick
            test_historical_range_does_not_borrow_the_current_task
        ; test_case "unchanged boundaries skip checkpoint" `Quick
            test_unchanged_boundaries_do_not_require_checkpoint
        ; test_case "caught-up prior trace transitions to current trace" `Quick
            test_caught_up_prior_trace_transitions_to_current_trace
        ; test_case "absent prior checkpoint transitions to current trace" `Quick
            test_absent_prior_checkpoint_transitions_to_current_trace
        ; test_case "absent prior checkpoint requires current history start" `Quick
            test_absent_prior_checkpoint_requires_current_history_start
        ; test_case "unread prior trace finishes before current trace" `Quick
            test_unread_prior_trace_finishes_before_current_trace
        ; test_case "failed growing range retries oldest cut" `Quick
            test_failed_long_range_retries_only_oldest_cut_point
        ; test_case "last boundary wins when wall clock goes backward" `Quick
            test_last_matching_boundary_wins_when_clock_moves_backward
        ; test_case "distinct backward clocks do not erase counterpart evidence" `Quick
            test_distinct_boundaries_reject_non_monotone_counterpart_interval
        ; test_case "equal boundary clocks make an empty interval" `Quick
            test_equal_boundary_timestamps_form_an_empty_counterpart_interval
        ; test_case "unknown speaker authority keeps durable progress" `Quick
            test_unknown_speaker_authority_does_not_advance_progress
        ; test_case "missing speaker authority keeps durable progress" `Quick
            test_missing_speaker_authority_does_not_advance_progress
        ; test_case "torn external tail retries the same range once" `Quick
            test_torn_external_tail_retries_the_same_range_once
        ; test_case "torn chat tail retries the same range once" `Quick
            test_torn_chat_tail_retries_the_same_range_once
        ; test_case "same-name clusters isolate range progress" `Quick
            test_same_name_clusters_keep_independent_ranges
        ; test_case "same-name clusters isolate commit receipts" `Quick
            test_same_name_clusters_keep_independent_commit_receipts
        ; test_case "selected range bypasses recent window" `Quick
            test_selected_range_bypasses_recent_window
        ; test_case "counterpart range exceeds recent windows" `Quick
            test_counterpart_range_reads_beyond_recent_windows
        ; test_case "counterpart range includes upper boundary once" `Quick
            test_counterpart_range_includes_upper_boundary_once
        ; test_case "external/chat pair across boundary is emitted once" `Quick
            test_external_chat_pair_straddling_a_boundary_is_not_duplicated
        ; test_case "restart cut excludes current unfinished turn" `Quick
            test_restart_cut_never_commits_a_current_unfinished_turn
        ; test_case "seen restart skips absent checkpoint" `Quick
            (test_seen_restart_skips_checkpoint Missing_checkpoint)
        ; test_case "seen restart skips corrupt checkpoint" `Quick
            (test_seen_restart_skips_checkpoint Corrupt_checkpoint)
        ; test_case "new completed cut reads checkpoint" `Quick
            test_new_completed_cut_still_reads_checkpoint
        ; test_case "unseen restart reads checkpoint" `Quick
            test_unseen_restart_still_reads_checkpoint
        ; test_case "trace change without witness keeps prior progress" `Quick
            test_trace_change_without_history_witness_keeps_prior_progress
        ; test_case "new unreadable boundary remains visible" `Quick
            test_new_unreadable_boundary_is_not_hidden_by_preflight
        ] )
    ; ( "official-client turns"
      , [ test_case "official turns skip an unchanged atom checkpoint" `Quick
            (test_official_turns_skip_unchanged_atom_checkpoint ~with_atoms:true)
        ; test_case "official-only turns skip an unused checkpoint" `Quick
            (test_official_turns_skip_unchanged_atom_checkpoint ~with_atoms:false)
        ; test_case "an official-only keeper is read from its fragments" `Quick
            test_an_official_only_keeper_is_read_from_its_fragments
        ; test_case "a mixed keeper is read in line order" `Quick
            test_a_mixed_keeper_is_read_in_line_order
        ; test_case "official receipt recovers failed cursor write" `Quick
            (test_official_commit_recovers_without_resynthesis ~mixed:false ~cancel_after_save:false)
        ; test_case "mixed receipt recovers partial cursor write" `Quick
            (test_official_commit_recovers_without_resynthesis ~mixed:true ~cancel_after_save:false)
        ; test_case "official receipt recovers cancellation after save" `Quick
            (test_official_commit_recovers_without_resynthesis ~mixed:false ~cancel_after_save:true)
        ; test_case "mixed receipt restores both cursors after cancellation" `Quick
            (test_official_commit_recovers_without_resynthesis ~mixed:true ~cancel_after_save:true)
        ; test_case "Memory lane drain recovers mixed cancellation without synthesis" `Quick
            (test_official_commit_recovers_without_resynthesis ~through_queue:true ~mixed:true ~cancel_after_save:true)
        ; test_case "Memory lane drain recovers partial cursor writes without synthesis" `Quick
            (test_official_commit_recovers_without_resynthesis ~through_queue:true ~mixed:true ~cancel_after_save:false)
        ; test_case "official receipt cannot skip replaced history" `Quick
            test_official_receipt_rejects_replaced_history
        ; test_case "untagged fragments are passed without a commit" `Quick
            test_untagged_fragments_are_passed_without_a_commit
        ; test_case "a refused fragment line stops the pass" `Quick
            test_a_refused_fragment_line_stops_the_pass
        ; test_case "an official line older than the baseline is read" `Quick
            test_an_official_line_older_than_the_baseline_is_read
        ; test_case "a refused boundary line is not lifted for official turns" `Quick
            test_a_refused_boundary_line_is_not_lifted_for_official_turns
        ] )
    ; ( "production wake"
      , [ test_case "failure stops and a later wake drains successful cuts" `Quick
            test_one_wake_stops_on_failure_then_drains_successful_cuts
        ; test_case "one wake continues after an initial baseline" `Quick
            test_one_wake_continues_after_an_initial_baseline
        ; test_case "disable between cuts waits for a new enabled wake" `Quick
            test_disabling_between_cuts_stops_until_a_new_enabled_wake
        ] )
    ]
;;
