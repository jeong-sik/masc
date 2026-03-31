open Yojson.Safe.Util

module GV2 = Council.Governance_v2

type detail_status = [ `OK | `Not_found ]

let option_to_yojson = Json_util.option_to_yojson
let string_opt_json = Json_util.string_opt_to_json
let iso_of_unix = Dashboard_utils.iso_of_unix

let rec take n items =
  match items with
  | [] -> []
  | _ when n <= 0 -> []
  | item :: rest -> item :: take (n - 1) rest

let rec drop n items =
  match items with
  | [] -> []
  | rows when n <= 0 -> rows
  | _ :: rest -> drop (n - 1) rest

let json_string_list values =
  `List (List.map (fun value -> `String value) values)

let truth_summary_of_bundle (bundle : GV2.case_bundle) =
  let petition_count = List.length bundle.GV2.petitions in
  let brief_count = List.length bundle.GV2.case_.GV2.briefs in
  let ref_count =
    bundle.GV2.petitions
    |> List.fold_left
         (fun acc (petition : GV2.petition) ->
           acc + List.length petition.GV2.source_refs)
         0
  in
  Printf.sprintf "petitions %d · briefs %d · refs %d" petition_count brief_count ref_count

let related_agents_of_bundle (bundle : GV2.case_bundle) =
  let petition_agents =
    bundle.GV2.petitions |> List.map (fun (petition : GV2.petition) -> petition.GV2.created_by)
  in
  let brief_agents =
    bundle.GV2.case_.GV2.briefs |> List.map (fun (brief : GV2.case_brief) -> brief.GV2.author)
  in
  List.sort_uniq String.compare (petition_agents @ brief_agents)

let evidence_refs_of_bundle (bundle : GV2.case_bundle) =
  let petition_refs =
    bundle.GV2.petitions |> List.concat_map (fun (petition : GV2.petition) -> petition.GV2.source_refs)
  in
  let brief_refs =
    bundle.GV2.case_.GV2.briefs
    |> List.concat_map (fun (brief : GV2.case_brief) -> brief.GV2.evidence_refs)
  in
  List.sort_uniq String.compare (petition_refs @ brief_refs)

