(** Advisory orthogonal product for Goal x Task x Board x Reward. *)

type task_phase =
  | No_task
  | Todo
  | Claimed
  | In_progress
  | Awaiting_verification
  | Done
  | Cancelled
  | Mixed

let task_phase_to_string = function
  | No_task -> "no_task"
  | Todo -> "todo"
  | Claimed -> "claimed"
  | In_progress -> "in_progress"
  | Awaiting_verification -> "awaiting_verification"
  | Done -> "done"
  | Cancelled -> "cancelled"
  | Mixed -> "mixed"
;;

let task_phase_of_status = function
  | Types.Todo -> Todo
  | Types.Claimed _ -> Claimed
  | Types.InProgress _ -> In_progress
  | Types.AwaitingVerification _ -> Awaiting_verification
  | Types.Done _ -> Done
  | Types.Cancelled _ -> Cancelled
;;

type board_phase =
  | Quiet
  | Signal_pending
  | Signal_acknowledged
  | Signal_expired
  | Degraded

let board_phase_to_string = function
  | Quiet -> "quiet"
  | Signal_pending -> "signal_pending"
  | Signal_acknowledged -> "signal_acknowledged"
  | Signal_expired -> "signal_expired"
  | Degraded -> "degraded"
;;

type reward_phase =
  | Disabled
  | Neutral
  | Credit_pending
  | Rewarded
  | Spent
  | Penalized

let reward_phase_to_string = function
  | Disabled -> "disabled"
  | Neutral -> "neutral"
  | Credit_pending -> "credit_pending"
  | Rewarded -> "rewarded"
  | Spent -> "spent"
  | Penalized -> "penalized"
;;

type axis =
  | Goal
  | Task
  | Board
  | Reward
  | Product

let axis_to_string = function
  | Goal -> "goal"
  | Task -> "task"
  | Board -> "board"
  | Reward -> "reward"
  | Product -> "product"
;;

type severity =
  | Info
  | Warn
  | Error

let severity_to_string = function
  | Info -> "info"
  | Warn -> "warn"
  | Error -> "error"
;;

type ids =
  { goal_id : string option
  ; task_ids : string list
  ; post_ids : string list
  ; agent_name : string option
  }

let empty_ids = { goal_id = None; task_ids = []; post_ids = []; agent_name = None }

type task_counts =
  { total : int
  ; open_count : int
  ; done_count : int
  ; cancelled_count : int
  ; awaiting_verification_count : int
  }

let empty_task_counts =
  { total = 0
  ; open_count = 0
  ; done_count = 0
  ; cancelled_count = 0
  ; awaiting_verification_count = 0
  }
;;

let task_counts_of_statuses statuses =
  let count pred = statuses |> List.filter pred |> List.length in
  { total = List.length statuses
  ; open_count = count (fun status -> not (Types.task_status_is_terminal status))
  ; done_count = count Types.task_status_is_done
  ; cancelled_count =
      count (function
        | Types.Cancelled _ -> true
        | _ -> false)
  ; awaiting_verification_count =
      count (function
        | Types.AwaitingVerification _ -> true
        | _ -> false)
  }
;;

let task_phase_of_counts statuses =
  match statuses with
  | [] -> No_task
  | [ status ] -> task_phase_of_status status
  | first :: rest ->
    let first_phase = task_phase_of_status first in
    if List.for_all (fun status -> task_phase_of_status status = first_phase) rest
    then first_phase
    else Mixed
;;

type facts =
  { economy_enabled : bool
  ; has_reward_earning : bool
  ; has_spend : bool
  ; has_penalty : bool
  ; board_signal_count : int
  ; board_persist_error_count : int
  ; active_goal_verification : bool
  }

let default_facts =
  { economy_enabled = false
  ; has_reward_earning = false
  ; has_spend = false
  ; has_penalty = false
  ; board_signal_count = 0
  ; board_persist_error_count = 0
  ; active_goal_verification = false
  }
;;

type evidence =
  { source : string
  ; kind : string
  ; id : string option
  ; label : string
  ; detail : string
  ; timestamp : float option
  ; refs : ids
  }

type product =
  { ids : ids
  ; goal : Goal_phase.t option
  ; task : task_phase
  ; board : board_phase
  ; reward : reward_phase
  ; task_counts : task_counts
  ; facts : facts
  ; evidence : evidence list
  }

