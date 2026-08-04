include Dashboard_utils

type attention_context = Dashboard_briefing_assembly.attention_context = {
  severity : string;
  has_action : bool;
  last_seen_ts : float;
  related_agent_names : string list;
  json : Yojson.Safe.t;
}

let top_item items =
  match items with
  | item :: _ -> item
  | [] -> `Null

let matching_action target_type target_id actions =
  List.find_opt
    (fun action ->
      let action_target_type = string_field "target_type" action in
      let action_target_id = String_util.trim_to_option (string_field "target_id" action) in
      String.equal action_target_type target_type
      &&
      match target_id, action_target_id with
      | Some left, Some right -> String.equal left right
      | None, None -> true
      | _ -> false)
    actions

let matching_action_for_incident incident actions =
  let target_type = string_field "target_type" incident in
  let target_id = String_util.trim_to_option (string_field "target_id" incident) in
  let candidates =
    actions
    |> List.filter (fun action ->
           let action_target_type = string_field "target_type" action in
           let action_target_id = String_util.trim_to_option (string_field "target_id" action) in
           String.equal action_target_type target_type
           &&
           match target_id, action_target_id with
           | Some left, Some right -> String.equal left right
           | None, None -> true
           | _ -> false)
  in
  match
    List.find_opt
      (Dashboard_briefing_assembly.action_matches_incident incident)
      candidates
  with
  | Some action -> Some action
  | None -> (match candidates with action :: _ -> Some action | [] -> None)

let rec evidence_preview_strings json =
  match json with
  | `String value ->
      let compact = compact_text value in
      if compact = "" then [] else [ compact ]
  | `List items ->
      items |> List.concat_map evidence_preview_strings |> dedup_strings |> take 4
  | `Assoc fields ->
      fields |> List.map snd |> List.concat_map evidence_preview_strings |> dedup_strings |> take 4
  | _ -> []

(* Workspace-level attention stays internal to the operator projection. *)
let is_internal_attention incident =
  Operator_digest_types.is_workspace_target_type
    (string_field "target_type" incident)

let build_attention_queue incidents actions =
  let public_incidents =
    incidents
    |> List.filter (fun incident -> not (is_internal_attention incident))
  in
  public_incidents
  |> List.filter_map (fun incident ->
         let kind = string_field "kind" incident in
         let severity = string_field ~default:"warn" "severity" incident in
         let summary = string_field "summary" incident in
         if kind = "" || summary = "" then None
         else
           let target_type = string_field "target_type" incident in
           let target_id = String_util.trim_to_option (string_field "target_id" incident) in
           let related_agent_names =
             dedup_strings
               (match String_util.trim_to_option (string_field "actor" incident) with
               | Some actor -> [ actor ]
               | None -> [])
           in
           let top_action = matching_action_for_incident incident actions in
           let last_seen_at = None in
           let id =
             Printf.sprintf "%s:%s:%s" kind target_type
               (match target_id with Some value -> value | None -> "none")
           in
           Some
             {
               severity;
               has_action = Option.is_some top_action;
               last_seen_ts =
                 Dashboard_utils.parse_iso_opt last_seen_at |> Option.value ~default:0.0;
               related_agent_names;
               json =
                 `Assoc
                   [
                     ("id", `String id);
                     ("kind", `String kind);
                     ("severity", `String severity);
                     ("summary", `String summary);
                     ("target_type", `String target_type);
                     ("target_id", Json_util.string_opt_to_json target_id);
                     ("top_action", Json_util.option_to_yojson (fun value -> value) top_action);
                     ("related_agent_names", `List (List.map (fun value -> `String value) related_agent_names));
                     ("evidence", member_assoc "evidence" incident);
                     ("evidence_preview", `List (List.map (fun value -> `String value) (evidence_preview_strings (member_assoc "evidence" incident))));
                     ("last_seen_at", Json_util.string_opt_to_json last_seen_at);
                   ];
             })
  |> List.sort (fun left right ->
         let by_severity = Int.compare (severity_rank right.severity) (severity_rank left.severity) in
         if by_severity <> 0 then by_severity
         else
           let by_action = Bool.compare right.has_action left.has_action in
           if by_action <> 0 then by_action
           else Float.compare right.last_seen_ts left.last_seen_ts)


type briefing_projection = {
  generated_at : string;
  snapshot_json : Yojson.Safe.t;
  digest_json : Yojson.Safe.t;
  namespace_json : Yojson.Safe.t;
  incidents : Yojson.Safe.t list;
  recommended_actions : Yojson.Safe.t list;
  attention_queue : attention_context list;
  agent_briefs : Yojson.Safe.t list;
  keeper_briefs : Yojson.Safe.t list;
  internal_signals : Yojson.Safe.t list;
}