let action_request_json (request : GV2.action_request) =
  `Assoc
    [
      ("action_type", `String request.GV2.action_type);
      ("target_type", string_opt_json request.GV2.target_type);
      ("target_id", string_opt_json request.GV2.target_id);
      ( "payload_preview",
        match request.GV2.payload with
        | Some payload -> payload
        | None -> `Null );
    ]

let recommended_action_json (bundle : GV2.case_bundle) =
  match bundle.GV2.ruling with
  | None -> `Null
  | Some ruling -> (
      match ruling.GV2.recommended_action with
      | None -> `Null
      | Some request ->
          `Assoc
            [
              ("action_kind", `String request.GV2.action_type);
              ("resolved_tool", `Null);
              ("target_type", string_opt_json request.GV2.target_type);
              ("target_id", string_opt_json request.GV2.target_id);
              ("reason", `String ruling.GV2.summary);
              ("payload_preview", match request.GV2.payload with Some payload -> payload | None -> `Null);
            ])

let executed_route_json (bundle : GV2.case_bundle) =
  match bundle.GV2.execution_order with
  | None -> `Null
  | Some order ->
      `Assoc
        [
          ( "action_type",
            match order.GV2.action_request with
            | Some request -> `String request.GV2.action_type
            | None -> `Null );
          ( "delegated_tool",
            match order.GV2.action_request with
            | Some request -> `String request.GV2.action_type
            | None -> `Null );
          ("confirmation_state", `String (GV2.order_status_to_string order.GV2.status));
          ("created_at", `String (iso_of_unix order.GV2.updated_at));
        ]

let guardrail_state_json (bundle : GV2.case_bundle) =
  let requires_human_gate, ready_to_execute =
    match bundle.GV2.execution_order with
    | Some order -> (
        match order.GV2.status with
        | GV2.Needs_human_gate_order -> (true, false)
        | GV2.Queued_auto -> (false, true)
        | GV2.Auto_executed | GV2.Done | GV2.Denied | GV2.Blocked_order -> (false, false))
    | None -> (false, false)
  in
  `Assoc
    [
      ("requires_human_gate", `Bool requires_human_gate);
      ("pending_confirm", `Null);
      ("pending_confirm_token", `Null);
      ("ready_to_execute", `Bool ready_to_execute);
    ]

let linked_task_id_of_bundle (bundle : GV2.case_bundle) =
  match bundle.GV2.execution_order with
  | Some order -> (
      match order.GV2.execution_ref, order.GV2.action_request with
      | Some execution_ref, Some request
        when String.equal (String.lowercase_ascii request.GV2.action_type) "add_task" ->
          Some execution_ref
      | _ -> None)
  | None -> None

let linked_operation_id_of_bundle (bundle : GV2.case_bundle) =
  match bundle.GV2.execution_order with
  | Some order -> (
      match order.GV2.execution_ref, order.GV2.action_request with
      | Some execution_ref, Some request
        when String.equal
               (String.lowercase_ascii request.GV2.action_type)
               "start_operation" ->
          Some execution_ref
      | _ -> None)
  | None -> None

let governance_item_of_bundle (bundle : GV2.case_bundle) =
  let ruling_summary =
    match bundle.GV2.ruling with
    | Some ruling -> Some ruling.GV2.summary
    | None -> None
  in
  let confidence =
    match bundle.GV2.ruling with
    | Some ruling -> Some ruling.GV2.confidence
    | None -> None
  in
  let provenance =
    match bundle.GV2.ruling with
    | Some ruling -> ruling.GV2.provenance
    | None -> "truth"
  in
  let auto_execution_state =
    match bundle.GV2.execution_order with
    | Some order -> GV2.order_status_to_string order.GV2.status
    | None -> (
        match bundle.GV2.ruling with
        | Some ruling -> ruling.GV2.auto_execution_state
        | None -> "pending_ruling")
  in
  `Assoc
    [
      ("kind", `String "case");
      ("id", `String bundle.GV2.case_.GV2.id);
      ("topic", `String bundle.GV2.case_.GV2.title);
      ("status", `String (GV2.case_status_to_string bundle.GV2.case_.GV2.status));
      ("last_activity_at", `String (iso_of_unix bundle.GV2.case_.GV2.updated_at));
      ("truth_summary", `String (truth_summary_of_bundle bundle));
      ("judgment_summary", option_to_yojson (fun value -> `String value) ruling_summary);
      ("confidence", option_to_yojson (fun value -> `Float value) confidence);
      ("related_agents", json_string_list (related_agents_of_bundle bundle));
      ( "context",
        `Assoc
          [
            ("board_post_id", `Null);
            ("task_id", string_opt_json (linked_task_id_of_bundle bundle));
            ("operation_id", string_opt_json (linked_operation_id_of_bundle bundle));
            ("team_session_id", `Null);
          ] );
      ("linked_board_post_id", `Null);
      ("linked_task_id", string_opt_json (linked_task_id_of_bundle bundle));
      ("linked_operation_id", string_opt_json (linked_operation_id_of_bundle bundle));
      ("linked_session_id", `Null);
      ("recommended_action", recommended_action_json bundle);
      ("executed_route", executed_route_json bundle);
      ("guardrail_state", guardrail_state_json bundle);
      ("evidence_refs", json_string_list (evidence_refs_of_bundle bundle));
      ("origin", `String bundle.GV2.case_.GV2.origin);
      ("risk_class", `String (GV2.risk_class_to_string bundle.GV2.case_.GV2.risk_class));
      ("provenance", `String provenance);
      ("auto_execution_state", `String auto_execution_state);
      ("petition_count", `Int (List.length bundle.GV2.petitions));
      ("brief_count", `Int (List.length bundle.GV2.case_.GV2.briefs));
    ]

let activity_of_bundle (bundle : GV2.case_bundle) =
  let petition_events =
    bundle.GV2.petitions
    |> List.map (fun (petition : GV2.petition) ->
           `Assoc
             [
               ("kind", `String "petition_submitted");
               ("item_kind", `String "petition");
               ("item_id", `String petition.GV2.id);
               ("topic", `String petition.GV2.title);
               ("created_at", `String (iso_of_unix petition.GV2.created_at));
               ("summary", `String "Petition submitted");
               ("actor", `String petition.GV2.created_by);
             ])
  in
  let brief_events =
    bundle.GV2.case_.GV2.briefs
    |> List.map (fun (brief : GV2.case_brief) ->
           `Assoc
             [
               ("kind", `String "brief_submitted");
               ("item_kind", `String "brief");
               ("item_id", `String brief.GV2.id);
               ("topic", `String bundle.GV2.case_.GV2.title);
               ("created_at", `String (iso_of_unix brief.GV2.created_at));
               ("summary", `String brief.GV2.summary);
               ("actor", `String brief.GV2.author);
             ])
  in
  let ruling_events =
    match bundle.GV2.ruling with
    | None -> []
    | Some ruling ->
        [
          `Assoc
            [
              ("kind", `String "ruling_issued");
              ("item_kind", `String "ruling");
              ("item_id", `String ruling.GV2.id);
              ("topic", `String bundle.GV2.case_.GV2.title);
              ("created_at", `String (iso_of_unix ruling.GV2.generated_at));
              ("summary", `String ruling.GV2.summary);
              ("actor", `String ruling.GV2.keeper_name);
            ];
        ]
  in
  let order_events =
    match bundle.GV2.execution_order with
    | None -> []
    | Some order ->
        [
          `Assoc
            [
              ("kind", `String "execution_order");
              ("item_kind", `String "execution_order");
              ("item_id", `String order.GV2.id);
              ("topic", `String bundle.GV2.case_.GV2.title);
              ("created_at", `String (iso_of_unix order.GV2.updated_at));
              ( "summary",
                `String
                  (Option.value
                     ~default:(GV2.order_status_to_string order.GV2.status)
                     order.GV2.result_summary) );
              ("actor", string_opt_json order.GV2.actor);
            ];
        ]
  in
  petition_events @ brief_events @ ruling_events @ order_events

let compare_activity left right =
  let left_ts =
    left |> member "created_at" |> to_string_option |> function
    | Some iso -> (try Types.parse_iso8601 iso with Failure _ -> 0.0)
    | None -> 0.0
  in
  let right_ts =
    right |> member "created_at" |> to_string_option |> function
    | Some iso -> (try Types.parse_iso8601 iso with Failure _ -> 0.0)
    | None -> 0.0
  in
  Float.compare right_ts left_ts

let judge_runtime_json base_path =
  let st = Dashboard_governance_judge.runtime_status base_path in
  `Assoc
    [
      ("judge_online", `Bool st.judge_online);
      ("refreshing", `Bool st.refreshing);
      ( "generated_at",
        option_to_yojson (fun s -> `String s) st.generated_at );
      ( "expires_at",
        option_to_yojson (fun s -> `String s) st.expires_at );
      ( "model_used",
        option_to_yojson (fun s -> `String s) st.model_used );
      ("keeper_name", `String st.keeper_name);
      ( "last_error",
        option_to_yojson (fun s -> `String s) st.last_error );
    ]

let factual_snapshot_json ~base_path =
  let cases = GV2.list_cases ~include_test:true base_path in
  let bundles =
    cases
    |> List.filter_map (fun (case_ : GV2.case_record) ->
           match GV2.get_case_bundle base_path case_.GV2.id with
           | Ok bundle -> Some bundle
           | Error _ -> None)
  in
  let items = bundles |> List.map governance_item_of_bundle in
  let activity =
    bundles |> List.concat_map activity_of_bundle |> List.sort compare_activity |> take 50
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("items", `List items);
      ("activity", `List activity);
    ]

let dashboard_json ~base_path ~limit ~offset ~status_filter =
  let cases = GV2.list_cases ?status_filter base_path |> drop offset |> take limit in
  let bundles =
    cases
    |> List.filter_map (fun (case_ : GV2.case_record) ->
           match GV2.get_case_bundle base_path case_.GV2.id with
           | Ok bundle -> Some bundle
           | Error _ -> None)
  in
  let items = List.map governance_item_of_bundle bundles in
  let activity =
    bundles |> List.concat_map activity_of_bundle |> List.sort compare_activity |> take 50
  in
  let pending_actions =
    bundles
    |> List.filter_map (fun bundle ->
           match bundle.GV2.execution_order with
           | Some order when order.GV2.status = GV2.Needs_human_gate_order ->
               Some
                 (`Assoc
                   [
                     ("confirm_token", `String bundle.GV2.case_.GV2.id);
                     ("action_type", `String "human_gate");
                     ("target_type", `String "case");
                     ("target_id", `String bundle.GV2.case_.GV2.id);
                     ( "reason",
                       `String
                         (match bundle.GV2.ruling with
                         | Some ruling -> ruling.GV2.summary
                         | None -> "Human gate required") );
                     ("created_at", `String (iso_of_unix order.GV2.created_at));
                   ])
           | _ -> None)
  in
  let count_by status =
    bundles
    |> List.filter (fun bundle -> bundle.GV2.case_.GV2.status = status)
    |> List.length
  in
  let ready_auto_execute = count_by GV2.Ready_auto_execute in
  let cases_open =
    count_by GV2.Pending_ruling + ready_auto_execute + count_by GV2.Needs_human_gate
  in
  let now_ts = Time_compat.now () in
  let age_of_ts ts =
    let delta = now_ts -. ts in
    if Float.is_nan delta || Float.is_infinite delta then `Null
    else `Int (int_of_float (max 0.0 (min delta (float_of_int max_int))))
  in
  let oldest_open_case_ts_opt =
    bundles
    |> List.filter (fun bundle ->
           match bundle.GV2.case_.GV2.status with
           | GV2.Pending_ruling | GV2.Ready_auto_execute | GV2.Needs_human_gate -> true
           | GV2.Executed | GV2.Blocked | GV2.Closed -> false)
    |> List.fold_left
         (fun acc bundle ->
           let ts = bundle.GV2.case_.GV2.updated_at in
           match acc with
           | None -> Some ts
           | Some prev -> Some (min prev ts))
         None
  in
  let latest_case_ts_opt =
    bundles
    |> List.fold_left
         (fun acc bundle ->
           let ts = bundle.GV2.case_.GV2.updated_at in
           match acc with
           | None -> Some ts
           | Some prev -> Some (max prev ts))
         None
  in
  let judge = judge_runtime_json base_path in
  let judgments =
    Dashboard_governance_judge.fresh_judgments_json ~base_path ~limit:20
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("cases_open", `Int cases_open);
            ("pending_ruling", `Int (count_by GV2.Pending_ruling));
            ("ready_auto_execute", `Int ready_auto_execute);
            ("needs_human_gate", `Int (count_by GV2.Needs_human_gate));
            ("executed", `Int (count_by GV2.Executed));
            ("blocked", `Int (count_by GV2.Blocked));
            ("ready_to_execute", `Int ready_auto_execute);
            ( "oldest_open_case_age_s",
              match oldest_open_case_ts_opt with
              | Some ts -> age_of_ts ts
              | None -> `Null );
            ( "last_activity_age_s",
              match latest_case_ts_opt with
              | Some ts -> age_of_ts ts
              | None -> `Null );
            ("judge_online", judge |> member "judge_online");
            ("judge_last_seen_at", judge |> member "generated_at");
          ] );
      ("items", `List items);
      ("activity", `List activity);
      ("judge", judge);
      ("judgments", `List judgments);
      ("pending_actions", `List pending_actions);
      ("cases", `List items);
    ]

let cases_json ~base_path ~limit ~offset ~status_filter ~include_test =
  let cases =
    GV2.list_cases ?status_filter ~include_test base_path |> drop offset |> take limit
  in
  let items =
    cases
    |> List.map (fun (case_ : GV2.case_record) ->
           `Assoc
             [
               ("id", `String case_.GV2.id);
               ("title", `String case_.GV2.title);
               ("origin", `String case_.GV2.origin);
               ("risk_class", `String (GV2.risk_class_to_string case_.GV2.risk_class));
               ("status", `String (GV2.case_status_to_string case_.GV2.status));
               ("updated_at", `String (iso_of_unix case_.GV2.updated_at));
             ])
  in
  `Assoc
    [
      ("cases", `List items);
      ("count", `Int (List.length items));
      ("limit", `Int limit);
      ("offset", `Int offset);
    ]

let rec case_detail_json ~base_path ~case_id : detail_status * Yojson.Safe.t =
  match GV2.get_case_bundle base_path case_id with
  | Error _ -> (`Not_found, `Assoc [ ("error", `String "Case not found") ])
  | Ok bundle ->
      ( `OK,
        `Assoc
          [
            ("case", case_json bundle.GV2.case_);
            ("petitions", `List (List.map petition_json bundle.GV2.petitions));
            ("briefs", `List (List.map brief_json bundle.GV2.case_.GV2.briefs));
            ("ruling", option_to_yojson ruling_json bundle.GV2.ruling);
            ("execution_order", option_to_yojson execution_order_json bundle.GV2.execution_order);
          ] )

