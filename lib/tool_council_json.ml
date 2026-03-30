(** JSON serializers for Governance V2 types.
    Pure functions, no state or side-effects.
    Extracted from tool_council.ml to reduce file size. *)

module GV2 = Council.Governance_v2

let json_string_list values =
  `List (List.map (fun value -> `String value) values)

let string_opt_json = Json_util.string_opt_to_json

let action_request_json (request : GV2.action_request) =
  `Assoc
    [
      ("action_type", `String request.GV2.action_type);
      ("target_type", string_opt_json request.GV2.target_type);
      ("target_id", string_opt_json request.GV2.target_id);
      ( "payload",
        match request.GV2.payload with
        | Some payload -> payload
        | None -> `Null );
    ]

let risk_class_json value =
  `String (GV2.risk_class_to_string value)

let stance_json value =
  `String (GV2.brief_stance_to_string value)

let case_status_json value =
  `String (GV2.case_status_to_string value)

let order_status_json value =
  `String (GV2.order_status_to_string value)

let petition_json (petition : GV2.petition) =
  `Assoc
    [
      ("id", `String petition.id);
      ("case_id", `String petition.case_id);
      ("title", `String petition.GV2.title);
      ("origin", `String petition.GV2.origin);
      ("subject_type", `String petition.GV2.subject_type);
      ("risk_class", risk_class_json petition.GV2.risk_class);
      ( "requested_action",
        match petition.GV2.requested_action with
        | Some request -> action_request_json request
        | None -> `Null );
      ("source_refs", json_string_list petition.GV2.source_refs);
      ("created_by", `String petition.GV2.created_by);
      ("created_at", `String (Dashboard_utils.iso_of_unix petition.GV2.created_at));
    ]

let brief_json (brief : GV2.case_brief) =
  `Assoc
    [
      ("id", `String brief.id);
      ("author", `String brief.author);
      ("stance", stance_json brief.GV2.stance);
      ("summary", `String brief.GV2.summary);
      ("evidence_refs", json_string_list brief.GV2.evidence_refs);
      ("created_at", `String (Dashboard_utils.iso_of_unix brief.created_at));
    ]

let case_json (case_ : GV2.case_record) =
  `Assoc
    [
      ("id", `String case_.id);
      ("petition_ids", json_string_list case_.petition_ids);
      ("title", `String case_.title);
      ("origin", `String case_.origin);
      ("subject_type", `String case_.subject_type);
      ("risk_class", risk_class_json case_.GV2.risk_class);
      ("status", case_status_json case_.GV2.status);
      ("created_at", `String (Dashboard_utils.iso_of_unix case_.created_at));
      ("updated_at", `String (Dashboard_utils.iso_of_unix case_.updated_at));
      ( "requested_action",
        match case_.GV2.requested_action with
        | Some request -> action_request_json request
        | None -> `Null );
      ("source_refs", json_string_list case_.GV2.source_refs);
      ("briefs", `List (List.map brief_json case_.GV2.briefs));
    ]

let ruling_json (ruling : GV2.ruling) =
  `Assoc
    [
      ("id", `String ruling.id);
      ("case_id", `String ruling.case_id);
      ("status", `String ruling.GV2.status);
      ("summary", `String ruling.GV2.summary);
      ("confidence", `Float ruling.GV2.confidence);
      ("provenance", `String ruling.GV2.provenance);
      ("generated_at", `String (Dashboard_utils.iso_of_unix ruling.GV2.generated_at));
      ( "expires_at",
        match ruling.GV2.expires_at with
        | Some value -> `String (Dashboard_utils.iso_of_unix value)
        | None -> `Null );
      ("keeper_name", `String ruling.GV2.keeper_name);
      ("model_used", string_opt_json ruling.GV2.model_used);
      ("risk_class", risk_class_json ruling.GV2.risk_class);
      ("evidence_refs", json_string_list ruling.GV2.evidence_refs);
      ( "recommended_action",
        match ruling.GV2.recommended_action with
        | Some request -> action_request_json request
        | None -> `Null );
      ("auto_execution_state", `String ruling.GV2.auto_execution_state);
    ]

let execution_order_json (order : GV2.execution_order) =
  `Assoc
    [
      ("id", `String order.id);
      ("case_id", `String order.case_id);
      ("status", order_status_json order.GV2.status);
      ("risk_class", risk_class_json order.GV2.risk_class);
      ( "action_request",
        match order.GV2.action_request with
        | Some request -> action_request_json request
        | None -> `Null );
      ("created_at", `String (Dashboard_utils.iso_of_unix order.created_at));
      ("updated_at", `String (Dashboard_utils.iso_of_unix order.GV2.updated_at));
      ("execution_ref", string_opt_json order.GV2.execution_ref);
      ("result_summary", string_opt_json order.GV2.result_summary);
      ("actor", string_opt_json order.GV2.actor);
    ]

let case_bundle_json (bundle : GV2.case_bundle) =
  `Assoc
    [
      ("case", case_json bundle.GV2.case_);
      ("petitions", `List (List.map petition_json bundle.GV2.petitions));
      ( "ruling",
        match bundle.GV2.ruling with
        | Some ruling -> ruling_json ruling
        | None -> `Null );
      ( "execution_order",
        match bundle.GV2.execution_order with
        | Some order -> execution_order_json order
        | None -> `Null );
    ]
