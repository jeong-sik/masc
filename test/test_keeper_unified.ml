open Alcotest

module WO = Masc_mcp.Keeper_world_observation
module UP = Masc_mcp.Keeper_unified_prompt
module UT = Masc_mcp.Keeper_unified_turn
module KR = Masc_mcp.Keeper_registry
module KAR = Masc_mcp.Keeper_agent_run
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

let () =
  let base_path = repo_root () in
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
    failed_task_count = 0;
    pending_verification_count = 0;
    active_agent_count = 0;
    last_turn_budget = None;
    last_tools_used = [];
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
  match Masc_mcp.Keeper_types.meta_of_json json with
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
        WO.observe ~pending_board_events:(Some events)
          ~config ~meta:minimal_meta
      in
      check int "precollected board events preserved" (List.length events)
        (List.length obs.pending_board_events);
      check bool "board event schedules turn" true
        (WO.should_run_keeper_cycle ~meta:minimal_meta obs))

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
      check int "keeps non-mention events" 1 (List.length events);
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
    (WO.should_run_keeper_cycle ~meta obs)

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
    (WO.should_run_keeper_cycle ~meta base_observation)

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
  let decision = WO.keeper_cycle_decision ~meta obs in
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
  check (list string) "structured idle-gate skip tags"
    [ "idle_gate_pending" ]
    (WO.verdict_reasons_to_strings idle_gate_verdict);
  check (list string) "structured cooldown skip tags"
    [ "cooldown_pending" ]
    (WO.verdict_reasons_to_strings cooldown_verdict)

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
    let decision = WO.keeper_cycle_decision ~meta obs in
    check (option int) "task reactive cooldown clamps to positive floor" (Some 300)
      decision.task_reactive_cooldown)

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
    (contains_substring sys "Heartbeat is server-managed")

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
  check bool "gh pr create path documented" true
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
  check bool "mentions git path via keeper_bash" true
    (contains_substring sys
       "keeper_bash (run commands, including git add/commit/push inside worktrees)");
  check bool "mentions gh create path" true
    (contains_substring sys
       "keeper_shell op=gh (PR/issues via gh CLI; after git push");
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

let test_prompt_room_state_section () =
  let obs =
    { base_observation with
      unclaimed_task_count = 3;
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
  check bool "obsolete claim alias removed" false
    (source_file_contains "lib/keeper/keeper_agent_run.ml" "keeper_claim_task");
  check bool "claim tool uses registered no-arg schema" true
    (source_file_contains "lib/keeper/keeper_agent_run.ml" "`keeper_task_claim` {}");
  check bool "bash tool uses cmd field" true
    (source_file_contains "lib/keeper/keeper_agent_run.ml" "`keeper_bash` { cmd:");
  check bool "worktree tool uses task_id schema" true
    (source_file_contains "lib/keeper/keeper_agent_run.ml"
       "`masc_worktree_create` { task_id:");
  check bool "legacy worktree branch_name schema removed" false
    (source_file_contains "lib/keeper/keeper_agent_run.ml" "branch_name:");
  check bool "tool-less runtime escape hatch removed from nudge" false
    (source_file_contains "lib/keeper/keeper_agent_run.ml" "NO_TOOL_CHANNEL");
  check bool "work discovery nudge warns gh needs claimed task" true
    (source_file_contains "lib/keeper/keeper_agent_run.ml"
       "keeper_shell op=gh` derives repo context from the active task worktree/current_task_id");
  check bool "keeper_shell schema documents gh claim prerequisite" true
    (source_file_contains "lib/tool_shard.ml"
       "Requires an active claimed task/current_task_id");
  check bool "keeper_shell gh runtime allows sandbox fallback" true
    (source_file_contains "lib/keeper/keeper_exec_shell.ml"
       "task_id = \"(sandbox)\"")

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
    (* max_turns is set in keeper_agent_run.ml (default: 50) *)))

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
    ?(actual_input_tokens = 0)
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
    visible_tool_count = 0;
    tool_gate_enabled = false;
    tool_surface_fallback_used = false;
    config_root = "";
    cascade_config_path = None;
    gemini_mcp_disabled = false;
    approval_mode_effective = None;
    approval_mode_derived = false;
  }
