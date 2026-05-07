module Types = Masc_domain

open Alcotest

module WO = Masc_mcp.Keeper_world_observation
module UP = Masc_mcp.Keeper_unified_prompt
module UT = Masc_mcp.Keeper_unified_turn
module EC = Masc_mcp.Keeper_error_classify
module UM = Masc_mcp.Keeper_unified_metrics
module KR = Masc_mcp.Keeper_registry
module KAR = Masc_mcp.Keeper_agent_run
module KCC = Masc_mcp.Keeper_contract_classifier
module KTCL = Masc_mcp.Keeper_tool_call_log
module KTD = Masc_mcp.Keeper_tool_disclosure
module KEC = Masc_mcp.Keeper_exec_context
module KSM = Masc_mcp.Keeper_social_model
module KP = Masc_mcp.Keeper_state_machine
module KD = Masc_mcp.Keeper_deliberation
module AE = Masc_mcp.Agent_economy
module KC = Masc_mcp.Keeper_config
module HK = Masc_mcp.Keeper_hooks_oas
module KG = Masc_mcp.Keeper_guards
module OMR = Masc_mcp.Oas_model_resolve
module AQ = Masc_mcp.Keeper_approval_queue
module Keeper_types = Masc_mcp.Keeper_types

let oas_error_cascade_name = Masc_mcp.Oas_worker_named.cascade_name_of_string

let has_prompt_root path =
  Sys.file_exists (Filename.concat path "config/prompts/keeper.unified.system.md")

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_prompt_root root -> root
  | _ ->
      let rec ascend path =
        if has_prompt_root path then path
        else
          let parent = Filename.dirname path in
          if String.equal parent path then Sys.getcwd () else ascend parent
      in
      ascend (Sys.getcwd ())

let copy_file src dst =
  let ic = open_in_bin src in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let oc = open_out_bin dst in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc (In_channel.input_all ic)))

let unix_mkdir_p path =
  let rec loop dir =
    if dir = "" || dir = "." || Sys.file_exists dir then ()
    else (
      loop (Filename.dirname dir);
      Unix.mkdir dir 0o755)
  in
  loop path

let () =
  let base_path = repo_root () in
  let test_base_path =
    let path = Filename.temp_file "test_keeper_unified_runtime_" "" in
    Unix.unlink path;
    Unix.mkdir path 0o755;
    path
  in
  let test_config_dir =
    Filename.concat (Filename.concat test_base_path ".masc") "config"
  in
  unix_mkdir_p test_config_dir;
  copy_file
    (Filename.concat base_path "config/cascade.json")
    (Filename.concat test_config_dir "cascade.json");
  Unix.putenv "MASC_BASE_PATH" test_base_path;
  Unix.putenv "MASC_CONFIG_DIR" test_config_dir;
  Masc_mcp.Config_dir_resolver.reset ();
  let prompts_dir = Filename.concat base_path "config/prompts" in
  Prompt_registry.set_markdown_dir prompts_dir;
  ignore (Result.get_ok (Masc_mcp.Keeper_exec_tools.init_policy_config ~base_path));
  Masc_mcp.Prompt_defaults.init ()

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_unified_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let read_jsonl_line path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
    input_line ic |> Yojson.Safe.from_string)

let contains_substring haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    if i + needle_len > hay_len then false
    else if String.sub haystack i needle_len = needle then true
    else loop (i + 1)
  in
  needle_len = 0 || loop 0

let substring_index haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    if needle_len = 0 then Some 0
    else if i + needle_len > hay_len then None
    else if String.sub haystack i needle_len = needle then Some i
    else loop (i + 1)
  in
  loop 0

let source_file_contains file_rel needle =
  let path = Filename.concat (repo_root ()) file_rel in
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> contains_substring (In_channel.input_all ic) needle)

let contains_disallowed_control_char s =
  let rec loop i =
    if i >= String.length s then false
    else
      let code = Char.code s.[i] in
      if (code < 32 && s.[i] <> '\n' && s.[i] <> '\r' && s.[i] <> '\t') || code = 127
      then true
      else loop (i + 1)
  in
  loop 0

let tool_log_entry ?ts tool_name =
  let ts = Option.value ~default:(Time_compat.now ()) ts in
  `Assoc [ ("tool", `String tool_name); ("ts", `Float ts) ]

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect ~finally:(fun () ->
    match old with
    | Some v -> Unix.putenv name v
    | None -> (try Unix.putenv name "" with _ -> ()))
    f

let prepare_test_config_root base_dir =
  let config_dir =
    Filename.concat (Filename.concat base_dir ".masc") "config"
  in
  Keeper_types.mkdir_p config_dir;
  copy_file
    (Filename.concat (repo_root ()) "config/cascade.json")
    (Filename.concat config_dir "cascade.json");
  config_dir

let with_test_runtime_roots base_dir f =
  let config_dir = prepare_test_config_root base_dir in
  with_env "MASC_BASE_PATH" base_dir @@ fun () ->
  with_env "MASC_CONFIG_DIR" config_dir @@ fun () ->
  Masc_mcp.Config_dir_resolver.reset ();
  Fun.protect
    ~finally:(fun () -> Masc_mcp.Config_dir_resolver.reset ())
    f

(* ---------- World Observation type tests ---------- *)

let base_observation : WO.world_observation =
  {
    pending_mentions = [];
    pending_board_events = [];
    pending_scope_messages = [];
    message_cursor_updates = [];
    idle_seconds = 0;
    active_goals = [];
    continuity_summary = "";
    worktree_change_summary = None;
    context_ratio = 0.0;
    economic_pressure = AE.Normal;
    unclaimed_task_count = 0;
    claimable_task_count = 0;
    failed_task_count = 0;
    pending_verification_count = 0;
    backlog_updated_since_last_scheduled_autonomous = false;
    active_agent_count = 0;
    last_turn_budget = None;
    work_discovery_due = false;
  }

let sample_board_event : WO.pending_board_event =
  {
    post_id = "board-post-1";
    author = "alice";
    title = "Need help";
    preview = "Please take a look.";
    hearth = Some "research";
    post_kind = Masc_mcp.Board.Human_post;
    updated_at = 0.0;
    explicit_mention = false;
    matched_targets = [];
    self_commented = false;
    new_external_since = 0;
    latest_external_author = None;
    latest_external_preview = None;
  }

let test_observation_defaults () =
  let obs = base_observation in
  check int "idle_seconds default" 0 obs.idle_seconds;
  check (float 0.001) "context_ratio default" 0.0 obs.context_ratio;
  check int "unclaimed default" 0 obs.unclaimed_task_count;
  check int "claimable default" 0 obs.claimable_task_count;
  check int "failed default" 0 obs.failed_task_count;
  check int "active_agents default" 0 obs.active_agent_count;
  check bool "no mentions" true (obs.pending_mentions = []);
  check bool "no goals" true (obs.active_goals = [])

let test_observation_with_mentions () =
  let obs =
    { base_observation with
      pending_mentions = [("alice", "hey keeper"); ("bob", "need help")]
    }
  in
  check int "mention count" 2 (List.length obs.pending_mentions)

let test_observation_with_goals () =
  let obs =
    { base_observation with
      active_goals = ["goal-1"; "goal-2"; "goal-3"]
    }
  in
  check int "goal count" 3 (List.length obs.active_goals)

let test_observation_economic_modes () =
  let modes = [AE.Normal; AE.Frugal; AE.Hustle] in
  List.iter
    (fun mode ->
      let obs = { base_observation with economic_pressure = mode } in
      check bool "observation created" true (obs.idle_seconds >= 0))
    modes

(* ---------- Unified Prompt tests ---------- *)

let make_meta name : Masc_mcp.Keeper_types.keeper_meta =
  let json = `Assoc [
    ("name", `String name);
    ("trace_id", `String ("test-trace-" ^ name));
    ("goal", `String "test goal");
  ] in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)

let minimal_meta : Masc_mcp.Keeper_types.keeper_meta =
  make_meta "test-keeper"

let minimal_policy_meta =
  {
    minimal_meta with
    tool_access =
      Preset { preset = Minimal; also_allow = [] };
  }

let room_signal_meta =
  { minimal_meta with room_signal_prompt_enabled = true }

let contract_requiring_tools required_tools : Masc_domain.task_contract =
  {
    strict = false;
    completion_contract = [];
    required_tools;
    required_evidence = [];
    inspect_gate_evidence = [];
    verify_gate_evidence = [];
    links =
      {
        operation_id = None;
        session_id = None;
        autoresearch_loop_id = None;
      };
  }

let test_observe_uses_precollected_board_events () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      Unix.putenv "MASC_BASE_PATH" base_dir;
      Masc_mcp.Board.reset_global_for_test ();
      Masc_mcp.Board_dispatch.reset_for_test ();
      Masc_mcp.Board_dispatch.init_jsonl ();
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      (match
         Masc_mcp.Board_dispatch.create_post ~author:"alice"
           ~title:"Need sangsu" ~content:"@test-keeper please check this"
           ~post_kind:Masc_mcp.Board.Human_post ()
       with
      | Ok _ -> ()
      | Error e -> fail ("create_post failed: " ^ Masc_mcp.Board.show_board_error e));
      let events, _, _ =
        WO.collect_board_events ~base_path:base_dir
          ~continuity_summary:"goal test-keeper"
          ~meta:minimal_meta
      in
      let obs =
        WO.observe ~allowed_tool_names:None
          ~pending_board_events:(Some events)
          ~config ~meta:minimal_meta
      in
      check int "precollected board events preserved" (List.length events)
        (List.length obs.pending_board_events);
      check bool "board event schedules turn" true
        (WO.should_run_keeper_cycle ~meta:minimal_meta obs))

let test_board_signal_stimulus_becomes_pending_board_event () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Unix.putenv "MASC_BASE_PATH" base_dir;
      Masc_mcp.Board.reset_global_for_test ();
      Masc_mcp.Board_dispatch.reset_for_test ();
      Masc_mcp.Board_dispatch.init_jsonl ();
      let post =
        match
          Masc_mcp.Board_dispatch.create_post ~author:"alice"
            ~title:"Need test-keeper"
            ~content:"@test-keeper please react from the queued stimulus"
            ~post_kind:Masc_mcp.Board.Human_post ()
        with
        | Ok post -> post
        | Error e -> fail ("create_post failed: " ^ Masc_mcp.Board.show_board_error e)
      in
      let post_id = Masc_mcp.Board.Post_id.to_string post.id in
      let payload =
        `Assoc
          [
            ("source", `String "board_signal");
            ("kind", `String "post_created");
            ("post_id", `String post_id);
            ("author", `String "alice");
            ("title", `String "Need test-keeper");
            ( "content",
              `String "@test-keeper please react from the queued stimulus" );
            ("hearth", `Null);
            ("wake_reason", `String "explicit_mention");
          ]
        |> Yojson.Safe.to_string
      in
      let stimulus : Masc_mcp.Keeper_event_queue.stimulus =
        {
          post_id;
          urgency = Masc_mcp.Keeper_event_queue.Immediate;
          arrived_at = Time_compat.now ();
          payload;
        }
      in
      match
        WO.pending_board_event_of_stimulus
          ~continuity_summary:"goal test-keeper"
          ~meta:minimal_meta stimulus
      with
      | None -> fail "queued board stimulus was not converted"
      | Some event ->
          check string "post id" post_id event.post_id;
          check string "author" "alice" event.author;
          check string "title from board snapshot" "Need test-keeper" event.title;
          check bool "explicit mention" true event.explicit_mention;
          check (list string) "matched target" [ "test-keeper" ]
            event.matched_targets;
          check bool "schedules turn" true
            (WO.should_run_keeper_cycle ~meta:minimal_meta
               { base_observation with pending_board_events = [ event ] }))

let test_legacy_board_comment_stimulus_becomes_pending_board_event () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Unix.putenv "MASC_BASE_PATH" base_dir;
      Masc_mcp.Board.reset_global_for_test ();
      Masc_mcp.Board_dispatch.reset_for_test ();
      Masc_mcp.Board_dispatch.init_jsonl ();
      let post =
        match
          Masc_mcp.Board_dispatch.create_post ~author:"alice"
            ~title:"Need test-keeper"
            ~content:"@test-keeper please react from the queued stimulus"
            ~post_kind:Masc_mcp.Board.Human_post ()
        with
        | Ok post -> post
        | Error e -> fail ("create_post failed: " ^ Masc_mcp.Board.show_board_error e)
      in
      let post_id = Masc_mcp.Board.Post_id.to_string post.id in
      let payload =
        `Assoc
          [
            ("source", `String "board_signal");
            ("kind", `String "comment");
            ("post_id", `String post_id);
            ("author", `String "bob");
            ("title", `String "Need test-keeper");
            ("content", `String "comment payload from live board signal");
            ("hearth", `Null);
            ("wake_reason", `String "scope_message");
          ]
        |> Yojson.Safe.to_string
      in
      let stimulus : Masc_mcp.Keeper_event_queue.stimulus =
        {
          post_id;
          urgency = Masc_mcp.Keeper_event_queue.Normal;
          arrived_at = Time_compat.now ();
          payload;
        }
      in
      match
        WO.pending_board_event_of_stimulus
          ~continuity_summary:"goal test-keeper"
          ~meta:minimal_meta stimulus
      with
      | None -> fail "legacy board comment stimulus was not converted"
      | Some event ->
          check string "post id" post_id event.post_id;
          check string "latest external author" "bob"
            (Option.value ~default:"" event.latest_external_author);
          check int "new external comment" 1 event.new_external_since;
          check bool "schedules turn" true
            (WO.should_run_keeper_cycle ~meta:minimal_meta
               { base_observation with pending_board_events = [ event ] }))

let test_observe_splits_absolute_and_claimable_backlog () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      ignore
        (Masc_mcp.Coord.add_task config ~title:"Open task" ~priority:1
           ~description:"");
      ignore
        (Masc_mcp.Coord.add_task config ~title:"Bash task" ~priority:1
           ~description:""
           ~contract:(contract_requiring_tools [ "keeper_bash" ]));
      let obs =
        WO.observe ~allowed_tool_names:(Some [ "keeper_task_claim" ])
          ~pending_board_events:(Some []) ~config ~meta:minimal_meta
      in
      check int "absolute todo backlog" 2 obs.unclaimed_task_count;
      check int "matched claimable backlog" 1 obs.claimable_task_count)

let test_observe_claimable_backlog_respects_active_goal_ids () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      let goal, _ =
        match Masc_mcp.Goal_store.upsert_goal config ~title:"Scoped goal" () with
        | Ok payload -> payload
        | Error msg -> fail msg
      in
      let other_goal, _ =
        match Masc_mcp.Goal_store.upsert_goal config ~title:"Other goal" () with
        | Ok payload -> payload
        | Error msg -> fail msg
      in
      ignore
        (Masc_mcp.Coord.add_task ~goal_id:other_goal.id config
           ~title:"Out-of-scope task" ~priority:1 ~description:"desc");
      let meta = { minimal_meta with active_goal_ids = [ goal.id ] } in
      let obs =
        WO.observe ~allowed_tool_names:(Some [ "keeper_task_claim" ])
          ~pending_board_events:(Some []) ~config ~meta
      in
      check int "absolute todo backlog" 1 obs.unclaimed_task_count;
      check int "scoped claimable backlog" 0 obs.claimable_task_count;
      let signal =
        obs
        |> KCC.of_keeper_world_observation
        |> KCC.classify_actionable_signal_for_tools
             ~allowed_tool_names:[ "keeper_task_claim" ]
      in
      check bool "out-of-scope backlog is not actionable" false
        (KCC.is_actionable signal))

let test_observe_claimable_backlog_uses_auto_goal_fallback_scope () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      let auto_goal, _ =
        match
          Masc_mcp.Goal_store.upsert_goal config
            ~title:
              (Masc_mcp.Keeper_goal_repair.goal_title_of_purpose
                 minimal_meta.goal)
            ()
        with
        | Ok payload -> payload
        | Error msg -> fail msg
      in
      let product_goal, _ =
        match Masc_mcp.Goal_store.upsert_goal config ~title:"Product goal" () with
        | Ok payload -> payload
        | Error msg -> fail msg
      in
      ignore
        (Masc_mcp.Coord.add_task ~goal_id:product_goal.id config
           ~title:"Fallback task" ~priority:1 ~description:"desc");
      let meta = { minimal_meta with active_goal_ids = [ auto_goal.id ] } in
      let obs =
        WO.observe ~allowed_tool_names:(Some [ "keeper_task_claim" ])
          ~pending_board_events:(Some []) ~config ~meta
      in
      check int "absolute todo backlog" 1 obs.unclaimed_task_count;
      check int "auto-goal fallback claimable backlog" 1
        obs.claimable_task_count)

let test_durable_signal_present_sees_claimable_backlog_for_smart_hb_gate () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      ignore
        (Masc_mcp.Coord.add_task config ~title:"Open task" ~priority:1
           ~description:"");
      let meta = { minimal_meta with work_discovery_enabled = Some false } in
      let present =
        WO.durable_signal_present
          ~allowed_tool_names:(Some [ "keeper_task_claim" ])
          ~pending_board_events:(Some [])
          ~config ~meta
      in
      check bool "claimable backlog forces smart heartbeat emit" true present)

let test_durable_signal_present_filters_unclaimable_backlog_for_smart_hb_gate () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      ignore
        (Masc_mcp.Coord.add_task config ~title:"Bash task" ~priority:1
           ~description:""
           ~contract:(contract_requiring_tools [ "keeper_bash" ]));
      let meta = { minimal_meta with work_discovery_enabled = Some false } in
      let present =
        WO.durable_signal_present
          ~allowed_tool_names:(Some [ "keeper_task_claim" ])
          ~pending_board_events:(Some [])
          ~config ~meta
      in
      check bool "unclaimable backlog stays idle" false present)

let test_collect_board_events_keeps_non_mentions_as_followup_signal () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Unix.putenv "MASC_BASE_PATH" base_dir;
      Masc_mcp.Board.reset_global_for_test ();
      Masc_mcp.Board_dispatch.reset_for_test ();
      Masc_mcp.Board_dispatch.init_jsonl ();
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      (match
         Masc_mcp.Board_dispatch.create_post ~author:"alice"
           ~title:"General update" ~content:"No direct mention here"
           ~post_kind:Masc_mcp.Board.Human_post ()
       with
      | Ok _ -> ()
      | Error e -> fail ("create_post failed: " ^ Masc_mcp.Board.show_board_error e));
      let events, new_count, mention_count =
        WO.collect_board_events ~base_path:base_dir
          ~continuity_summary:"goal test-keeper"
          ~meta:minimal_meta
      in
      check int "default keepers ignore unmatched non-mention events" 0
        (List.length events);
      check int "new count includes non-mention" 1 new_count;
      check int "mention count stays zero" 0 mention_count)

let test_collect_board_events_keeps_non_mentions_for_room_signal_keepers () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Unix.putenv "MASC_BASE_PATH" base_dir;
      Masc_mcp.Board.reset_global_for_test ();
      Masc_mcp.Board_dispatch.reset_for_test ();
      Masc_mcp.Board_dispatch.init_jsonl ();
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      (match
         Masc_mcp.Board_dispatch.create_post ~author:"alice"
           ~title:"General update" ~content:"No direct mention here"
           ~post_kind:Masc_mcp.Board.Human_post ()
       with
      | Ok _ -> ()
      | Error e -> fail ("create_post failed: " ^ Masc_mcp.Board.show_board_error e));
      let events, new_count, mention_count =
        WO.collect_board_events ~base_path:base_dir
          ~continuity_summary:"goal test-keeper"
          ~meta:room_signal_meta
      in
      check int "room-signal keepers keep non-mention events" 1
        (List.length events);
      check int "new count includes non-mention" 1 new_count;
      check int "mention count stays zero" 0 mention_count;
      check bool "event is not explicit mention" false
        (List.hd events).explicit_mention)

let test_collect_board_events_keeps_external_replies_after_self_comment () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Unix.putenv "MASC_BASE_PATH" base_dir;
      Masc_mcp.Board.reset_global_for_test ();
      Masc_mcp.Board_dispatch.reset_for_test ();
      Masc_mcp.Board_dispatch.init_jsonl ();
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      let post_id =
        match
          Masc_mcp.Board_dispatch.create_post ~author:"alice"
            ~title:"General update" ~content:"No direct mention here"
            ~post_kind:Masc_mcp.Board.Human_post ()
        with
        | Ok post -> Masc_mcp.Board.Post_id.to_string post.id
        | Error e -> fail ("create_post failed: " ^ Masc_mcp.Board.show_board_error e)
      in
      (match
         Masc_mcp.Board_dispatch.add_comment ~post_id ~author:"test-keeper"
           ~content:"I am following this thread."
           ()
       with
      | Ok _ -> ()
      | Error e -> fail ("add_comment failed: " ^ Masc_mcp.Board.show_board_error e));
      Unix.sleepf 0.02;
      (match
         Masc_mcp.Board_dispatch.add_comment ~post_id ~author:"bob"
           ~content:"Thanks, there is a new question for you."
           ()
       with
      | Ok _ -> ()
      | Error e -> fail ("add_comment failed: " ^ Masc_mcp.Board.show_board_error e));
      let events, new_count, mention_count =
        WO.collect_board_events ~base_path:base_dir
          ~continuity_summary:"goal test-keeper"
          ~meta:minimal_meta
      in
      check int "new count still tracks recent post" 1 new_count;
      check int "mention count stays zero" 0 mention_count;
      match events with
      | [ event ] ->
          check bool "follow-up marks self commented" true event.self_commented;
          check int "external reply count" 1 event.new_external_since;
          check bool "no explicit mention required" false event.explicit_mention;
          check string "latest external author" "bob"
            (Option.value ~default:"" event.latest_external_author)
      | _ -> fail "expected one follow-up board event")

let test_collect_board_events_treats_generated_alias_as_self_comment () =
  let base_dir = temp_dir () in
  let meta =
    {
      (make_meta "ramarama") with
      agent_name = "keeper-ramarama-agent";
    }
  in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Unix.putenv "MASC_BASE_PATH" base_dir;
      Masc_mcp.Board.reset_global_for_test ();
      Masc_mcp.Board_dispatch.reset_for_test ();
      Masc_mcp.Board_dispatch.init_jsonl ();
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      let post_id =
        match
          Masc_mcp.Board_dispatch.create_post ~author:"alice"
            ~title:"General update" ~content:"No direct mention here"
            ~post_kind:Masc_mcp.Board.Human_post ()
        with
        | Ok post -> Masc_mcp.Board.Post_id.to_string post.id
        | Error e -> fail ("create_post failed: " ^ Masc_mcp.Board.show_board_error e)
      in
      (match
         Masc_mcp.Board_dispatch.add_comment ~post_id
           ~author:"ramarama-fierce-panda"
           ~content:"I am following this thread."
           ()
       with
      | Ok _ -> ()
      | Error e -> fail ("add_comment failed: " ^ Masc_mcp.Board.show_board_error e));
      Unix.sleepf 0.02;
      (match
         Masc_mcp.Board_dispatch.add_comment ~post_id ~author:"bob"
           ~content:"Thanks, there is a new question for you."
           ()
       with
      | Ok _ -> ()
      | Error e -> fail ("add_comment failed: " ^ Masc_mcp.Board.show_board_error e));
      let events, new_count, mention_count =
        WO.collect_board_events ~base_path:base_dir
          ~continuity_summary:"goal ramarama"
          ~meta
      in
      check int "new count still tracks recent post" 1 new_count;
      check int "mention count stays zero" 0 mention_count;
      match events with
      | [ event ] ->
          check bool "generated alias counts as self comment" true event.self_commented;
          check int "external reply count" 1 event.new_external_since;
          check string "latest external author" "bob"
            (Option.value ~default:"" event.latest_external_author)
      | _ -> fail "expected one follow-up board event")

let test_observe_ignores_scope_messages_without_room_signal_opt_in () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Unix.putenv "MASC_BASE_PATH" base_dir;
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      ignore (Masc_mcp.Coord.broadcast config ~from_agent:"alice" ~content:"general room update");
      let meta = { minimal_meta with joined_room_ids = [ "default" ] } in
      let obs =
        WO.observe ~allowed_tool_names:None
          ~pending_board_events:(Some [])
          ~config ~meta
      in
      check int "mentions stay empty" 0 (List.length obs.pending_mentions);
      check int "scope messages stay empty" 0
        (List.length obs.pending_scope_messages))

let test_observe_collects_scope_messages_for_room_signal_keepers () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Unix.putenv "MASC_BASE_PATH" base_dir;
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      ignore (Masc_mcp.Coord.broadcast config ~from_agent:"alice" ~content:"general room update");
      let meta = { room_signal_meta with joined_room_ids = [ "default" ] } in
      let obs =
        WO.observe ~allowed_tool_names:None
          ~pending_board_events:(Some [])
          ~config ~meta
      in
      check int "mentions stay empty" 0 (List.length obs.pending_mentions);
      check bool "scope messages collected" true
        (List.length obs.pending_scope_messages >= 1))

let test_observe_damps_keeper_scope_chatter_but_keeps_direct_mentions () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Unix.putenv "MASC_BASE_PATH" base_dir;
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      ignore
        (Masc_mcp.Coord.broadcast config
           ~from_agent:"keeper-ramarama-agent"
           ~content:"general keeper room update");
      ignore
        (Masc_mcp.Coord.broadcast config
           ~from_agent:"keeper-ramarama-agent"
           ~content:"@test-keeper please inspect this");
      ignore
        (Masc_mcp.Coord.broadcast config ~from_agent:"operator"
           ~content:"general operator room update");
      let meta = { room_signal_meta with joined_room_ids = [ "default" ] } in
      let obs =
        WO.observe ~allowed_tool_names:None
          ~pending_board_events:(Some [])
          ~config ~meta
      in
      check int "keeper direct mention collected" 1
        (List.length obs.pending_mentions);
      check int "only operator scope collected" 1
        (List.length obs.pending_scope_messages);
      match obs.pending_scope_messages with
      | [ (author, content) ] ->
          check string "scope author" "operator" author;
          check string "scope content" "general operator room update" content
      | _ -> fail "expected one operator scope message")

let test_observe_skips_stale_terminal_task_mentions () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Unix.putenv "MASC_BASE_PATH" base_dir;
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      ignore
        (Masc_mcp.Coord.add_task config ~title:"Terminal task" ~priority:1
           ~description:"");
      ignore
        (Masc_mcp.Coord.claim_task config ~agent_name:"nick0cave"
           ~task_id:"task-001");
      ignore
        (Masc_mcp.Coord.broadcast config ~from_agent:"taskmaster"
           ~content:
             "@test-keeper task-001 stale claim detected: current_task_id=null \
              but MASC still lists task-001 as claimed by you. Please release \
              it.");
      (match
         Masc_mcp.Coord.force_done_task_r config ~agent_name:"operator"
           ~task_id:"task-001" ~notes:"terminal in backlog" ()
       with
       | Ok _ -> ()
       | Error err -> fail (Masc_domain.masc_error_to_string err));
      let meta = { minimal_meta with joined_room_ids = [ "default" ] } in
      let obs =
        WO.observe ~allowed_tool_names:None
          ~pending_board_events:(Some [])
          ~config ~meta
      in
      check int "stale mention skipped" 0 (List.length obs.pending_mentions);
      check int "scope messages stay empty" 0
        (List.length obs.pending_scope_messages);
      check bool "cursor advanced" true
        (List.exists
           (fun (room_id, seq) -> String.equal room_id "default" && seq > 0)
           obs.message_cursor_updates))

let test_scheduled_turn_uses_cooldown_only () =
  let meta =
    { minimal_meta with
      current_task_id =
        (match Masc_mcp.Keeper_id.Task_id.of_string "task-123" with
         | Ok value -> Some value
         | Error err -> fail ("task id parse failed: " ^ err));
      proactive =
        { enabled = true; idle_sec = 0; cooldown_sec = 60 };
      runtime =
        { minimal_meta.runtime with
          proactive_rt =
            { minimal_meta.runtime.proactive_rt with
              last_ts = Time_compat.now () -. 120.0;
            };
        };
    }
  in
  let obs = { base_observation with idle_seconds = 0 } in
  check bool "cooldown opens scheduled turn for current task" true
    (WO.keeper_cycle_decision
       ~provider_cooldown_remaining_sec:(fun ~cascade_name:_ -> None)
       ~meta obs).should_run

let test_scheduled_turn_skips_without_structured_work_signal () =
  let meta =
    { minimal_meta with
      proactive =
        { enabled = true; idle_sec = 0; cooldown_sec = 60 };
      runtime =
        { minimal_meta.runtime with
          proactive_rt =
            { minimal_meta.runtime.proactive_rt with
              last_ts = Time_compat.now () -. 120.0;
            };
        };
    }
  in
  let obs = { base_observation with idle_seconds = 0 } in
  check bool "no signal blocks scheduled turn" false
    (WO.should_run_keeper_cycle ~meta obs);
  let decision = WO.keeper_cycle_decision ~meta obs in
  check bool "decision records no-signal reason" true
    (match decision.verdict with
     | WO.Skip { reasons = (first, rest) } ->
         List.exists (function WO.No_signal -> true | _ -> false)
           (first :: rest)
     | WO.Run _ -> false)

let test_scheduled_turn_respects_cooldown () =
  let meta =
    { minimal_meta with
      proactive =
        { enabled = true; idle_sec = 0; cooldown_sec = 300 };
      runtime =
        { minimal_meta.runtime with
          proactive_rt =
            { minimal_meta.runtime.proactive_rt with
              last_ts = Time_compat.now () -. 30.0;
            };
        };
    }
  in
  check bool "cooldown blocks scheduled turn" false
    (WO.should_run_keeper_cycle ~meta base_observation)

let test_scheduled_turn_requires_idle_gate () =
  let meta =
    {
      minimal_meta with
      proactive =
        { enabled = true; idle_sec = 300; cooldown_sec = 60 };
      runtime =
        {
          minimal_meta.runtime with
          proactive_rt =
            { minimal_meta.runtime.proactive_rt with
              last_ts = Time_compat.now () -. 600.0;
            };
        };
    }
  in
  let obs = { base_observation with idle_seconds = 120 } in
  check bool "idle gate blocks scheduled turn" false
    (WO.should_run_keeper_cycle ~meta obs);
  let decision = WO.keeper_cycle_decision ~meta obs in
  check bool "decision records idle wait reason" true
    (match decision.verdict with
     | WO.Skip { reasons = (first, rest)} ->
         List.exists (function WO.Idle_gate_pending _ -> true | _ -> false)
           (first :: rest)
     | WO.Run _ -> false)

let test_provider_cooldown_blocks_scheduled_turn_when_work_is_ready () =
  let meta =
    { minimal_meta with
      current_task_id =
        (match Masc_mcp.Keeper_id.Task_id.of_string "task-456" with
         | Ok value -> Some value
         | Error err -> fail ("task id parse failed: " ^ err));
      proactive =
        { enabled = true; idle_sec = 0; cooldown_sec = 60 };
      runtime =
        { minimal_meta.runtime with
          proactive_rt =
            { minimal_meta.runtime.proactive_rt with
              last_ts = Time_compat.now () -. 120.0;
            };
        };
    }
  in
  let decision =
    WO.keeper_cycle_decision
      ~provider_cooldown_remaining_sec:(fun ~cascade_name:_ -> Some 3599)
      ~meta
      base_observation
  in
  check bool "provider cooldown blocks scheduled turn" false decision.should_run;
  check string "channel stays scheduled_autonomous" "scheduled_autonomous"
    (WO.channel_to_string decision.channel);
  check bool "decision records provider cooldown wait reason" true
    (match decision.verdict with
     | WO.Skip { reasons = (first, rest) } ->
         List.exists
           (function WO.Provider_cooldown_pending { remaining_sec = 3599 } -> true | _ -> false)
           (first :: rest)
     | WO.Run _ -> false)

let test_provider_cooldown_keeps_scheduled_turn_open_when_fail_open_exists () =
  let meta =
    { minimal_meta with
      cascade_name = "tool_rerank";
      current_task_id =
        (match Masc_mcp.Keeper_id.Task_id.of_string "task-789" with
         | Ok value -> Some value
         | Error err -> fail ("task id parse failed: " ^ err));
      proactive =
        { enabled = true; idle_sec = 0; cooldown_sec = 60 };
      runtime =
        { minimal_meta.runtime with
          proactive_rt =
            { minimal_meta.runtime.proactive_rt with
              last_ts = Time_compat.now () -. 120.0;
            };
        };
    }
  in
  let decision =
    WO.keeper_cycle_decision
      ~provider_cooldown_remaining_sec:(fun ~cascade_name:_ -> Some 3599)
      ~meta
      base_observation
  in
  check bool "provider cooldown keeps scheduled turn open when fallback exists"
    true decision.should_run;
  check bool "decision does not surface cooldown skip when fail-open exists"
    false
    (match decision.verdict with
     | WO.Skip { reasons = (first, rest) } ->
         List.exists
           (function WO.Provider_cooldown_pending _ -> true | _ -> false)
           (first :: rest)
     | WO.Run _ -> false)

let test_effective_cooldown_no_decay_within_base () =
  (* Within the base cooldown period, no decay should apply. *)
  let result =
    WO.effective_scheduled_autonomous_cooldown
      ~base_cooldown:1800 ~since_last:900 ()
  in
  check int "no decay within base" 1800 result

let test_effective_cooldown_at_boundary () =
  (* Exactly at the base cooldown, no decay yet. *)
  let result =
    WO.effective_scheduled_autonomous_cooldown
      ~base_cooldown:1800 ~since_last:1800 ()
  in
  check int "no decay at boundary" 1800 result

let test_effective_cooldown_first_decay () =
  (* One full extra period: cooldown halved. *)
  let result =
    WO.effective_scheduled_autonomous_cooldown
      ~base_cooldown:1800 ~since_last:3600 ()
  in
  check int "first decay halves cooldown" 900 result

let test_effective_cooldown_second_decay () =
  (* Two extra periods: cooldown quartered. *)
  let result =
    WO.effective_scheduled_autonomous_cooldown
      ~base_cooldown:1800 ~since_last:5400 ()
  in
  check int "second decay quarters cooldown" 450 result

let test_effective_cooldown_floor () =
  (* Four+ extra periods: cooldown at floor (300s default). *)
  let result =
    WO.effective_scheduled_autonomous_cooldown
      ~base_cooldown:1800 ~since_last:10800 ()
  in
  check int "decay floors at min_cooldown" 300 result

let test_effective_cooldown_max_int () =
  (* max_int (first scheduled autonomous cycle ever): should hit floor immediately. *)
  let result =
    WO.effective_scheduled_autonomous_cooldown
      ~base_cooldown:1800 ~since_last:max_int ()
  in
  check int "max_int hits floor" 300 result

let test_noop_backoff_doubles_cooldown () =
  let result =
    WO.effective_scheduled_autonomous_cooldown
      ~base_cooldown:1800 ~since_last:900
      ~consecutive_noop_count:1 ()
  in
  (* 1 noop → 2x multiplier → effective base = 3600, since_last < 3600 *)
  check int "1 noop doubles effective base" 3600 result

let test_noop_backoff_quadruples_cooldown () =
  let result =
    WO.effective_scheduled_autonomous_cooldown
      ~base_cooldown:1800 ~since_last:900
      ~consecutive_noop_count:2 ()
  in
  (* 2 noops → 4x multiplier → effective base = 7200 *)
  check int "2 noops quadruples effective base" 7200 result

let test_noop_backoff_caps_at_8x () =
  let result =
    WO.effective_scheduled_autonomous_cooldown
      ~base_cooldown:1800 ~since_last:900
      ~consecutive_noop_count:5 ()
  in
  (* 5 noops → capped at 3 → 8x multiplier → effective base = 14400 *)
  check int "noop backoff caps at 8x" 14400 result

let test_noop_backoff_zero_noops_unchanged () =
  let result =
    WO.effective_scheduled_autonomous_cooldown
      ~base_cooldown:1800 ~since_last:900
      ~consecutive_noop_count:0 ()
  in
  check int "0 noops = no backoff" 1800 result

let test_idle_decay_triggers_turn () =
  (* After extended idle, decay should make cooldown_elapsed true
     even when since_last_proactive < base cooldown_sec, provided the
     scheduler sees structured work for the keeper. *)
  let meta =
    { minimal_meta with
      current_task_id =
        (match Masc_mcp.Keeper_id.Task_id.of_string "task-123" with
         | Ok value -> Some value
         | Error err -> fail ("task id parse failed: " ^ err));
      proactive =
        { enabled = true; idle_sec = 0; cooldown_sec = 1800 };
      runtime =
        { minimal_meta.runtime with
          consecutive_noop_count = 0;
          proactive_rt =
            { minimal_meta.runtime.proactive_rt with
              consecutive_noop_count = 0;
              last_ts = Time_compat.now () -. 4000.0;
            };
        };
    }
  in
  check bool "idle decay triggers turn before base cooldown" true
    (WO.keeper_cycle_decision
       ~provider_cooldown_remaining_sec:(fun ~cascade_name:_ -> None)
       ~meta base_observation).should_run

let test_scheduled_turn_decision_uses_backlog_acceleration () =
  let meta =
    {
      minimal_meta with
      proactive =
        { enabled = true; idle_sec = 60; cooldown_sec = 900 };
      runtime =
        {
          minimal_meta.runtime with
          proactive_rt =
            { minimal_meta.runtime.proactive_rt with
              last_ts = Time_compat.now () -. 320.0;
            };
        };
    }
  in
  let obs =
    {
      base_observation with
      idle_seconds = 120;
      failed_task_count = 2;
    }
  in
  let decision =
    WO.keeper_cycle_decision
      ~provider_cooldown_remaining_sec:(fun ~cascade_name:_ -> None)
      ~meta obs
  in
  check bool "backlog acceleration opens scheduled turn" true decision.should_run;
  check bool "marks actionable backlog" true
    (match decision.verdict with
     | WO.Run { reasons = (first, rest)} ->
         List.exists (function WO.Task_backlog _ -> true | _ -> false)
           (first :: rest)
     | WO.Skip _ -> false);
  check bool "marks backlog cooldown elapsed" true
    (match decision.verdict with
     | WO.Run { reasons = (first, rest)} ->
         List.mem WO.Task_reactive_cooldown_elapsed (first :: rest)
     | WO.Skip _ -> false)

let test_scheduled_turn_ignores_unclaimable_backlog () =
  let meta =
    {
      minimal_meta with
      proactive =
        { enabled = true; idle_sec = 600; cooldown_sec = 900 };
      runtime =
        {
          minimal_meta.runtime with
          proactive_rt =
            { minimal_meta.runtime.proactive_rt with
              last_ts = Time_compat.now () -. 320.0;
            };
        };
    }
  in
  let obs =
    {
      base_observation with
      idle_seconds = 120;
      unclaimed_task_count = 3;
      claimable_task_count = 0;
      backlog_updated_since_last_scheduled_autonomous = true;
    }
  in
  let decision =
    WO.keeper_cycle_decision
      ~provider_cooldown_remaining_sec:(fun ~cascade_name:_ -> None)
      ~meta obs
  in
  check bool "absolute-only backlog does not wake keeper" false
    decision.should_run;
  check bool "no task backlog reason for unclaimable backlog" true
    (match decision.verdict with
     | WO.Skip { reasons = (first, rest)} ->
         List.exists (function WO.No_signal -> true | _ -> false)
           (first :: rest)
     | WO.Run _ -> false)

let test_verdict_reasons_to_strings_uses_structured_run_tags () =
  let verdict =
    WO.Run
      {
        reasons =
          ( WO.Scheduled_autonomous_turn,
            [
              WO.Idle_cooldown_elapsed { idle_sec = 120; cooldown = 900 };
              WO.Cooldown_elapsed;
              WO.Task_backlog { unclaimed = 1; failed = 2 };
              WO.Task_reactive_cooldown_elapsed;
            ] );
      }
  in
  check (list string) "structured run tags"
    [ "scheduled_autonomous_turn";
      "idle_cooldown_elapsed";
      "cooldown_elapsed";
      "task_backlog";
      "task_reactive_cooldown_elapsed" ]
    (WO.verdict_reasons_to_strings verdict)

let test_verdict_reasons_to_strings_uses_structured_skip_tags () =
  let idle_gate_verdict =
    WO.Skip
      {
        reasons =
          ( WO.Idle_gate_pending { remaining_sec = 180 }, [] );
      }
  in
  let cooldown_verdict =
    WO.Skip
      {
        reasons =
          ( WO.Cooldown_pending { remaining_sec = 60 }, [] );
      }
  in
  let provider_cooldown_verdict =
    WO.Skip
      {
        reasons =
          ( WO.Provider_cooldown_pending { remaining_sec = 3599 }, [] );
      }
  in
  check (list string) "structured idle-gate skip tags"
    [ "idle_gate_pending" ]
    (WO.verdict_reasons_to_strings idle_gate_verdict);
  check (list string) "structured cooldown skip tags"
    [ "cooldown_pending" ]
    (WO.verdict_reasons_to_strings cooldown_verdict);
  check (list string) "structured provider cooldown skip tags"
    [ "provider_cooldown_pending" ]
    (WO.verdict_reasons_to_strings provider_cooldown_verdict)

let test_paused_keeper_blocks_turns_even_with_reactive_signal () =
  let meta = { minimal_meta with paused = true } in
  let obs =
    { base_observation with pending_mentions = [ ("alice", "@keeper wake up") ] }
  in
  let decision = WO.unified_turn_decision ~meta obs in
  check bool "paused keeper does not run" false decision.should_run;
  check string "channel stays reactive" "reactive"
    (WO.channel_to_string decision.channel);
  check (list string) "paused reason is surfaced"
    [ "keeper_paused" ]
    (WO.verdict_reasons_to_strings decision.verdict)

let test_pending_approval_blocks_turns_until_resolved () =
  Eio_main.run @@ fun _env ->
  let reactive_obs =
    {
      base_observation with
      pending_mentions = [ ("alice", "@keeper continue") ];
    }
  in
  let id =
    AQ.submit_pending
      ~keeper_name:minimal_meta.name
      ~tool_name:"keeper_continue_after_partial_commit"
      ~input:(`Assoc [ ("kind", `String "continue_gate_required") ])
      ~risk_level:AQ.Critical
      ~on_resolution:(fun _ -> ())
      ()
  in
  let decision = WO.unified_turn_decision ~meta:minimal_meta reactive_obs in
  check bool "approval pending blocks turn" false decision.should_run;
  check (list string) "approval pending reason is surfaced"
    [ "approval_pending" ]
    (WO.verdict_reasons_to_strings decision.verdict);
  match AQ.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
  | Ok () ->
    let resumed = WO.unified_turn_decision ~meta:minimal_meta reactive_obs in
    check bool "approval resolve re-opens reactive scheduling" true resumed.should_run;
    check string "resolved approval restores reactive channel" "reactive"
      (WO.channel_to_string resumed.channel)
  | Error err -> Alcotest.fail ("resolve failed: " ^ AQ.resolve_error_to_string err)

let test_task_reactive_cooldown_floor_never_hits_zero () =
  with_env "MASC_KEEPER_PROACTIVE_TASK_MIN_COOLDOWN_SEC" "0" (fun () ->
    let meta =
      {
        minimal_meta with
        proactive =
          { enabled = true; idle_sec = 60; cooldown_sec = 900 };
        runtime =
          {
            minimal_meta.runtime with
            proactive_rt =
              { minimal_meta.runtime.proactive_rt with
                last_ts = Time_compat.now () -. 320.0;
              };
          };
      }
    in
    let obs =
      {
        base_observation with
        idle_seconds = 120;
        failed_task_count = 1;
      }
    in
    let decision =
      WO.keeper_cycle_decision
        ~provider_cooldown_remaining_sec:(fun ~cascade_name:_ -> None)
        ~meta obs
    in
    check (option int) "task reactive cooldown clamps to positive floor" (Some 300)
      decision.task_reactive_cooldown)

let test_task_backlog_cooldown_applies_noop_backoff_once () =
  with_env "MASC_KEEPER_PROACTIVE_TASK_MIN_COOLDOWN_SEC" "0" (fun () ->
    let meta =
      {
        minimal_meta with
        proactive =
          { enabled = true; idle_sec = 120; cooldown_sec = 300 };
        runtime =
          {
            minimal_meta.runtime with
            consecutive_noop_count = 16;
            proactive_rt =
              { minimal_meta.runtime.proactive_rt with
                consecutive_noop_count = 3;
                last_ts = Time_compat.now () -. 1000.0;
              };
          };
      }
    in
    let obs =
      {
        base_observation with
        idle_seconds = 1000;
        unclaimed_task_count = 1;
        claimable_task_count = 1;
      }
    in
    let decision =
      WO.keeper_cycle_decision
        ~provider_cooldown_remaining_sec:(fun ~cascade_name:_ -> None)
        ~meta obs
    in
    check (option int) "cooldown uses proactive noop backoff once" (Some 2400)
      decision.effective_cooldown;
    check (option int) "task cooldown stays responsive" (Some 800)
      decision.task_reactive_cooldown;
    check bool "task backlog can schedule after task cooldown" true decision.should_run)

let test_scheduled_turn_decision_runs_immediately_on_fresh_backlog_update () =
  let meta =
    {
      minimal_meta with
      proactive =
        { enabled = true; idle_sec = 60; cooldown_sec = 60 };
      runtime =
        {
          minimal_meta.runtime with
          proactive_rt =
            { minimal_meta.runtime.proactive_rt with
              last_ts = Time_compat.now ();
            };
        };
    }
  in
  let obs =
    {
      base_observation with
      unclaimed_task_count = 1;
      claimable_task_count = 1;
      backlog_updated_since_last_scheduled_autonomous = true;
    }
  in
  let decision =
    WO.keeper_cycle_decision
      ~provider_cooldown_remaining_sec:(fun ~cascade_name:_ -> None)
      ~meta obs
  in
  check bool "fresh backlog bypasses cooldown" true decision.should_run;
  check bool "backlog emits reactive cooldown tag" true
    (match decision.verdict with
     | WO.Run { reasons = (first, rest) } ->
         List.mem WO.Task_reactive_cooldown_elapsed (first :: rest)
     | WO.Skip _ -> false)

(* Phase 1 — Bootstrap bypass *)

let test_bootstrap_turn_fires_when_never_started () =
  (* A keeper with last_ts <= 0.0 (never started) should always run a turn
     even when there are no work signals, no tasks, and the idle gate has
     not elapsed.  This breaks the bootstrap deadlock. *)
  let meta =
    { minimal_meta with
      proactive =
        { enabled = true; idle_sec = 300; cooldown_sec = 1800 };
      runtime =
        { minimal_meta.runtime with
          proactive_rt =
            { minimal_meta.runtime.proactive_rt with
              last_ts = 0.0;
            };
        };
    }
  in
  let obs = { base_observation with idle_seconds = 0 } in
  let decision =
    WO.keeper_cycle_decision
      ~provider_cooldown_remaining_sec:(fun ~cascade_name:_ -> None)
      ~meta obs
  in
  check bool "bootstrap: should_run=true when never started" true decision.should_run;
  check bool "bootstrap: Never_started reason emitted" true
    (match decision.verdict with
     | WO.Run { reasons = (first, rest) } ->
         List.mem WO.Never_started (first :: rest)
     | WO.Skip _ -> false);
  check int "bootstrap: since_last_scheduled_autonomous = max_int" max_int
    (Option.value ~default:(-1) decision.since_last_scheduled_autonomous)

let test_bootstrap_turn_emits_scheduled_autonomous_channel () =
  let meta =
    { minimal_meta with
      proactive =
        { enabled = true; idle_sec = 600; cooldown_sec = 900 };
      runtime =
        { minimal_meta.runtime with
          proactive_rt =
            { minimal_meta.runtime.proactive_rt with
              last_ts = 0.0;
            };
        };
    }
  in
  let obs = { base_observation with idle_seconds = 0 } in
  let decision =
    WO.keeper_cycle_decision
      ~provider_cooldown_remaining_sec:(fun ~cascade_name:_ -> None)
      ~meta obs
  in
  check string "bootstrap channel is scheduled_autonomous" "scheduled_autonomous"
    (WO.channel_to_string decision.channel)

let test_provider_cooldown_blocks_bootstrap_turn () =
  let meta =
    { minimal_meta with
      cascade_name = Masc_mcp.Keeper_config.default_cascade_name;
      proactive =
        { enabled = true; idle_sec = 300; cooldown_sec = 1800 };
      runtime =
        { minimal_meta.runtime with
          proactive_rt =
            { minimal_meta.runtime.proactive_rt with
              last_ts = 0.0;
            };
        };
    }
  in
  let obs = { base_observation with idle_seconds = 0 } in
  let decision =
    WO.keeper_cycle_decision
      ~provider_cooldown_remaining_sec:(fun ~cascade_name:_ -> Some 3599)
      ~meta obs
  in
  check bool "provider cooldown blocks bootstrap turn" false decision.should_run;
  check bool "bootstrap cooldown skip reason emitted" true
    (match decision.verdict with
     | WO.Skip { reasons = (first, rest) } ->
         List.exists
           (function
             | WO.Provider_cooldown_pending { remaining_sec = 3599 } -> true
             | _ -> false)
           (first :: rest)
     | WO.Run _ -> false)

(* Phase 2 — Minimum proactive cadence *)

let test_min_interval_fires_without_work_signal () =
  (* After proactive_min_interval_sec has elapsed since the last turn,
     the keeper should fire a housekeeping turn even when there are no
     observable work signals. *)
  with_env "MASC_KEEPER_PROACTIVE_MIN_INTERVAL_SEC" "900" (fun () ->
    let meta =
      { minimal_meta with
        proactive =
          { enabled = true; idle_sec = 0; cooldown_sec = 600 };
        runtime =
          { minimal_meta.runtime with
            proactive_rt =
              { minimal_meta.runtime.proactive_rt with
                (* 1000s > 900s min_interval, so the elapsed condition triggers *)
                last_ts = Time_compat.now () -. 1000.0;
              };
          };
      }
    in
    let obs = { base_observation with idle_seconds = 0 } in
    let decision =
      WO.keeper_cycle_decision
        ~provider_cooldown_remaining_sec:(fun ~cascade_name:_ -> None)
        ~meta obs
    in
    check bool "min interval elapsed fires turn" true decision.should_run;
    check bool "Min_interval_elapsed reason emitted" true
      (match decision.verdict with
       | WO.Run { reasons = (first, rest) } ->
           List.mem WO.Min_interval_elapsed (first :: rest)
       | WO.Skip _ -> false))

let test_min_interval_turn_is_not_tagged_entropic () =
  with_env "MASC_KEEPER_PROACTIVE_MIN_INTERVAL_SEC" "900" (fun () ->
    Fun.protect ~finally:Random.self_init @@ fun () ->
    Random.init 15;
    let meta =
      { minimal_meta with
        proactive =
          { enabled = true; idle_sec = 0; cooldown_sec = 600 };
        runtime =
          { minimal_meta.runtime with
            proactive_rt =
              { minimal_meta.runtime.proactive_rt with
                last_ts = Time_compat.now () -. 1000.0;
              };
          };
      }
    in
    let obs = { base_observation with idle_seconds = 0 } in
    let decision =
      WO.keeper_cycle_decision
        ~provider_cooldown_remaining_sec:(fun ~cascade_name:_ -> None)
        ~meta obs
    in
    check bool "min interval elapsed fires turn" true decision.should_run;
    check bool "Min_interval_elapsed reason emitted" true
      (match decision.verdict with
       | WO.Run { reasons = (first, rest) } ->
           List.mem WO.Min_interval_elapsed (first :: rest)
       | WO.Skip _ -> false);
    check bool "Min_interval_elapsed is not tagged as entropic" false
      (match decision.verdict with
       | WO.Run { reasons = (first, rest) } ->
           List.mem WO.Entropic_oscillation (first :: rest)
       | WO.Skip _ -> false))

let test_min_interval_does_not_fire_before_elapsed () =
  (* With since_last = 500s and min_interval = 900s, the keeper should
     NOT get a free housekeeping turn (no work signals present either). *)
  with_env "MASC_KEEPER_PROACTIVE_MIN_INTERVAL_SEC" "900" (fun () ->
    let meta =
      { minimal_meta with
        proactive =
          { enabled = true; idle_sec = 0; cooldown_sec = 600 };
        runtime =
          { minimal_meta.runtime with
            proactive_rt =
              { minimal_meta.runtime.proactive_rt with
                (* 500s < 900s min_interval, so not-yet-elapsed condition holds *)
                last_ts = Time_compat.now () -. 500.0;
              };
          };
      }
    in
    let obs = { base_observation with idle_seconds = 0 } in
    let decision =
      WO.keeper_cycle_decision
        ~provider_cooldown_remaining_sec:(fun ~cascade_name:_ -> None)
        ~meta obs
    in
    check bool "min interval not yet elapsed: should_run=false" false decision.should_run;
    check bool "No_signal reason present when interval pending" true
      (match decision.verdict with
       | WO.Skip { reasons = (first, rest) } ->
           List.exists (function WO.No_signal -> true | _ -> false)
             (first :: rest)
       | WO.Run _ -> false))

let test_min_interval_never_fires_for_bootstrap () =
  (* The Min_interval_elapsed path must not fire when is_bootstrap = true
     (since_last = max_int).  The bootstrap bypass covers that case and
     emits Never_started, not Min_interval_elapsed. *)
  with_env "MASC_KEEPER_PROACTIVE_MIN_INTERVAL_SEC" "900" (fun () ->
    let meta =
      { minimal_meta with
        proactive =
          { enabled = true; idle_sec = 0; cooldown_sec = 600 };
        runtime =
          { minimal_meta.runtime with
            proactive_rt =
              { minimal_meta.runtime.proactive_rt with
                last_ts = 0.0;
              };
          };
      }
    in
    let obs = { base_observation with idle_seconds = 0 } in
    let decision =
      WO.keeper_cycle_decision
        ~provider_cooldown_remaining_sec:(fun ~cascade_name:_ -> None)
        ~meta obs
    in
    check bool "bootstrap does not emit Min_interval_elapsed" false
      (match decision.verdict with
       | WO.Run { reasons = (first, rest) } ->
           List.mem WO.Min_interval_elapsed (first :: rest)
       | WO.Skip _ -> false);
    check bool "bootstrap emits Never_started" true
      (match decision.verdict with
       | WO.Run { reasons = (first, rest) } ->
           List.mem WO.Never_started (first :: rest)
       | WO.Skip _ -> false))

let test_provider_cooldown_blocks_min_interval_turn () =
  with_env "MASC_KEEPER_PROACTIVE_MIN_INTERVAL_SEC" "900" (fun () ->
    let meta =
      { minimal_meta with
        cascade_name = Masc_mcp.Keeper_config.default_cascade_name;
        proactive =
          { enabled = true; idle_sec = 0; cooldown_sec = 600 };
        runtime =
          { minimal_meta.runtime with
            proactive_rt =
              { minimal_meta.runtime.proactive_rt with
                last_ts = Time_compat.now () -. 1000.0;
              };
          };
      }
    in
    let obs = { base_observation with idle_seconds = 0 } in
    let decision =
      WO.keeper_cycle_decision
        ~provider_cooldown_remaining_sec:(fun ~cascade_name:_ -> Some 3599)
        ~meta obs
    in
    check bool "provider cooldown blocks min-interval turn" false decision.should_run;
    check bool "min-interval cooldown skip reason emitted" true
      (match decision.verdict with
       | WO.Skip { reasons = (first, rest) } ->
           List.exists
             (function
               | WO.Provider_cooldown_pending { remaining_sec = 3599 } -> true
               | _ -> false)
             (first :: rest)
       | WO.Run _ -> false))

let test_runtime_trust_snapshot_tolerates_null_telemetry () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      with_test_runtime_roots base_dir @@ fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      let keeper_name = "runtime-trust-null-telemetry" in
      let meta = { minimal_meta with name = keeper_name } in
      let decision_path = Keeper_types.keeper_decision_log_path config keeper_name in
      Keeper_types.mkdir_p (Filename.dirname decision_path);
      Masc_mcp.Keeper_types_support.append_jsonl_line
        decision_path
        (`Assoc [ ("telemetry", `Null) ]);
      let snapshot =
        Masc_mcp.Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta
      in
	      check bool "selected model stays null" true
	        Yojson.Safe.Util.(snapshot |> member "selected_model" = `Null))

let test_runtime_trust_snapshot_surfaces_terminal_reason () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      with_test_runtime_roots base_dir @@ fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      let keeper_name = "runtime-trust-terminal-reason" in
      let meta =
        {
          minimal_meta with
          name = keeper_name;
          active_goal_ids = [ "goal-terminal-reason" ];
        }
      in
      let decision_path = Keeper_types.keeper_decision_log_path config keeper_name in
      Keeper_types.mkdir_p (Filename.dirname decision_path);
      Masc_mcp.Keeper_types_support.append_jsonl_line
        decision_path
        (`Assoc
          [
            ("ts_unix", `Float 1_712_000_000.0);
            ("trace_id", `String "trace-terminal-reason");
            ("turn_id", `Int 7);
            ("task_id", `String "task-terminal-reason");
            ("goal_ids", `List [ `String "goal-terminal-reason" ]);
            ( "terminal_reason",
              `Assoc
                [
                  ("code", `String "gh_repo_context_missing_worktree");
                  ("source", `String "legacy_error_text");
                  ("severity", `String "warn");
                  ( "summary",
                    `String "GitHub command blocked because the active task has no linked worktree" );
                  ("next_action", `String "create_or_link_worktree");
                ] );
          ]);
      let snapshot =
        Masc_mcp.Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta
      in
      let open Yojson.Safe.Util in
      check string "latest terminal code" "gh_repo_context_missing_worktree"
        (snapshot |> member "latest_terminal_reason" |> member "code" |> to_string);
      check string "latest next action" "create_or_link_worktree"
        (snapshot |> member "latest_next_action" |> to_string);
      let timeline = snapshot |> member "causal_timeline" |> to_list in
      check bool "terminal reason event present" true
        (List.exists
           (fun event ->
             event |> member "kind" |> to_string = "terminal_reason"
             && event |> member "next_human_action" |> to_string = "create_or_link_worktree")
           timeline))

let test_runtime_trust_snapshot_reads_terminal_reason_code_alias () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      with_test_runtime_roots base_dir @@ fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      let keeper_name = "runtime-trust-terminal-code-alias" in
      let meta = { minimal_meta with name = keeper_name } in
      let decision_path = Keeper_types.keeper_decision_log_path config keeper_name in
      Keeper_types.mkdir_p (Filename.dirname decision_path);
      Masc_mcp.Keeper_types_support.append_jsonl_line
        decision_path
        (`Assoc
          [
            ("ts_unix", `Float 1_712_000_010.0);
            ("trace_id", `String "trace-terminal-code-alias");
            ("turn_id", `Int 9);
            ("terminal_reason_code", `String "provider_error");
          ]);
      let snapshot =
        Masc_mcp.Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta
      in
      let open Yojson.Safe.Util in
      check string "latest terminal code alias" "provider_error"
        (snapshot |> member "latest_terminal_reason" |> member "code" |> to_string);
      let timeline = snapshot |> member "causal_timeline" |> to_list in
      check bool "terminal reason alias event present" true
        (List.exists
           (fun event ->
             event |> member "kind" |> to_string = "terminal_reason"
             && event |> member "summary" |> to_string = "provider or cascade failed")
           timeline))

let test_prompt_contains_identity () =
  let sys, _user = UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:base_observation () in
  check bool "contains name" true (String.length sys > 0);
  check bool "contains keeper name" true
    (let has_name =
       try ignore (Str.search_forward (Str.regexp_string "test-keeper") sys 0); true
       with Not_found -> false
     in has_name)

let test_prompt_contains_goal () =
  let sys, _user = UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:base_observation () in
  check bool "contains goal" true
    (let has_goal =
       try ignore (Str.search_forward (Str.regexp_string "test goal") sys 0); true
       with Not_found -> false
     in has_goal)

let test_prompt_mentions_extend_turns_guidance () =
  let sys, _user = UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:base_observation () in
  check bool "mentions extend_turns" true
    (let found =
       try
         ignore
           (Str.search_forward (Str.regexp_string "extend_turns") sys 0);
         true
       with Not_found -> false
     in found);
  check bool "mentions generation continuity" true
    (let found =
       try
         ignore
           (Str.search_forward (Str.regexp_string "checkpoint survives across cycles") sys 0);
         true
       with Not_found -> false
     in found)

let test_prompt_includes_operational_tool_guidance () =
  let sys, _user = UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:base_observation () in
  check bool "mentions task audit guidance" true
    (contains_substring sys "keeper_tasks_audit");
  check bool "mentions tool-first principle" true
    (contains_substring sys "Tool-first principle");
  check bool "mentions worktree inspection guidance" true
    (contains_substring sys "masc_code_read");
  check bool "mentions server-managed heartbeat" true
    (contains_substring sys "Heartbeat is server-managed");
  check bool "mentions draft PR broker" true
    (contains_substring sys "keeper_pr_create draft=true");
  check bool "raw gh PR creation not documented" false
    (contains_substring sys "open draft PRs after pushing")

let test_prompt_includes_research_evidence_contract () =
  let sys, _user =
    UP.build_prompt ~base_path:"/test" ~meta:minimal_meta
      ~observation:base_observation ()
  in
  check bool "mentions research evidence" true
    (contains_substring sys "Research evidence");
  check bool "mentions web search" true
    (contains_substring sys "masc_web_search");
  check bool "mentions uncited marker" true
    (contains_substring sys "[uncited]");
  check bool "mentions board sources metadata" true
    (contains_substring sys "sources` array")

let test_capabilities_prompt_distinguishes_sandbox_and_worktree () =
  let prompt = Prompt_registry.get_prompt "keeper.capabilities" in
  check bool "sandbox paths documented" true
    (contains_substring prompt "sandbox_repos");
  check bool "local backend host path not model-facing" false
    (contains_substring prompt "ALL tool calls that accept `cwd` or `path` MUST resolve under `.masc/playground");
  check bool "github shorthand removed" false
    (contains_substring prompt "keeper_github");
  check bool "sandbox is default coding workspace" true
    (contains_substring prompt "default coding workspace");
  check bool "git path documented via keeper_bash" true
    (contains_substring prompt "keeper_bash cmd='git status'");
  check bool "draft pr tool documented" true
    (contains_substring prompt "keeper_pr_create");
  check bool "gh pr create path not documented" false
    (contains_substring prompt "keeper_shell op=gh cmd='pr create --draft");
  check bool "legacy pr workflow removed from prompt" false
    (contains_substring prompt "keeper_pr_workflow")

let test_world_prompt_distinguishes_sandbox_and_worktree () =
  let prompt = Prompt_registry.get_prompt "keeper.world" in
  check bool "world prompt names single sandbox" true
    (contains_substring prompt "Your sandbox is the only filesystem ground");
  (* Keep the containment clause asserted so bare server-root `.worktrees/...`
     paths cannot drift back in. *)
  check bool "world prompt names worktree workflow inside sandbox" true
    (contains_substring prompt
       "Repo worktrees live *inside* your sandbox clone");
  check bool "world prompt names canonical sandbox-relative worktree path" true
    (contains_substring prompt
       "repos/<REPO_NAME>/.worktrees/<branch-or-task>/")

let test_system_prompt_prefers_bash_and_gh_pr_lane () =
  let sys =
    Masc_mcp.Keeper_prompt.build_keeper_system_prompt
      ~goal:"test goal"
      ~short_goal:"short"
      ~mid_goal:"mid"
      ~long_goal:"long"
      ~will:"will"
      ~needs:"needs"
      ~desires:"desires"
      ~instructions:""
      ()
  in
  check bool "mentions active schema guard" true
    (contains_substring sys
       "Use only the tool schemas currently shown to you by the runtime");
  check bool "mentions gh identity as conditional route" true
    (contains_substring sys
       "when keeper_shell op=gh is present");
  check bool "does not advertise removed keeper_github" false
    (contains_substring sys "keeper_github");
  check bool "legacy pr workflow removed" false
    (contains_substring sys "keeper_pr_workflow")

let test_prompt_includes_autonomous_trigger_section () =
  let meta =
    {
      minimal_meta with
      current_task_id =
        (match Masc_mcp.Keeper_id.Task_id.of_string "task-123" with
         | Ok value -> Some value
         | Error err -> fail ("task id parse failed: " ^ err));
      proactive =
        { enabled = true; idle_sec = 0; cooldown_sec = 60 };
      runtime =
        {
          minimal_meta.runtime with
          consecutive_noop_count = 0;
          proactive_rt =
            { minimal_meta.runtime.proactive_rt with
              consecutive_noop_count = 0;
              last_ts = Time_compat.now () -. 300.0;
            };
        };
    }
  in
  let _sys, user = UP.build_prompt ~base_path:"/test" ~meta ~observation:base_observation () in
  check bool "has autonomous trigger section" true
    (contains_substring user "Autonomous Trigger");
  check bool "includes scheduled reason" true
    (contains_substring user "scheduled autonomous keepalive turn");
  check bool "includes cooldown detail" true
    (contains_substring user "effective cooldown")

let test_prompt_omits_autonomous_trigger_for_reactive_turn () =
  let obs =
    {
      base_observation with
      pending_mentions = [ ("alice", "please check this") ];
      idle_seconds = 999;
    }
  in
  let _sys, user = UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs () in
  check bool "reactive turn omits autonomous trigger section" false
    (contains_substring user "Autonomous Trigger")

let test_prompt_omits_empty_sections () =
  let _sys, user = UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:base_observation () in
  check bool "no mention section" true
    (not (let found =
       try ignore (Str.search_forward (Str.regexp_string "Pending Mentions") user 0); true
       with Not_found -> false
     in found));
  check bool "no goals section" true
    (not (let found =
       try ignore (Str.search_forward (Str.regexp_string "Active Goals") user 0); true
       with Not_found -> false
     in found))

let test_prompt_continuity_drops_inert_idle_directives () =
  let obs =
    {
      base_observation with
      continuity_summary =
        "Goal: structural quality improvement\n\
         Next plan: stay silent until new actionable work appears\n\
         Next: 대기 유지; all non-destructive actions exhausted\n\
         Constraints: repos/ empty";
      unclaimed_task_count = 125;
    }
  in
  let _sys, user =
    UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs ()
  in
  check bool "continuity section present" true
    (contains_substring user "### Continuity");
  check bool "advisory note present" true
    (contains_substring user "ignore prior silence/wait directives");
  check bool "idle next plan removed" false
    (contains_substring user "stay silent until new actionable work appears");
  check bool "idle next removed" false
    (contains_substring user "대기 유지");
  check bool "goal preserved" true
    (contains_substring user "Goal: structural quality improvement");
  check bool "constraints preserved" true
    (contains_substring user "Constraints: repos/ empty")

let test_prompt_continuity_drops_stale_tool_surface_claims () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let obs =
    {
      base_observation with
      continuity_summary =
        "Goal: restore autonomous tool use\n\
         Next plan: call keeper_task_claim after checking live policy\n\
         Constraints: tool surface: masc_* only; no keeper_* tools visible";
      unclaimed_task_count = 3;
      claimable_task_count = 3;
    }
  in
  let _sys, user =
    UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs ()
  in
  check bool "continuity section present" true
    (contains_substring user "### Continuity");
  check bool "stale masc-only surface removed" false
    (contains_substring user "masc_* only");
  check bool "stale missing keeper tools removed" false
    (contains_substring user "no keeper_* tools");
  check bool "goal preserved" true
    (contains_substring user "Goal: restore autonomous tool use");
  check bool "live policy action preserved" true
    (contains_substring user "keeper_task_claim")

let test_prompt_includes_mentions_section () =
  let obs =
    { base_observation with
      pending_mentions = [("alice", "hello keeper")]
    }
  in
  let _sys, user = UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs () in
  check bool "has mention section" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "Pending Mentions") user 0); true
       with Not_found -> false
     in found);
  check bool "has mention content" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "@alice") user 0); true
       with Not_found -> false
     in found)

let test_prompt_includes_goals_section () =
  let obs =
    { base_observation with
      active_goals = ["goal-abc"]
    }
  in
  let _sys, user = UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs () in
  check bool "has goals section" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "Active Goals") user 0); true
       with Not_found -> false
     in found)

let test_prompt_includes_context_ratio () =
  let obs = { base_observation with context_ratio = 0.75 } in
  let _sys, user = UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs () in
  check bool "has context percentage" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "75%") user 0); true
       with Not_found -> false
     in found)

let test_prompt_includes_idle () =
  let obs = { base_observation with idle_seconds = 300 } in
  let _sys, user = UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs () in
  check bool "has idle seconds" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "300s") user 0); true
       with Not_found -> false
     in found)

let test_prompt_frugal_economy () =
  let obs = { base_observation with economic_pressure = AE.Frugal } in
  let _sys, user = UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs () in
  check bool "has frugal warning" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "Frugal") user 0); true
       with Not_found -> false
     in found)

let test_prompt_hustle_economy () =
  let obs = { base_observation with economic_pressure = AE.Hustle } in
  let _sys, user = UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs () in
  check bool "has hustle warning" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "Hustle") user 0); true
       with Not_found -> false
     in found)

let test_prompt_includes_worktree_delta () =
  let obs =
    { base_observation with
      worktree_change_summary =
        Some
          "<git_status_change>\nWorking tree changed since last keeper turn (1 files):\n M lib/example.ml\n</git_status_change>"
    }
  in
  let _sys, user = UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs () in
  check bool "has worktree section" true
    (let found =
       try
         ignore
           (Str.search_forward
              (Str.regexp_string "Live Worktree Delta")
              user 0);
         true
       with Not_found -> false
     in found);
  check bool "has git status block" true
    (let found =
       try
         ignore
           (Str.search_forward
              (Str.regexp_string "<git_status_change>")
              user 0);
         true
       with Not_found -> false
     in found)

let test_prompt_orders_stable_sections_before_reactive_sections () =
  let obs =
    {
      base_observation with
      active_goals = [ "goal-abc" ];
      continuity_summary =
        "Goal: structural quality improvement\nNext: verify latest runtime state";
      pending_mentions = [ ("alice", "hello keeper") ];
      pending_board_events = [ sample_board_event ];
      worktree_change_summary =
        Some "<git_status_change>\n M lib/example.ml\n</git_status_change>";
      context_ratio = 0.42;
      idle_seconds = 45;
      unclaimed_task_count = 2;
      claimable_task_count = 2;
      active_agent_count = 3;
    }
  in
  let _sys, user =
    UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs ()
  in
  let idx needle =
    match substring_index user needle with
    | Some i -> i
    | None -> fail ("missing section: " ^ needle)
  in
  check bool "active goals precede pending mentions" true
    (idx "### Active Goals" < idx "### Pending Mentions");
  check bool "continuity precedes board activity" true
    (idx "### Continuity" < idx "### Board Activity");
  check bool "context precedes live worktree delta" true
    (idx "### Context" < idx "### Live Worktree Delta")

let test_prompt_room_state_section () =
  let obs =
    { base_observation with
      unclaimed_task_count = 3;
      claimable_task_count = 3;
      failed_task_count = 1;
      active_agent_count = 5;
    }
  in
  let _sys, user = UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs () in
  check bool "has namespace state" true
    (let found =
       try
         ignore
           (Str.search_forward (Str.regexp_string "Namespace State") user 0);
         true
       with Not_found -> false
     in found)

let test_prompt_includes_claim_first_guidance () =
  let obs =
    { base_observation with
      unclaimed_task_count = 3;
      claimable_task_count = 3;
      active_agent_count = 5;
    }
  in
  let sys, user =
    UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs ()
  in
  check bool "system prompt explains auto-claim" true
    (contains_substring sys "Call keeper_task_claim with {}");
  check bool "user prompt adds immediate task move section" true
    (contains_substring user "### Immediate Task Move");
  check bool "user prompt explains no task_id needed" true
    (contains_substring user "Do not wait for keeper_tasks_list");
  check bool "user prompt prefers claim before browsing" true
    (contains_substring user "Prefer keeper_task_claim before keeper_board_list or keeper_shell");
  check bool "user prompt explains gh requires claim first" true
    (contains_substring user "If you need keeper_shell op=gh, claim first")

let test_prompt_omits_claim_first_guidance_when_no_claimable_tasks () =
  let obs =
    { base_observation with
      unclaimed_task_count = 3;
      claimable_task_count = 0;
      active_agent_count = 5;
    }
  in
  let sys, user =
    UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs ()
  in
  check bool "system prompt omits auto-claim for unclaimable backlog" false
    (contains_substring sys "Call keeper_task_claim with {}");
  check bool "user prompt omits immediate task move for unclaimable backlog" false
    (contains_substring user "### Immediate Task Move");
  check bool "namespace exposes zero matched availability" true
    (contains_substring user "Claimable tasks for this keeper: 0")

let test_prompt_omits_claim_first_guidance_when_task_claimed () =
  let current_task_id =
    match Masc_mcp.Keeper_id.Task_id.of_string "task-123" with
    | Ok value -> value
    | Error err -> fail ("task id parse failed: " ^ err)
  in
  let meta = { minimal_meta with current_task_id = Some current_task_id } in
  let obs =
    { base_observation with
      unclaimed_task_count = 3;
      claimable_task_count = 3;
      active_agent_count = 5;
    }
  in
  let _sys, user =
    UP.build_prompt ~base_path:"/test" ~meta ~observation:obs ()
  in
  check bool "no immediate task move section once task claimed" false
    (contains_substring user "### Immediate Task Move")

let test_prompt_omits_claim_first_guidance_when_claim_tool_unavailable () =
  let obs =
    { base_observation with
      unclaimed_task_count = 3;
      claimable_task_count = 3;
      active_agent_count = 5;
    }
  in
  let sys, user =
    UP.build_prompt ~base_path:"/test" ~meta:minimal_policy_meta ~observation:obs ()
  in
  check bool "system prompt omits auto-claim when tool unavailable" false
    (contains_substring sys "Call keeper_task_claim with {}");
  check bool "user prompt omits immediate task move when tool unavailable" false
    (contains_substring user "### Immediate Task Move")

let test_prompt_omits_claim_first_guidance_when_paused () =
  let meta = { minimal_meta with paused = true } in
  let obs =
    { base_observation with
      unclaimed_task_count = 3;
      claimable_task_count = 3;
      active_agent_count = 5;
    }
  in
  let sys, user =
    UP.build_prompt ~base_path:"/test" ~meta ~observation:obs ()
  in
  check bool "system prompt omits auto-claim while paused" false
    (contains_substring sys "Call keeper_task_claim with {}");
  check bool "user prompt omits immediate task move while paused" false
    (contains_substring user "### Immediate Task Move")

let test_work_discovery_nudge_uses_registered_keeper_tool_schemas () =
  let module Guidance = Masc_mcp.Keeper_tool_guidance in
  let social_meta =
    {
      minimal_meta with
      tool_access = Preset { preset = Social; also_allow = [] };
    }
  in
  let coding_meta =
    {
      minimal_meta with
      tool_access = Preset { preset = Coding; also_allow = [] };
    }
  in
  let social_allowed =
    Masc_mcp.Keeper_exec_tools.keeper_allowed_tool_names social_meta
  in
  let coding_allowed =
    Masc_mcp.Keeper_exec_tools.keeper_allowed_tool_names coding_meta
  in
  let social_guidance =
    Guidance.render_preferred_tools ~allowed_tool_names:social_allowed
  in
  let coding_guidance =
    Guidance.render_preferred_tools ~allowed_tool_names:coding_allowed
  in
  check bool "obsolete claim alias removed" false
    (source_file_contains "lib/keeper/keeper_agent_run.ml" "keeper_claim_task");
  check bool "social guidance includes claim schema when allowed" true
    (contains_substring social_guidance "`keeper_task_claim` {}");
  check bool "social guidance includes board post when allowed" true
    (contains_substring social_guidance "`keeper_board_post` { content:");
  check bool "social guidance includes web search when allowed" true
    (contains_substring social_guidance "`masc_web_search` { query:");
  check bool "social guidance omits bash outside preset" false
    (contains_substring social_guidance "`keeper_bash` { cmd:");
  check bool "social guidance omits worktree outside preset" false
    (contains_substring social_guidance "`masc_worktree_create` { task_id:");
  check bool "coding guidance includes bash schema" true
    (contains_substring coding_guidance "`keeper_bash` { cmd:");
  check bool "coding guidance includes web search schema" true
    (contains_substring coding_guidance "`masc_web_search` { query:");
  check bool "coding guidance includes worktree schema" true
    (contains_substring coding_guidance "`masc_worktree_create` { task_id:");
  check bool "legacy worktree branch_name schema removed" false
    (source_file_contains "lib/keeper/keeper_agent_run.ml" "branch_name:");
  check bool "tool-less runtime escape hatch removed from nudge" false
    (source_file_contains "lib/keeper/keeper_agent_run.ml" "NO_TOOL_CHANNEL");
  check bool "work discovery nudge warns gh needs claimed task" true
    (contains_substring
       (Option.value ~default:""
          (Guidance.render_gh_workflow ~allowed_tool_names:coding_allowed))
       "keeper_shell op=gh` derives repo context from the active task worktree/current_task_id");
  check bool "unknown tool guard names server-managed public lifecycle tools" true
    (contains_substring (Guidance.render_unknown_tool_guard ()) "masc_heartbeat");
  check bool "unknown tool guard warns against public board alias" true
    (contains_substring (Guidance.render_unknown_tool_guard ()) "masc_board_list");
  check bool "keeper_shell schema documents gh claim prerequisite" true
    (source_file_contains "lib/tool_shard.ml"
       "Requires an active claimed task/current_task_id");
  check bool "keeper_shell gh runtime allows sandbox fallback" true
    (source_file_contains "lib/keeper/keeper_shell_gh_context.ml"
       "task_id = \"(sandbox)\"");
  check bool
    "work discovery nudge avoids pre-filter policy tool names"
    false
    (source_file_contains "lib/keeper/keeper_agent_run.ml"
       "render_preferred_tools ~allowed_tool_names");
  check bool
    "claimed-task nudge avoids hard-coded execution tool names"
    false
    (source_file_contains "lib/keeper/keeper_agent_run.ml"
       "Use keeper_bash, keeper_shell, keeper_fs_read")

(* ---------- Config tests ---------- *)

let test_unified_turn_runtime_defaults () =
  with_env "MASC_KEEPER_UNIFIED_TEMP" "" (fun () ->
  with_env "MASC_KEEPER_UNIFIED_MAX_TOKENS" "" (fun () ->
    check (float 0.01) "unified temp default" 0.4
      (KC.keeper_unified_temperature ());
    (* Runtime param default is 65536 (safe fallback).
       In production, cascade.json overrides to 16384.
       This test verifies the runtime default, not cascade-resolved value. *)
    check int "unified max_tokens default" 65536
      (KC.keeper_unified_max_tokens ())
    (* max_turns is set in keeper_agent_run.ml from keeper runtime config. *)))

let test_meta_defaults_social_model () =
  check string "default social model" "bdi_speech_v1"
    minimal_meta.social_model

let test_social_model_registry_round_trip () =
  check (option string) "known model id resolves"
    (Some "bdi_speech_v1")
    (KSM.model_id_of_string "bdi_speech_v1"
    |> Option.map KSM.model_id_to_string);
  check (option string) "second model id resolves"
    (Some "magentic_ledger_v1")
    (KSM.model_id_of_string "magentic_ledger_v1"
    |> Option.map KSM.model_id_to_string);
  check bool "unknown model id rejected" true
    (Option.is_none (KSM.model_id_of_string "experimental_v99"));
  check bool "unknown model flagged as unrecognized" false
    (KSM.is_known_social_model "experimental_v99");
  check (option string) "unknown model exposes explicit fallback"
    (Some "bdi_speech_v1")
    (KSM.fallback_social_model "experimental_v99");
  check string "unknown model normalized to baseline" "bdi_speech_v1"
    (KSM.normalize_social_model "experimental_v99")

(* ---------- Metrics observation tests ---------- *)

let sample_prompt_metrics ?(system_prompt = "You are a keeper.")
    ?(dynamic_context = "")
    ?(user_message = "Check the board.")
    () =
  KAR.build_prompt_metrics ~system_prompt ~dynamic_context ~user_message

let sample_ctx_composition ?(system_prompt = "You are a keeper.")
    ?(dynamic_context = "")
    ?(user_message = "Check the board.")
    ?(actual_input_tokens : int option = None)
    () =
  KAR.build_ctx_composition_metrics
    ~system_prompt
    ~dynamic_context
    ~memory_context:""
    ~temporal_context:""
    ~user_message
    ~history_messages:[]
    ~actual_input_tokens

let sample_tool_surface_metrics () : Masc_mcp.Keeper_agent_run.tool_surface_metrics =
  {
    turn_lane = "tool_optional";
    tool_surface_class = "mixed";
    tool_requirement = Masc_mcp.Keeper_agent_tool_surface.Optional;
    visible_tool_count = 0;
    tool_gate_enabled = false;
    tool_surface_fallback_used = false;
    required_tool_names = [];
    missing_required_tool_names = [];
    config_root = "";
    cascade_config_path = None;
    gemini_mcp_disabled = false;
    approval_mode_effective = None;
    approval_mode_derived = false;
  }
let make_run_result ~text ~tools ~model ~input_tok ~output_tok
    ?(usage_reported = true)
    ?(cache_creation_tokens = 0)
    ?(cache_read_tokens = 0)
    ?(tool_calls = [])
    ?proof
    ?trace_ref
    ?run_validation
    ?cascade_observation
    () : Masc_mcp.Keeper_agent_run.run_result =
  {
    response_text = text;
    model_used = model;
    prompt_metrics = sample_prompt_metrics ();
    ctx_composition =
      sample_ctx_composition
        ~actual_input_tokens:(if input_tok > 0 then Some input_tok else None)
        ();
    cascade_observation;
    turn_count = 1;
    tool_calls_made = List.length tools;
    usage =
      {
        input_tokens = input_tok;
        output_tokens = output_tok;
        cache_creation_input_tokens = cache_creation_tokens;
        cache_read_input_tokens = cache_read_tokens;
        cost_usd = None;
      };
    usage_reported;
    tools_used = tools;
    tool_calls;
    checkpoint = None;
    proof;
    trace_ref;
    run_validation;
    stop_reason = Masc_mcp.Oas_worker.Completed;
    inference_telemetry = None;
    tool_surface = sample_tool_surface_metrics ();
  }

let sample_cdal_proof ?(raw_evidence_refs = []) () : Agent_sdk.Cdal_proof.t =
  {
    schema_version = Agent_sdk.Cdal_proof.schema_version_current;
    run_id = "keeper-metrics-proof-test";
    contract_id = "md5:test";
    requested_execution_mode = Execute;
    effective_execution_mode = Execute;
    mode_decision_source = "passthrough";
    risk_class = Agent_sdk.Risk_class.Low;
    provider_snapshot =
      {
        provider_name = "test";
        model_id = "test-model";
        api_version = None;
      };
    capability_snapshot =
      {
        tools = [ "read"; "write" ];
        mcp_servers = [];
        max_turns = 10;
        max_tokens = Some 4096;
        thinking_enabled = None;
      };
    tool_trace_refs = [];
    raw_evidence_refs;
    checkpoint_ref = None;
    result_status = Completed;
    started_at = 1000.0;
    ended_at = 1001.0;
    scope = None;
  }

let test_prompt_metrics_fingerprint_is_deterministic () =
  let metrics_a =
    sample_prompt_metrics ~system_prompt:"sys" ~dynamic_context:"ctx"
      ~user_message:"user" ()
  in
  let metrics_b =
    sample_prompt_metrics ~system_prompt:"sys" ~dynamic_context:"ctx"
      ~user_message:"user" ()
  in
  let metrics_c =
    sample_prompt_metrics ~system_prompt:"sys" ~dynamic_context:"ctx"
      ~user_message:"changed user" ()
  in
  check string "same inputs -> same fingerprint"
    metrics_a.fingerprint metrics_b.fingerprint;
  check bool "different prompt inputs -> different fingerprint" true
    (metrics_a.fingerprint <> metrics_c.fingerprint);
  check int "cacheable tokens follow system prompt"
    metrics_a.system_prompt_segment.estimated_tokens
    metrics_a.estimated_cacheable_tokens;
  check int "total estimated tokens are additive"
    (metrics_a.system_prompt_segment.estimated_tokens
     + metrics_a.dynamic_context_segment.estimated_tokens
     + metrics_a.user_message_segment.estimated_tokens)
    metrics_a.estimated_total_tokens

let test_metrics_text_response () =
  let result =
    make_run_result ~text:"I checked the board." ~tools:[]
      ~model:"test-model" ~input_tok:100 ~output_tok:50 ()
  in
  let updated =
    UM.update_metrics_from_result minimal_meta ~latency_ms:200
      ~observation:base_observation result
  in
  check int "total_turns +1" (minimal_meta.runtime.usage.total_turns + 1) updated.runtime.usage.total_turns;
  check int "proactive_count +1"
    (minimal_meta.runtime.proactive_rt.count_total + 1) updated.runtime.proactive_rt.count_total;
  check int "proactive visible_count +1"
    (minimal_meta.runtime.proactive_rt.visible_count_total + 1)
    updated.runtime.proactive_rt.visible_count_total;
  check bool "proactive outcome text" true
    (updated.runtime.proactive_rt.last_outcome
     = Masc_mcp.Keeper_types.Proactive_text_response);
  check int "no autonomous action" minimal_meta.runtime.autonomous_action_count
    updated.runtime.autonomous_action_count;
  check int "input tokens" (minimal_meta.runtime.usage.total_input_tokens + 100) updated.runtime.usage.total_input_tokens;
  check int "output tokens" (minimal_meta.runtime.usage.total_output_tokens + 50) updated.runtime.usage.total_output_tokens

let test_metrics_idle_seconds_gauge_records_observation () =
  let idle_seconds = 19_006 in
  let result =
    make_run_result ~text:"I checked the board." ~tools:[]
      ~model:"test-model" ~input_tok:100 ~output_tok:50 ()
  in
  let observation = { base_observation with idle_seconds = idle_seconds } in
  ignore
    (UM.update_metrics_from_result minimal_meta ~latency_ms:200
       ~observation result);
  check (option (float 0.001)) "success idle seconds gauge"
    (Some (float_of_int idle_seconds))
    (Masc_mcp.Prometheus.get_metric_value
       Masc_mcp.Prometheus.metric_keeper_idle_seconds
       ~labels:[ ("keeper_name", minimal_meta.name) ]
       ());
  let failure_idle_seconds = idle_seconds + 1 in
  let failure_observation =
    { base_observation with idle_seconds = failure_idle_seconds }
  in
  ignore
    (UM.update_metrics_from_failure minimal_meta ~latency_ms:100
       ~observation:failure_observation ~reason:"synthetic failure" ());
  check (option (float 0.001)) "failure idle seconds gauge"
    (Some (float_of_int failure_idle_seconds))
    (Masc_mcp.Prometheus.get_metric_value
       Masc_mcp.Prometheus.metric_keeper_idle_seconds
       ~labels:[ ("keeper_name", minimal_meta.name) ]
       ())

let test_metrics_surface_model_prefers_successful_cascade_label () =
  let selected_label = "llama:qwen3.5-3b-a3b-ud-q8-xl" in
  let result =
    make_run_result ~text:"I checked the board." ~tools:[]
      ~model:"qwen3.5:27b-nvfp4" ~input_tok:100 ~output_tok:50
      ~cascade_observation:
        {
          Masc_mcp.Oas_worker.cascade_name =
            Masc_mcp.Keeper_cascade_profile.Runtime_name
              Masc_mcp.Keeper_config.default_cascade_name;
          strategy = Some "round_robin";
          configured_labels = [ "llama:auto" ];
          candidate_models =
            [ "llama:qwen3.5-35b-a3b-ud-q8-xl"; selected_label ];
          primary_model = Some "llama:qwen3.5-35b-a3b-ud-q8-xl";
          selected_model = Some "qwen3.5:27b-nvfp4";
          selected_model_raw = Some "qwen3.5:27b-nvfp4";
          selected_index = None;
          fallback_hops = Some 1;
          fallback_applied = true;
          attempts =
            [
              {
                Masc_mcp.Oas_worker.attempt_index = 0;
                model_id = "qwen3.5-35b-a3b-ud-q8-xl";
                model_label = Some "llama:qwen3.5-35b-a3b-ud-q8-xl";
                latency_ms = None;
                error = Some "HTTP 503";
              };
              {
                attempt_index = 1;
                model_id = "qwen3.5-3b-a3b-ud-q8-xl";
                model_label = Some selected_label;
                latency_ms = Some 187;
                error = None;
              };
            ];
          fallback_events =
            [
              {
                from_model_id = "qwen3.5-35b-a3b-ud-q8-xl";
                from_model_label = Some "llama:qwen3.5-35b-a3b-ud-q8-xl";
                to_model_id = "qwen3.5-3b-a3b-ud-q8-xl";
                to_model_label = Some selected_label;
                reason = "HTTP 503";
              };
            ];
          attempt_details_available = true;
          attempt_details_source = "oas_metrics_callbacks";
        }
      ()
  in
  let updated =
    UM.update_metrics_from_result minimal_meta ~latency_ms:200
      ~observation:base_observation result
  in
  check string "helper canonicalizes surface model" selected_label
    (KAR.surface_model_used result);
  check string "last_model_used stores canonical surface label" selected_label
    updated.runtime.usage.last_model_used

(* #9953: [surface_resolved_model_id] returns the concrete model_id from
   the last cascade attempt, even when [model_label] is populated. This
   lets analysts correlate ["context_max"] with the actual resolved
   variant instead of the auto label. *)
let test_metrics_resolved_model_id_prefers_last_attempt_id () =
  let result =
    make_run_result ~text:"I checked the board." ~tools:[]
      ~model:"claude-opus-4-6" ~input_tok:100 ~output_tok:50
      ~cascade_observation:
        {
          Masc_mcp.Oas_worker.cascade_name =
            Masc_mcp.Keeper_cascade_profile.Runtime_name
              Masc_mcp.Keeper_config.default_cascade_name;
          strategy = Some "round_robin";
          configured_labels = [ "claude_code:auto" ];
          candidate_models =
            [ "claude-sonnet-4-6"; "claude-opus-4-6" ];
          primary_model = Some "claude-sonnet-4-6";
          selected_model = Some "claude-opus-4-6";
          selected_model_raw = Some "claude-opus-4-6";
          selected_index = None;
          fallback_hops = Some 1;
          fallback_applied = true;
          attempts =
            [
              {
                Masc_mcp.Oas_worker.attempt_index = 0;
                model_id = "claude-sonnet-4-6";
                model_label = Some "claude_code:auto";
                latency_ms = None;
                error = Some "HTTP 503";
              };
              {
                attempt_index = 1;
                model_id = "claude-opus-4-6";
                model_label = Some "claude_code:auto";
                latency_ms = Some 187;
                error = None;
              };
            ];
          fallback_events = [];
          attempt_details_available = true;
          attempt_details_source = "oas_metrics_callbacks";
        }
      ()
  in
  check string "surface_model_used returns cascade label"
    "claude_code:auto" (KAR.surface_model_used result);
  check string "surface_resolved_model_id returns concrete variant id"
    "claude-opus-4-6" (KAR.surface_resolved_model_id result)

(* #9953: when no cascade observation is available, resolved id falls
   back to the raw [model_used] reported by the provider, not to the
   empty string. This preserves signal for non-cascade keeper turns. *)
let test_metrics_resolved_model_id_fallback_to_model_used () =
  let result =
    make_run_result ~text:"ok" ~tools:[] ~model:"claude-opus-4-6"
      ~input_tok:10 ~output_tok:5 ()
  in
  check string "surface_resolved_model_id falls back to model_used"
    "claude-opus-4-6" (KAR.surface_resolved_model_id result)

let test_metrics_tool_response () =
  let result =
    make_run_result ~text:"" ~tools:["keeper_board_post"; "keeper_board_comment"]
      ~model:"test-model" ~input_tok:200 ~output_tok:80 ()
  in
  let updated =
    UM.update_metrics_from_result minimal_meta ~latency_ms:500
      ~observation:base_observation result
  in
  check int "proactive_count +1" (minimal_meta.runtime.proactive_rt.count_total + 1)
    updated.runtime.proactive_rt.count_total;
  check int "proactive visible_count +1"
    (minimal_meta.runtime.proactive_rt.visible_count_total + 1)
    updated.runtime.proactive_rt.visible_count_total;
  check bool "proactive outcome tool" true
    (updated.runtime.proactive_rt.last_outcome
     = Masc_mcp.Keeper_types.Proactive_tool_use);
  check int "autonomous_action +2" (minimal_meta.runtime.autonomous_action_count + 2)
    updated.runtime.autonomous_action_count;
  check bool "last autonomous action ts updated" true
    (String.trim updated.runtime.last_autonomous_action_at <> "");
  check int "latency_ms" 500 updated.runtime.usage.last_latency_ms

let test_metrics_noop_response () =
  let result =
    make_run_result ~text:"" ~tools:[]
      ~model:"test-model" ~input_tok:50 ~output_tok:10 ()
  in
  let updated =
    UM.update_metrics_from_result minimal_meta ~latency_ms:100
      ~observation:base_observation result
  in
  check int "proactive_count +1"
    (minimal_meta.runtime.proactive_rt.count_total + 1)
    updated.runtime.proactive_rt.count_total;
  check int "proactive visible_count unchanged"
    minimal_meta.runtime.proactive_rt.visible_count_total
    updated.runtime.proactive_rt.visible_count_total;
  check bool "proactive outcome silent" true
    (updated.runtime.proactive_rt.last_outcome
     = Masc_mcp.Keeper_types.Proactive_silent);
  check int "autonomous unchanged" minimal_meta.runtime.autonomous_action_count
    updated.runtime.autonomous_action_count;
  check int "total_turns +1" (minimal_meta.runtime.usage.total_turns + 1) updated.runtime.usage.total_turns

let test_metrics_observation_only_tools_are_noop () =
  let observation_only =
    [
      Masc_mcp.Tool_name.Keeper.to_string Masc_mcp.Tool_name.Keeper.Board_list;
      Masc_mcp.Tool_name.Keeper.to_string
        Masc_mcp.Tool_name.Keeper.Context_status;
      Masc_mcp.Tool_name.Keeper.to_string
        Masc_mcp.Tool_name.Keeper.Tool_search;
      Masc_mcp.Tool_name.Keeper.to_string Masc_mcp.Tool_name.Keeper.Tasks_list;
      Masc_mcp.Tool_name.Keeper.to_string Masc_mcp.Tool_name.Keeper.Task_claim;
    ]
  in
  let result =
    make_run_result ~text:"" ~tools:observation_only
      ~model:"test-model" ~input_tok:50 ~output_tok:10 ()
  in
  let updated =
    UM.update_metrics_from_result minimal_meta ~latency_ms:100
      ~observation:base_observation result
  in
  check bool "tools are not substantive" false
    (UM.has_substantive_tool_calls observation_only);
  check int "proactive visible_count unchanged"
    minimal_meta.runtime.proactive_rt.visible_count_total
    updated.runtime.proactive_rt.visible_count_total;
  check int "autonomous action unchanged"
    minimal_meta.runtime.autonomous_action_count
    updated.runtime.autonomous_action_count;
  check int "autonomous tool turn unchanged"
    minimal_meta.runtime.autonomous_tool_turn_count
    updated.runtime.autonomous_tool_turn_count;
  check int "noop turn increments"
    (minimal_meta.runtime.noop_turn_count + 1)
    updated.runtime.noop_turn_count

let test_metrics_execution_tools_are_substantive () =
  check bool "claim alone is not execution progress" false
    (UM.has_substantive_tool_calls [ "keeper_task_claim" ]);
  check bool "task listing is not execution progress" false
    (UM.has_substantive_tool_calls [ "keeper_tasks_list" ]);
  check bool "task creation is execution progress" true
    (UM.has_substantive_tool_calls [ "keeper_task_create" ]);
  check bool "masc task creation is execution progress" true
    (UM.has_substantive_tool_calls [ "masc_add_task" ]);
  check bool "masc batch task creation is execution progress" true
    (UM.has_substantive_tool_calls [ "masc_batch_add_tasks" ]);
  check bool "force release is execution progress" true
    (UM.has_substantive_tool_calls [ "keeper_task_force_release" ]);
  check bool "bash is execution progress" true
    (UM.has_substantive_tool_calls [ "keeper_bash" ]);
  check bool "completion is execution progress" true
    (UM.has_substantive_tool_calls [ "keeper_task_submit_for_verification" ])

let sample_run_ref : Agent_sdk.Raw_trace.run_ref = {
  worker_run_id = "test-run"; path = "/tmp/test.jsonl";
  start_seq = 0; end_seq = 5; agent_name = "test"; session_id = None;
}

let test_metrics_validated_evidence_counts_as_visible () =
  let validation : Agent_sdk.Raw_trace.run_validation = {
    run_ref = sample_run_ref; ok = true;
    checks = []; evidence = ["tool_paired:keeper_fs_read"];
    paired_tool_result_count = 1; has_file_write = false;
    verification_pass_after_file_write = false;
    final_text = None; tool_names = ["keeper_fs_read"];
    stop_reason = None; failure_reason = None;
  } in
  let result =
    make_run_result ~text:"" ~tools:[]
      ~model:"test-model" ~input_tok:50 ~output_tok:10
      ~run_validation:validation ()
  in
  let updated =
    UM.update_metrics_from_result minimal_meta ~latency_ms:100
      ~observation:base_observation result
  in
  check int "proactive visible_count +1"
    (minimal_meta.runtime.proactive_rt.visible_count_total + 1)
    updated.runtime.proactive_rt.visible_count_total;
  check bool "validated evidence outcome is tool_use" true
    (updated.runtime.proactive_rt.last_outcome
     = Masc_mcp.Keeper_types.Proactive_tool_use);
  check string "validated evidence preview"
    "(validated evidence: keeper_fs_read)"
    updated.runtime.proactive_rt.last_preview;
  check int "noop unchanged"
    minimal_meta.runtime.noop_turn_count
    updated.runtime.noop_turn_count;
  check int "autonomous action unchanged"
    minimal_meta.runtime.autonomous_action_count
    updated.runtime.autonomous_action_count;
  check string "last autonomous action ts unchanged"
    minimal_meta.runtime.last_autonomous_action_at
    updated.runtime.last_autonomous_action_at;
  check bool "last_reason contains validated_evidence" true
    (String.length updated.runtime.proactive_rt.last_reason > 0
     && (let r = updated.runtime.proactive_rt.last_reason in
         try ignore (Str.search_forward (Str.regexp_string "validated_evidence") r 0); true
         with Not_found -> false))

let test_metrics_failed_validation_does_not_count_as_visible () =
  let validation : Agent_sdk.Raw_trace.run_validation = {
    run_ref = sample_run_ref; ok = false;
    checks = []; evidence = [];
    paired_tool_result_count = 0; has_file_write = false;
    verification_pass_after_file_write = false;
    final_text = None; tool_names = [];
    stop_reason = None; failure_reason = Some "validation failed";
  } in
  let result =
    make_run_result ~text:"" ~tools:[]
      ~model:"test-model" ~input_tok:50 ~output_tok:10
      ~run_validation:validation ()
  in
  let updated =
    UM.update_metrics_from_result minimal_meta ~latency_ms:100
      ~observation:base_observation result
  in
  check int "proactive visible_count unchanged"
    minimal_meta.runtime.proactive_rt.visible_count_total
    updated.runtime.proactive_rt.visible_count_total;
  check bool "outcome is silent" true
    (updated.runtime.proactive_rt.last_outcome
     = Masc_mcp.Keeper_types.Proactive_silent)

let test_metrics_file_write_evidence_counts_as_visible () =
  let validation : Agent_sdk.Raw_trace.run_validation = {
    run_ref = sample_run_ref; ok = true;
    checks = []; evidence = [];
    paired_tool_result_count = 0; has_file_write = true;
    verification_pass_after_file_write = true;
    final_text = None; tool_names = ["keeper_fs_write"];
    stop_reason = None; failure_reason = None;
  } in
  let result =
    make_run_result ~text:"" ~tools:[]
      ~model:"test-model" ~input_tok:50 ~output_tok:10
      ~run_validation:validation ()
  in
  let updated =
    UM.update_metrics_from_result minimal_meta ~latency_ms:100
      ~observation:base_observation result
  in
  check int "proactive visible_count +1"
    (minimal_meta.runtime.proactive_rt.visible_count_total + 1)
    updated.runtime.proactive_rt.visible_count_total;
  check bool "file write evidence outcome is tool_use" true
    (updated.runtime.proactive_rt.last_outcome
     = Masc_mcp.Keeper_types.Proactive_tool_use);
  check string "file write evidence preview"
    "(validated evidence: file_write)"
    updated.runtime.proactive_rt.last_preview;
  check int "noop unchanged"
    minimal_meta.runtime.noop_turn_count
    updated.runtime.noop_turn_count;
  check int "autonomous action unchanged"
    minimal_meta.runtime.autonomous_action_count
    updated.runtime.autonomous_action_count;
  check string "last autonomous action ts unchanged"
    minimal_meta.runtime.last_autonomous_action_at
    updated.runtime.last_autonomous_action_at

let test_metrics_heartbeat_only_tool_response_is_maintenance_only () =
  let result =
    make_run_result ~text:"" ~tools:[]
      ~model:"test-model" ~input_tok:40 ~output_tok:0 ()
  in
  let updated =
    UM.update_metrics_from_result minimal_meta ~latency_ms:80
      ~observation:base_observation result
  in
  check int "proactive_count +1"
    (minimal_meta.runtime.proactive_rt.count_total + 1)
    updated.runtime.proactive_rt.count_total;
  check int "proactive visible_count unchanged"
    minimal_meta.runtime.proactive_rt.visible_count_total
    updated.runtime.proactive_rt.visible_count_total;
  check bool "heartbeat-only outcome stays silent" true
    (updated.runtime.proactive_rt.last_outcome
     = Masc_mcp.Keeper_types.Proactive_silent);
  check int "autonomous action unchanged"
    minimal_meta.runtime.autonomous_action_count
    updated.runtime.autonomous_action_count;
  check int "autonomous tool turn unchanged"
    minimal_meta.runtime.autonomous_tool_turn_count
    updated.runtime.autonomous_tool_turn_count;
  check int "noop turn increments"
    (minimal_meta.runtime.noop_turn_count + 1)
    updated.runtime.noop_turn_count

let test_metrics_reactive_turn_does_not_mutate_proactive_runtime () =
  let reactive_observation =
    { base_observation with
      pending_mentions = [ ("alice", "@test-keeper check this") ]
    }
  in
  let result =
    make_run_result ~text:"On it." ~tools:[]
      ~model:"test-model" ~input_tok:90 ~output_tok:30 ()
  in
  let updated =
    UM.update_metrics_from_result minimal_meta ~latency_ms:120
      ~observation:reactive_observation result
  in
  check int "proactive_count unchanged on reactive turn"
    minimal_meta.runtime.proactive_rt.count_total
    updated.runtime.proactive_rt.count_total;
  check int "proactive visible_count unchanged on reactive turn"
    minimal_meta.runtime.proactive_rt.visible_count_total
    updated.runtime.proactive_rt.visible_count_total;
  check bool "proactive outcome unchanged on reactive turn" true
    (minimal_meta.runtime.proactive_rt.last_outcome
     = updated.runtime.proactive_rt.last_outcome)

let test_silent_proactive_cycle_advances_cooldown_anchor () =
  let result =
    make_run_result ~text:"" ~tools:[]
      ~model:"test-model" ~input_tok:40 ~output_tok:10 ()
  in
  let updated =
    UM.update_metrics_from_result
      { minimal_meta with
        proactive = { minimal_meta.proactive with enabled = true; cooldown_sec = 300 }
      }
      ~latency_ms:80
      ~observation:base_observation
      result
  in
  check bool "silent proactive updates last_ts" true
    (updated.runtime.proactive_rt.last_ts > 0.0);
  check bool "silent proactive leaves last_visible_ts untouched" true
    (updated.runtime.proactive_rt.last_visible_ts = 0.0);
  check bool "cooldown blocks immediate rerun after silent cycle" false
    (WO.should_run_keeper_cycle ~meta:updated base_observation)

let test_metrics_reactive_failure_does_not_mutate_proactive_runtime () =
  let reactive_observation =
    { base_observation with
      pending_board_events = [ sample_board_event ]
    }
  in
  let updated =
    UM.update_metrics_from_failure minimal_meta ~latency_ms:90
      ~observation:reactive_observation ~reason:"reactive failure" ()
  in
  check int "reactive failure leaves proactive_count unchanged"
    minimal_meta.runtime.proactive_rt.count_total
    updated.runtime.proactive_rt.count_total;
  check int "reactive failure leaves visible_count unchanged"
    minimal_meta.runtime.proactive_rt.visible_count_total
    updated.runtime.proactive_rt.visible_count_total;
  check bool "reactive failure leaves last_ts unchanged" true
    (updated.runtime.proactive_rt.last_ts
     = minimal_meta.runtime.proactive_rt.last_ts);
  check bool "reactive failure leaves last_outcome unchanged" true
    (updated.runtime.proactive_rt.last_outcome
     = minimal_meta.runtime.proactive_rt.last_outcome)

let test_meta_migration_does_not_infer_visible_proactive_fields () =
  let legacy_json =
    `Assoc
      [
        ("name", `String "legacy-keeper");
        ("goal", `String "legacy goal");
        ("trace_id", `String "legacy-trace");
        ("proactive_count_total", `Int 7);
        ("last_proactive_ts", `Float 1234.0);
      ]
  in
  match Masc_test_deps.meta_of_json_fixture legacy_json with
  | Error e -> fail ("legacy meta_of_json failed: " ^ e)
  | Ok meta ->
      check int "legacy visible count stays unknown->0" 0
        meta.runtime.proactive_rt.visible_count_total;
      check (float 0.001) "legacy visible ts stays unknown->0" 0.0
        meta.runtime.proactive_rt.last_visible_ts;
      check bool "legacy outcome unknown" true
        (meta.runtime.proactive_rt.last_outcome
         = Masc_mcp.Keeper_types.Proactive_unknown)

let test_append_metrics_snapshot_includes_cascade_observation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      let validation : Agent_sdk.Raw_trace.run_validation = {
        run_ref = sample_run_ref; ok = true;
        checks = []; evidence = ["tool_paired:keeper_board_list"];
        paired_tool_result_count = 1; has_file_write = false;
        verification_pass_after_file_write = false;
        final_text = Some "Observed";
        tool_names = ["keeper_board_list"];
        stop_reason = Some "completed"; failure_reason = None;
      } in
      let result =
        {
          (make_run_result ~text:"Observed" ~tools:[]
             ~model:"qwen3.5:27b-nvfp4" ~input_tok:40 ~output_tok:20 ())
          with
          prompt_metrics =
            sample_prompt_metrics
              ~system_prompt:"You are a keeper focused on triage."
              ~dynamic_context:"Pending mentions: 2"
              ~user_message:"Review the board and decide what to do next."
              ();
          trace_ref = Some sample_run_ref;
          run_validation = Some validation;
          cascade_observation =
            Some
              {
                Masc_mcp.Oas_worker.cascade_name =
                  Masc_mcp.Keeper_cascade_profile.Runtime_name
                    Masc_mcp.Keeper_config.default_cascade_name;
                strategy = Some "round_robin";
                configured_labels = [ "llama:auto" ];
                candidate_models =
                  [
                    "llama:qwen3.5-35b-a3b-ud-q8-xl";
                    "llama:qwen3.5-3b-a3b-ud-q8-xl";
                  ];
                primary_model = Some "llama:qwen3.5-35b-a3b-ud-q8-xl";
                selected_model = Some "qwen3.5:27b-nvfp4";
                selected_model_raw = Some "qwen3.5:27b-nvfp4";
                selected_index = Some 1;
                fallback_hops = Some 1;
                fallback_applied = true;
                attempts =
                  [
                    {
                      Masc_mcp.Oas_worker.attempt_index = 0;
                      model_id = "qwen3.5-35b-a3b-ud-q8-xl";
                      model_label = Some "llama:qwen3.5-35b-a3b-ud-q8-xl";
                      latency_ms = None;
                      error = Some "HTTP 503";
                    };
                    {
                      attempt_index = 1;
                      model_id = "qwen3.5-3b-a3b-ud-q8-xl";
                      model_label = Some "llama:qwen3.5-3b-a3b-ud-q8-xl";
                      latency_ms = Some 187;
                      error = None;
                    };
                  ];
                fallback_events =
                  [
                    {
                      from_model_id = "qwen3.5-35b-a3b-ud-q8-xl";
                      from_model_label = Some "llama:qwen3.5-35b-a3b-ud-q8-xl";
                      to_model_id = "qwen3.5-3b-a3b-ud-q8-xl";
                      to_model_label = Some "llama:qwen3.5-3b-a3b-ud-q8-xl";
                      reason = "HTTP 503";
                    };
                  ];
                attempt_details_available = true;
                attempt_details_source = "oas_metrics_callbacks";
              };
        }
      in
      let deliberation_execution =
        KD.baseline_execution_result
          (KD.empty_world_observation ~keeper_name:minimal_meta.name)
      in
      let completed_before =
        Masc_mcp.Prometheus.metric_value_or_zero
          Masc_mcp.Prometheus.metric_keeper_turn_completed
          ~labels:[("keeper_name", minimal_meta.name)]
          ()
      in
      UM.append_metrics_snapshot
        ~config
        ~meta:minimal_meta
        ~observation:base_observation
        ~result
        ~latency_ms:123
        ~turn_cost:0.01
        ~turn_generation:1
        ~channel:"turn"
        ~snapshot_source:"test"
        ~context_ratio:0.1
        ~context_tokens:10
        ~context_max:100
        ~message_count:2
        ~compaction:
          {
            Masc_mcp.Keeper_exec_context.applied = false;
            attempted = false;
            failure_reason = None;
            trigger = None;
            decision = Masc_mcp.Keeper_exec_context.Blocked_below_thresholds;
            before_tokens = 0;
            after_tokens = 0;
            saved_tokens = 0;
          }
        ~handoff_json:None
        ~deliberation_execution
        ();
      let completed_after =
        Masc_mcp.Prometheus.metric_value_or_zero
          Masc_mcp.Prometheus.metric_keeper_turn_completed
          ~labels:[("keeper_name", minimal_meta.name)]
          ()
      in
      check (float 0.0001) "turn completed counter increments"
        (completed_before +. 1.0)
        completed_after;
      let metrics_store =
        Masc_mcp.Keeper_types.keeper_metrics_store config minimal_meta.name
      in
      let line =
        match Dated_jsonl.read_recent_lines metrics_store 1 with
        | [ line ] -> line
        | _ -> fail "expected one metrics line"
      in
      let json = Yojson.Safe.from_string line in
      check string "metrics snapshot uses canonical surface model"
        "llama:qwen3.5-3b-a3b-ud-q8-xl"
        Yojson.Safe.Util.(json |> member "model_used" |> to_string);
      check bool "cascade field present" true
        Yojson.Safe.Util.(json |> member "cascade" <> `Null);
      check string "cascade name persisted" Masc_mcp.Keeper_config.default_cascade_name
        Yojson.Safe.Util.(
          json |> member "cascade" |> member "cascade_name" |> to_string);
      check bool "fallback applied persisted" true
        Yojson.Safe.Util.(
          json |> member "cascade" |> member "fallback_applied" |> to_bool);
      check int "attempts persisted" 2
        Yojson.Safe.Util.(
          json |> member "cascade" |> member "attempts" |> to_list
          |> List.length);
      check bool "attempt details available persisted" true
        Yojson.Safe.Util.(
          json |> member "cascade" |> member "attempt_details_available" |> to_bool);
      check string "attempt detail boundary persisted" "oas_metrics_callbacks"
        Yojson.Safe.Util.(
          json |> member "cascade" |> member "attempt_details_source" |> to_string);
      check string "action source persisted" "baseline"
        Yojson.Safe.Util.(json |> member "action_source" |> to_string);
      check string "nested deliberation execution source persisted" "baseline"
        Yojson.Safe.Util.(
          json |> member "deliberation_execution" |> member "action_source"
          |> to_string);
      check string "top-level prompt fingerprint persisted"
        result.prompt_metrics.fingerprint
        Yojson.Safe.Util.(json |> member "prompt_fingerprint" |> to_string);
      check int "prompt total tokens persisted"
        result.prompt_metrics.estimated_total_tokens
        Yojson.Safe.Util.(
          json |> member "prompt" |> member "estimated_total_tokens"
          |> to_int);
      check int "system prompt bytes persisted"
        result.prompt_metrics.system_prompt_segment.bytes
        Yojson.Safe.Util.(
          json |> member "prompt" |> member "system_prompt" |> member "bytes"
          |> to_int);
      check string "user message fingerprint persisted"
        (Option.value ~default:""
           result.prompt_metrics.user_message_segment.fingerprint)
        Yojson.Safe.Util.(
          json |> member "prompt" |> member "user_message"
          |> member "fingerprint" |> to_string);
      check int "ctx composition known tokens persisted"
        result.ctx_composition.estimated_known_tokens
        Yojson.Safe.Util.(
          json |> member "ctx_composition" |> member "estimated_known_tokens"
          |> to_int);
      check int "ctx composition display total persisted"
        result.ctx_composition.display_total_tokens
        Yojson.Safe.Util.(
          json |> member "ctx_composition" |> member "display_total_tokens"
          |> to_int);
      check bool "ctx composition unattributed bucket persisted" true
        Yojson.Safe.Util.(
          json |> member "ctx_composition" |> member "segments"
          |> member "unattributed" <> `Null);
      check string "trace ref worker run id persisted"
        sample_run_ref.worker_run_id
        Yojson.Safe.Util.(
          json |> member "trace_ref" |> member "worker_run_id" |> to_string);
      check bool "run validation persisted" true
        Yojson.Safe.Util.(json |> member "run_validation" <> `Null);
      check bool "run validation ok persisted" true
        Yojson.Safe.Util.(
          json |> member "run_validation" |> member "ok" |> to_bool))

let test_append_metrics_snapshot_treats_validated_evidence_as_tool_use () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      let validation : Agent_sdk.Raw_trace.run_validation = {
        run_ref = sample_run_ref; ok = true;
        checks = []; evidence = ["tool_paired:keeper_fs_read"];
        paired_tool_result_count = 1; has_file_write = false;
        verification_pass_after_file_write = false;
        final_text = None; tool_names = ["keeper_fs_read"];
        stop_reason = None; failure_reason = None;
      } in
      let result =
        make_run_result ~text:"" ~tools:[]
          ~model:"openai:qwen3.5-35b" ~input_tok:40 ~output_tok:20
          ~run_validation:validation ()
      in
      UM.append_metrics_snapshot
        ~config
        ~meta:minimal_meta
        ~observation:base_observation
        ~result
        ~latency_ms:123
        ~turn_cost:0.01
        ~turn_generation:1
        ~channel:"scheduled_autonomous"
        ~snapshot_source:"test"
        ~context_ratio:0.1
        ~context_tokens:10
        ~context_max:100
        ~message_count:2
        ~compaction:
          {
            Masc_mcp.Keeper_exec_context.applied = false;
            attempted = false;
            failure_reason = None;
            trigger = None;
            decision = Masc_mcp.Keeper_exec_context.Blocked_below_thresholds;
            before_tokens = 0;
            after_tokens = 0;
            saved_tokens = 0;
          }
        ~handoff_json:None
        ();
      let metrics_store =
        Masc_mcp.Keeper_types.keeper_metrics_store config minimal_meta.name
      in
      let line =
        match Dated_jsonl.read_recent_lines metrics_store 1 with
        | [ line ] -> line
        | _ -> fail "expected one metrics line"
      in
      let json = Yojson.Safe.from_string line in
      check string "turn mode persisted as tool_use" "tool_use"
        Yojson.Safe.Util.(json |> member "turn_mode" |> to_string);
      check bool "work_kind removed from snapshot" true
        (match Yojson.Safe.Util.(json |> member "work_kind") with
         | `Null -> true
         | _ -> false);
      check string "scheduled autonomous outcome persisted as tool_use"
        "tool_use"
        Yojson.Safe.Util.(
          json |> member "scheduled_autonomous_outcome" |> to_string))

let test_append_metrics_snapshot_counts_only_mode_violation_refs () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      let proof =
        sample_cdal_proof
          ~raw_evidence_refs:
            [
              "proof-store://keeper-metrics-proof-test/evidence/effects.json";
              "proof-store://keeper-metrics-proof-test/evidence/mode_violations.json";
              "proof-store://keeper-metrics-proof-test/evidence/review_warning.json";
            ]
          ()
      in
      let result =
        make_run_result
          ~text:""
          ~tools:[]
          ~model:"openai:qwen3.5-35b"
          ~input_tok:40
          ~output_tok:20
          ~proof
          ()
      in
      UM.append_metrics_snapshot
        ~config
        ~meta:minimal_meta
        ~observation:base_observation
        ~result
        ~latency_ms:123
        ~turn_cost:0.01
        ~turn_generation:1
        ~channel:"turn"
        ~snapshot_source:"test"
        ~context_ratio:0.1
        ~context_tokens:10
        ~context_max:100
        ~message_count:2
        ~compaction:
          {
            Masc_mcp.Keeper_exec_context.applied = false;
            attempted = false;
            failure_reason = None;
            trigger = None;
            decision = Masc_mcp.Keeper_exec_context.Blocked_below_thresholds;
            before_tokens = 0;
            after_tokens = 0;
            saved_tokens = 0;
          }
        ~handoff_json:None
        ();
      let metrics_store =
        Masc_mcp.Keeper_types.keeper_metrics_store config minimal_meta.name
      in
      let line =
        match Dated_jsonl.read_recent_lines metrics_store 1 with
        | [ line ] -> line
        | _ -> fail "expected one metrics line"
      in
      let cdal_proof =
        Yojson.Safe.Util.(Yojson.Safe.from_string line |> member "cdal_proof")
      in
      check int "only mode_violations refs count as violations" 1
        Yojson.Safe.Util.(cdal_proof |> member "violation_count" |> to_int);
      check int "raw evidence refs are counted separately" 3
        Yojson.Safe.Util.(
          cdal_proof |> member "raw_evidence_ref_count" |> to_int))

let test_append_metrics_snapshot_nulls_unreported_usage () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      let result =
        make_run_result
          ~text:"Kimi replied without usage."
          ~tools:[]
          ~model:"kimi_cli:kimi-for-coding"
          ~input_tok:0
          ~output_tok:0
          ~usage_reported:false
          ()
      in
      UM.append_metrics_snapshot
        ~config
        ~meta:minimal_meta
        ~observation:base_observation
        ~result
        ~latency_ms:321
        ~turn_cost:0.42
        ~turn_generation:1
        ~channel:"turn"
        ~snapshot_source:"test"
        ~context_ratio:0.1
        ~context_tokens:10
        ~context_max:100
        ~message_count:2
        ~compaction:
          {
            Masc_mcp.Keeper_exec_context.applied = false;
            attempted = false;
            failure_reason = None;
            trigger = None;
            decision = Masc_mcp.Keeper_exec_context.Blocked_below_thresholds;
            before_tokens = 0;
            after_tokens = 0;
            saved_tokens = 0;
          }
        ~handoff_json:None
        ();
      let metrics_store =
        Masc_mcp.Keeper_types.keeper_metrics_store config minimal_meta.name
      in
      let line =
        match Dated_jsonl.read_recent_lines metrics_store 1 with
        | [ line ] -> line
        | _ -> fail "expected one metrics line"
      in
      let json = Yojson.Safe.from_string line in
      let open Yojson.Safe.Util in
      let usage = json |> member "usage" in
      check bool "snapshot input_tokens null when usage unreported" true
        (match usage |> member "input_tokens" with `Null -> true | _ -> false);
      check bool "snapshot output_tokens null when usage unreported" true
        (match usage |> member "output_tokens" with `Null -> true | _ -> false);
      check bool "snapshot total_tokens null when usage unreported" true
        (match usage |> member "total_tokens" with `Null -> true | _ -> false);
      check bool "snapshot cache_creation_tokens null when usage unreported" true
        (match usage |> member "cache_creation_tokens" with `Null -> true | _ -> false);
      check bool "snapshot cache_read_tokens null when usage unreported" true
        (match usage |> member "cache_read_tokens" with `Null -> true | _ -> false);
      check bool "snapshot cost_usd null when usage unreported" true
        (match json |> member "cost_usd" with `Null -> true | _ -> false))

let test_append_metrics_snapshot_persists_cache_usage () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      let result =
        make_run_result
          ~text:"Claude reported cache usage."
          ~tools:[]
          ~model:"claude:claude-sonnet-4-6"
          ~input_tok:2000
          ~output_tok:200
          ~cache_creation_tokens:1500
          ~cache_read_tokens:300
          ()
      in
      UM.append_metrics_snapshot
        ~config
        ~meta:minimal_meta
        ~observation:base_observation
        ~result
        ~latency_ms:321
        ~turn_cost:0.42
        ~turn_generation:1
        ~channel:"turn"
        ~snapshot_source:"test"
        ~context_ratio:0.1
        ~context_tokens:10
        ~context_max:100_000
        ~message_count:2
        ~compaction:
          {
            Masc_mcp.Keeper_exec_context.applied = false;
            attempted = false;
            failure_reason = None;
            trigger = None;
            decision = Masc_mcp.Keeper_exec_context.Blocked_below_thresholds;
            before_tokens = 0;
            after_tokens = 0;
            saved_tokens = 0;
          }
        ~handoff_json:None
        ();
      let metrics_store =
        Masc_mcp.Keeper_types.keeper_metrics_store config minimal_meta.name
      in
      let line =
        match Dated_jsonl.read_recent_lines metrics_store 1 with
        | [ line ] -> line
        | _ -> fail "expected one metrics line"
      in
      let usage =
        Yojson.Safe.Util.(Yojson.Safe.from_string line |> member "usage")
      in
      let open Yojson.Safe.Util in
      check int "cache creation persisted"
        1500 (usage |> member "cache_creation_tokens" |> to_int);
      check int "cache read persisted"
        300 (usage |> member "cache_read_tokens" |> to_int))

let test_estimate_trusted_usage_cost_uses_cache_usage () =
  let result =
    make_run_result
      ~text:"Claude reported cache usage."
      ~tools:[]
      ~model:"claude:claude-sonnet-4-6"
      ~input_tok:1_000_000
      ~output_tok:0
      ~cache_creation_tokens:100_000
      ~cache_read_tokens:200_000
      ()
  in
  let cost =
    UM.estimate_trusted_usage_cost_usd
      ~usage_trusted:true
      ~model:"claude-sonnet-4-6"
      result.usage
  in
  (* regular input 700k * $3/M + cache write 100k * $3/M * 1.25
     + cache read 200k * $3/M * 0.1 = $2.535.  This pins the unified
     keeper path to the same cache-aware pricing semantics as OAS. *)
  check (float 0.001) "cache-aware trusted cost" 2.535 cost;
  check (float 0.001) "untrusted usage is zero cost" 0.0
    (UM.estimate_trusted_usage_cost_usd
       ~usage_trusted:false
       ~model:"claude-sonnet-4-6"
       result.usage)

let test_record_keeper_total_cost_metric () =
  let keeper_name = "cost-metric-keeper" in
  UM.record_keeper_total_cost_usd ~keeper_name ~total_cost_usd:0.042;
  check (option (float 0.0001)) "keeper total cost gauge" (Some 0.042)
    (Masc_mcp.Prometheus.get_metric_value
       Masc_mcp.Prometheus.metric_keeper_total_cost_usd
       ~labels:[ ("keeper_name", keeper_name) ]
       ())

let test_append_metrics_snapshot_marks_untrusted_usage () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      let result =
        make_run_result
          ~text:"Usage is absurd."
          ~tools:[]
          ~model:"llama:qwen3.5-27b"
          ~input_tok:1_200_001
          ~output_tok:20
          ()
      in
      UM.append_metrics_snapshot
        ~config
        ~meta:minimal_meta
        ~observation:base_observation
        ~result
        ~latency_ms:321
        ~turn_cost:0.42
        ~turn_generation:1
        ~channel:"turn"
        ~snapshot_source:"test"
        ~context_ratio:0.1
        ~context_tokens:10
        ~context_max:100_000
        ~message_count:2
        ~compaction:
          {
            Masc_mcp.Keeper_exec_context.applied = false;
            attempted = false;
            failure_reason = None;
            trigger = None;
            decision = Masc_mcp.Keeper_exec_context.Blocked_below_thresholds;
            before_tokens = 0;
            after_tokens = 0;
            saved_tokens = 0;
          }
        ~handoff_json:None
        ();
      let metrics_store =
        Masc_mcp.Keeper_types.keeper_metrics_store config minimal_meta.name
      in
      let line =
        match Dated_jsonl.read_recent_lines metrics_store 1 with
        | [ line ] -> line
        | _ -> fail "expected one metrics line"
      in
      let json = Yojson.Safe.from_string line in
      let open Yojson.Safe.Util in
      check string "usage trust persisted" "untrusted"
        (json |> member "usage_trust" |> to_string);
      check string "nested usage trust persisted" "untrusted"
        (json |> member "usage" |> member "usage_trust" |> to_string);
      check bool "cost hidden when usage untrusted" true
        (match json |> member "cost_usd" with `Null -> true | _ -> false);
      let reasons =
        json |> member "usage_anomaly_reasons" |> to_list |> List.map to_string
      in
      check bool "absolute token anomaly persisted" true
        (List.mem "input_tokens_gt_1m" reasons);
      check bool "context token anomaly persisted" true
        (List.mem "input_tokens_gt_2x_context_max" reasons))

let test_append_decision_record_persists_tool_calls () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let current_task_id =
        match Masc_mcp.Keeper_id.Task_id.of_string "task-runtime-trust" with
        | Ok task_id -> task_id
        | Error err -> fail ("task id parse failed: " ^ err)
      in
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      let meta =
        {
          minimal_meta with
          active_goal_ids = [ "goal-runtime-trust" ];
          current_task_id = Some current_task_id;
        }
      in
      let tool_calls : KAR.tool_call_detail list =
        [ { tool_name = "keeper_shell"
          ; provider = "codex_cli"
          ; outcome = "ok"
          ; latency_ms = 12.5
          ; route_evidence =
              Some
                (`Assoc
                   [
                     ("tool_name", `String "keeper_shell");
                     ("command", `String "git_status");
                     ("cwd", `String "repos/masc-mcp");
                     ("via", `String "docker");
                     ("sandbox_profile", `String "docker");
                     ("git_creds_enabled", `Bool true);
                     ("network_mode", `String "bridge");
                   ])
          }
        ; { tool_name = "keeper_board_post"
          ; provider = "codex_cli"
          ; outcome = "error"
          ; latency_ms = 3.0
          ; route_evidence = None
          }
        ]
      in
      let result =
        make_run_result
          ~text:"Checked GitHub and reported blocker."
          ~tools:["keeper_shell"; "keeper_board_post"]
          ~tool_calls
          ~model:"codex_cli:gpt-5.4"
          ~input_tok:40
          ~output_tok:20
          ()
      in
      Fun.protect
        ~finally:KTCL.reset_for_testing
        (fun () ->
          KTCL.set_turn_context
            ~keeper_name:meta.name
            ~thinking_enabled:false
            ~keeper_turn_id:8
            ~approval_mode:"manual"
            ();
          UM.append_decision_record
            ~config
            ~meta
            ~observation:base_observation
            ~latency_ms:42
            ~outcome:"success"
            ~degraded_retry_applied:true
            ~degraded_retry_cascade:KC.local_recovery_cascade_name
            ~fallback_reason:"turn_timeout"
            ~turn_mode:UM.Tool_use
            ~result:(Some result)
            ());
      let json =
        read_jsonl_line (Keeper_types.keeper_decision_log_path config meta.name)
      in
      check int "tool call count persisted" 2
        Yojson.Safe.Util.(json |> member "tool_call_count" |> to_int);
      check int "turn id persisted" 8
        Yojson.Safe.Util.(json |> member "turn_id" |> to_int);
      check int "duration alias persisted" 42
        Yojson.Safe.Util.(json |> member "duration_ms" |> to_int);
      check (option string) "task id persisted"
        (Some "task-runtime-trust")
        Yojson.Safe.Util.(json |> member "task_id" |> to_string_option);
      check (option string) "goal id persisted"
        (Some "goal-runtime-trust")
        Yojson.Safe.Util.(json |> member "goal_id" |> to_string_option);
      check (list string) "goal ids persisted"
        [ "goal-runtime-trust" ]
        Yojson.Safe.Util.(json |> member "goal_ids" |> to_list |> List.map to_string);
      check (option string) "approval mode persisted"
        (Some "manual")
        Yojson.Safe.Util.(json |> member "approval_mode" |> to_string_option);
      check (option string) "runtime contract backend persisted"
        (Some "local")
        Yojson.Safe.Util.(
          json |> member "runtime_contract" |> member "backend" |> to_string_option);
      check int "pending approval count persisted" 0
        Yojson.Safe.Util.(json |> member "pending_approval_count" |> to_int);
      check (list string) "tools used persisted"
        ["keeper_shell"; "keeper_board_post"]
        Yojson.Safe.Util.(json |> member "tools_used" |> to_list |> List.map to_string);
      check (option string) "turn mode persisted" (Some "tool_use")
        Yojson.Safe.Util.(json |> member "turn_mode" |> to_string_option);
      check bool "degraded retry flag persisted" true
        Yojson.Safe.Util.(json |> member "degraded_retry_applied" |> to_bool);
      check (option string) "degraded retry cascade persisted"
        (Some KC.local_recovery_cascade_name)
        Yojson.Safe.Util.(
          json |> member "degraded_retry_cascade" |> to_string_option);
      check (option string) "fallback reason persisted"
        (Some "turn_timeout")
        Yojson.Safe.Util.(json |> member "fallback_reason" |> to_string_option);
      check bool "selected_mode removed from decision log" true
        (match Yojson.Safe.Util.(json |> member "selected_mode") with
         | `Null -> true
         | _ -> false);
      let recorded_tool_calls =
        Yojson.Safe.Util.(json |> member "tool_calls" |> to_list)
      in
      check int "tool call details persisted" 2 (List.length recorded_tool_calls);
      check string "first tool name" "keeper_shell"
        Yojson.Safe.Util.(List.nth recorded_tool_calls 0 |> member "tool_name" |> to_string);
      check string "first provider" "codex_cli"
        Yojson.Safe.Util.(List.nth recorded_tool_calls 0 |> member "provider" |> to_string);
      check string "first route via" "docker"
        Yojson.Safe.Util.(
          List.nth recorded_tool_calls 0 |> member "route_evidence"
          |> member "via" |> to_string);
      check bool "first route git creds" true
        Yojson.Safe.Util.(
          List.nth recorded_tool_calls 0 |> member "route_evidence"
          |> member "git_creds_enabled" |> to_bool);
	      check string "second outcome" "error"
	        Yojson.Safe.Util.(List.nth recorded_tool_calls 1 |> member "outcome" |> to_string);
      check bool "second route evidence absent" true
        (match
           Yojson.Safe.Util.(
             List.nth recorded_tool_calls 1 |> member "route_evidence")
         with
         | `Null -> true
         | _ -> false);
	      check (float 0.001) "second latency" 3.0
	        Yojson.Safe.Util.(List.nth recorded_tool_calls 1 |> member "latency_ms" |> to_float);
	      check string "terminal reason success" "success"
	        Yojson.Safe.Util.(json |> member "terminal_reason" |> member "code" |> to_string);
	      check string "terminal reason code alias" "success"
	        Yojson.Safe.Util.(json |> member "terminal_reason_code" |> to_string);
	      check string "provider context selected model" "codex_cli:gpt-5.4"
	        Yojson.Safe.Util.(json |> member "provider_context" |> member "selected_model" |> to_string);
	      check string "tool contract requirement" "optional"
	        Yojson.Safe.Util.(json |> member "tool_contract" |> member "requirement" |> to_string);
	      check int "tool contract count mirrors tool calls" 2
	        Yojson.Safe.Util.(json |> member "tool_contract" |> member "tool_call_count" |> to_int))

let test_append_decision_record_nulls_unreported_usage () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      let result =
        make_run_result
          ~text:"Kimi replied without usage."
          ~tools:[]
          ~model:"kimi_cli:kimi-for-coding"
          ~input_tok:0
          ~output_tok:0
          ~usage_reported:false
          ()
      in
      UM.append_decision_record
        ~config
        ~meta:minimal_meta
        ~observation:base_observation
        ~latency_ms:420
        ~outcome:"success"
        ~turn_mode:UM.Text_response
        ~result:(Some result)
        ();
      let json =
        read_jsonl_line (Keeper_types.keeper_decision_log_path config minimal_meta.name)
      in
      let open Yojson.Safe.Util in
      let telemetry = json |> member "telemetry" in
      check bool "input_tokens null when usage unreported" true
        (match telemetry |> member "input_tokens" with `Null -> true | _ -> false);
      check bool "output_tokens null when usage unreported" true
        (match telemetry |> member "output_tokens" with `Null -> true | _ -> false);
      check bool "cache_read_tokens null when usage unreported" true
        (match telemetry |> member "cache_read_tokens" with `Null -> true | _ -> false);
      check bool "cost_usd null when usage unreported" true
        (match telemetry |> member "cost_usd" with `Null -> true | _ -> false);
      check bool "tokens_per_second null when usage unreported" true
        (match telemetry |> member "tokens_per_second" with `Null -> true | _ -> false);
      check string "outcome persisted" "success"
        (telemetry |> member "outcome" |> to_string);
      check bool "usage_reported false persisted" false
        (telemetry |> member "usage_reported" |> to_bool);
      check bool "telemetry_reported false persisted" false
        (telemetry |> member "telemetry_reported" |> to_bool);
      check string "coverage stage persisted" "oas"
        (telemetry |> member "coverage_stage" |> to_string);
	      check string "coverage reason persisted" "missing_usage_and_inference"
	        (telemetry |> member "coverage_reason" |> to_string))

let test_append_decision_record_classifies_legacy_worktree_error () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      UM.append_decision_record
        ~config
        ~meta:minimal_meta
        ~observation:base_observation
        ~latency_ms:19
        ~outcome:"error"
        ~error:
          "keeper_shell failed: gh_repo_context_missing_worktree: active task has no linked worktree"
        ();
      let json =
        read_jsonl_line (Keeper_types.keeper_decision_log_path config minimal_meta.name)
      in
      let open Yojson.Safe.Util in
      check int "error duration alias persisted" 19
        (json |> member "duration_ms" |> to_int);
      check string "terminal code" "gh_repo_context_missing_worktree"
        (json |> member "terminal_reason" |> member "code" |> to_string);
      check string "terminal code alias" "gh_repo_context_missing_worktree"
        (json |> member "terminal_reason_code" |> to_string);
      check string "next action" "create_or_link_worktree"
        (json |> member "terminal_reason" |> member "next_action" |> to_string);
      check string "tool contract unknown for error path" "unknown"
        (json |> member "tool_contract" |> member "requirement" |> to_string))

let test_append_decision_record_preserves_no_result_skipped_outcome () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      UM.append_decision_record
        ~config
        ~meta:minimal_meta
        ~observation:base_observation
        ~latency_ms:11
        ~outcome:"skipped"
        ~terminal_reason:(Masc_mcp.Keeper_turn_terminal.of_code "ollama_saturated")
        ();
      let json =
        read_jsonl_line (Keeper_types.keeper_decision_log_path config minimal_meta.name)
      in
      let open Yojson.Safe.Util in
      let telemetry = json |> member "telemetry" in
      check string "top-level skipped outcome persisted" "skipped"
        (json |> member "outcome" |> to_string);
      check string "telemetry skipped outcome persisted" "skipped"
        (telemetry |> member "outcome" |> to_string);
      check bool "skipped telemetry category is null" true
        Yojson.Safe.Util.(telemetry |> member "error_category" = `Null);
      check string "skipped telemetry coverage stage" "pre_dispatch"
        (telemetry |> member "coverage_stage" |> to_string);
      check string "skipped telemetry coverage reason" "skipped_turn"
        (telemetry |> member "coverage_reason" |> to_string);
      check string "terminal code alias" "ollama_saturated"
        (json |> member "terminal_reason_code" |> to_string);
      check int "duration alias persisted" 11
        (json |> member "duration_ms" |> to_int))

let test_run_keeper_cycle_skips_non_executable_phase () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  let old_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect
    ~finally:(fun () ->
      (match old_base_path with
       | Some value -> Unix.putenv "MASC_BASE_PATH" value
       | None -> Unix.putenv "MASC_BASE_PATH" "");
      KR.clear ();
      cleanup_dir base_dir)
    (fun () ->
      KR.clear ();
      Unix.putenv "MASC_BASE_PATH" base_dir;
      let meta = make_meta "phase-gated-keeper" in
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (KR.register ~base_path:base_dir meta.name meta);
      (match KR.dispatch_event ~base_path:base_dir meta.name KP.Operator_pause with
       | Ok _ -> ()
       | Error err -> fail (KP.transition_error_to_string err));
      check (option string) "phase paused before run"
        (Some "paused")
        (Option.map KP.phase_to_string
           (KR.get_phase ~base_path:base_dir meta.name));
      let phase_skip_labels =
        [
          ("from", "phase_gating");
          ("to", "done");
          ("action", "PhaseGateSkip");
          ("keeper", meta.name);
        ]
      in
      let legacy_phase_cancel_labels =
        [
          ("from", "phase_gating");
          ("to", "cancelled:phase_gate_close");
          ("action", "HonorStopSignal");
          ("keeper", meta.name);
        ]
      in
      let phase_skip_before =
        Masc_mcp.Prometheus.metric_value_or_zero
          Masc_mcp.Prometheus.metric_keeper_turn_fsm_transitions
          ~labels:phase_skip_labels
          ()
      in
      let legacy_phase_cancel_before =
        Masc_mcp.Prometheus.metric_value_or_zero
          Masc_mcp.Prometheus.metric_keeper_turn_fsm_transitions
          ~labels:legacy_phase_cancel_labels
          ()
      in
      match
        UT.run_keeper_cycle
          ~config
          ~meta
          ~observation:base_observation
          ~generation:meta.runtime.generation
          ()
      with
      | Error err ->
          Alcotest.fail
            ("expected paused-phase skip, got error: "
            ^ Agent_sdk.Error.to_string err)
      | Ok updated ->
          let phase_skip_after =
            Masc_mcp.Prometheus.metric_value_or_zero
              Masc_mcp.Prometheus.metric_keeper_turn_fsm_transitions
              ~labels:phase_skip_labels
              ()
          in
          let legacy_phase_cancel_after =
            Masc_mcp.Prometheus.metric_value_or_zero
              Masc_mcp.Prometheus.metric_keeper_turn_fsm_transitions
              ~labels:legacy_phase_cancel_labels
              ()
          in
          check string "keeper name preserved" meta.name updated.name;
          check (float 0.0) "phase skip emits Done transition"
            (phase_skip_before +. 1.0)
            phase_skip_after;
          check (float 0.0) "phase skip does not emit legacy cancel"
            legacy_phase_cancel_before
            legacy_phase_cancel_after;
          check (option string) "phase remains paused after skipped turn"
            (Some "paused")
            (Option.map KP.phase_to_string
               (KR.get_phase ~base_path:base_dir meta.name));
          (match
             Masc_mcp.Keeper_execution_receipt.latest_json config meta.name
           with
           | None -> fail "expected skipped turn execution receipt"
           | Some receipt ->
              check string "skipped receipt outcome" "receipt_skipped"
                 Yojson.Safe.Util.(receipt |> member "outcome" |> to_string);
               check string "skipped receipt terminal reason"
                 "non_executable_phase:paused"
                 Yojson.Safe.Util.(
                   receipt |> member "terminal_reason_code" |> to_string);
               check string "skipped receipt action radius tool"
                 "keeper_turn"
                 Yojson.Safe.Util.(
                   receipt |> member "action_radius" |> member "tool_name"
                   |> to_string);
               check string "skipped receipt runtime contract keeper"
                 meta.name
                 Yojson.Safe.Util.(
                   receipt |> member "runtime_contract" |> member "keeper_name"
                   |> to_string));
          let trajectory_path =
            Masc_mcp.Trajectory.trajectory_path
              (Masc_mcp.Coord.masc_root_dir config)
              meta.name
              (Masc_mcp.Keeper_id.Trace_id.to_string meta.runtime.trace_id)
          in
          let trajectory_summary = read_jsonl_line trajectory_path in
          check string "skipped trajectory summary type" "trajectory_summary"
            Yojson.Safe.Util.(
              trajectory_summary |> member "type" |> to_string);
          check string "skipped trajectory outcome status" "gated"
            Yojson.Safe.Util.(
              trajectory_summary |> member "outcome" |> member "status"
              |> to_string);
          check string "skipped trajectory outcome reason"
            "non_executable_phase:paused"
            Yojson.Safe.Util.(
              trajectory_summary |> member "outcome" |> member "reason"
              |> to_string))

let test_streaming_cancel_records_supervisor_stop_when_fiber_stop_set () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      KR.clear ();
      cleanup_dir base_dir)
    (fun () ->
      with_test_runtime_roots base_dir @@ fun () ->
      KR.clear ();
      let meta = make_meta "streaming-supervisor-stop-keeper" in
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      let entry = KR.register ~base_path:base_dir meta.name meta in
      Atomic.set entry.fiber_stop true;
      let supervisor_request_labels =
        [
          ("from", "streaming");
          ("to", "streaming");
          ("action", "SupervisorRequestsStop");
          ("keeper", meta.name);
        ]
      in
      let honor_stop_labels =
        [
          ("from", "streaming");
          ("to", "cancelled:supervisor_stop");
          ("action", "HonorStopSignal");
          ("keeper", meta.name);
        ]
      in
      let supervisor_request_before =
        Masc_mcp.Prometheus.metric_value_or_zero
          Masc_mcp.Prometheus.metric_keeper_turn_fsm_transitions
          ~labels:supervisor_request_labels
          ()
      in
      let honor_stop_before =
        Masc_mcp.Prometheus.metric_value_or_zero
          Masc_mcp.Prometheus.metric_keeper_turn_fsm_transitions
          ~labels:honor_stop_labels
          ()
      in
      UT.record_streaming_cancelled_observation
        ~config
        ~run_meta:meta
        ~run_generation:meta.runtime.generation
        ~cascade_name:
          (Masc_mcp.Keeper_execution_receipt.cascade_name_of_string
             meta.cascade_name)
        ~keeper_turn_id:meta.runtime.usage.total_turns
        ();
      let supervisor_request_after =
        Masc_mcp.Prometheus.metric_value_or_zero
          Masc_mcp.Prometheus.metric_keeper_turn_fsm_transitions
          ~labels:supervisor_request_labels
          ()
      in
      let honor_stop_after =
        Masc_mcp.Prometheus.metric_value_or_zero
          Masc_mcp.Prometheus.metric_keeper_turn_fsm_transitions
          ~labels:honor_stop_labels
          ()
      in
      check (float 0.0)
        "streaming supervisor stop emits SupervisorRequestsStop"
        (supervisor_request_before +. 1.0)
        supervisor_request_after;
      check (float 0.0)
        "streaming supervisor stop emits HonorStopSignal"
        (honor_stop_before +. 1.0)
        honor_stop_after;
      match Masc_mcp.Keeper_execution_receipt.latest_json config meta.name with
      | None -> fail "expected streaming cancel execution receipt"
      | Some receipt ->
          check string "streaming cancel receipt outcome" "receipt_cancelled"
            Yojson.Safe.Util.(receipt |> member "outcome" |> to_string);
          check string "streaming cancel terminal reason" "supervisor_stop"
            Yojson.Safe.Util.(
              receipt |> member "terminal_reason_code" |> to_string))

let test_run_keeper_cycle_records_trajectory_source_contract () =
  check bool "keeper cycle creates trajectory accumulator" true
    (source_file_contains "lib/keeper/keeper_unified_turn.ml"
       "Trajectory.create_accumulator");
  check bool "keeper cycle passes trajectory_acc to agent run" true
    (source_file_contains "lib/keeper/keeper_unified_turn.ml"
       "~trajectory_acc");
  check bool "keeper cycle resolves masc root via Coord.masc_root_dir" true
    (source_file_contains "lib/keeper/keeper_unified_turn.ml"
       "Coord.masc_root_dir config");
  check bool "keeper cycle finalizes trajectory on completion/failure" true
    (source_file_contains "lib/keeper/keeper_turn_helpers.ml"
       "let finalize_trajectory_acc");
  check bool "pre-dispatch exits record terminal receipt" true
    (source_file_contains "lib/keeper/keeper_unified_turn.ml"
       "record_pre_dispatch_terminal_observation");
  check bool "saturation skip has durable terminal reason" true
    (source_file_contains "lib/keeper/keeper_unified_turn.ml"
       "~terminal_reason_code:\"ollama_saturated\"");
  check bool "saturation skip is not recorded as error" true
    (source_file_contains "lib/keeper/keeper_unified_turn.ml"
       "~terminal_reason_code:\"ollama_saturated\"\n\
       \                ~activity_kind:\"keeper.turn_skipped\"");
  check bool "saturation skip uses fsm-allowed cascade unavailable transition" true
    (source_file_contains "lib/keeper/keeper_unified_turn.ml"
       "Keeper_turn_fsm.Failure_cascade_unavailable");
  check bool "livelock block has durable terminal reason" true
    (source_file_contains "lib/keeper/keeper_unified_turn.ml"
       "Printf.sprintf \"turn_livelock:%s\"")

let test_pre_tool_gate_records_durable_attempt_telemetry () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      KTCL.reset_for_testing ();
      cleanup_dir base_dir)
    (fun () ->
      let keeper_name = "pre-tool-gate-keeper" in
      let meta_ref = ref (make_meta keeper_name) in
      let config = Masc_mcp.Coord.default_config base_dir in
      let masc_root = Masc_mcp.Coord.masc_root_dir config in
      let trace_id = "trace-pre-tool-gate" in
      let acc =
        Masc_mcp.Trajectory.create_accumulator
          ~masc_root ~keeper_name ~trace_id ~generation:9
      in
      KTCL.reset_for_testing ();
      KTCL.init ~base_path:base_dir ();
      KTCL.set_turn_context
        ~keeper_name
        ~agent_name:"pre-tool-gate-agent"
        ~trace_id
        ~session_id:"session-pre-tool-gate"
        ~generation:9
        ~turn:3
        ~keeper_turn_id:3
        ~task_id:"task-pre-tool"
        ~goal_ids:["goal-pre-tool"]
        ~approval_mode:"manual"
        ~tool_surface_class:"execution"
        ~visible_tool_count:1
        ~required_tools:["keeper_bash"]
        ();
      let hooks =
        HK.make_hooks
          ~config
          ~meta_ref
          ~generation:9
          ~pre_tool_use_guard:(fun ~tool_name:_ ~input:_ ->
            Some "operator approval required before dispatch")
          ~trajectory_acc:acc
          ()
      in
      let schedule : Agent_sdk.Hooks.tool_schedule =
        {
          planned_index = 0;
          batch_index = 0;
          batch_size = 1;
          concurrency_class = "default";
          batch_kind = "sequential";
        }
      in
      let decision =
        Agent_sdk.Hooks.invoke hooks.pre_tool_use
          (Agent_sdk.Hooks.PreToolUse
             {
               tool_use_id = "toolu_pre_gate";
               tool_name = "keeper_bash";
               input = `Assoc [ ("cmd", `String "git status --short") ];
               accumulated_cost_usd = 0.0;
               turn = 3;
               schedule;
             })
      in
      check string "custom gate blocked"
        "Override"
        (Agent_sdk.Hooks.decision_kind_to_string
           (Agent_sdk.Hooks.classify_decision decision));
      let entries =
        Masc_mcp.Trajectory.read_entries ~masc_root ~keeper_name ~trace_id
      in
      check int "trajectory entry count" 1 (List.length entries);
      (match entries with
       | [ entry ] ->
         check string "trajectory tool" "keeper_bash" entry.tool_name;
         check int "trajectory turn" 3 entry.turn;
         (match entry.gate_decision with
          | Masc_mcp.Trajectory.Reject reason ->
            check bool "reject reason names pre-tool guard" true
              (contains_substring reason "pre_tool_use_guard")
          | Masc_mcp.Trajectory.Pass ->
            fail "expected rejected gate decision");
         check bool "trajectory error present" true
           (Option.is_some entry.error)
       | _ -> fail "expected one trajectory entry");
      let raw_trajectory =
        read_jsonl_line
          (Masc_mcp.Trajectory.trajectory_path masc_root keeper_name trace_id)
      in
      let runtime_contract =
        Yojson.Safe.Util.member "runtime_contract" raw_trajectory
      in
      check string "runtime contract keeper" keeper_name
        Yojson.Safe.Util.(runtime_contract |> member "keeper_name" |> to_string);
      check string "runtime contract trace" trace_id
        Yojson.Safe.Util.(runtime_contract |> member "trace_id" |> to_string);
      let action_radius =
        Yojson.Safe.Util.member "action_radius" raw_trajectory
      in
      check string "action radius tool" "keeper_bash"
        Yojson.Safe.Util.(action_radius |> member "tool_name" |> to_string);
      check bool "action radius failed" false
        Yojson.Safe.Util.(action_radius |> member "success" |> to_bool);
      let tool_call_entries = KTCL.read_recent ~keeper_name ~n:1 () in
      check int "tool-call log entry count" 1 (List.length tool_call_entries);
      let tool_call = List.hd tool_call_entries in
      check string "tool-call log tool" "keeper_bash"
        (Safe_ops.json_string ~default:"" "tool" tool_call);
      check bool "tool-call log failed" false
        (Safe_ops.json_bool ~default:true "success" tool_call);
      check string "tool-call trace" trace_id
        (Safe_ops.json_string ~default:"" "trace_id" tool_call))

let test_run_keeper_cycle_surfaces_side_effect_failures_source_contract () =
  check bool "keeper cycle records side-effect issues in registry" true
    (source_file_contains "lib/keeper/keeper_turn_helpers.ml"
       "Keeper_registry.record_error ~base_path:config.base_path");
  check bool "trajectory finalize is not silently ignored" false
    (source_file_contains "lib/keeper/keeper_unified_turn.ml"
       "ignore (Trajectory.finalize trajectory_acc outcome)");
  check bool "paused-state sync result is not discarded" false
    (source_file_contains "lib/keeper/keeper_unified_turn.ml"
       "let _ = sync_keeper_paused_state");
  check bool "local discovery refresh is not silently ignored" false
    (source_file_contains "lib/keeper/keeper_unified_turn.ml"
       "ignore (Cascade_runtime.refresh_local_discovery_if_possible model_labels)");
  check bool "manual keeper_msg local discovery refresh is not silently ignored" false
    (source_file_contains "lib/keeper/keeper_turn.ml"
       "ignore (Cascade_runtime.refresh_local_discovery_if_possible effective_models)");
  check bool "activity graph emit is not silently ignored" false
    (source_file_contains "lib/keeper/keeper_unified_turn.ml"
       "ignore (Activity_graph.emit config");
  check bool "discovery helper guards keeper setup" true
    (source_file_contains "lib/keeper/keeper_unified_turn.ml"
       "ensure_local_discovery_ready model_labels");
  check bool "manual keeper_msg discovery helper guards keeper setup" true
    (source_file_contains "lib/keeper/keeper_turn.ml"
       "ensure_local_discovery_ready effective_models")

let test_sync_keeper_paused_state_surfaces_write_failure_without_mutating_registry () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      KR.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      let meta = make_meta "paused-sync-failure" in
      ignore (KR.register ~base_path:base_dir meta.name meta);
      let masc_root = Masc_mcp.Coord.masc_root_dir config in
      Masc_mcp.Keeper_types.mkdir_p masc_root;
      let keepers_path = Filename.concat masc_root "keepers" in
      let oc = open_out_bin keepers_path in
      close_out oc;
      match UT.sync_keeper_paused_state ~config ~meta ~paused:true with
      | Ok _ -> fail "expected paused-state sync failure"
      | Error msg ->
          check bool "write failure surfaced" true
            (contains_substring msg "failed to write meta");
          let latest =
            match KR.get ~base_path:base_dir meta.name with
            | Some entry -> entry.meta
            | None -> fail "expected registered keeper entry"
          in
          check bool "registry meta unchanged" false latest.paused;
          check (option string) "phase unchanged" (Some "running")
            (Option.map KP.phase_to_string
               (KR.get_phase ~base_path:base_dir meta.name)))

let test_ensure_local_discovery_ready_surfaces_refresh_failure () =
  let refresh_calls = ref 0 in
  match
    UT.ensure_local_discovery_ready
      ~refresh:(fun _labels ->
        incr refresh_calls;
        false)
      [ "llama:auto" ]
  with
  | Ok () -> fail "expected local discovery refresh failure"
  | Error msg ->
      check int "refresh called once" 1 !refresh_calls;
      check bool "error includes label" true
        (contains_substring msg "llama:auto")

let provider_config_of_label label =
  match Masc_mcp.Cascade_config.parse_model_string label with
  | Some cfg -> cfg
  | None -> fail ("expected model label to parse: " ^ label)

let test_decide_local_only_liveness_keeps_non_local_effective () =
  match
    UT.decide_local_only_liveness
      ~resolve_label:(fun _ -> fail "resolver should not run")
      ~base_cascade:"keeper_unified"
      ~effective_cascade:"default"
      [ "not-a-real-label" ]
  with
  | UT.Keep_effective_cascade cascade ->
      check string "keeps selected cascade" KC.default_cascade_name cascade
  | UT.Probe_local_only_urls _ -> fail "unexpected local-only probe decision"

let test_decide_local_only_liveness_keeps_explicit_local_only () =
  match
    UT.decide_local_only_liveness
      ~resolve_label:(fun _ -> fail "resolver should not run")
      ~base_cascade:"local_only"
      ~effective_cascade:"local_only"
      [ "not-a-real-label" ]
  with
  | UT.Keep_effective_cascade cascade ->
      check string "legacy local_only alias follows phase-buffer route"
        KC.local_only_cascade_name cascade
  | UT.Probe_local_only_urls _ -> fail "unexpected local-only probe decision"

let test_decide_local_only_liveness_requests_deduped_ollama_probe () =
  let label = "ollama:qwen3.6:35b-a3b-mlx-bf16" in
  let cfg = provider_config_of_label label in
  match
    UT.decide_local_only_liveness
      ~base_cascade:"tool_rerank"
      ~effective_cascade:KC.local_only_cascade_name
      [ label; label ]
  with
  | UT.Keep_effective_cascade _ -> fail "expected Ollama liveness probe"
  | UT.Probe_local_only_urls
      { effective_cascade; fallback_cascade; ollama_base_urls } ->
      check string "effective cascade" KC.local_only_cascade_name effective_cascade;
      check string "fallback cascade" "tool_rerank" fallback_cascade;
      check (list string) "deduped probe URLs" [ cfg.base_url ]
        ollama_base_urls

let test_fail_open_local_only_when_probe_fails () =
  let cascade =
    UT.fail_open_local_only_when_unavailable
      ~probe_ollama_base_url:(fun _ -> false)
      ~base_cascade:"tool_rerank"
      ~effective_cascade:KC.local_only_cascade_name
      [ "ollama:qwen3.6:35b-a3b-mlx-bf16" ]
  in
  check string "falls back to base cascade" "tool_rerank" cascade

let test_fail_open_local_only_preserves_explicit_local_only_base () =
  let probe_calls = ref 0 in
  let cascade =
    UT.fail_open_local_only_when_unavailable
      ~probe_ollama_base_url:(fun _ ->
        incr probe_calls;
        false)
      ~base_cascade:"local_only"
      ~effective_cascade:"local_only"
      [ "ollama:qwen3.6:35b-a3b-mlx-bf16" ]
  in
  check int "probe not called" 0 !probe_calls;
  check string "legacy local_only alias follows phase-buffer route"
    KC.local_only_cascade_name cascade

let test_fail_open_local_only_preserves_healthy_local_only () =
  let cascade =
    UT.fail_open_local_only_when_unavailable
      ~probe_ollama_base_url:(fun _ -> true)
      ~base_cascade:"tool_rerank"
      ~effective_cascade:KC.local_only_cascade_name
      [ "ollama:qwen3.6:35b-a3b-mlx-bf16" ]
  in
  check string "healthy ollama keeps phase-buffer route"
    KC.local_only_cascade_name cascade

(* PR-B: ollama saturation pre-skip helpers. *)

let make_capacity_info ?(total = 1) ?(active = 0) ?(available = 1)
    ?(queue = 0) () : Masc_mcp.Cascade_throttle.capacity_info =
  {
    total;
    process_active = active;
    process_available = available;
    process_queue_length = queue;
    source = Llm_provider.Provider_throttle.Discovered;
  }

let test_resolve_ollama_only_base_url_empty_returns_none () =
  match UT.resolve_ollama_only_base_url [] with
  | None -> ()
  | Some _ -> fail "empty labels should not resolve to ollama-only"

let test_resolve_ollama_only_base_url_single_ollama () =
  let label = "ollama:qwen3.6:35b-a3b-mlx-bf16" in
  let cfg = provider_config_of_label label in
  match UT.resolve_ollama_only_base_url [ label ] with
  | Some url -> check string "single ollama base url" cfg.base_url url
  | None -> fail "single ollama label should resolve"

let test_resolve_ollama_only_base_url_mixed_provider () =
  match
    UT.resolve_ollama_only_base_url
      [ "ollama:qwen3.6:35b-a3b-mlx-bf16"; "claude:sonnet-4-5" ]
  with
  | None -> ()
  | Some _ -> fail "mixed provider must not be classified as ollama-only"

let test_resolve_ollama_only_base_url_different_hosts () =
  let resolve_label = function
    | "ollama:a" ->
        Some
          (Llm_provider.Provider_config.make
             ~kind:Llm_provider.Provider_config.Ollama
             ~model_id:"a"
             ~base_url:"http://127.0.0.1:11434"
             ())
    | "ollama:b" ->
        Some
          (Llm_provider.Provider_config.make
             ~kind:Llm_provider.Provider_config.Ollama
             ~model_id:"b"
             ~base_url:"http://10.0.0.5:11434"
             ())
    | _ -> None
  in
  match
    UT.resolve_ollama_only_base_url ~resolve_label
      [ "ollama:a"; "ollama:b" ]
  with
  | None -> ()
  | Some _ -> fail "different ollama hosts must not collapse"

let test_is_ollama_saturated_returns_false_when_cache_missing () =
  let url = "http://127.0.0.1:11434" in
  check bool "missing cache treated as healthy" false
    (UT.is_ollama_saturated ~capacity_lookup:(fun _ -> None) url)

let test_is_ollama_saturated_returns_false_when_idle () =
  let url = "http://127.0.0.1:11434" in
  let info = make_capacity_info ~active:0 ~available:1 ~queue:0 () in
  check bool "idle endpoint not saturated" false
    (UT.is_ollama_saturated
       ~capacity_lookup:(fun _ -> Some info) url)

let test_is_ollama_saturated_returns_true_when_full_with_queue () =
  let url = "http://127.0.0.1:11434" in
  let info = make_capacity_info ~active:1 ~available:0 ~queue:3 () in
  check bool "full endpoint with queue is saturated" true
    (UT.is_ollama_saturated
       ~capacity_lookup:(fun _ -> Some info) url)

let test_is_ollama_saturated_ignores_zero_available_when_idle () =
  (* Defensive: discovery may report 0 available before any traffic.
     Without active or queued requests the keeper should still dispatch. *)
  let url = "http://127.0.0.1:11434" in
  let info = make_capacity_info ~active:0 ~available:0 ~queue:0 () in
  check bool "idle endpoint with no slots is fail-open" false
    (UT.is_ollama_saturated
       ~capacity_lookup:(fun _ -> Some info) url)

let test_saturation_skip_count_starts_at_zero () =
  UT.saturation_skip_count_clear_all ();
  check int "fresh keeper has zero skip count" 0
    (UT.saturation_skip_count_get ~keeper_name:"fresh_keeper")

let test_saturation_skip_count_inc_returns_new_value () =
  UT.saturation_skip_count_clear_all ();
  let n1 = UT.saturation_skip_count_inc ~keeper_name:"k_inc" in
  let n2 = UT.saturation_skip_count_inc ~keeper_name:"k_inc" in
  let n3 = UT.saturation_skip_count_inc ~keeper_name:"k_inc" in
  check int "first inc returns 1" 1 n1;
  check int "second inc returns 2" 2 n2;
  check int "third inc returns 3" 3 n3;
  check int "get matches last inc" 3
    (UT.saturation_skip_count_get ~keeper_name:"k_inc")

let test_saturation_skip_count_reset_zeros_one_keeper () =
  UT.saturation_skip_count_clear_all ();
  let _ = UT.saturation_skip_count_inc ~keeper_name:"k_a" in
  let _ = UT.saturation_skip_count_inc ~keeper_name:"k_b" in
  let _ = UT.saturation_skip_count_inc ~keeper_name:"k_b" in
  UT.saturation_skip_count_reset ~keeper_name:"k_a";
  check int "reset target zeroed" 0
    (UT.saturation_skip_count_get ~keeper_name:"k_a");
  check int "untouched keeper preserved" 2
    (UT.saturation_skip_count_get ~keeper_name:"k_b")

let test_saturation_skip_cap_default_is_at_least_one () =
  (* The cap is floored at 1 even if the env var is set to 0 or
     negative — a cap of 0 would force-dispatch every cycle. *)
  let prev = try Some (Sys.getenv "MASC_MAX_CONSECUTIVE_SATURATION_SKIPS")
             with Not_found -> None in
  Unix.putenv "MASC_MAX_CONSECUTIVE_SATURATION_SKIPS" "0";
  let cap = UT.max_consecutive_saturation_skips () in
  (match prev with
   | Some v -> Unix.putenv "MASC_MAX_CONSECUTIVE_SATURATION_SKIPS" v
   | None -> Unix.putenv "MASC_MAX_CONSECUTIVE_SATURATION_SKIPS" "");
  check bool "cap floored at 1 even with env=0" true (cap >= 1)

let wrapped_claude_limit_error () =
  Agent_sdk.Error.Api
    (NetworkError
       {
         message =
           "claude exited with code 1: {\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"api_error_status\":429,\"result\":\"You've hit your limit · resets Apr 24 at 4am (Asia/Seoul)\"}";
         kind = Llm_provider.Http_client.Unknown;
       })

let wrapped_claude_max_turns_message =
  "claude exited with code 1: {\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,\"stop_reason\":\"tool_use\",\"terminal_reason\":\"max_turns\",\"errors\":[\"Reached maximum number of turns (10)\"]}"

let wrapped_claude_max_turns_error () =
  Agent_sdk.Error.Api
    (NetworkError
       {
         message = wrapped_claude_max_turns_message;
         kind = Llm_provider.Http_client.Unknown;
       })

let wrapped_cascade_max_turns_error () =
  Masc_mcp.Oas_worker_named.sdk_error_of_masc_internal_error
    (Masc_mcp.Oas_worker_named.Cascade_exhausted
       {
         cascade_name =
           oas_error_cascade_name Masc_mcp.Keeper_config.default_cascade_name;
         reason = Keeper_types.Other_detail wrapped_claude_max_turns_message;
       })

let required_tool_contract_violation_error () =
  Agent_sdk.Error.Agent
    (CompletionContractViolation
       {
         contract = Agent_sdk.Completion_contract_id.Require_tool_use;
         reason =
           "required tool contract unsatisfied: tool_choice requested tool use, but the model returned no ToolUse block";
       })

let expect_degraded_retry label expected_cascade expected_reason = function
  | Some (retry : EC.degraded_retry) ->
      check string (label ^ " cascade") expected_cascade retry.next_cascade;
      check string (label ^ " reason") expected_reason retry.fallback_reason
  | None -> fail (label ^ ": expected degraded retry")

let test_degraded_retry_after_recoverable_error_uses_local_recovery_for_hard_quota () =
  let degraded_retry =
    EC.degraded_retry_after_recoverable_error
      ~effective_cascade:"underdog"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      (wrapped_claude_limit_error ())
  in
  expect_degraded_retry "hard quota degraded retry"
    KC.local_recovery_cascade_name "hard_quota" degraded_retry

let test_degraded_retry_after_recoverable_error_uses_local_recovery_for_resumable_session () =
  let degraded_retry =
    EC.degraded_retry_after_recoverable_error
      ~effective_cascade:"underdog"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      (Masc_mcp.Oas_worker_named.sdk_error_of_masc_internal_error
         (Masc_mcp.Oas_worker_named.Resumable_cli_session
            {
              cascade_name = oas_error_cascade_name "kimi_cli_keeper";
              detail =
                "kimi exited with code 75: \nTo resume this session: kimi -r ff37febe-2adb-4ac6-9dc6-cae23e672fbc";
              exit_code = Some 75;
            }))
  in
  expect_degraded_retry "resumable session degraded retry"
    KC.local_recovery_cascade_name "resumable_cli_session" degraded_retry

let test_degraded_retry_after_recoverable_error_includes_admission_queue_timeout () =
  let degraded_retry =
    EC.degraded_retry_after_recoverable_error
      ~effective_cascade:"underdog"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      (Masc_mcp.Oas_worker_named.sdk_error_of_masc_internal_error
         (Masc_mcp.Oas_worker_named.Admission_queue_timeout
            {
              keeper_name = "nick0cave";
              cascade_name = oas_error_cascade_name "big_three";
              wait_sec = 90.0;
            }))
  in
  expect_degraded_retry "admission queue timeout degraded retry"
    KC.local_recovery_cascade_name "admission_queue_timeout" degraded_retry

let test_degraded_retry_after_recoverable_error_includes_turn_timeout () =
  let degraded_retry =
    EC.degraded_retry_after_recoverable_error
      ~effective_cascade:"underdog"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      (Masc_mcp.Oas_worker_named.sdk_error_of_masc_internal_error
         (Masc_mcp.Oas_worker_named.Turn_timeout { elapsed_sec = 180.0 }))
  in
  expect_degraded_retry "turn timeout degraded retry"
    KC.local_recovery_cascade_name "turn_timeout" degraded_retry

let test_degraded_retry_after_recoverable_error_includes_oas_timeout_budget () =
  let degraded_retry =
    EC.degraded_retry_after_recoverable_error
      ~effective_cascade:"underdog"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      (Masc_mcp.Oas_worker_named.sdk_error_of_masc_internal_error
         (Masc_mcp.Oas_worker_named.Oas_timeout_budget
            {
              budget_sec = 273.0;
              keeper_turn_timeout_sec = 1200.0;
              estimated_input_tokens = 2_000;
              source = "adaptive_estimated_input_tokens";
              remaining_turn_budget_sec = Some 600.0;
              min_required_sec = 15.0;
              phase = "test_phase";
            }))
  in
  expect_degraded_retry "oas timeout budget degraded retry"
    KC.local_recovery_cascade_name "oas_timeout_budget" degraded_retry

let test_degraded_retry_after_recoverable_error_includes_max_turns () =
  let degraded_retry =
    EC.degraded_retry_after_recoverable_error
      ~effective_cascade:"underdog"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      (wrapped_cascade_max_turns_error ())
  in
  expect_degraded_retry "max turns degraded retry"
    KC.local_recovery_cascade_name "max_turns" degraded_retry

let test_degraded_retry_after_recoverable_error_blocks_required_tools () =
  let degraded_retry =
    EC.degraded_retry_after_recoverable_error
      ~effective_cascade:"underdog"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Required
      (wrapped_claude_limit_error ())
  in
  check bool "required tool turn stays terminal" true
    (Option.is_none degraded_retry)

let test_degraded_retry_after_recoverable_error_does_not_broaden_local_only () =
  let degraded_retry =
    EC.degraded_retry_after_recoverable_error
      ~effective_cascade:KC.local_only_cascade_name
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      (wrapped_claude_limit_error ())
  in
  check bool "local_only does not broaden further" true
    (Option.is_none degraded_retry)

let test_degraded_retry_after_recoverable_error_does_not_broaden_local_recovery () =
  let degraded_retry =
    EC.degraded_retry_after_recoverable_error
      ~effective_cascade:KC.local_recovery_cascade_name
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      (wrapped_claude_limit_error ())
  in
  check bool "local_recovery does not broaden further" true
    (Option.is_none degraded_retry)

let test_fallback_cascade_for_unavailable_profile_prefers_default () =
  let fallback =
    EC.fallback_cascade_for_unavailable_profile
      ~base_cascade:"tool_rerank"
      ~effective_cascade:"tool_rerank"
  in
  check (option string) "non-default cascade fallback target is default"
    (Some KC.default_cascade_name) fallback

let test_fallback_cascade_for_unavailable_profile_prefers_base_after_phase_override () =
  let fallback =
    EC.fallback_cascade_for_unavailable_profile
      ~base_cascade:"tool_rerank"
      ~effective_cascade:KC.local_recovery_cascade_name
  in
  check (option string) "phase override fallback target is base cascade"
    (Some "tool_rerank") fallback

let test_next_fail_open_cascade_for_turn_returns_untried_default_cascade () =
  let degraded_retry =
    UT.next_fail_open_cascade_for_turn
      ~base_cascade:"tool_rerank"
      ~effective_cascade:"tool_rerank"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_cascades:[ "tool_rerank" ]
      (wrapped_claude_limit_error ())
  in
  expect_degraded_retry "next degraded retry"
    KC.default_cascade_name "hard_quota" degraded_retry

let test_next_fail_open_cascade_for_turn_continues_to_local_recovery () =
  let degraded_retry =
    UT.next_fail_open_cascade_for_turn
      ~base_cascade:"tool_rerank"
      ~effective_cascade:"tool_rerank"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_cascades:
        [ "tool_rerank"; KC.default_cascade_name ]
      (wrapped_claude_limit_error ())
  in
  check bool "collapsed local_recovery is exhausted after default" true
    (Option.is_none degraded_retry)

let test_next_fail_open_cascade_for_turn_suppresses_exhausted_rotation_group () =
  let degraded_retry =
    UT.next_fail_open_cascade_for_turn
      ~base_cascade:"tool_rerank"
      ~effective_cascade:"tool_rerank"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_cascades:
        [
          "tool_rerank";
          KC.default_cascade_name;
          KC.local_recovery_cascade_name;
        ]
      (wrapped_claude_limit_error ())
  in
  check bool "exhausted rotation group suppressed" true
    (Option.is_none degraded_retry)

let test_next_fail_open_cascade_for_required_tool_uses_default_not_strict () =
  let degraded_retry =
    UT.next_fail_open_cascade_for_turn
      ~base_cascade:"tool_rerank"
      ~effective_cascade:"tool_rerank"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Required
      ~attempted_cascades:[ "tool_rerank" ]
      (wrapped_claude_limit_error ())
  in
  expect_degraded_retry "required tool degraded retry skips strict injection"
    KC.default_cascade_name "hard_quota" degraded_retry

let test_next_fail_open_cascade_for_turn_allows_required_tool_rotation () =
  let degraded_retry =
    UT.next_fail_open_cascade_for_turn
      ~base_cascade:"tool_rerank"
      ~effective_cascade:"strict_exec"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Required
      ~attempted_cascades:[ "strict_exec" ]
      (wrapped_claude_limit_error ())
  in
  expect_degraded_retry "required tool degraded retry"
    "tool_rerank" "hard_quota" degraded_retry

let test_next_fail_open_cascade_for_turn_retries_required_tool_contract_violation () =
  let degraded_retry =
    UT.next_fail_open_cascade_for_turn
      ~base_cascade:KC.default_cascade_name
      ~effective_cascade:"strict_exec"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Required
      ~attempted_cascades:[ "strict_exec" ]
      (required_tool_contract_violation_error ())
  in
  expect_degraded_retry "required contract degraded retry"
    KC.default_cascade_name "required_tool_contract_violation" degraded_retry

let test_next_fail_open_cascade_for_turn_uses_catalog_rotation_profile () =
  let degraded_retry =
    UT.next_fail_open_cascade_for_turn
      ~rotation_cascades:
        [
          KC.default_cascade_name;
          KC.local_recovery_cascade_name;
          "ollama_only";
        ]
      ~base_cascade:"tool_rerank"
      ~effective_cascade:"tool_rerank"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_cascades:
        [
          "tool_rerank";
          KC.default_cascade_name;
          KC.local_recovery_cascade_name;
        ]
      (wrapped_claude_limit_error ())
  in
  expect_degraded_retry "catalog degraded retry"
    "ollama_only" "hard_quota" degraded_retry

let test_next_fail_open_cascade_for_turn_does_not_inject_default_when_catalog_omits_it () =
  let degraded_retry =
    UT.next_fail_open_cascade_for_turn
      ~rotation_cascades:[ "resilient_profile" ]
      ~base_cascade:"tool_rerank"
      ~effective_cascade:"tool_rerank"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_cascades:[ "tool_rerank" ]
      (wrapped_claude_limit_error ())
  in
  expect_degraded_retry "catalog-only degraded retry"
    "resilient_profile" "hard_quota" degraded_retry

let test_next_fail_open_cascade_for_required_tool_filters_local_recovery_catalog () =
  let degraded_retry =
    UT.next_fail_open_cascade_for_turn
      ~rotation_cascades:[ KC.local_recovery_cascade_name; "required_safe" ]
      ~base_cascade:KC.default_cascade_name
      ~effective_cascade:"strict_exec"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Required
      ~attempted_cascades:[ "strict_exec" ]
      (required_tool_contract_violation_error ())
  in
  expect_degraded_retry "required catalog degraded retry"
    KC.default_cascade_name "required_tool_contract_violation" degraded_retry

let test_next_fail_open_cascade_for_required_tool_rejects_local_recovery_only_catalog () =
  let degraded_retry =
    UT.next_fail_open_cascade_for_turn
      ~rotation_cascades:[ KC.local_recovery_cascade_name ]
      ~base_cascade:"strict_exec"
      ~effective_cascade:"strict_exec"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Required
      ~attempted_cascades:[ "strict_exec" ]
      (required_tool_contract_violation_error ())
  in
  expect_degraded_retry "required catalog default-backed recovery"
    KC.default_cascade_name "required_tool_contract_violation" degraded_retry

let test_degraded_rotation_after_recoverable_error_filters_required_catalog_directly () =
  let degraded_retry =
    EC.degraded_rotation_after_recoverable_error
      ~rotation_cascades:[ KC.local_recovery_cascade_name; " big_three " ]
      ~base_cascade:"strict_exec"
      ~effective_cascade:"strict_exec"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Required
      ~attempted_cascades:[ "strict_exec" ]
      (required_tool_contract_violation_error ())
  in
  expect_degraded_retry "required catalog classifier rotation"
    "big_three" "required_tool_contract_violation" degraded_retry

let test_degraded_rotation_preserves_local_recovery_profile_hint_for_required_tool
    () =
  let degraded_retry =
    EC.degraded_rotation_after_recoverable_error
      ~rotation_cascades:[ "big_three"; "local_recovery" ]
      ~fallback_hint:"local_recovery"
      ~base_cascade:"tier_fast"
      ~effective_cascade:"keeper_bound_safe"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Required
      ~attempted_cascades:[ "tier_fast"; "keeper_bound_safe"; "big_three" ]
      (required_tool_contract_violation_error ())
  in
  expect_degraded_retry "required local_recovery fallback profile"
    "local_recovery" "required_tool_contract_violation" degraded_retry

let test_degraded_rotation_after_recoverable_error_normalizes_catalog_directly () =
  let degraded_retry =
    EC.degraded_rotation_after_recoverable_error
      ~rotation_cascades:[ ""; " tool_rerank "; " catalog_next "; "catalog_next" ]
      ~base_cascade:" tool_rerank "
      ~effective_cascade:"tool_rerank"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_cascades:[ "tool_rerank" ]
      (wrapped_claude_limit_error ())
  in
  expect_degraded_retry "normalized catalog classifier rotation"
    "catalog_next" "hard_quota" degraded_retry

let test_degraded_rotation_prefers_fallback_hint_over_catalog () =
  let degraded_retry =
    EC.degraded_rotation_after_recoverable_error
      ~rotation_cascades:[ KC.local_recovery_cascade_name; "big_three" ]
      ~fallback_hint:"local_with_kimi_coding_with_glm"
      ~base_cascade:"ollama_only"
      ~effective_cascade:"ollama_only"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_cascades:[ "ollama_only" ]
      (wrapped_claude_limit_error ())
  in
  expect_degraded_retry "fallback_hint takes priority"
    "local_with_kimi_coding_with_glm" "hard_quota" degraded_retry

let test_degraded_rotation_skips_already_attempted_fallback_hint () =
  let degraded_retry =
    EC.degraded_rotation_after_recoverable_error
      ~rotation_cascades:[ KC.local_recovery_cascade_name; "big_three" ]
      ~fallback_hint:"local_with_kimi_coding_with_glm"
      ~base_cascade:"ollama_only"
      ~effective_cascade:"ollama_only"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_cascades:
        [ "ollama_only"; "local_with_kimi_coding_with_glm" ]
      (wrapped_claude_limit_error ())
  in
  expect_degraded_retry "exhausted hint falls through to catalog"
    KC.local_recovery_cascade_name "hard_quota" degraded_retry

let test_degraded_rotation_ignores_blank_fallback_hint () =
  let degraded_retry =
    EC.degraded_rotation_after_recoverable_error
      ~rotation_cascades:[ KC.local_recovery_cascade_name; "big_three" ]
      ~fallback_hint:"   "
      ~base_cascade:"ollama_only"
      ~effective_cascade:"ollama_only"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_cascades:[ "ollama_only" ]
      (wrapped_claude_limit_error ())
  in
  expect_degraded_retry "blank hint behaves like no hint"
    KC.local_recovery_cascade_name "hard_quota" degraded_retry

let test_fail_open_rotation_cascades_from_catalog_merges_reserved_and_assignable () =
  let rotation =
    UT.fail_open_rotation_cascades_from_catalog
      ~catalog_names:
        [
          KC.default_cascade_name;
          KC.local_recovery_cascade_name;
          "ollama_only";
        ]
      ~keeper_assignable:[ KC.default_cascade_name; "ollama_only" ]
  in
  check (option (list string)) "catalog-derived rotation order"
    (Some
       [
         KC.default_cascade_name;
         "ollama_only";
       ])
    rotation

let test_fail_open_rotation_cascades_from_catalog_preserves_catalog_order () =
  let rotation =
    UT.fail_open_rotation_cascades_from_catalog
      ~catalog_names:
        [
          "ollama_only";
          KC.local_recovery_cascade_name;
          KC.default_cascade_name;
        ]
      ~keeper_assignable:[ KC.default_cascade_name; "ollama_only" ]
  in
  check (option (list string)) "catalog-derived rotation preserves catalog order"
    (Some
       [
         "ollama_only";
         KC.default_cascade_name;
       ])
    rotation

let test_fail_open_rotation_cascades_from_catalog_empty_when_unresolved () =
  let rotation =
    UT.fail_open_rotation_cascades_from_catalog
      ~catalog_names:[]
      ~keeper_assignable:[ KC.default_cascade_name ]
  in
  check (option (list string)) "unresolved catalog falls back to legacy path"
    None rotation

let test_fail_open_rotation_cascades_from_catalog_empty_without_assignable_candidates () =
  let rotation =
    UT.fail_open_rotation_cascades_from_catalog
      ~catalog_names:[ "experimental_only" ]
      ~keeper_assignable:[]
  in
  check (option (list string)) "resolved catalog without assignable candidates"
    None rotation

(* context_overflow_limit is now in OAS as Retry.extract_context_limit.
   These tests verify the OAS SSOT API is accessible from MASC. *)
let test_context_overflow_limit_parses_common_oas_errors () =
  check (option int) "available context size extracted" (Some 159671)
    (Agent_sdk.Retry.extract_context_limit
       "OpenAI returned 400: This model's maximum context length is 128000 tokens. However, your messages resulted in 193217 tokens. available context size (159671)");
  check (option int) "input budget exceeded extracted" (Some 8192)
    (Agent_sdk.Retry.extract_context_limit
       "Agent run failed: Input token budget exceeded:\n  10847/8192");
  check (option int) "non-overflow message" None
    (Agent_sdk.Retry.extract_context_limit
       "HTTP error: 503 Service Unavailable")

let test_is_context_overflow_only_for_overflow_errors () =
  check bool "ContextOverflow matches" true
    (EC.is_context_overflow
       (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = Some 32768 })));
  check bool "ContextOverflow without limit" true
    (EC.is_context_overflow
       (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = None })));
  check bool "NetworkError does not match" false
    (EC.is_context_overflow
       (Agent_sdk.Error.Api
          (NetworkError
             {
               message = "Connection_reset";
               kind = Llm_provider.Http_client.Connection_refused;
             })));
  check bool "Internal does not match" false
    (EC.is_context_overflow
       (Agent_sdk.Error.Internal "some error"));
  check bool "TokenBudgetExceeded Input matches" true
    (EC.is_context_overflow
       (Agent_sdk.Error.Agent (TokenBudgetExceeded { kind = "Input"; used = 204917; limit = 200000 })));
  check bool "TokenBudgetExceeded Total does not match" false
    (EC.is_context_overflow
       (Agent_sdk.Error.Agent (TokenBudgetExceeded { kind = "Total"; used = 300000; limit = 250000 })))

let test_summarize_turn_event_bus_extracts_overflow_signal () =
  let events =
    [
      Agent_sdk.Event_bus.mk_event
        ~correlation_id:"cid-123"
        ~run_id:"run-1"
        (Agent_sdk.Event_bus.TurnStarted
           { agent_name = minimal_meta.name; turn = 1 });
      Agent_sdk.Event_bus.mk_event
        ~correlation_id:"cid-123"
        ~run_id:"run-1"
        (Agent_sdk.Event_bus.ContextOverflowImminent
           {
             agent_name = minimal_meta.name;
             estimated_tokens = 205_000;
             limit_tokens = 200_000;
             ratio = 1.025;
           });
    ]
  in
  let summary = UT.summarize_turn_event_bus events in
  check (option string) "correlation id from first event" (Some "cid-123")
    summary.correlation_id;
  match summary.overflow_imminent with
  | Some overflow ->
      check int "estimated tokens" 205_000 overflow.estimated_tokens;
      check int "limit tokens" 200_000 overflow.limit_tokens
  | None -> fail "expected overflow_imminent summary"

let test_context_overflow_event_prefers_event_bus_signal () =
  let turn_event_bus : UT.turn_event_bus_summary =
    {
      correlation_id = Some "cid-123";
      overflow_imminent =
        Some
          {
            estimated_tokens = 205_000;
            limit_tokens = 200_000;
          };
    }
  in
  match
    UT.context_overflow_event_of_error
      ~fallback_tokens:32_768
      ~turn_event_bus
      (Agent_sdk.Error.Api
         (ContextOverflow { message = "prompt exceeds context"; limit = Some 32_768 }))
  with
  | KP.Context_overflow_detected
      {
        source = `Oas_signal;
        token_count;
        limit_tokens = Some limit_tokens;
      } ->
      check int "estimated tokens win" 205_000 token_count;
      check int "event bus limit wins" 200_000 limit_tokens
  | event ->
      fail
        ("expected oas_signal overflow event, got "
        ^ KP.event_to_string event)

let test_context_overflow_event_falls_back_without_event_bus_signal () =
  match
    UT.context_overflow_event_of_error
      ~fallback_tokens:32_768
      (Agent_sdk.Error.Api
         (ContextOverflow { message = "prompt exceeds context"; limit = Some 32_768 }))
  with
  | KP.Context_overflow_detected
      {
        source = `Prompt_rejected;
        token_count;
        limit_tokens = Some limit_tokens;
      } ->
      check int "fallback uses error limit" 32_768 token_count;
      check int "fallback preserves limit" 32_768 limit_tokens
  | event ->
      fail
        ("expected prompt_rejected overflow event, got "
        ^ KP.event_to_string event)

let test_metrics_persist_social_state_fields () =
  let result =
    make_run_result
      ~text:
        "SOCIAL_MODEL: bdi_speech_v1\nBELIEF_SUMMARY: quiet_room\nACTIVE_DESIRE: maintain_quiet_readiness\nCURRENT_INTENTION: stay_available_without_noise\nBLOCKER: none\nNEED: none\nSPEECH_ACT: stay_silent\nDELIVERY_SURFACE: silent"
      ~tools:[]
      ~model:"test-model" ~input_tok:50 ~output_tok:10 ()
  in
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let routed, social_state, transition_reason =
        KSM.apply_to_result ~meta:minimal_meta
          ~observation:base_observation ~previous_state:None result
      in
      let updated =
        UM.update_metrics_from_result minimal_meta ~latency_ms:100
          ~observation:base_observation ~social_state
          ~social_transition_reason:
            (KSM.transition_reason_to_string transition_reason)
          routed
      in
      check string "active desire tracked" "maintain_quiet_readiness"
        updated.runtime.last_active_desire;
      check string "current intention tracked" "stay_available_without_noise"
        updated.runtime.last_current_intention;
      check string "speech act tracked" "stay_silent"
        updated.runtime.last_speech_act;
      check string "transition reason tracked" "headers:explicit_social_headers"
        updated.runtime.last_social_transition_reason;
      check string "no blocker tracked" "" updated.runtime.last_blocker;
      check string "no need tracked" "" updated.runtime.last_need)

let test_metrics_failure_response () =
  let reason = "Agent run failed: Max turns exceeded (turn 10, limit 10)" in
  let updated =
    UM.update_metrics_from_failure minimal_meta ~latency_ms:250
      ~observation:base_observation ~reason
      ~social_transition_reason:"failure:run_error" ()
  in
  check int "total_turns +1" (minimal_meta.runtime.usage.total_turns + 1) updated.runtime.usage.total_turns;
  check int "latency recorded" 250 updated.runtime.usage.last_latency_ms;
  check bool "last_turn_ts updated" true (updated.runtime.usage.last_turn_ts > 0.0);
  check int "proactive count +1" (minimal_meta.runtime.proactive_rt.count_total + 1)
    updated.runtime.proactive_rt.count_total;
  check bool "proactive outcome error" true
    (updated.runtime.proactive_rt.last_outcome
     = Masc_mcp.Keeper_types.Proactive_error);
  check bool "failure reason tagged" true
    (let found =
       try
         ignore
           (Str.search_forward
              (Str.regexp_string "unified:error:")
              updated.runtime.proactive_rt.last_reason 0);
         true
       with Not_found -> false
     in
     found);
  check bool "failure preview preserved" true
    (let found =
       try
         ignore
           (Str.search_forward
              (Str.regexp_string "Max turns exceeded")
              updated.runtime.proactive_rt.last_preview 0);
         true
       with Not_found -> false
     in
     found);
  check string "failure transition reason tracked" "failure:run_error"
    updated.runtime.last_social_transition_reason

let test_metrics_failure_timeout_increments_proactive_backoff () =
  let sdk_error =
    Masc_mcp.Oas_worker_named.sdk_error_of_masc_internal_error
      (Masc_mcp.Oas_worker_named.Oas_timeout_budget
         {
           budget_sec = 90.0;
           keeper_turn_timeout_sec = 90.0;
           estimated_input_tokens = 42_000;
           source = "test";
           remaining_turn_budget_sec = Some 0.0;
           min_required_sec = 15.0;
           phase = "test_phase";
         })
  in
  let updated =
    UM.update_metrics_from_failure minimal_meta ~latency_ms:90
      ~observation:base_observation
      ~reason:"OAS budget timeout after 90s" ~sdk_error
      ~social_transition_reason:"failure:run_error" ()
  in
  check int "proactive timeout backoff count +1"
    (minimal_meta.runtime.proactive_rt.consecutive_noop_count + 1)
    updated.runtime.proactive_rt.consecutive_noop_count

let test_metrics_failure_response_redacts_resumable_cli_session_detail () =
  let raw_reason =
    "kimi exited with code 75: \nTo resume this session: kimi -r ff37febe-2adb-4ac6-9dc6-cae23e672fbc"
  in
  let canonical_detail =
    Masc_mcp.Oas_worker_exec.Kimi_cli_transport_local.resumable_session_detail
  in
  let sdk_error =
    Masc_mcp.Oas_worker_named.sdk_error_of_masc_internal_error
      (Masc_mcp.Oas_worker_named.Resumable_cli_session
         {
           cascade_name = oas_error_cascade_name "kimi_cli_keeper";
           detail = canonical_detail;
           exit_code = Some 75;
         })
  in
  let updated =
    UM.update_metrics_from_failure minimal_meta ~latency_ms:250
      ~observation:base_observation ~reason:raw_reason ~sdk_error
      ~social_transition_reason:"failure:run_error" ()
  in
  check string "last reason is redacted"
    ("unified:error:" ^ canonical_detail)
    updated.runtime.proactive_rt.last_reason;
  check string "last preview is redacted"
    canonical_detail
    updated.runtime.proactive_rt.last_preview;
  check string "last blocker is redacted"
    canonical_detail
    updated.runtime.last_blocker;
  check bool "raw resume hint removed from last blocker" false
    (contains_substring updated.runtime.last_blocker "To resume this session:");
  check bool "raw session token removed from last reason" false
    (contains_substring updated.runtime.proactive_rt.last_reason "kimi -r");
  match updated.runtime.last_blocker_class with
  | Some (Keeper_types.Cascade_exhausted (Keeper_types.Other_detail detail)) ->
      check string "blocker class detail preserved as canonical detail"
        canonical_detail detail
  | _ -> fail "expected resumable CLI session blocker class"

let test_prompt_includes_board_activity_section () =
  let obs =
    { base_observation with
      pending_board_events = [ sample_board_event ]
    }
  in
  let _sys, user = UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs () in
  check bool "has board activity section" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "Board Activity") user 0); true
       with Not_found -> false
     in found);
  check bool "includes board event preview" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "Please take a look.") user 0); true
       with Not_found -> false
     in found)

let test_prompt_marks_board_curation_due_for_multi_event_window () =
  let second_board_event =
    {
      sample_board_event with
      post_id = "board-post-2";
      title = "Answer candidate";
      preview = "This may answer the earlier thread.";
    }
  in
  let obs =
    { base_observation with
      pending_board_events = [ sample_board_event; second_board_event ]
    }
  in
  let _sys, user =
    UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs ()
  in
  check bool "marks curation due" true
    (contains_substring user "Curation due");
  check bool "names curation submit tool" true
    (contains_substring user "keeper_board_curation_submit")

let test_prompt_prefers_silence_guidance () =
  let sys, _user = UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:base_observation () in
  check bool "mentions speech act header" true
    (let found =
       try
         ignore (Str.search_forward (Str.regexp_string "SPEECH_ACT:") sys 0);
         true
       with Not_found -> false
     in
     found)

let test_sanitize_text_utf8_replaces_control_chars () =
  let raw = "alpha\000beta\001gamma\127delta\n\tomega" in
  let sanitized = Masc_mcp.Inference_utils.sanitize_text_utf8 raw in
  check bool "no disallowed control chars" false
    (contains_disallowed_control_char sanitized);
  check string "content preserved with spaces"
    "alpha beta gamma delta\n\tomega"
    sanitized

let test_prompt_sanitizes_control_chars () =
  let meta =
    { minimal_meta with
      instructions = "watch\000this";
    }
  in
  let obs =
    { base_observation with
      pending_mentions = [ ("alice", "ping\001pong") ];
      pending_board_events =
        [
          { sample_board_event with
            preview = "bad\127preview";
          };
        ];
    }
  in
  let sys_raw, user_raw =
    UP.build_prompt ~base_path:"/test" ~meta ~observation:obs ()
  in
  (* #6645 intentionally moved UTF-8 sanitization from MASC's
     [build_prompt] to the OAS pipeline boundary (agent.ml,
     pipeline.ml, agent_turn.ml in OAS v0.121.0). MASC callers now
     receive raw strings and the OAS [Agent.run] pipeline scrubs them
     before hitting the LLM. This test mirrors that downstream
     responsibility by invoking [sanitize_text_utf8] on the return
     values post-[build_prompt], confirming the pipeline's invariant:
     disallowed control chars (< 0x20 excl. \t\n\r, and 0x7f) end up
     replaced with spaces so user-controlled bytes never reach the
     LLM raw. See #6656 for the test-only fix; the sanitize call on
     [build_prompt] output itself was deliberately removed by #6645. *)
  let sys = Masc_mcp.Inference_utils.sanitize_text_utf8 sys_raw in
  let user = Masc_mcp.Inference_utils.sanitize_text_utf8 user_raw in
  check bool "system prompt sanitized" false
    (contains_disallowed_control_char sys);
  check bool "user prompt sanitized" false
    (contains_disallowed_control_char user);
  check bool "mention text preserved after sanitize" true
    (contains_substring user "ping pong");
  check bool "board preview preserved after sanitize" true
    (contains_substring user "bad preview")

let test_sanitize_messages_utf8_cleans_history_path () =
  let user_msg =
    Agent_sdk.Types.
      {
        role = User;
        content = [ Text "hist\000ory\127entry" ];
        name = None;
        tool_call_id = None;
      metadata = [];
      }
  in
  let tool_msg =
    Agent_sdk.Types.
      {
        role = Tool;
        content =
          [
            ToolResult
              {
                tool_use_id = "tool\001id";
                content = "result\127payload";
                is_error = false;
                json = Some (`Assoc [("key\000", `String "value\127")]);
              };
          ];
        name = None;
        tool_call_id = None;
      metadata = [];
      }
  in
  let assistant_msg =
    Agent_sdk.Types.
      {
        role = Assistant;
        content =
          [
            ToolUse
              {
                id = "call\001id";
                name = "keeper\127shell";
                input =
                  `Assoc
                    [
                      ("pattern\000", `String "bad\127bytes");
                      ("nested", `List [`String "x\001y"]);
                    ];
              };
          ];
        name = None;
        tool_call_id = None;
        metadata = [];
      }
  in
  let sanitized =
    Masc_mcp.Inference_utils.sanitize_messages_utf8
      [ user_msg; assistant_msg; tool_msg ]
  in
  match sanitized with
  | [ user_msg; assistant_msg; tool_msg ] ->
      check string "user history content sanitized" "hist ory entry"
        (Agent_sdk.Types.text_of_message user_msg);
      (match assistant_msg.Agent_sdk.Types.content with
       | [ Agent_sdk.Types.ToolUse { id; name; input } ] ->
           check string "tool use id sanitized" "call id" id;
           check string "tool use name sanitized" "keeper shell" name;
           (match input with
            | `Assoc
                [
                  (key, `String value);
                  ("nested", `List [`String nested_value]);
                ] ->
                check string "tool use json key sanitized" "pattern " key;
                check string "tool use json value sanitized" "bad bytes" value;
                check string "tool use nested json sanitized" "x y" nested_value
            | _ -> fail "expected sanitized tool use json")
       | _ -> fail "expected sanitized tool use");
      (match tool_msg.Agent_sdk.Types.content with
       | [ Agent_sdk.Types.ToolResult { tool_use_id; content; _ } ] ->
           check string "tool id sanitized" "tool id" tool_use_id;
           check string "tool payload sanitized" "result payload" content;
           (match tool_msg.Agent_sdk.Types.content with
            | [ Agent_sdk.Types.ToolResult { json = Some (`Assoc [ (key, `String value) ]); _ } ] ->
                check string "tool json key sanitized" "key " key;
                check string "tool json value sanitized" "value " value
            | _ -> fail "expected sanitized tool result json")
       | _ -> fail "expected sanitized tool result")
  | _ -> fail "expected three sanitized messages"

let test_sanitize_messages_utf8_reuses_clean_history_list () =
  let msgs =
    [
      Agent_sdk.Types.user_msg "already clean";
      Agent_sdk.Types.assistant_msg "still clean";
    ]
  in
  let sanitized = Masc_mcp.Inference_utils.sanitize_messages_utf8 msgs in
  check bool "same list reused" true (sanitized == msgs)

let test_overflow_detection_and_limit_parsing () =
  check bool "ContextOverflow with limit" true
    (EC.is_context_overflow
       (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = Some 8192 })));
  check (option int) "parses limit via OAS SSOT" (Some 8192)
    (Agent_sdk.Retry.extract_context_limit
       "HTTP 400: prompt exceeds available context size (8192 tokens)");
  check (option int) "no limit in unrelated error" None
    (Agent_sdk.Retry.extract_context_limit "Network error: connection reset");
  check bool "NetworkError not overflow" false
    (EC.is_context_overflow
       (Agent_sdk.Error.Api
          (NetworkError
             { message = "timeout"; kind = Llm_provider.Http_client.Timeout })))

let test_side_effect_timeout_reclassified_as_persistent () =
  let original =
    Agent_sdk.Error.Api
      (Timeout { message = "Execution cancelled after 300.0s" })
  in
  let reclassified =
    EC.reclassify_error_after_side_effect
      ~tool_names:["keeper_fs_edit"] original
  in
  check bool "marked ambiguous partial" true
    (EC.is_ambiguous_side_effect_error reclassified);
  check bool "no longer transient" false
    (EC.is_transient_network_error reclassified);
  check bool "mentions tool name" true
    (contains_substring
       (Agent_sdk.Error.to_string reclassified)
       "keeper_fs_edit")

let test_side_effect_reclassification_requires_committed_tools () =
  let original =
    Agent_sdk.Error.Api
      (Timeout { message = "Execution cancelled after 300.0s" })
  in
  let reclassified =
    EC.reclassify_error_after_side_effect
      ~tool_names:[] original
  in
  check bool "no committed tool keeps transient" true
    (EC.is_transient_network_error reclassified);
  check bool "not marked ambiguous partial" false
    (EC.is_ambiguous_side_effect_error reclassified)

let test_side_effect_reclassification_ignores_read_only_tools () =
  let original =
    Agent_sdk.Error.Api
      (Timeout { message = "Execution cancelled after 300.0s" })
  in
  let reclassified =
    EC.reclassify_error_after_side_effect
      ~tool_names:["keeper_board_list"; "keeper_fs_read"] original
  in
  check bool "read-only timeout stays transient" true
    (EC.is_transient_network_error reclassified);
  check bool "read-only timeout not ambiguous partial" false
    (EC.is_ambiguous_side_effect_error reclassified)

let test_side_effect_reclassification_marks_any_post_commit_error () =
  let original =
    Agent_sdk.Error.Api
      (AuthError { message = "Unauthorized" })
  in
  let reclassified =
    EC.reclassify_error_after_side_effect
      ~tool_names:["keeper_fs_edit"] original
  in
  check bool "auth error stays non-transient" false
    (EC.is_transient_network_error reclassified);
  check bool "auth error becomes ambiguous partial" true
    (EC.is_ambiguous_side_effect_error reclassified)

let test_post_commit_failure_kind_marks_timeouts () =
  let timeout_error =
    Agent_sdk.Error.Api
      (Timeout { message = "Execution cancelled after 300.0s" })
  in
  check string "timeout kind" "post_commit_timeout"
    (KR.ambiguous_partial_commit_kind_to_string
       (EC.post_commit_failure_kind_of_error timeout_error))

let test_post_commit_failure_kind_marks_non_timeouts_as_failures () =
  let auth_error =
    Agent_sdk.Error.Api
      (AuthError { message = "Unauthorized" })
  in
  check string "failure kind" "post_commit_failure"
    (KR.ambiguous_partial_commit_kind_to_string
       (EC.post_commit_failure_kind_of_error auth_error))

let test_server_rejected_parse_error_ollama_closing_brace () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = {|Value looks like object, but can't find closing '}' symbol|} })
  in
  check bool "ollama closing brace is parse error" true
    (EC.is_server_rejected_parse_error err);
  check bool "ollama closing brace is NOT transient network" false
    (EC.is_transient_network_error err)

let test_server_rejected_parse_error_unterminated () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = "Unterminated string in JSON" })
  in
  check bool "unterminated is parse error" true
    (EC.is_server_rejected_parse_error err)

let test_server_rejected_parse_error_unexpected_char () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = "Unexpected character in JSON at position 42" })
  in
  check bool "unexpected character in json is parse error" true
    (EC.is_server_rejected_parse_error err)

let test_server_rejected_parse_error_parse_error () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = "Parse error at position 1024" })
  in
  check bool "parse error is parse error" true
    (EC.is_server_rejected_parse_error err)

let test_server_rejected_parse_error_case_insensitive () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = "PARSE ERROR in request body" })
  in
  check bool "uppercase PARSE ERROR detected" true
    (EC.is_server_rejected_parse_error err)

let test_server_rejected_parse_error_generic_invalid_request () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = "bad tool schema" })
  in
  check bool "generic InvalidRequest is NOT parse error" false
    (EC.is_server_rejected_parse_error err)

let test_server_rejected_parse_error_generic_closing () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = "Service closing for maintenance" })
  in
  check bool "generic 'closing' is NOT parse error" false
    (EC.is_server_rejected_parse_error err)

let test_server_rejected_parse_error_generic_cant_find () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = "Can't find the specified tool 'my_tool'" })
  in
  check bool "generic 'can't find' is NOT parse error" false
    (EC.is_server_rejected_parse_error err)

let test_server_rejected_parse_error_network_error () =
  let err =
    Agent_sdk.Error.Api
      (NetworkError
         {
           message = "connection refused";
           kind = Llm_provider.Http_client.Connection_refused;
         })
  in
  check bool "network error is NOT parse error" false
    (EC.is_server_rejected_parse_error err)

let test_auto_recoverable_turn_error_includes_transient_network () =
  let err =
    Agent_sdk.Error.Api
      (Timeout { message = "Execution cancelled after 300.0s" })
  in
  check bool "timeout is auto-recoverable" true
    (EC.is_auto_recoverable_turn_error err)

let test_auto_recoverable_turn_error_includes_server_parse_rejection () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = "Parse error at position 42" })
  in
  check bool "server parse rejection is auto-recoverable" true
    (EC.is_auto_recoverable_turn_error err)

let test_auto_recoverable_turn_error_includes_wrapped_hard_quota () =
  let err =
    Agent_sdk.Error.Api
      (NetworkError
         {
           message =
             "claude exited with code 1: {\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"api_error_status\":429,\"result\":\"You've hit your limit · resets Apr 24 at 4am (Asia/Seoul)\"}";
           kind = Llm_provider.Http_client.Unknown;
         })
  in
  check bool "wrapped hard quota is auto-recoverable" true
    (EC.is_auto_recoverable_turn_error err)

let test_auto_recoverable_turn_error_includes_wrapped_max_turns () =
  check bool "wrapped CLI max-turns is auto-recoverable" true
    (EC.is_auto_recoverable_turn_error (wrapped_claude_max_turns_error ()))

let test_required_tool_contract_violation_detected () =
  let err =
    Agent_sdk.Error.Agent
      (CompletionContractViolation
         {
           contract = Agent_sdk.Completion_contract_id.Require_tool_use;
           reason =
             "required tool contract unsatisfied: tool_choice requested tool use, but the model returned no ToolUse block";
         })
  in
  check bool "tool-choice contract violation detected" true
    (EC.is_required_tool_contract_violation err)

let test_required_tool_contract_violation_ignores_legacy_internal_error () =
  let err =
    Agent_sdk.Error.Internal
      "Completion contract [require_tool_use] violated: required tool contract unsatisfied: tool_choice requested tool use, but the model returned no ToolUse block"
  in
  check bool "legacy internal contract violation ignored" false
    (EC.is_required_tool_contract_violation err)

(* Rotation-cap threshold: the cap must NOT fire on the very first attempt
   (attempted_cascades length = 1, meaning no rotation has occurred yet).
   Regression for the >= 1 / >= 2 threshold bug where the fast-fail fired
   before any rotation was tried, causing immediate cycle failure instead of
   offering at least one cascade rotation. *)
let test_should_cap_rotation_does_not_fire_on_first_attempt () =
  let err = required_tool_contract_violation_error () in
  check bool "cap must not fire when no rotation has been attempted" false
    (EC.should_cap_rotation_for_contract_violation
       ~attempted_cascades:[ "strict_exec" ]
       ~fallback_not_yet_tried:false
       err)

let test_should_cap_rotation_fires_after_one_rotation () =
  let err = required_tool_contract_violation_error () in
  check bool "cap fires when one rotation has already been attempted" true
    (EC.should_cap_rotation_for_contract_violation
       ~attempted_cascades:[ "strict_exec"; KC.default_cascade_name ]
       ~fallback_not_yet_tried:false
       err)

let test_should_cap_rotation_suppressed_while_fallback_available () =
  let err = required_tool_contract_violation_error () in
  check bool "cap is suppressed when an untried fallback cascade exists" false
    (EC.should_cap_rotation_for_contract_violation
       ~attempted_cascades:[ "strict_exec"; KC.default_cascade_name ]
       ~fallback_not_yet_tried:true
       err)

let test_should_cap_rotation_ignores_non_contract_violation_error () =
  let err = wrapped_claude_limit_error () in
  check bool "cap does not fire for non-contract-violation errors" false
    (EC.should_cap_rotation_for_contract_violation
       ~attempted_cascades:[ "strict_exec"; KC.default_cascade_name ]
       ~fallback_not_yet_tried:false
       err)

let test_cascade_exhausted_error_detected_from_structured_internal_error () =
  let err =
    Masc_mcp.Oas_worker_named.sdk_error_of_masc_internal_error
      (Masc_mcp.Oas_worker_named.Cascade_exhausted
         {
           cascade_name =
             oas_error_cascade_name Masc_mcp.Keeper_config.default_cascade_name;
           reason = Masc_mcp.Keeper_types.All_providers_failed;
         })
  in
  check bool "structured cascade exhausted error detected" true
    (EC.is_cascade_exhausted_error err)

let test_cascade_exhausted_error_ignores_legacy_internal_error () =
  let err =
    Agent_sdk.Error.Internal
      "cascade keeper_unified: all models failed: no providers available"
  in
  check bool "legacy internal cascade exhaustion ignored" false
    (EC.is_cascade_exhausted_error err)

let test_auto_recoverable_turn_error_excludes_required_tool_contract_violation () =
  let err =
    Agent_sdk.Error.Agent
      (CompletionContractViolation
         {
           contract = Agent_sdk.Completion_contract_id.Require_tool_use;
           reason =
             "required tool contract unsatisfied: tool_choice requested tool use, but the model returned no ToolUse block";
         })
  in
  check bool "tool-choice contract violation is not globally auto-recoverable" false
    (EC.is_auto_recoverable_turn_error err)

let test_auto_recoverable_turn_error_excludes_persistent_errors () =
  let err =
    Agent_sdk.Error.Api
      (AuthError { message = "Unauthorized" })
  in
  check bool "auth error is persistent" false
    (EC.is_auto_recoverable_turn_error err)

let test_auto_recoverable_turn_error_includes_wrapped_cascade_exhausted_hard_quota () =
  let err =
    Masc_mcp.Oas_worker_named.sdk_error_of_masc_internal_error
      (Masc_mcp.Oas_worker_named.Cascade_exhausted
         {
           cascade_name =
             oas_error_cascade_name Masc_mcp.Keeper_config.default_cascade_name;
           reason =
             Keeper_types.Other_detail
               "claude exited with code 1: {\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"api_error_status\":429,\"result\":\"You've hit your limit · resets Apr 24 at 4am (Asia/Seoul)\"}";
         })
  in
  check bool "wrapped cascade hard quota is auto-recoverable" true
    (EC.is_auto_recoverable_turn_error err)

let test_auto_recoverable_turn_error_includes_wrapped_cascade_max_turns () =
  check bool "wrapped cascade max-turns is auto-recoverable" true
    (EC.is_auto_recoverable_turn_error (wrapped_cascade_max_turns_error ()))

let test_auto_recoverable_turn_error_includes_filtered_candidates_cascade_exhaustion () =
  let err =
    Masc_mcp.Oas_worker_named.sdk_error_of_masc_internal_error
      (Masc_mcp.Oas_worker_named.Cascade_exhausted
         {
           cascade_name =
             oas_error_cascade_name Masc_mcp.Keeper_config.default_cascade_name;
           reason = Keeper_types.Candidates_filtered_after_cycles;
         })
  in
  check bool "filtered candidates cascade exhaustion is auto-recoverable" true
    (EC.is_auto_recoverable_turn_error err)

let test_auto_recoverable_turn_error_includes_resumable_cli_session_error () =
  let err =
    Masc_mcp.Oas_worker_named.sdk_error_of_masc_internal_error
      (Masc_mcp.Oas_worker_named.Resumable_cli_session
         {
           cascade_name = oas_error_cascade_name "kimi_cli_keeper";
           detail =
             Masc_mcp.Oas_worker_exec.Kimi_cli_transport_local.resumable_session_detail;
           exit_code = Some 75;
         })
  in
  check bool "resumable CLI session error is auto-recoverable" true
    (EC.is_auto_recoverable_turn_error err)

let test_cascade_exhausted_error_includes_resumable_cli_session_error () =
  let err =
    Masc_mcp.Oas_worker_named.sdk_error_of_masc_internal_error
      (Masc_mcp.Oas_worker_named.Resumable_cli_session
         {
           cascade_name = oas_error_cascade_name "kimi_cli_keeper";
           detail =
             Masc_mcp.Oas_worker_exec.Kimi_cli_transport_local.resumable_session_detail;
           exit_code = Some 75;
         })
  in
  check bool "resumable CLI session error is treated as cascade exhaustion surface" true
    (EC.is_cascade_exhausted_error err)

let test_bounded_oas_timeout_uses_adaptive_when_budget_is_large () =
  let estimated_input_tokens = 2_000 in
  let expected =
    Env_config.KeeperKeepalive.oas_timeout_for_estimated_input_tokens
      ~estimated_input_tokens
  in
  match
    UT.bounded_oas_timeout_for_turn_budget
      ~estimated_input_tokens ~remaining_turn_budget_s:1200.0
  with
  | Some timeout_s ->
      (* The bounded variant subtracts a 15s finalization guard from
         [remaining_turn_budget_s] and caps at the adaptive raw.  After
         the bulkhead hard ceiling, [turn_timeout_sec] is 600, so the
         adaptive cap dominates this large remaining-budget case. *)
      check bool "bounded timeout at or below adaptive raw"
        true (timeout_s <= expected);
      check (float 0.01) "bounded uses hard-capped adaptive timeout"
        expected timeout_s
  | None -> fail "expected bounded timeout"

(* #10008 fm2: the budget formula no longer scales with token count,
   so [bounded_oas_timeout_for_turn_budget] returns the same value
   for small and large prompts when the remaining_turn_budget is
   unchanged.  Replaces the prior "smaller prompt gets smaller
   budget" invariant, which was load-bearing on the (removed)
   [per_1k * tokens] term. *)
let test_bounded_oas_timeout_is_token_independent () =
  match
    ( UT.bounded_oas_timeout_for_turn_budget
        ~estimated_input_tokens:2_000 ~remaining_turn_budget_s:1200.0,
      UT.bounded_oas_timeout_for_turn_budget
        ~estimated_input_tokens:262_144 ~remaining_turn_budget_s:1200.0 )
  with
  | Some low_prompt_timeout, Some high_prompt_timeout ->
      check (float 0.01) "token count no longer affects budget"
        low_prompt_timeout high_prompt_timeout
  | _ -> fail "expected bounded timeouts for both prompt sizes"

let test_bounded_oas_timeout_caps_to_remaining_turn_budget () =
  match
    UT.bounded_oas_timeout_for_turn_budget
      ~estimated_input_tokens:2_000 ~remaining_turn_budget_s:235.7
  with
  | Some timeout_s ->
      check (float 0.01) "remaining budget cap leaves finalization guard"
        220.7 timeout_s
  | None -> fail "expected bounded timeout"

let test_bounded_oas_timeout_uses_channel_turn_budget_override () =
  let max_turns =
    Env_config.KeeperKeepalive.oas_max_turns_per_call_scheduled_autonomous
  in
  let estimated_input_tokens = 2_000 in
  let raw =
    Env_config.KeeperKeepalive
    .oas_timeout_for_estimated_input_tokens_with_turn_budget
      ~estimated_input_tokens ~max_turns
  in
  match
    UT.bounded_oas_timeout_for_turn_budget_with_turn_budget
      ~max_turns ~estimated_input_tokens ~remaining_turn_budget_s:1200.0
  with
  | Some timeout_s ->
      (* #10008 fm2: raw formula no longer depends on max_turns;
         bounded variant still subtracts the 15s finalization guard
         from [remaining_turn_budget_s] and caps at the raw.  After
         the bulkhead hard ceiling, the raw 600s cap dominates. *)
      check bool "bounded timeout at or below raw formula output"
        true (timeout_s <= raw);
      check (float 0.01) "bounded uses channel hard-capped raw timeout"
        raw timeout_s
  | None -> fail "expected bounded timeout"

let test_bounded_oas_timeout_reserves_degraded_retry_budget () =
  match
    UT.resolve_bounded_oas_timeout_budget_with_turn_budget
      ~allow_wall_clock_retry_budget:false
      ~is_retry:false ~reserve_degraded_retry_budget:true
      ~estimated_input_tokens:2_000 ~max_turns:4
      ~remaining_turn_budget_s:500.0
  with
  | Some budget ->
      check (float 0.01)
        "first attempt keeps half the usable turn budget for fallback"
        242.5 budget.effective_timeout_sec;
      check (float 0.01) "remaining budget records raw wall-clock remaining"
        500.0 budget.remaining_turn_budget_sec;
      check string "source records retry reserve"
        "adaptive_estimated_input_tokens_capped_by_degraded_retry_budget"
        budget.source
  | None -> fail "expected bounded timeout"

let test_attempt_watchdog_preserves_degraded_retry_reserve () =
  match
    UT.resolve_bounded_oas_timeout_budget_with_turn_budget
      ~allow_wall_clock_retry_budget:false
      ~is_retry:false ~reserve_degraded_retry_budget:true
      ~estimated_input_tokens:2_000 ~max_turns:4
      ~remaining_turn_budget_s:500.0
  with
  | Some budget ->
      check (float 0.01)
        "attempt watchdog includes OAS timeout plus finalization guard"
        257.5
        (UT.attempt_watchdog_timeout_sec
           ~remaining_turn_budget_s:500.0
           budget)
  | None -> fail "expected bounded timeout"

let test_attempt_watchdog_fires_before_outer_turn_timeout () =
  let budget =
    {
      UT.effective_timeout_sec = 293.0;
      adaptive_timeout_sec = 600.0;
      keeper_turn_timeout_sec = 600.0;
      remaining_turn_budget_sec = 293.0;
      estimated_input_tokens = 2_000;
      max_turns = 4;
      source = "adaptive_per_attempt_retry";
    }
  in
  check (float 0.01)
    "retry watchdog is capped just before the enclosing turn timeout"
    292.0
    (UT.attempt_watchdog_timeout_sec
       ~remaining_turn_budget_s:293.0
       budget)

let test_bounded_oas_timeout_refuses_too_little_budget () =
  check (option (float 0.01)) "insufficient budget returns none" None
    (UT.bounded_oas_timeout_for_turn_budget
       ~estimated_input_tokens:2_000 ~remaining_turn_budget_s:20.0)

let test_oas_timeout_reclassifies_only_current_attempt_budget () =
  let err =
    Agent_sdk.Error.Api
      (Timeout { message = "Timeout after 273.0s (budget=273s)" })
  in
  match
    UT.resolve_bounded_oas_timeout_budget_with_turn_budget
      ~allow_wall_clock_retry_budget:false
      ~is_retry:false ~reserve_degraded_retry_budget:false
      ~estimated_input_tokens:2_000 ~max_turns:4
      ~remaining_turn_budget_s:1200.0
  with
  | None -> fail "expected timeout budget"
  | Some timeout_budget ->
      let classified =
        UT.reclassify_oas_timeout_for_attempt
          ~timeout_budget:(Some timeout_budget)
          err
      in
      (match
         Masc_mcp.Oas_worker_named.classify_masc_internal_error classified
       with
       | Some (Masc_mcp.Oas_worker_named.Oas_timeout_budget budget) ->
           check int "estimated tokens preserved" 2_000
             budget.estimated_input_tokens;
           check string "source preserved" timeout_budget.source budget.source;
           check (option (float 0.001)) "remaining budget preserved"
             (Some timeout_budget.remaining_turn_budget_sec)
             budget.remaining_turn_budget_sec;
           check string "phase" "cascade_attempt_watchdog" budget.phase
       | _ -> fail "expected OAS timeout budget classification")

let test_pre_retry_timeout_helper_does_not_reuse_stale_budget () =
  let err =
    Agent_sdk.Error.Api
      (Timeout
         {
           message =
             "Turn wall-clock budget exhausted before retry (remaining=2.0s)";
         })
  in
  let classified =
    UT.reclassify_oas_timeout_for_attempt ~timeout_budget:None err
  in
  check bool "plain helper call without budget stays raw timeout" true
    (Option.is_none
       (Masc_mcp.Oas_worker_named.classify_masc_internal_error classified))

let oas_timeout_budget_error () =
  Masc_mcp.Oas_worker_named.sdk_error_of_masc_internal_error
    (Masc_mcp.Oas_worker_named.Oas_timeout_budget
       {
         budget_sec = 273.0;
         keeper_turn_timeout_sec = 1200.0;
         estimated_input_tokens = 2_000;
         source = "adaptive_estimated_input_tokens";
         remaining_turn_budget_sec = Some 600.0;
         min_required_sec = 15.0;
         phase = "test_phase";
       })

let test_degraded_retry_budget_gate_allows_remaining_budget () =
  match
    UT.next_fail_open_cascade_for_turn_with_budget
      ~base_cascade:"underdog"
      ~effective_cascade:"underdog"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_cascades:[ "underdog" ]
      ~estimated_input_tokens:2_000
      ~max_turns:4
      ~remaining_turn_budget_s:1200.0
      (oas_timeout_budget_error ())
  with
  | UT.Degraded_retry_allowed retry ->
      check string "retry cascade" KC.local_recovery_cascade_name
        retry.next_cascade;
      check string "fallback reason" "oas_timeout_budget"
        retry.fallback_reason
  | UT.Degraded_retry_slot_phase_exhausted _ ->
      fail "expected productive slot phase budget to remain"
  | UT.Degraded_retry_budget_exhausted _ ->
      fail "expected retry budget to remain"
  | UT.No_degraded_retry -> fail "expected degraded retry"

let test_degraded_retry_budget_gate_blocks_exhausted_budget () =
  match
    UT.next_fail_open_cascade_for_turn_with_budget
      ~base_cascade:"underdog"
      ~effective_cascade:"underdog"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_cascades:[ "underdog" ]
      ~estimated_input_tokens:2_000
      ~max_turns:4
      ~remaining_turn_budget_s:0.0
      (oas_timeout_budget_error ())
  with
  | UT.Degraded_retry_budget_exhausted retry ->
      check string "retry cascade candidate" KC.local_recovery_cascade_name
        retry.next_cascade;
      check string "fallback reason" "oas_timeout_budget"
        retry.fallback_reason
  | UT.Degraded_retry_slot_phase_exhausted _ ->
      fail "expected exhausted retry budget, not slot phase budget"
  | UT.Degraded_retry_allowed _ -> fail "expected exhausted retry budget"
  | UT.No_degraded_retry -> fail "expected recoverable retry candidate"

let test_degraded_retry_slot_phase_allows_oas_timeout_local_recovery () =
  match
    UT.next_fail_open_cascade_for_turn_with_budget
      ~base_cascade:"underdog"
      ~effective_cascade:"underdog"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_cascades:[ "underdog" ]
      ~estimated_input_tokens:2_000
      ~max_turns:4
      ~time_spent_in_turn_s:(UT.degraded_retry_slot_phase_budget_sec +. 1.0)
      ~remaining_turn_budget_s:300.0
      (oas_timeout_budget_error ())
  with
  | UT.Degraded_retry_allowed retry ->
      check string "retry cascade candidate" KC.local_recovery_cascade_name
        retry.next_cascade;
      check string "fallback reason" "oas_timeout_budget"
        retry.fallback_reason
  | UT.Degraded_retry_slot_phase_exhausted _ ->
      fail "expected OAS timeout budget to bypass slot phase for local recovery"
  | UT.Degraded_retry_budget_exhausted _ ->
      fail "expected retry budget to remain"
  | UT.No_degraded_retry -> fail "expected recoverable retry candidate"

let test_degraded_retry_slot_phase_allows_first_contract_rotation () =
  match
    UT.next_fail_open_cascade_for_turn_with_budget
      ~base_cascade:KC.default_cascade_name
      ~effective_cascade:"strict_exec"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Required
      ~attempted_cascades:[ "strict_exec" ]
      ~estimated_input_tokens:2_000
      ~max_turns:4
      ~time_spent_in_turn_s:(UT.degraded_retry_slot_phase_budget_sec +. 1.0)
      ~remaining_turn_budget_s:1200.0
      (required_tool_contract_violation_error ())
  with
  | UT.Degraded_retry_allowed retry ->
      check string "retry cascade candidate" KC.default_cascade_name
        retry.next_cascade;
      check string "fallback reason" "required_tool_contract_violation"
        retry.fallback_reason
  | UT.Degraded_retry_slot_phase_exhausted _ ->
      fail "expected first contract rotation to bypass productive slot phase"
  | UT.Degraded_retry_budget_exhausted _ ->
      fail "expected retry budget to remain"
  | UT.No_degraded_retry -> fail "expected recoverable retry candidate"

(* Regression: GitHub #12675 / RFC #12887 — per-attempt retry budget cap.
   When is_retry=true, the budget resolution must refuse the retry if the
   time spent in the current turn exceeds the adaptive per-attempt budget.
   This prevents a retry loop from holding the outer slot for the entire
   turn timeout (600s). *)
let test_per_attempt_retry_budget_with_near_zero_remaining () =
  match
    UT.resolve_bounded_oas_timeout_budget_with_turn_budget
      ~allow_wall_clock_retry_budget:false
      ~is_retry:true
      ~reserve_degraded_retry_budget:false
      ~estimated_input_tokens:2_000
      ~max_turns:4
      ~remaining_turn_budget_s:3.0
  with
  | None -> () (* expected: retry is aborted to release the slot cleanly *)
  | Some _ ->
      fail
        "is_retry=true must refuse budget when outer turn time spent exceeds \
         per-attempt cap"

let test_per_attempt_retry_budget_capped_by_remaining_when_healthy () =
  match
    UT.resolve_bounded_oas_timeout_budget_with_turn_budget
      ~allow_wall_clock_retry_budget:false
      ~is_retry:true
      ~reserve_degraded_retry_budget:false
      ~estimated_input_tokens:2_000
      ~max_turns:4
      ~remaining_turn_budget_s:1200.0
  with
  | None -> fail "is_retry=true should resolve with healthy remaining"
  | Some budget ->
      check bool "effective capped by min(adaptive, remaining)" true
        (budget.effective_timeout_sec <= 1200.0)

let test_per_attempt_retry_blocks_after_adaptive_budget_spent () =
  match
    UT.resolve_bounded_oas_timeout_budget_with_turn_budget
      ~allow_wall_clock_retry_budget:false
      ~is_retry:true
      ~reserve_degraded_retry_budget:false
      ~estimated_input_tokens:2_000
      ~max_turns:4
      ~remaining_turn_budget_s:300.0
  with
  | None -> ()
  | Some _ ->
      fail "plain retry should refuse once the adaptive budget was already spent"

let test_degraded_retry_wall_clock_budget_allows_remaining_turn_time () =
  match
    UT.resolve_bounded_oas_timeout_budget_with_turn_budget
      ~allow_wall_clock_retry_budget:true
      ~is_retry:true
      ~reserve_degraded_retry_budget:false
      ~estimated_input_tokens:2_000
      ~max_turns:4
      ~remaining_turn_budget_s:300.0
  with
  | None -> fail "degraded retry should use remaining wall-clock budget"
  | Some budget ->
      check string "source marks wall-clock retry"
        "adaptive_wall_clock_retry" budget.source;
      check (float 0.01) "wall-clock retry leaves finalization guard"
        285.0 budget.effective_timeout_sec

let test_degraded_retry_wall_clock_budget_gate_is_one_shot () =
  let allowed ~degraded_rotation_first_attempt ~attempt ~attempted_cascades =
    UT.allow_wall_clock_retry_budget_for_attempt
      ~is_retry:true
      ~degraded_rotation_first_attempt
      ~attempt
      ~attempted_cascades
  in
  let rotated_cascades = [ "local_recovery"; "underdog" ] in
  check bool "first degraded rotation attempt may use wall clock" true
    (allowed ~degraded_rotation_first_attempt:true ~attempt:1
       ~attempted_cascades:rotated_cascades);
  check bool "same-cascade retry after rotation uses per-attempt budget" false
    (allowed ~degraded_rotation_first_attempt:false ~attempt:2
       ~attempted_cascades:rotated_cascades);
  check bool "attempt counter still blocks later retries" false
    (allowed ~degraded_rotation_first_attempt:true ~attempt:2
       ~attempted_cascades:rotated_cascades);
  check bool "non-rotated retry cannot use wall clock" false
    (allowed ~degraded_rotation_first_attempt:true ~attempt:1
       ~attempted_cascades:[ "underdog" ])

let test_non_retry_still_refuses_tiny_budget () =
  match
    UT.resolve_bounded_oas_timeout_budget_with_turn_budget
      ~allow_wall_clock_retry_budget:false
      ~is_retry:false
      ~reserve_degraded_retry_budget:false
      ~estimated_input_tokens:2_000
      ~max_turns:4
      ~remaining_turn_budget_s:20.0
  with
  | None -> ()
  | Some _ ->
      fail "is_retry=false should refuse budget when remaining < guard + min"

let test_per_attempt_retry_refuses_zero_remaining () =
  (* Wall-clock gate: a retry with 0.0s remaining would be immediately
     cancelled by the outer turn timeout — resolver must return None. *)
  match
    UT.resolve_bounded_oas_timeout_budget_with_turn_budget
      ~allow_wall_clock_retry_budget:false
      ~is_retry:true
      ~reserve_degraded_retry_budget:false
      ~estimated_input_tokens:2_000
      ~max_turns:4
      ~remaining_turn_budget_s:0.0
  with
  | None -> ()
  | Some _ ->
      fail "is_retry=true with 0.0s remaining should return None"

let test_degraded_retry_budget_gate_allows_retry_with_tiny_remaining () =
  (* Regression: GitHub #12675 — this simulates the real call-site scenario:
     a *first-attempt* failure (is_retry=false at the call site) triggers
     degraded-retry scheduling when wall-clock remaining is very small (3s).

     Before the fix, the gate received the current attempt's is_retry=false
     and evaluated budget using the non-retry guard+reserve path, which
     rejected the degraded retry because remaining (3s) < guard+min (30s).
     The fix removes the is_retry parameter from the gate and always evaluates
     the *candidate* (which is always a retry) with per-attempt semantics. *)
  match
    UT.next_fail_open_cascade_for_turn_with_budget
      ~base_cascade:"underdog"
      ~effective_cascade:"underdog"
      ~tool_requirement:Masc_mcp.Keeper_agent_tool_surface.Optional
      ~attempted_cascades:[ "underdog" ]
      ~estimated_input_tokens:2_000
      ~max_turns:4
      ~remaining_turn_budget_s:3.0
      (oas_timeout_budget_error ())
  with
  | UT.Degraded_retry_budget_exhausted _ -> ()
  | UT.Degraded_retry_allowed _ ->
      fail "expected retry aborted due to per-attempt cap exceeded"
  | UT.Degraded_retry_slot_phase_exhausted _ ->
      fail "expected retry budget exhaustion without slot phase input"
  | UT.No_degraded_retry -> fail "expected degraded retry"

let test_pure_local_labels_detection () =
  check bool "ollama-only cascade is pure local" true
    (OMR.labels_are_pure_local [ "ollama:qwen3.5:35b-a3b-nvfp4" ]);
  check bool "mixed cascade is not pure local" false
    (OMR.labels_are_pure_local [ "glm:glm-5.1"; "ollama:qwen3.5:35b-a3b-nvfp4" ])

let test_clamp_context_for_pure_local_labels () =
  let local_floor = Env_config.ContextCompact.small_local_floor in
  check int "pure local max_context gets capped" local_floor
    (OMR.clamp_context_for_pure_local_labels
       ~labels:[ "ollama:qwen3.5:35b-a3b-nvfp4" ]
       ~max_context:262_144);
  check int "mixed cascade keeps raw context" 262_144
    (OMR.clamp_context_for_pure_local_labels
       ~labels:[ "glm:glm-5.1"; "ollama:qwen3.5:35b-a3b-nvfp4" ]
       ~max_context:262_144)

let test_resolved_max_context_for_turn_uses_primary_budget () =
  let labels = [ "glm:glm-5.1"; "ollama:qwen3.5:35b-a3b-nvfp4" ] in
  let expected = OMR.resolve_primary_max_context labels in
  check int "turn budget follows primary available model" expected
    (UT.resolved_max_context_for_turn ~meta:minimal_meta labels)

let test_max_context_resolution_separates_override_and_effective_budget () =
  let labels = [ "unknown:model" ] in
  let resolution =
    KEC.resolve_max_context_resolution
      ~requested_override:(Some 1_000_000) labels
  in
  check int "primary budget uses fallback context window"
    Masc_mcp.Cascade_runtime.fallback_context_window
    resolution.primary_budget;
  check int "turn budget preserves requested override" 1_000_000
    resolution.turn_budget;
  check int "effective budget caps to primary budget"
    resolution.primary_budget resolution.effective_budget

let test_resolved_max_context_for_turn_uses_effective_budget () =
  let labels = [ "unknown:model" ] in
  let meta = { minimal_meta with max_context_override = Some 1_000_000 } in
  let resolution =
    KEC.resolve_max_context_resolution
      ~requested_override:meta.max_context_override labels
  in
  check int "turn dispatch budget is capped to effective budget"
    resolution.effective_budget
    (UT.resolved_max_context_for_turn ~meta labels)

let test_side_effect_reclassification_ignores_keeper_read_only_tools () =
  let original =
    Agent_sdk.Error.Api
      (Timeout { message = "Execution cancelled after 300.0s" })
  in
  let reclassified =
    EC.reclassify_error_after_side_effect
      ~tool_names:["keeper_tasks_list"; "keeper_memory_search"] original
  in
  check bool "read-only keeper tools stay transient" true
    (EC.is_transient_network_error reclassified);
  check bool "read-only keeper tools are not ambiguous" false
    (EC.is_ambiguous_side_effect_error reclassified)

let test_side_effect_reclassification_drops_keeper_read_only_tools_from_mixed_set () =
  let original =
    Agent_sdk.Error.Api
      (Timeout { message = "Execution cancelled after 300.0s" })
  in
  let reclassified =
    EC.reclassify_error_after_side_effect
      ~tool_names:["keeper_tasks_list"; "keeper_fs_edit"; "keeper_memory_search"]
      original
  in
  let rendered = Agent_sdk.Error.to_string reclassified in
  check bool "mixed set is ambiguous" true
    (EC.is_ambiguous_side_effect_error reclassified);
  check bool "keeps mutating tool" true
    (contains_substring rendered "keeper_fs_edit");
  check bool "drops tasks_list from ambiguous set" false
    (contains_substring rendered "keeper_tasks_list");
  check bool "drops memory_search from ambiguous set" false
    (contains_substring rendered "keeper_memory_search")

let test_metrics_mixed_response () =
  let result =
    make_run_result ~text:"Done." ~tools:["keeper_fs_edit"]
      ~model:"test-model" ~input_tok:150 ~output_tok:60 ()
  in
  let updated =
    UM.update_metrics_from_result minimal_meta ~latency_ms:300
      ~observation:base_observation result
  in
  check int "proactive +1" (minimal_meta.runtime.proactive_rt.count_total + 1)
    updated.runtime.proactive_rt.count_total;
  check int "proactive visible_count +1"
    (minimal_meta.runtime.proactive_rt.visible_count_total + 1)
    updated.runtime.proactive_rt.visible_count_total;
  check bool "proactive outcome mixed" true
    (updated.runtime.proactive_rt.last_outcome
     = Masc_mcp.Keeper_types.Proactive_mixed_response);
  check int "autonomous +1" (minimal_meta.runtime.autonomous_action_count + 1)
    updated.runtime.autonomous_action_count;
  check bool "proactive reason has unified" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "unified:tools=") updated.runtime.proactive_rt.last_reason 0); true
       with Not_found -> false
     in found)

let test_normalize_response_text_passthrough () =
  match KTD.normalize_response_text ~text:"All good." ~tool_names:[] () with
  | Ok text -> check string "keeps text" "All good." text
  | Error e -> fail ("unexpected error: " ^ e)

let test_normalize_response_text_tool_only_synthesizes () =
  match KTD.normalize_response_text
          ~text:""
          ~tool_names:["keeper_board_post"; "keeper_board_comment"]
          ()
  with
  | Ok text ->
      check bool "mentions no textual reply" true
        (String.length text > 0
         && String.contains text 'T');
      check bool "mentions first tool" true
        (let found =
           try
             ignore
               (Str.search_forward
                  (Str.regexp_string "keeper_board_post")
                  text 0);
             true
           with Not_found -> false
         in
         found)
  | Error e -> fail ("unexpected error: " ^ e)

let test_normalize_response_text_empty_without_tools_errors () =
  match KTD.normalize_response_text ~text:"" ~tool_names:[] () with
  | Ok text -> fail ("expected error, got: " ^ text)
  | Error e ->
      check bool "error mentions textual reply" true
        (let found =
           try
             ignore
               (Str.search_forward
                  (Str.regexp_string "no textual reply")
                  e 0);
             true
           with Not_found -> false
         in
         found)

let test_validate_completion_contract_allows_text_without_tools () =
  match
    KTD.validate_completion_contract
      ~contract:KTD.Allow_text_or_tool
      ~tool_names:[]
      ()
  with
  | Ok () -> ()
  | Error e -> fail ("unexpected error: " ^ e)

let test_validate_completion_contract_requires_tool_use () =
  match
    KTD.validate_completion_contract
      ~contract:KTD.Require_tool_use
      ~tool_names:[]
      ()
  with
  | Ok () -> fail "expected tool contract failure"
  | Error e ->
      check bool "error mentions required tool contract" true
        (contains_substring e "required tool contract")

let test_validate_completion_contract_accepts_stay_silent () =
  match
    KTD.validate_completion_contract
      ~contract:KTD.Require_tool_use
      ~tool_names:["keeper_stay_silent"]
      ()
  with
  | Ok () -> ()
  | Error e -> fail ("unexpected error: " ^ e)

let test_unexpected_tool_names_accepts_keeper_surface () =
  check (list string) "no unexpected tools" []
    (KTD.unexpected_tool_names
       ~allowed_tool_names:
         [ "keeper_task_claim"; "keeper_board_comment"; "extend_turns" ]
       ~tool_names:[ "keeper_task_claim"; "extend_turns" ])

let test_unexpected_tool_names_reports_foreign_surface () =
  check (list string) "foreign tools flagged"
    [ "Skill"; "Bash"; "Agent" ]
    (KTD.unexpected_tool_names
       ~allowed_tool_names:
         [ "keeper_task_claim"; "keeper_board_comment"; "extend_turns" ]
       ~tool_names:
         [ "keeper_task_claim"; "Skill"; "Bash"; "Skill"; "Agent" ])

let test_completion_contract_of_tool_choice_allows_auto () =
  check bool "auto allows text" true
    (match KTD.completion_contract_of_tool_choice None with
     | KTD.Allow_text_or_tool -> true
     | KTD.Require_tool_use -> false);
  check bool "none allows text" true
    (match KTD.completion_contract_of_tool_choice (Some Agent_sdk.Types.None_) with
     | KTD.Allow_text_or_tool -> true
     | KTD.Require_tool_use -> false)

let test_completion_contract_of_tool_choice_requires_any () =
  check bool "any requires tool use" true
    (match KTD.completion_contract_of_tool_choice (Some Agent_sdk.Types.Any) with
     | KTD.Require_tool_use -> true
     | KTD.Allow_text_or_tool -> false)

let test_run_completion_contract_latches_required_tool_use () =
  check bool "required tool use stays latched across run" true
    (match
       KTD.run_completion_contract
         ~turn_contract:KTD.Allow_text_or_tool
         ~required_tool_use_seen:true
     with
     | KTD.Require_tool_use -> true
     | KTD.Allow_text_or_tool -> false);
  check bool "optional stays optional when no required turn seen" true
    (match
       KTD.run_completion_contract
         ~turn_contract:KTD.Allow_text_or_tool
         ~required_tool_use_seen:false
     with
     | KTD.Allow_text_or_tool -> true
     | KTD.Require_tool_use -> false)

let test_validate_completion_contract_presence_requires_keeper_surface_tool () =
  (match
     KTD.validate_completion_contract_presence
       ~contract:KTD.Require_tool_use
       ~tool_present:true
   with
   | Ok () -> ()
   | Error e -> fail ("unexpected error: " ^ e));
  match
    KTD.validate_completion_contract_presence
      ~contract:KTD.Require_tool_use
      ~tool_present:false
  with
  | Ok () -> fail "expected keeper-surface contract failure"
  | Error e ->
    check bool "error mentions keeper-surface tools" true
      (contains_substring e "keeper-surface tools")

let test_actionable_tool_contract_flags_no_tools () =
  match
    KTD.actionable_tool_contract_violation_reason
      ~claim_context_allowed:true
      ~actionable_signal_context:true
      ~tool_names:[]
  with
  | Some reason ->
      check bool "reason mentions no keeper tools" true
        (contains_substring reason "no keeper tools")
  | None -> fail "expected actionable no-tool violation"

let test_actionable_tool_contract_flags_passive_only_tools () =
  match
    KTD.actionable_tool_contract_violation_reason
      ~claim_context_allowed:true
      ~actionable_signal_context:true
      ~tool_names:[ "keeper_board_get"; "masc_status" ]
  with
  | Some reason ->
      check bool "reason mentions passive tools" true
        (contains_substring reason "passive status/read tools")
  | None -> fail "expected actionable passive-only violation"

let test_actionable_tool_contract_rejects_claim_context_when_already_claimed () =
  let () =
    match
      KTD.actionable_tool_contract_violation_reason
        ~claim_context_allowed:false
        ~actionable_signal_context:true
        ~tool_names:[ "keeper_task_claim" ]
    with
    | Some reason ->
        check bool "reason mentions execution progress" true
          (contains_substring reason "without execution progress")
    | None -> fail "expected actionable claim-context-only violation"
  in
  check (option string) "claim context is allowed before ownership" None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:true
       ~tool_names:[ "keeper_task_claim" ])

let test_actionable_tool_contract_rejects_stay_silent_when_already_claimed () =
  let check_violation label tool_names =
    match
      KTD.actionable_tool_contract_violation_reason
        ~claim_context_allowed:false
        ~actionable_signal_context:true
        ~tool_names
    with
    | Some reason ->
        check bool (label ^ " mentions owned active task") true
          (contains_substring reason "owned active task");
        check bool (label ^ " mentions execution progress") true
          (contains_substring reason "without execution progress")
    | None -> fail (label ^ ": expected owned-task silence violation")
  in
  check_violation "stay_silent alone" [ "keeper_stay_silent" ];
  check_violation "stay_silent plus passive"
    [ "keeper_stay_silent"; "keeper_tasks_list"; "masc_status" ];
  check_violation "claim plus passive"
    [ "keeper_task_claim"; "keeper_tasks_list" ];
  check (option string) "task completion still satisfies owned task" None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:false
       ~actionable_signal_context:true
       ~tool_names:[ "keeper_task_done" ])

let test_claim_tool_classification_covers_masc_claim_task () =
  check bool "keeper claim is claim tool" true
    (KTD.is_claim_tool_name "keeper_task_claim");
  check bool "masc claim next is claim tool" true
    (KTD.is_claim_tool_name "masc_claim_next");
  check bool "masc claim task is claim tool" true
    (KTD.is_claim_tool_name "masc_claim_task");
  check bool "task creation is not claim tool" false
    (KTD.is_claim_tool_name "keeper_task_create");
  check bool "task list is not claim tool" false
    (KTD.is_claim_tool_name "keeper_tasks_list")

let test_actionable_tool_contract_allows_execution_tools () =
  check (option string) "execution tool satisfies actionable signal" None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:true
       ~tool_names:[ "keeper_bash"; "masc_status" ]);
  check (option string) "non-actionable no-op remains allowed" None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:false
       ~tool_names:[])

let test_stay_silent_requires_typed_no_work_proof_on_actionable_signal () =
  (* keeper_stay_silent has effect_domain=Read_only in tool_catalog but is
     classified as Completion in completion_tool_names, so it can still
     satisfy a plain required-tool contract.  On an actionable world signal,
     however, stay_silent must not close the turn unless the typed observation
     path already proved there is no actionable work. *)
  check bool "stay_silent satisfies required contract" true
    (KTD.tool_name_can_satisfy_required_contract "keeper_stay_silent");
  check bool "completion tool set includes stay_silent" true
    (KTD.is_completion_tool_name "keeper_stay_silent");
  (match
     KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:true
       ~tool_names:[ "keeper_stay_silent"; "keeper_tasks_list" ]
   with
   | Some reason ->
       check bool "reason mentions typed no-work proof" true
         (contains_substring reason "typed no-work proof")
   | None -> fail "expected stay_silent actionable violation");
  check (option string) "execution plus stay_silent remains accepted" None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:true
       ~tool_names:[ "keeper_board_comment"; "keeper_stay_silent" ]);
  check (option string) "owned-task progress plus stay_silent remains accepted" None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:false
       ~actionable_signal_context:true
       ~tool_names:[ "keeper_bash"; "keeper_stay_silent" ]);
  check (option string) "non-actionable stay_silent remains allowed" None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:false
       ~tool_names:[ "keeper_stay_silent" ]);
  (* Without stay_silent, passive-only still violates *)
  check bool "passive-only still violates" true
    (Option.is_some
       (KTD.actionable_tool_contract_violation_reason
          ~claim_context_allowed:true
          ~actionable_signal_context:true
          ~tool_names:[ "keeper_tasks_list"; "masc_status" ]))

let required_tool_call name input
  : Agent_sdk.Completion_contract.tool_call
  =
  { name; input; tool = None }

let satisfies_required_tool name input =
  Result.is_ok
    (KTD.required_tool_satisfaction (required_tool_call name input))

let test_required_tool_satisfaction_rejects_passive_tools () =
  check bool "masc_status is passive" false
    (satisfies_required_tool "masc_status" (`Assoc []));
  check bool "keeper_tasks_list is passive" false
    (satisfies_required_tool "keeper_tasks_list" (`Assoc []));
  (* keeper_stay_silent is a Completion tool and intentionally satisfies
     the required-tool contract despite its Read_only effect_domain.
     See keeper_tool_disclosure.ml is_completion_tool_name exemption. *)
  check bool "keeper_stay_silent satisfies as completion" true
    (satisfies_required_tool "keeper_stay_silent" (`Assoc []));
  check bool "Read alias is passive" false
    (satisfies_required_tool "Read" (`Assoc []));
  check bool "read-only gh shell is passive" false
    (satisfies_required_tool "keeper_shell"
       (`Assoc
          [
            ("op", `String "gh");
            ("cmd", `String "pr view 123");
          ]))

let test_required_tool_satisfaction_accepts_mutating_tools () =
  check bool "keeper_task_claim mutates" true
    (satisfies_required_tool "keeper_task_claim" (`Assoc []));
  check bool "Write alias mutates" true
    (satisfies_required_tool "Write" (`Assoc []));
  check bool "mutating gh shell satisfies" true
    (satisfies_required_tool "keeper_shell"
       (`Assoc
          [
            ("op", `String "gh");
            ("cmd", `String "pr comment 123 --body ok");
          ]))

let test_tool_usage_delta_uses_registry_counts () =
  let before =
    [
      ("keeper_board_post", 1);
      ("keeper_fs_read", 0);
      ("keeper_voice_agent", 2);
    ]
  in
  let after =
    [
      ("keeper_board_post", 1);
      ("keeper_fs_read", 1);
      ("keeper_voice_agent", 4);
    ]
  in
  check (list string) "delta tracks repeated calls"
    [ "keeper_fs_read"; "keeper_voice_agent"; "keeper_voice_agent" ]
    (KTD.tool_usage_delta ~before ~after)

let test_tool_usage_delta_ignores_removed_tools () =
  let before =
    [
      ("keeper_board_post", 2);
      ("keeper_voice_agent", 1);
    ]
  in
  let after =
    [
      ("keeper_board_post", 2);
    ]
  in
  check (list string) "no phantom tools when counts drop"
    []
    (KTD.tool_usage_delta ~before ~after)

let test_merge_observed_tool_names_prefers_hook_without_double_counting () =
  let merged =
    KTD.merge_observed_tool_names
      ~hook_observed_tool_names:[ "keeper_bash"; "keeper_pr_create" ]
      ~registry_observed_tool_names:
        [ "keeper_bash"; "keeper_pr_create"; "keeper_board_post" ]
  in
  check (list string) "hook evidence plus registry-only tail"
    [ "keeper_bash"; "keeper_pr_create"; "keeper_board_post" ]
    merged

let test_merge_observed_tool_names_preserves_extra_registry_repeats () =
  let merged =
    KTD.merge_observed_tool_names
      ~hook_observed_tool_names:[ "keeper_bash" ]
      ~registry_observed_tool_names:[ "keeper_bash"; "keeper_bash" ]
  in
  check (list string) "max count per observed source"
    [ "keeper_bash"; "keeper_bash" ]
    merged

let test_merge_reported_and_observed_tool_names_preserves_synthetic_tools () =
  let merged =
    KTD.merge_reported_and_observed_tool_names
      ~reported_tool_names:[ "keeper_board_post" ]
      ~observed_tool_names:[ "keeper_voice_agent"; "keeper_voice_agent" ]
  in
  check (list string) "observed dispatch plus synthetic tool"
    [ "keeper_voice_agent"; "keeper_voice_agent"; "keeper_board_post" ]
    merged

let test_final_keeper_tool_names_falls_back_to_reported_tool_use () =
  let final_tools =
    KTD.final_keeper_tool_names
      ~reported_tool_names:[ "keeper_task_claim"; "Bash"; "Skill" ]
      ~observed_tool_names:[]
      ~allowed_tool_names:[ "keeper_task_claim"; "keeper_bash" ]
  in
  check (list string) "reported keeper tool plus alias preserved"
    [ "keeper_task_claim"; "keeper_bash" ]
    final_tools

let test_final_keeper_tool_names_accepts_reported_mcp_keeper_tool () =
  let final_tools =
    KTD.final_keeper_tool_names
      ~reported_tool_names:
        [ "mcp__masc__masc_board_post"; "list_mcp_resources" ]
      ~observed_tool_names:[]
      ~allowed_tool_names:[ "keeper_board_post"; "keeper_bash" ]
  in
  check (list string) "reported MCP keeper tool preserved"
    [ "keeper_board_post" ]
    final_tools;
  check (option string) "reported execution tool satisfies actionable signal" None
    (KTD.actionable_tool_contract_violation_reason
       ~claim_context_allowed:true
       ~actionable_signal_context:true
       ~tool_names:final_tools)

(* prioritized_disclosed_tool_names tests removed: function replaced
   by OAS Tool_selector.select in #5429 boundary cleanup. *)

let test_tool_query_text_of_user_message_strips_continuity_noise () =
  let user_message =
    "## Current World State\n\n### Namespace State\n- Failed tasks: 5\n\n### Autonomous Trigger\n- Scheduler: scheduled autonomous keepalive turn.\n\n### Continuity\nDONE: 하트비트 갱신\nNEXT: 대기 유지\n\n### Live Worktree Delta\n<git_status_change>\n?? lib/example.ml\n</git_status_change>\n"
  in
  let query = KTD.tool_query_text_of_user_message user_message in
  check bool "continuity heading stripped" false
    (contains_substring query "### Continuity");
  check bool "heartbeat residue stripped" false
    (contains_substring query "하트비트 갱신");
  check bool "autonomous trigger stripped" false
    (contains_substring query "Autonomous Trigger");
  check bool "worktree section preserved" true
    (contains_substring query "Live Worktree Delta")

let test_tool_query_text_of_user_message_keeps_counted_headers () =
  let obs =
    {
      base_observation with
      pending_mentions = [ ("alice", "please inspect the failures") ];
      pending_scope_messages = [ ("bob", "recent room update") ];
      active_goals = [ "goal-1" ];
      pending_board_events = [ sample_board_event ];
      failed_task_count = 2;
    }
  in
  let _sys, user = UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs () in
  let query = KTD.tool_query_text_of_user_message user in
  check bool "keeps counted pending mentions header" true
    (contains_substring query "### Pending Mentions (1)");
  check bool "keeps mention content" true
    (contains_substring query "@alice: please inspect the failures");
  check bool "keeps counted scope messages header" true
    (contains_substring query "### Scope Messages (1 recent)");
  check bool "keeps counted active goals header" true
    (contains_substring query "### Active Goals (1)");
  check bool "keeps counted board activity header" true
    (contains_substring query "### Board Activity (1 new)")

let test_scope_messages_prompt_caps_payload_not_count () =
  let pending_scope_messages =
    List.init 15 (fun i ->
      ( Printf.sprintf "agent-%02d" i,
        Printf.sprintf "message-%02d %s" i (String.make 220 'x') ))
  in
  let obs = { base_observation with pending_scope_messages } in
  let _sys, user =
    UP.build_prompt ~base_path:"/test" ~meta:minimal_meta ~observation:obs ()
  in
  check bool "header keeps real scope message count" true
    (contains_substring user "### Scope Messages (15 recent)");
  check bool "older scope messages are summarized" true
    (contains_substring user "omitted 3 older scope messages");
  check bool "oldest omitted message absent" false
    (contains_substring user "message-00");
  check bool "newest retained message present" true
    (contains_substring user "message-14");
  check bool "long scope message preview capped" false
    (contains_substring user (String.make 180 'x'))

let test_social_model_silences_skip_only_turn () =
  let result =
    make_run_result
      ~text:
        "SOCIAL_MODEL: bdi_speech_v1\nBELIEF_SUMMARY: quiet_room\nACTIVE_DESIRE: maintain_quiet_readiness\nCURRENT_INTENTION: stay_available_without_noise\nBLOCKER: none\nNEED: none\nSPEECH_ACT: stay_silent\nDELIVERY_SURFACE: silent"
      ~tools:[]
      ~model:"test-model" ~input_tok:20 ~output_tok:5 ()
  in
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let routed, state, _ =
        KSM.apply_to_result ~meta:minimal_meta
          ~observation:base_observation ~previous_state:None result
      in
      check string "speech act" "stay_silent"
        (KSM.speech_act_to_string state.speech_act);
      check string "delivery surface" "silent"
        (KSM.delivery_surface_to_string state.delivery_surface);
      check string "visible response suppressed" "" routed.response_text;
      check (list string) "no synthetic tools" [] routed.tools_used)

let test_social_model_unknown_meta_falls_back_to_baseline () =
  let meta = { minimal_meta with social_model = "experimental_v99" } in
  let result =
    make_run_result ~text:"I can respond normally." ~tools:[]
      ~model:"test-model" ~input_tok:20 ~output_tok:5 ()
  in
  let routed, state, _ =
    KSM.apply_to_result ~meta ~observation:base_observation
      ~previous_state:None result
  in
  check string "unknown meta model falls back to baseline"
    "bdi_speech_v1" state.social_model;
  check string "visible response preserved"
    "I can respond normally." routed.response_text

let test_social_model_unknown_header_falls_back_to_baseline () =
  let result =
    make_run_result
      ~text:
        "SOCIAL_MODEL: experimental_v99\nBELIEF_SUMMARY: quiet_room\nACTIVE_DESIRE: maintain_quiet_readiness\nCURRENT_INTENTION: stay_available_without_noise\nBLOCKER: none\nNEED: none\nSPEECH_ACT: stay_silent\nDELIVERY_SURFACE: silent"
      ~tools:[]
      ~model:"test-model" ~input_tok:20 ~output_tok:5 ()
  in
  let routed, state, _ =
    KSM.apply_to_result ~meta:minimal_meta
      ~observation:base_observation ~previous_state:None result
  in
  check string "unknown header model falls back to baseline"
    "bdi_speech_v1" state.social_model;
  check string "visible response suppressed" "" routed.response_text

let test_social_model_infers_visible_reply_without_headers () =
  let result =
    make_run_result ~text:"I think I should ask for help." ~tools:[]
      ~model:"test-model" ~input_tok:20 ~output_tok:5 ()
  in
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let routed, state, _ =
        KSM.apply_to_result ~meta:minimal_meta
          ~observation:base_observation ~previous_state:None result
      in
      check string "speech act" "inform"
        (KSM.speech_act_to_string state.speech_act);
      check string "delivery surface" "visible_reply"
        (KSM.delivery_surface_to_string state.delivery_surface);
      check (option string) "no blocker persisted" None state.blocker;
      check string "visible response preserved"
        "I think I should ask for help." routed.response_text;
      check (list string) "no synthetic tools" [] routed.tools_used)

let test_social_model_empty_text_without_headers_stays_silent () =
  let result =
    make_run_result ~text:"" ~tools:[]
      ~model:"test-model" ~input_tok:20 ~output_tok:5 ()
  in
  let routed, state, transition_reason =
    KSM.apply_to_result ~meta:minimal_meta
      ~observation:base_observation ~previous_state:None result
  in
  check string "speech act" "defer"
    (KSM.speech_act_to_string state.speech_act);
  check string "delivery surface" "silent"
    (KSM.delivery_surface_to_string state.delivery_surface);
  check (option string) "blocker notes empty protocol violation"
    (Some "no tool calls and no social headers") state.blocker;
  check string "transition reason"
    "protocol_violation:no_tool_calls_and_no_social_headers"
    (KSM.transition_reason_to_string transition_reason);
  check string "visible response suppressed" "" routed.response_text;
  check (list string) "no synthetic tools" [] routed.tools_used

let test_social_model_state_only_reply_stays_silent () =
  let result =
    make_run_result
      ~text:
        "[STATE]\nGoal: keep things tidy\nProgress: no visible response needed\n[/STATE]"
      ~tools:[]
      ~model:"test-model" ~input_tok:20 ~output_tok:5 ()
  in
  let routed, state, _ =
    KSM.apply_to_result ~meta:minimal_meta
      ~observation:base_observation ~previous_state:None result
  in
  check string "speech act" "defer"
    (KSM.speech_act_to_string state.speech_act);
  check string "delivery surface" "silent"
    (KSM.delivery_surface_to_string state.delivery_surface);
  check string "visible response suppressed" "" routed.response_text

let test_social_model_strips_state_block_from_visible_reply () =
  let result =
    make_run_result
      ~text:
        "Board checked.\n[STATE]\nGoal: keep things tidy\nProgress: board scanned\n[/STATE]"
      ~tools:[]
      ~model:"test-model" ~input_tok:20 ~output_tok:5 ()
  in
  let routed, state, _ =
    KSM.apply_to_result ~meta:minimal_meta
      ~observation:base_observation ~previous_state:None result
  in
  check string "speech act" "inform"
    (KSM.speech_act_to_string state.speech_act);
  check string "delivery surface" "visible_reply"
    (KSM.delivery_surface_to_string state.delivery_surface);
  check string "visible response strips state block"
    "Board checked."
    routed.response_text

let test_social_model_routes_blocker_to_board_post () =
  let result =
    make_run_result
      ~text:
        "SOCIAL_MODEL: bdi_speech_v1\nBELIEF_SUMMARY: quiet_room\nACTIVE_DESIRE: seek_help\nCURRENT_INTENTION: recover_tool_route\nBLOCKER: tool route unavailable\nNEED: tool route or operator guidance\nSPEECH_ACT: request_help\nDELIVERY_SURFACE: board_post"
      ~tools:[]
      ~model:"test-model" ~input_tok:30 ~output_tok:10 ()
  in
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Unix.putenv "MASC_BASE_PATH" base_dir;
      Masc_mcp.Board.reset_global_for_test ();
      Masc_mcp.Board_dispatch.reset_for_test ();
      Masc_mcp.Board_dispatch.init_jsonl ();
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      let routed, state, _ =
        KSM.apply_to_result ~meta:minimal_meta
          ~observation:base_observation ~previous_state:None result
      in
      let posts =
        Masc_mcp.Board_dispatch.list_posts
          ~sort_by:Masc_mcp.Board_dispatch.Recent ~limit:10 ()
      in
      check string "speech act" "request_help"
        (KSM.speech_act_to_string state.speech_act);
      check string "delivery surface" "board_post"
        (KSM.delivery_surface_to_string state.delivery_surface);
      check string "response suppressed after routing" "" routed.response_text;
      check bool "synthetic board tool recorded" true
        (List.mem "keeper_board_post" routed.tools_used);
      check int "one board post created" 1 (List.length posts);
      match posts with
      | [ post ] ->
          check string "post author" minimal_meta.name
            (Masc_mcp.Board.Agent_id.to_string post.author);
          check bool "post body mentions blocker" true
            (contains_substring post.body "blocked")
      | _ -> fail "expected one request-help board post")

let test_social_model_tool_only_turn_skips_protocol_violation () =
  let result =
    make_run_result ~text:"" ~tools:["masc_status"]
      ~model:"test-model" ~input_tok:10 ~output_tok:1 ()
  in
  let routed, state, transition_reason =
    KSM.apply_to_result ~meta:minimal_meta
      ~observation:base_observation ~previous_state:None result
  in
  check string "speech act" "inform"
    (KSM.speech_act_to_string state.speech_act);
  check string "delivery surface" "visible_reply"
    (KSM.delivery_surface_to_string state.delivery_surface);
  check (option string) "no protocol violation blocker" None state.blocker;
  check string "transition reason" "tool_only:visible_reply"
    (KSM.transition_reason_to_string transition_reason);
  check bool "tool-only turn synthesizes visible response" true
    (contains_substring routed.response_text "Tools used: masc_status.");
  check (list string) "tool list preserved" ["masc_status"] routed.tools_used

let test_social_model_previous_state_of_meta_restores_runtime_fields () =
  let meta =
    {
      minimal_meta with
      runtime =
        {
          minimal_meta.runtime with
          last_speech_act = "request_help";
          last_social_transition_reason = "headers:explicit_social_headers";
          last_active_desire = "seek_help";
          last_current_intention = "recover_tool_route";
          last_blocker = "tool route unavailable";
          last_need = "operator guidance";
        };
    }
  in
  match KSM.previous_state_of_meta meta with
  | None -> fail "expected previous social state"
  | Some state ->
      check string "social model restored" "bdi_speech_v1" state.social_model;
      check (option string) "active desire restored"
        (Some "seek_help") state.active_desire;
      check (option string) "current intention restored"
        (Some "recover_tool_route") state.current_intention;
      check (option string) "blocker restored"
        (Some "tool route unavailable") state.blocker;
      check (option string) "need restored"
        (Some "operator guidance") state.need;
      check string "speech act restored" "request_help"
        (KSM.speech_act_to_string state.speech_act);
      check string "delivery surface inferred from speech act" "board_post"
        (KSM.delivery_surface_to_string state.delivery_surface)

let test_social_model_tool_only_turn_carries_previous_state () =
  let result =
    make_run_result ~text:"" ~tools:["masc_status"]
      ~model:"test-model" ~input_tok:10 ~output_tok:1 ()
  in
  let previous_state =
    Some
      KSM.
        {
          social_model = "bdi_speech_v1";
          belief_summary = "mentions=1";
          active_desire = Some "seek_help";
          current_intention = Some "recover_tool_route";
          blocker = Some "tool route unavailable";
          need = Some "operator guidance";
          speech_act = Request_help;
          delivery_surface = Board_post;
        }
  in
  let routed, state, _ =
    KSM.apply_to_result ~meta:minimal_meta
      ~observation:base_observation ~previous_state result
  in
  check string "speech act becomes inform for tool-only turn" "inform"
    (KSM.speech_act_to_string state.speech_act);
  check (option string) "active desire carried"
    (Some "seek_help") state.active_desire;
  check (option string) "current intention carried"
    (Some "recover_tool_route") state.current_intention;
  check (option string) "need carried"
    (Some "operator guidance") state.need;
  check (option string) "blocker not carried into tool-only turn" None
    state.blocker;
  check bool "tool-only response still synthesized" true
    (contains_substring routed.response_text "Tools used: masc_status.");
  check (list string) "tool list preserved" ["masc_status"] routed.tools_used

let test_social_model_infers_board_comment_from_tool_use () =
  let result =
    make_run_result ~text:"" ~tools:["keeper_board_comment"; "masc_status"]
      ~model:"test-model" ~input_tok:10 ~output_tok:1 ()
  in
  let routed, state, transition_reason =
    KSM.apply_to_result ~meta:minimal_meta
      ~observation:base_observation ~previous_state:None result
  in
  check string "speech act" "comment_board"
    (KSM.speech_act_to_string state.speech_act);
  check string "delivery surface" "board_comment"
    (KSM.delivery_surface_to_string state.delivery_surface);
  check (option string) "no protocol violation blocker" None state.blocker;
  check string "transition reason" "tool_only:comment_board"
    (KSM.transition_reason_to_string transition_reason);
  check bool "tool turn keeps synthesized visible response" true
    (contains_substring routed.response_text
       "Tools used: keeper_board_comment, masc_status.");
  check (list string) "tool list preserved"
    ["keeper_board_comment"; "masc_status"] routed.tools_used

let test_social_model_does_not_infer_comment_vote_as_board_comment () =
  let result =
    make_run_result ~text:""
      ~tools:["keeper_board_comment_vote"; "masc_status"]
      ~model:"test-model" ~input_tok:10 ~output_tok:1 ()
  in
  let routed, state, transition_reason =
    KSM.apply_to_result ~meta:minimal_meta
      ~observation:base_observation ~previous_state:None result
  in
  check string "speech act" "inform"
    (KSM.speech_act_to_string state.speech_act);
  check string "delivery surface" "visible_reply"
    (KSM.delivery_surface_to_string state.delivery_surface);
  check string "transition reason" "tool_only:visible_reply"
    (KSM.transition_reason_to_string transition_reason);
  check bool "tool-only turn synthesizes visible response" true
    (contains_substring routed.response_text
       "Tools used: keeper_board_comment_vote, masc_status.");
  check (list string) "tool list preserved"
    ["keeper_board_comment_vote"; "masc_status"] routed.tools_used

let test_social_model_infers_masc_claim_task_from_tool_use () =
  let result =
    make_run_result ~text:"" ~tools:["masc_claim_task"]
      ~model:"test-model" ~input_tok:10 ~output_tok:1 ()
  in
  let routed, state, transition_reason =
    KSM.apply_to_result ~meta:minimal_meta
      ~observation:base_observation ~previous_state:None result
  in
  check string "speech act" "claim_task"
    (KSM.speech_act_to_string state.speech_act);
  check string "delivery surface" "task_claim"
    (KSM.delivery_surface_to_string state.delivery_surface);
  check string "transition reason" "tool_only:claim_task"
    (KSM.transition_reason_to_string transition_reason);
  check (list string) "tool list preserved" ["masc_claim_task"]
    routed.tools_used

let test_social_model_magentic_ledger_silences_tool_only_turn () =
  let meta = { minimal_meta with social_model = "magentic_ledger_v1" } in
  let result =
    make_run_result ~text:"" ~tools:["masc_status"]
      ~model:"test-model" ~input_tok:10 ~output_tok:1 ()
  in
  let routed, state, transition_reason =
    KSM.apply_to_result ~meta ~observation:base_observation
      ~previous_state:None result
  in
  check string "social model" "magentic_ledger_v1" state.social_model;
  check string "speech act" "stay_silent"
    (KSM.speech_act_to_string state.speech_act);
  check string "delivery surface" "silent"
    (KSM.delivery_surface_to_string state.delivery_surface);
  check (option string) "active desire reflects progress ledger"
    (Some "advance_task_progress") state.active_desire;
  check (option string) "current intention tracks evidence"
    (Some "record_progress_evidence") state.current_intention;
  check string "transition reason" "tool_only:progress_ledger"
    (KSM.transition_reason_to_string transition_reason);
  check bool "belief summary is ledger shaped" true
    (contains_substring state.belief_summary "ledger:phase=advancing");
  check string "visible response suppressed" "" routed.response_text;
  check (list string) "tool list preserved" ["masc_status"] routed.tools_used

let test_social_model_magentic_ledger_tracks_masc_claim_task () =
  let meta = { minimal_meta with social_model = "magentic_ledger_v1" } in
  let result =
    make_run_result ~text:"" ~tools:["masc_claim_task"]
      ~model:"test-model" ~input_tok:10 ~output_tok:1 ()
  in
  let routed, state, transition_reason =
    KSM.apply_to_result ~meta ~observation:base_observation
      ~previous_state:None result
  in
  check string "social model" "magentic_ledger_v1" state.social_model;
  check (option string) "current intention tracks claim"
    (Some "capture_next_task") state.current_intention;
  check string "transition reason" "tool_only:claim_task"
    (KSM.transition_reason_to_string transition_reason);
  check string "visible response suppressed" "" routed.response_text;
  check (list string) "tool list preserved" ["masc_claim_task"]
    routed.tools_used

let test_social_model_magentic_ledger_hides_nonvisible_tool_text () =
  let meta = { minimal_meta with social_model = "magentic_ledger_v1" } in
  let result =
    make_run_result ~text:"" ~tools:["keeper_board_comment"; "masc_status"]
      ~model:"test-model" ~input_tok:10 ~output_tok:1 ()
  in
  let routed, state, transition_reason =
    KSM.apply_to_result ~meta ~observation:base_observation
      ~previous_state:None result
  in
  check string "social model" "magentic_ledger_v1" state.social_model;
  check string "speech act" "comment_board"
    (KSM.speech_act_to_string state.speech_act);
  check string "delivery surface" "board_comment"
    (KSM.delivery_surface_to_string state.delivery_surface);
  check string "transition reason preserved" "tool_only:comment_board"
    (KSM.transition_reason_to_string transition_reason);
  check string "non-visible tool turn does not synthesize text" ""
    routed.response_text;
  check (list string) "tool list preserved"
    ["keeper_board_comment"; "masc_status"] routed.tools_used

let test_social_model_magentic_ledger_previous_state_of_meta_restores_model ()
    =
  let meta =
    {
      minimal_meta with
      social_model = "magentic_ledger_v1";
      runtime =
        {
          minimal_meta.runtime with
          last_speech_act = "inform";
          last_active_desire = "advance_task_progress";
          last_current_intention = "record_progress_evidence";
        };
    }
  in
  match KSM.previous_state_of_meta meta with
  | None -> fail "expected previous social state"
  | Some state ->
      check string "social model restored" "magentic_ledger_v1"
        state.social_model;
      check string "speech act restored" "inform"
        (KSM.speech_act_to_string state.speech_act)

let test_social_model_previous_state_of_meta_falls_back_for_unknown_model () =
  let meta =
    {
      minimal_meta with
      social_model = "experimental_v99";
      runtime =
        {
          minimal_meta.runtime with
          last_speech_act = "request_help";
          last_active_desire = "seek_help";
          last_current_intention = "recover_tool_route";
          last_blocker = "tool route unavailable";
          last_need = "operator guidance";
        };
    }
  in
  match KSM.previous_state_of_meta meta with
  | None -> fail "expected fallback previous social state"
  | Some state ->
      check string "unknown model falls back to default" "bdi_speech_v1"
        state.social_model;
      check string "speech act restored under fallback" "request_help"
        (KSM.speech_act_to_string state.speech_act);
      check string "delivery surface inferred under fallback" "board_post"
        (KSM.delivery_surface_to_string state.delivery_surface)

let test_social_model_bdi_failure_state_rewrites_claim_retry_loop () =
  let observation =
    {
      base_observation with
      unclaimed_task_count = 12;
      claimable_task_count = 12;
    }
  in
  let previous_state =
    Some
      KSM.
        {
          social_model = "bdi_speech_v1";
          belief_summary = "unclaimed_tasks=12; idle=406s";
          active_desire = Some "claim_next_task";
          current_intention = Some "keeper_task_claim {}";
          blocker = None;
          need = Some "available task";
          speech_act = Inform;
          delivery_surface = Visible_reply;
        }
  in
  let state, transition_reason =
    KSM.derive_failure_state ~meta:minimal_meta ~observation ~previous_state
      ~is_auto_recoverable:true
      ~sdk_error:None
      ~reason:
        "Internal error: [masc_oas_error] {\"kind\":\"cascade_exhausted\",\"cascade_name\":\"tool_use_strict\"}"
  in
  check string "transition reason" "failure:run_error"
    (KSM.transition_reason_to_string transition_reason);
  check string "speech act stays defer" "defer"
    (KSM.speech_act_to_string state.speech_act);
  check string "delivery surface stays silent" "silent"
    (KSM.delivery_surface_to_string state.delivery_surface);
  check (option string) "active desire rewrites to route recovery"
    (Some "recover_tool_route") state.active_desire;
  check (option string) "stale claim intention is replaced"
    (Some "retry_claim_after_recovery") state.current_intention;
  check (option string) "need requests recovery guidance"
    (Some "provider_recovery_or_operator_guidance") state.need;
  check bool "blocker keeps failure detail" true
    (match state.blocker with
    | Some blocker -> contains_substring blocker "cascade_exhausted"
    | None -> false)

let test_social_model_required_tool_failure_requests_help () =
  let state, transition_reason =
    KSM.derive_failure_state ~meta:minimal_meta ~observation:base_observation
      ~previous_state:None ~is_auto_recoverable:false
      ~sdk_error:(Some (required_tool_contract_violation_error ()))
      ~reason:
        "Completion contract [require_tool_use] violated: actionable keeper \
         signal was present, but the model called no keeper tools"
  in
  check string "transition reason" "failure:run_error"
    (KSM.transition_reason_to_string transition_reason);
  check string "speech act requests help" "request_help"
    (KSM.speech_act_to_string state.speech_act);
  check string "delivery surface is operator-visible board post" "board_post"
    (KSM.delivery_surface_to_string state.delivery_surface);
  check (option string) "active desire recovers route"
    (Some "recover_tool_route") state.active_desire;
  check (option string) "intention surfaces blocker"
    (Some "surface_required_tool_blocker") state.current_intention;
  check (option string) "need names route recovery"
    (Some "operator_guidance_or_tool_capable_route") state.need;
  check bool "blocker keeps contract detail" true
    (match state.blocker with
    | Some blocker -> contains_substring blocker "require_tool_use"
    | None -> false)

let test_social_model_bdi_failure_state_keeps_existing_carry_without_claim_context
    () =
  let previous_state =
    Some
      KSM.
        {
          social_model = "bdi_speech_v1";
          belief_summary = "mentions=1";
          active_desire = Some "seek_help";
          current_intention = Some "recover_tool_route";
          blocker = Some "tool route unavailable";
          need = Some "operator guidance";
          speech_act = Request_help;
          delivery_surface = Board_post;
        }
  in
  let state, _ =
    KSM.derive_failure_state ~meta:minimal_meta ~observation:base_observation
      ~previous_state ~is_auto_recoverable:false
      ~sdk_error:None
      ~reason:"local config error"
  in
  check (option string) "active desire still carries on ordinary failure"
    (Some "seek_help") state.active_desire;
  check (option string) "current intention still carries on ordinary failure"
    (Some "recover_tool_route") state.current_intention;
  check (option string) "need still carries on ordinary failure"
    (Some "operator guidance") state.need

let test_social_model_magentic_ledger_stalled_state_carries_until_delta () =
  let meta = { minimal_meta with social_model = "magentic_ledger_v1" } in
  let previous_state =
    Some
      {
        KSM.social_model = "magentic_ledger_v1";
        belief_summary = "ledger:phase=stalled; event=goal_idle_timeout";
        active_desire = Some "recover_forward_motion";
        current_intention = Some "request_replan";
        blocker = Some "stalled_without_progress_evidence";
        need = Some "fresh_plan_or_external_delta";
        speech_act = KSM.Stay_silent;
        delivery_surface = KSM.Silent;
      }
  in
  let observation =
    { base_observation with active_goals = [ "goal-1" ]; idle_seconds = 0 }
  in
  let result =
    make_run_result ~text:"" ~tools:[]
      ~model:"test-model" ~input_tok:10 ~output_tok:1 ()
  in
  let _, state, _ =
    KSM.apply_to_result ~meta ~observation ~previous_state result
  in
  check (option string) "stalled desire carried" (Some "recover_forward_motion")
    state.active_desire;
  check (option string) "stalled intention carried" (Some "request_replan")
    state.current_intention;
  check bool "belief summary remains stalled" true
    (contains_substring state.belief_summary "ledger:phase=stalled")

let test_keeper_allowed_tools_exclude_heartbeat () =
  let allowed =
    Masc_mcp.Keeper_exec_tools.keeper_allowed_tool_names minimal_policy_meta
  in
  check bool "masc_heartbeat hidden from keeper tool surface" false
    (List.mem "masc_heartbeat" allowed)

let test_should_require_tools_for_initial_turn_matches_first_turn_gate () =
  let affordances = [ "task_claim"; "board_post_or_comment" ] in
  check bool "single-turn call reserves final turn without forcing strict lane" false
    (KAR.should_require_tools_for_initial_turn ~max_turns:1 ~turn_affordances:affordances);
  check bool "two-turn call can require initial tools" true
    (KAR.should_require_tools_for_initial_turn ~max_turns:2 ~turn_affordances:affordances);
  check bool "two-turn board action can require initial tools" true
    (KAR.should_require_tools_for_initial_turn ~max_turns:2
       ~turn_affordances:[ "board_post_or_comment" ]);
  check bool "two-turn board curation can require initial tools" true
    (KAR.should_require_tools_for_initial_turn ~max_turns:2
       ~turn_affordances:[ "board_curation" ]);
  check bool "three-turn call can require initial tools" true
    (KAR.should_require_tools_for_initial_turn ~max_turns:3 ~turn_affordances:affordances);
  check bool "pending verification requires an action tool" true
    (KAR.should_require_tools_for_initial_turn ~max_turns:3
       ~turn_affordances:[ "task_verify" ]);
  check bool "work discovery requires an action tool" true
    (KAR.should_require_tools_for_initial_turn ~max_turns:3
       ~turn_affordances:[ "work_discovery" ]);
  check bool "worktree delta inspection requires an action tool" true
    (KAR.should_require_tools_for_initial_turn ~max_turns:3
       ~turn_affordances:[ "inspect_worktree_delta" ]);
  check bool "no tool-required affordance stays optional" false
    (KAR.should_require_tools_for_initial_turn ~max_turns:3 ~turn_affordances:[ "observe" ])

let test_should_require_tools_for_initial_turn_covers_actionable_affordances () =
  let require affordance =
    KAR.should_require_tools_for_initial_turn ~max_turns:2
      ~turn_affordances:[ affordance ]
  in
  check bool "reply requires tool gate" true (require "reply_in_room");
  check bool "verification requires tool gate" true (require "task_verify");
  check bool "board curation requires tool gate" true
    (require "board_curation");
  check bool "worktree inspection requires tool gate" true
    (require "inspect_worktree_delta")

let test_turn_affordances_require_tool_gate_with_allowed_filters_by_tool () =
  (* P1: an affordance must have a matching tool in the keeper's
     visible surface to count as a "tool-gated" affordance.  This
     prevents Require_tool_use from firing on keepers that cannot
     satisfy the demanded action class. *)
  let gate ~tools affordances =
    KAR.turn_affordances_require_tool_gate_with_allowed
      ~allowed_tool_names:tools affordances
  in
  check bool
    "task_claim affordance with claim tool present -> gate fires" true
    (gate ~tools:[ "keeper_task_claim" ] [ "task_claim" ]);
  check bool
    "task_claim affordance without any claim tool -> gate suppressed" false
    (gate ~tools:[ "keeper_board_post"; "keeper_context_status" ]
       [ "task_claim" ]);
  check bool
    "board_post_or_comment with comment tool -> gate fires" true
    (gate ~tools:[ "keeper_board_comment" ] [ "board_post_or_comment" ]);
  check bool
    "board_post_or_comment without any post tool -> gate suppressed" false
    (gate ~tools:[ "keeper_task_claim"; "keeper_tasks_list" ]
       [ "board_post_or_comment" ]);
  check bool
    "board_curation with submit tool -> gate fires" true
    (gate ~tools:[ "keeper_board_curation_submit" ] [ "board_curation" ]);
  check bool
    "board_curation without submit tool -> gate suppressed" false
    (gate ~tools:[ "keeper_board_post"; "keeper_board_comment" ]
       [ "board_curation" ]);
  check bool
    "any matching affordance is enough" true
    (gate
       ~tools:[ "masc_claim_next" ]
       [ "task_claim"; "task_audit"; "board_post_or_comment" ]);
  check bool
    "task_audit with only passive audit/list tools -> gate suppressed" false
    (gate ~tools:[ "keeper_tasks_audit"; "keeper_tasks_list" ]
       [ "task_audit" ]);
  check bool
    "task_verify with only passive task list -> gate suppressed" false
    (gate ~tools:[ "keeper_tasks_list" ] [ "task_verify" ]);
  check bool
    "task_verify with submit tool -> gate fires" true
    (gate ~tools:[ "keeper_task_submit_for_verification" ] [ "task_verify" ]);
  check bool
    "all gated affordances missing tools -> gate suppressed" false
    (gate
       ~tools:[ "keeper_context_status"; "keeper_time_now" ]
       [ "task_claim"; "task_verify"; "board_post_or_comment" ]);
  check bool "empty affordances -> gate stays off" false
    (gate ~tools:[ "keeper_task_claim" ] []);
  check bool
    "unknown affordance string is ignored" false
    (gate ~tools:[ "keeper_task_claim" ] [ "totally_unknown_affordance" ])

let test_turn_affordance_gate_suppression_metric () =
  let metric affordance =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_keeper_required_tool_gate_suppressed_total
      ~labels:[ ("affordance", affordance) ]
      ()
  in
  let gate ~tools affordances =
    KAR.turn_affordances_require_tool_gate_with_allowed
      ~record_suppression_metric:true ~allowed_tool_names:tools affordances
  in
  let verify_before = metric "task_verify" in
  let unknown_before = metric "totally_unknown_affordance" in
  check bool "passive task_verify list tool suppresses gate" false
    (gate ~tools:[ "keeper_tasks_list" ] [ "task_verify" ]);
  check (float 0.0) "task_verify suppression increments metric"
    (verify_before +. 1.0)
    (metric "task_verify");
  check (float 0.0) "unknown affordance does not create metric label"
    unknown_before
    (metric "totally_unknown_affordance");
  let claim_before = metric "task_claim" in
  check bool "claim tool present keeps gate active" true
    (gate ~tools:[ "keeper_task_claim" ] [ "task_claim" ]);
  check (float 0.0) "successful gate does not increment suppression metric"
    claim_before
    (metric "task_claim")

let test_required_gate_surface_removes_passive_distractions () =
  let module Surface = Masc_mcp.Keeper_agent_tool_surface in
  check (list string)
    "required gate keeps actionable tools only"
    [ "keeper_task_claim"; "keeper_board_post" ]
    (Surface.tool_names_for_required_gate_surface
       ~tool_gate_requested:true
       [ "keeper_tasks_list"; "keeper_task_claim"; "keeper_stay_silent";
         "keeper_board_post"; "masc_status" ]);
  check (list string)
    "optional turn keeps passive tools visible"
    [ "keeper_tasks_list"; "keeper_board_post" ]
    (Surface.tool_names_for_required_gate_surface
       ~tool_gate_requested:false
       [ "keeper_tasks_list"; "keeper_board_post" ]);
  check (list string)
    "passive-only surface remains unchanged when no action exists"
    [ "keeper_tasks_list"; "masc_status" ]
    (Surface.tool_names_for_required_gate_surface
       ~tool_gate_requested:true
       [ "keeper_tasks_list"; "masc_status" ])

let test_tools_for_gated_affordance_covers_each_variant () =
  (* Compile-time exhaustiveness already ensures every variant is
     handled; this asserts the runtime mapping is non-empty so a
     well-meaning future edit cannot silently break the gate by
     returning [] for an affordance.  It also checks each mapped name
     against tool-name/surface SSOTs so typoed affordance tools do not
     silently turn into dead gate entries. *)
  let module Surface = Masc_mcp.Keeper_agent_tool_surface in
  let known_tool_name name =
    Masc_mcp.Tool_name.of_string name <> None
    || Masc_mcp.Tool_catalog_surfaces.surfaces_for_tool name <> []
  in
  let nonempty label affordance =
    let tools = Surface.tools_for_gated_affordance affordance in
    check bool
      (Printf.sprintf "tools_for_gated_affordance non-empty for %s" label)
      true (tools <> []);
    check (list string)
      (Printf.sprintf "tools_for_gated_affordance known tools for %s" label)
      [] (List.filter (fun name -> not (known_tool_name name)) tools)
  in
  nonempty "Board_curation" Surface.Board_curation;
  nonempty "Board_post_or_comment" Surface.Board_post_or_comment;
  nonempty "Message_sweep" Surface.Message_sweep;
  nonempty "Reply_in_room" Surface.Reply_in_room;
  nonempty "Task_claim" Surface.Task_claim;
  nonempty "Task_audit" Surface.Task_audit;
  nonempty "Task_verify" Surface.Task_verify;
  nonempty "Work_discovery" Surface.Work_discovery;
  nonempty "Inspect_worktree_delta" Surface.Inspect_worktree_delta;
  check (list string)
    "board_curation force-includes submit tool"
    [ "keeper_board_curation_submit" ]
    (Surface.preferred_tool_names_for_turn_affordances
       [ "board_curation"; "task_claim"; "board_curation" ]);
  check (list string)
    "generic board affordance has no forced specific tool"
    []
    (Surface.preferred_tool_names_for_turn_affordances
       [ "board_post_or_comment" ]);
  check bool "work discovery includes keeper-native task creation" true
    (List.mem "keeper_task_create"
       (Surface.tools_for_gated_affordance Surface.Work_discovery))

let test_preferred_tool_choice_for_required_turn_claims_first () =
  let module Surface = Masc_mcp.Keeper_agent_tool_surface in
  let choose ?(has_current_task = false) ?(turn_affordances = [ "task_claim" ])
      ?(allowed_tool_names =
        [ "keeper_task_claim"; "keeper_tasks_list"; "keeper_board_post" ])
      () =
    KAR.preferred_tool_choice_for_required_turn ~has_current_task
      ~turn_affordances ~allowed_tool_names
  in
  (match choose () with
   | Agent_sdk.Types.Tool name ->
       check string "forces claim tool first" "keeper_task_claim" name
   | other ->
       fail
         (Printf.sprintf "expected Tool keeper_task_claim, got %s"
            (Agent_sdk.Types.show_tool_choice other)));
  (match choose ~has_current_task:true () with
   | Agent_sdk.Types.Any -> ()
   | other ->
       fail
         (Printf.sprintf
            "expected Any when already owning work, got %s"
            (Agent_sdk.Types.show_tool_choice other)));
  (* Board curation is the most specific action for a due curation
     window, so prefer the submit tool over generic board/task tools. *)
  (match
     choose
       ~turn_affordances:[ "board_curation"; "task_claim" ]
       ~allowed_tool_names:
         [
           "keeper_board_curation_submit";
           "keeper_task_claim";
           "keeper_board_post";
         ]
       ()
   with
   | Agent_sdk.Types.Any -> ()
   | other ->
       fail
         (Printf.sprintf
            "expected Any for board curation required turn, got %s"
            (Agent_sdk.Types.show_tool_choice other)));
  (match
     choose
       ~turn_affordances:[ "board_curation" ]
       ~allowed_tool_names:[ "keeper_board_post" ]
       ()
   with
   | Agent_sdk.Types.Auto -> ()
   | other ->
       fail
         (Printf.sprintf
            "expected Auto when curation submit is unavailable and keeper is idle, \
             got %s"
            (Agent_sdk.Types.show_tool_choice other)));
  (* #10008: when no specific tool is applicable for the current
     affordance, fall back to [Auto] so the model can respond with
     honest refusal text ("no eligible task to claim") instead of
     being forced into a [Require_tool_use] contract violation. *)
  (match
     choose
       ~turn_affordances:[ "task_audit" ]
       ~allowed_tool_names:[ "keeper_tasks_audit"; "keeper_board_post" ]
       ()
   with
   | Agent_sdk.Types.Auto -> ()
   | other ->
       fail
         (Printf.sprintf
            "expected Auto for task audit with passive audit tool, got %s"
            (Agent_sdk.Types.show_tool_choice other)));
  (match
     choose
       ~turn_affordances:[ "task_audit" ]
       ~allowed_tool_names:[ "keeper_tasks_list"; "keeper_board_post" ]
       ()
   with
   | Agent_sdk.Types.Auto -> ()
   | other ->
       fail
         (Printf.sprintf
            "expected Auto for task audit without applicable tool \
             (#10008), got %s"
            (Agent_sdk.Types.show_tool_choice other)));
  (match
     choose
       ~turn_affordances:[ "task_verify" ]
       ~allowed_tool_names:[ "keeper_tasks_list"; "keeper_board_post" ]
       ()
   with
   | Agent_sdk.Types.Auto -> ()
   | other ->
       fail
         (Printf.sprintf
            "expected Auto for task verify with passive task list, got %s"
            (Agent_sdk.Types.show_tool_choice other)));
  (match
     choose
       ~turn_affordances:[ "task_verify" ]
       ~allowed_tool_names:
         [ "keeper_tasks_list"; "keeper_task_submit_for_verification" ]
       ()
   with
   | Agent_sdk.Types.Auto -> ()
   | other ->
       fail
         (Printf.sprintf
            "expected Auto for idle task verify turn, got %s"
            (Agent_sdk.Types.show_tool_choice other)));
  (match
     choose
       ~has_current_task:true
       ~turn_affordances:[ "task_verify" ]
       ~allowed_tool_names:
         [ "keeper_tasks_list"; "keeper_task_submit_for_verification" ]
       ()
   with
   | Agent_sdk.Types.Any -> ()
   | other ->
       fail
         (Printf.sprintf
            "expected Any for active task verify turn, got %s"
            (Agent_sdk.Types.show_tool_choice other)));
  (match choose ~allowed_tool_names:[ "keeper_board_post" ] () with
  | Agent_sdk.Types.Auto -> ()
  | other ->
      fail
        (Printf.sprintf
           "expected Auto when claim is unavailable and keeper is \
            idle (#10008), got %s"
           (Agent_sdk.Types.show_tool_choice other)));
  check (list string)
    "per-call required tools override active task required tools"
    [ "keeper_board_post" ]
    (Surface.required_tool_names_for_turn
       ~current_task_required_tool_names:[ "keeper_board_curation_submit" ]
       ~per_call_required_tool_names:[ "keeper_board_post" ]);
  let product_design_required_tools =
    Surface.required_tool_names_for_turn
      ~current_task_required_tool_names:[ "keeper_board_curation_submit" ]
      ~per_call_required_tool_names:[ "keeper_board_post" ]
  in
  (match
     Surface.preferred_tool_choice_for_required_tool_names
       ~required_tool_names:product_design_required_tools
       ~allowed_tool_names:
         [ "keeper_board_curation_submit"; "keeper_board_post" ]
   with
   | Agent_sdk.Types.Any -> ()
   | other ->
       fail
         (Printf.sprintf
            "expected Any for product/design reprobe required tool, got %s"
            (Agent_sdk.Types.show_tool_choice other)));
  check (list string)
    "active task required tools remain when no per-call requirement exists"
    [ "keeper_board_curation_submit" ]
    (Surface.required_tool_names_for_turn
       ~current_task_required_tool_names:[ "keeper_board_curation_submit" ]
       ~per_call_required_tool_names:[]);
  check (list string)
    "satisfied per-call required tool is not forced again"
    []
    (Surface.outstanding_required_tool_names
       ~required_tool_names:[ "keeper_pr_review_comment" ]
       ~satisfied_tool_names:[ "keeper_pr_review_comment" ]);
  check (list string)
    "unsatisfied required tool remains outstanding"
    [ "keeper_board_post" ]
    (Surface.outstanding_required_tool_names
       ~required_tool_names:
         [ "keeper_pr_review_comment"; "keeper_board_post" ]
       ~satisfied_tool_names:[ "keeper_pr_review_comment" ]);
  check (list string)
    "failed required tool call remains outstanding"
    [ "keeper_pr_review_comment" ]
    (Surface.outstanding_required_tool_names
       ~required_tool_names:[ "keeper_pr_review_comment" ]
       ~satisfied_tool_names:
         (Surface.satisfied_required_tool_names_of_outcomes
            [ "keeper_pr_review_comment", "error" ]));
  check (list string)
    "successful required tool call is satisfied"
    []
    (Surface.outstanding_required_tool_names
       ~required_tool_names:[ "keeper_pr_review_comment" ]
       ~satisfied_tool_names:
         (Surface.satisfied_required_tool_names_of_outcomes
            [ "keeper_pr_review_comment", "ok" ]));
  (match
     Surface.preferred_tool_choice_for_required_tool_names
       ~required_tool_names:[ "keeper_board_post" ]
       ~allowed_tool_names:
         [ "keeper_board_curation_submit"; "keeper_board_post" ]
   with
   | Agent_sdk.Types.Any -> ()
   | other ->
       fail (Printf.sprintf "expected Any for single required tool, got %s"
               (Agent_sdk.Types.show_tool_choice other)));
  (match
     Surface.preferred_tool_choice_for_required_tool_names
       ~required_tool_names:[ "keeper_pr_create" ]
       ~allowed_tool_names:[ "keeper_pr_create"; "keeper_bash" ]
   with
   | Agent_sdk.Types.Any -> ()
   | other ->
       fail
         (Printf.sprintf
            "expected Any for keeper_pr_create to avoid raw require_specific_tool \
             MCP-prefix mismatches, got %s"
            (Agent_sdk.Types.show_tool_choice other)));
  (match
     Surface.preferred_tool_choice_for_required_tool_names
       ~required_tool_names:
         [ "keeper_shell"; "keeper_bash"; "keeper_board_post" ]
       ~allowed_tool_names:
         [ "keeper_shell"; "keeper_bash"; "keeper_board_post" ]
   with
   | Agent_sdk.Types.Any -> ()
   | other ->
       fail
         (Printf.sprintf "expected Any for multiple required tools, got %s"
            (Agent_sdk.Types.show_tool_choice other)));
  (match
     Surface.preferred_tool_choice_for_required_tool_names
       ~required_tool_names:[ "keeper_tasks_audit" ]
       ~allowed_tool_names:[ "keeper_tasks_audit"; "keeper_board_post" ]
   with
   | Agent_sdk.Types.Auto -> ()
   | other ->
       fail
         (Printf.sprintf
            "expected Auto for passive-only required tool, got %s"
            (Agent_sdk.Types.show_tool_choice other)));
  (match
     Surface.preferred_tool_choice_for_required_tool_names
       ~required_tool_names:[ "keeper_tasks_audit"; "keeper_board_post" ]
       ~allowed_tool_names:[ "keeper_tasks_audit"; "keeper_board_post" ]
   with
   | Agent_sdk.Types.Any -> ()
   | other ->
       fail
         (Printf.sprintf
            "expected Any for mixed passive/active required \
             tools, got %s"
            (Agent_sdk.Types.show_tool_choice other)));
  (* Active task keeper retains the strict gate even without a
     specific applicable tool — the caller is expected to make
     progress via board_post, task_update, etc. *)
  match
    choose ~has_current_task:true
      ~turn_affordances:[ "task_audit" ]
      ~allowed_tool_names:[ "keeper_tasks_list"; "keeper_board_post" ]
      ()
  with
  | Agent_sdk.Types.Any -> ()
  | other ->
      fail
        (Printf.sprintf
           "expected Any for active-task keeper (must make \
            progress), got %s"
           (Agent_sdk.Types.show_tool_choice other))

let test_direct_keeper_msg_timeout_overrides_meta_per_provider_timeout () =
  let meta =
    { (make_meta "product-design-timeout") with
      per_provider_timeout_s = Some 300.0;
    }
  in
  check (option (float 0.001))
    "explicit direct-message timeout wins over stale per-provider timeout"
    (Some 900.0)
    (KAR.per_provider_timeout_for_turn ~meta ~oas_timeout_s:900.0
       ~timeout_s:900.0 ());
  check (option (float 0.001))
    "profile per-provider timeout still applies without explicit override"
    (Some 300.0)
    (KAR.per_provider_timeout_for_turn ~meta ~timeout_s:900.0 ())

(* ---------- render_inline_skip_reason tests ---------- *)

let str_contains s sub =
  try ignore (Str.search_forward (Str.regexp_string sub) s 0); true
  with Not_found -> false

let test_render_inline_skip_reason_deny () =
  let result = KG.render_inline_skip_reason
    ~tool_name:"keeper_bash"
    ~reason_code:"keeper_deny"
    ~reason_text:"tool is on the keeper deny list"
  in
  check bool "prefix" true (String.starts_with ~prefix:"[tool_skipped]" result);
  check bool "tool" true (str_contains result "tool=keeper_bash");
  check bool "code" true (str_contains result "code=keeper_deny");
  check bool "reason encoded" true (str_contains result "reason=tool%20is%20on")

let test_render_inline_skip_reason_cost () =
  let result = KG.render_inline_skip_reason
    ~tool_name:"keeper_bash"
    ~reason_code:"cost_gate"
    ~reason_text:"accumulated_cost_usd=0.5100 exceeded limit=0.5000"
  in
  check bool "prefix" true (String.starts_with ~prefix:"[tool_skipped]" result);
  check bool "code" true (str_contains result "code=cost_gate");
  check bool "reason encoded equals" true (str_contains result "0.5100%20exceeded")

let test_render_inline_skip_reason_destructive () =
  let result = KG.render_inline_skip_reason
    ~tool_name:"keeper_bash"
    ~reason_code:"destructive_guard"
    ~reason_text:"pattern='rm -rf' (recursive forced deletion)"
  in
  check bool "prefix" true (String.starts_with ~prefix:"[tool_skipped]" result);
  check bool "code" true (str_contains result "code=destructive_guard");
  check bool "pattern encoded" true (str_contains result "pattern%3D")

let test_render_inline_escape_edge_cases () =
  (* Empty reason text *)
  let empty = KG.render_inline_skip_reason
    ~tool_name:"t" ~reason_code:"c" ~reason_text:"" in
  check bool "empty reason" true (str_contains empty "reason=");
  (* Percent sign in reason *)
  let pct = KG.render_inline_skip_reason
    ~tool_name:"t" ~reason_code:"c" ~reason_text:"CPU at 90%" in
  check bool "percent encoded" true (str_contains pct "90%25")

let test_render_inline_with_replacement () =
  (* keeper_board_post has replacement=masc_board_post in Tool_catalog *)
  let result = KG.render_inline_skip_reason
    ~tool_name:"keeper_board_post"
    ~reason_code:"keeper_deny"
    ~reason_text:"denied"
  in
  check bool "has replacement" true (str_contains result "replacement=")

let test_normalize_override_passthrough () =
  let override_text =
    "[tool_skipped] tool=keeper_bash source=keeper_hook code=keeper_deny \
     reason=tool%20is%20on%20the%20keeper%20deny%20list"
  in
  match KTD.normalize_response_text
          ~text:override_text
          ~tool_names:["keeper_bash"]
          ()
  with
  | Ok text -> check string "passes through" override_text text
  | Error e -> fail ("unexpected error: " ^ e)

(* ---------- Metacognition tests ---------- *)

let test_on_idle_nudge_at_first_idle () =
  (* Use an explicit skip_at=3 to exercise the pure helper at a chosen
     threshold, independent of any global/default configuration. *)
  let decision = HK.on_idle_decision_with_threshold
    ~skip_at:3
    ~consecutive_idle_turns:1
    ~allowed_tools:[]
    ~tool_names:["keeper_board_list"; "keeper_tasks_list"] in
  match decision with
  | Agent_sdk.Hooks.Nudge msg ->
    check bool "nudge mentions repeated tools"
      true (contains_substring msg "keeper_board_list")
  | other ->
    fail (Printf.sprintf "expected Nudge, got %s"
      (Agent_sdk.Hooks.decision_kind_to_string
        (Agent_sdk.Hooks.classify_decision other)))

let test_on_idle_final_warning_before_skip () =
  (* At skip_at - 1, the hook should send a final-warning nudge *)
  let decision = HK.on_idle_decision_with_threshold
    ~skip_at:3
    ~consecutive_idle_turns:2
    ~allowed_tools:[]
    ~tool_names:["keeper_board_list"] in
  match decision with
  | Agent_sdk.Hooks.Nudge msg ->
    check bool "final warning mentions stay_silent"
      true (contains_substring msg "stay_silent")
  | other ->
    fail (Printf.sprintf "expected Nudge (final warning), got %s"
      (Agent_sdk.Hooks.decision_kind_to_string
        (Agent_sdk.Hooks.classify_decision other)))

let test_on_idle_skip_at_repeated_idle () =
  (* At skip_at the hook should issue Skip; use explicit threshold so the
     test does not depend on the global constant *)
  let decision = HK.on_idle_decision_with_threshold
    ~skip_at:3
    ~consecutive_idle_turns:3
    ~allowed_tools:[]
    ~tool_names:["keeper_board_list"] in
  match decision with
  | Agent_sdk.Hooks.Skip -> ()
  | other ->
    fail (Printf.sprintf "expected Skip, got %s"
      (Agent_sdk.Hooks.decision_kind_to_string
        (Agent_sdk.Hooks.classify_decision other)))

let test_on_idle_skip_with_custom_threshold () =
  (* The pure helper must respect a custom skip_at value *)
  let decision = HK.on_idle_decision_with_threshold
    ~skip_at:2
    ~consecutive_idle_turns:2
    ~allowed_tools:[]
    ~tool_names:["keeper_board_list"] in
  match decision with
  | Agent_sdk.Hooks.Skip -> ()
  | other ->
    fail (Printf.sprintf "expected Skip at custom threshold 2, got %s"
      (Agent_sdk.Hooks.decision_kind_to_string
        (Agent_sdk.Hooks.classify_decision other)))

let test_recent_tool_streak_count_counts_tail_matches () =
  let now = Time_compat.now () in
  let entries =
    [
      tool_log_entry ~ts:(now -. 30.0) "keeper_fs_read";
      tool_log_entry ~ts:(now -. 20.0) "masc_status";
      tool_log_entry ~ts:(now -. 10.0) "masc_status";
    ]
  in
  check int "tail streak count" 2
    (HK.recent_tool_streak_count ~tool_name:"masc_status" entries)

let test_recent_tool_streak_count_ignores_stale_entries () =
  let now = Time_compat.now () in
  let entries =
    [
      tool_log_entry ~ts:(now -. 1800.0) "masc_status";
      tool_log_entry ~ts:(now -. 10.0) "masc_status";
    ]
  in
  check int "stale entry does not extend streak" 1
    (HK.recent_tool_streak_count ~within_sec:60.0 ~tool_name:"masc_status"
       entries)
(* ---------- Test runner ---------- *)

let () =
  run "Keeper Cycle"
    [
      ( "world_observation",
        [
          test_case "defaults" `Quick test_observation_defaults;
          test_case "with mentions" `Quick test_observation_with_mentions;
          test_case "uses precollected board events" `Quick
            test_observe_uses_precollected_board_events;
          test_case "queued board stimulus becomes board event" `Quick
            test_board_signal_stimulus_becomes_pending_board_event;
          test_case "legacy queued board comment becomes board event" `Quick
            test_legacy_board_comment_stimulus_becomes_pending_board_event;
          test_case "splits absolute and claimable backlog" `Quick
            test_observe_splits_absolute_and_claimable_backlog;
          test_case "claimable backlog respects active goals" `Quick
            test_observe_claimable_backlog_respects_active_goal_ids;
          test_case "claimable backlog mirrors auto-goal fallback" `Quick
            test_observe_claimable_backlog_uses_auto_goal_fallback_scope;
          test_case "durable signal sees claimable backlog" `Quick
            test_durable_signal_present_sees_claimable_backlog_for_smart_hb_gate;
          test_case "durable signal filters unclaimable backlog" `Quick
            test_durable_signal_present_filters_unclaimable_backlog_for_smart_hb_gate;
          test_case "default keepers ignore unmatched non-mention board events" `Quick
            test_collect_board_events_keeps_non_mentions_as_followup_signal;
          test_case "room-signal keepers keep unmatched non-mention board events" `Quick
            test_collect_board_events_keeps_non_mentions_for_room_signal_keepers;
          test_case "keeps external replies after self comment" `Quick
            test_collect_board_events_keeps_external_replies_after_self_comment;
          test_case "treats generated alias as self comment" `Quick
            test_collect_board_events_treats_generated_alias_as_self_comment;
          test_case "default keepers ignore scope messages" `Quick
            test_observe_ignores_scope_messages_without_room_signal_opt_in;
          test_case "room-signal keepers collect scope messages" `Quick
            test_observe_collects_scope_messages_for_room_signal_keepers;
          test_case "room-signal keepers damp keeper scope chatter" `Quick
            test_observe_damps_keeper_scope_chatter_but_keeps_direct_mentions;
          test_case "stale terminal task mentions advance cursor" `Quick
            test_observe_skips_stale_terminal_task_mentions;
          test_case "scheduled turn uses cooldown only when work exists" `Quick
            test_scheduled_turn_uses_cooldown_only;
          test_case "scheduled turn skips without structured work signal" `Quick
            test_scheduled_turn_skips_without_structured_work_signal;
          test_case "scheduled turn respects cooldown" `Quick
            test_scheduled_turn_respects_cooldown;
          test_case "scheduled turn requires idle gate" `Quick
            test_scheduled_turn_requires_idle_gate;
          test_case "provider cooldown blocks scheduled turn" `Quick
            test_provider_cooldown_blocks_scheduled_turn_when_work_is_ready;
          test_case "provider cooldown keeps scheduled turn open when fail-open exists" `Quick
            test_provider_cooldown_keeps_scheduled_turn_open_when_fail_open_exists;
          test_case "idle decay: no decay within base" `Quick
            test_effective_cooldown_no_decay_within_base;
          test_case "idle decay: at boundary" `Quick
            test_effective_cooldown_at_boundary;
          test_case "idle decay: first decay" `Quick
            test_effective_cooldown_first_decay;
          test_case "idle decay: second decay" `Quick
            test_effective_cooldown_second_decay;
          test_case "idle decay: floor" `Quick
            test_effective_cooldown_floor;
          test_case "idle decay: max_int" `Quick
            test_effective_cooldown_max_int;
          test_case "noop backoff: doubles cooldown" `Quick
            test_noop_backoff_doubles_cooldown;
          test_case "noop backoff: quadruples cooldown" `Quick
            test_noop_backoff_quadruples_cooldown;
          test_case "noop backoff: caps at 8x" `Quick
            test_noop_backoff_caps_at_8x;
          test_case "noop backoff: zero noops unchanged" `Quick
            test_noop_backoff_zero_noops_unchanged;
          test_case "idle decay: triggers turn" `Quick
            test_idle_decay_triggers_turn;
          test_case "scheduled decision uses backlog acceleration" `Quick
            test_scheduled_turn_decision_uses_backlog_acceleration;
          test_case "scheduled decision ignores unclaimable backlog" `Quick
            test_scheduled_turn_ignores_unclaimable_backlog;
          test_case "verdict reasons use structured run tags" `Quick
            test_verdict_reasons_to_strings_uses_structured_run_tags;
          test_case "verdict reasons use structured skip tags" `Quick
            test_verdict_reasons_to_strings_uses_structured_skip_tags;
          test_case "paused keeper blocks turns" `Quick
            test_paused_keeper_blocks_turns_even_with_reactive_signal;
          test_case "pending approval blocks turns" `Quick
            test_pending_approval_blocks_turns_until_resolved;
          test_case "task reactive cooldown floor never hits zero" `Quick
            test_task_reactive_cooldown_floor_never_hits_zero;
          test_case "task backlog cooldown applies noop backoff once" `Quick
            test_task_backlog_cooldown_applies_noop_backoff_once;
          test_case "fresh backlog update bypasses cooldown" `Quick
            test_scheduled_turn_decision_runs_immediately_on_fresh_backlog_update;
          test_case "bootstrap: fires when keeper never started" `Quick
            test_bootstrap_turn_fires_when_never_started;
          test_case "bootstrap: channel is scheduled_autonomous" `Quick
            test_bootstrap_turn_emits_scheduled_autonomous_channel;
          test_case "bootstrap: provider cooldown blocks first turn" `Quick
            test_provider_cooldown_blocks_bootstrap_turn;
          test_case "min interval: fires without work signal after interval" `Quick
            test_min_interval_fires_without_work_signal;
          test_case "min interval: not tagged entropic" `Quick
            test_min_interval_turn_is_not_tagged_entropic;
          test_case "min interval: does not fire before elapsed" `Quick
            test_min_interval_does_not_fire_before_elapsed;
          test_case "min interval: never fires for bootstrap turn" `Quick
            test_min_interval_never_fires_for_bootstrap;
          test_case "min interval: provider cooldown blocks turn" `Quick
            test_provider_cooldown_blocks_min_interval_turn;
	          test_case "runtime trust snapshot tolerates null telemetry" `Quick
	            test_runtime_trust_snapshot_tolerates_null_telemetry;
	          test_case "runtime trust snapshot surfaces terminal reason" `Quick
	            test_runtime_trust_snapshot_surfaces_terminal_reason;
	          test_case "runtime trust snapshot reads terminal reason code alias" `Quick
	            test_runtime_trust_snapshot_reads_terminal_reason_code_alias;
	          test_case "with goals" `Quick test_observation_with_goals;
          test_case "economic modes" `Quick test_observation_economic_modes;
        ] );
      ( "unified_prompt",
        [
          test_case "contains identity" `Quick test_prompt_contains_identity;
          test_case "contains goal" `Quick test_prompt_contains_goal;
          test_case "mentions extend_turns guidance" `Quick
            test_prompt_mentions_extend_turns_guidance;
          test_case "includes operational tool guidance" `Quick
            test_prompt_includes_operational_tool_guidance;
          test_case "includes research evidence contract" `Quick
            test_prompt_includes_research_evidence_contract;
          test_case "distinguishes sandbox and worktree" `Quick
            test_capabilities_prompt_distinguishes_sandbox_and_worktree;
          test_case "world prompt distinguishes sandbox and worktree" `Quick
            test_world_prompt_distinguishes_sandbox_and_worktree;
          test_case "prefers submit over legacy workflow" `Quick
            test_system_prompt_prefers_bash_and_gh_pr_lane;
          test_case "includes autonomous trigger section" `Quick
            test_prompt_includes_autonomous_trigger_section;
          test_case "omits autonomous trigger for reactive turn" `Quick
            test_prompt_omits_autonomous_trigger_for_reactive_turn;
          test_case "omits empty sections" `Quick test_prompt_omits_empty_sections;
          test_case "continuity drops inert idle directives" `Quick
            test_prompt_continuity_drops_inert_idle_directives;
          test_case "continuity drops stale tool surface claims" `Quick
            test_prompt_continuity_drops_stale_tool_surface_claims;
          test_case "includes mentions" `Quick test_prompt_includes_mentions_section;
          test_case "includes board activity" `Quick
            test_prompt_includes_board_activity_section;
          test_case "marks board curation due" `Quick
            test_prompt_marks_board_curation_due_for_multi_event_window;
          test_case "includes goals" `Quick test_prompt_includes_goals_section;
          test_case "includes context ratio" `Quick test_prompt_includes_context_ratio;
          test_case "includes idle" `Quick test_prompt_includes_idle;
          test_case "frugal economy" `Quick test_prompt_frugal_economy;
          test_case "hustle economy" `Quick test_prompt_hustle_economy;
          test_case "includes worktree delta" `Quick test_prompt_includes_worktree_delta;
          test_case "orders stable sections before reactive sections" `Quick
            test_prompt_orders_stable_sections_before_reactive_sections;
          test_case "room state section" `Quick test_prompt_room_state_section;
          test_case "claim first guidance" `Quick
            test_prompt_includes_claim_first_guidance;
          test_case "claim first guidance omitted when no task is claimable" `Quick
            test_prompt_omits_claim_first_guidance_when_no_claimable_tasks;
          test_case "claim first guidance omitted when task claimed" `Quick
            test_prompt_omits_claim_first_guidance_when_task_claimed;
          test_case "claim first guidance omitted when tool unavailable" `Quick
            test_prompt_omits_claim_first_guidance_when_claim_tool_unavailable;
          test_case "claim first guidance omitted when paused" `Quick
            test_prompt_omits_claim_first_guidance_when_paused;
          test_case "work discovery nudge uses registered tool schemas" `Quick
            test_work_discovery_nudge_uses_registered_keeper_tool_schemas;
          test_case "prefers silence guidance" `Quick
            test_prompt_prefers_silence_guidance;
          test_case "sanitize_text_utf8 replaces control chars" `Quick
            test_sanitize_text_utf8_replaces_control_chars;
          test_case "prompt sanitizes control chars" `Quick
            test_prompt_sanitizes_control_chars;
          test_case "sanitize_messages_utf8 cleans history path" `Quick
            test_sanitize_messages_utf8_cleans_history_path;
          test_case "sanitize_messages_utf8 reuses clean history list" `Quick
            test_sanitize_messages_utf8_reuses_clean_history_list;
        ] );
      ( "metacognition",
        [
          test_case "on_idle nudge at first idle" `Quick
            test_on_idle_nudge_at_first_idle;
          test_case "on_idle final warning before skip" `Quick
            test_on_idle_final_warning_before_skip;
          test_case "on_idle skip at repeated idle" `Quick
            test_on_idle_skip_at_repeated_idle;
          test_case "on_idle skip with custom threshold" `Quick
            test_on_idle_skip_with_custom_threshold;
          test_case "recent tool streak counts tail matches" `Quick
            test_recent_tool_streak_count_counts_tail_matches;
          test_case "recent tool streak ignores stale entries" `Quick
            test_recent_tool_streak_count_ignores_stale_entries;
        ] );
      ( "config",
        [
          test_case "default social model" `Quick
            test_meta_defaults_social_model;
          test_case "unified runtime defaults" `Quick
            test_unified_turn_runtime_defaults;
        ] );
      ( "metrics_observation",
        [
          test_case "prompt metrics fingerprint" `Quick
            test_prompt_metrics_fingerprint_is_deterministic;
          test_case "text response" `Quick test_metrics_text_response;
          test_case "idle seconds gauge records observation" `Quick
            test_metrics_idle_seconds_gauge_records_observation;
          test_case "surface model prefers successful cascade label" `Quick
            test_metrics_surface_model_prefers_successful_cascade_label;
          test_case "resolved_model_id prefers last attempt id (#9953)"
            `Quick
            test_metrics_resolved_model_id_prefers_last_attempt_id;
          test_case "resolved_model_id falls back to model_used (#9953)"
            `Quick test_metrics_resolved_model_id_fallback_to_model_used;
          test_case "tool response" `Quick test_metrics_tool_response;
          test_case "noop response" `Quick test_metrics_noop_response;
          test_case "observation-only tools are noop" `Quick
            test_metrics_observation_only_tools_are_noop;
          test_case "execution tools are substantive" `Quick
            test_metrics_execution_tools_are_substantive;
          test_case "validated evidence counts as visible" `Quick
            test_metrics_validated_evidence_counts_as_visible;
          test_case "failed validation does not count as visible" `Quick
            test_metrics_failed_validation_does_not_count_as_visible;
          test_case "file write evidence counts as visible" `Quick
            test_metrics_file_write_evidence_counts_as_visible;
          test_case "heartbeat-only tool response is maintenance only" `Quick
            test_metrics_heartbeat_only_tool_response_is_maintenance_only;
          test_case "reactive turn leaves proactive runtime untouched" `Quick
            test_metrics_reactive_turn_does_not_mutate_proactive_runtime;
          test_case "silent proactive cycle advances cooldown anchor" `Quick
            test_silent_proactive_cycle_advances_cooldown_anchor;
          test_case "reactive failure leaves proactive runtime untouched" `Quick
            test_metrics_reactive_failure_does_not_mutate_proactive_runtime;
          test_case "legacy migration does not infer visible proactive fields" `Quick
            test_meta_migration_does_not_infer_visible_proactive_fields;
          test_case "snapshot includes cascade observation" `Quick
            test_append_metrics_snapshot_includes_cascade_observation;
          test_case "snapshot treats validated evidence as tool use" `Quick
            test_append_metrics_snapshot_treats_validated_evidence_as_tool_use;
          test_case "snapshot counts only mode violation refs" `Quick
            test_append_metrics_snapshot_counts_only_mode_violation_refs;
          test_case "snapshot nulls unreported usage" `Quick
            test_append_metrics_snapshot_nulls_unreported_usage;
          test_case "snapshot persists cache usage" `Quick
            test_append_metrics_snapshot_persists_cache_usage;
          test_case "trusted usage cost uses cache token pricing" `Quick
            test_estimate_trusted_usage_cost_uses_cache_usage;
          test_case "total cost gauge records accumulated keeper cost" `Quick
            test_record_keeper_total_cost_metric;
          test_case "snapshot marks untrusted usage" `Quick
            test_append_metrics_snapshot_marks_untrusted_usage;
          test_case "decision record persists tool call details" `Quick
            test_append_decision_record_persists_tool_calls;
	          test_case "decision record nulls unreported usage" `Quick
	            test_append_decision_record_nulls_unreported_usage;
	          test_case "decision record classifies worktree blocker" `Quick
	            test_append_decision_record_classifies_legacy_worktree_error;
	          test_case "decision record preserves no-result skipped outcome" `Quick
	            test_append_decision_record_preserves_no_result_skipped_outcome;
	          test_case "social fields" `Quick
	            test_metrics_persist_social_state_fields;
          test_case "failure response" `Quick test_metrics_failure_response;
          test_case "timeout failure increments proactive backoff" `Quick
            test_metrics_failure_timeout_increments_proactive_backoff;
          test_case "failure response redacts resumable session detail" `Quick
            test_metrics_failure_response_redacts_resumable_cli_session_detail;
          test_case "mixed response" `Quick test_metrics_mixed_response;
          test_case "normalize passthrough" `Quick
            test_normalize_response_text_passthrough;
          test_case "normalize tool only synthesizes" `Quick
            test_normalize_response_text_tool_only_synthesizes;
          test_case "normalize empty without tools errors" `Quick
            test_normalize_response_text_empty_without_tools_errors;
          test_case "completion contract allows text without tools" `Quick
            test_validate_completion_contract_allows_text_without_tools;
          test_case "completion contract requires tool use" `Quick
            test_validate_completion_contract_requires_tool_use;
          test_case "completion contract accepts stay silent" `Quick
            test_validate_completion_contract_accepts_stay_silent;
          test_case "unexpected tool names accepts keeper surface" `Quick
            test_unexpected_tool_names_accepts_keeper_surface;
          test_case "unexpected tool names reports foreign surface" `Quick
            test_unexpected_tool_names_reports_foreign_surface;
          test_case "completion contract mapping allows auto" `Quick
            test_completion_contract_of_tool_choice_allows_auto;
          test_case "completion contract mapping requires any" `Quick
            test_completion_contract_of_tool_choice_requires_any;
          test_case "run completion contract latches required tool use"
            `Quick test_run_completion_contract_latches_required_tool_use;
          test_case
            "completion contract presence requires keeper-surface tool"
            `Quick
            test_validate_completion_contract_presence_requires_keeper_surface_tool;
          test_case "actionable signal rejects no tools" `Quick
            test_actionable_tool_contract_flags_no_tools;
          test_case "actionable signal rejects passive-only tools" `Quick
            test_actionable_tool_contract_flags_passive_only_tools;
          test_case
            "actionable signal rejects claim context after ownership"
            `Quick
            test_actionable_tool_contract_rejects_claim_context_when_already_claimed;
          test_case
            "actionable signal rejects stay_silent after ownership"
            `Quick
            test_actionable_tool_contract_rejects_stay_silent_when_already_claimed;
          test_case "claim tool classification covers masc claim task" `Quick
            test_claim_tool_classification_covers_masc_claim_task;
          test_case "actionable signal allows execution tools" `Quick
            test_actionable_tool_contract_allows_execution_tools;
          test_case "stay_silent needs typed no-work proof on actionable signal" `Quick
            test_stay_silent_requires_typed_no_work_proof_on_actionable_signal;
          test_case "required tool predicate rejects passive tools" `Quick
            test_required_tool_satisfaction_rejects_passive_tools;
          test_case "required tool predicate accepts mutating tools" `Quick
            test_required_tool_satisfaction_accepts_mutating_tools;
          test_case "tool usage delta uses registry counts" `Quick
            test_tool_usage_delta_uses_registry_counts;
          test_case "tool usage delta ignores removed tools" `Quick
            test_tool_usage_delta_ignores_removed_tools;
          test_case "merge observed tool names uses hook evidence" `Quick
            test_merge_observed_tool_names_prefers_hook_without_double_counting;
          test_case "merge observed tool names keeps extra registry repeats" `Quick
            test_merge_observed_tool_names_preserves_extra_registry_repeats;
          test_case "merge observed and synthetic tool names" `Quick
            test_merge_reported_and_observed_tool_names_preserves_synthetic_tools;
          test_case "final keeper tool names fall back to reported tools"
            `Quick
            test_final_keeper_tool_names_falls_back_to_reported_tool_use;
          test_case "final keeper tool names accept reported MCP keeper tool"
            `Quick
            test_final_keeper_tool_names_accepts_reported_mcp_keeper_tool;
          test_case "tool query strips continuity noise" `Quick
            test_tool_query_text_of_user_message_strips_continuity_noise;
          test_case "tool query keeps counted headers" `Quick
            test_tool_query_text_of_user_message_keeps_counted_headers;
          test_case "scope messages cap prompt payload not count" `Quick
            test_scope_messages_prompt_caps_payload_not_count;
          test_case "social model registry round trip" `Quick
            test_social_model_registry_round_trip;
          test_case "social model silences skip-only turn" `Quick
            test_social_model_silences_skip_only_turn;
          test_case "social model unknown meta falls back to baseline" `Quick
            test_social_model_unknown_meta_falls_back_to_baseline;
          test_case "social model unknown header falls back to baseline" `Quick
            test_social_model_unknown_header_falls_back_to_baseline;
          test_case "social model infers visible reply without headers" `Quick
            test_social_model_infers_visible_reply_without_headers;
          test_case "social model empty text without headers stays silent" `Quick
            test_social_model_empty_text_without_headers_stays_silent;
          test_case "social model state-only reply stays silent" `Quick
            test_social_model_state_only_reply_stays_silent;
          test_case "social model strips state block from visible reply" `Quick
            test_social_model_strips_state_block_from_visible_reply;
          test_case "social model routes blocker to board post" `Quick
            test_social_model_routes_blocker_to_board_post;
          test_case "social model tool-only turn skips protocol violation" `Quick
            test_social_model_tool_only_turn_skips_protocol_violation;
          test_case "social model restores previous state from runtime" `Quick
            test_social_model_previous_state_of_meta_restores_runtime_fields;
          test_case "social model tool-only turn carries previous state" `Quick
            test_social_model_tool_only_turn_carries_previous_state;
          test_case "social model infers board comment from tool use" `Quick
            test_social_model_infers_board_comment_from_tool_use;
          test_case
            "social model does not infer comment vote as board comment" `Quick
            test_social_model_does_not_infer_comment_vote_as_board_comment;
          test_case "social model infers masc claim task from tool use" `Quick
            test_social_model_infers_masc_claim_task_from_tool_use;
          test_case "magentic ledger silences tool-only turn" `Quick
            test_social_model_magentic_ledger_silences_tool_only_turn;
          test_case "magentic ledger tracks masc claim task" `Quick
            test_social_model_magentic_ledger_tracks_masc_claim_task;
          test_case "magentic ledger hides non-visible tool text" `Quick
            test_social_model_magentic_ledger_hides_nonvisible_tool_text;
          test_case "magentic ledger restores previous state model" `Quick
            test_social_model_magentic_ledger_previous_state_of_meta_restores_model;
          test_case "social model previous state falls back for unknown model" `Quick
            test_social_model_previous_state_of_meta_falls_back_for_unknown_model;
          test_case "bdi failure rewrites stale claim retry loop" `Quick
            test_social_model_bdi_failure_state_rewrites_claim_retry_loop;
          test_case "bdi required-tool failure requests help" `Quick
            test_social_model_required_tool_failure_requests_help;
          test_case "bdi failure keeps ordinary carry state" `Quick
            test_social_model_bdi_failure_state_keeps_existing_carry_without_claim_context;
          test_case "magentic ledger stalled state carries until delta" `Quick
            test_social_model_magentic_ledger_stalled_state_carries_until_delta;
          test_case "render_inline deny" `Quick
            test_render_inline_skip_reason_deny;
          test_case "render_inline cost" `Quick
            test_render_inline_skip_reason_cost;
          test_case "render_inline destructive" `Quick
            test_render_inline_skip_reason_destructive;
          test_case "normalize override passthrough" `Quick
            test_normalize_override_passthrough;
          test_case "escape edge cases" `Quick
            test_render_inline_escape_edge_cases;
          test_case "render_inline with replacement" `Quick
            test_render_inline_with_replacement;
        ] );
      ( "transient_network_error",
        [
          test_case "NetworkError detected" `Quick (fun () ->
            check bool "network error" true
              (EC.is_transient_network_error
                 (Agent_sdk.Error.Api
                    (NetworkError
                       {
                         message = "Connection_reset";
                         kind = Llm_provider.Http_client.Connection_refused;
                       }))));
          test_case "Timeout detected" `Quick (fun () ->
            check bool "timeout" true
              (EC.is_transient_network_error
                 (Agent_sdk.Error.Api (Timeout { message = "connection timed out" }))));
          test_case "structural OAS timeout is not network transient" `Quick (fun () ->
            check bool "oas budget timeout" false
              (EC.is_transient_network_error
                 (Agent_sdk.Error.Api
                    (Timeout { message = "Timeout after 573.2s (budget=573s)" }))));
          test_case "Overloaded detected" `Quick (fun () ->
            check bool "overloaded" true
              (EC.is_transient_network_error
                 (Agent_sdk.Error.Api (Overloaded { message = "server busy" }))));
          test_case "ServerError 503 detected" `Quick (fun () ->
            check bool "503" true
              (EC.is_transient_network_error
                 (Agent_sdk.Error.Api (ServerError { status = 503; message = "Service Unavailable" }))));
          test_case "ServerError 500 not transient" `Quick (fun () ->
            check bool "500" false
              (EC.is_transient_network_error
                 (Agent_sdk.Error.Api (ServerError { status = 500; message = "Internal" }))));
          test_case "AuthError not transient" `Quick (fun () ->
            check bool "auth" false
              (EC.is_transient_network_error
                 (Agent_sdk.Error.Api (AuthError { message = "Unauthorized" }))));
          test_case "RateLimited not transient" `Quick (fun () ->
            check bool "rate limit" false
              (EC.is_transient_network_error
                 (Agent_sdk.Error.Api (RateLimited { retry_after = None; message = "429" }))));
          test_case "ContextOverflow not transient" `Quick (fun () ->
            check bool "overflow" false
              (EC.is_transient_network_error
                 (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = None }))));
          test_case "Internal error not transient" `Quick (fun () ->
            check bool "internal" false
              (EC.is_transient_network_error
                 (Agent_sdk.Error.Internal "some error")));
          test_case "timeout after mutating tool becomes persistent" `Quick
            test_side_effect_timeout_reclassified_as_persistent;
          test_case "reclassification requires committed tools" `Quick
            test_side_effect_reclassification_requires_committed_tools;
          test_case "read-only tool timeouts stay transient" `Quick
            test_side_effect_reclassification_ignores_read_only_tools;
          test_case "any post-commit error becomes ambiguous partial" `Quick
            test_side_effect_reclassification_marks_any_post_commit_error;
          test_case "timeout classified as post-commit timeout" `Quick
            test_post_commit_failure_kind_marks_timeouts;
          test_case "non-timeout classified as post-commit failure" `Quick
            test_post_commit_failure_kind_marks_non_timeouts_as_failures;
          test_case "ollama closing brace detected as server parse error" `Quick
            test_server_rejected_parse_error_ollama_closing_brace;
          test_case "unterminated JSON detected as server parse error" `Quick
            test_server_rejected_parse_error_unterminated;
          test_case "unexpected character in JSON detected" `Quick
            test_server_rejected_parse_error_unexpected_char;
          test_case "parse error detected" `Quick
            test_server_rejected_parse_error_parse_error;
          test_case "case insensitive detection" `Quick
            test_server_rejected_parse_error_case_insensitive;
          test_case "generic InvalidRequest is NOT server parse error" `Quick
            test_server_rejected_parse_error_generic_invalid_request;
          test_case "generic 'closing' is NOT server parse error" `Quick
            test_server_rejected_parse_error_generic_closing;
          test_case "generic 'can't find' is NOT server parse error" `Quick
            test_server_rejected_parse_error_generic_cant_find;
          test_case "network error is NOT server parse error" `Quick
            test_server_rejected_parse_error_network_error;
          test_case "auto-recoverable includes transient network" `Quick
            test_auto_recoverable_turn_error_includes_transient_network;
          test_case "auto-recoverable includes server parse rejection" `Quick
            test_auto_recoverable_turn_error_includes_server_parse_rejection;
          test_case "auto-recoverable includes wrapped hard quota" `Quick
            test_auto_recoverable_turn_error_includes_wrapped_hard_quota;
          test_case "auto-recoverable includes wrapped CLI max turns" `Quick
            test_auto_recoverable_turn_error_includes_wrapped_max_turns;
          test_case "required tool contract violation detected from structured error" `Quick
            test_required_tool_contract_violation_detected;
          test_case "legacy internal contract violation is ignored" `Quick
            test_required_tool_contract_violation_ignores_legacy_internal_error;
          test_case "rotation cap does not fire before first rotation" `Quick
            test_should_cap_rotation_does_not_fire_on_first_attempt;
          test_case "rotation cap fires after one rotation" `Quick
            test_should_cap_rotation_fires_after_one_rotation;
          test_case "rotation cap suppressed while fallback available" `Quick
            test_should_cap_rotation_suppressed_while_fallback_available;
          test_case "rotation cap ignores non-contract-violation errors" `Quick
            test_should_cap_rotation_ignores_non_contract_violation_error;
          test_case "structured cascade exhausted error detected" `Quick
            test_cascade_exhausted_error_detected_from_structured_internal_error;
          test_case "legacy internal cascade exhaustion is ignored" `Quick
            test_cascade_exhausted_error_ignores_legacy_internal_error;
          test_case "auto-recoverable excludes tool-choice contract violation" `Quick
            test_auto_recoverable_turn_error_excludes_required_tool_contract_violation;
          test_case "auto-recoverable excludes persistent errors" `Quick
            test_auto_recoverable_turn_error_excludes_persistent_errors;
          test_case "auto-recoverable includes wrapped cascade hard quota" `Quick
            test_auto_recoverable_turn_error_includes_wrapped_cascade_exhausted_hard_quota;
          test_case "auto-recoverable includes wrapped cascade max turns" `Quick
            test_auto_recoverable_turn_error_includes_wrapped_cascade_max_turns;
          test_case "auto-recoverable includes filtered candidates cascade exhaustion" `Quick
            test_auto_recoverable_turn_error_includes_filtered_candidates_cascade_exhaustion;
          test_case "auto-recoverable includes resumable CLI session error" `Quick
            test_auto_recoverable_turn_error_includes_resumable_cli_session_error;
          test_case "cascade exhausted surface includes resumable CLI session error" `Quick
            test_cascade_exhausted_error_includes_resumable_cli_session_error;
          test_case "bounded OAS timeout keeps adaptive timeout under full budget" `Quick
            test_bounded_oas_timeout_uses_adaptive_when_budget_is_large;
          test_case "bounded OAS timeout is token-independent (#10008 fm2)" `Quick
            test_bounded_oas_timeout_is_token_independent;
          test_case "bounded OAS timeout caps to remaining turn budget" `Quick
            test_bounded_oas_timeout_caps_to_remaining_turn_budget;
          test_case "bounded OAS timeout respects channel turn budget override" `Quick
            test_bounded_oas_timeout_uses_channel_turn_budget_override;
          test_case "bounded OAS timeout reserves degraded retry budget" `Quick
            test_bounded_oas_timeout_reserves_degraded_retry_budget;
          test_case "attempt watchdog preserves degraded retry reserve" `Quick
            test_attempt_watchdog_preserves_degraded_retry_reserve;
          test_case "attempt watchdog fires before outer turn timeout" `Quick
            test_attempt_watchdog_fires_before_outer_turn_timeout;
          test_case "bounded OAS timeout refuses too little remaining budget" `Quick
            test_bounded_oas_timeout_refuses_too_little_budget;
          test_case "OAS timeout classification uses current attempt budget" `Quick
            test_oas_timeout_reclassifies_only_current_attempt_budget;
          test_case "plain pre-retry timeout helper does not reuse stale budget" `Quick
            test_pre_retry_timeout_helper_does_not_reuse_stale_budget;
          test_case "degraded retry is allowed when turn budget remains" `Quick
            test_degraded_retry_budget_gate_allows_remaining_budget;
          test_case "degraded retry is blocked when turn budget is exhausted" `Quick
            test_degraded_retry_budget_gate_blocks_exhausted_budget;
          test_case "OAS timeout budget can still rotate to local recovery after slot phase" `Quick
            test_degraded_retry_slot_phase_allows_oas_timeout_local_recovery;
          test_case "contract retry gets first rotation after slot phase (#12888)"
            `Quick
            test_degraded_retry_slot_phase_allows_first_contract_rotation;
          test_case "per-attempt retry budget with near-zero remaining (#12675)" `Quick
            test_per_attempt_retry_budget_with_near_zero_remaining;
          test_case "per-attempt retry budget capped by healthy remaining" `Quick
            test_per_attempt_retry_budget_capped_by_remaining_when_healthy;
          test_case "plain retry blocks after adaptive budget is spent" `Quick
            test_per_attempt_retry_blocks_after_adaptive_budget_spent;
          test_case "degraded retry can use remaining wall-clock budget" `Quick
            test_degraded_retry_wall_clock_budget_allows_remaining_turn_time;
          test_case "degraded retry wall-clock budget is one-shot" `Quick
            test_degraded_retry_wall_clock_budget_gate_is_one_shot;
          test_case "non-retry still refuses tiny budget" `Quick
            test_non_retry_still_refuses_tiny_budget;
          test_case "per-attempt retry refuses zero remaining (#12675)" `Quick
            test_per_attempt_retry_refuses_zero_remaining;
          test_case "degraded retry gate allows retry with tiny remaining (#12675)" `Quick
            test_degraded_retry_budget_gate_allows_retry_with_tiny_remaining;
          test_case "pure local label detection" `Quick
            test_pure_local_labels_detection;
          test_case "pure local context clamp" `Quick
            test_clamp_context_for_pure_local_labels;
          test_case "turn context budget uses primary model" `Quick
            test_resolved_max_context_for_turn_uses_primary_budget;
          test_case "max_context resolution separates override and effective budget" `Quick
            test_max_context_resolution_separates_override_and_effective_budget;
          test_case "resolved max_context dispatch uses effective budget" `Quick
            test_resolved_max_context_for_turn_uses_effective_budget;
          test_case "read-only keeper tools do not become ambiguous partial" `Quick
            test_side_effect_reclassification_ignores_keeper_read_only_tools;
          test_case "mixed tool sets only keep mutating keeper tools" `Quick
            test_side_effect_reclassification_drops_keeper_read_only_tools_from_mixed_set;
          test_case "overflow detection and limit parsing" `Quick
            test_overflow_detection_and_limit_parsing;
        ] );
      ( "context_overflow",
        [
          test_case "parses common OAS overflow errors (SSOT)" `Quick
            test_context_overflow_limit_parses_common_oas_errors;
          test_case "is_context_overflow only matches ContextOverflow" `Quick
            test_is_context_overflow_only_for_overflow_errors;
          test_case "summarize_turn_event_bus extracts overflow signal" `Quick
            test_summarize_turn_event_bus_extracts_overflow_signal;
          test_case "context_overflow_event prefers event bus signal" `Quick
            test_context_overflow_event_prefers_event_bus_signal;
          test_case "context_overflow_event falls back without event bus signal" `Quick
            test_context_overflow_event_falls_back_without_event_bus_signal;
        ] );
      ( "phase_gate",
        [
          test_case "run_keeper_cycle skips paused keeper" `Quick
            test_run_keeper_cycle_skips_non_executable_phase;
          test_case "streaming cancel records supervisor stop" `Quick
            test_streaming_cancel_records_supervisor_stop_when_fiber_stop_set;
          test_case "run_keeper_cycle records trajectory contract" `Quick
            test_run_keeper_cycle_records_trajectory_source_contract;
          test_case "pre-tool gates record durable attempt telemetry" `Quick
            test_pre_tool_gate_records_durable_attempt_telemetry;
          test_case "run_keeper_cycle surfaces side-effect failures contract"
            `Quick
            test_run_keeper_cycle_surfaces_side_effect_failures_source_contract;
          test_case "paused-state sync surfaces write failure" `Quick
            test_sync_keeper_paused_state_surfaces_write_failure_without_mutating_registry;
          test_case "local discovery guard surfaces refresh failure" `Quick
            test_ensure_local_discovery_ready_surfaces_refresh_failure;
          test_case "local_only liveness decision keeps non-local route" `Quick
            test_decide_local_only_liveness_keeps_non_local_effective;
          test_case "local_only liveness decision keeps explicit local base"
            `Quick
            test_decide_local_only_liveness_keeps_explicit_local_only;
          test_case "local_only liveness decision requests deduped probe"
            `Quick
            test_decide_local_only_liveness_requests_deduped_ollama_probe;
          test_case "local_only fail-open falls back when ollama is down" `Quick
            test_fail_open_local_only_when_probe_fails;
          test_case "explicit local_only does not fail-open" `Quick
            test_fail_open_local_only_preserves_explicit_local_only_base;
          test_case "healthy local_only stays selected" `Quick
            test_fail_open_local_only_preserves_healthy_local_only;
          test_case "PR-B: empty labels are not ollama-only" `Quick
            test_resolve_ollama_only_base_url_empty_returns_none;
          test_case "PR-B: single ollama label is ollama-only" `Quick
            test_resolve_ollama_only_base_url_single_ollama;
          test_case "PR-B: mixed providers are not ollama-only" `Quick
            test_resolve_ollama_only_base_url_mixed_provider;
          test_case "PR-B: different ollama hosts are not ollama-only" `Quick
            test_resolve_ollama_only_base_url_different_hosts;
          test_case "PR-B: missing cache is fail-open" `Quick
            test_is_ollama_saturated_returns_false_when_cache_missing;
          test_case "PR-B: idle endpoint not saturated" `Quick
            test_is_ollama_saturated_returns_false_when_idle;
          test_case "PR-B: full endpoint with queue is saturated" `Quick
            test_is_ollama_saturated_returns_true_when_full_with_queue;
          test_case "PR-B: zero available without traffic is fail-open" `Quick
            test_is_ollama_saturated_ignores_zero_available_when_idle;
          test_case "PR-B follow-up: fresh keeper has zero skip count" `Quick
            test_saturation_skip_count_starts_at_zero;
          test_case "PR-B follow-up: inc returns monotonic counts" `Quick
            test_saturation_skip_count_inc_returns_new_value;
          test_case "PR-B follow-up: reset zeros one keeper only" `Quick
            test_saturation_skip_count_reset_zeros_one_keeper;
          test_case "PR-B follow-up: cap floored at 1" `Quick
            test_saturation_skip_cap_default_is_at_least_one;
          test_case "hard quota degraded retry uses local_recovery" `Quick
            test_degraded_retry_after_recoverable_error_uses_local_recovery_for_hard_quota;
          test_case "resumable session degraded retry uses local_recovery"
            `Quick
            test_degraded_retry_after_recoverable_error_uses_local_recovery_for_resumable_session;
          test_case "admission queue timeout is degraded-retry eligible"
            `Quick
            test_degraded_retry_after_recoverable_error_includes_admission_queue_timeout;
          test_case "turn timeout is degraded-retry eligible" `Quick
            test_degraded_retry_after_recoverable_error_includes_turn_timeout;
          test_case "OAS timeout budget is degraded-retry eligible" `Quick
            test_degraded_retry_after_recoverable_error_includes_oas_timeout_budget;
          test_case "max turns is degraded-retry eligible" `Quick
            test_degraded_retry_after_recoverable_error_includes_max_turns;
          test_case "required tool turns block degraded retry" `Quick
            test_degraded_retry_after_recoverable_error_blocks_required_tools;
          test_case "local_only stays terminal for degraded retry" `Quick
            test_degraded_retry_after_recoverable_error_does_not_broaden_local_only;
          test_case "local_recovery stays terminal for degraded retry" `Quick
            test_degraded_retry_after_recoverable_error_does_not_broaden_local_recovery;
          test_case "unavailable profile fallback prefers default" `Quick
            test_fallback_cascade_for_unavailable_profile_prefers_default;
          test_case "unavailable phase override fallback prefers base" `Quick
            test_fallback_cascade_for_unavailable_profile_prefers_base_after_phase_override;
          test_case "next degraded retry returns untried default cascade"
            `Quick
            test_next_fail_open_cascade_for_turn_returns_untried_default_cascade;
          test_case "next degraded retry continues to local_recovery"
            `Quick
            test_next_fail_open_cascade_for_turn_continues_to_local_recovery;
          test_case "next degraded retry suppresses exhausted rotation group"
            `Quick
            test_next_fail_open_cascade_for_turn_suppresses_exhausted_rotation_group;
          test_case "required-tool rotation uses default without strict injection"
            `Quick
            test_next_fail_open_cascade_for_required_tool_uses_default_not_strict;
          test_case "required tool turns rotate without dropping requirement"
            `Quick
            test_next_fail_open_cascade_for_turn_allows_required_tool_rotation;
          test_case "required tool contract violations rotate retry lane"
            `Quick
            test_next_fail_open_cascade_for_turn_retries_required_tool_contract_violation;
          test_case "catalog rotation can continue beyond reserved recovery"
            `Quick
            test_next_fail_open_cascade_for_turn_uses_catalog_rotation_profile;
          test_case "catalog rotation does not inject missing default"
            `Quick
            test_next_fail_open_cascade_for_turn_does_not_inject_default_when_catalog_omits_it;
          test_case "required-tool catalog rotation filters local recovery"
            `Quick
            test_next_fail_open_cascade_for_required_tool_filters_local_recovery_catalog;
          test_case "required-tool local-recovery-only catalog exhausts"
            `Quick
            test_next_fail_open_cascade_for_required_tool_rejects_local_recovery_only_catalog;
          test_case "classifier filters required-tool catalog rotation"
            `Quick
            test_degraded_rotation_after_recoverable_error_filters_required_catalog_directly;
          test_case
            "classifier preserves explicit local_recovery fallback profile"
            `Quick
            test_degraded_rotation_preserves_local_recovery_profile_hint_for_required_tool;
          test_case "classifier normalizes catalog rotation"
            `Quick
            test_degraded_rotation_after_recoverable_error_normalizes_catalog_directly;
          test_case "fallback_hint preempts catalog rotation"
            `Quick
            test_degraded_rotation_prefers_fallback_hint_over_catalog;
          test_case "fallback_hint skipped when already attempted"
            `Quick
            test_degraded_rotation_skips_already_attempted_fallback_hint;
          test_case "blank fallback_hint behaves like no hint"
            `Quick
            test_degraded_rotation_ignores_blank_fallback_hint;
          test_case "catalog rotation order merges reserved and assignable"
            `Quick
            test_fail_open_rotation_cascades_from_catalog_merges_reserved_and_assignable;
          test_case "catalog rotation preserves catalog order"
            `Quick
            test_fail_open_rotation_cascades_from_catalog_preserves_catalog_order;
          test_case "unresolved catalog keeps legacy rotation fallback"
            `Quick
            test_fail_open_rotation_cascades_from_catalog_empty_when_unresolved;
          test_case "resolved catalog without assignable candidates falls back"
            `Quick
            test_fail_open_rotation_cascades_from_catalog_empty_without_assignable_candidates;
        ] );
      ( "tool_classification",
        [
          test_case "keeper allowed tools exclude heartbeat" `Quick
            test_keeper_allowed_tools_exclude_heartbeat;
          test_case "initial tool requirement mirrors first-turn gate" `Quick
            test_should_require_tools_for_initial_turn_matches_first_turn_gate;
          test_case "initial tool requirement covers actionable affordances"
            `Quick
            test_should_require_tools_for_initial_turn_covers_actionable_affordances;
          test_case "task backlog required turn prefers claim tool choice"
            `Quick test_preferred_tool_choice_for_required_turn_claims_first;
          test_case "direct keeper msg timeout overrides stale per-provider timeout"
            `Quick
            test_direct_keeper_msg_timeout_overrides_meta_per_provider_timeout;
          test_case "affordance gate filters by allowed_tool_names"
            `Quick
            test_turn_affordances_require_tool_gate_with_allowed_filters_by_tool;
          test_case "affordance gate suppression emits metric" `Quick
            test_turn_affordance_gate_suppression_metric;
          test_case "required gate surface removes passive distractions" `Quick
            test_required_gate_surface_removes_passive_distractions;
          test_case "tools_for_gated_affordance non-empty for every variant"
            `Quick test_tools_for_gated_affordance_covers_each_variant;
        ] );
      ( "verification_surface",
        [
          test_case "affordance: keeper sees task_verify when pending>0"
            `Quick (fun () ->
              let meta =
                { minimal_meta with mention_targets = [ "analyst" ] }
              in
              let obs =
                { base_observation with pending_verification_count = 3 }
              in
              let affordances =
                UM.observed_affordances_of_observation ~meta obs
              in
              check bool "task_verify present for keeper" true
                (List.mem "task_verify" affordances));
          test_case "affordance: verifier-tagged keeper also sees task_verify"
            `Quick
            (fun () ->
              let meta =
                { minimal_meta with mention_targets = [ "verifier" ] }
              in
              let obs =
                { base_observation with pending_verification_count = 3 }
              in
              let affordances =
                UM.observed_affordances_of_observation ~meta obs
              in
              check bool "task_verify present for verifier-tagged keeper" true
                (List.mem "task_verify" affordances));
          test_case "affordance: no meta keeps legacy surface-to-all" `Quick
            (fun () ->
              let obs =
                { base_observation with pending_verification_count = 2 }
              in
              let affordances =
                UM.observed_affordances_of_observation obs
              in
              check bool "task_verify present without meta" true
                (List.mem "task_verify" affordances));
          test_case "affordance: work discovery requires action" `Quick
            (fun () ->
              let obs = { base_observation with work_discovery_due = true } in
              let affordances =
                UM.observed_affordances_of_observation obs
              in
              check bool "work_discovery present" true
                (List.mem "work_discovery" affordances));
          test_case "affordance: board curation requires multi-event window"
            `Quick
            (fun () ->
              let second_board_event =
                {
                  sample_board_event with
                  post_id = "board-post-2";
                  title = "Follow-up";
                  preview = "Another board item needs routing.";
                }
              in
              let obs =
                {
                  base_observation with
                  pending_board_events =
                    [ sample_board_event; second_board_event ];
                }
              in
              let affordances =
                UM.observed_affordances_of_observation obs
              in
              check bool "board_curation present" true
                (List.mem "board_curation" affordances));
          test_case "affordance: single board event skips curation gate" `Quick
            (fun () ->
              let obs =
                {
                  base_observation with
                  pending_board_events = [ sample_board_event ];
                }
              in
              let affordances =
                UM.observed_affordances_of_observation obs
              in
              check bool "board_curation absent" false
                (List.mem "board_curation" affordances));
          test_case "affordance: task claim requires matched backlog" `Quick
            (fun () ->
              let obs =
                {
                  base_observation with
                  unclaimed_task_count = 3;
                  claimable_task_count = 0;
                }
              in
              let affordances =
                UM.observed_affordances_of_observation obs
              in
              check bool "task_claim absent for unclaimable backlog" false
                (List.mem "task_claim" affordances));
          test_case "affordance: task claim present for claimable backlog" `Quick
            (fun () ->
              let obs =
                {
                  base_observation with
                  unclaimed_task_count = 3;
                  claimable_task_count = 1;
                }
              in
              let affordances =
                UM.observed_affordances_of_observation obs
              in
              check bool "task_claim present for matched backlog" true
                (List.mem "task_claim" affordances));
          test_case "trigger: absolute and matched backlog split" `Quick
            (fun () ->
              let obs =
                {
                  base_observation with
                  unclaimed_task_count = 3;
                  claimable_task_count = 1;
                }
              in
              let triggers = UM.observed_triggers_of_observation obs in
              check bool "absolute backlog trigger remains visible" true
                (List.mem "new_unclaimed_task" triggers);
              check bool "matched backlog trigger is explicit" true
                (List.mem "claimable_task" triggers));
          test_case "trigger: keeper sees pending_verification"
            `Quick (fun () ->
              let meta =
                { minimal_meta with mention_targets = [ "scholar" ] }
              in
              let obs =
                { base_observation with pending_verification_count = 5 }
              in
              let triggers =
                UM.observed_triggers_of_observation ~meta obs
              in
              check bool "pending_verification present for keeper" true
                (List.mem "pending_verification" triggers));
          test_case "trigger: verifier-tagged keeper also sees pending_verification"
            `Quick
            (fun () ->
              let meta =
                { minimal_meta with mention_targets = [ "검증자" ] }
              in
              let obs =
                { base_observation with pending_verification_count = 1 }
              in
              let triggers =
                UM.observed_triggers_of_observation ~meta obs
              in
              check bool "pending_verification present for verifier-tagged keeper"
                true
                (List.mem "pending_verification" triggers));
        ] );
    ]
