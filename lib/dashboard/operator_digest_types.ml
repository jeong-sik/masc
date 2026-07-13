(** Severity levels for operator attention items and recommendations.
    Closed set — exhaustive matching catches new levels at compile time. *)
type operator_severity = Sev_critical | Sev_bad | Sev_warn

let operator_severity_to_string = function
  | Sev_critical -> "critical"
  | Sev_bad -> "bad"
  | Sev_warn -> "warn"

let operator_severity_of_string_opt = function
  | "critical" -> Some Sev_critical
  | "bad" -> Some Sev_bad
  | "warn" -> Some Sev_warn
  | _ -> None

let operator_severity_of_failure_envelope
    (sev : Failure_envelope.severity) : operator_severity =
  match sev with
  | Failure_envelope.Critical -> Sev_critical
  | Failure_envelope.Bad -> Sev_bad
  | Failure_envelope.Warn -> Sev_warn

type attention_item = {
  kind : string;
  severity : operator_severity;
  summary : string;
  target_type : string;
  target_id : string option;
  actor : string option;
  evidence : Yojson.Safe.t;
}

type recommended_action = {
  action_type : string;
  target_type : string;
  target_id : string option;
  severity : operator_severity;
  reason : string;
  suggested_payload : Yojson.Safe.t;
}

let stalled_session_threshold_sec = Env_config.InternalTimers.stalled_session_threshold_sec

let severity_rank = function
  | Sev_critical -> 3
  | Sev_bad -> 2
  | Sev_warn -> 1

let compare_attention (a : attention_item) (b : attention_item) =
  let by_severity = Int.compare (severity_rank b.severity) (severity_rank a.severity) in
  if by_severity <> 0 then by_severity
  else
    match (a.target_id, b.target_id) with
    | Some x, Some y ->
        let by_target = String.compare x y in
        if by_target <> 0 then by_target else String.compare a.kind b.kind
    | Some _, None -> -1
    | None, Some _ -> 1
    | None, None -> String.compare a.kind b.kind

let compare_recommendation (a : recommended_action) (b : recommended_action) =
  let by_severity = Int.compare (severity_rank b.severity) (severity_rank a.severity) in
  if by_severity <> 0 then by_severity
  else
    match (a.target_id, b.target_id) with
    | Some x, Some y ->
        let by_target = String.compare x y in
        if by_target <> 0 then by_target else String.compare a.action_type b.action_type
    | Some _, None -> -1
    | None, Some _ -> 1
    | None, None -> String.compare a.action_type b.action_type

let attention_item_to_yojson (item : attention_item) =
  `Assoc
    [
      ("kind", `String item.kind);
      ("severity", `String (operator_severity_to_string item.severity));
      ("summary", `String item.summary);
      ("target_type", `String item.target_type);
      ("target_id", Json_util.string_opt_to_json item.target_id);
      ("actor", Json_util.string_opt_to_json item.actor);
      ("evidence", item.evidence);
      ("provenance", `String "derived");
      ("authoritative", `Bool false);
    ]

let recommended_confirm_required = Operator_action_catalog.requires_confirmation

let recommended_action_to_yojson ~actor (item : recommended_action) =
  let preview =
    `Assoc
      [
        ("actor", `String actor);
        ("action_type", `String item.action_type);
        ("target_type", `String item.target_type);
        ("target_id", Json_util.string_opt_to_json item.target_id);
        ("payload", item.suggested_payload);
      ]
  in
  `Assoc
    [
      ("action_type", `String item.action_type);
      ("target_type", `String item.target_type);
      ("target_id", Json_util.string_opt_to_json item.target_id);
      ("severity", `String (operator_severity_to_string item.severity));
      ("reason", `String item.reason);
      ("confirm_required", `Bool (recommended_confirm_required item.action_type));
      ("suggested_payload", item.suggested_payload);
      ("preview", preview);
      ("provenance", `String "fallback");
      ("authoritative", `Bool false);
    ]

let summary_of_attention_items (items : attention_item list) =
  let sorted = List.sort compare_attention items in
  let top_item : attention_item option =
    match sorted with item :: _ -> Some item | [] -> None
  in
  let bad_count =
    List.fold_left
      (fun acc (item : attention_item) ->
        match item.severity with Sev_bad -> acc + 1 | Sev_critical | Sev_warn -> acc)
      0 sorted
  in
  let warn_count =
    List.fold_left
      (fun acc (item : attention_item) ->
        match item.severity with Sev_warn -> acc + 1 | Sev_critical | Sev_bad -> acc)
      0 sorted
  in
  `Assoc
    [
      ("count", `Int (List.length sorted));
      ("bad_count", `Int bad_count);
      ("warn_count", `Int warn_count);
      ("top_item", Json_util.option_to_yojson attention_item_to_yojson top_item);
      ("provenance", `String "derived");
      ("authoritative", `Bool false);
    ]

let dedup_recommendations (items : recommended_action list) =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | (item : recommended_action) :: rest ->
        let key =
          String.concat "|"
            [
              item.action_type;
              item.target_type;
              Option.value ~default:"" item.target_id;
              String.trim item.reason |> String.lowercase_ascii;
            ]
        in
        if List.mem key seen then loop seen acc rest
        else loop (key :: seen) (item :: acc) rest
  in
  items |> List.sort compare_recommendation |> loop [] []

let summary_of_recommendations ~actor (items : recommended_action list) =
  let sorted = dedup_recommendations items in
  let top_item : recommended_action option =
    match sorted with item :: _ -> Some item | [] -> None
  in
  `Assoc
    [
      ("count", `Int (List.length sorted));
      ( "top_action",
        Json_util.option_to_yojson (recommended_action_to_yojson ~actor) top_item );
      ("provenance", `String "fallback");
      ("authoritative", `Bool false);
    ]

(** [is_workspace_target_type v] is true when [v] is the canonical
    workspace target from the operator target codec. *)
let is_workspace_target_type value =
  match Operator_action_constants.target_type_of_string value with
  | Some Operator_action_constants.Workspace -> true
  | Some Operator_action_constants.Keeper
  | Some Operator_action_constants.Goal
  | None -> false
;;

let normalize_digest_target_type value =
  match value with
  | Some raw ->
      let normalized = String.trim raw |> String.lowercase_ascii in
      if is_workspace_target_type normalized
      then Ok Operator_action_constants.workspace_target_type
      else Error Operator_action_constants.workspace_target_type_error
  | None -> Ok Operator_action_constants.workspace_target_type
