open Yojson.Safe.Util

type detail_status = [ `OK | `Not_found ]

let option_to_yojson = Json_util.option_to_yojson
let iso_of_unix = Dashboard_utils.iso_of_unix
let parse_iso_opt = Dashboard_utils.parse_iso_opt

let string_member json key = json |> member key |> to_string_option

let bool_member json key =
  match json |> member key with
  | `Bool value -> Some value
  | _ -> None

let float_member json key =
  match json |> member key with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | _ -> None

let string_list_member json key =
  match json |> member key with
  | `List items ->
      items
      |> List.filter_map (function
             | `String value ->
                 let trimmed = String.trim value in
                 if trimmed = "" then None else Some trimmed
             | _ -> None)
  | _ -> []

let target_kind judgment =
  string_member judgment "target_kind" |> Option.value ~default:"case"

let target_id judgment =
  string_member judgment "target_id" |> Option.value ~default:""

let summary_text judgment =
  string_member judgment "summary" |> Option.value ~default:""

let guardrail_state judgment = judgment |> member "guardrail_state"
let recommended_action judgment = judgment |> member "recommended_action"
let executed_route judgment = judgment |> member "executed_route"

let derived_status judgment =
  let normalized_status =
    string_member judgment "status"
    |> Option.map (fun value -> String.lowercase_ascii (String.trim value))
  in
  match normalized_status with
  | Some ("blocked" | "denied" | "closed") -> "blocked"
  | Some ("executed" | "done" | "auto_executed") -> "executed"
  | Some "needs_human_gate" -> "needs_human_gate"
  | Some ("ready_auto_execute" | "queued_auto") -> "ready_auto_execute"
  | _ ->
      if executed_route judgment <> `Null then "executed"
      else if bool_member (guardrail_state judgment) "requires_human_gate" = Some true then
        "needs_human_gate"
      else if bool_member (guardrail_state judgment) "ready_to_execute" = Some true then
        "ready_auto_execute"
      else
        "pending_ruling"

let status_matches ~status_filter status =
  match status_filter with
  | None -> true
  | Some raw_filter ->
      let filter = String.lowercase_ascii (String.trim raw_filter) in
      let normalized_status = String.lowercase_ascii (String.trim status) in
      match filter with
      | "" | "all" -> true
      | "open" ->
          normalized_status <> "executed"
          && normalized_status <> "blocked"
          && normalized_status <> "closed"
      | "blocked" -> normalized_status = "blocked" || normalized_status = "closed"
      | _ -> normalized_status = filter

let context_json ~target_kind ~target_id =
  let fields =
    match String.lowercase_ascii (String.trim target_kind) with
    | "task" -> [ ("task_id", `String target_id) ]
    | "board_post" | "post" | "board" -> [ ("board_post_id", `String target_id) ]
    | "operation" -> [ ("operation_id", `String target_id) ]
    | "team_session" | "session" -> [ ("team_session_id", `String target_id) ]
    | _ -> []
  in
  `Assoc fields

let linked_field_values ~target_kind ~target_id =
  match String.lowercase_ascii (String.trim target_kind) with
  | "task" -> (`Null, `String target_id, `Null, `Null)
  | "board_post" | "post" | "board" -> (`String target_id, `Null, `Null, `Null)
  | "operation" -> (`Null, `Null, `String target_id, `Null)
  | "team_session" | "session" -> (`Null, `Null, `Null, `String target_id)
  | _ -> (`Null, `Null, `Null, `Null)

let topic_of_judgment judgment =
  let target_kind = target_kind judgment in
  let target_id = target_id judgment in
  match string_member (recommended_action judgment) "target_id" with
  | Some value when String.trim value <> "" -> String.trim value
  | _ when target_id <> "" -> Printf.sprintf "%s:%s" target_kind target_id
  | _ -> summary_text judgment

let pending_action_json judgment =
  match string_member (guardrail_state judgment) "pending_confirm_token" with
  | None -> None
  | Some confirm_token ->
      let target_kind = target_kind judgment in
      let target_id = target_id judgment in
      Some
        (`Assoc
          [
            ("confirm_token", `String confirm_token);
            ( "actor",
              option_to_yojson (fun value -> `String value)
                (string_member judgment "keeper_name") );
            ( "action_type",
              option_to_yojson (fun value -> `String value)
                (string_member (recommended_action judgment) "action_kind") );
            ("target_type", `String target_kind);
            ("target_id", `String target_id);
            ( "delegated_tool",
              option_to_yojson (fun value -> `String value)
                (string_member (recommended_action judgment) "resolved_tool") );
            ( "created_at",
              option_to_yojson (fun value -> `String value)
                (string_member judgment "generated_at") );
            ("preview", recommended_action judgment |> member "payload_preview");
          ])

let decision_item_json judgment =
  let target_kind = target_kind judgment in
  let target_id = target_id judgment in
  let linked_board_post_id, linked_task_id, linked_operation_id, linked_session_id =
    linked_field_values ~target_kind ~target_id
  in
  let evidence_refs = string_list_member judgment "evidence_refs" in
  `Assoc
    [
      ("kind", `String "case");
      ("id", `String target_id);
      ("topic", `String (topic_of_judgment judgment));
      ("status", `String (derived_status judgment));
      ("origin", `String "governance-judge");
      ("subject_type", `String target_kind);
      ("provenance", `String "governance_judge");
      ("auto_execution_state", `Null);
      ("petition_count", `Int 0);
      ("brief_count", `Int 0);
      ( "last_activity_at",
        option_to_yojson (fun value -> `String value)
          (string_member judgment "generated_at") );
      ("truth_summary", `String (summary_text judgment));
      ("judgment_summary", `String (summary_text judgment));
      ( "confidence",
        match float_member judgment "confidence" with
        | Some value -> `Float value
        | None -> `Null );
      ("related_agents", `List []);
      ("context", context_json ~target_kind ~target_id);
      ("linked_board_post_id", linked_board_post_id);
      ("linked_task_id", linked_task_id);
      ("linked_operation_id", linked_operation_id);
      ("linked_session_id", linked_session_id);
      ("recommended_action", recommended_action judgment);
      ("executed_route", executed_route judgment);
      ("guardrail_state", guardrail_state judgment);
      ("evidence_refs", `List (List.map (fun value -> `String value) evidence_refs));
    ]

let execution_order_json judgment =
  let case_id = target_id judgment in
  let status =
    match derived_status judgment with
    | "needs_human_gate" -> Some "needs_human_gate"
    | "ready_auto_execute" -> Some "queued_auto"
    | "executed" -> Some "done"
    | "blocked" -> Some "blocked"
    | _ -> None
  in
  match (status, recommended_action judgment, executed_route judgment) with
  | None, `Null, `Null -> None
  | _ ->
      Some
        (`Assoc
          [
            ("id", `String ("order:" ^ case_id));
            ("case_id", `String case_id);
            ( "status",
              `String (Option.value status ~default:"none") );
            ("risk_class", `Null);
            ("action_request", recommended_action judgment);
            ( "created_at",
              option_to_yojson (fun value -> `String value)
                (string_member judgment "generated_at") );
            ( "updated_at",
              option_to_yojson (fun value -> `String value)
                (string_member judgment "generated_at") );
            ("execution_ref", executed_route judgment |> member "execution_ref");
            ("result_summary", executed_route judgment |> member "result_summary");
            ("actor", executed_route judgment |> member "actor");
          ])

let case_bundle_json judgment =
  let case_id = target_id judgment in
  let evidence_refs = string_list_member judgment "evidence_refs" in
  let target_kind = target_kind judgment in
  `Assoc
    [
      ( "case",
        `Assoc
          [
            ("id", `String case_id);
            ("petition_ids", `List []);
            ("title", `String (topic_of_judgment judgment));
            ("origin", `String "governance-judge");
            ("subject_type", `String target_kind);
            ("risk_class", `Null);
            ("status", `String (derived_status judgment));
            ( "created_at",
              option_to_yojson (fun value -> `String value)
                (string_member judgment "generated_at") );
            ( "updated_at",
              option_to_yojson (fun value -> `String value)
                (string_member judgment "generated_at") );
            ("source_refs", `List (List.map (fun value -> `String value) evidence_refs));
            ("briefs", `List []);
          ] );
      ("petitions", `List []);
      ("ruling", judgment);
      ( "execution_order",
        option_to_yojson (fun value -> value) (execution_order_json judgment) );
    ]

let event_json ~index judgment =
  `Assoc
    [
      ("kind", `String "ruling_issued");
      ("item_kind", `String (target_kind judgment));
      ("item_id", `String (target_id judgment));
      ("topic", `String (topic_of_judgment judgment));
      ( "created_at",
        option_to_yojson (fun value -> `String value)
          (string_member judgment "generated_at") );
      ("summary", `String (summary_text judgment));
      ( "actor",
        option_to_yojson (fun value -> `String value)
          (string_member judgment "keeper_name") );
      ("index", `Int index);
      ("decision", `String (derived_status judgment));
    ]