let build_projection ?actor ~config ~sw ~clock
    ~proc_mgr () =
  let actor_name = Dashboard_projection_cache.normalize_actor_name actor in
  let ctx : _ Tool_operator.context =
    {
      config;
      agent_name = actor_name;
      sw;
      clock;
      proc_mgr;
      net = None;
      (* Briefing projections call only snapshot/digest reads; no Keeper lane
         action is reachable through this context. *)
      delegated_dispatch = None;
      mcp_session_id = None;
    }
  in
  let snapshot_json =
    Dashboard_projection_cache.get_or_compute_snapshot_json
      ~config ~actor:(Some actor_name) (fun actor_name ->
        Dashboard_projection_cache.operator_snapshot_json
          ~actor:actor_name
          ~view:"summary"
          ~include_messages:false
          ~include_keepers:true
          ~include_summary_fields:false
          ~lightweight_summary:true
          ctx)
  in
  let digest_json =
    Dashboard_projection_cache.get_or_compute_digest_json
      ~config ~actor:(Some actor_name) (fun actor_name ->
        match Dashboard_projection_cache.operator_digest_json ~actor:actor_name ctx with
        | Ok json -> json
        | Error message ->
            `Assoc
              [
                ("health", `String "warn");
                ("attention_items", `List []);
                ("recommended_actions", `List []);
                ("error", `String message);
              ])
  in
  let namespace_json =
    match member_assoc "workspace" snapshot_json with
    | `Assoc _ as value -> value
    | _ -> member_assoc "workspace" snapshot_json
  in
  let incidents =
    list_field "attention_items" digest_json
    |> List.sort (fun left right ->
           Int.compare
             (severity_rank (string_field ~default:"ok" "severity" right))
             (severity_rank (string_field ~default:"ok" "severity" left)))
  in
  let recommended_actions = list_field "recommended_actions" digest_json in
  let attention_queue = build_attention_queue incidents recommended_actions in
  let keeper_items =
    match member_assoc "keepers" snapshot_json |> member_assoc "items" with
    | `List items -> items
    | _ -> []
  in
  let agent_briefs =
    Dashboard_briefing_assembly.build_agent_briefs config attention_queue keeper_items
  in
  let keeper_briefs = Dashboard_briefing_assembly.build_keeper_briefs config keeper_items in
  let internal_signals = Dashboard_briefing_assembly.build_internal_signals incidents recommended_actions in
  {
    generated_at = Masc_domain.now_iso ();
    snapshot_json;
    digest_json;
    namespace_json;
    incidents;
    recommended_actions;
    attention_queue;
    agent_briefs;
    keeper_briefs;
    internal_signals;
}

let json ?actor ~config ~sw ~clock ~proc_mgr
    () =
  let projection =
    build_projection ?actor ~config ~sw
      ~clock ~proc_mgr ()
  in
  let summary_json =
    `Assoc
      [
        ("workspace_health", `String (string_field ~default:"ok" "health" projection.digest_json));
        ("cluster", Json_util.string_opt_to_json (Some (string_field "cluster" projection.namespace_json)));
        ("project", Json_util.string_opt_to_json (Some (string_field "project" projection.namespace_json)));
      ]
  in
  let command_focus_json =
    `Assoc
      [
        ("health", `String (string_field ~default:"ok" "health" projection.digest_json));
        ("active_operations", `Int 0);
        ("pending_approvals", `Int 0);
        ("top_attention", top_item projection.incidents);
        ("top_action", top_item projection.recommended_actions);
      ]
  in
  let operator_targets_json =
    `Assoc
      [
        ("keepers", `List projection.keeper_briefs);
        ("pending_confirms", member_assoc "pending_confirms" projection.snapshot_json);
        ("available_actions", member_assoc "available_actions" projection.snapshot_json);
      ]
  in
  `Assoc
    [
      ("generated_at", `String projection.generated_at);
      ("summary", summary_json);
      ("incidents", `List projection.incidents);
      ("recommended_actions", `List projection.recommended_actions);
      ("command_focus", command_focus_json);
      ("operator_targets", operator_targets_json);
      ( "attention_queue",
        `List (List.map (fun (item : attention_context) -> item.json) projection.attention_queue)
      );
      ("agent_briefs", `List projection.agent_briefs);
      ("keeper_briefs", `List projection.keeper_briefs);
      ("internal_signals", `List projection.internal_signals);
    ]
