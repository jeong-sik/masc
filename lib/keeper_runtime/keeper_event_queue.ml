type urgency =
  | Immediate
  | Normal
  | Low

let urgency_rank = function
  | Immediate -> 0
  | Normal -> 1
  | Low -> 2

type post_id = string

type board_stimulus_kind =
  | Post_created
  | Comment_added
  | Reaction_changed of board_reaction_change
  | Vote_cast of board_vote_change

and board_reaction_target_type =
  | Reaction_post
  | Reaction_comment

and board_reaction_change = {
  target_type : board_reaction_target_type;
  target_id : string;
  user_id : string;
  emoji : string;
  reacted : bool;
}

and board_vote_target =
  | Vote_on_post of string
  | Vote_on_comment of string

and board_vote_direction =
  | Vote_up
  | Vote_down

and board_vote_change = {
  target : board_vote_target;
  target_author : string;
  voter : string;
  direction : board_vote_direction;
}

type board_stimulus = {
  kind : board_stimulus_kind;
  author : string;
  title : string;
  content : string;
  hearth : string option;
  updated_at : float option;
}

type stimulus_payload =
  | Board_signal of board_stimulus
  | Board_attention of board_attention
  | Bootstrap
  | Fusion_completed of fusion_completion
      (* RFC-0266: an async [masc_fusion] deliberation finished. Wakes the
         calling keeper so the resolved answer arrives as actionable turn
         input on its next cycle, instead of being discovered passively. *)
  | Schedule_due of scheduled_wake
      (* A scheduled automation request reached its due time and explicitly
         targets this keeper. The scheduler/consumer side owns timing,
         approval, and payload validation; this queue payload only carries the
         typed wake and operator-authored message. *)
  | Connector_attention of connector_attention
      (* RFC-connector-ambient-attention-wake: an ambient connector message
         recorded as external attention. Carries the [event_id] pointer (not
         content). Dormant — no producer emits it yet (handle_ambient enqueuer
         lands in P3). *)
  | Hitl_resolved of hitl_resolution
  | Ask_answered of ask_answered
      (* A nonblocking HITL approval this keeper enqueued was resolved. Wakes
         the keeper so it re-evaluates and proceeds on its next independent
         cycle instead of waiting for unrelated stimulus or no-progress
         recovery. Blocking approvals resume their resolver directly and do
         not emit this duplicate wake. Mirrors
         [Fusion_completed]: a HITL decision is an async completion the
         waiting keeper must be notified of. *)
  | Completion_authority_rejected of completion_authority_rejection
  (* Cancellation is the one terminal outcome with no Board projection. This
     carries the cancellation to the Task's author. *)
  | Task_cancelled of task_cancellation
  (* A committed workspace message named this Keeper. The transcript row is the
     content SSOT; this payload carries the workspace request identity so the
     message is an entry in the linear drain rather than only a row a scan may
     or may not reach. *)
  | Workspace_message of workspace_message
  (* One Keeper asked another to run a turn and did not wait. This carries the
     answer back to the asker. Without it the answer is written down where
     only a screen reads it, and the asking Keeper has to remember to go
     looking — measured over 2026-08-17..24, nobody did: 4 delegations
     started, 0 status reads, 10 cancels. *)
  | Delegate_completed of delegate_completion
  (* An async composition the Keeper submitted has finished. The tool returns
     a request id and does not wait, so before this payload the result reached
     the submitter only if it remembered to read that id back -- measured over
     2026-08-18..26, 22 submissions produced 12 reads, and a result sat unread
     for a median of 21.9s against a median 2.7ms of work. One waited 47
     minutes. *)
  | Composition_completed of composition_completion

and board_attention = {
  candidate_id : string;
  signal : board_stimulus;
}

and fusion_completion = {
  run_id : string;
  terminal : fusion_terminal;
  board_post_id : string;
  (* correlates to the sink's board evidence post; "" if none was created. *)
  channel : Keeper_continuation_channel.t;
  (* RFC-0320 pattern: the connector conversation the deliberation was started
     from, captured at masc_fusion call time, so the woken keeper can deliver
     the resolved answer back into the originating channel.  [Unrouted] when
     the run was not started from a connector conversation. *)
}

and fusion_terminal =
  | Fusion_succeeded of string
  | Fusion_failed of string
  | Fusion_cancelled

and delegate_completion = {
  dc_operation_id : string;
  (* The id [masc_keeper_delegate] handed back, so the asker matches the
     answer to its own request without a second lookup. *)
  dc_keeper : string;
  (* Which Keeper ran the turn. *)
  dc_terminal : delegate_terminal;
}

and delegate_terminal =
  | Delegate_replied of string
  | Delegate_no_reply
  (* The turn ended without text to hand back — it either finished its work
     through a tool that posted elsewhere, or said nothing. Which of the two
     is not carried: neither gives the asker something to read, and one
     variant that says "no text" is the whole fact it acts on. *)
  | Delegate_failed of string


and composition_completion = {
  cc_request_id : string;
  (* The id the async composition tool handed back, so the submitter matches
     the result to its own request and can read it with
     [keeper_composition_status]. *)
  cc_tool : string;
  (* Which composition finished. A Keeper can have several in flight and the
     request id alone does not say which is which. *)
  cc_terminal : composition_terminal;
}

and composition_terminal =
  | Composition_succeeded
  (* No body. The result is already durable in the async request record and
     [keeper_composition_status] already reads it; copying it here would put
     the same bytes in two durable stores that can then disagree. This is the
     same choice [Connector_attention] makes about ambient message content. *)
  | Composition_failed of string
  | Composition_cancelled of string

and ask_answered = {
  ask_id : string;
  (* The answered question. Only the pointer travels: the answer text lives in
     [Keeper_ask_store] and the woken keeper reads it there, the same choice
     [Connector_attention] makes about ambient message content. *)
  channel : Keeper_continuation_channel.t;
  (* Where the question was asked from, captured when the keeper asked and
     carried through so a woken keeper answers into that conversation rather
     than its own state. [Unrouted] when the ask named no channel. *)
}

and hitl_resolution_decision =
  | Hitl_approved
  | Hitl_rejected of string

and hitl_resolution = {
  approval_id : string;
  (* the resolved pending-approval id; correlates to the queue entry. *)
  decision : hitl_resolution_decision;
  (* resolved decision label carried for observability. *)
  channel : Keeper_continuation_channel.t;
  (* RFC-0320: the connector the resolved conversation started on, captured at
     approval-submission time and carried through so a woken keeper can reply
     into it. [Unrouted] when no originating connector was captured. *)
}

and connector_attention = {
  event_id : string;
      (* RFC-connector-ambient-attention-wake: pointer into
         [Keeper_external_attention] for the ambient message; content/surface
         read from that store on the turn path. *)
  channel : Keeper_continuation_channel.t;
      (* RFC-0320: the connector that raised this attention, so a woken keeper
         replies into the same channel. [Unrouted] when unknown. *)
}

and scheduled_wake = {
  occurrence_id : string;
  schedule_instance_id : string;
  schedule_id : string;
  due_at : float;
  payload_digest : string;
  title : string option;
  message : string;
  result_delivery : Keeper_continuation_channel.t option;
}

and completion_authority_rejection = {
  car_task_id : string;
  car_verification_id : string;
  car_reason : string;
  car_authority : Masc_domain.completion_authority;
}

and task_cancellation = {
  tc_task_id : string;
  tc_cancelled_by : string;
  tc_reason : string option;
}

and workspace_message = {
  wmsg_request_id : string;
  wmsg_from : string;
}

let workspace_message_post_id (message : workspace_message) =
  "workspace-message:" ^ message.wmsg_request_id

let fusion_completion_post_id (fc : fusion_completion) = "fusion-run:" ^ fc.run_id

let delegate_completion_post_id (dc : delegate_completion) =
  "keeper-delegate:" ^ dc.dc_operation_id

let composition_completion_post_id (cc : composition_completion) =
  "keeper-composition:" ^ cc.cc_request_id

let hitl_resolution_post_id (r : hitl_resolution) = "hitl-approval:" ^ r.approval_id

let ask_answered_post_id (a : ask_answered) = "keeper-ask:" ^ a.ask_id

let completion_authority_rejection_post_id
      (rejection : completion_authority_rejection)
  =
  "completion-authority-rejected:" ^ rejection.car_task_id ^ ":"
  ^ rejection.car_verification_id

(* Cancellation is terminal, so the task id alone is a complete key: a second
   cancellation of the same task cannot occur. *)
let task_cancellation_post_id (cancellation : task_cancellation) =
  "task-cancelled:" ^ cancellation.tc_task_id

let hitl_resolution_decision_to_string = function
  | Hitl_approved -> "approve"
  | Hitl_rejected _ -> "reject"

type stimulus = {
  post_id : post_id;
  urgency : urgency;
  arrived_at : float;
  payload : stimulus_payload;
}

type t =
  { front : stimulus list
  ; back_rev : stimulus list
  ; length : int
  }

let empty : t = { front = []; back_rev = []; length = 0 }

let length q = q.length

let is_empty q = q.length = 0

let enqueue (queue : t) (s : stimulus) : t =
  { queue with back_rev = s :: queue.back_rev; length = queue.length + 1 }

(* Identity projection: durable-event identity must ignore display-only
   payload fields, or repeats of the same event with volatile text (token
   counts, addresses, timestamps inside provider error strings) defeat
   [enqueue_if_missing]/[dedup_by_identity] and the queue grows unbounded.
   Exhaustive on purpose: a new
   payload kind must decide its identity fields here at compile time. *)
let identity_payload = function
  | Task_cancelled cancellation ->
    (* The reason is operator-facing prose whose wording can vary between
       retries of the same cancellation; identity is the task and who ended
       it. *)
    Task_cancelled { cancellation with tc_reason = None }
  | ( Board_signal _ | Board_attention _ | Bootstrap | Fusion_completed _
    | Schedule_due _ | Connector_attention _ | Hitl_resolved _
    | Ask_answered _
    | Completion_authority_rejected _ | Workspace_message _
    | Delegate_completed _ | Composition_completed _
    ) as payload ->
    payload

let fusion_terminal_equal left right =
  match left, right with
  | Fusion_succeeded left, Fusion_succeeded right
  | Fusion_failed left, Fusion_failed right -> String.equal left right
  | Fusion_cancelled, Fusion_cancelled -> true
  | Fusion_succeeded _, (Fusion_failed _ | Fusion_cancelled)
  | Fusion_failed _, (Fusion_succeeded _ | Fusion_cancelled)
  | Fusion_cancelled, (Fusion_succeeded _ | Fusion_failed _) -> false

let fusion_completion_identity_equal left right =
  String.equal left.run_id right.run_id
  && fusion_terminal_equal left.terminal right.terminal
  && String.equal left.board_post_id right.board_post_id
  (* The first durably committed row owns recipient authority. The channel is
     recipient metadata, not result identity: a replay sources it from the
     durable delivery obligation, but a first commit can legitimately carry
     [Unrouted] (obligation unavailable at projection time) while a later
     startup recovery replays the same result with the recovered channel.
     Treating [channel] as event identity would turn that exact result replay
     into a false conflict. [enqueue_external_decision] retains the existing
     row, so excluding the channel here never overwrites the authoritative
     recipient. *)

let stimulus_identity_equal a b =
  String.equal a.post_id b.post_id
  && a.urgency = b.urgency
  &&
  match a.payload, b.payload with
  | Fusion_completed left, Fusion_completed right ->
    fusion_completion_identity_equal left right
  | Schedule_due _, Schedule_due _ ->
    (* [post_id] is the scheduler occurrence identity.  Pre-occurrence-id
       durable rows decode with an empty payload [occurrence_id], while a
       replay after upgrade carries the same occurrence in both places.  The
       first committed row owns the payload, so comparing the payload again
       would turn that representation upgrade into a second execution. *)
    true
  | _ -> identity_payload a.payload = identity_payload b.payload

let to_list (queue : t) : stimulus list =
  match queue.back_rev with
  | [] -> queue.front
  | back_rev -> queue.front @ List.rev back_rev

let of_list (items : stimulus list) : t =
  { front = items; back_rev = []; length = List.length items }

let dequeue (queue : t) : (stimulus * t) option =
  match queue.front with
  | s :: rest -> Some (s, { queue with front = rest; length = queue.length - 1 })
  | [] ->
    (match List.rev queue.back_rev with
     | [] -> None
     | s :: rest -> Some (s, { front = rest; back_rev = []; length = queue.length - 1 }))

let remove_by_post_id post_id queue =
  let removed, kept =
    queue
    |> to_list
    |> List.partition (fun stimulus -> String.equal stimulus.post_id post_id)
  in
  removed, of_list kept

(* Scans both halves of the queue directly instead of rebuilding it through
   repeated [dequeue], so membership stays allocation-free. *)
let contains (queue : t) (stimulus : stimulus) : bool =
  let same head = stimulus_identity_equal head stimulus in
  List.exists same queue.front || List.exists same queue.back_rev

let uniq_stimuli stimuli =
  List.fold_left
    (fun acc stimulus ->
       if List.exists (stimulus_identity_equal stimulus) acc
       then acc
       else stimulus :: acc)
    []
    stimuli
  |> List.rev

let sort_by_urgency (queue : t) : t =
  queue
  |> to_list
  |> List.stable_sort
       (fun a b -> Int.compare (urgency_rank a.urgency) (urgency_rank b.urgency))
  |> of_list

(* Starvation fix for #31597: [Low] competes forever against a Keeper's own
   continuous [Normal] backlog (explicit task work, board mentions) under a
   strict-priority selector with no fairness correction — measured as a
   16-day-old recurring schedule that dispatched "succeeded" every hour
   without a single Board post ever landing. 3600s matches the cadence most
   recurring schedules in this fleet already use; it is a reasoned default,
   not a measured distribution (unlike the dated comments elsewhere in this
   file — there is no equivalent aging measurement yet). [Normal] is never
   aged into [Immediate]: [Immediate] is a producer-declared contract (see
   keeper_composition_completion_wake.ml) reserved for "this Keeper is
   waiting on an answer to something it asked for," and letting aging blur
   into that would erode the one guarantee Immediate still gives callers. *)
let low_to_normal_aging_threshold_sec = 3600.0

let effective_urgency ~now (s : stimulus) : urgency =
  match s.urgency with
  | Low when now -. s.arrived_at >= low_to_normal_aging_threshold_sec -> Normal
  | u -> u
;;

let effective_urgency_rank ~now (s : stimulus) : int =
  urgency_rank (effective_urgency ~now s)
;;

let payload_kind_label = function
  | Board_signal _ -> "board_signal"
  | Board_attention _ -> "board_attention"
  | Bootstrap -> "bootstrap"
  | Fusion_completed _ -> "fusion_completed"
  | Schedule_due _ -> "schedule_due"
  | Connector_attention _ -> "connector_attention"
  | Hitl_resolved _ -> "hitl_resolved"
  | Ask_answered _ -> "ask_answered"
  | Completion_authority_rejected _ -> "completion_authority_rejected"
  | Task_cancelled _ -> "task_cancelled"
  | Workspace_message _ -> "workspace_message"
  | Delegate_completed _ -> "keeper_delegate_completed"
  | Composition_completed _ -> "keeper_composition_completed"

let is_board_signal = function
  | Board_signal _ | Board_attention _ -> true
  | Bootstrap | Fusion_completed _
  | Schedule_due _ | Connector_attention _ | Hitl_resolved _
  | Ask_answered _
  | Completion_authority_rejected _
  | Task_cancelled _ | Workspace_message _ | Delegate_completed _
  | Composition_completed _ ->
    false

(* RFC-0377: the batch-intake predicate needs the routed channel without
   repeating the payload match at every call site. Exhaustive on purpose,
   like [is_board_signal] above: a new payload kind must decide here at
   compile time whether it carries a conversation channel. *)
let connector_attention_channel = function
  | Connector_attention { channel; _ } -> Some channel
  (* [Ask_answered] carries a channel but answers [None] here on purpose. This
     predicate holds a stimulus back when another conversation has already
     claimed the batch; an answer to a question this keeper asked is not
     ambient conversation traffic and must not wait behind one. *)
  | Ask_answered _
  | Board_signal _ | Board_attention _ | Bootstrap | Fusion_completed _
  | Schedule_due _ | Hitl_resolved _
  | Completion_authority_rejected _ | Task_cancelled _ | Workspace_message _
  | Delegate_completed _ | Composition_completed _ ->
    None

let drain_board_all (queue : t) : stimulus list * t =
  let board, rest =
    List.partition (fun s -> is_board_signal s.payload) (to_list queue)
  in
  (to_list (sort_by_urgency (of_list board)), of_list rest)

let summary (queue : t) : string =
  Printf.sprintf "%d stimulus%s pending"
    queue.length
    (if queue.length = 1 then "" else "es")

let urgency_to_string = function
  | Immediate -> "immediate"
  | Normal -> "normal"
  | Low -> "low"

let urgency_of_string = function
  | "immediate" -> Ok Immediate
  | "normal" -> Ok Normal
  | "low" -> Ok Low
  | value -> Error (Printf.sprintf "unknown urgency: %s" value)

let board_stimulus_kind_to_string = function
  | Post_created -> "post_created"
  | Comment_added -> "comment_added"
  | Reaction_changed _ -> "reaction_changed"
  | Vote_cast _ -> "vote_cast"

let board_stimulus_kind_of_string = function
  | "post_created" -> Ok Post_created
  | "comment_added" -> Ok Comment_added
  | "reaction_changed" ->
    Error "reaction_changed board stimulus requires reaction payload fields"
  | "vote_cast" -> Error "vote_cast board stimulus requires vote payload fields"
  | value -> Error (Printf.sprintf "unknown board stimulus kind: %s" value)

let board_reaction_target_type_to_string = function
  | Reaction_post -> "post"
  | Reaction_comment -> "comment"

let board_reaction_target_type_of_string = function
  | "post" -> Ok Reaction_post
  | "comment" -> Ok Reaction_comment
  | value -> Error (Printf.sprintf "unknown board reaction target type: %s" value)

let board_vote_target_fields = function
  | Vote_on_post post_id ->
    [ "vote_target_kind", `String "post"; "vote_target_id", `String post_id ]
  | Vote_on_comment comment_id ->
    [ "vote_target_kind", `String "comment"; "vote_target_id", `String comment_id ]

let board_vote_target_of_strings ~kind ~target_id =
  match kind with
  | "post" -> Ok (Vote_on_post target_id)
  | "comment" -> Ok (Vote_on_comment target_id)
  | value -> Error (Printf.sprintf "unknown board vote target kind: %s" value)

let board_vote_direction_to_string = function
  | Vote_up -> "up"
  | Vote_down -> "down"

let board_vote_direction_of_string = function
  | "up" -> Ok Vote_up
  | "down" -> Ok Vote_down
  | value -> Error (Printf.sprintf "unknown board vote direction: %s" value)

let option_json f = function
  | Some value -> f value
  | None -> `Null

let ( let* ) = Result.bind

let board_reaction_change_fields (reaction : board_reaction_change) =
  [ "reaction_target_type", `String (board_reaction_target_type_to_string reaction.target_type)
  ; "reaction_target_id", `String reaction.target_id
  ; "reaction_user_id", `String reaction.user_id
  ; "reaction_emoji", `String reaction.emoji
  ; "reaction_active", `Bool reaction.reacted
  ]

let board_vote_change_fields (vote : board_vote_change) =
  board_vote_target_fields vote.target
  @ [ "vote_target_author", `String vote.target_author
    ; "vote_voter", `String vote.voter
    ; "vote_direction", `String (board_vote_direction_to_string vote.direction)
    ]

let board_stimulus_fields board =
  [ "board_kind", `String (board_stimulus_kind_to_string board.kind)
  ; "author", `String board.author
  ; "title", `String board.title
  ; "content", `String board.content
  ; "hearth", option_json (fun value -> `String value) board.hearth
  ; "updated_at_unix", option_json (fun value -> `Float value) board.updated_at
  ]
  @
  match board.kind with
  | Post_created | Comment_added -> []
  | Reaction_changed reaction -> board_reaction_change_fields reaction
  | Vote_cast vote -> board_vote_change_fields vote

let assoc_fields ~context = function
  | `Assoc fields -> Ok fields
  | _ -> Error (Printf.sprintf "%s must be a JSON object" context)

let required_field ~context name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s missing required field %s" context name)

let exact_fields ~context ~expected fields =
  let actual = List.map fst fields |> List.sort String.compare in
  let expected = List.sort String.compare expected in
  if actual = expected
  then Ok ()
  else
    Error
      (Printf.sprintf
         "%s fields must be exactly [%s], got [%s]"
         context
         (String.concat "," expected)
         (String.concat "," actual))

let optional_field name fields =
  match List.assoc_opt name fields with
  | Some `Null | None -> None
  | Some value -> Some value

let string_of_json ~context = function
  | `String value -> Ok value
  | _ -> Error (Printf.sprintf "%s must be a string" context)

let bool_of_json ~context = function
  | `Bool value -> Ok value
  | _ -> Error (Printf.sprintf "%s must be a boolean" context)

let float_of_json ~context = function
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error (Printf.sprintf "%s must be a number" context)

let optional_string_field ~context name fields =
  match optional_field name fields with
  | None -> Ok None
  | Some json ->
    let* value = string_of_json ~context:(context ^ "." ^ name) json in
    Ok (Some value)

let optional_float_field ~context name fields =
  match optional_field name fields with
  | None -> Ok None
  | Some json ->
    let* value = float_of_json ~context:(context ^ "." ^ name) json in
    Ok (Some value)

let string_field ~context name fields =
  let* json = required_field ~context name fields in
  string_of_json ~context:(context ^ "." ^ name) json

let bool_field ~context name fields =
  let* json = required_field ~context name fields in
  bool_of_json ~context:(context ^ "." ^ name) json

let float_field ~context name fields =
  let* json = required_field ~context name fields in
  float_of_json ~context:(context ^ "." ^ name) json

let payload_to_yojson = function
  | Board_signal board ->
    `Assoc
      ([ "kind", `String "board_signal" ] @ board_stimulus_fields board)
  | Board_attention attention ->
    `Assoc
      ([ "kind", `String "board_attention"
       ; "candidate_id", `String attention.candidate_id
       ]
       @ board_stimulus_fields attention.signal)
  | Bootstrap -> `Assoc [ "kind", `String "bootstrap" ]
  | Fusion_completed fusion ->
    let terminal =
      match fusion.terminal with
      | Fusion_succeeded answer ->
        `Assoc [ "kind", `String "succeeded"; "message", `String answer ]
      | Fusion_failed detail ->
        `Assoc [ "kind", `String "failed"; "message", `String detail ]
      | Fusion_cancelled -> `Assoc [ "kind", `String "cancelled" ]
    in
    `Assoc
      [ "kind", `String "fusion_completed"
      ; "run_id", `String fusion.run_id
      ; "terminal", terminal
      ; "board_post_id", `String fusion.board_post_id
      ; "channel", Keeper_continuation_channel.to_yojson fusion.channel
      ]
  | Schedule_due sw ->
    `Assoc
      [ "kind", `String "schedule_due"
      ; "occurrence_id", `String sw.occurrence_id
      ; "schedule_instance_id", `String sw.schedule_instance_id
      ; "schedule_id", `String sw.schedule_id
      ; "due_at_unix", `Float sw.due_at
      ; "payload_digest", `String sw.payload_digest
      ; "title", option_json (fun value -> `String value) sw.title
      ; "message", `String sw.message
      ; ( "result_delivery"
        , match sw.result_delivery with
          | None -> `Null
          | Some channel -> Keeper_continuation_channel.to_yojson channel )
      ]
  | Ask_answered a ->
    `Assoc
      [ "kind", `String "ask_answered"
      ; "ask_id", `String a.ask_id
      ; "channel", Keeper_continuation_channel.to_yojson a.channel
      ]
  | Connector_attention ca ->
    `Assoc
      [ "kind", `String "connector_attention"
      ; "event_id", `String ca.event_id
      ; "channel", Keeper_continuation_channel.to_yojson ca.channel
      ]
  | Hitl_resolved r ->
    `Assoc
      ([ "kind", `String "hitl_resolved"
       ; "approval_id", `String r.approval_id
       ; "decision", `String (hitl_resolution_decision_to_string r.decision)
       ; "channel", Keeper_continuation_channel.to_yojson r.channel
       ]
       @
       match r.decision with
       | Hitl_approved -> []
       | Hitl_rejected rationale -> [ "rationale", `String rationale ])
  | Completion_authority_rejected rejection ->
    `Assoc
      [ "kind", `String "completion_authority_rejected"
      ; "task_id", `String rejection.car_task_id
      ; "verification_id", `String rejection.car_verification_id
      ; "reason", `String rejection.car_reason
      ; ( "authority_kind"
        , `String
            (Masc_domain.completion_authority_kind rejection.car_authority) )
      ; ( "authority_actor"
        , `String
            (Masc_domain.completion_authority_actor rejection.car_authority) )
      ]
  | Task_cancelled cancellation ->
    `Assoc
      [ "kind", `String "task_cancelled"
      ; "task_id", `String cancellation.tc_task_id
      ; "cancelled_by", `String cancellation.tc_cancelled_by
      ; ( "reason"
        , match cancellation.tc_reason with
          | None -> `Null
          | Some reason -> `String reason )
      ]
  | Workspace_message message ->
    `Assoc
      [ "kind", `String "workspace_message"
      ; "request_id", `String message.wmsg_request_id
      ; "from", `String message.wmsg_from
      ]
  | Delegate_completed dc ->
    let terminal =
      match dc.dc_terminal with
      | Delegate_replied reply ->
        `Assoc [ "kind", `String "replied"; "message", `String reply ]
      | Delegate_no_reply -> `Assoc [ "kind", `String "no_reply" ]
      | Delegate_failed detail ->
        `Assoc [ "kind", `String "failed"; "message", `String detail ]
    in
    `Assoc
      [ "kind", `String "keeper_delegate_completed"
      ; "operation_id", `String dc.dc_operation_id
      ; "keeper", `String dc.dc_keeper
      ; "terminal", terminal
      ]
  | Composition_completed cc ->
    let terminal =
      match cc.cc_terminal with
      | Composition_succeeded -> `Assoc [ "kind", `String "succeeded" ]
      | Composition_failed detail ->
        `Assoc [ "kind", `String "failed"; "message", `String detail ]
      | Composition_cancelled reason ->
        `Assoc [ "kind", `String "cancelled"; "message", `String reason ]
    in
    `Assoc
      [ "kind", `String "keeper_composition_completed"
      ; "request_id", `String cc.cc_request_id
      ; "tool", `String cc.cc_tool
      ; "terminal", terminal
      ]

