open Alcotest

module WO = Masc_mcp.Keeper_world_observation
module UP = Masc_mcp.Keeper_unified_prompt
module UT = Masc_mcp.Keeper_unified_turn
module KAR = Masc_mcp.Keeper_agent_run
module KSM = Masc_mcp.Keeper_social_model
module AE = Masc_mcp.Agent_economy
module KC = Masc_mcp.Keeper_config
module HK = Masc_mcp.Keeper_hooks_oas

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
  let prompts_dir = Filename.concat (repo_root ()) "config/prompts" in
  Prompt_registry.set_markdown_dir prompts_dir;
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

let contains_substring haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    if i + needle_len > hay_len then false
    else if String.sub haystack i needle_len = needle then true
    else loop (i + 1)
  in
  needle_len = 0 || loop 0

(* ---------- World Observation type tests ---------- *)

let base_observation : WO.world_observation =
  {
    pending_mentions = [];
    pending_board_events = [];
    idle_seconds = 0;
    active_goals = [];
    continuity_summary = "";
    worktree_change_summary = None;
    context_ratio = 0.0;
    economic_pressure = AE.Normal;
    unclaimed_task_count = 0;
    failed_task_count = 0;
    active_agent_count = 0;
    last_turn_budget = None;
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

let minimal_meta : Masc_mcp.Keeper_types.keeper_meta =
  let json = `Assoc [
    ("name", `String "test-keeper");
    ("trace_id", `String "test-trace-001");
    ("goal", `String "test goal");
  ] in
  match Masc_mcp.Keeper_types.meta_of_json json with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)

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
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "observer"));
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
        (WO.should_run_unified_turn ~meta:minimal_meta obs))

let test_collect_board_events_keeps_non_mentions () =
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
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "observer"));
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
      check int "collects non-mention events" 1 (List.length events);
      check int "new count includes non-mention" 1 new_count;
      check int "mention count stays zero" 0 mention_count;
      match events with
      | [ event ] ->
          check bool "explicit mention false" false event.explicit_mention;
          check (list string) "matched targets empty" [] event.matched_targets
      | _ -> fail "expected exactly one board event")

let test_scheduled_turn_uses_cooldown_only () =
  let meta =
    { minimal_meta with
      proactive =
        { minimal_meta.proactive with
          enabled = true;
          cooldown_sec = 60;
        };
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
  check bool "cooldown opens scheduled turn without idle heuristic" true
    (WO.should_run_unified_turn ~meta obs)

let test_scheduled_turn_respects_cooldown () =
  let meta =
    { minimal_meta with
      proactive =
        { minimal_meta.proactive with
          enabled = true;
          cooldown_sec = 300;
        };
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
    (WO.should_run_unified_turn ~meta base_observation)

let test_effective_cooldown_no_decay_within_base () =
  (* Within the base cooldown period, no decay should apply. *)
  let result = WO.effective_proactive_cooldown ~base_cooldown:1800 ~since_last:900 in
  check int "no decay within base" 1800 result

let test_effective_cooldown_at_boundary () =
  (* Exactly at the base cooldown, no decay yet. *)
  let result = WO.effective_proactive_cooldown ~base_cooldown:1800 ~since_last:1800 in
  check int "no decay at boundary" 1800 result

let test_effective_cooldown_first_decay () =
  (* One full extra period: cooldown halved. *)
  let result = WO.effective_proactive_cooldown ~base_cooldown:1800 ~since_last:3600 in
  check int "first decay halves cooldown" 900 result

let test_effective_cooldown_second_decay () =
  (* Two extra periods: cooldown quartered. *)
  let result = WO.effective_proactive_cooldown ~base_cooldown:1800 ~since_last:5400 in
  check int "second decay quarters cooldown" 450 result

let test_effective_cooldown_floor () =
  (* Four+ extra periods: cooldown at floor (300s default). *)
  let result = WO.effective_proactive_cooldown ~base_cooldown:1800 ~since_last:10800 in
  check int "decay floors at min_cooldown" 300 result

let test_effective_cooldown_max_int () =
  (* max_int (first proactive ever): should hit floor immediately. *)
  let result = WO.effective_proactive_cooldown ~base_cooldown:1800 ~since_last:max_int in
  check int "max_int hits floor" 300 result

let test_idle_decay_triggers_turn () =
  (* After extended idle, decay should make cooldown_elapsed true
     even when since_last_proactive < base cooldown_sec. *)
  let meta =
    { minimal_meta with
      proactive =
        { minimal_meta.proactive with
          enabled = true;
          cooldown_sec = 1800;
        };
      runtime =
        { minimal_meta.runtime with
          proactive_rt =
            { minimal_meta.runtime.proactive_rt with
              last_ts = Time_compat.now () -. 4000.0;
            };
        };
    }
  in
  check bool "idle decay triggers turn before base cooldown" true
    (WO.should_run_unified_turn ~meta base_observation)

let test_prompt_contains_identity () =
  let sys, _user = UP.build_prompt ~meta:minimal_meta ~observation:base_observation in
  check bool "contains name" true (String.length sys > 0);
  check bool "contains keeper name" true
    (let has_name =
       try ignore (Str.search_forward (Str.regexp_string "test-keeper") sys 0); true
       with Not_found -> false
     in has_name)

let test_prompt_contains_goal () =
  let sys, _user = UP.build_prompt ~meta:minimal_meta ~observation:base_observation in
  check bool "contains goal" true
    (let has_goal =
       try ignore (Str.search_forward (Str.regexp_string "test goal") sys 0); true
       with Not_found -> false
     in has_goal)

let test_prompt_mentions_extend_turns_guidance () =
  let sys, _user = UP.build_prompt ~meta:minimal_meta ~observation:base_observation in
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

let test_prompt_omits_empty_sections () =
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:base_observation in
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

let test_prompt_includes_mentions_section () =
  let obs =
    { base_observation with
      pending_mentions = [("alice", "hello keeper")]
    }
  in
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
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
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
  check bool "has goals section" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "Active Goals") user 0); true
       with Not_found -> false
     in found)

