type capability = Invoke_turn
type target = Keeper of Keeper_id.Keeper_name.t
type reply_to = Caller_keeper of Keeper_id.Keeper_name.t

type input =
  | Delegated_turn of string
  | Direct_delivery of Keeper_direct_invocation.t
[@@deriving yojson, eq]

type request =
  { target : target
  ; capability : capability
  ; input : input
  ; reply_to : reply_to option
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

type terminal_result =
  | Invocation_succeeded of { body : string; data : Yojson.Safe.t option }
  | Invocation_failed of { body : string; data : Yojson.Safe.t option }
  | Invocation_lost of { reason : string }
  | Invocation_cancelled of { reason : string; cancelled_by : string }
  | Invocation_persistence_failed of { attempted_status : string; reason : string }
[@@deriving yojson]

let artifact_refs_key = "artifact_refs"

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
        ; input = Delegated_turn prompt
        ; reply_to = None
        }
;;

let direct_turn ~keeper_name payload =
  let ( let* ) = Result.bind in
  let* () = Keeper_direct_invocation.validate payload in
  let* target_name = Keeper_id.Keeper_name.of_string keeper_name in
  Ok
    { target = Keeper target_name
    ; capability = Invoke_turn
    ; input = Direct_delivery payload
    ; reply_to = None
    }
;;

let with_reply_to ~keeper_name request =
  Keeper_id.Keeper_name.of_string keeper_name
  |> Result.map (fun keeper_name ->
    { request with reply_to = Some (Caller_keeper keeper_name) })
;;

let request_target (request : request) = request.target
let request_capability (request : request) = request.capability
let request_target_name (request : request) = target_name request.target
let request_prompt (request : request) =
  match request.input with
  | Delegated_turn prompt -> prompt
  | Direct_delivery payload -> payload.execution_prompt
;;

let request_direct_delivery (request : request) =
  match request.input with
  | Delegated_turn _ -> None
  | Direct_delivery payload -> Some payload
;;

let request_reply_to (request : request) = request.reply_to

let reply_to_keeper_name = function
  | Caller_keeper name -> Keeper_id.Keeper_name.to_string name
;;

let request_equal (left : request) (right : request) =
  match left.target, right.target, left.capability, right.capability with
  | Keeper left_name, Keeper right_name, Invoke_turn, Invoke_turn ->
    Keeper_id.Keeper_name.equal left_name right_name
    && equal_input left.input right.input
    && Option.equal ( = ) left.reply_to right.reply_to
;;

let reply_to_to_json = function
  | Caller_keeper name ->
    `Assoc
      [ "kind", `String "keeper"
      ; "name", `String (Keeper_id.Keeper_name.to_string name)
      ]
;;

let request_to_json (request : request) =
  `Assoc
    [ "target", target_to_json request.target
    ; "capability", `String "invoke_turn"
    ; "input", input_to_yojson request.input
    ; "reply_to", Option.fold ~none:`Null ~some:reply_to_to_json request.reply_to
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

let reply_to_of_json = function
  | `Null -> Ok None
  | json ->
    let ( let* ) = Result.bind in
    let* fields =
      exact_object ~field:"request.reply_to" ~expected:[ "kind"; "name" ] json
    in
    let* kind = required_string ~field:"request.reply_to" "kind" fields in
    let* keeper_name = required_string ~field:"request.reply_to" "name" fields in
    if not (String.equal kind "keeper")
    then Error "request.reply_to.kind must be keeper"
    else
      Keeper_id.Keeper_name.of_string keeper_name
      |> Result.map (fun name -> Some (Caller_keeper name))
;;

let request_of_json json =
  let ( let* ) = Result.bind in
  let* fields =
    exact_object
      ~field:"request"
      ~expected:[ "target"; "capability"; "input"; "reply_to" ]
      json
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
  let* input =
    input_of_yojson input_json
    |> Result.map_error (fun detail -> "request.input: " ^ detail)
  in
  let* reply_to_json =
    match List.assoc_opt "reply_to" fields with
    | Some value -> Ok value
    | None -> Error "request.reply_to is required"
  in
  let* reply_to = reply_to_of_json reply_to_json in
  let* () =
    if input_to_yojson input = input_json
    then Ok ()
    else Error "request.input is not in canonical persisted form"
  in
  if not (String.equal kind "keeper")
  then Error "request.target.kind must be keeper"
  else if not (String.equal capability "invoke_turn")
  then Error "request.capability must be invoke_turn"
  else
    let* request =
      match input with
      | Delegated_turn prompt -> keeper_turn ~keeper_name ~prompt
      | Direct_delivery payload -> direct_turn ~keeper_name payload
    in
    Ok { request with reply_to }
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