let continuation_channel_field fields =
  let* json = required_field ~context:"stimulus.payload" "channel" fields in
  Keeper_continuation_channel.of_yojson json

let payload_of_yojson json =
  let context = "stimulus.payload" in
  let* fields = assoc_fields ~context json in
  let kind_count =
    List.fold_left
      (fun count (name, _) -> if String.equal name "kind" then count + 1 else count)
      0
      fields
  in
  let* () =
    if kind_count = 1
    then Ok ()
    else Error (Printf.sprintf "%s.kind must occur exactly once" context)
  in
  let* kind = string_field ~context "kind" fields in
  let parse_board_stimulus () =
    let* board_kind = string_field ~context "board_kind" fields in
    let* kind =
      match board_kind with
      | "reaction_changed" ->
        let* target_type_raw = string_field ~context "reaction_target_type" fields in
        let* target_type = board_reaction_target_type_of_string target_type_raw in
        let* target_id = string_field ~context "reaction_target_id" fields in
        let* user_id = string_field ~context "reaction_user_id" fields in
        let* emoji = string_field ~context "reaction_emoji" fields in
        let* reacted = bool_field ~context "reaction_active" fields in
        Ok (Reaction_changed { target_type; target_id; user_id; emoji; reacted })
      | "vote_cast" ->
        let* kind = string_field ~context "vote_target_kind" fields in
        let* target_id = string_field ~context "vote_target_id" fields in
        let* target = board_vote_target_of_strings ~kind ~target_id in
        let* target_author = string_field ~context "vote_target_author" fields in
        let* voter = string_field ~context "vote_voter" fields in
        let* direction_raw = string_field ~context "vote_direction" fields in
        let* direction = board_vote_direction_of_string direction_raw in
        Ok (Vote_cast { target; target_author; voter; direction })
      | _ -> board_stimulus_kind_of_string board_kind
    in
    let* author = string_field ~context "author" fields in
    let* title = string_field ~context "title" fields in
    let* content = string_field ~context "content" fields in
    let* hearth = optional_string_field ~context "hearth" fields in
    let* updated_at = optional_float_field ~context "updated_at_unix" fields in
    Ok { kind; author; title; content; hearth; updated_at }
  in
  match kind with
  | "board_signal" ->
    let* signal = parse_board_stimulus () in
    Ok (Board_signal signal)
  | "board_attention" ->
    let* candidate_id = string_field ~context "candidate_id" fields in
    if String.equal candidate_id ""
    then Error "stimulus.payload.candidate_id must not be empty"
    else
      let* signal = parse_board_stimulus () in
      Ok (Board_attention { candidate_id; signal })
  | "bootstrap" -> Ok Bootstrap
  | "fusion_completed" ->
    let* () =
      exact_fields
        ~context
        ~expected:[ "kind"; "run_id"; "terminal"; "board_post_id"; "channel" ]
        fields
    in
    let* run_id = string_field ~context "run_id" fields in
    let* terminal =
      let* terminal_json = required_field ~context "terminal" fields in
      let* terminal_fields =
        assoc_fields ~context:"stimulus.payload.terminal" terminal_json
      in
      let* terminal_kind =
        string_field ~context:"stimulus.payload.terminal" "kind" terminal_fields
      in
      match terminal_kind with
      | "succeeded" ->
        let* () =
          exact_fields
            ~context:"stimulus.payload.terminal"
            ~expected:[ "kind"; "message" ]
            terminal_fields
        in
        let* answer =
          string_field ~context:"stimulus.payload.terminal" "message" terminal_fields
        in
        Ok (Fusion_succeeded answer)
      | "failed" ->
        let* () =
          exact_fields
            ~context:"stimulus.payload.terminal"
            ~expected:[ "kind"; "message" ]
            terminal_fields
        in
        let* detail =
          string_field ~context:"stimulus.payload.terminal" "message" terminal_fields
        in
        Ok (Fusion_failed detail)
      | "cancelled" ->
        let* () =
          exact_fields
            ~context:"stimulus.payload.terminal"
            ~expected:[ "kind" ]
            terminal_fields
        in
        Ok Fusion_cancelled
      | value -> Error (Printf.sprintf "unknown fusion terminal kind: %s" value)
    in
    let* board_post_id = string_field ~context "board_post_id" fields in
    let* channel = continuation_channel_field fields in
    Ok (Fusion_completed { run_id; terminal; board_post_id; channel })
  | "schedule_due" ->
    let allowed_fields =
      [ "kind"
      ; "occurrence_id"
      ; "schedule_instance_id"
      ; "schedule_id"
      ; "due_at_unix"
      ; "payload_digest"
      ; "title"
      ; "message"
      ; "result_delivery"
      ]
    in
    let field_names = List.map fst fields in
    let* () =
      if
        List.length field_names
        = List.length (List.sort_uniq String.compare field_names)
      then Ok ()
      else Error "stimulus.payload.schedule_due has duplicate fields"
    in
    let* () =
      match
        List.find_opt
          (fun name -> not (List.mem name allowed_fields))
          field_names
      with
      | None -> Ok ()
      | Some name ->
        Error ("stimulus.payload.schedule_due has unknown field: " ^ name)
    in
    let* occurrence_id =
      match List.assoc_opt "occurrence_id" fields with
      | None -> Ok ""
      | Some _ -> string_field ~context "occurrence_id" fields
    in
    let* schedule_instance_id = string_field ~context "schedule_instance_id" fields in
    let* schedule_id = string_field ~context "schedule_id" fields in
    let* due_at = float_field ~context "due_at_unix" fields in
    let* payload_digest = string_field ~context "payload_digest" fields in
    let* title = optional_string_field ~context "title" fields in
    let* message = string_field ~context "message" fields in
    let* result_delivery =
      match List.assoc_opt "result_delivery" fields with
      | None | Some `Null -> Ok None
      | Some channel_json ->
        Keeper_continuation_channel.of_yojson channel_json
        |> Result.map Option.some
    in
    let* () =
      match result_delivery with
      | None -> Ok ()
      | Some _ when String.trim occurrence_id = "" ->
        Error "stimulus.payload.schedule_due delivery requires occurrence_id"
      | Some channel when not (Keeper_continuation_channel.is_routable channel) ->
        Error "stimulus.payload.schedule_due result_delivery must be routable"
      | Some _ -> Ok ()
    in
    Ok
      (Schedule_due
         { occurrence_id
         ; schedule_instance_id
         ; schedule_id
         ; due_at
         ; payload_digest
         ; title
         ; message
         ; result_delivery
         })
  | "connector_attention" ->
    let* event_id = string_field ~context "event_id" fields in
    let* channel = continuation_channel_field fields in
    Ok (Connector_attention { event_id; channel })
  | "ask_answered" ->
    let* ask_id = string_field ~context "ask_id" fields in
    let* channel = continuation_channel_field fields in
    Ok (Ask_answered { ask_id; channel })
  | "hitl_resolved" ->
    let* approval_id = string_field ~context "approval_id" fields in
    let* decision_s = string_field ~context "decision" fields in
    let* decision =
      match decision_s with
      | "approve" -> Ok Hitl_approved
      | "reject" ->
        let* rationale = string_field ~context "rationale" fields in
        Ok (Hitl_rejected rationale)
      | other -> Error (Printf.sprintf "unknown hitl_resolution decision: %s" other)
    in
    let* channel = continuation_channel_field fields in
    Ok (Hitl_resolved { approval_id; decision; channel })
  | "completion_authority_rejected" ->
    let* () =
      exact_fields
        ~context
        ~expected:
          [ "kind"
          ; "task_id"
          ; "verification_id"
          ; "reason"
          ; "authority_kind"
          ; "authority_actor"
          ]
        fields
    in
    let* task_id = string_field ~context "task_id" fields in
    let* verification_id = string_field ~context "verification_id" fields in
    let* reason = string_field ~context "reason" fields in
    let* authority_kind = string_field ~context "authority_kind" fields in
    let* authority_actor = string_field ~context "authority_actor" fields in
    let* () =
      if String.equal (String.trim authority_actor) ""
      then Error "completion authority actor must not be empty"
      else Ok ()
    in
    let* authority =
      match authority_kind with
      | "system_llm_agent" ->
        Ok (Masc_domain.System_llm_agent { agent_run_id = authority_actor })
      | "human_operator" ->
        Ok (Masc_domain.Human_operator { operator_id = authority_actor })
      | value ->
        Error
          (Printf.sprintf
             "unknown completion authority kind: %s"
             value)
    in
    Ok
      (Completion_authority_rejected
         { car_task_id = task_id
         ; car_verification_id = verification_id
         ; car_reason = reason
         ; car_authority = authority
         })
  | "task_cancelled" ->
    let* () =
      exact_fields
        ~context
        ~expected:[ "kind"; "task_id"; "cancelled_by"; "reason" ]
        fields
    in
    let* task_id = string_field ~context "task_id" fields in
    let* cancelled_by = string_field ~context "cancelled_by" fields in
    (* [`Null] is the durable encoding of "no reason given" and round-trips
       back to [None]; a missing field is a malformed record, not a silent
       absence. *)
    let* reason =
      match List.assoc_opt "reason" fields with
      | Some `Null -> Ok None
      | Some (`String reason) -> Ok (Some reason)
      | Some _ -> Error (context ^ ".reason must be a string or null")
      | None -> Error (context ^ ".reason is missing")
    in
    Ok
      (Task_cancelled
         { tc_task_id = task_id; tc_cancelled_by = cancelled_by; tc_reason = reason })
  | "workspace_message" ->
    let* () =
      exact_fields ~context ~expected:[ "kind"; "request_id"; "from" ] fields
    in
    let* request_id = string_field ~context "request_id" fields in
    let* from = string_field ~context "from" fields in
    Ok (Workspace_message { wmsg_request_id = request_id; wmsg_from = from })
  | "keeper_delegate_completed" ->
    let* () =
      exact_fields
        ~context
        ~expected:[ "kind"; "operation_id"; "keeper"; "terminal" ]
        fields
    in
    let* operation_id = string_field ~context "operation_id" fields in
    let* keeper = string_field ~context "keeper" fields in
    let* terminal_json = required_field ~context "terminal" fields in
    let* terminal_fields =
      assoc_fields ~context:"stimulus.payload.terminal" terminal_json
    in
    let* terminal_kind =
      string_field ~context:"stimulus.payload.terminal" "kind" terminal_fields
    in
    let* terminal =
      match terminal_kind with
      | "replied" | "failed" ->
        let* () =
          exact_fields
            ~context:"stimulus.payload.terminal"
            ~expected:[ "kind"; "message" ]
            terminal_fields
        in
        let* message =
          string_field ~context:"stimulus.payload.terminal" "message" terminal_fields
        in
        Ok
          (if String.equal terminal_kind "replied"
           then Delegate_replied message
           else Delegate_failed message)
      | "no_reply" ->
        let* () =
          exact_fields
            ~context:"stimulus.payload.terminal"
            ~expected:[ "kind" ]
            terminal_fields
        in
        Ok Delegate_no_reply
      | value ->
        Error (Printf.sprintf "unknown keeper delegate terminal kind: %s" value)
    in
    Ok
      (Delegate_completed
         { dc_operation_id = operation_id; dc_keeper = keeper; dc_terminal = terminal })
  | "keeper_composition_completed" ->
    let* () =
      exact_fields
        ~context
        ~expected:[ "kind"; "request_id"; "tool"; "terminal" ]
        fields
    in
    let* request_id = string_field ~context "request_id" fields in
    let* tool = string_field ~context "tool" fields in
    let* terminal_json = required_field ~context "terminal" fields in
    let* terminal_fields =
      assoc_fields ~context:"stimulus.payload.terminal" terminal_json
    in
    let* terminal_kind =
      string_field ~context:"stimulus.payload.terminal" "kind" terminal_fields
    in
    let* terminal =
      match terminal_kind with
      | "succeeded" ->
        let* () =
          exact_fields
            ~context:"stimulus.payload.terminal"
            ~expected:[ "kind" ]
            terminal_fields
        in
        Ok Composition_succeeded
      | "failed" | "cancelled" ->
        let* () =
          exact_fields
            ~context:"stimulus.payload.terminal"
            ~expected:[ "kind"; "message" ]
            terminal_fields
        in
        let* message =
          string_field ~context:"stimulus.payload.terminal" "message" terminal_fields
        in
        Ok
          (if String.equal terminal_kind "failed"
           then Composition_failed message
           else Composition_cancelled message)
      | value ->
        Error (Printf.sprintf "unknown keeper composition terminal kind: %s" value)
    in
    Ok
      (Composition_completed
         { cc_request_id = request_id; cc_tool = tool; cc_terminal = terminal })
  | value -> Error (Printf.sprintf "unknown stimulus payload kind: %s" value)

