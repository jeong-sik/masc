type completed_call =
  { operation : string
  ; input : Yojson.Safe.t
  ; result : Yojson.Safe.t
  ; succeeded : bool
  }

type t =
  { turn_id : int option
  ; initial : Yojson.Safe.t
  ; completed_rev : completed_call list Atomic.t
  }

let create ~turn_id ~initial =
  { turn_id; initial; completed_rev = Atomic.make [] }
;;

let rec record_completed t call =
  let current = Atomic.get t.completed_rev in
  if not (Atomic.compare_and_set t.completed_rev current (call :: current))
  then record_completed t call
;;

let record_tool_result t ~operation ~input result =
  record_completed
    t
    { operation
    ; input
    ; result = Tool_result.data result
    ; succeeded = Tool_result.is_success result
    }
;;

let completed_call_to_yojson call =
  `Assoc
    [ "operation", `String call.operation
    ; "input", call.input
    ; "result", call.result
    ; "succeeded", `Bool call.succeeded
    ]
;;

let snapshot t : Keeper_gate.causal_context =
  let completed_calls =
    Atomic.get t.completed_rev
    |> List.rev_map completed_call_to_yojson
  in
  { turn_id = t.turn_id
  ; snapshot =
      `Assoc
        [ "initial", t.initial
        ; "completed_tool_calls", `List completed_calls
        ]
  }
;;