let sort_judgments judgments =
  List.sort
    (fun a b ->
      let at = string_member a "generated_at" |> parse_iso_opt |> Option.value ~default:0.0 in
      let bt = string_member b "generated_at" |> parse_iso_opt |> Option.value ~default:0.0 in
      Float.compare bt at)
    judgments

let all_judgments ~base_path =
  Dashboard_governance_judge.fresh_judgments_json ~base_path ~limit:5000 |> sort_judgments

let filtered_judgments ~base_path ~status_filter =
  all_judgments ~base_path
  |> List.filter (fun judgment -> status_matches ~status_filter (derived_status judgment))

let paged list ~limit ~offset =
  list |> List.filteri (fun index _ -> index >= offset && index < offset + limit)

let summary_json ~judge ~judgments =
  let now = Unix.gettimeofday () in
  let statuses = List.map derived_status judgments in
  let is_open status =
    let normalized = String.lowercase_ascii (String.trim status) in
    normalized <> "executed" && normalized <> "blocked" && normalized <> "closed"
  in
  let ages =
    judgments
    |> List.filter_map (fun judgment ->
           string_member judgment "generated_at"
           |> parse_iso_opt
           |> Option.map (fun ts -> now -. ts))
  in
  let open_ages =
    List.combine judgments statuses
    |> List.filter_map (fun (judgment, status) ->
           if is_open status then
             string_member judgment "generated_at"
             |> parse_iso_opt
             |> Option.map (fun ts -> now -. ts)
           else
             None)
  in
  `Assoc
    [
      ("cases_open", `Int (List.length (List.filter is_open statuses)));
      ( "pending_ruling",
        `Int
          (List.length
             (List.filter (fun status -> String.equal status "pending_ruling") statuses)) );
      ( "ready_auto_execute",
        `Int
          (List.length
             (List.filter (fun status -> String.equal status "ready_auto_execute") statuses)) );
      ( "needs_human_gate",
        `Int
          (List.length
             (List.filter (fun status -> String.equal status "needs_human_gate") statuses)) );
      ( "executed",
        `Int
          (List.length
             (List.filter (fun status -> String.equal status "executed") statuses)) );
      ( "blocked",
        `Int
          (List.length
             (List.filter (fun status -> String.equal status "blocked") statuses)) );
      ( "ready_to_execute",
        `Int
          (List.length
             (List.filter
                (fun judgment ->
                  bool_member (guardrail_state judgment) "ready_to_execute" = Some true)
                judgments)) );
      ( "oldest_open_case_age_s",
        match List.sort Float.compare open_ages |> List.rev with
        | age :: _ -> `Float age
        | [] -> `Null );
      ( "last_activity_age_s",
        match List.sort Float.compare ages with
        | age :: _ -> `Float age
        | [] -> `Null );
      ("judge_online", `Bool judge.judge_online);
      ( "judge_last_seen_at",
        option_to_yojson (fun value -> `String value) judge.generated_at );
    ]

