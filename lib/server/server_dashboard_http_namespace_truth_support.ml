(** Shared helpers for assembling namespace-truth payloads. *)

open Dashboard_http_helpers

let pending_confirm_summary_ttl = 10.0
let pending_confirm_summary_stale_for = pending_confirm_summary_ttl *. 3.0

let pending_confirm_summary_empty_json =
  `Assoc
    [
      ("actor_filter", `Null);
      ("filter_active", `Bool false);
      ("visible_count", `Int 0);
      ("total_count", `Int 0);
      ("hidden_count", `Int 0);
      ("hidden_actors", `List []);
      ("confirm_required_actions", `List []);
    ]

let last_good_pending_confirm_summary : Yojson.Safe.t Atomic.t =
  Atomic.make pending_confirm_summary_empty_json

let pending_confirm_summary_cached (config : Workspace.config) =
  let key = Printf.sprintf "pending_confirm_summary:%s" config.base_path in
  let fallback = Atomic.get last_good_pending_confirm_summary in
  let compute () =
    let json = Operator_control.pending_confirm_summary_json config in
    Atomic.set last_good_pending_confirm_summary json;
    json
  in
  if Option.is_some (Eio_context.get_switch_opt ()) then
    Dashboard_cache.seed_stale_if_missing key
      ~stale_for:pending_confirm_summary_stale_for fallback;
  let result = Dashboard_cache.get_or_compute key ~ttl:pending_confirm_summary_ttl compute in
  if result = `Null then fallback else result

let dashboard_namespace_truth_focus_json ~initialized ~runtime_count ~top_queue =
  let focus_of_queue queue =
    let target_type =
      json_string_field_opt "target_type" queue
      |> Option.value ~default:"execution"
    in
    let target_id = json_string_field_opt "target_id" queue in
    let linked_operation_id =
      json_string_field_opt "linked_operation_id" queue
    in
    let suggested_tab, suggested_surface, suggested_params =
      match linked_operation_id with
      | Some operation_id ->
          ( "command",
            Some "operations",
            `Assoc [ ("operation_id", `String operation_id) ] )
      | None ->
          ( "command",
            Some "summary",
            `Assoc
              (List.filter_map
                 (fun (key, value_opt) ->
                   Option.map (fun value -> (key, `String value)) value_opt)
                 [ ("target_type", Some target_type); ("target_id", target_id) ])
          )
    in
    `Assoc
      [
        ( "label",
          `String
            (match json_string_field_opt "summary" queue with
            | Some summary -> summary
            | None -> "Execution queue requires attention.") );
        ( "reason",
          `String
            (match json_string_field_opt "summary" queue with
            | Some summary -> summary
            | None -> "Top execution queue item is the next drill-down target.")
        );
        ("source", `String "execution");
        ("provenance", `String "derived");
        ("target_kind", `String "queue");
        ( "target_id", Json_util.string_opt_to_json target_id );
        ("suggested_tab", `String suggested_tab);
        ( "suggested_surface", Json_util.string_opt_to_json suggested_surface );
        ("suggested_params", suggested_params);
      ]
  in
  match top_queue with
  | `Assoc _ as queue -> focus_of_queue queue
  | _ ->
      let label, reason, source, provenance =
        if not initialized then
          ( "초기 project snapshot",
            "조율 namespace가 아직 초기화되지 않았습니다. 기본 namespace 상태부터 확인하세요.",
            "orchestra",
            "derived" )
        else if runtime_count = 0 then
          ( "등록된 런타임이 없습니다. 활동이 시작되면 여기에 포커스가 나타납니다.",
            "No agents or keepers bound yet; namespace is idle.",
            "namespace",
            "fallback" )
        else
          ( "지금은 namespace 전체가 비교적 안정적입니다",
            "Namespace-wide view is healthy enough; start from the command overview.",
            "namespace",
            "fallback" )
      in
      `Assoc
        [
          ("label", `String label);
          ("reason", `String reason);
          ("source", `String source);
          ("provenance", `String provenance);
          ("target_kind", `String "node");
          ("target_id", `String "namespace:default");
          ("suggested_tab", `String "command");
          ("suggested_surface", `String "summary");
          ("suggested_params", `Assoc []);
        ]

let take_n = List.take

let execution_top_queue execution_json =
  match Json_util.assoc_member_opt "execution_queue" execution_json with
  | Some (`List (head :: _)) -> head
  | _ -> `Null

let execution_summary_json execution_json =
  let execution_queue =
    match Json_util.assoc_member_opt "execution_queue" execution_json with
    | Some (`List items) -> items
    | _ -> []
  in
  let execution_operation_briefs =
    json_list_field "operation_briefs" execution_json |> take_n 20
  in
  let execution_worker_support =
    json_list_field "worker_support_briefs" execution_json |> take_n 10
  in
  let execution_continuity =
    json_list_field "continuity_briefs" execution_json |> take_n 10
  in
  let execution_keepers = json_list_field "keepers" execution_json |> take_n 20 in
  let has_text key json = json_string_field_opt key json |> Option.is_some in
  let existing = json_assoc_field "summary" execution_json in
  match Json_util.assoc_member_opt "blocked_sessions" existing with
  | Some (`Int _ | `Intlit _) -> existing
  | _ ->
      `Assoc
        [
          ("active_operations", `Int (List.length execution_operation_briefs));
          ( "blocked_operations",
            `Int
              (count_where execution_operation_briefs (has_text "blocker_summary"))
          );
          ( "worker_alerts",
            `Int
              (count_where execution_worker_support (fun row ->
                   match json_string_field_opt "tone" row with
                   | Some "warn" | Some "bad" -> true
                   | _ -> false)) );
          ( "continuity_alerts",
            `Int
              (count_where execution_continuity (fun row ->
                   match json_string_field_opt "tone" row with
                   | Some "warn" | Some "bad" -> true
                   | _ -> false)) );
          ("priority_items", `Int (List.length execution_queue));
          ("keepers", `Int (List.length execution_keepers));
        ]

let namespace_truth_command_summary_json command_summary_json =
  let command_ops = json_assoc_field "operations" command_summary_json in
  let command_detachments = json_assoc_field "detachments" command_summary_json in
  let command_alerts = json_assoc_field "alerts" command_summary_json in
  let command_decisions = json_assoc_field "decisions" command_summary_json in
  `Assoc
    [
      ( "active_operations",
        `Int
          (json_int_field "active" (json_assoc_field "summary" command_ops)
             ~default:0) );
      ( "active_detachments",
        `Int
          (json_int_field "active" (json_assoc_field "summary" command_detachments)
             ~default:0) );
      ( "pending_approvals",
        `Int
          (json_int_field "pending" (json_assoc_field "summary" command_decisions)
             ~default:0) );
      ( "bad_alerts",
        `Int
          (json_int_field "bad" (json_assoc_field "summary" command_alerts)
             ~default:0) );
      ( "warn_alerts",
        `Int
          (json_int_field "warn" (json_assoc_field "summary" command_alerts)
             ~default:0) );
      ("provenance", `String "truth");
    ]

let namespace_truth_dashboard_surface = "/api/v1/dashboard/namespace-truth"
let namespace_truth_source = "namespace_truth_read_model"

let namespace_truth_aliases =
  [
    "/api/v1/dashboard/project-snapshot";
  ]

let namespace_truth_aliases_json () =
  `List (List.map (fun alias -> `String alias) namespace_truth_aliases)

let namespace_truth_retention_json ~(config : Workspace.config) =
  `Assoc
    [
      ("scope", `String "dashboard_namespace_truth");
      ("workspace_root", `String config.base_path);
      ("workspace_path", `String config.workspace_path);
      ("shell_input", `String "/api/v1/dashboard/shell");
      ("execution_input", `String "/api/v1/dashboard/execution");
      ("command_input", `String "command_summary_json");
      ( "cache_policy",
        `String "proactive_execution_cache_last_good_shell_fallback" );
    ]

let namespace_truth_metadata_fields ~(config : Workspace.config) ~generated_at =
  [
    ("dashboard_surface", `String namespace_truth_dashboard_surface);
    ("dashboard_aliases", namespace_truth_aliases_json ());
    ("source", `String namespace_truth_source);
    ("retention", namespace_truth_retention_json ~config);
    ("generated_at_iso", `String generated_at);
  ]

let compose_namespace_truth_initializing ~(config : Workspace.config) ~message =
  let generated_at = Masc_domain.now_iso () in
  `Assoc
    (namespace_truth_metadata_fields ~config ~generated_at
     @ [
         ("status", `String "initializing");
         ("generated_at", `String generated_at);
         ("message", `String message);
       ])

module String_set = Set_util.StringSet

let json_bool_field key json ~default =
  match Safe_ops.safe_member key json with
  | `Bool value -> value
  | _ -> default

let keeper_live keeper =
  json_bool_field "keepalive_running" keeper ~default:false

let keeper_has_goal keeper =
  json_list_field "active_goal_ids" keeper <> []
  || Option.is_some (json_string_field_opt "goal" keeper)

let keeper_actor_names keeper =
  [ json_string_field_opt "name" keeper; json_string_field_opt "agent_name" keeper ]
  |> List.filter_map Fun.id

let task_is_active task =
  match json_string_field_opt "status" task with
  | Some ("todo" | "claimed" | "in_progress" | "awaiting_verification") -> true
  | _ -> false

let readiness_score_of_status = function
  | "bad" -> 40
  | "warn" -> 72
  | _ -> 100

let summary_of_reasons ~ok_message reasons =
  match reasons with
  | [] -> ok_message
  | _ -> String.concat "; " reasons

let metrics_json entries =
  `Assoc (List.map (fun (key, value) -> (key, `Int value)) entries)

let readiness_pillar_json ~key ~label ~status ~ok_message ~reasons ~metrics =
  let score = readiness_score_of_status status in
  `Assoc
    [
      ("key", `String key);
      ("label", `String label);
      ("status", `String status);
      ("score", `Int score);
      ("summary", `String (summary_of_reasons ~ok_message reasons));
      ("blocking_reasons", `List (List.map (fun reason -> `String reason) reasons));
      ("metrics", metrics_json metrics);
    ]

