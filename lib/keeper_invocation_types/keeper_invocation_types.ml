type capability = Invoke_turn
type target = Keeper of Keeper_id.Keeper_name.t

type input = Prompt of string

type request =
  { target : target
  ; capability : capability
  ; input : input
  }

type run_ref = { run_id : string; target : target; capability : capability }

type result_contract =
  | Awaiting_execution
  | Publication_uncertain
  | Running
  | Yielded
  | Cancellation_requested
  | Cancelled
  | Completed
  | Failed

let target_name = function Keeper name -> Keeper_id.Keeper_name.to_string name

let target_to_json target =
  `Assoc [ "kind", `String "keeper"; "name", `String (target_name target) ]

let keeper_turn ~keeper_name ~prompt =
  match Keeper_id.Keeper_name.of_string keeper_name with
  | Error _ as error -> error
  | Ok target_name ->
    if String.equal prompt ""
    then Error "request.input.prompt must be a non-empty string"
    else
      Ok
        { target = Keeper target_name
        ; capability = Invoke_turn
        ; input = Prompt prompt
        }
;;

let request_target request = request.target
let request_capability request = request.capability
let request_target_name request = target_name request.target
let request_prompt request = match request.input with Prompt prompt -> prompt

let request_equal left right =
  match left.target, right.target, left.capability, right.capability with
  | Keeper left_name, Keeper right_name, Invoke_turn, Invoke_turn ->
    Keeper_id.Keeper_name.equal left_name right_name
    && String.equal (request_prompt left) (request_prompt right)
;;

let request_to_json request =
  `Assoc
    [ "target", target_to_json request.target
    ; "capability", `String "invoke_turn"
    ; "input", `Assoc [ "prompt", `String (request_prompt request) ]
    ]
;;

let exact_object ~field ~expected = function
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.length names <> List.length (List.sort_uniq String.compare names)
    then Error (Printf.sprintf "%s contains duplicate fields" field)
    else if
      List.length names <> List.length expected
      || List.exists (fun name -> not (List.mem name names)) expected
    then Error (Printf.sprintf "%s must contain exactly %s" field (String.concat ", " expected))
    else Ok fields
  | _ -> Error (field ^ " must be an object")
;;

let required_string ~field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ | None -> Error (Printf.sprintf "%s.%s must be a string" field name)
;;

let request_of_json json =
  let ( let* ) = Result.bind in
  let* fields =
    exact_object ~field:"request" ~expected:[ "target"; "capability"; "input" ] json
  in
  let* target_json =
    match List.assoc_opt "target" fields with
    | Some value -> Ok value
    | None -> Error "request.target is required"
  in
  let* target_fields =
    exact_object ~field:"request.target" ~expected:[ "kind"; "name" ] target_json
  in
  let* kind = required_string ~field:"request.target" "kind" target_fields in
  let* keeper_name = required_string ~field:"request.target" "name" target_fields in
  let* capability = required_string ~field:"request" "capability" fields in
  let* input_json =
    match List.assoc_opt "input" fields with
    | Some value -> Ok value
    | None -> Error "request.input is required"
  in
  let* input_fields =
    exact_object ~field:"request.input" ~expected:[ "prompt" ] input_json
  in
  let* prompt = required_string ~field:"request.input" "prompt" input_fields in
  if not (String.equal kind "keeper")
  then Error "request.target.kind must be keeper"
  else if not (String.equal capability "invoke_turn")
  then Error "request.capability must be invoke_turn"
  else keeper_turn ~keeper_name ~prompt
;;

let run_id reference = reference.run_id
let run_ref_target_name reference = target_name reference.target

let run_ref_to_json reference =
  `Assoc
    [ "run_id", `String reference.run_id
    ; "target", target_to_json reference.target
    ; "capability", `String "invoke_turn"
    ]
;;

let result_contract_to_string = function
  | Awaiting_execution -> "awaiting_execution"
  | Publication_uncertain -> "publication_uncertain"
  | Running -> "running"
  | Yielded -> "yielded"
  | Cancellation_requested -> "cancellation_requested"
  | Cancelled -> "cancelled"
  | Completed -> "completed"
  | Failed -> "failed"
;;

let result_contract_of_string = function
  | "awaiting_execution" -> Some Awaiting_execution
  | "publication_uncertain" -> Some Publication_uncertain
  | "running" -> Some Running
  | "yielded" -> Some Yielded
  | "cancellation_requested" -> Some Cancellation_requested
  | "cancelled" -> Some Cancelled
  | "completed" -> Some Completed
  | "failed" -> Some Failed
  | _ -> None
;;
