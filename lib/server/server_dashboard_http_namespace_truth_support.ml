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

let _last_good_pending_confirm_summary : Yojson.Safe.t Atomic.t =
  Atomic.make pending_confirm_summary_empty_json

let pending_confirm_summary_cached (config : Coord.config) =
  let key = Printf.sprintf "pending_confirm_summary:%s" config.base_path in
  let fallback = Atomic.get _last_good_pending_confirm_summary in
  let compute () =
    let json = Operator_control.pending_confirm_summary_json config in
    Atomic.set _last_good_pending_confirm_summary json;
    json
  in
  if Option.is_some (Eio_context.get_switch_opt ()) then
    Dashboard_cache.seed_stale_if_missing key
      ~stale_for:pending_confirm_summary_stale_for fallback;
  let result = Dashboard_cache.get_or_compute key ~ttl:pending_confirm_summary_ttl compute in
  if result = `Null then fallback else result

let dashboard_namespace_truth_focus_json ~initialized ~runtime_count
    ~operator_digest_json ~top_queue =
  let recommendation_summary =
    json_assoc_field "recommendation_summary" operator_digest_json
  in
  let attention_summary =
    json_assoc_field "attention_summary" operator_digest_json
  in
  let focus_of_recommendation top_action provenance =
    `Assoc
      [
        ("label", `String "운영 권고");
        ("reason", Yojson.Safe.Util.member "reason" top_action);
        ("source", `String "operator");
        ("provenance", `String provenance);
        ("target_kind", `String "action");
        ("target_id", Yojson.Safe.Util.member "target_id" top_action);
        ("suggested_tab", `String "intervene");
        ("suggested_surface", `Null);
        ( "suggested_params",
          `Assoc
            [
              ("action_type", Yojson.Safe.Util.member "action_type" top_action);
              ("target_type", Yojson.Safe.Util.member "target_type" top_action);
              ("target_id", Yojson.Safe.Util.member "target_id" top_action);
            ] );
      ]
  in
  let focus_of_attention top_item provenance =
    let target_type = json_string_field_opt "target_type" top_item in
    let target_id = json_string_field_opt "target_id" top_item in
  let source, target_kind, suggested_tab, suggested_surface, suggested_params =
      match target_type with
      | Some "room_meta_cognition" | Some "namespace_meta_cognition" ->
          ( "meta_cognition",
            "meta_cognition",
            "overview",
            None,
            `Assoc [] )
      | _ ->
          ( "operator",
            "attention",
            "intervene",
            None,
            `Assoc
              (List.filter_map
                 (fun (key, value_opt) ->
                   Option.map (fun value -> (key, `String value)) value_opt)
                 [ ("target_type", target_type); ("target_id", target_id) ]) )
    in
    `Assoc
      [
        ("label", `String "주의 필요");
        ( "reason",
          match json_string_field_opt "summary" top_item with
          | Some summary -> `String summary
          | None -> `String "Operator attention item requires follow-up." );
        ("source", `String source);
        ("provenance", `String provenance);
        ("target_kind", `String target_kind);
        ( "target_id",
          match target_id with
          | Some value -> `String value
          | None -> `Null );
        ("suggested_tab", `String suggested_tab);
        ( "suggested_surface",
          match suggested_surface with
          | Some value -> `String value
          | None -> `Null );
        ("suggested_params", suggested_params);
      ]
  in
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
        ( "target_id",
          match target_id with
          | Some value -> `String value
          | None -> `Null );
        ("suggested_tab", `String suggested_tab);
        ( "suggested_surface",
          match suggested_surface with
          | Some value -> `String value
          | None -> `Null );
        ("suggested_params", suggested_params);
      ]
  in
  match json_record_field "top_action" recommendation_summary with
  | Some top_action ->
      let provenance =
        Option.value
          ~default:"fallback"
          (json_string_field_opt "provenance" recommendation_summary)
      in
      focus_of_recommendation top_action provenance
  | None -> (
      match json_record_field "top_item" attention_summary with
      | Some top_item ->
          let provenance =
            Option.value
              ~default:"derived"
              (json_string_field_opt "provenance" attention_summary)
          in
          focus_of_attention top_item provenance
      | None -> (
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
                    "No agents or keepers joined yet; namespace is idle.",
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
                ]))

let take_n n lst =
  if List.length lst <= n then lst else List.filteri (fun i _ -> i < n) lst

let severity_of_meta_salience = function
  | Meta_cognition.Operator_tension -> "bad"
  | Meta_cognition.Contested_belief
  | Meta_cognition.Operator_desire
  | Meta_cognition.Stagnant_room -> "warn"
  | Meta_cognition.Stable -> "info"

let derived_meta_attention_item ~meta_cognition_json
    (interpretation : Meta_cognition.interpretation) =
  match interpretation.primary_salience with
  | Meta_cognition.Stable -> None
  | primary_salience ->
      Some
        (`Assoc
           [
             ("kind", `String "namespace_meta_cognition");
             ("severity", `String (severity_of_meta_salience primary_salience));
             ("summary", `String interpretation.reason);
             ("target_type", `String "namespace_meta_cognition");
             ( "target_id",
               match interpretation.target_id with
               | Some value -> `String value
               | None -> `String "namespace:default" );
             ("actor", `String "namespace");
             ( "evidence",
               `Assoc
                 [
                   ("summary", meta_cognition_json);
                   ( "interpretation",
                     Meta_cognition.interpretation_to_json interpretation );
                 ] );
           ])