let test_prompt_includes_context_ratio () =
  let obs = { base_observation with context_ratio = 0.75 } in
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
  check bool "has context percentage" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "75%") user 0); true
       with Not_found -> false
     in found)

let test_prompt_includes_idle () =
  let obs = { base_observation with idle_seconds = 300 } in
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
  check bool "has idle seconds" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "300s") user 0); true
       with Not_found -> false
     in found)

let test_prompt_frugal_economy () =
  let obs = { base_observation with economic_pressure = AE.Frugal } in
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
  check bool "has frugal warning" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "Frugal") user 0); true
       with Not_found -> false
     in found)

let test_prompt_hustle_economy () =
  let obs = { base_observation with economic_pressure = AE.Hustle } in
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
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
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
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
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
  check bool "has room state" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "Room State") user 0); true
       with Not_found -> false
     in found)

(* ---------- Config tests ---------- *)

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect ~finally:(fun () ->
    match old with
    | Some v -> Unix.putenv name v
    | None -> (try Unix.putenv name "" with _ -> ()))
    f

let test_unified_turn_runtime_defaults () =
  with_env "MASC_KEEPER_UNIFIED_TEMP" "" (fun () ->
  with_env "MASC_KEEPER_UNIFIED_MAX_TOKENS" "" (fun () ->
  with_env "MASC_KEEPER_UNIFIED_MAX_TURNS" "" (fun () ->
    check (float 0.01) "unified temp default" 0.4
      (KC.keeper_unified_temperature ());
    check int "unified max_tokens default" 2048
      (KC.keeper_unified_max_tokens ());
    check int "unified max_turns default" 20
      (KC.keeper_unified_max_turns ()))))

let test_meta_defaults_social_model () =
  check string "default social model" "bdi_speech_v1"
    minimal_meta.social_model

(* ---------- Metrics observation tests ---------- *)

let make_run_result ~text ~tools ~model ~input_tok ~output_tok
    : Masc_mcp.Keeper_agent_run.run_result =
  {
    response_text = text;
    model_used = model;
    turn_count = 1;
    tool_calls_made = List.length tools;
    usage = { input_tokens = input_tok; output_tokens = output_tok; cache_creation_input_tokens = 0; cache_read_input_tokens = 0; cost_usd = None };
    tools_used = tools;
    checkpoint = None;
    proof = None;
    stop_reason = Masc_mcp.Oas_worker.Completed;
  }