type violation =
  { axis : axis
  ; code : string
  ; severity : severity
  ; message : string
  ; ids : ids
  }

let reward_phase_of_facts
      ~economy_enabled
      ~task_counts
      ~board
      ~has_reward_earning
      ~has_spend
      ~has_penalty
  =
  if not economy_enabled
  then Disabled
  else if has_penalty
  then Penalized
  else if has_reward_earning && has_spend
  then Spent
  else if has_reward_earning
  then Rewarded
  else if task_counts.done_count > 0 || board = Signal_acknowledged
  then Credit_pending
  else Neutral
;;

let add_violation violations ~axis ~code ~severity ~message ~ids =
  { axis; code; severity; message; ids } :: violations
;;

let goal_is_terminal = function
  | Some Goal_phase.Completed | Some Goal_phase.Dropped -> true
  | Some
      ( Goal_phase.Executing
      | Goal_phase.Awaiting_verification
      | Goal_phase.Awaiting_approval
      | Goal_phase.Blocked
      | Goal_phase.Paused )
  | None -> false
;;

let reward_has_evidence (product : product) =
  product.task_counts.done_count > 0
  || product.board = Signal_acknowledged
  || product.facts.has_reward_earning
;;

let check_invariants (product : product) =
  let violations = ref [] in
  let add ~axis ~code ~severity ~message =
    violations
    := add_violation !violations ~axis ~code ~severity ~message ~ids:product.ids
  in
  (match product.goal with
   | Some (Goal_phase.Completed | Goal_phase.Dropped)
     when product.task_counts.open_count > 0 ->
     add
       ~axis:Product
       ~code:"goal_terminal_open_tasks"
       ~severity:Error
       ~message:"Goal is terminal while one or more linked tasks are still open."
   | Some Goal_phase.Completed
     when product.task_counts.total = 0 || product.task_counts.done_count = 0 ->
     add
       ~axis:Goal
       ~code:"goal_completed_without_done_task"
       ~severity:Warn
       ~message:
         "Goal is completed without linked done-task evidence; this may be an operator \
          override."
   | Some Goal_phase.Awaiting_verification
     when product.task_counts.done_count = 0 && not product.facts.active_goal_verification
     ->
     add
       ~axis:Goal
       ~code:"goal_verification_without_evidence"
       ~severity:Warn
       ~message:
         "Goal is awaiting verification without done-task evidence or an active \
          verification request."
   | Some
       ( Goal_phase.Executing
       | Goal_phase.Awaiting_verification
       | Goal_phase.Awaiting_approval
       | Goal_phase.Blocked
       | Goal_phase.Paused
       | Goal_phase.Completed
       | Goal_phase.Dropped )
   | None -> ());
  (match product.reward with
   | (Rewarded | Spent) when not (reward_has_evidence product) ->
     add
       ~axis:Reward
       ~code:"reward_without_evidence"
       ~severity:Error
       ~message:
         "Reward state is earned/spent without task completion or acknowledged board \
          evidence."
   | Credit_pending
     when product.goal = Some Goal_phase.Dropped || product.task = Cancelled ->
     add
       ~axis:Reward
       ~code:"pending_credit_for_dropped_work"
       ~severity:Warn
       ~message:
         "Credit is pending for dropped or cancelled work; ledger should stay neutral \
          unless an override exists."
   | Disabled | Neutral | Credit_pending | Rewarded | Spent | Penalized -> ());
  (match product.board with
   | Degraded ->
     add
       ~axis:Board
       ~code:"board_degraded"
       ~severity:Error
       ~message:
         "Board persistence has recorded errors; coordination signals may be incomplete."
   | Signal_pending when goal_is_terminal product.goal ->
     add
       ~axis:Board
       ~code:"board_signal_pending_after_terminal_goal"
       ~severity:Warn
       ~message:"Board signal remains pending after the goal reached a terminal phase."
   | Signal_pending
     when product.task_counts.total > 0 && product.task_counts.open_count = 0 ->
     add
       ~axis:Board
       ~code:"board_signal_pending_after_terminal_tasks"
       ~severity:Warn
       ~message:
         "Board signal remains pending after all linked tasks reached terminal states."
   | Quiet | Signal_pending | Signal_acknowledged | Signal_expired -> ());
  List.rev !violations
;;

let option_string_to_yojson = function
  | Some value -> `String value
  | None -> `Null
;;