let make_run_result ~text ~tools ~model ~input_tok ~output_tok
    ?(tool_calls = [])
    ?trace_ref
    ?run_validation
    ?cascade_observation
    () : Masc_mcp.Keeper_agent_run.run_result =
  {
    response_text = text;
    model_used = model;
    prompt_metrics = sample_prompt_metrics ();
    ctx_composition = sample_ctx_composition ~actual_input_tokens:input_tok ();
    cascade_observation;
    turn_count = 1;
    tool_calls_made = List.length tools;
    usage = { input_tokens = input_tok; output_tokens = output_tok; cache_creation_input_tokens = 0; cache_read_input_tokens = 0; cost_usd = None };
    tools_used = tools;
    tool_calls;
    checkpoint = None;
    proof = None;
    trace_ref;
    run_validation;
    stop_reason = Masc_mcp.Oas_worker.Completed;
    inference_telemetry = None;
    tool_surface = sample_tool_surface_metrics ();
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
    UT.update_metrics_from_result minimal_meta ~latency_ms:200
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

let test_metrics_surface_model_prefers_successful_cascade_label () =
  let selected_label = "llama:qwen3.5-3b-a3b-ud-q8-xl" in
  let result =
    make_run_result ~text:"I checked the board." ~tools:[]
      ~model:"qwen3.5:27b-nvfp4" ~input_tok:100 ~output_tok:50
      ~cascade_observation:
        {
          Masc_mcp.Oas_worker.cascade_name = Masc_mcp.Keeper_config.default_cascade_name;
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
    UT.update_metrics_from_result minimal_meta ~latency_ms:200
      ~observation:base_observation result
  in
  check string "helper canonicalizes surface model" selected_label
    (KAR.surface_model_used result);
  check string "last_model_used stores canonical surface label" selected_label
    updated.runtime.usage.last_model_used

let test_metrics_tool_response () =
  let result =
    make_run_result ~text:"" ~tools:["keeper_board_post"; "keeper_board_comment"]
      ~model:"test-model" ~input_tok:200 ~output_tok:80 ()
  in
  let updated =
    UT.update_metrics_from_result minimal_meta ~latency_ms:500
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
    UT.update_metrics_from_result minimal_meta ~latency_ms:100
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
    UT.update_metrics_from_result minimal_meta ~latency_ms:100
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
    UT.update_metrics_from_result minimal_meta ~latency_ms:100
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
    UT.update_metrics_from_result minimal_meta ~latency_ms:100
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
    UT.update_metrics_from_result minimal_meta ~latency_ms:80
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
    UT.update_metrics_from_result minimal_meta ~latency_ms:120
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
    UT.update_metrics_from_result
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
    UT.update_metrics_from_failure minimal_meta ~latency_ms:90
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
  match Masc_mcp.Keeper_types.meta_of_json legacy_json with
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
                Masc_mcp.Oas_worker.cascade_name = Masc_mcp.Keeper_config.default_cascade_name;
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
      UT.append_metrics_snapshot
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
            decision = "no_compaction";
            before_tokens = 0;
            after_tokens = 0;
            saved_tokens = 0;
          }
        ~handoff_json:None
        ~deliberation_execution
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
      UT.append_metrics_snapshot
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
            decision = "no_compaction";
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
      check string "work kind persisted as tool_use" "tool_use"
        Yojson.Safe.Util.(json |> member "work_kind" |> to_string);
      check string "scheduled autonomous outcome persisted as tool_use"
        "tool_use"
        Yojson.Safe.Util.(
          json |> member "scheduled_autonomous_outcome" |> to_string))

let test_append_decision_record_persists_tool_calls () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "observer"));
      let tool_calls : KAR.tool_call_detail list =
        [ { tool_name = "keeper_shell"
          ; provider = "codex_cli"
          ; outcome = "ok"
          ; latency_ms = 12.5
          }
        ; { tool_name = "keeper_board_post"
          ; provider = "codex_cli"
          ; outcome = "error"
          ; latency_ms = 3.0
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
      UT.append_decision_record
        ~config
        ~meta:minimal_meta
        ~observation:base_observation
        ~latency_ms:42
        ~outcome:"tool_use"
        ~selected_mode:"tool_use"
        ~result:(Some result)
        ();
      let json =
        read_jsonl_line (Keeper_types.keeper_decision_log_path config minimal_meta.name)
      in
      check int "tool call count persisted" 2
        Yojson.Safe.Util.(json |> member "tool_call_count" |> to_int);
      check (list string) "tools used persisted"
        ["keeper_shell"; "keeper_board_post"]
        Yojson.Safe.Util.(json |> member "tools_used" |> to_list |> List.map to_string);
      let recorded_tool_calls =
        Yojson.Safe.Util.(json |> member "tool_calls" |> to_list)
      in
      check int "tool call details persisted" 2 (List.length recorded_tool_calls);
      check string "first tool name" "keeper_shell"
        Yojson.Safe.Util.(List.nth recorded_tool_calls 0 |> member "tool_name" |> to_string);
      check string "first provider" "codex_cli"
        Yojson.Safe.Util.(List.nth recorded_tool_calls 0 |> member "provider" |> to_string);
      check string "second outcome" "error"
        Yojson.Safe.Util.(List.nth recorded_tool_calls 1 |> member "outcome" |> to_string);
      check (float 0.001) "second latency" 3.0
        Yojson.Safe.Util.(List.nth recorded_tool_calls 1 |> member "latency_ms" |> to_float))

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
          check string "keeper name preserved" meta.name updated.name;
          check (option string) "phase remains paused after skipped turn"
            (Some "paused")
            (Option.map KP.phase_to_string
               (KR.get_phase ~base_path:base_dir meta.name)))

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
    (source_file_contains "lib/keeper/keeper_unified_turn.ml"
       "Trajectory.finalize trajectory_acc")

