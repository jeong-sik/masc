open Operator_pending_confirm
open Result.Syntax

type review_decision_value = Review_decision_value of string

let review_decision_value_to_string (Review_decision_value value) = value
let review_decision_value_of_string value = Review_decision_value value

type review_decision = {
  item_id : string;
  fingerprint : string;
  decision : review_decision_value;
  actor : string;
  reason : string;
  at : string;
  target_type : string;
  target_id : string option;
  recommended_action_type : string option;
}

let review_state_path config =
  Filename.concat (operator_dir config) "review_state.json"

let review_decision_to_yojson (entry : review_decision) =
  `Assoc
    [
      ("item_id", `String entry.item_id);
      ("fingerprint", `String entry.fingerprint);
      ("decision", `String (review_decision_value_to_string entry.decision));
      ("actor", `String entry.actor);
      ("reason", `String entry.reason);
      ("at", `String entry.at);
      ("target_type", `String entry.target_type);
      ("target_id", Json_util.string_opt_to_json entry.target_id);
      ( "recommended_action_type",
        Json_util.string_opt_to_json entry.recommended_action_type );
    ]

let required_string json field =
  match Json_util.get_string json field with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing string field %s" field)

let review_decision_of_yojson json =
  let* item_id = required_string json "item_id" in
  let* fingerprint = required_string json "fingerprint" in
  let* decision = required_string json "decision" in
  let* actor = required_string json "actor" in
  let* reason = required_string json "reason" in
  let* at = required_string json "at" in
  let* target_type = required_string json "target_type" in
  Ok
    {
      item_id;
      fingerprint;
      decision = review_decision_value_of_string decision;
      actor;
      reason;
      at;
      target_type;
      target_id = Json_util.get_string json "target_id";
      recommended_action_type = Json_util.get_string json "recommended_action_type";
    }

let compare_review_decision (left : review_decision) (right : review_decision) =
  String.compare right.at left.at

let decode_review_decision_rows rows =
  let rec loop index acc = function
    | [] -> Ok (List.rev acc)
    | row :: rest -> (
        match review_decision_of_yojson row with
        | Ok entry -> loop (index + 1) (entry :: acc) rest
        | Error msg ->
            Error
              (Printf.sprintf "review_state[%d] decode failed: %s" index msg))
  in
  loop 0 [] rows

let raw_review_decisions_result config =
  match Workspace_utils.read_json_opt_result config (review_state_path config) with
  | Error msg ->
      Error (Printf.sprintf "operator review state read failed: %s" msg)
  | Ok None -> Ok []
  | Ok (Some (`List rows)) ->
      let+ entries = decode_review_decision_rows rows in
      List.sort compare_review_decision entries
  | Ok (Some _) -> Error "operator review state decode failed: expected JSON list"

let raw_review_decisions config =
  match raw_review_decisions_result config with
  | Ok entries -> entries
  | Error msg ->
      Log.Misc.warn "[operator_review_state] %s" msg;
      []

let read_review_decisions_result config = raw_review_decisions_result config
let read_review_decisions config = raw_review_decisions config

let recent_review_decisions_result ?limit ?target_type ?target_id config =
  let matches_target (entry : review_decision) =
    let target_type_ok =
      match target_type with
      | Some value -> String.equal value entry.target_type
      | None -> true
    in
    let target_id_ok =
      match target_id with
      | Some value -> entry.target_id = Some value
      | None -> true
    in
    target_type_ok && target_id_ok
  in
  let+ entries = read_review_decisions_result config in
  let filtered = entries |> List.filter matches_target in
  match limit with
  | Some value when value >= 0 ->
      filtered |> List.to_seq |> Seq.take value |> List.of_seq
  | _ -> filtered

let recent_review_decisions ?limit ?target_type ?target_id config =
  match recent_review_decisions_result ?limit ?target_type ?target_id config with
  | Ok entries -> entries
  | Error msg ->
      Log.Misc.warn "[operator_review_state] %s" msg;
      []

let recent_review_decisions_json_result ?limit ?target_type ?target_id config =
  let+ entries = recent_review_decisions_result ?limit ?target_type ?target_id config in
  entries |> List.map review_decision_to_yojson |> fun rows -> `List rows

let recent_review_decisions_json ?limit ?target_type ?target_id config =
  match recent_review_decisions_json_result ?limit ?target_type ?target_id config with
  | Ok json -> json
  | Error msg ->
      Log.Misc.warn "[operator_review_state] %s" msg;
      `List []
