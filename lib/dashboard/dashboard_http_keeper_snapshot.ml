(* Dashboard_http_keeper_snapshot — per-keeper snapshot and config rendering.
   Extracted from dashboard_http_keeper.ml during godfile decomposition.
   Contains: BDI snapshot, full config JSON rendering, and K2 feed delegations. *)

open Dashboard_http_keeper_types
open Keeper_status_bridge

let recent_keeper_metric_jsons (config : Coord.config) name =
  let metrics_store = Keeper_types_support.keeper_metrics_store config name in
  let lines =
    let dated = Dated_jsonl.read_recent_lines metrics_store 80 in
    if dated <> [] then dated
    else
      let metrics_path = Keeper_types_support.keeper_metrics_path config name in
      keeper_tail_lines_or_empty ~site:"dashboard_keeper_snapshot_metrics" metrics_path
        ~max_bytes:120000 ~max_lines:80
  in
  List.filter_map parse_json_line_opt lines

let recent_token_spend_json metrics =
  metrics
  |> List.filter_map (fun json ->
         let input_tokens = int_member_fallback "input_tokens" json in
         let output_tokens = int_member_fallback "output_tokens" json in
         let total_tokens =
           match int_member_fallback "total_tokens" json with
           | Some value -> Some value
           | None -> (
               match input_tokens, output_tokens with
               | Some input, Some output -> Some (input + output)
               | _ -> None)
         in
         match input_tokens, output_tokens, total_tokens with
         | None, None, None -> None
         | _ ->
             Some
               (`Assoc
                  [
                    ("ts_unix", `Float (metric_ts json));
                    ("ts", Json_util.string_opt_to_json (string_member_nonempty "ts" json));
                    ("channel", Json_util.string_opt_to_json (string_member_nonempty "channel" json));
                    ("model", `Null);
                    ("input_tokens", Json_util.int_opt_to_json input_tokens);
                    ("output_tokens", Json_util.int_opt_to_json output_tokens);
                    ("total_tokens", Json_util.int_opt_to_json total_tokens);
                  ]))
  |> sort_by_latest_ts
  |> take_list 5

let latest_tool_call_json name =
  Keeper_tool_call_log.read_recent ~keeper_name:name ~n:10 ()
  |> List.sort
       (fun left right ->
         Float.compare
           (Safe_ops.json_float ~default:0.0 "ts" right)
           (Safe_ops.json_float ~default:0.0 "ts" left))
  |> List.find_opt (fun json ->
         match string_member_nonempty "tool" json with
         | Some _ -> true
         | None -> false)
  |> Option.map (fun json ->
         `Assoc
           [
             ("ts_unix", Json_util.float_opt_to_json (Safe_ops.json_float_opt "ts" json));
             ("tool", Json_util.string_opt_to_json (string_member_nonempty "tool" json));
             ("success", Json_util.bool_opt_to_json (Safe_ops.json_bool_opt "success" json));
             ("semantic_outcome", Json_util.string_opt_to_json (string_member_nonempty "semantic_outcome" json));
             ("duration_ms", Json_util.float_opt_to_json (Safe_ops.json_float_opt "duration_ms" json));
           ])

let keeper_bdi_snapshot_json (config : Coord.config) (name : string)
    : [ `OK | `Not_found ] * Yojson.Safe.t =
  match Keeper_types.read_meta config name with
  | Error msg ->
      (`Not_found, `Assoc [ ("error", `String msg) ])
  | Ok None ->
      (`Not_found,
       `Assoc [ ("error", `String (Printf.sprintf "keeper %S not found" name)) ])
  | Ok (Some (m : Keeper_types.keeper_meta)) ->
      let metrics = recent_keeper_metric_jsons config name in
      let latest_social =
        sort_by_latest_ts metrics
        |> List.find_opt (fun json ->
               Option.is_some (string_member_nonempty "belief_summary" json)
               || Option.is_some (string_member_nonempty "active_desire" json)
               || Option.is_some (string_member_nonempty "current_intention" json)
               || Option.is_some (string_member_nonempty "need" json))
      in
      let metric_field key =
        Option.bind latest_social (string_member_nonempty key)
      in
      let belief =
        match metric_field "belief_summary" with
        | Some value -> Some value
        | None ->
            (match m.runtime.last_blocker with
             | Some info ->
                 let trimmed = String.trim info.detail in
                 let label =
                   if trimmed = "" then
                     Keeper_types.blocker_class_to_string info.klass
                   else trimmed
                 in
                 Some ("blocked: " ^ label)
             | None -> None)
      in
      let desire =
        match metric_field "active_desire" with
        | Some value -> Some value
        | None -> nonempty_string_opt m.runtime.last_active_desire
      in
      let intention =
        match metric_field "current_intention" with
        | Some value -> Some value
        | None -> nonempty_string_opt m.runtime.last_current_intention
      in
      let need =
        match metric_field "need" with
        | Some value -> Some value
        | None -> nonempty_string_opt m.runtime.last_need
      in
      (`OK,
       `Assoc
         [
           ("keeper", `String m.name);
           ("generated_at", `String (Masc_domain.now_iso ()));
           ("poll_interval_ms", `Int 5000);
           ("belief", Json_util.string_opt_to_json belief);
           ("desire", Json_util.string_opt_to_json desire);
           ("intention", Json_util.string_opt_to_json intention);
           ("need", Json_util.string_opt_to_json need);
           ("profile_will", Json_util.string_opt_to_json (nonempty_string_opt m.will));
           ("profile_needs", Json_util.string_opt_to_json (nonempty_string_opt m.needs));
           ("profile_desires", Json_util.string_opt_to_json (nonempty_string_opt m.desires));
           ("recent_token_spend", `List (recent_token_spend_json metrics));
           ("last_tool_call", Json_util.option_to_yojson Fun.id (latest_tool_call_json name));
           ("source", `String "keeper_meta+metrics_jsonl+tool_call_log");
         ])

(** Build a structured config JSON for a single keeper, grouped by category.
    Returns (http_status, json). *)
let keeper_config_json (config : Coord.config) (name : string)
    : [ `OK | `Not_found ] * Yojson.Safe.t =
  match Keeper_types.read_meta config name with
  | Error msg ->
      (`Not_found, `Assoc [ ("error", `String msg) ])
  | Ok None ->
      (`Not_found,
       `Assoc [ ("error", `String (Printf.sprintf "keeper %S not found" name)) ])
  | Ok (Some (m : Keeper_types.keeper_meta)) ->
      (* bootstrap_runtime is called at server startup — skip here to
         avoid blocking the HTTP handler with Eio.Mutex + file I/O (#3335). *)
      let defaults = Keeper_types_profile.load_keeper_profile_defaults m.name in
      let persona_extended =
        Keeper_types_profile.resolved_persona_name ~keeper_name:m.name defaults
        |> Keeper_types_profile.load_persona_extended
        |> Option.value ~default:""
      in
      let active_goals =
        List.filter_map
          (fun goal_id ->
             match Goal_store.get_goal config ~goal_id with
             | Some { Goal_store.id; title; horizon } ->
                 let horizon_str =
                   match horizon with
                   | Goal_store.Short -> "short"
                   | Goal_store.Mid -> "mid"
                   | Goal_store.Long -> "long"
                 in
                 Some (id, title, horizon_str)
               | None -> None)
          m.active_goal_ids
      in
      let active_goal_ids_json =
        `List (List.map (fun goal_id -> `String goal_id) m.active_goal_ids)
      in
      let active_goals_json =
        `List
          (List.map
             (fun (id, title, horizon) ->
                `Assoc [
                  ("id", `String id);
                  ("title", `String title);
                  ("horizon", `String horizon);
                ])
             active_goals)
      in
      let resolved_active_goal_ids =
        List.map (fun (id, _, _) -> id) active_goals
      in
      let missing_active_goal_ids =
        m.active_goal_ids
        |> List.filter (fun goal_id ->
               not (List.mem goal_id resolved_active_goal_ids))
      in
      let coordination =
        match coordination_surface_json m with
        | `Assoc fields ->
            `Assoc
              (fields
               @ [
                   ("active_goal_ids", active_goal_ids_json);
                   ("active_goals", active_goals_json);
                   ("active_goal_count", `Int (List.length m.active_goal_ids));
                   ( "missing_active_goal_ids",
                     `List
                       (List.map
                          (fun goal_id -> `String goal_id)
                          missing_active_goal_ids) );
                 ])
        | other -> other
      in
      let runtime_trust =
        Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta:m
      in
      let git_clone_allowed_orgs =
        Keeper_tool_policy.git_clone_allowed_orgs ()
      in
      let git_clone_denied_repos =
        Keeper_tool_policy.git_clone_denied_repos ()
      in
      let git_clone_policy_loaded =
        Option.is_some git_clone_allowed_orgs
        && Option.is_some git_clone_denied_repos
      in
      let effective_system_prompt =
        Keeper_prompt.build_keeper_system_prompt
          ~goal:m.goal ~short_goal:m.short_goal ~mid_goal:m.mid_goal
          ~long_goal:m.long_goal ~will:m.will
          ~needs:m.needs ~desires:m.desires ~instructions:m.instructions
          ~persona_extended ~keeper_name:m.name
          ~allowed_orgs:(Option.value git_clone_allowed_orgs ~default:[])
          ~denied_repos:(Option.value git_clone_denied_repos ~default:[])
          ~git_clone_policy_loaded
          ~active_goals
          ()
      in
      let prompt =
        `Assoc [
          ("goal", `String m.goal);
          ("short_goal", `String m.short_goal);
          ("mid_goal", `String m.mid_goal);
          ("long_goal", `String m.long_goal);
          ("will", `String m.will);
          ("needs", `String m.needs);
          ("desires", `String m.desires);
          ("instructions", `String m.instructions);
          ( "system_prompt_blocks",
            `Assoc
              [
                ("constitution", prompt_block_json Keeper_prompt_names.constitution);
                ("world", prompt_block_json Keeper_prompt_names.world);
                ("capabilities", prompt_block_json Keeper_prompt_names.capabilities);
              ] );
          ("effective_system_prompt", `String effective_system_prompt);
        ]
      in
      let cascade_name = Keeper_types.cascade_name_of_meta m in
      (* RFC-0149 §3.3 — Result-returning resolver: on [Error] the
         canonical field surfaces as JSON [null] (parse-don't-validate
         honest signal) instead of the silent [Keeper_turn] rewrite the
         legacy [live_keeper_cascade_name] would produce. *)
      let selected_cascade_canonical_json =
        match live_keeper_cascade_name_result cascade_name with
        | Ok runtime ->
          `String (Cascade_name.to_string runtime)
        | Error (`Unresolved _) -> `Null
      in
      let execution =
        `Assoc [
          ("selected_cascade_name", `String cascade_name);
          ( "selected_cascade_canonical",
            selected_cascade_canonical_json );
          ( "cascade_ref",
            (match m.cascade_ref with
             | Some ref_ -> Cascade_ref.cascade_ref_to_json ref_
             | None -> `Null) );
          ("models", `List []);
          ("active_model", `Null);
          ("active_model_label", `Null);
          ("last_model_used_label", `Null);
          ( "per_provider_timeout_sec",
            Json_util.float_opt_to_json m.per_provider_timeout_s );
          ( "per_provider_timeout_mode",
            `String
              (match m.per_provider_timeout_s with
               | Some _ -> "override"
               | None -> "turn_budget_heuristic") );
          ("verify", `Bool false);
        ]
      in
      let compaction =
        `Assoc [
          ("profile", `String m.compaction.profile);
          ("ratio_gate", `Float m.compaction.ratio_gate);
          ("message_gate", `Int m.compaction.message_gate);
          ("token_gate", `Int m.compaction.token_gate);
          ("cooldown_sec", `Int m.compaction.cooldown_sec);
        ]
      in
      let proactive =
        `Assoc [
          ("enabled", `Bool m.proactive.enabled);
          ("idle_sec", `Int m.proactive.idle_sec);
          ("cooldown_sec", `Int m.proactive.cooldown_sec);
        ]
      in
      let drift =
        let toml_defaults =
          Keeper_types_profile.load_keeper_profile_defaults name
        in
        drift_surface_json ~unknown_toml_keys:toml_defaults.unknown_toml_keys
      in
      let handoff =
        `Assoc [
          ("auto", `Bool m.auto_handoff);
          ("threshold", `Float m.handoff_threshold);
          ("cooldown_sec", `Int m.handoff_cooldown_sec);
        ]
      in
      let metrics =
        `Assoc [
          ("generation", `Int m.runtime.generation);
          ("total_turns", `Int m.runtime.usage.total_turns);
          ("total_input_tokens", `Int m.runtime.usage.total_input_tokens);
          ("total_output_tokens", `Int m.runtime.usage.total_output_tokens);
          ("total_tokens", `Int m.runtime.usage.total_tokens);
          ("total_cost_usd", `Float m.runtime.usage.total_cost_usd);
          ("last_model_used", `Null);
          ("last_input_tokens", `Int m.runtime.usage.last_input_tokens);
          ("last_output_tokens", `Int m.runtime.usage.last_output_tokens);
          ("last_total_tokens", `Int m.runtime.usage.last_total_tokens);
          ("last_latency_ms", last_latency_ms_json m.runtime.usage.last_latency_ms);
          ( "last_total_tokens_per_sec",
            tokens_per_sec_json ~tokens:m.runtime.usage.last_total_tokens
              ~latency_ms:m.runtime.usage.last_latency_ms );
          ( "last_output_tokens_per_sec",
            tokens_per_sec_json ~tokens:m.runtime.usage.last_output_tokens
              ~latency_ms:m.runtime.usage.last_latency_ms );
          ("compaction_count", `Int m.runtime.compaction_rt.count);
        ]
      in
      let current_phase =
        Keeper_registry.get_phase ~base_path:config.base_path m.name
      in
      let pipeline_stage =
        match current_phase with
        | Some phase -> Keeper_exec_status.pipeline_stage_of_phase phase
        | None -> "offline"
      in
      let state_diagram =
        Keeper_state_machine_mermaid.phase_to_mermaid
          ~current:(Option.value ~default:Keeper_state_machine.Offline current_phase)
      in
      let decision_pipeline_diagram =
        let phase = Option.value ~default:Keeper_state_machine.Offline current_phase in
        let stats = Thompson_sampling.get_stats m.agent_name in
        let tool_count = List.length (Keeper_exec_tools.keeper_allowed_tool_names m) in
        let recovery_floor_count =
          List.length (Keeper_tool_policy.failing_minimum_tool_names ())
        in
        let turn_outcome : [`Ok | `Failed] option =
          match Keeper_registry.get ~base_path:config.base_path m.name with
          | Some entry when entry.turn_consecutive_failures > 0 ->
            Some `Failed
          | Some _ -> Some `Ok
          | None -> None
        in
        Keeper_decision_audit.decision_pipeline_to_mermaid
          ?turn_outcome
          ~guard_penalty_total:stats.guard_penalties_total
          ~phase
          ~thompson_alpha:stats.alpha
          ~thompson_beta:stats.beta
          ~tool_count
          ~recovery_floor_count
          ()
      in
      let tools_access =
        let allowed = Keeper_exec_tools.keeper_allowed_tool_names m in
        let masc_tool_count =
          List.length (Keeper_exec_tools.keeper_masc_tool_names m)
        in
        `Assoc [
          ("tool_access", Keeper_types.tool_access_to_json m.tool_access);
          ("resolved_allowlist", `List (List.map (fun s -> `String s) allowed));
          ("tool_denylist", `List (List.map (fun s -> `String s) m.tool_denylist));
          ("active_masc_tool_count", `Int masc_tool_count);
          ("active_keeper_tool_count",
            `Int (List.length allowed - masc_tool_count));
          ("total_active", `Int (List.length allowed));
        ]
      in
      let sandbox_last_error =
        match Keeper_registry.get ~base_path:config.base_path m.name with
        | Some entry -> entry.last_error
        | None -> None
      in
      let effective_sandbox_image =
        if m.sandbox_profile = Keeper_types.Docker
        then Some (Env_config_keeper.KeeperSandbox.docker_image ())
        else None
      in
      let sandbox_preflight_json =
        Keeper_sandbox_runtime.docker_preflight ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Preflight ()) ()
        |> Option.map Keeper_sandbox_runtime.docker_preflight_to_yojson
      in
      let sandbox_preflight =
        match effective_sandbox_image, sandbox_preflight_json with
        | Some _, Some preflight -> Some preflight
        | _ -> None
      in
      let private_workspace_root =
        Keeper_sandbox.host_root_abs_of_meta ~config m
      in
      let sandbox_environment =
        let string_or_null value =
          let trimmed = String.trim value in
          if trimmed = "" then `Null else `String trimmed
        in
        `Assoc [
          ("base_path", `String config.base_path);
          ("project_root",
            `String (Keeper_alerting_path.project_root_of_config config));
          ("docker_playground_enabled",
            `Bool Env_config_keeper.DockerPlayground.enabled);
          ("docker_container_name",
            string_or_null Env_config_keeper.DockerPlayground.container_name);
          ("container_playground_root",
            string_or_null
              Env_config_keeper.DockerPlayground.container_playground_root);
          ("git_egress",
            `String
              (if Env_config_keeper.KeeperSandbox.with_git_dispatch_enabled () then
                 "docker_git_dispatch"
               else
                 "container_network_policy"));
          ("credential_fallbacks_disabled", `Bool false);
          ("docker_image",
            match effective_sandbox_image with
            | Some img -> string_or_null img
            | None -> `Null);
          ("pids_limit", `Int (Env_config_keeper.KeeperSandbox.pids_limit ()));
          ("memory",
            string_or_null (Env_config_keeper.KeeperSandbox.memory ()));
          ("tmpfs_size",
            string_or_null (Env_config_keeper.KeeperSandbox.tmpfs_size ()));
          ("relax_fs",
            `Bool (Env_config_keeper.KeeperSandbox.relax_fs ()));
          ("seccomp_profile",
            string_or_null
              (Env_config_keeper.KeeperSandbox.seccomp_profile ()));
          ("require_rootless",
            `Bool (Env_config_keeper.KeeperSandbox.require_rootless ()));
          ("require_userns",
            `Bool (Env_config_keeper.KeeperSandbox.require_userns ()));
          ("preflight",
            Json_util.option_to_yojson Fun.id sandbox_preflight);
        ]
      in
      (`OK,
       `Assoc [
         ("name", `String m.name);
         ("active_goal_ids", active_goal_ids_json);
         ("sandbox_profile", `String (Keeper_types.sandbox_profile_to_string m.sandbox_profile));
         ("network_mode", `String (Keeper_types.network_mode_to_string m.network_mode));         ("sandbox_last_error", Json_util.string_opt_to_json sandbox_last_error);
         ("sandbox_preflight",
           Json_util.option_to_yojson Fun.id sandbox_preflight);
         ("effective_sandbox_image",
           Json_util.string_opt_to_json effective_sandbox_image);
         ("private_workspace_root", `String private_workspace_root);
         ("sandbox_environment", sandbox_environment);
         ("allowed_paths",
           `List (List.map (fun s -> `String s) m.allowed_paths));
         ("effective_allowed_paths",
           `List (List.map (fun s -> `String s)
             (Keeper_alerting_path.effective_allowed_paths ~meta:m)));
         ("pipeline_stage", `String pipeline_stage);
         ("state_diagram", `String state_diagram);
         ("decision_pipeline_diagram", `String decision_pipeline_diagram);
         ("prompt", prompt);
         ("execution", execution);
         ("compaction", compaction);
         ("proactive", proactive);
         ("drift", drift);
         ("auto_execution_session", auto_execution_session_surface_json ());
         ("handoff", handoff);
         ("tools", tools_access);
         ("hooks", Keeper_hooks_oas.hook_introspection_json ());
         ("runtime", runtime_surface_json config m);
         ("runtime_trust", runtime_trust);
         ("coordination", coordination);
         ("sources", source_provenance_json config m);
         ("metrics", metrics);
       ])

(** Per-keeper cost/latency aggregates for the O4 cost dashboard.

    Reads each keeper's metrics JSONL, extracts cost_usd / latency_ms /
    token fields, and returns per-keeper totals plus p50/p95 latency
    percentiles and a redacted runtime cost breakdown.

    This closes the Phase-2 gap between runtime metrics (already in
    /api/v1/models/metrics) and per-agent spend (required by preview). *)
let keeper_cost_aggregates_json =
  Dashboard_http_keeper_feeds.keeper_cost_aggregates_json
;;

(** Read per-keeper [.decisions.jsonl] files and return a unified,
    time-sorted stream of recent events (turn telemetry, tool_exec,
    memory_search, etc.).  Each event is normalized to a flat record so
    the dashboard can render a single chronology without knowing the
    original schema variants. *)
let keeper_decisions_json = Dashboard_http_keeper_feeds.keeper_decisions_json

let keeper_decisions_log_json =
  Dashboard_http_keeper_feeds.keeper_decisions_log_json
;;

let keeper_memory_log_json = Dashboard_http_keeper_feeds.keeper_memory_log_json