let test_run_keeper_cycle_surfaces_side_effect_failures_source_contract () =
  check bool "keeper cycle records side-effect issues in registry" true
    (source_file_contains "lib/keeper/keeper_unified_turn.ml"
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
  check bool "activity graph emit is not silently ignored" false
    (source_file_contains "lib/keeper/keeper_unified_turn.ml"
       "ignore (Activity_graph.emit config");
  check bool "discovery helper guards keeper setup" true
    (source_file_contains "lib/keeper/keeper_unified_turn.ml"
       "ensure_local_discovery_ready model_labels")

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

let test_fail_open_local_only_when_probe_fails () =
  let cascade =
    UT.fail_open_local_only_when_unavailable
      ~probe_ollama_base_url:(fun _ -> false)
      ~base_cascade:"keeper_unified"
      ~effective_cascade:"local_only"
      [ "ollama:qwen3.6:35b-a3b-mlx-bf16" ]
  in
  check string "falls back to base cascade" "keeper_unified" cascade

let test_fail_open_local_only_preserves_explicit_local_only_base () =
  let cascade =
    UT.fail_open_local_only_when_unavailable
      ~probe_ollama_base_url:(fun _ -> false)
      ~base_cascade:"local_only"
      ~effective_cascade:"local_only"
      [ "ollama:qwen3.6:35b-a3b-mlx-bf16" ]
  in
  check string "explicit local_only stays local_only" "local_only" cascade

let test_fail_open_local_only_preserves_healthy_local_only () =
  let cascade =
    UT.fail_open_local_only_when_unavailable
      ~probe_ollama_base_url:(fun _ -> true)
      ~base_cascade:"keeper_unified"
      ~effective_cascade:"local_only"
      [ "ollama:qwen3.6:35b-a3b-mlx-bf16" ]
  in
  check string "healthy ollama keeps local_only" "local_only" cascade

let wrapped_claude_limit_error () =
  Agent_sdk.Error.Api
    (NetworkError
       {
         message =
           "claude exited with code 1: {\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"api_error_status\":429,\"result\":\"You've hit your limit · resets Apr 24 at 4am (Asia/Seoul)\"}";
         kind = Llm_provider.Http_client.Unknown;
       })

let test_fail_open_cascade_after_auto_recoverable_error_falls_back_to_default () =
  let fallback =
    UT.fail_open_cascade_after_auto_recoverable_error
      ~base_cascade:"tool_use_strict"
      ~effective_cascade:"tool_use_strict"
      (wrapped_claude_limit_error ())
  in
  check (option string) "strict cascade broadens to default"
    (Some KC.default_cascade_name) fallback

let test_fail_open_cascade_after_auto_recoverable_error_returns_base_after_phase_override () =
  let fallback =
    UT.fail_open_cascade_after_auto_recoverable_error
      ~base_cascade:"tool_use_strict"
      ~effective_cascade:KC.local_recovery_cascade_name
      (wrapped_claude_limit_error ())
  in
  check (option string) "phase override returns to keeper base"
    (Some "tool_use_strict") fallback

let test_fail_open_cascade_after_auto_recoverable_error_preserves_explicit_local_only () =
  let fallback =
    UT.fail_open_cascade_after_auto_recoverable_error
      ~base_cascade:KC.local_only_cascade_name
      ~effective_cascade:KC.local_only_cascade_name
      (wrapped_claude_limit_error ())
  in
  check (option string) "explicit local_only stays authoritative" None
    fallback

let test_fail_open_cascade_after_auto_recoverable_error_skips_default_cascade () =
  let fallback =
    UT.fail_open_cascade_after_auto_recoverable_error
      ~base_cascade:KC.default_cascade_name
      ~effective_cascade:KC.default_cascade_name
      (wrapped_claude_limit_error ())
  in
  check (option string) "default cascade has no broader fallback" None
    fallback

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
    (UT.is_context_overflow
       (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = Some 32768 })));
  check bool "ContextOverflow without limit" true
    (UT.is_context_overflow
       (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = None })));
  check bool "NetworkError does not match" false
    (UT.is_context_overflow
       (Agent_sdk.Error.Api (NetworkError {
         message = "Connection_reset";
         kind = Llm_provider.Http_client.Unknown })));
  check bool "Internal does not match" false
    (UT.is_context_overflow
       (Agent_sdk.Error.Internal "some error"));
  check bool "TokenBudgetExceeded Input matches" true
    (UT.is_context_overflow
       (Agent_sdk.Error.Agent (TokenBudgetExceeded { kind = "Input"; used = 204917; limit = 200000 })));
  check bool "TokenBudgetExceeded Total does not match" false
    (UT.is_context_overflow
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
        UT.update_metrics_from_result minimal_meta ~latency_ms:100
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
    UT.update_metrics_from_failure minimal_meta ~latency_ms:250
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
        tool_call_id = None; metadata = [];
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
        tool_call_id = None; metadata = [];
      }
  in
  let sanitized =
    Masc_mcp.Inference_utils.sanitize_messages_utf8 [ user_msg; tool_msg ]
  in
  match sanitized with
  | [ user_msg; tool_msg ] ->
      check string "user history content sanitized" "hist ory entry"
        (Agent_sdk.Types.text_of_message user_msg);
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
  | _ -> fail "expected two sanitized messages"

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
    (UT.is_context_overflow
       (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = Some 8192 })));
  check (option int) "parses limit via OAS SSOT" (Some 8192)
    (Agent_sdk.Retry.extract_context_limit
       "HTTP 400: prompt exceeds available context size (8192 tokens)");
  check (option int) "no limit in unrelated error" None
    (Agent_sdk.Retry.extract_context_limit "Network error: connection reset");
  check bool "NetworkError not overflow" false
    (UT.is_context_overflow
       (Agent_sdk.Error.Api (NetworkError {
         message = "timeout";
         kind = Llm_provider.Http_client.Unknown })))

