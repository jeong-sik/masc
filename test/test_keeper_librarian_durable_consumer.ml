open Alcotest

module Workspace = Masc.Workspace
module Consumer = Masc.Keeper_librarian_durable_consumer
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

let test_unchanged_boundaries_do_not_require_checkpoint () =
  with_workspace @@ fun config ->
  let trace_id = "trace-no-new-boundary" in
  establish_progress config ~trace_id "before";
  let session_dir = Masc.Keeper_fs.keeper_session_dir config trace_id in
  Sys.remove (Store.agent_core_checkpoint_path ~session_dir ~session_id:trace_id);
  match consume config (fun ~expected_revision:_ _ -> fail "commit was called") with
  | Consumer.Nothing_to_read -> ()
  | Consumer.Baseline_advanced _
  | Consumer.Memory_not_committed
  | Consumer.Progress_advanced _ -> fail "unchanged boundaries did not stop before checkpoint"
;;

let test_trace_change_is_not_hidden_by_preflight () =
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
  match
    Consumer.consume_one
      ~config
      ~keeper_name
      ~commit:(fun ~expected_revision:_ _ -> fail "trace mismatch called commit")
  with
  | Error (Consumer.Position_in_other_trace position) ->
    check string "prior trace remains visible" trace_a position.trace_id
  | Error error -> fail (Consumer.error_to_string error)
  | Ok _ -> fail "trace change was hidden as no unread range"
;;

let test_failed_long_range_retries_only_oldest_cut_point () =
  with_workspace @@ fun config ->
  let trace_id = "trace-bounded-retry" in
  establish_progress config ~trace_id "turn-1";
  let first_two = [ message "turn-1"; message "turn-2" ] in
  append_boundary config ~trace_id ~turn:2 ~recorded_at:2.0 first_two;
  save_checkpoint config ~trace_id first_two 2;
  (match consume config (fun ~expected_revision:_ _ -> false) with
   | Consumer.Memory_not_committed -> ()
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Progress_advanced _ -> fail "failed range unexpectedly advanced");
  let first_four = first_two @ [ message "turn-3"; message "turn-4" ] in
  append_boundary config ~trace_id ~turn:3 ~recorded_at:3.0
    (first_two @ [ message "turn-3" ]);
  append_boundary config ~trace_id ~turn:4 ~recorded_at:4.0 first_four;
  save_checkpoint config ~trace_id first_four 4;
  let retry = ref [] in
  (match
     consume config (fun ~expected_revision:_ input ->
       retry := text_markers input;
       true)
   with
   | Consumer.Progress_advanced progress ->
     check int "bounded retry reaches oldest cut" 2 progress.position.end_atom
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Memory_not_committed -> fail "bounded retry did not advance");
  check (list string) "retry does not grow with later turns" [ "turn-2" ] !retry;
  let remaining = ref [] in
  (match
     consume config (fun ~expected_revision:_ input ->
       remaining := text_markers input;
       true)
   with
   | Consumer.Progress_advanced progress ->
     check int "success clears bounded retry" 4 progress.position.end_atom
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
   | Consumer.Memory_not_committed -> fail "remaining range did not advance");
  check (list string) "later turns remain readable" [ "turn-3"; "turn-4" ] !remaining
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
     consume config (fun ~expected_revision:_ input ->
       selected_turn := Some (Ids.Turn_ref.absolute_turn input.turn_ref);
       true)
   with
   | Consumer.Progress_advanced _ -> ()
   | Consumer.Nothing_to_read
   | Consumer.Baseline_advanced _
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
  (match consume config (fun ~expected_revision:_ _ -> true) with
   | Consumer.Baseline_advanced _ | Consumer.Progress_advanced _ -> ()
   | Consumer.Nothing_to_read
   | Consumer.Memory_not_committed -> fail "fixture progress did not advance");
  let messages = first @ [ message "turn-2" ] in
  append_boundary config ~trace_id ~turn:2 ~recorded_at:10.0 messages;
  save_checkpoint config ~trace_id messages 2;
  let commit_called = ref false in
  (match
     Consumer.consume_one ~config ~keeper_name
       ~commit:(fun ~expected_revision:_ _ ->
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

let () =
  run
    "Keeper Librarian durable consumer"
    [ ( "range lifecycle"
      , [ test_case "N ticks retain intermediate turns" `Quick
            test_n_tick_reads_every_intermediate_turn
        ; test_case "failed commit and restart retry exact range" `Quick
            test_failed_commit_and_restart_retry_the_same_range
        ; test_case "unchanged boundaries skip checkpoint" `Quick
            test_unchanged_boundaries_do_not_require_checkpoint
        ; test_case "trace change is not hidden by preflight" `Quick
            test_trace_change_is_not_hidden_by_preflight
        ; test_case "failed growing range retries oldest cut" `Quick
            test_failed_long_range_retries_only_oldest_cut_point
        ; test_case "last boundary wins when wall clock goes backward" `Quick
            test_last_matching_boundary_wins_when_clock_moves_backward
        ; test_case "distinct backward clocks do not erase counterpart evidence" `Quick
            test_distinct_boundaries_reject_non_monotone_counterpart_interval
        ; test_case "same-name clusters isolate range progress" `Quick
            test_same_name_clusters_keep_independent_ranges
        ; test_case "selected range bypasses recent window" `Quick
            test_selected_range_bypasses_recent_window
        ; test_case "counterpart range exceeds recent windows" `Quick
            test_counterpart_range_reads_beyond_recent_windows
        ] )
    ]
;;
