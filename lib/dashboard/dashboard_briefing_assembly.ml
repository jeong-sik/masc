(** Dashboard_briefing_assembly — keeper briefs, operation contexts,
    session assembly, internal signals, and timeline rendering for the dashboard.

    Agent briefs and related helpers are in Dashboard_briefing_agents. *)

(** Context ratio above which a keeper gets elevated lane pressure rank. *)
let lane_pressure_ctx_ratio = 0.80

include Dashboard_briefing_agents

let keeper_tool_audit_json_fields config _registry_lookup keeper agent_name =
  let keeper_name =
    match member_assoc "name" keeper with
    | `String n ->
        (match String_util.trim_nonempty n with Some v -> v | None -> agent_name)
    | _ -> agent_name
  in
  let fallback_latest =
    Dashboard_utils.string_list_of_json (member_assoc "latest_tool_names" keeper)
  in
  let fallback_count = Json_util.assoc_int_opt "latest_tool_call_count" keeper in
  let fallback_source =
    match String_util.trim_nonempty (string_field "tool_audit_source" keeper) with
    | Some _ as value -> value
    | None -> None
  in
  let fallback_action_source =
    String_util.trim_nonempty (string_field "latest_action_source" keeper)
  in
  let fallback_at =
    String_util.trim_nonempty (string_field "tool_audit_at" keeper)
  in
  let file_snapshot =
    let keeper_updated_at =
      String_util.trim_nonempty (string_field "updated_at" keeper)
    in
    match
      Keeper_status_metrics.latest_tool_audit_snapshot_from_files config
        ~keeper_name
    with
    | Some snapshot ->
        Some
          {
            snapshot with
            tool_audit_at =
              (match snapshot.tool_audit_source, snapshot.tool_audit_at, keeper_updated_at with
               | Some _, None, Some updated_at -> Some updated_at
               | _ -> snapshot.tool_audit_at);
          }
    | None -> None
  in
  let latest_tool_names, latest_tool_call_count, latest_action_source,
      tool_audit_source, tool_audit_at =
    (match file_snapshot with
        | Some snapshot ->
            ( snapshot.latest_tool_names,
              snapshot.latest_tool_call_count,
              snapshot.latest_action_source,
              snapshot.tool_audit_source,
              snapshot.tool_audit_at )
        | None ->
            (* Use per-keeper tool tracking as last-resort fallback *)
            let tracked = Keeper_tools_agent_core.tool_usage_for_keeper agent_name in
            if tracked <> [] then
              let names = List.map fst tracked in
              let total = List.fold_left (fun acc (_, e) -> acc + e.Keeper_types.count) 0 tracked in
              let latest_at = List.fold_left (fun acc (_, e) ->
                max acc e.Keeper_types.last_used_at) 0.0 tracked in
              let at_str = if latest_at > 0.0
                then Some (Masc_domain.iso8601_of_unix_seconds latest_at) else None in
              (names, Some total, None, Some "keeper_dispatch", at_str)
            else
              ( fallback_latest,
                fallback_count,
                fallback_action_source,
                fallback_source,
                fallback_at ))
  in
  [
    ("latest_tool_names", Json_util.json_string_list latest_tool_names);
    ( "latest_tool_call_count",
      Json_util.option_to_yojson (fun value -> `Int value) latest_tool_call_count );
    ("latest_action_source", Json_util.string_opt_to_json latest_action_source);
    ("tool_audit_source", Json_util.string_opt_to_json tool_audit_source);
    ("tool_audit_at", Json_util.string_opt_to_json tool_audit_at);
  ]

let action_identity action =
  String.concat "|"
    [
      string_field "action_type" action;
      string_field "target_type" action;
      Option.value ~default:"none" (String_util.trim_nonempty (string_field "target_id" action));
      normalized_text_key (string_field "reason" action);
    ]

let incident_identity incident =
  String.concat "|"
    [
      string_field "kind" incident;
      string_field "target_type" incident;
      Option.value ~default:"none" (String_util.trim_nonempty (string_field "target_id" incident));
      normalized_text_key (string_field "summary" incident);
    ]

let identity_digest prefix identity =
  Printf.sprintf "%s:%s" prefix (Digest.to_hex (Digest.string identity))

let is_internal_attention incident =
  Operator_digest_types.is_workspace_target_type
    (string_field "target_type" incident)

let is_internal_action action =
  Operator_digest_types.is_workspace_target_type
    (string_field "target_type" action)