let test_side_effect_timeout_reclassified_as_persistent () =
  let original =
    Agent_sdk.Error.Api
      (Timeout { message = "Execution cancelled after 300.0s" })
  in
  let reclassified =
    UT.reclassify_error_after_side_effect
      ~tool_names:["keeper_fs_edit"] original
  in
  check bool "marked ambiguous partial" true
    (UT.is_ambiguous_side_effect_error reclassified);
  check bool "no longer transient" false
    (UT.is_transient_network_error reclassified);
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
    UT.reclassify_error_after_side_effect
      ~tool_names:[] original
  in
  check bool "no committed tool keeps transient" true
    (UT.is_transient_network_error reclassified);
  check bool "not marked ambiguous partial" false
    (UT.is_ambiguous_side_effect_error reclassified)

let test_side_effect_reclassification_ignores_read_only_tools () =
  let original =
    Agent_sdk.Error.Api
      (Timeout { message = "Execution cancelled after 300.0s" })
  in
  let reclassified =
    UT.reclassify_error_after_side_effect
      ~tool_names:["keeper_board_list"; "keeper_fs_read"] original
  in
  check bool "read-only timeout stays transient" true
    (UT.is_transient_network_error reclassified);
  check bool "read-only timeout not ambiguous partial" false
    (UT.is_ambiguous_side_effect_error reclassified)

let test_side_effect_reclassification_marks_any_post_commit_error () =
  let original =
    Agent_sdk.Error.Api
      (AuthError { message = "Unauthorized" })
  in
  let reclassified =
    UT.reclassify_error_after_side_effect
      ~tool_names:["keeper_fs_edit"] original
  in
  check bool "auth error stays non-transient" false
    (UT.is_transient_network_error reclassified);
  check bool "auth error becomes ambiguous partial" true
    (UT.is_ambiguous_side_effect_error reclassified)

let test_post_commit_failure_kind_marks_timeouts () =
  let timeout_error =
    Agent_sdk.Error.Api
      (Timeout { message = "Execution cancelled after 300.0s" })
  in
  check string "timeout kind" "post_commit_timeout"
    (KR.ambiguous_partial_commit_kind_to_string
       (UT.post_commit_failure_kind_of_error timeout_error))

let test_post_commit_failure_kind_marks_non_timeouts_as_failures () =
  let auth_error =
    Agent_sdk.Error.Api
      (AuthError { message = "Unauthorized" })
  in
  check string "failure kind" "post_commit_failure"
    (KR.ambiguous_partial_commit_kind_to_string
       (UT.post_commit_failure_kind_of_error auth_error))

let test_server_rejected_parse_error_ollama_closing_brace () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = {|Value looks like object, but can't find closing '}' symbol|} })
  in
  check bool "ollama closing brace is parse error" true
    (UT.is_server_rejected_parse_error err);
  check bool "ollama closing brace is NOT transient network" false
    (UT.is_transient_network_error err)

let test_server_rejected_parse_error_unterminated () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = "Unterminated string in JSON" })
  in
  check bool "unterminated is parse error" true
    (UT.is_server_rejected_parse_error err)

let test_server_rejected_parse_error_unexpected_char () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = "Unexpected character in JSON at position 42" })
  in
  check bool "unexpected character in json is parse error" true
    (UT.is_server_rejected_parse_error err)

let test_server_rejected_parse_error_parse_error () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = "Parse error at position 1024" })
  in
  check bool "parse error is parse error" true
    (UT.is_server_rejected_parse_error err)

let test_server_rejected_parse_error_case_insensitive () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = "PARSE ERROR in request body" })
  in
  check bool "uppercase PARSE ERROR detected" true
    (UT.is_server_rejected_parse_error err)