let factual_snapshot_json ~base_path =
  let judgments = all_judgments ~base_path in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("items", `List (List.map decision_item_json judgments));
      ("activity", `List (List.mapi (fun index judgment -> event_json ~index judgment) judgments));
      ( "note",
        `String
          (if judgments = [] then
             "Governance case tracking is currently empty."
           else
             "Governance snapshot derived from recent judge output.") );
    ]

let dashboard_json ~base_path ~limit ~offset ~status_filter =
  let judgments = filtered_judgments ~base_path ~status_filter in
  let judge = Dashboard_governance_judge.runtime_status base_path in
  let page = paged judgments ~limit ~offset in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("summary", summary_json ~judge ~judgments);
      ("items", `List (List.map decision_item_json page));
      ("activity", `List (List.mapi (fun index judgment -> event_json ~index judgment) page));
      ( "judge",
        `Assoc
          [
            ("judge_online", `Bool judge.judge_online);
            ("refreshing", `Bool judge.refreshing);
            ("generated_at", option_to_yojson (fun value -> `String value) judge.generated_at);
            ("expires_at", option_to_yojson (fun value -> `String value) judge.expires_at);
            ("model_used", option_to_yojson (fun value -> `String value) judge.model_used);
            ("keeper_name", `String judge.keeper_name);
            ("last_error", option_to_yojson (fun value -> `String value) judge.last_error);
          ] );
      ("judgments", `List page);
      ("pending_actions", `List (List.filter_map pending_action_json page));
      ("cases", `List (List.map case_bundle_json page));
    ]

let cases_json ~base_path ~limit ~offset ~status_filter ~include_test:_ =
  let filtered = filtered_judgments ~base_path ~status_filter in
  let judgments = filtered |> paged ~limit ~offset in
  `Assoc
    [
      ("cases", `List (List.map case_bundle_json judgments));
      ("count", `Int (List.length filtered));
      ("limit", `Int limit);
      ("offset", `Int offset);
    ]

let case_detail_json ~base_path ~case_id =
  match
    all_judgments ~base_path
    |> List.find_opt (fun judgment -> String.equal (target_id judgment) case_id)
  with
  | Some judgment -> (`OK, case_bundle_json judgment)
  | None -> (`Not_found, `Assoc [ ("error", `String "Governance case tracking unavailable") ])