let build_keeper_briefs (config : Workspace.config) (keepers : Yojson.Safe.t list) =
  let all_entries = Keeper_registry.all ~base_path:config.base_path () in
  let registry_lookup name =
    List.find_opt (fun (e : Keeper_registry.registry_entry) -> String.equal e.name name) all_entries
  in
  keepers
  |> List.filter_map (fun keeper ->
         let name = string_field "name" keeper in
         if name = "" then None
         else
           let status =
             string_field "status" keeper
           in
           let context_ratio =
             match member_assoc "context_ratio" keeper with
             | `Float value -> Some value
             | `Int value -> Some (float_of_int value)
             | _ -> None
           in
           let context_metrics_unavailable =
             member_assoc "context_metrics_unavailable" keeper
           in
           (* Parsed once into the closed surface vocabulary rather than
              compared as text twice. keeper_status_runtime's comment on that
              type names this ranker as one of the two sites that re-classified
              the string; the producer builds it exhaustively, so a status this
              parser does not know is a producer/consumer mismatch, not a rank
              to guess at (#29350). *)
           let surface = Keeper_status_runtime.surface_status_of_string_opt status in
           let pressure_rank =
             match surface with
             | Some (Keeper_status_runtime.Surface_offline | Surface_inactive) -> 3
             | Some (Surface_active | Surface_busy | Surface_listening | Surface_idle)
             | None ->
               if
                 Option.exists
                   (fun ratio -> ratio >= lane_pressure_ctx_ratio)
                   context_ratio
               then 2
               else (
                 match surface with
                 | Some Keeper_status_runtime.Surface_idle -> 1
                 | Some _ | None -> 0)
           in
           Some
             {
               pressure_rank;
               last_seen_ts =
                 Dashboard_utils.parse_iso_opt
                   (String_util.trim_nonempty
                      (match String_util.trim_nonempty (string_field "last_autonomous_action_at" keeper) with
                      | Some value -> value
                      | None -> string_field "updated_at" keeper))
                 |> Option.value ~default:0.0;
               json =
                 `Assoc
                   ([
                      ("name", `String name);
                      ("agent_name", member_assoc "agent_name" keeper);
                      ("status", `String status);
                      ("context_ratio", Json_util.option_to_yojson (fun value -> `Float value) context_ratio);
                      ("context_metrics_unavailable", context_metrics_unavailable);
                      ("last_turn_ago_s", member_assoc "last_turn_ago_s" keeper);
                      ("current_work", member_assoc "current_task_id" keeper);
                      ("last_autonomous_action_at", member_assoc "last_autonomous_action_at" keeper);
                      ("proactive_enabled", member_assoc "proactive_enabled" keeper);
                      ("paused", member_assoc "paused" keeper);
                      ("exclusion_reason",
                       Keeper_runtime.autoboot_exclusion_reason_opt_to_yojson
                         (Keeper_runtime.autoboot_exclusion_reason config name));
                    ]
                    @ keeper_tool_audit_json_fields config registry_lookup keeper
                        (match String_util.trim_nonempty (string_field "agent_name" keeper) with
                         | Some agent_name -> agent_name
                         | None -> name));
             })
  |> List.sort (fun left right ->
         let by_pressure = Int.compare right.pressure_rank left.pressure_rank in
         if by_pressure <> 0 then by_pressure
         else Float.compare right.last_seen_ts left.last_seen_ts)
  |> List.map (fun (row : keeper_context) -> row.json)

(* An attention row and an action row are separate signals. The operator
   digest gives no link between them: [recommended_action] is free-form JSON
   an operator judgment wrote, and an attention item is a read-model
   observation, so nothing in either says which one answers which. This used
   to guess -- normalized-prose equality of the incident summary against the
   action reason, else a hand-written kind -> action_type table -- and stamp
   the single workspace recommendation onto every incident whose kind the
   table happened to list. Both rows are still emitted; neither claims the
   other. *)
let build_internal_signals incidents actions =
  let internal_incidents =
    incidents
    |> List.filter is_internal_attention
    |> List.map (fun incident ->
           {
             pressure_rank = Operator_digest_types.severity_rank_of_string (string_field ~default:"warn" "severity" incident);
             last_seen_ts = 0.0;
             json =
               `Assoc
                 [
                   ("id", `String (identity_digest "attention" (incident_identity incident)));
                   ("signal_type", `String "attention");
                   ("severity", member_assoc "severity" incident);
                   ("summary", member_assoc "summary" incident);
                   ("target_type", member_assoc "target_type" incident);
                   ("target_id", member_assoc "target_id" incident);
                   ("attention", incident);
                   ("action", `Null);
                 ];
           })
  in
  let internal_actions =
    actions
    |> List.filter is_internal_action
    |> List.map (fun action ->
           {
             pressure_rank = Operator_digest_types.severity_rank_of_string (string_field ~default:"warn" "severity" action);
             last_seen_ts = 0.0;
             json =
               `Assoc
                 [
                   ("id", `String (identity_digest "action" (action_identity action)));
                   ("signal_type", `String "action");
                   ("severity", member_assoc "severity" action);
                   ("summary", member_assoc "reason" action);
                   ("target_type", member_assoc "target_type" action);
                   ("target_id", member_assoc "target_id" action);
                   ("attention", `Null);
                   ("action", action);
                 ];
           })
  in
  (internal_incidents @ internal_actions)
  |> List.sort (fun left right -> Int.compare right.pressure_rank left.pressure_rank)
  |> List.map (fun (row : keeper_context) -> row.json)