let derived_operator_digest_json (config : Coord.config) _execution_json
    meta_cognition_json meta_interpretation =
  let meta_attention =
    Option.bind meta_interpretation
      (derived_meta_attention_item ~meta_cognition_json)
  in
  let health = if Option.is_some meta_attention then "warn" else "ok" in
  let attention_count = if Option.is_some meta_attention then 1 else 0 in
  let warn_count =
    match meta_attention with
    | Some item ->
        if json_string_field_opt "severity" item = Some "bad" then 0 else 1
    | None -> 0
  in
  let bad_count =
    match meta_attention with
    | Some item ->
        if json_string_field_opt "severity" item = Some "bad" then 1 else 0
    | None -> 0
  in
  `Assoc
    [
      ("health", `String health);
      ( "attention_summary",
        `Assoc
          [
            ("count", `Int attention_count);
            ("bad_count", `Int bad_count);
            ("warn_count", `Int warn_count);
            ( "top_item",
              match meta_attention with
              | Some item -> item
              | None -> `Null );
            ("provenance", `String "derived");
          ] );
      ( "recommendation_summary",
        `Assoc [ ("count", `Int 0); ("provenance", `String "derived") ] );
      ("pending_confirm_summary", pending_confirm_summary_cached config);
    ]

let execution_top_queue execution_json =
  match Yojson.Safe.Util.member "execution_queue" execution_json with
  | `List (head :: _) -> head
  | _ -> `Null

let execution_summary_json execution_json =
  let execution_queue =
    match Yojson.Safe.Util.member "execution_queue" execution_json with
    | `List items -> items
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
  match Yojson.Safe.Util.member "blocked_sessions" existing with
  | `Int _ | `Intlit _ -> existing
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

let compose_namespace_truth_snapshot ~(config : Coord.config) ~initialized ~shell_json
    ~execution_json ~command_summary_json =
  let meta_cognition_summary = json_assoc_field "meta_cognition" shell_json in
  let meta_summary_input, meta_interpretation =
    match Meta_cognition.parse_summary meta_cognition_summary with
    | Ok summary_input ->
        (Some summary_input, Some (Meta_cognition.interpret summary_input))
    | Error err ->
        Log.Dashboard.debug
          "project-snapshot meta-cognition summary parse skipped: %s" err;
        (None, None)
  in
  let meta_cognition_latest_digest =
    Meta_cognition.latest_digest_json ?summary:meta_summary_input ()
  in
  let operator_digest_json =
    derived_operator_digest_json config execution_json meta_cognition_summary
      meta_interpretation
  in
  let top_queue = execution_top_queue execution_json in
  let execution_summary = execution_summary_json execution_json in
  let command_summary = namespace_truth_command_summary_json command_summary_json in
  let shell_counts = json_assoc_field "counts" shell_json in
  let configured_keepers =
    Yojson.Safe.Util.member "configured_keepers" shell_json
  in
  let runtime_count =
    json_int_field "total_runtimes" shell_counts
      ~default:
        ( json_int_field "agents" shell_counts ~default:0
        + json_int_field "keepers" shell_counts ~default:0 )
  in
  let focus_json =
    dashboard_namespace_truth_focus_json ~initialized ~runtime_count
      ~operator_digest_json ~top_queue
  in
  let namespace_block =
    `Assoc
      [
        ("status", json_assoc_field "status" shell_json);
        ("counts", json_assoc_field "counts" shell_json);
        ("configured_keepers", configured_keepers);
        ("provenance", `String "truth");
      ]
  in
  `Assoc
      [
        ("generated_at", `String (Types.now_iso ()));
        ("root", namespace_block);
        ( "execution",
        `Assoc
          [
            ("summary", execution_summary);
            ("top_queue", top_queue);
            ("provenance", `String "derived");
          ] );
      ( "meta_cognition",
        `Assoc
          [
            ("summary", meta_cognition_summary);
            ( "interpretation",
              match meta_interpretation with
              | Some interpretation ->
                  Meta_cognition.interpretation_to_json interpretation
              | None -> `Null );
            ("latest_digest", meta_cognition_latest_digest);
            ("provenance", `String "shell");
          ] );
      ("command", command_summary);
      ( "operator",
        `Assoc
          [
            ("health", Yojson.Safe.Util.member "health" operator_digest_json);
            ("attention_summary", json_assoc_field "attention_summary" operator_digest_json);
            ( "recommendation_summary",
              json_assoc_field "recommendation_summary" operator_digest_json );
            ( "pending_confirm_summary",
              json_assoc_field "pending_confirm_summary" operator_digest_json );
            ("provenance", `String "derived");
          ] );
      ("focus", focus_json);
    ]