let test_server_rejected_parse_error_generic_invalid_request () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = "bad tool schema" })
  in
  check bool "generic InvalidRequest is NOT parse error" false
    (UT.is_server_rejected_parse_error err)

let test_server_rejected_parse_error_generic_closing () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = "Service closing for maintenance" })
  in
  check bool "generic 'closing' is NOT parse error" false
    (UT.is_server_rejected_parse_error err)

let test_server_rejected_parse_error_generic_cant_find () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = "Can't find the specified tool 'my_tool'" })
  in
  check bool "generic 'can't find' is NOT parse error" false
    (UT.is_server_rejected_parse_error err)

let test_server_rejected_parse_error_network_error () =
  let err =
    Agent_sdk.Error.Api
      (NetworkError { message = "connection refused";
                      kind = Llm_provider.Http_client.Unknown })
  in
  check bool "network error is NOT parse error" false
    (UT.is_server_rejected_parse_error err)

let test_auto_recoverable_turn_error_includes_transient_network () =
  let err =
    Agent_sdk.Error.Api
      (Timeout { message = "Execution cancelled after 300.0s" })
  in
  check bool "timeout is auto-recoverable" true
    (UT.is_auto_recoverable_turn_error err)

let test_auto_recoverable_turn_error_includes_server_parse_rejection () =
  let err =
    Agent_sdk.Error.Api
      (InvalidRequest { message = "Parse error at position 42" })
  in
  check bool "server parse rejection is auto-recoverable" true
    (UT.is_auto_recoverable_turn_error err)

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
    (UT.is_auto_recoverable_turn_error err)

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
    (UT.is_required_tool_contract_violation err)

let test_required_tool_contract_violation_ignores_legacy_internal_error () =
  let err =
    Agent_sdk.Error.Internal
      "Completion contract [require_tool_use] violated: required tool contract unsatisfied: tool_choice requested tool use, but the model returned no ToolUse block"
  in
  check bool "legacy internal contract violation ignored" false
    (UT.is_required_tool_contract_violation err)

let test_cascade_exhausted_error_detected_from_structured_internal_error () =
  let err =
    Masc_mcp.Oas_worker_named.sdk_error_of_masc_internal_error
      (Masc_mcp.Oas_worker_named.Cascade_exhausted
         {
           cascade_name = Masc_mcp.Keeper_config.default_cascade_name;
           reason = Keeper_types.All_providers_failed;
         })
  in
  check bool "structured cascade exhausted error detected" true
    (UT.is_cascade_exhausted_error err)

let test_cascade_exhausted_error_ignores_legacy_internal_error () =
  let err =
    Agent_sdk.Error.Internal
      "cascade keeper_unified: all models failed: no providers available"
  in
  check bool "legacy internal cascade exhaustion ignored" false
    (UT.is_cascade_exhausted_error err)

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
    (UT.is_auto_recoverable_turn_error err)

let test_auto_recoverable_turn_error_excludes_persistent_errors () =
  let err =
    Agent_sdk.Error.Api
      (AuthError { message = "Unauthorized" })
  in
  check bool "auth error is persistent" false
    (UT.is_auto_recoverable_turn_error err)

let test_auto_recoverable_turn_error_includes_wrapped_cascade_exhausted_hard_quota () =
  let err =
    Masc_mcp.Oas_worker_named.sdk_error_of_masc_internal_error
      (Masc_mcp.Oas_worker_named.Cascade_exhausted
         {
           cascade_name = Masc_mcp.Keeper_config.default_cascade_name;
           reason =
             Keeper_types.Other_detail
               "claude exited with code 1: {\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"api_error_status\":429,\"result\":\"You've hit your limit · resets Apr 24 at 4am (Asia/Seoul)\"}";
         })
  in
  check bool "wrapped cascade hard quota is auto-recoverable" true
    (UT.is_auto_recoverable_turn_error err)

let test_auto_recoverable_turn_error_includes_filtered_candidates_cascade_exhaustion () =
  let err =
    Masc_mcp.Oas_worker_named.sdk_error_of_masc_internal_error
      (Masc_mcp.Oas_worker_named.Cascade_exhausted
         {
           cascade_name = Masc_mcp.Keeper_config.default_cascade_name;
           reason = Keeper_types.Candidates_filtered_after_cycles;
         })
  in
  check bool "filtered candidates cascade exhaustion is auto-recoverable" true
    (UT.is_auto_recoverable_turn_error err)

let test_bounded_oas_timeout_uses_adaptive_when_budget_is_large () =
  let expected =
    Env_config.KeeperKeepalive.oas_timeout_for_context ~max_context:262_144
  in
  match
    UT.bounded_oas_timeout_for_turn_budget
      ~max_context:262_144 ~remaining_turn_budget_s:1200.0
  with
  | Some timeout_s ->
      check (float 0.01) "adaptive timeout kept under full budget"
        expected timeout_s
  | None -> fail "expected bounded timeout"

