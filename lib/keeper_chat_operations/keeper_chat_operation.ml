module Operation_id = struct
  type t = string

  let max_length = 128

  let of_string value =
    let length = String.length value in
    let rec valid_chars index =
      if index = length
      then true
      else
        match value.[index] with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' ->
          valid_chars (index + 1)
        | _ -> false
    in
    if length = 0
    then Error "operation_id must not be empty"
    else if length > max_length
    then Error "operation_id exceeds 128 bytes"
    else if String.equal value "." || String.equal value ".."
    then Error "operation_id must not be a path segment"
    else if valid_chars 0
    then Ok value
    else Error "operation_id contains an unsupported character"
  ;;

  let to_string value = value
  let equal = String.equal
end

type failure_kind =
  | Interrupted_by_restart
  | Turn_cancelled
  | Turn_exception
  | Store_unavailable
  | No_queued_operation
  | Invalid_input
  | Turn_invariant
  | Delivery_failed

let all_failure_kinds =
  [ Interrupted_by_restart
  ; Turn_cancelled
  ; Turn_exception
  ; Store_unavailable
  ; No_queued_operation
  ; Invalid_input
  ; Turn_invariant
  ; Delivery_failed
  ]
;;

let failure_kind_to_string = function
  | Interrupted_by_restart -> "Interrupted_by_restart"
  | Turn_cancelled -> "Turn_cancelled"
  | Turn_exception -> "Turn_exception"
  | Store_unavailable -> "Store_unavailable"
  | No_queued_operation -> "No_queued_operation"
  | Invalid_input -> "Invalid_input"
  | Turn_invariant -> "Turn_invariant"
  | Delivery_failed -> "Delivery_failed"
;;

let failure_kind_of_string = function
  | "Interrupted_by_restart" -> Ok Interrupted_by_restart
  | "Turn_cancelled" -> Ok Turn_cancelled
  | "Turn_exception" -> Ok Turn_exception
  | "Store_unavailable" -> Ok Store_unavailable
  | "No_queued_operation" -> Ok No_queued_operation
  | "Invalid_input" -> Ok Invalid_input
  | "Turn_invariant" -> Ok Turn_invariant
  | "Delivery_failed" -> Ok Delivery_failed
  | value -> Error (Printf.sprintf "unknown Keeper chat operation failure kind %S" value)
;;

type failure =
  { kind : failure_kind
  ; detail : string
  ; outcome_ref : string option
  }

type state =
  | Queued
  | Running of { started_at : float }
  | Succeeded of
      { completed_at : float
      ; outcome_ref : string
      }
  | Failed of
      { completed_at : float
      ; failure : failure
      }
  | Cancelled of { completed_at : float }

type t =
  { operation_id : Operation_id.t
  ; admission_digest : string
  ; execution_digest : string
  ; sequence : int64
  ; source : Yojson.Safe.t
  ; input : Yojson.Safe.t option
  ; state : state
  ; created_at : float
  }

let state_to_string = function
  | Queued -> "queued"
  | Running _ -> "running"
  | Succeeded _ -> "succeeded"
  | Failed _ -> "failed"
  | Cancelled _ -> "cancelled"
;;

let is_terminal = function
  | Succeeded _ | Failed _ | Cancelled _ -> true
  | Queued | Running _ -> false
;;

let to_json operation =
  let state_fields =
    match operation.state with
    | Queued -> [ "state", `String "Queued" ]
    | Running { started_at } ->
      [ "state", `String "Running"; "started_at", `Float started_at ]
    | Succeeded { completed_at; outcome_ref } ->
      [ "state", `String "Succeeded"
      ; "completed_at", `Float completed_at
      ; "outcome_ref", `String outcome_ref
      ]
    | Failed { completed_at; failure = { kind; detail; outcome_ref } } ->
      [ "state", `String "Failed"
      ; "completed_at", `Float completed_at
      ; "failure_kind", `String (failure_kind_to_string kind)
      ; "failure_detail", `String detail
      ; ( "outcome_ref"
        , match outcome_ref with
          | None -> `Null
          | Some value -> `String value )
      ]
    | Cancelled { completed_at } ->
      [ "state", `String "Cancelled"; "completed_at", `Float completed_at ]
  in
  `Assoc
    ([ "schema", `String "masc.keeper_chat_operation.v1"
     ; "operation_id", `String (Operation_id.to_string operation.operation_id)
     ; "sequence", `String (Int64.to_string operation.sequence)
     ; "created_at", `Float operation.created_at
     ; "execution_digest", `String operation.execution_digest
     ; "source", operation.source
     ; ( "input"
       , match operation.input with
         | None -> `Null
         | Some input -> input )
     ]
     @ state_fields)
;;

let validate_timestamp ~field value =
  if Float.is_finite value && value >= 0.0
  then Ok ()
  else Error (field ^ " must be a finite non-negative timestamp")
;;

let validate_nonblank ~field value =
  if String.equal (String.trim value) ""
  then Error (field ^ " must not be blank")
  else Ok value
;;

let canonical_json_string value =
  let rec normalize = function
    | `Assoc fields ->
      let rec loop seen normalized = function
        | [] ->
          normalized
          |> List.sort (fun (left, _) (right, _) -> String.compare left right)
          |> fun fields -> Ok (`Assoc fields)
        | (name, value) :: rest ->
          if List.mem name seen
          then Error (Printf.sprintf "JSON has duplicate field %S" name)
          else
            (match normalize value with
             | Error _ as error -> error
             | Ok value -> loop (name :: seen) ((name, value) :: normalized) rest)
      in
      loop [] [] fields
    | `List values ->
      let rec loop normalized = function
        | [] -> Ok (`List (List.rev normalized))
        | value :: rest ->
          (match normalize value with
           | Error _ as error -> error
           | Ok value -> loop (value :: normalized) rest)
      in
      loop [] values
    | `Float value when not (Float.is_finite value) ->
      Error "JSON contains a non-finite float"
    | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value ->
      Ok value
  in
  normalize value |> Result.map Yojson.Safe.to_string
;;

let sha256 value = Digestif.SHA256.(digest_string value |> to_hex)

let execution_digest input =
  canonical_json_string input |> Result.map sha256
;;

let admission_digest ~source ~input =
  canonical_json_string (`Assoc [ "source", source; "input", input ])
  |> Result.map sha256
;;