let stimulus_to_yojson (stimulus : stimulus) =
  `Assoc
    [ "post_id", `String stimulus.post_id
    ; "urgency", `String (urgency_to_string stimulus.urgency)
    ; "arrived_at_unix", `Float stimulus.arrived_at
    ; "payload", payload_to_yojson stimulus.payload
    ]

let stimulus_of_yojson json =
  let context = "stimulus" in
  let* fields = assoc_fields ~context json in
  let* () =
    exact_fields
      ~context
      ~expected:[ "post_id"; "urgency"; "arrived_at_unix"; "payload" ]
      fields
  in
  let* post_id = string_field ~context "post_id" fields in
  let* urgency_s = string_field ~context "urgency" fields in
  let* urgency = urgency_of_string urgency_s in
  let* arrived_at = float_field ~context "arrived_at_unix" fields in
  let* payload_json = required_field ~context "payload" fields in
  let* payload = payload_of_yojson payload_json in
  Ok { post_id; urgency; arrived_at; payload }

let schema = "keeper.event_queue.v2"

let queue_to_yojson queue =
  `Assoc
    [ "schema", `String schema
    ; "length", `Int (length queue)
    ; "items", `List (List.map stimulus_to_yojson (to_list queue))
    ]

let list_of_json ~context f = function
  | `List items ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        let* parsed = f item in
        loop (parsed :: acc) rest
    in
    loop [] items
  | _ -> Error (Printf.sprintf "%s must be a JSON list" context)

let queue_of_yojson json =
  let context = "keeper event queue snapshot" in
  let* fields = assoc_fields ~context json in
  let* schema_value = string_field ~context "schema" fields in
  if not (String.equal schema_value schema)
  then Error (Printf.sprintf "unsupported keeper event queue schema: %s" schema_value)
  else (
    let* items_json = required_field ~context "items" fields in
    let* items = list_of_json ~context:"keeper event queue snapshot.items" stimulus_of_yojson items_json in
    Ok (of_list items))

let continuation_channel_of_payload = function
  | Fusion_completed completion -> Some completion.channel
  | Hitl_resolved resolution -> Some resolution.channel
  | Connector_attention attention -> Some attention.channel
  (* Where the question was asked. A keeper woken by an answer replies there
     rather than wherever its own state last left it. *)
  | Ask_answered answered -> Some answered.channel
  | Schedule_due wake -> wake.result_delivery
  | Board_signal _
  | Board_attention _
  | Bootstrap
  | Completion_authority_rejected _
  | Task_cancelled _
  | Workspace_message _
  (* The answer arriving is itself the reply; there is nowhere further to
     route it. *)
  | Delegate_completed _
  (* The submitter is the one being woken; there is nowhere further to
     route it. *)
  | Composition_completed _ -> None
;;
