(** Canonical dependency-leaf contract for one tool invocation. *)

module Resource_scope = struct
  type identity = { namespace : string; key : string }
  type identity_error = Empty_namespace | Empty_key
  type access = Read | Write
  type t = { access : access; occupied : identity; ancestors : identity list }

  let identity ~namespace ~key =
    if String.equal namespace "" then Error Empty_namespace
    else if String.equal key "" then Error Empty_key
    else Ok { namespace; key }
  ;;

  let create ~access ~occupied ~ancestors = { access; occupied; ancestors }

  let equal_identity left right =
    String.equal left.namespace right.namespace && String.equal left.key right.key
  ;;

  let conflicts left right =
    match left.access, right.access with
    | Read, Read -> false
    | Read, Write | Write, Read | Write, Write ->
      equal_identity left.occupied right.occupied
      || List.exists (equal_identity left.occupied) right.ancestors
      || List.exists (equal_identity right.occupied) left.ancestors
  ;;
end

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

module Occurrence = struct
  type t = {run_id:string;node_id:string}
  type error = Empty_run_id | Empty_node_id | Padded_run_id | Padded_node_id
  let of_strings ~run_id ~node_id =
    if run_id="" then Error Empty_run_id
    else if node_id="" then Error Empty_node_id
    else if run_id<>String.trim run_id then Error Padded_run_id
    else if node_id<>String.trim node_id then Error Padded_node_id
    else Ok {run_id;node_id}
  let run_id t=t.run_id
  let node_id t=t.node_id
  let compare a b=match String.compare a.run_id b.run_id with
    | 0->String.compare a.node_id b.node_id |order->order
  let equal a b=compare a b=0
end

module Invocation = struct
  type t =
    { tool_use_id : string
    ; turn : int
    ; schedule : schedule
    ; completion : completion
    ; occurrence : Occurrence.t option
    }

  let create ~tool_use_id ~turn ~schedule ~completion =
    { tool_use_id; turn; schedule; completion;occurrence=None }
  ;;

  let of_occurrence occurrence ~tool_use_id ~turn ~schedule ~completion =
    {tool_use_id;turn;schedule;completion;occurrence=Some occurrence}
  let occurrence t=t.occurrence
  let tool_use_id t = t.tool_use_id
  let turn t = t.turn
  let schedule t = t.schedule
  let completion t = t.completion
  let planned_index t = t.schedule.planned_index
end
