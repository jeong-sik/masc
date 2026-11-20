open Keeper_memory_os_types
open Keeper_turn_log
open Keeper_turn_log_wire

let f_kind = wire_field_kind
let f_post = "post"
let f_author = "author"
let f_event = "event"
let f_comment = "comment"
let f_by = "by"
let f_candidate = "candidate"
let f_receipt = "receipt"
let f_run = "run"
let f_schedule = "schedule"
let f_occurrence = "occurrence"
let f_attention = "attention"
let f_approval = "approval"
let f_ask = "ask"
let f_task = "task"
let f_verification = "verification"
let f_judge = "judge"
let f_operator = "operator"
let f_request = "request"
let f_from = "from"
let f_operation = "operation"
let f_keeper = "keeper"
let f_tool = "tool"
let f_job = "job"

type kind =
  | Kind_board
  | Kind_board_routing_pending
  | Kind_board_attention
  | Kind_bootstrap
  | Kind_tool_result
  | Kind_fusion
  | Kind_schedule
  | Kind_connector
  | Kind_hitl
  | Kind_ask
  | Kind_completion_rejected
  | Kind_completion_approved
  | Kind_task_cancelled
  | Kind_workspace_message
  | Kind_delegate
  | Kind_composition
  | Kind_owned_job

let kind_token = function
  | Kind_board -> "board"
  | Kind_board_routing_pending -> "board_routing_pending"
  | Kind_board_attention -> "board_attention"
  | Kind_bootstrap -> "bootstrap"
  | Kind_tool_result -> "tool_result"
  | Kind_fusion -> "fusion"
  | Kind_schedule -> "schedule"
  | Kind_connector -> "connector"
  | Kind_hitl -> "hitl"
  | Kind_ask -> "ask"
  | Kind_completion_rejected -> "completion_rejected"
  | Kind_completion_approved -> "completion_approved"
  | Kind_task_cancelled -> "task_cancelled"
  | Kind_workspace_message -> "workspace_message"
  | Kind_delegate -> "delegate"
  | Kind_composition -> "composition"
  | Kind_owned_job -> "owned_job"
;;

let kinds =
  [ Kind_board
  ; Kind_board_routing_pending
  ; Kind_board_attention
  ; Kind_bootstrap
  ; Kind_tool_result
  ; Kind_fusion
  ; Kind_schedule
  ; Kind_connector
  ; Kind_hitl
  ; Kind_ask
  ; Kind_completion_rejected
  ; Kind_completion_approved
  ; Kind_task_cancelled
  ; Kind_workspace_message
  ; Kind_delegate
  ; Kind_composition
  ; Kind_owned_job
  ]
;;

type event_kind =
  | Event_post_created
  | Event_post_updated
  | Event_comment_added
  | Event_reaction_changed
  | Event_vote_cast

let event_token = function
  | Event_post_created -> "post_created"
  | Event_post_updated -> "post_updated"
  | Event_comment_added -> "comment_added"
  | Event_reaction_changed -> "reaction_changed"
  | Event_vote_cast -> "vote_cast"
;;

let event_kinds =
  [ Event_post_created
  ; Event_post_updated
  ; Event_comment_added
  ; Event_reaction_changed
  ; Event_vote_cast
  ]
;;

type judge_kind =
  | Judge_human_operator
  | Judge_system_agent

let judge_token = function
  | Judge_human_operator -> "human_operator"
  | Judge_system_agent -> "system_agent"
;;

let judge_kinds = [ Judge_human_operator; Judge_system_agent ]

let board_fields { post; author; event } =
  let event_fields =
    match event with
    | Post_created -> [ f_event, event_token Event_post_created ]
    | Post_updated -> [ f_event, event_token Event_post_updated ]
    | Comment_added { comment } ->
      [ f_event, event_token Event_comment_added; f_comment, comment ]
    | Reaction_changed { by } -> [ f_event, event_token Event_reaction_changed; f_by, by ]
    | Vote_cast { by } -> [ f_event, event_token Event_vote_cast; f_by, by ]
  in
  (f_post, post) :: (f_author, author) :: event_fields
;;

let judge_fields = function
  | Human_operator { operator } ->
    [ f_judge, judge_token Judge_human_operator; f_operator, operator ]
  | System_agent { run } -> [ f_judge, judge_token Judge_system_agent; f_run, run ]
;;

let fields = function
  | Board item -> Kind_board, board_fields item
  | Board_routing_pending item -> Kind_board_routing_pending, board_fields item
  | Board_attention { candidate; item } ->
    Kind_board_attention, (f_candidate, candidate) :: board_fields item
  | Bootstrap -> Kind_bootstrap, []
  | Tool_result { receipt } -> Kind_tool_result, [ f_receipt, receipt ]
  | Fusion { run } -> Kind_fusion, [ f_run, run ]
  | Schedule { schedule; occurrence } ->
    Kind_schedule, [ f_schedule, schedule; f_occurrence, occurrence ]
  | Connector { attention } -> Kind_connector, [ f_attention, attention ]
  | Hitl { approval } -> Kind_hitl, [ f_approval, approval ]
  | Ask { ask } -> Kind_ask, [ f_ask, ask ]
  | Completion_rejected { task; verification; judge } ->
    ( Kind_completion_rejected
    , (f_task, task) :: (f_verification, verification) :: judge_fields judge )
  | Completion_approved { task; verification; judge } ->
    ( Kind_completion_approved
    , (f_task, task) :: (f_verification, verification) :: judge_fields judge )
  | Task_cancelled { task; by } -> Kind_task_cancelled, [ f_task, task; f_by, by ]
  | Workspace_message { request; from } ->
    Kind_workspace_message, [ f_request, request; f_from, from ]
  | Delegate { operation; keeper } -> Kind_delegate, [ f_operation, operation; f_keeper, keeper ]
  | Composition { request; tool } -> Kind_composition, [ f_request, request; f_tool, tool ]
  | Owned_job { job } -> Kind_owned_job, [ f_job, job ]