let test_metrics_text_response () =
  let result =
    make_run_result ~text:"I checked the board." ~tools:[]
      ~model:"test-model" ~input_tok:100 ~output_tok:50
  in
  let updated =
    UT.update_metrics_from_result minimal_meta ~latency_ms:200
      ~observation:base_observation result
  in
  check int "total_turns +1" (minimal_meta.runtime.usage.total_turns + 1) updated.runtime.usage.total_turns;
  check int "proactive_count +1"
    (minimal_meta.runtime.proactive_rt.count_total + 1) updated.runtime.proactive_rt.count_total;
  check int "no autonomous action" minimal_meta.runtime.autonomous_action_count
    updated.runtime.autonomous_action_count;
  check int "input tokens" (minimal_meta.runtime.usage.total_input_tokens + 100) updated.runtime.usage.total_input_tokens;
  check int "output tokens" (minimal_meta.runtime.usage.total_output_tokens + 50) updated.runtime.usage.total_output_tokens

let test_metrics_tool_response () =
  let result =
    make_run_result ~text:"" ~tools:["keeper_board_post"; "keeper_board_comment"]
      ~model:"test-model" ~input_tok:200 ~output_tok:80
  in
  let updated =
    UT.update_metrics_from_result minimal_meta ~latency_ms:500
      ~observation:base_observation result
  in
  check int "proactive_count +1" (minimal_meta.runtime.proactive_rt.count_total + 1)
    updated.runtime.proactive_rt.count_total;
  check int "autonomous_action +2" (minimal_meta.runtime.autonomous_action_count + 2)
    updated.runtime.autonomous_action_count;
  check int "latency_ms" 500 updated.runtime.usage.last_latency_ms

let test_metrics_noop_response () =
  let result =
    make_run_result ~text:"" ~tools:[]
      ~model:"test-model" ~input_tok:50 ~output_tok:10
  in
  let updated =
    UT.update_metrics_from_result minimal_meta ~latency_ms:100
      ~observation:base_observation result
  in
  check int "proactive_count unchanged" minimal_meta.runtime.proactive_rt.count_total
    updated.runtime.proactive_rt.count_total;
  check int "autonomous unchanged" minimal_meta.runtime.autonomous_action_count
    updated.runtime.autonomous_action_count;
  check int "total_turns +1" (minimal_meta.runtime.usage.total_turns + 1) updated.runtime.usage.total_turns

let test_metrics_persist_social_state_fields () =
  let result =
    make_run_result
      ~text:
        "SOCIAL_MODEL: bdi_speech_v1\nBELIEF_SUMMARY: quiet_room\nACTIVE_DESIRE: maintain_quiet_readiness\nCURRENT_INTENTION: stay_available_without_noise\nBLOCKER: none\nNEED: none\nSPEECH_ACT: stay_silent\nDELIVERY_SURFACE: silent"
      ~tools:[]
      ~model:"test-model" ~input_tok:50 ~output_tok:10
  in
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let routed, social_state =
        KSM.apply_to_result ~meta:minimal_meta
          ~observation:base_observation result
      in
      let updated =
        UT.update_metrics_from_result minimal_meta ~latency_ms:100
          ~observation:base_observation ~social_state routed
      in
      check string "speech act tracked" "stay_silent"
        updated.runtime.last_speech_act;
      check string "no blocker tracked" "" updated.runtime.last_blocker;
      check string "no need tracked" "" updated.runtime.last_need)

let test_metrics_failure_response () =
  let reason = "Agent run failed: Max turns exceeded (turn 10, limit 10)" in
  let updated =
    UT.update_metrics_from_failure minimal_meta ~latency_ms:250 ~reason ()
  in
  check int "total_turns +1" (minimal_meta.runtime.usage.total_turns + 1) updated.runtime.usage.total_turns;
  check int "latency recorded" 250 updated.runtime.usage.last_latency_ms;
  check bool "last_turn_ts updated" true (updated.runtime.usage.last_turn_ts > 0.0);
  check int "proactive count unchanged" minimal_meta.runtime.proactive_rt.count_total
    updated.runtime.proactive_rt.count_total;
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
     found)

let test_prompt_includes_board_activity_section () =
  let obs =
    { base_observation with
      pending_board_events = [ sample_board_event ]
    }
  in
  let _sys, user = UP.build_prompt ~meta:minimal_meta ~observation:obs in
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
  let sys, _user = UP.build_prompt ~meta:minimal_meta ~observation:base_observation in
  check bool "mentions speech act header" true
    (let found =
       try
         ignore (Str.search_forward (Str.regexp_string "SPEECH_ACT:") sys 0);
         true
       with Not_found -> false
     in
     found)

