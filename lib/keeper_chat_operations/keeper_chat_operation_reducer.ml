module Operation = Keeper_chat_operation

type command =
  | Start of { started_at : float }
  | Edit_queued of
      { input : Yojson.Safe.t
      ; execution_digest : string
      }
  | Move_queued of { sequence : int64 }
  | Cancel_queued of { completed_at : float }
  | Succeed_running of
      { completed_at : float
      ; outcome_ref : string
      }
  | Fail_running of
      { completed_at : float
      ; failure : Operation.failure
      }

type persistence_intent =
  | Persist_running
  | Persist_queued_edit
  | Persist_queued_move
  | Persist_terminal

type post_commit_effect = Publish_operation

type transition =
  { operation : Operation.t
  ; persistence : persistence_intent
  ; post_commit : post_commit_effect
  }

type error =
  | Not_queued
  | Not_running
  | Invalid_input of string

let error_to_string = function
  | Not_queued -> "operation is not queued"
  | Not_running -> "operation is not running"
  | Invalid_input detail -> detail
;;

let transition operation persistence =
  { operation; persistence; post_commit = Publish_operation }
;;

let validate_sequence sequence =
  if Int64.compare sequence 0L < 0
  then Error (Invalid_input "sequence must be non-negative")
  else Ok ()
;;

let validate_terminal_time completed_at =
  Operation.validate_timestamp ~field:"completed_at" completed_at
  |> Result.map_error (fun detail -> Invalid_input detail)
;;

let apply (operation : Operation.t) command =
  match command, operation.state with
  | Start { started_at }, Queued ->
    (match Operation.validate_timestamp ~field:"started_at" started_at with
     | Error detail -> Error (Invalid_input detail)
     | Ok () ->
       Ok
         (transition
            { operation with state = Running { started_at } }
            Persist_running))
  | Edit_queued { input; execution_digest }, Queued ->
    if String.length execution_digest <> 64
    then Error (Invalid_input "execution_digest must be lowercase SHA-256 hex")
    else
      Ok
        (transition
           { operation with input = Some input; execution_digest }
           Persist_queued_edit)
  | Move_queued { sequence }, Queued ->
    (match validate_sequence sequence with
     | Error _ as error -> error
     | Ok () ->
       Ok (transition { operation with sequence } Persist_queued_move))
  | Cancel_queued { completed_at }, Queued ->
    (match validate_terminal_time completed_at with
     | Error _ as error -> error
     | Ok () ->
       Ok
         (transition
            { operation with
              input = None
            ; state = Cancelled { completed_at }
            }
            Persist_terminal))
  | Succeed_running { completed_at; outcome_ref }, Running _ ->
    (match
       validate_terminal_time completed_at,
       Operation.validate_nonblank ~field:"outcome_ref" outcome_ref
     with
     | Error error, _ -> Error error
     | _, Error detail -> Error (Invalid_input detail)
     | Ok (), Ok outcome_ref ->
       Ok
         (transition
            { operation with
              input = None
            ; state = Succeeded { completed_at; outcome_ref }
            }
            Persist_terminal))
  | Fail_running { completed_at; failure }, Running _ ->
    (match
       validate_terminal_time completed_at,
       Operation.validate_nonblank ~field:"failure.detail" failure.detail
     with
     | Error error, _ -> Error error
     | _, Error detail -> Error (Invalid_input detail)
     | Ok (), Ok detail ->
       let failure = { failure with detail } in
       Ok
         (transition
            { operation with
              input = None
            ; state = Failed { completed_at; failure }
            }
            Persist_terminal))
  | (Start _ | Edit_queued _ | Move_queued _ | Cancel_queued _),
    (Running _ | Succeeded _ | Failed _ | Cancelled _) ->
    Error Not_queued
  | (Succeed_running _ | Fail_running _),
    (Queued | Succeeded _ | Failed _ | Cancelled _) ->
    Error Not_running
;;
