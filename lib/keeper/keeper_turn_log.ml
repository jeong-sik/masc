module Digest = Agent_core.Checkpoint_objects

module Log_id = struct
  type t = string

  let length = 32

  let is_lower_hex = function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false
  ;;

  let of_string text =
    if String.length text = length && String.for_all is_lower_hex text then Some text else None
  ;;

  let to_string id = id
  let equal = String.equal
end

type mark =
  { trace : string
  ; closed_messages : int
  ; session : string
  ; history_bytes : int
  ; internal_bytes : int
  ; chat_bytes : int
  ; external_rows : int
  }

type slice =
  { bundle : Digest.digest
  ; skip : int
  ; take : int
  }

type outcome =
  | Completed
  | Errored
  | Cancelled
  | Save_failed
  | Stale_save
  | Close_missing
  | Process_exited

type announced =
  | Cleared
  | Recovered

type reset_cause =
  | Announced of announced
  | Unannounced

type goal_shown =
  { goal : string
  ; shown : string
  }

type task_evidence =
  | No_task
  | Task_source_unavailable
  | Task of
      { task : Keeper_id.Task_id.t
      ; goals : goal_shown list option
      }

type line =
  | Log_started of
      { id : Log_id.t
      ; at : float
      ; mark : mark
      }
  | Opened of
      { at : float
      ; turn_ref : Ids.Turn_ref.t
      ; runtime : string
      ; task : task_evidence
      ; baseline : mark
      }
  | Closed of
      { turn : int
      ; at : float
      ; outcome : outcome
      ; after : mark
      ; unattributed : slice list
      ; own : slice list
      }
  | Reset of
      { at : float
      ; cause : reset_cause
      ; before : mark
      ; after : mark
      ; closed_before : slice list
      }

type boundary =
  | Starts_at of mark
  | Ends_unit of
      { through : mark
      ; next : mark
      }
  | Moves_nothing

let boundary = function
  | Log_started { mark; _ } -> Starts_at mark
  | Closed { after; _ } -> Ends_unit { through = after; next = after }
  | Reset { before; after; _ } -> Ends_unit { through = before; next = after }
  | Opened _ -> Moves_nothing
;;

type position =
  | Nothing_written
  | Between_turns
  | Turn_open of { opened : int }

type order_error =
  | Not_started
  | Started_twice
  | Opened_while_open of { opened : int }
  | Closed_without_open
  | Closed_another_turn of
      { opened : int
      ; closed : int
      }

let step position ~offset line =
  match position, line with
  | Nothing_written, Log_started _ -> Ok Between_turns
  | Nothing_written, (Opened _ | Closed _ | Reset _) -> Error Not_started
  | (Between_turns | Turn_open _), Log_started _ -> Error Started_twice
  | Between_turns, Opened _ -> Ok (Turn_open { opened = offset })
  | Turn_open { opened }, Opened _ -> Error (Opened_while_open { opened })
  | Between_turns, Closed _ -> Error Closed_without_open
  | Turn_open { opened }, Closed { turn; _ } ->
    if Int.equal turn opened
    then Ok Between_turns
    else Error (Closed_another_turn { opened; closed = turn })
  | ((Between_turns | Turn_open _) as position), Reset _ -> Ok position
;;
