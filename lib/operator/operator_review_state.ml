module U = Yojson.Safe.Util
open Operator_pending_confirm

type review_decision =
  { item_id : string
  ; fingerprint : string
  ; decision : string
  ; actor : string
  ; reason : string
  ; at : string
  ; target_type : string
  ; target_id : string option
  ; recommended_action_type : string option
  }

let review_state_path config = Filename.concat (operator_dir config) "review_state.json"

let review_decision_to_yojson (entry : review_decision) =
  `Assoc
    [ "item_id", `String entry.item_id
    ; "fingerprint", `String entry.fingerprint
    ; "decision", `String entry.decision
    ; "actor", `String entry.actor
    ; "reason", `String entry.reason
    ; "at", `String entry.at
    ; "target_type", `String entry.target_type
    ; "target_id", string_option_to_json entry.target_id
    ; "recommended_action_type", string_option_to_json entry.recommended_action_type
    ]
;;

let review_decision_of_yojson json =
  try
    Ok
      { item_id = json |> U.member "item_id" |> U.to_string
      ; fingerprint = json |> U.member "fingerprint" |> U.to_string
      ; decision = json |> U.member "decision" |> U.to_string
      ; actor = json |> U.member "actor" |> U.to_string
      ; reason = json |> U.member "reason" |> U.to_string
      ; at = json |> U.member "at" |> U.to_string
      ; target_type = json |> U.member "target_type" |> U.to_string
      ; target_id = json |> U.member "target_id" |> U.to_string_option
      ; recommended_action_type =
          json |> U.member "recommended_action_type" |> U.to_string_option
      }
  with
  | U.Type_error (msg, _) | Failure msg -> Error msg
;;

let compare_review_decision (left : review_decision) (right : review_decision) =
  String.compare right.at left.at
;;

let raw_review_decisions config =
  match Coord_utils.read_json_opt config (review_state_path config) with
  | None -> []
  | Some (`List rows) ->
    rows
    |> List.filter_map (fun row ->
      match review_decision_of_yojson row with
      | Ok entry -> Some entry
      | Error _ -> None)
    |> List.sort compare_review_decision
  | Some _ -> []
;;

let write_review_decisions config entries =
  entries
  |> List.sort compare_review_decision
  |> List.map review_decision_to_yojson
  |> fun rows -> Coord_utils.write_json config (review_state_path config) (`List rows)
;;

let read_review_decisions config = raw_review_decisions config

let recent_review_decisions ?limit ?target_type ?target_id config =
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
  let filtered = read_review_decisions config |> List.filter matches_target in
  match limit with
  | Some value when value >= 0 -> filtered |> List.to_seq |> Seq.take value |> List.of_seq
  | _ -> filtered
;;

let recent_review_decisions_json ?limit ?target_type ?target_id config =
  recent_review_decisions ?limit ?target_type ?target_id config
  |> List.map review_decision_to_yojson
  |> fun rows -> `List rows
;;