let test_bounded_oas_timeout_caps_to_remaining_turn_budget () =
  match
    UT.bounded_oas_timeout_for_turn_budget
      ~max_context:262_144 ~remaining_turn_budget_s:235.7
  with
  | Some timeout_s ->
      check (float 0.01) "remaining budget cap applies" 234.7 timeout_s
  | None -> fail "expected bounded timeout"

let test_bounded_oas_timeout_uses_channel_turn_budget_override () =
  let max_turns =
    Env_config.KeeperKeepalive.oas_max_turns_per_call_scheduled_autonomous
  in
  let expected =
    Env_config.KeeperKeepalive.oas_timeout_for_context_with_turn_budget
      ~max_context:262_144 ~max_turns
  in
  match
    UT.bounded_oas_timeout_for_turn_budget_with_turn_budget
      ~max_turns ~max_context:262_144 ~remaining_turn_budget_s:1200.0
  with
  | Some timeout_s ->
      check (float 0.01) "scheduled autonomous turn budget lowers adaptive timeout"
        expected timeout_s
  | None -> fail "expected bounded timeout"

let test_bounded_oas_timeout_refuses_too_little_budget () =
  check (option (float 0.01)) "insufficient budget returns none" None
    (UT.bounded_oas_timeout_for_turn_budget
       ~max_context:262_144 ~remaining_turn_budget_s:20.0)

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

let test_side_effect_reclassification_ignores_keeper_read_only_tools () =
  let original =
    Agent_sdk.Error.Api
      (Timeout { message = "Execution cancelled after 300.0s" })
  in
  let reclassified =
    UT.reclassify_error_after_side_effect
      ~tool_names:["keeper_tasks_list"; "keeper_memory_search"] original
  in
  check bool "read-only keeper tools stay transient" true
    (UT.is_transient_network_error reclassified);
  check bool "read-only keeper tools are not ambiguous" false
    (UT.is_ambiguous_side_effect_error reclassified)

let test_side_effect_reclassification_drops_keeper_read_only_tools_from_mixed_set () =
  let original =
    Agent_sdk.Error.Api
      (Timeout { message = "Execution cancelled after 300.0s" })
  in
  let reclassified =
    UT.reclassify_error_after_side_effect
      ~tool_names:["keeper_tasks_list"; "keeper_fs_edit"; "keeper_memory_search"]
      original
  in
  let rendered = Agent_sdk.Error.to_string reclassified in
  check bool "mixed set is ambiguous" true
    (UT.is_ambiguous_side_effect_error reclassified);
  check bool "keeps mutating tool" true
    (contains_substring rendered "keeper_fs_edit");
  check bool "drops tasks_list from ambiguous set" false
    (contains_substring rendered "keeper_tasks_list");
  check bool "drops memory_search from ambiguous set" false
    (contains_substring rendered "keeper_memory_search")