and petition_json (petition : GV2.petition) =
  `Assoc
    [
      ("id", `String petition.GV2.id);
      ("case_id", `String petition.GV2.case_id);
      ("title", `String petition.GV2.title);
      ("origin", `String petition.GV2.origin);
      ("subject_type", `String petition.GV2.subject_type);
      ("risk_class", `String (GV2.risk_class_to_string petition.GV2.risk_class));
      ("source_refs", json_string_list petition.GV2.source_refs);
      ("created_by", `String petition.GV2.created_by);
      ("created_at", `String (iso_of_unix petition.GV2.created_at));
      ( "requested_action",
        match petition.GV2.requested_action with
        | Some request -> action_request_json request
        | None -> `Null );
    ]

and brief_json (brief : GV2.case_brief) =
  `Assoc
    [
      ("id", `String brief.GV2.id);
      ("author", `String brief.GV2.author);
      ("stance", `String (GV2.brief_stance_to_string brief.GV2.stance));
      ("summary", `String brief.GV2.summary);
      ("evidence_refs", json_string_list brief.GV2.evidence_refs);
      ("created_at", `String (iso_of_unix brief.GV2.created_at));
    ]

and case_json (case_ : GV2.case_record) =
  `Assoc
    [
      ("id", `String case_.GV2.id);
      ("petition_ids", json_string_list case_.GV2.petition_ids);
      ("title", `String case_.GV2.title);
      ("origin", `String case_.GV2.origin);
      ("subject_type", `String case_.GV2.subject_type);
      ("risk_class", `String (GV2.risk_class_to_string case_.GV2.risk_class));
      ("status", `String (GV2.case_status_to_string case_.GV2.status));
      ("created_at", `String (iso_of_unix case_.GV2.created_at));
      ("updated_at", `String (iso_of_unix case_.GV2.updated_at));
      ("source_refs", json_string_list case_.GV2.source_refs);
      ( "requested_action",
        match case_.GV2.requested_action with
        | Some request -> action_request_json request
        | None -> `Null );
    ]