let attention_event_json
    ?keeper_name ?target_type ?target_id ?recommended_action
    ?(requires_decision = false) ~severity ~kind ~summary ~provenance () =
  `Assoc
    [
      ("severity", `String severity);
      ("kind", `String kind);
      ("summary", `String summary);
      ("requires_decision", `Bool requires_decision);
      ( "keeper_name", Json_util.string_opt_to_json keeper_name );
      ( "target_type", Json_util.string_opt_to_json target_type );
      ( "target_id", Json_util.string_opt_to_json target_id );
      ( "recommended_action", Json_util.string_opt_to_json recommended_action );
      ("provenance", `String provenance);
    ]

let derive_readiness_and_attention ~execution_json ~execution_summary
    ~pending_confirm_summary =
  let keepers = json_list_field "keepers" execution_json in
  let live_keepers = List.filter keeper_live keepers in
  let tasks = json_list_field "tasks" execution_json |> List.filter task_is_active in
  let pending_visible =
    json_int_field "visible_count" pending_confirm_summary
      ~default:(json_int_field "total_count" pending_confirm_summary ~default:0)
  in
  let sandbox_error_count =
    count_where live_keepers (fun keeper ->
      Option.is_some (json_string_field_opt "sandbox_last_error" keeper))
  in
  let docker_live_count =
    count_where live_keepers (fun keeper ->
      json_string_field_opt "sandbox_profile" keeper = Some "docker")
  in
  let local_live_count =
    count_where live_keepers (fun keeper ->
      json_string_field_opt "sandbox_profile" keeper = Some "local")
  in
  let unknown_sandbox_count =
    count_where live_keepers (fun keeper ->
      Option.is_none (json_string_field_opt "sandbox_profile" keeper))
  in
  let continue_gate_count =
    count_where live_keepers (fun keeper ->
      json_bool_field "runtime_blocker_continue_gate" keeper ~default:false)
  in
  let runtime_blocker_count =
    count_where live_keepers (fun keeper ->
      Option.is_some (json_string_field_opt "runtime_blocker_class" keeper))
  in
  let goalful_keeper_names =
    List.fold_left
      (fun acc keeper ->
        if keeper_has_goal keeper then
          keeper_actor_names keeper
          |> List.fold_left (fun names name -> String_set.add name names) acc
        else acc)
      String_set.empty keepers
  in
  let goalful_keeper_count = String_set.cardinal goalful_keeper_names in
  let goal_dark_live_count =
    count_where live_keepers (fun keeper -> not (keeper_has_goal keeper))
  in
  let unassigned_active_tasks =
    count_where tasks (fun task ->
      Option.is_none (json_string_field_opt "assignee" task))
  in
  let assigned_goal_dark_tasks =
    count_where tasks (fun task ->
      match json_string_field_opt "assignee" task with
      | Some assignee -> not (String_set.mem assignee goalful_keeper_names)
      | None -> false)
  in
  let missing_audit_live_count =
    count_where live_keepers (fun keeper ->
      Option.is_none (json_string_field_opt "tool_audit_at" keeper))
  in
  let continuity_alerts =
    json_int_field "continuity_alerts" execution_summary ~default:0
  in
  let worker_alerts =
    json_int_field "worker_alerts" execution_summary ~default:0
  in
  let execution_safety_reasons =
    List.filter_map Fun.id
      [
        (if pending_visible > 0 then
           Some (Printf.sprintf "%d operator approvals are still pending" pending_visible)
         else None);
        (if sandbox_error_count > 0 then
           Some (Printf.sprintf "%d live keepers report sandbox errors" sandbox_error_count)
         else None);
        (if local_live_count > 0 then
           Some (Printf.sprintf "%d live keepers are still running in local sandbox" local_live_count)
         else None);
        (if unknown_sandbox_count > 0 then
           Some (Printf.sprintf "%d live keepers are missing sandbox provenance" unknown_sandbox_count)
         else None);
      ]
  in
  let execution_safety_status =
    if pending_visible > 0 then "bad"
    else if sandbox_error_count > 0 || local_live_count > 0 || unknown_sandbox_count > 0
    then "warn"
    else "ok"
  in
  let autonomy_reliability_reasons =
    List.filter_map Fun.id
      [
        (if continue_gate_count > 0 then
           Some (Printf.sprintf "%d keepers are waiting at a continue gate" continue_gate_count)
         else None);
        (if runtime_blocker_count > 0 then
           Some (Printf.sprintf "%d live keepers have runtime blockers" runtime_blocker_count)
         else None);
        (if continuity_alerts > 0 then
           Some (Printf.sprintf "%d continuity alerts are active" continuity_alerts)
         else None);
        (if worker_alerts > 0 then
           Some (Printf.sprintf "%d worker support alerts are active" worker_alerts)
         else None);
      ]
  in
  let autonomy_reliability_status =
    if continue_gate_count > 0 || runtime_blocker_count > 0 then "bad"
    else if continuity_alerts > 0 || worker_alerts > 0 then "warn"
    else "ok"
  in
  let goal_coherence_reasons =
    List.filter_map Fun.id
      [
        (if tasks <> [] && goalful_keeper_count = 0 then
           Some "Active tasks exist, but no keeper exposes linked goals"
         else None);
        (if unassigned_active_tasks > 0 then
           Some
             (Printf.sprintf "%d active tasks are still unassigned" unassigned_active_tasks)
         else None);
        (if assigned_goal_dark_tasks > 0 then
           Some
             (Printf.sprintf "%d active tasks are assigned to keepers without visible goal context"
                assigned_goal_dark_tasks)
         else None);
        (if goal_dark_live_count > 0 then
           Some
             (Printf.sprintf "%d live keepers are active without linked goal context"
                goal_dark_live_count)
         else None);
      ]
  in
  let goal_coherence_status =
    if (tasks <> [] && goalful_keeper_count = 0) || unassigned_active_tasks > 0
    then "bad"
    else if assigned_goal_dark_tasks > 0 || goal_dark_live_count > 0
    then "warn"
    else "ok"
  in
  let operational_clarity_reasons =
    List.filter_map Fun.id
      [
        (if missing_audit_live_count > 0 then
           Some
             (Printf.sprintf "%d live keepers are missing tool-audit anchors in the execution snapshot"
                missing_audit_live_count)
         else None);
      ]
  in
  let operational_clarity_status =
    if missing_audit_live_count > 0 then "warn"
    else "ok"
  in
  let pillars =
    [
      readiness_pillar_json
        ~key:"execution_safety"
        ~label:"Execution Safety"
        ~status:execution_safety_status
        ~ok_message:"Approval and sandbox posture are visible for live keepers."
        ~reasons:execution_safety_reasons
        ~metrics:
          [
            ("live_keepers", List.length live_keepers);
            ("docker_live", docker_live_count);
            ("local_live", local_live_count);
            ("pending_approvals", pending_visible);
          ];
      readiness_pillar_json
        ~key:"autonomy_reliability"
        ~label:"Autonomy Reliability"
        ~status:autonomy_reliability_status
        ~ok_message:"No live keepers are blocked by runtime or operator gates."
        ~reasons:autonomy_reliability_reasons
        ~metrics:
          [
            ("runtime_blockers", runtime_blocker_count);
            ("continue_gates", continue_gate_count);
            ("continuity_alerts", continuity_alerts);
            ("worker_alerts", worker_alerts);
          ];
      readiness_pillar_json
        ~key:"goal_coherence"
        ~label:"Goal Coherence"
        ~status:goal_coherence_status
        ~ok_message:"Active work is attached to keepers with visible goal context."
        ~reasons:goal_coherence_reasons
        ~metrics:
          [
            ("active_tasks", List.length tasks);
            ("goalful_keepers", goalful_keeper_count);
            ("unassigned_tasks", unassigned_active_tasks);
            ("goal_dark_keepers", goal_dark_live_count);
          ];
      readiness_pillar_json
        ~key:"operational_clarity"
        ~label:"Operational Clarity"
        ~status:operational_clarity_status
        ~ok_message:"The control workspace has recent tool-audit anchors."
        ~reasons:operational_clarity_reasons
        ~metrics:[ ("missing_tool_audit", missing_audit_live_count) ];
    ]
  in
  let overall_status =
    if List.exists (fun pillar ->
      json_string_field_opt "status" pillar = Some "bad") pillars
    then "bad"
    else if List.exists (fun pillar ->
      json_string_field_opt "status" pillar = Some "warn") pillars
    then "warn"
    else "ok"
  in
  let overall_score =
    match pillars with
    | [] -> 100
    | _ ->
        List.fold_left
          (fun acc pillar -> acc + json_int_field "score" pillar ~default:100)
          0 pillars
        / List.length pillars
  in
  let blocking_count =
    pending_visible + runtime_blocker_count + unassigned_active_tasks
    + missing_audit_live_count
  in
  let base_events =
    let events = ref [] in
    if pending_visible > 0 then
      events :=
        attention_event_json ~severity:"bad" ~kind:"pending_confirm"
          ~summary:
            (Printf.sprintf "%d operator actions still require approval" pending_visible)
          ~recommended_action:"Review approvals in Operations"
          ~requires_decision:true ~provenance:"derived" ()
        :: !events;
    List.rev !events
  in
  let keeper_events =
    live_keepers
    |> List.filter_map (fun keeper ->
         let keeper_name =
           Option.value ~default:"keeper"
             (json_string_field_opt "name" keeper)
         in
         if json_bool_field "runtime_blocker_continue_gate" keeper ~default:false then
           Some
             (attention_event_json ~severity:"bad" ~kind:"continue_gate"
                ~summary:
                  (Printf.sprintf "%s is waiting for operator approval to continue"
                     keeper_name)
                ~keeper_name ~target_type:"keeper" ~target_id:keeper_name
                ~recommended_action:"Inspect the keeper and confirm or resume it"
                ~requires_decision:true ~provenance:"execution" ())
         else
           match json_string_field_opt "runtime_blocker_class" keeper with
           | Some blocker ->
               let severity =
                 match blocker with
                 | "runtime_exhausted" | "completion_contract_violation" -> "bad"
                 | _ -> "warn"
               in
               Some
                 (attention_event_json ~severity ~kind:"runtime_blocker"
                    ~summary:
                      (Printf.sprintf "%s is blocked by %s" keeper_name blocker)
                    ~keeper_name ~target_type:"keeper" ~target_id:keeper_name
                    ~recommended_action:"Open the keeper row and inspect the blocker"
                    ~provenance:"execution" ())
           | None when not (keeper_has_goal keeper) ->
               Some
                 (attention_event_json ~severity:"warn" ~kind:"goal_unscoped"
                    ~summary:
                      (Printf.sprintf "%s is active without linked goal context" keeper_name)
                    ~keeper_name ~target_type:"keeper" ~target_id:keeper_name
                    ~recommended_action:"Add a short/mid/long goal or link active goals"
                    ~provenance:"execution" ())
           | None when Option.is_none (json_string_field_opt "tool_audit_at" keeper) ->
               Some
                 (attention_event_json ~severity:"warn" ~kind:"history_gap"
                    ~summary:
                      (Printf.sprintf "%s is missing a recent tool-audit anchor" keeper_name)
                    ~keeper_name ~target_type:"keeper" ~target_id:keeper_name
                    ~recommended_action:"Inspect recent tool use or refresh the keeper snapshot"
                    ~provenance:"execution" ())
           | None -> None)
    |> take_n 8
  in
  ( `Assoc
      [
        ("status", `String overall_status);
        ("score", `Int overall_score);
        ("decision_required_count", `Int (pending_visible + continue_gate_count));
        ("blocking_count", `Int blocking_count);
        ("pillars", `List pillars);
      ],
    `List (take_n 10 (base_events @ keeper_events)) )

let runtime_count_authority_json ~runtime_count ~shell_counts
    ~configured_keepers =
  let live_keepers = json_int_field "keepers" shell_counts ~default:0 in
  let configured_keepers_count =
    match configured_keepers with
    | `Int v -> Some v
    | `Intlit s -> int_of_string_opt s
    | _ -> None
  in
  let configured_minus_live =
    Option.map
      (fun configured -> max 0 (configured - live_keepers))
      configured_keepers_count
  in
  `Assoc
    [
      ("source", `String namespace_truth_source);
      ("authority", `String "root.counts");
      ("configured_authority", `String "root.configured_keepers");
      ( "fallback_policy",
        `String "shell_last_good_only_when_namespace_unavailable" );
      ("shell_arbitration_allowed", `Bool false);
      ("live_total_runtimes", `Int runtime_count);
      ("live_keepers", `Int live_keepers);
      ("configured_keepers", Json_util.int_opt_to_json configured_keepers_count);
      ("configured_minus_live_keepers", Json_util.int_opt_to_json configured_minus_live);
      ( "count_roles",
        `Assoc
          [
            ("root.counts", `String "authoritative_live_snapshot");
            ("root.configured_keepers", `String "authoritative_inventory");
            ("shell", `String "read_model_input");
            ("execution", `String "diagnostic_summary_only");
          ] );
    ]