let test_metrics_mixed_response () =
  let result =
    make_run_result ~text:"Done." ~tools:["keeper_fs_read"]
      ~model:"test-model" ~input_tok:150 ~output_tok:60
  in
  let updated =
    UT.update_metrics_from_result minimal_meta ~latency_ms:300
      ~observation:base_observation result
  in
  check int "proactive +1" (minimal_meta.runtime.proactive_rt.count_total + 1)
    updated.runtime.proactive_rt.count_total;
  check int "autonomous +1" (minimal_meta.runtime.autonomous_action_count + 1)
    updated.runtime.autonomous_action_count;
  check bool "proactive reason has unified" true
    (let found =
       try ignore (Str.search_forward (Str.regexp_string "unified:tools=") updated.runtime.proactive_rt.last_reason 0); true
       with Not_found -> false
     in found)

let test_normalize_response_text_passthrough () =
  match KAR.normalize_response_text ~text:"All good." ~tool_names:[] () with
  | Ok text -> check string "keeps text" "All good." text
  | Error e -> fail ("unexpected error: " ^ e)

let test_normalize_response_text_tool_only_synthesizes () =
  match KAR.normalize_response_text
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
  match KAR.normalize_response_text ~text:"" ~tool_names:[] () with
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
    (KAR.tool_usage_delta ~before ~after)

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
    (KAR.tool_usage_delta ~before ~after)

let test_merge_reported_and_observed_tool_names_preserves_synthetic_tools () =
  let merged =
    KAR.merge_reported_and_observed_tool_names
      ~reported_tool_names:[ "keeper_board_post" ]
      ~observed_tool_names:[ "keeper_voice_agent"; "keeper_voice_agent" ]
  in
  check (list string) "observed dispatch plus synthetic tool"
    [ "keeper_voice_agent"; "keeper_voice_agent"; "keeper_board_post" ]
    merged

let test_social_model_silences_skip_only_turn () =
  let result =
    make_run_result
      ~text:
        "SOCIAL_MODEL: bdi_speech_v1\nBELIEF_SUMMARY: quiet_room\nACTIVE_DESIRE: maintain_quiet_readiness\nCURRENT_INTENTION: stay_available_without_noise\nBLOCKER: none\nNEED: none\nSPEECH_ACT: stay_silent\nDELIVERY_SURFACE: silent"
      ~tools:[]
      ~model:"test-model" ~input_tok:20 ~output_tok:5
  in
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let routed, state =
        KSM.apply_to_result ~meta:minimal_meta
          ~observation:base_observation result
      in
      check string "speech act" "stay_silent"
        (KSM.speech_act_to_string state.speech_act);
      check string "delivery surface" "silent"
        (KSM.delivery_surface_to_string state.delivery_surface);
      check string "visible response suppressed" "" routed.response_text;
      check (list string) "no synthetic tools" [] routed.tools_used)

let test_social_model_requires_explicit_headers () =
  let result =
    make_run_result ~text:"I think I should ask for help." ~tools:[]
      ~model:"test-model" ~input_tok:20 ~output_tok:5
  in
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let routed, state =
        KSM.apply_to_result ~meta:minimal_meta
          ~observation:base_observation result
      in
      check string "speech act" "defer"
        (KSM.speech_act_to_string state.speech_act);
      check string "delivery surface" "silent"
        (KSM.delivery_surface_to_string state.delivery_surface);
      check (option string) "blocker notes protocol violation"
        (Some "missing social headers") state.blocker;
      check string "visible response suppressed" "" routed.response_text;
      check (list string) "no synthetic tools" [] routed.tools_used)

let test_social_model_routes_blocker_to_board_post () =
  let result =
    make_run_result
      ~text:
        "SOCIAL_MODEL: bdi_speech_v1\nBELIEF_SUMMARY: quiet_room\nACTIVE_DESIRE: seek_help\nCURRENT_INTENTION: recover_tool_route\nBLOCKER: tool route unavailable\nNEED: tool route or operator guidance\nSPEECH_ACT: request_help\nDELIVERY_SURFACE: board_post"
      ~tools:[]
      ~model:"test-model" ~input_tok:30 ~output_tok:10
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
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "observer"));
      let routed, state =
        KSM.apply_to_result ~meta:minimal_meta
          ~observation:base_observation result
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

(* ---------- render_inline_skip_reason tests ---------- *)

let str_contains s sub =
  try ignore (Str.search_forward (Str.regexp_string sub) s 0); true
  with Not_found -> false

