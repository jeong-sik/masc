(** Canonical dependency-leaf contract for one tool invocation. *)

type execution_mode =
  | Concurrent
  | Serial
[@@deriving show]

let execution_mode_to_yojson = function
  | Concurrent -> `String "concurrent"
  | Serial -> `String "serial"
;;

let execution_mode_of_yojson = function
  | `String "concurrent" -> Ok Concurrent
  | `String "serial" -> Ok Serial
  | value ->
    Error
      (Printf.sprintf
         "Tool_contract.execution_mode: expected \"concurrent\" or \"serial\", got %s"
         (Yojson.Safe.to_string value))
;;

type failure_effect_disposition =
  | Proven_pre_effect
  | Proven_post_effect
  | Effect_outcome_unknown
[@@deriving show]

type completion =
  | Continue_after_success
  | Terminal_after_success of failure_effect_disposition
[@@deriving show]

let failure_effect_disposition_to_yojson = function
  | Proven_pre_effect -> `String "proven_pre_effect"
  | Proven_post_effect -> `String "proven_post_effect"
  | Effect_outcome_unknown -> `String "effect_outcome_unknown"
;;

let failure_effect_disposition_of_yojson = function
  | `String "proven_pre_effect" -> Ok Proven_pre_effect
  | `String "proven_post_effect" -> Ok Proven_post_effect
  | `String "effect_outcome_unknown" -> Ok Effect_outcome_unknown
  | value ->
    Error
      (Printf.sprintf
         "Tool_contract.failure_effect_disposition: invalid value %s"
         (Yojson.Safe.to_string value))
;;

let completion_to_yojson = function
  | Continue_after_success -> `Assoc [ "kind", `String "continue_after_success" ]
  | Terminal_after_success failure_effect ->
    `Assoc
      [ "kind", `String "terminal_after_success"
      ; "failure_effect", failure_effect_disposition_to_yojson failure_effect
      ]
;;

let completion_of_yojson = function
  | `Assoc fields ->
    let values key =
      List.filter_map
        (fun (field, value) -> if String.equal field key then Some value else None)
        fields
    in
    let has_unknown_field =
      List.exists
        (fun (field, _) ->
           not (String.equal field "kind" || String.equal field "failure_effect"))
        fields
    in
    if has_unknown_field
    then Error "Tool_contract.completion: unknown field"
    else (
      match values "kind", values "failure_effect" with
      | [ `String "continue_after_success" ], [] -> Ok Continue_after_success
      | [ `String "terminal_after_success" ], [ failure_effect ] ->
        Result.map
          (fun disposition -> Terminal_after_success disposition)
          (failure_effect_disposition_of_yojson failure_effect)
      | [ `String "terminal_after_success" ], [] ->
        Error "Tool_contract.completion: terminal completion requires failure_effect"
      | _ -> Error "Tool_contract.completion: invalid or duplicate fields")
  | value ->
    Error
      (Printf.sprintf
         "Tool_contract.completion: expected a current-version object, got %s"
         (Yojson.Safe.to_string value))
;;

type schedule =
  { planned_index : int
  ; batch_index : int
  ; batch_size : int
  ; execution_mode : execution_mode
  }

module Invocation = struct
  type t =
    { tool_use_id : string
    ; turn : int
    ; schedule : schedule
    ; completion : completion
    }

  let create ~tool_use_id ~turn ~schedule ~completion =
    { tool_use_id; turn; schedule; completion }
  ;;

  let tool_use_id t = t.tool_use_id
  let turn t = t.turn
  let schedule t = t.schedule
  let completion t = t.completion
  let planned_index t = t.schedule.planned_index
end