let string_list_to_yojson values = `List (List.map (fun value -> `String value) values)

let ids_to_yojson ids =
  `Assoc
    [ "goal_id", option_string_to_yojson ids.goal_id
    ; "task_ids", string_list_to_yojson ids.task_ids
    ; "post_ids", string_list_to_yojson ids.post_ids
    ; "agent_name", option_string_to_yojson ids.agent_name
    ]
;;

let task_counts_to_yojson counts =
  `Assoc
    [ "total", `Int counts.total
    ; "open", `Int counts.open_count
    ; "done", `Int counts.done_count
    ; "cancelled", `Int counts.cancelled_count
    ; "awaiting_verification", `Int counts.awaiting_verification_count
    ]
;;

let facts_to_yojson facts =
  `Assoc
    [ "economy_enabled", `Bool facts.economy_enabled
    ; "has_reward_earning", `Bool facts.has_reward_earning
    ; "has_spend", `Bool facts.has_spend
    ; "has_penalty", `Bool facts.has_penalty
    ; "board_signal_count", `Int facts.board_signal_count
    ; "board_persist_error_count", `Int facts.board_persist_error_count
    ; "active_goal_verification", `Bool facts.active_goal_verification
    ]
;;

let option_float_to_yojson = function
  | Some value -> `Float value
  | None -> `Null
;;

let evidence_to_yojson evidence =
  `Assoc
    [ "source", `String evidence.source
    ; "kind", `String evidence.kind
    ; "id", option_string_to_yojson evidence.id
    ; "label", `String evidence.label
    ; "detail", `String evidence.detail
    ; "timestamp", option_float_to_yojson evidence.timestamp
    ; "refs", ids_to_yojson evidence.refs
    ]
;;

let violation_to_yojson ?(evidence = []) violation =
  `Assoc
    [ "axis", `String (axis_to_string violation.axis)
    ; "code", `String violation.code
    ; "severity", `String (severity_to_string violation.severity)
    ; "message", `String violation.message
    ; "refs", ids_to_yojson violation.ids
    ; "evidence", `List (List.map evidence_to_yojson evidence)
    ]
;;

let product_to_yojson product =
  let violations = check_invariants product in
  `Assoc
    [ "refs", ids_to_yojson product.ids
    ; ( "goal"
      , match product.goal with
        | Some phase -> Goal_phase.to_yojson phase
        | None -> `Null )
    ; "task", `String (task_phase_to_string product.task)
    ; "board", `String (board_phase_to_string product.board)
    ; "reward", `String (reward_phase_to_string product.reward)
    ; "task_counts", task_counts_to_yojson product.task_counts
    ; "facts", facts_to_yojson product.facts
    ; "evidence", `List (List.map evidence_to_yojson product.evidence)
    ; ( "violations"
      , `List
          (List.map
             (fun violation -> violation_to_yojson ~evidence:product.evidence violation)
             violations) )
    ]
;;

type snapshot =
  { products : product list
  ; violations : violation list
  }

let snapshot products =
  let violations = List.concat_map check_invariants products in
  { products; violations }
;;

let severity_counts violations =
  let count severity =
    violations
    |> List.filter (fun violation -> violation.severity = severity)
    |> List.length
  in
  `Assoc
    [ "info", `Int (count Info); "warn", `Int (count Warn); "error", `Int (count Error) ]
;;

let evidence_for_violation products violation =
  products
  |> List.find_map (fun (product : product) ->
    if product.ids = violation.ids then Some product.evidence else None)
  |> Option.value ~default:[]
;;

let snapshot_to_yojson snapshot =
  let evidence =
    snapshot.products |> List.concat_map (fun product -> product.evidence)
  in
  `Assoc
    [ "schema_version", `Int 1
    ; "mode", `String "advisory"
    ; ( "summary"
      , `Assoc
          [ "products", `Int (List.length snapshot.products)
          ; "violations", `Int (List.length snapshot.violations)
          ; "evidence", `Int (List.length evidence)
          ; "severity_counts", severity_counts snapshot.violations
          ] )
    ; "products", `List (List.map product_to_yojson snapshot.products)
    ; "evidence", `List (List.map evidence_to_yojson evidence)
    ; ( "violations"
      , `List
          (List.map
             (fun violation ->
               let evidence = evidence_for_violation snapshot.products violation in
               violation_to_yojson ~evidence violation)
             snapshot.violations) )
    ]
;;