;;

let to_json stimulus =
  let kind, fields = fields stimulus in
  `Assoc
    ((f_kind, `String (kind_token kind))
     :: List.map (fun (name, text) -> name, `String text) fields)
;;

let ( let* ) = Result.bind

(* [also] is the fields of the kind besides the item's own. *)
let board_item ~also fields =
  let text field = wire_string_field field fields in
  let exact names = exact_field_names_result (f_kind :: f_post :: f_author :: f_event :: names) fields in
  let* event_kind = of_token ~token_of:event_token event_kinds f_event fields in
  let* event =
    match event_kind with
    | Event_post_created ->
      let* () = exact also in
      Ok Post_created
    | Event_post_updated ->
      let* () = exact also in
      Ok Post_updated
    | Event_comment_added ->
      let* () = exact (f_comment :: also) in
      let* comment = text f_comment in
      Ok (Comment_added { comment })
    | Event_reaction_changed ->
      let* () = exact (f_by :: also) in
      let* by = text f_by in
      Ok (Reaction_changed { by })
    | Event_vote_cast ->
      let* () = exact (f_by :: also) in
      let* by = text f_by in
      Ok (Vote_cast { by })
  in
  let* post = text f_post in
  let* author = text f_author in
  Ok { post; author; event }
;;

let judged fields =
  let text field = wire_string_field field fields in
  let exact names =
    exact_field_names_result (f_kind :: f_task :: f_verification :: f_judge :: names) fields
  in
  let* judge_kind = of_token ~token_of:judge_token judge_kinds f_judge fields in
  let* judge =
    match judge_kind with
    | Judge_human_operator ->
      let* () = exact [ f_operator ] in
      let* operator = text f_operator in
      Ok (Human_operator { operator })
    | Judge_system_agent ->
      let* () = exact [ f_run ] in
      let* run = text f_run in
      Ok (System_agent { run })
  in
  let* task = text f_task in
  let* verification = text f_verification in
  Ok (task, verification, judge)
;;

let of_json json =
  let* fields = object_fields json in
  let text field = wire_string_field field fields in
  let exact names = exact_field_names_result (f_kind :: names) fields in
  let* kind = of_token ~token_of:kind_token kinds f_kind fields in
  match kind with
  | Kind_board ->
    let* item = board_item ~also:[] fields in
    Ok (Board item)
  | Kind_board_routing_pending ->
    let* item = board_item ~also:[] fields in
    Ok (Board_routing_pending item)
  | Kind_board_attention ->
    let* item = board_item ~also:[ f_candidate ] fields in
    let* candidate = text f_candidate in
    Ok (Board_attention { candidate; item })
  | Kind_bootstrap ->
    let* () = exact [] in
    Ok Bootstrap
  | Kind_tool_result ->
    let* () = exact [ f_receipt ] in
    let* receipt = text f_receipt in
    Ok (Tool_result { receipt })
  | Kind_fusion ->
    let* () = exact [ f_run ] in
    let* run = text f_run in
    Ok (Fusion { run })
  | Kind_schedule ->
    let* () = exact [ f_schedule; f_occurrence ] in
    let* schedule = text f_schedule in
    let* occurrence = text f_occurrence in
    Ok (Schedule { schedule; occurrence })
  | Kind_connector ->
    let* () = exact [ f_attention ] in
    let* attention = text f_attention in
    Ok (Connector { attention })
  | Kind_hitl ->
    let* () = exact [ f_approval ] in
    let* approval = text f_approval in
    Ok (Hitl { approval })
  | Kind_ask ->
    let* () = exact [ f_ask ] in
    let* ask = text f_ask in
    Ok (Ask { ask })
  | Kind_completion_rejected ->
    let* task, verification, judge = judged fields in
    Ok (Completion_rejected { task; verification; judge })
  | Kind_completion_approved ->
    let* task, verification, judge = judged fields in
    Ok (Completion_approved { task; verification; judge })
  | Kind_task_cancelled ->
    let* () = exact [ f_task; f_by ] in
    let* task = text f_task in
    let* by = text f_by in
    Ok (Task_cancelled { task; by })
  | Kind_workspace_message ->
    let* () = exact [ f_request; f_from ] in
    let* request = text f_request in
    let* from = text f_from in
    Ok (Workspace_message { request; from })
  | Kind_delegate ->
    let* () = exact [ f_operation; f_keeper ] in
    let* operation = text f_operation in
    let* keeper = text f_keeper in
    Ok (Delegate { operation; keeper })
  | Kind_composition ->
    let* () = exact [ f_request; f_tool ] in
    let* request = text f_request in
    let* tool = text f_tool in
    Ok (Composition { request; tool })
  | Kind_owned_job ->
    let* () = exact [ f_job ] in
    let* job = text f_job in
    Ok (Owned_job { job })
;;