let test_metrics_mixed_response () =
  let result =
    make_run_result ~text:"Done." ~tools:["keeper_fs_read"]
      ~model:"test-model" ~input_tok:150 ~output_tok:60 ()
  in
  let updated =
    UT.update_metrics_from_result minimal_meta ~latency_ms:300
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
  let observation = { base_observation with unclaimed_task_count = 12 } in
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
          test_case "keeps non-mention board events as follow-up signal" `Quick
            test_collect_board_events_keeps_non_mentions_as_followup_signal;
          test_case "keeps external replies after self comment" `Quick
            test_collect_board_events_keeps_external_replies_after_self_comment;
          test_case "scheduled turn uses cooldown only when work exists" `Quick
            test_scheduled_turn_uses_cooldown_only;
          test_case "scheduled turn skips without structured work signal" `Quick
            test_scheduled_turn_skips_without_structured_work_signal;
          test_case "scheduled turn respects cooldown" `Quick
            test_scheduled_turn_respects_cooldown;
          test_case "scheduled turn requires idle gate" `Quick
            test_scheduled_turn_requires_idle_gate;
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
          test_case "includes mentions" `Quick test_prompt_includes_mentions_section;
          test_case "includes board activity" `Quick
            test_prompt_includes_board_activity_section;
          test_case "includes goals" `Quick test_prompt_includes_goals_section;
          test_case "includes context ratio" `Quick test_prompt_includes_context_ratio;
          test_case "includes idle" `Quick test_prompt_includes_idle;
          test_case "frugal economy" `Quick test_prompt_frugal_economy;
          test_case "hustle economy" `Quick test_prompt_hustle_economy;
          test_case "includes worktree delta" `Quick test_prompt_includes_worktree_delta;
          test_case "room state section" `Quick test_prompt_room_state_section;
          test_case "claim first guidance" `Quick
            test_prompt_includes_claim_first_guidance;
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
          test_case "surface model prefers successful cascade label" `Quick
            test_metrics_surface_model_prefers_successful_cascade_label;
          test_case "tool response" `Quick test_metrics_tool_response;
          test_case "noop response" `Quick test_metrics_noop_response;
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
          test_case "decision record persists tool call details" `Quick
            test_append_decision_record_persists_tool_calls;
          test_case "social fields" `Quick
            test_metrics_persist_social_state_fields;
          test_case "failure response" `Quick test_metrics_failure_response;
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
          test_case "tool usage delta uses registry counts" `Quick
            test_tool_usage_delta_uses_registry_counts;
          test_case "tool usage delta ignores removed tools" `Quick
            test_tool_usage_delta_ignores_removed_tools;
          test_case "merge observed and synthetic tool names" `Quick
            test_merge_reported_and_observed_tool_names_preserves_synthetic_tools;
          test_case "final keeper tool names fall back to reported tools"
            `Quick
            test_final_keeper_tool_names_falls_back_to_reported_tool_use;
          test_case "tool query strips continuity noise" `Quick
            test_tool_query_text_of_user_message_strips_continuity_noise;
          test_case "tool query keeps counted headers" `Quick
            test_tool_query_text_of_user_message_keeps_counted_headers;
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
          test_case "magentic ledger silences tool-only turn" `Quick
            test_social_model_magentic_ledger_silences_tool_only_turn;
          test_case "magentic ledger hides non-visible tool text" `Quick
            test_social_model_magentic_ledger_hides_nonvisible_tool_text;
          test_case "magentic ledger restores previous state model" `Quick
            test_social_model_magentic_ledger_previous_state_of_meta_restores_model;
          test_case "social model previous state falls back for unknown model" `Quick
            test_social_model_previous_state_of_meta_falls_back_for_unknown_model;
          test_case "bdi failure rewrites stale claim retry loop" `Quick
            test_social_model_bdi_failure_state_rewrites_claim_retry_loop;
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
              (UT.is_transient_network_error
                 (Agent_sdk.Error.Api (NetworkError {
                   message = "Connection_reset";
                   kind = Llm_provider.Http_client.Unknown }))));
          test_case "Timeout detected" `Quick (fun () ->
            check bool "timeout" true
              (UT.is_transient_network_error
                 (Agent_sdk.Error.Api (Timeout { message = "connection timed out" }))));
          test_case "Overloaded detected" `Quick (fun () ->
            check bool "overloaded" true
              (UT.is_transient_network_error
                 (Agent_sdk.Error.Api (Overloaded { message = "server busy" }))));
          test_case "ServerError 503 detected" `Quick (fun () ->
            check bool "503" true
              (UT.is_transient_network_error
                 (Agent_sdk.Error.Api (ServerError { status = 503; message = "Service Unavailable" }))));
          test_case "ServerError 500 not transient" `Quick (fun () ->
            check bool "500" false
              (UT.is_transient_network_error
                 (Agent_sdk.Error.Api (ServerError { status = 500; message = "Internal" }))));
          test_case "AuthError not transient" `Quick (fun () ->
            check bool "auth" false
              (UT.is_transient_network_error
                 (Agent_sdk.Error.Api (AuthError { message = "Unauthorized" }))));
          test_case "RateLimited not transient" `Quick (fun () ->
            check bool "rate limit" false
              (UT.is_transient_network_error
                 (Agent_sdk.Error.Api (RateLimited { retry_after = None; message = "429" }))));
          test_case "ContextOverflow not transient" `Quick (fun () ->
            check bool "overflow" false
              (UT.is_transient_network_error
                 (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = None }))));
          test_case "Internal error not transient" `Quick (fun () ->
            check bool "internal" false
              (UT.is_transient_network_error
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
          test_case "required tool contract violation detected from structured error" `Quick
            test_required_tool_contract_violation_detected;
          test_case "legacy internal contract violation is ignored" `Quick
            test_required_tool_contract_violation_ignores_legacy_internal_error;
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
          test_case "auto-recoverable includes filtered candidates cascade exhaustion" `Quick
            test_auto_recoverable_turn_error_includes_filtered_candidates_cascade_exhaustion;
          test_case "bounded OAS timeout keeps adaptive timeout under full budget" `Quick
            test_bounded_oas_timeout_uses_adaptive_when_budget_is_large;
          test_case "bounded OAS timeout caps to remaining turn budget" `Quick
            test_bounded_oas_timeout_caps_to_remaining_turn_budget;
          test_case "bounded OAS timeout respects channel turn budget override" `Quick
            test_bounded_oas_timeout_uses_channel_turn_budget_override;
          test_case "bounded OAS timeout refuses too little remaining budget" `Quick
            test_bounded_oas_timeout_refuses_too_little_budget;
          test_case "pure local label detection" `Quick
            test_pure_local_labels_detection;
          test_case "pure local context clamp" `Quick
            test_clamp_context_for_pure_local_labels;
          test_case "turn context budget uses primary model" `Quick
            test_resolved_max_context_for_turn_uses_primary_budget;
          test_case "max_context resolution separates override and effective budget" `Quick
            test_max_context_resolution_separates_override_and_effective_budget;
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
          test_case "run_keeper_cycle records trajectory contract" `Quick
            test_run_keeper_cycle_records_trajectory_source_contract;
          test_case "run_keeper_cycle surfaces side-effect failures contract"
            `Quick
            test_run_keeper_cycle_surfaces_side_effect_failures_source_contract;
          test_case "paused-state sync surfaces write failure" `Quick
            test_sync_keeper_paused_state_surfaces_write_failure_without_mutating_registry;
          test_case "local discovery guard surfaces refresh failure" `Quick
            test_ensure_local_discovery_ready_surfaces_refresh_failure;
          test_case "local_only fail-open falls back when ollama is down" `Quick
            test_fail_open_local_only_when_probe_fails;
          test_case "explicit local_only does not fail-open" `Quick
            test_fail_open_local_only_preserves_explicit_local_only_base;
          test_case "healthy local_only stays selected" `Quick
            test_fail_open_local_only_preserves_healthy_local_only;
          test_case "strict quota fail-open broadens to default cascade" `Quick
            test_fail_open_cascade_after_auto_recoverable_error_falls_back_to_default;
          test_case "phase override fail-open returns to base cascade" `Quick
            test_fail_open_cascade_after_auto_recoverable_error_returns_base_after_phase_override;
          test_case "explicit local_only keeps fail-open disabled" `Quick
            test_fail_open_cascade_after_auto_recoverable_error_preserves_explicit_local_only;
          test_case "default cascade has no broader fail-open target" `Quick
            test_fail_open_cascade_after_auto_recoverable_error_skips_default_cascade;
        ] );
      ( "tool_classification",
        [
          test_case "keeper allowed tools exclude heartbeat" `Quick
            test_keeper_allowed_tools_exclude_heartbeat;
        ] );
      ( "verifier_role",
        [
          test_case "is_verifier_role_keeper detects english token" `Quick
            (fun () ->
              let meta =
                { minimal_meta with mention_targets = [ "verifier" ] }
              in
              check bool "verifier token matches" true
                (UT.is_verifier_role_keeper meta));
          test_case "is_verifier_role_keeper detects korean token" `Quick
            (fun () ->
              let meta =
                { minimal_meta with mention_targets = [ "검증자" ] }
              in
              check bool "korean token matches" true
                (UT.is_verifier_role_keeper meta));
          test_case "is_verifier_role_keeper rejects non-verifier persona"
            `Quick (fun () ->
              let meta =
                {
                  minimal_meta with
                  mention_targets = [ "analyst"; "scholar" ];
                }
              in
              check bool "non-verifier mention targets" false
                (UT.is_verifier_role_keeper meta));
          test_case "is_verifier_role_keeper empty mention targets" `Quick
            (fun () ->
              check bool "empty mention_targets" false
                (UT.is_verifier_role_keeper
                   { minimal_meta with mention_targets = [] }));
          test_case "affordance: verifier sees task_verify when pending>0"
            `Quick (fun () ->
              let meta =
                { minimal_meta with mention_targets = [ "verifier" ] }
              in
              let obs =
                { base_observation with pending_verification_count = 3 }
              in
              let affordances =
                UT.observed_affordances_of_observation ~meta obs
              in
              check bool "task_verify present for verifier" true
                (List.mem "task_verify" affordances));
          test_case "affordance: non-verifier gated off task_verify" `Quick
            (fun () ->
              let meta =
                { minimal_meta with mention_targets = [ "analyst" ] }
              in
              let obs =
                { base_observation with pending_verification_count = 3 }
              in
              let affordances =
                UT.observed_affordances_of_observation ~meta obs
              in
              check bool "task_verify absent for non-verifier" false
                (List.mem "task_verify" affordances));
          test_case "affordance: no meta keeps legacy surface-to-all" `Quick
            (fun () ->
              let obs =
                { base_observation with pending_verification_count = 2 }
              in
              let affordances =
                UT.observed_affordances_of_observation obs
              in
              check bool "task_verify present without meta" true
                (List.mem "task_verify" affordances));
          test_case "trigger: non-verifier gated off pending_verification"
            `Quick (fun () ->
              let meta =
                { minimal_meta with mention_targets = [ "scholar" ] }
              in
              let obs =
                { base_observation with pending_verification_count = 5 }
              in
              let triggers =
                UT.observed_triggers_of_observation ~meta obs
              in
              check bool "pending_verification absent for non-verifier" false
                (List.mem "pending_verification" triggers));
          test_case "trigger: verifier sees pending_verification" `Quick
            (fun () ->
              let meta =
                { minimal_meta with mention_targets = [ "검증자" ] }
              in
              let obs =
                { base_observation with pending_verification_count = 1 }
              in
              let triggers =
                UT.observed_triggers_of_observation ~meta obs
              in
              check bool "pending_verification present for verifier" true
                (List.mem "pending_verification" triggers));
        ] );
    ]