and ruling_json (ruling : GV2.ruling) =
  `Assoc
    [
      ("id", `String ruling.GV2.id);
      ("case_id", `String ruling.GV2.case_id);
      ("status", `String ruling.GV2.status);
      ("summary", `String ruling.GV2.summary);
      ("confidence", `Float ruling.GV2.confidence);
      ("provenance", `String ruling.GV2.provenance);
      ("generated_at", `String (iso_of_unix ruling.GV2.generated_at));
      ( "expires_at",
        match ruling.GV2.expires_at with
        | Some value -> `String (iso_of_unix value)
        | None -> `Null );
      ("keeper_name", `String ruling.GV2.keeper_name);
      ("model_used", string_opt_json ruling.GV2.model_used);
      ("risk_class", `String (GV2.risk_class_to_string ruling.GV2.risk_class));
      ("evidence_refs", json_string_list ruling.GV2.evidence_refs);
      ("auto_execution_state", `String ruling.GV2.auto_execution_state);
      ( "recommended_action",
        match ruling.GV2.recommended_action with
        | Some request -> action_request_json request
        | None -> `Null );
    ]

and execution_order_json (order : GV2.execution_order) =
  `Assoc
    [
      ("id", `String order.GV2.id);
      ("case_id", `String order.GV2.case_id);
      ("status", `String (GV2.order_status_to_string order.GV2.status));
      ("risk_class", `String (GV2.risk_class_to_string order.GV2.risk_class));
      ("created_at", `String (iso_of_unix order.GV2.created_at));
      ("updated_at", `String (iso_of_unix order.GV2.updated_at));
      ("execution_ref", string_opt_json order.GV2.execution_ref);
      ("result_summary", string_opt_json order.GV2.result_summary);
      ("actor", string_opt_json order.GV2.actor);
      ( "action_request",
        match order.GV2.action_request with
        | Some request -> action_request_json request
        | None -> `Null );
    ]
