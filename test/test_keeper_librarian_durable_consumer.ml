open Alcotest

module Workspace = Masc.Workspace
module Consumer = Masc.Keeper_librarian_durable_consumer
module Boundaries = Masc.Keeper_turn_boundaries
module Progress = Masc.Keeper_librarian_progress
module Store = Masc.Keeper_checkpoint_store

let keeper_name = "durable-reader"

let config_in_cluster config cluster_name =
  { config with
    Workspace.backend_config = { config.Workspace.backend_config with cluster_name }
  }
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
       f config)
;;

let meta trace_id =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String keeper_name; "trace_id", `String trace_id ])
  with
  | Ok meta -> meta
  | Error detail -> failf "fixture metadata: %s" detail
;;

let write_meta config trace_id =
  match Masc.Keeper_meta_store.replace_snapshot config (meta trace_id) with
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

let append_boundary config ~trace_id ~turn ~recorded_at messages =
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
              (if turn = 1
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
  match consume config (fun ~expected_revision:_ _ -> true) with
  | Consumer.Baseline_advanced progress | Consumer.Progress_advanced progress ->
    check int "initial end" 1 progress.position.end_atom
  | Consumer.Nothing_to_read
  | Consumer.Memory_not_committed -> fail "initial range did not advance"
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
     consume config (fun ~expected_revision:_ input ->
       carried := text_markers input;
       true)
   with
   | Consumer.Progress_advanced progress ->
     check int "all three turns reached" 3 progress.position.end_atom
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Memory_not_committed -> fail "unread range did not commit");
  check (list string) "both unread turns are delivered" [ "turn-2"; "turn-3" ] !carried
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
     consume config (fun ~expected_revision:_ input ->
       first := text_markers input;
       false)
   with
   | Consumer.Memory_not_committed -> ()
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Progress_advanced _ -> fail "failed commit advanced the pass");
  let after_failure = read_progress config in
  (match after_failure with
   | Some progress -> check int "failed commit keeps progress" 1 progress.position.end_atom
   | None -> fail "failed commit removed existing progress");
  let after_restart = ref [] in
  (match
     consume config (fun ~expected_revision:_ input ->
       after_restart := text_markers input;
       true)
   with
   | Consumer.Progress_advanced progress ->
     check int "restart reaches retried turn" 2 progress.position.end_atom
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Memory_not_committed -> fail "restart did not retry unread range");
  check (list string) "restart reads identical range" !first !after_restart
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
       consume config (fun ~expected_revision:_ input ->
         carried := text_markers input;
         true)
     with
     | Consumer.Progress_advanced _ -> ()
     | Consumer.Nothing_to_read
     | Consumer.Baseline_advanced _
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

let () =
  run
    "Keeper Librarian durable consumer"
    [ ( "range lifecycle"
      , [ test_case "N ticks retain intermediate turns" `Quick
            test_n_tick_reads_every_intermediate_turn
        ; test_case "failed commit and restart retry exact range" `Quick
            test_failed_commit_and_restart_retry_the_same_range
        ; test_case "same-name clusters isolate range progress" `Quick
            test_same_name_clusters_keep_independent_ranges
        ; test_case "selected range bypasses recent window" `Quick
            test_selected_range_bypasses_recent_window
        ] )
    ]
;;
