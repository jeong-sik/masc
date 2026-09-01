(* Dashboard_http_keeper_snapshot — per-keeper snapshot and config rendering.
   Extracted from dashboard_http_keeper.ml during godfile decomposition.
   Contains: full config JSON rendering and K2 feed delegations. *)

open Dashboard_http_keeper_types
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

let keeper_config_revision_json = function
  | Ok revision -> Keeper_turn_up_config_persistence.config_revision_to_yojson revision
  | Error detail ->
    `Assoc
      [ "state", `String "unavailable"
      ; "detail", `String detail
      ]
;;

(** Build a structured config JSON for a single keeper, grouped by category.
    Returns (http_status, json). *)
let keeper_config_json_once ~config_revision (config : Workspace.config) (name : string)
    : [ `OK | `Not_found ] * Yojson.Safe.t =
  match Keeper_meta_store.read_meta config name with
  | Error msg ->
      (`Not_found, `Assoc [ ("error", `String msg) ])
  | Ok None ->
      (`Not_found,
       `Assoc [ ("error", `String (Printf.sprintf "keeper %S not found" name)) ])
  | Ok (Some (m : Keeper_meta_contract.keeper_meta)) ->
      let raw_meta = m in
      (* bootstrap_runtime is called at server startup — skip here to
         avoid blocking the HTTP handler with Eio.Mutex + file I/O (#3335). *)
      let effective_meta =
        match
          Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
            ~base_path:config.base_path
            m.name
        with
        | Ok defaults ->
          (match Keeper_meta_contract.effective_meta_of_profile_defaults defaults m with
           | Ok meta -> Ok (defaults, meta)
           | Error detail ->
             let keeper_path =
               Option.value
                 ~default:(Keeper_types_profile.keeper_meta_path config m.name)
                 defaults.manifest_path
             in
             Error
               { Keeper_types_profile.keeper_name = m.name
               ; keeper_path
               ; failing_path = keeper_path
               ; kind = Keeper_types_profile.Profile_error
               ; detail
               })
        | Error error ->
          Error
            (Keeper_types_profile.keeper_toml_config_error_of_load_error
               ~keeper_name:m.name
               error)
      in
      (match effective_meta with
       | Error config_error ->
         let body =
           `Assoc
             [ "name", `String raw_meta.name
             ; "config_revision", keeper_config_revision_json config_revision
             ; "effective_config", `Null
             ; ( "config_error"
               , Keeper_types_profile.keeper_toml_config_error_to_json
                   config_error )
             ; "sources", source_provenance_json config raw_meta
             ]
         in
         `OK, with_keeper_config_field_presence body
       | Ok (defaults, m) ->
      let workspace = workspace_surface_json m in
      let runtime_trust =
        Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta:m
      in
      let effective_system_prompt =
        Keeper_run_context.build_base_system_prompt
          ~config
          ~profile_defaults:defaults
          ~meta:m
      in
      (* Preview the unified prompt shape a keeper turn uses.
         We build the observation from the current workspace state so the
         effective per-turn system side (identity + "Current World State"
         dynamic context) and the persisted user message match current state.
         No turn fired, so the typed preview entrypoint omits scheduler wake
         reasons instead of fabricating a cycle decision.

         Board events are collected WITHOUT advancing the keeper's board
         cursor: passing [~pending_board_events:None] would route through
         [collect_board_events ~advance_cursor:true], so merely opening a
         keeper's detail page would consume the live cursor and the next
         real turn would miss those events. Only a turn owns cursor
         advancement. *)
      let assembled_system_prompt_preview, unified_user_message_preview =
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
        let parts =
          let active_goal_summaries =
            Keeper_unified_prompt.active_goal_summaries_of_store ~config
          in
          let current_task =
            Keeper_world_observation_inputs.read_current_task ~config ~meta:m
          in
          (* The preview must advertise the same per-task Skill surfaces the
             real turn computes; omitting them renders every Task Skill as
             unavailable, the exact false signal the comment below promises
             not to send. Same resolve + same projection as the turn — a
             resolution failure previews as no surfaces, which is also what
             the failing turn would advertise. *)
          let task_skill_surfaces =
            let skill_snapshot =
              Keeper_agent_run.capture_skill_snapshot
                ~base_path:config.base_path
            in
            match
              Keeper_task_skill_turn.resolve_observations
                ~snapshot:skill_snapshot ~current_task
                ~held_task_skills:observation.held_task_skills
            with
            | Error _ -> []
            | Ok selection ->
              Keeper_task_skill_turn.exact_task_surfaces
                ~snapshot:skill_snapshot ~skill_names:defaults.skill_names
                ~selection ~current_task
                ~held_task_skills:observation.held_task_skills
          in
          (* Same parity rule as the Skill surfaces above: the preview shows
             the freshness rows a real turn would project, and a failed scan
             previews as an absent layer — which is also what the turn does. *)
          let repository_freshness =
            match
              Keeper_sandbox_control.checkout_freshness_rows ~config ~meta:m ()
            with
            | Ok rows -> rows
            | Error _ -> []
          in
          Keeper_unified_prompt.build_prompt_preview ~meta:m ~config
            ~profile_defaults:defaults ~current_task ~active_goal_summaries
            ~task_skill_surfaces ~repository_freshness ~observation ()
        in
        (* Match what a turn actually sends: the observation frame rides the
           per-turn dynamic context (system side), and the persisted user
           message is the wake marker / utterances only. *)
        ( parts.Keeper_unified_prompt.system_prompt
          ^ "\n\n"
          ^ parts.Keeper_unified_prompt.world_state,
          parts.Keeper_unified_prompt.user_message )
      in
      let prompt =
        `Assoc [
          ( "instructions",
            `String
              (Keeper_unified_prompt.effective_instructions
                 ~meta:m
                 ~profile_defaults:defaults
                 ()) );
          ( "system_prompt_blocks",
            `Assoc
              [
                ("system", prompt_block_json Prompt_names.keeper);
              ] );
          ("effective_system_prompt", `String effective_system_prompt);
          ("assembled_system_prompt", `String assembled_system_prompt_preview);
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
          ("verify", `Bool false);
        ]
      in
      let proactive =
        `Assoc [
          ("enabled", `Bool m.proactive.enabled);
        ]
      in
      let approval_mode =
        Keeper_tool_approval_mode.resolve
          (Keeper_tool_approval_mode.shared ())
          ~keeper_name:m.name
      in
      let tools =
        `Assoc
          [ ( "native"
            , match defaults.native_tool_posture with
              | None -> `Null
              | Some posture ->
                `String (Runtime_native_tools.to_string posture) )
          ; ( "approval_mode"
            , `String (Keeper_tool_approval_mode.mode_to_string approval_mode) )
          ; ( "full_native_admission"
            , match approval_mode with
              | Keeper_tool_approval_mode.Yolo ->
                `Assoc [ "status", `String "allowed" ]
              | Keeper_tool_approval_mode.Auto ->
                `Assoc
                  [ "status", `String "rejected"
                  ; "reason", `String "approval_mode_requires_yolo"
                  ] )
          ]
      in
      let skills =
        `Assoc
          [ ( "names"
            , match defaults.skill_names with
              | None -> `Null
              | Some names -> Json_util.json_string_list names )
          ]
      in
      let metrics =
        `Assoc [
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
      let keeper_last_error =
        match Keeper_registry.get ~base_path:config.base_path m.name with
        | Some entry -> entry.last_error
        | None -> None
      in
      let body =
       `Assoc [
         ("name", `String m.name);
         ("config_revision", keeper_config_revision_json config_revision);
         ("autoboot_enabled", `Bool m.autoboot_enabled);
         ("max_context_override", Json_util.int_opt_to_json m.max_context_override);
         ( "sandbox_profile"
         , `String
             (Keeper_types_profile_sandbox.sandbox_profile_to_string
                m.sandbox_profile) );
         ( "network_mode"
         , `String
             (Keeper_types_profile_sandbox.network_mode_to_string
                m.network_mode) );
         ("keeper_last_error", Json_util.string_opt_to_json keeper_last_error);
         ( "sandbox_roots"
         , `List
             (List.map
                (fun s -> `String s)
                (Keeper_alerting_path.sandbox_roots ~meta:m)) );
         ("pipeline_stage", `String pipeline_stage);
         ("lifecycle_phase", Json_util.string_opt_to_json lifecycle_phase);
         ("pipeline_stage_detail", `String pipeline_stage_detail);
	         ("state_diagram", `String state_diagram);
         ( "config_error",
           `Null );
         ("prompt", prompt);
         ("execution", execution);
         ("proactive", proactive);
         ("tools", tools);
         ("skills", skills);
         ("auto_execution_session", auto_execution_session_surface_json ());
         ("hooks", Keeper_hooks_agent_core.hook_introspection_json ());
         ("runtime", runtime_surface_json config m);
         ("runtime_trust", runtime_trust);
         ("workspace", workspace);
         ("sources", source_provenance_json config raw_meta);
         ("metrics", metrics);
       ]
      in
      (`OK, with_keeper_config_field_presence body))

let keeper_config_json (config : Workspace.config) (name : string)
    : [ `OK | `Not_found ] * Yojson.Safe.t =
  match
    Keeper_turn_up_config_persistence.with_current_config_revision
      ~config
      ~keeper_name:name
      (fun revision ->
        keeper_config_json_once ~config_revision:(Ok revision) config name)
  with
  | Ok { value = status, `Assoc fields; warnings } ->
    ( status
    , `Assoc
        (( "config_transaction_warnings"
         , `List
             (List.map
                Keeper_turn_up_config_persistence.warning_to_yojson
                warnings) )
         :: fields) )
  | Ok { value; warnings = _ } -> value
  | Error detail ->
    keeper_config_json_once ~config_revision:(Error detail) config name
;;

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