let test_render_inline_skip_reason_deny () =
  let result = HK.render_inline_skip_reason
    ~tool_name:"keeper_bash"
    ~reason_code:"keeper_deny"
    ~reason_text:"tool is on the keeper deny list"
  in
  check bool "prefix" true (String.starts_with ~prefix:"[tool_skipped]" result);
  check bool "tool" true (str_contains result "tool=keeper_bash");
  check bool "code" true (str_contains result "code=keeper_deny");
  check bool "reason encoded" true (str_contains result "reason=tool%20is%20on")

let test_render_inline_skip_reason_cost () =
  let result = HK.render_inline_skip_reason
    ~tool_name:"keeper_bash"
    ~reason_code:"cost_gate"
    ~reason_text:"accumulated_cost_usd=0.5100 exceeded limit=0.5000"
  in
  check bool "prefix" true (String.starts_with ~prefix:"[tool_skipped]" result);
  check bool "code" true (str_contains result "code=cost_gate");
  check bool "reason encoded equals" true (str_contains result "0.5100%20exceeded")

let test_render_inline_skip_reason_destructive () =
  let result = HK.render_inline_skip_reason
    ~tool_name:"keeper_bash"
    ~reason_code:"destructive_guard"
    ~reason_text:"pattern='rm -rf' (recursive forced deletion)"
  in
  check bool "prefix" true (String.starts_with ~prefix:"[tool_skipped]" result);
  check bool "code" true (str_contains result "code=destructive_guard");
  check bool "pattern encoded" true (str_contains result "pattern%3D")

let test_render_inline_escape_edge_cases () =
  (* Empty reason text *)
  let empty = HK.render_inline_skip_reason
    ~tool_name:"t" ~reason_code:"c" ~reason_text:"" in
  check bool "empty reason" true (str_contains empty "reason=");
  (* Percent sign in reason *)
  let pct = HK.render_inline_skip_reason
    ~tool_name:"t" ~reason_code:"c" ~reason_text:"CPU at 90%" in
  check bool "percent encoded" true (str_contains pct "90%25")

let test_render_inline_with_replacement () =
  (* keeper_board_post has replacement=masc_board_post in Tool_catalog *)
  let result = HK.render_inline_skip_reason
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
  match KAR.normalize_response_text
          ~text:override_text
          ~tool_names:["keeper_bash"]
          ()
  with
  | Ok text -> check string "passes through" override_text text
  | Error e -> fail ("unexpected error: " ^ e)

(* ---------- Test runner ---------- *)

let () =
  run "Keeper Unified Turn"
    [
      ( "world_observation",
        [
          test_case "defaults" `Quick test_observation_defaults;
          test_case "with mentions" `Quick test_observation_with_mentions;
          test_case "uses precollected board events" `Quick
            test_observe_uses_precollected_board_events;
          test_case "collects non-mention board events" `Quick
            test_collect_board_events_keeps_non_mentions;
          test_case "scheduled turn uses cooldown only" `Quick
            test_scheduled_turn_uses_cooldown_only;
          test_case "scheduled turn respects cooldown" `Quick
            test_scheduled_turn_respects_cooldown;
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
          test_case "idle decay: triggers turn" `Quick
            test_idle_decay_triggers_turn;
          test_case "with goals" `Quick test_observation_with_goals;
          test_case "economic modes" `Quick test_observation_economic_modes;
        ] );
      ( "unified_prompt",
        [
          test_case "contains identity" `Quick test_prompt_contains_identity;
          test_case "contains goal" `Quick test_prompt_contains_goal;
          test_case "mentions extend_turns guidance" `Quick
            test_prompt_mentions_extend_turns_guidance;
          test_case "omits empty sections" `Quick test_prompt_omits_empty_sections;
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
          test_case "prefers silence guidance" `Quick
            test_prompt_prefers_silence_guidance;
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
          test_case "text response" `Quick test_metrics_text_response;
          test_case "tool response" `Quick test_metrics_tool_response;
          test_case "noop response" `Quick test_metrics_noop_response;
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
          test_case "tool usage delta uses registry counts" `Quick
            test_tool_usage_delta_uses_registry_counts;
          test_case "tool usage delta ignores removed tools" `Quick
            test_tool_usage_delta_ignores_removed_tools;
          test_case "merge observed and synthetic tool names" `Quick
            test_merge_reported_and_observed_tool_names_preserves_synthetic_tools;
          test_case "social model silences skip-only turn" `Quick
            test_social_model_silences_skip_only_turn;
          test_case "social model requires explicit headers" `Quick
            test_social_model_requires_explicit_headers;
          test_case "social model routes blocker to board post" `Quick
            test_social_model_routes_blocker_to_board_post;
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
    ]
