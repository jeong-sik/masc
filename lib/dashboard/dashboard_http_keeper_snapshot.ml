(* Dashboard_http_keeper_snapshot — per-keeper snapshot and config rendering.
   Extracted from dashboard_http_keeper.ml during godfile decomposition.
   Contains: full config JSON rendering and K2 feed delegations. *)

open Dashboard_http_helpers
open Dashboard_http_keeper_types
open Dashboard_http_helpers
open Keeper_status_bridge

let keeper_config_field_presence_json config_json =
  let rec collect prefix json acc =
    match json with
    | `Assoc fields ->
      List.fold_left
        (fun acc (key, value) ->
          let path = if prefix = "" then key else prefix ^ "." ^ key in
          collect path value (path :: acc))
        acc
        fields
    | _ -> acc
  in
  let present_paths =
    collect "" config_json [] |> List.sort_uniq String.compare
  in
  `Assoc
    [ ("schema", `String "keeper.config.field_presence.v1")
    ; ("producer", `String "dashboard_http_keeper_snapshot")
    ; ("present_paths", Json_util.json_string_list present_paths)
    ]
;;

let with_keeper_config_field_presence = function
  | `Assoc fields as config_json ->
    `Assoc
      (fields @ [ ("field_presence", keeper_config_field_presence_json config_json) ])
  | other -> other
;;

(** Build a structured config JSON for a single keeper, grouped by category.
    Returns (http_status, json). *)