let compose_namespace_truth_snapshot ~(config : Workspace.config) ~initialized ~shell_json
    ~execution_json ~command_summary_json =
  let generated_at = Masc_domain.now_iso () in
  let pending_confirm_summary = pending_confirm_summary_cached config in
  let top_queue = execution_top_queue execution_json in
  let execution_summary = execution_summary_json execution_json in
  let readiness_json, attention_events_json =
    derive_readiness_and_attention ~execution_json ~execution_summary
      ~pending_confirm_summary
  in
  let command_summary = namespace_truth_command_summary_json command_summary_json in
  let shell_counts = json_assoc_field "counts" shell_json in
  let configured_keepers =
    Option.value ~default:`Null (Json_util.assoc_member_opt "configured_keepers" shell_json)
  in
  let runtime_count =
    json_int_field "total_runtimes" shell_counts
      ~default:
        ( json_int_field "agents" shell_counts ~default:0
        + json_int_field "keepers" shell_counts ~default:0 )
  in
  let focus_json =
    dashboard_namespace_truth_focus_json ~initialized ~runtime_count
      ~top_queue
  in
  let namespace_block =
    `Assoc
      [
        ("status", json_assoc_field "status" shell_json);
        ("counts", json_assoc_field "counts" shell_json);
        ("configured_keepers", configured_keepers);
        ( "runtime_count_authority",
          runtime_count_authority_json ~runtime_count ~shell_counts
            ~configured_keepers );
        ("provenance", `String "truth");
      ]
  in
  `Assoc
    (namespace_truth_metadata_fields ~config ~generated_at
     @ [
         ("generated_at", `String generated_at);
        ("workspace", namespace_block);
        ( "execution",
        `Assoc
          [
            ("summary", execution_summary);
            ("top_queue", top_queue);
            ("provenance", `String "derived");
          ] );
      ("command", command_summary);
      ( "operator",
        `Assoc
          [
            ("pending_confirm_summary", pending_confirm_summary);
            ("provenance", `String "derived");
          ] );
      ("readiness", readiness_json);
      ("attention_events", attention_events_json);
      ("focus", focus_json);
    ])