let keeper_config_json (config : Workspace.config) (name : string)
    : [ `OK | `Not_found ] * Yojson.Safe.t =
  match Keeper_meta_store.read_meta config name with
  | Error msg ->
      (`Not_found, `Assoc [ ("error", `String msg) ])
  | Ok None ->
      (`Not_found,
       `Assoc [ ("error", `String (Printf.sprintf "keeper %S not found" name)) ])
  | Ok (Some (m : Keeper_meta_contract.keeper_meta)) ->
      (* bootstrap_runtime is called at server startup — skip here to
         avoid blocking the HTTP handler with Eio.Mutex + file I/O (#3335). *)
      let defaults, profile_config_error =
        match
          Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
            ~base_path:config.base_path
            m.name
        with
        | Ok defaults -> defaults, None
        | Error error ->
          ( Keeper_types_profile.empty_keeper_profile_defaults
          , Some
              (Keeper_types_profile.keeper_toml_config_error_of_load_error
                 ~keeper_name:m.name
                 error) )
      in
      let persona_extended =
        Keeper_types_profile.resolved_persona_name ~keeper_name:m.name defaults
        |> Keeper_types_profile.load_persona_extended
        |> Option.value ~default:""
      in
      let active_goals =
        List.filter_map
          (fun goal_id ->
             match Goal_store.get_goal config ~goal_id with
             (* RFC-0294: active_goals tuple dropped its horizon element. *)
             | Some { Goal_store.id; title; _ } ->
                 Some (id, title)
               | None -> None)
          m.active_goal_ids
      in
      let default_prompt_string default live =
        match default with
        | Some value when String.trim live = "" -> value
        | _ -> live
      in
      let prompt_goal = default_prompt_string defaults.goal m.goal in
      let prompt_instructions =
        default_prompt_string defaults.instructions m.instructions
      in
      let active_goal_ids_json =
        `List (List.map (fun goal_id -> `String goal_id) m.active_goal_ids)
      in
      let active_goals_json =
        `List
          (List.map
             (fun (id, title) ->
                `Assoc [
                  ("id", `String id);
                  ("title", `String title);
                ])
             active_goals)
      in
      let resolved_active_goal_ids =
        List.map (fun (id, _) -> id) active_goals
      in
      let missing_active_goal_ids =
        m.active_goal_ids
        |> List.filter (fun goal_id ->
               not (List.mem goal_id resolved_active_goal_ids))
      in
      let workspace =
        match workspace_surface_json m with
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
      let effective_system_prompt =
        Keeper_prompt.build_keeper_system_prompt
          ~goal:prompt_goal
          ~instructions:prompt_instructions
          ~persona_extended ~keeper_name:m.name
          ~active_goals
          ()
      in
      (* Preview the actual unified prompt the keeper turn uses.
         We build the observation from the current workspace state so the
         system message and the "Current World State" user message both
         match what a turn would see right now.

         Board events are collected WITHOUT advancing the keeper's board
         cursor: passing [~pending_board_events:None] would route through
         [collect_board_events ~advance_cursor:true], so merely opening a
         keeper's detail page would consume the live cursor and the next
         real turn would miss those events. Only a turn owns cursor
         advancement. *)
      let unified_system_prompt_preview, unified_user_message_preview =
        let observation =
          let pending_board_events, _new_count, _mention_count =
            Keeper_world_observation
            .collect_board_events_without_advancing_cursor
              ~base_path:config.base_path
              ~meta:m
          in
          Keeper_world_observation.observe
            ~pending_board_events:(Some pending_board_events) ~config ~meta:m
        in
        Keeper_unified_prompt.build_prompt ~meta:m ~base_path:config.base_path
          ~profile_defaults:defaults ~observation ()
      in
      let prompt =
        `Assoc [
          ("goal", `String prompt_goal);
          ("instructions", `String prompt_instructions);
          ( "system_prompt_blocks",
            `Assoc
              [
                ("constitution", prompt_block_json Keeper_prompt_names.constitution);
                ("world", prompt_block_json Keeper_prompt_names.world);
                ("capabilities", prompt_block_json Keeper_prompt_names.capabilities);
              ] );
          ("effective_system_prompt", `String effective_system_prompt);
          ("unified_system_prompt", `String unified_system_prompt_preview);
          ("unified_user_message_preview", `String unified_user_message_preview);
        ]
      in
      let runtime_id = Keeper_meta_contract.runtime_id_of_meta m in
      let runtime_options =
        let catalog =
          Runtime.get_runtime_ids ()
          |> List.map String.trim
          |> List.filter (fun id -> id <> "")
        in
        let with_current =
          if List.mem runtime_id catalog then catalog else runtime_id :: catalog
        in
        List.sort_uniq String.compare with_current
      in
      (* RFC-0149 §3.3 — Result-returning resolver: on [Error] the
         canonical field surfaces as JSON [null] (parse-don't-validate
         honest signal) instead of the silent [Keeper_turn] rewrite the
         legacy live runtime-id facade would produce. *)
      let selected_runtime_canonical_json =
        match live_keeper_runtime_id_result runtime_id with
        | Ok runtime ->
          `String (runtime)
        | Error (`Unresolved _) -> `Null
      in
      let per_provider_timeout = defaults.per_provider_timeout in
      let execution =
        `Assoc [
          ("selected_runtime_id", `String runtime_id);
          ( "selected_runtime_canonical",
            selected_runtime_canonical_json );
          ( "runtime_options",
            `List (List.map (fun id -> `String id) runtime_options) );
          ("models", `List []);
          ("active_model", `Null);
          ("active_model_label", `Null);
          ("last_model_used_label", `Null);
          ( "per_provider_timeout_sec",
            Json_util.float_opt_to_json per_provider_timeout );
          ( "per_provider_timeout_mode",
            `String
               (match per_provider_timeout with
                | Some _ -> "override"
                | None -> "turn_budget_default") );
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
        ]
      in
      let drift =
        drift_surface_json ~unknown_toml_keys:defaults.unknown_toml_keys
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
        | Some phase -> Keeper_status_runtime.pipeline_stage_of_phase phase
        | None -> "offline"
      in
      let lifecycle_phase =
        Option.map Keeper_state_machine.phase_to_string current_phase
      in
      let pipeline_stage_detail =
        match current_phase with
        | Some phase -> Keeper_status_runtime.pipeline_stage_detail_of_phase phase
        | None -> "registry_absent"
      in
      let state_diagram =
        Keeper_state_machine_mermaid.phase_to_mermaid
          ~current:(Option.value ~default:Keeper_state_machine.Offline current_phase)
      in
      let decision_pipeline_diagram =
        let phase = Option.value ~default:Keeper_state_machine.Offline current_phase in
        let stats = Thompson_sampling.get_stats m.agent_name in
        let turn_outcome : [`Ok | `Failed] option =
          match Keeper_registry.get ~base_path:config.base_path m.name with
          | Some entry when entry.turn_consecutive_failures > 0 ->
            Some `Failed
          | Some _ -> Some `Ok
          | None -> None
        in
        Keeper_decision_audit.decision_pipeline_to_mermaid
          ?turn_outcome
          ~phase
          ~thompson_alpha:stats.alpha
          ~thompson_beta:stats.beta
          ()
      in
      let sandbox_last_error =
        match Keeper_registry.get ~base_path:config.base_path m.name with
        | Some entry -> entry.last_error
        | None -> None
      in
      let body =
       `Assoc [
         ("name", `String m.name);
         ("active_goal_ids", active_goal_ids_json);
         ("autoboot_enabled", `Bool m.autoboot_enabled);
         ("max_context_override", Json_util.int_opt_to_json m.max_context_override);
         ( "limits",
           `Assoc
             [
               ( "min_context_override_tokens",
                 `Int Keeper_config.min_keeper_context_tokens );
               ( "max_context_override_tokens",
                 `Int Keeper_config.max_keeper_context_tokens );
             ] );
         ("sandbox_profile", `String (Keeper_types_profile_sandbox.sandbox_profile_to_string m.sandbox_profile));
         ("network_mode", `String (Keeper_types_profile_sandbox.network_mode_to_string m.network_mode));         ("sandbox_last_error", Json_util.string_opt_to_json sandbox_last_error);
         ("allowed_paths",
           `List (List.map (fun s -> `String s) m.allowed_paths));
	         ("effective_allowed_paths",
	           `List (List.map (fun s -> `String s)
	             (Keeper_alerting_path.effective_allowed_paths ~meta:m)));
	         ("pipeline_stage", `String pipeline_stage);
	         ("lifecycle_phase", Json_util.string_opt_to_json lifecycle_phase);
	         ("pipeline_stage_detail", `String pipeline_stage_detail);
	         ("state_diagram", `String state_diagram);
         ( "config_error",
           Json_util.option_to_yojson
             Keeper_types_profile.keeper_toml_config_error_to_json
             profile_config_error );
         ("decision_pipeline_diagram", `String decision_pipeline_diagram);
         ("prompt", prompt);
         ("execution", execution);
         ("compaction", compaction);
         ("proactive", proactive);
         ("drift", drift);
         ("auto_execution_session", auto_execution_session_surface_json ());
         ("handoff", handoff);
         ("hooks", Keeper_hooks_oas.hook_introspection_json ());
         ("runtime", runtime_surface_json config m);
         ("runtime_trust", runtime_trust);
         ("workspace", workspace);
         ("sources", source_provenance_json config m);
         ("metrics", metrics);
       ]
      in
      (`OK, with_keeper_config_field_presence body)

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
