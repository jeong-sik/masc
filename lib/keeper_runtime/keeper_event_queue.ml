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
  | Post_updated of { content_updated_at : float }
  | Comment_added of { comment_id : string; parent_id : string option }
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

type board_audience =
  | Audience_targets of string list
  | Audience_broadcast
  | Audience_thread_participants
  | Audience_discoverable

type board_stimulus = {
  kind : board_stimulus_kind;
  author : string;
  title : string;
  content : string;
  hearth : string option;
  updated_at : float option;
  audience : board_audience;
}

type stimulus_payload =
  | Board_signal of board_stimulus
  | Board_routing_pending of board_stimulus
  | Board_attention of board_attention
  | Bootstrap
  | Tool_result_ready of string
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
  | Owned_job_completed of owned_job_completion
  (* A completion authority approved this Keeper's submitted evidence. The
     rejection twin ([Completion_authority_rejected]) has always woken the
     producer; the approval ended the loop in silence — the Board receipt is
     Unlisted ("approval wakes nobody") and the producer learned its task
     closed only by noticing its current-task projection empty on some later
     cycle (#25868). Pointer-only like the twins: the verdict record and the
     Board receipt stay the content stores, this carries the correlation keys
     so the producer's next turn can act without a scan. *)
  | Task_outcome of task_outcome

and task_outcome = {
  to_task_id : string;
  (* The task whose evidence was approved; identical to the producer's own
     submission key. *)
  to_verification_id : string;
  (* The verification the authority judged, so the producer can correlate the
     wake with its own submit record. *)
  to_producer : string;
  (* Which Keeper submitted the evidence — the recipient identity. Duplicated
     in the payload (beyond being the queue key) so a drained stimulus row can
     name its subject without a backlog read, matching
     [completion_authority_rejection]'s self-describing shape. *)
  to_authority : Masc_domain.completion_authority;
}

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

and owned_job_completion =
  { oj_job_id : Keeper_owned_job_identity.Job_id.t
  ; oj_source : Keeper_owned_job_identity.source
  ; oj_channel : Keeper_continuation_channel.t
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

let owned_job_completion_post_id (completion : owned_job_completion) =
  "keeper-job:" ^ Keeper_owned_job_identity.Job_id.to_string completion.oj_job_id

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

(* An approval is terminal and one task can be approved at most once, so the
   task id alone is a complete key — the verification id rides along for
   correlation, not identity. *)
let task_outcome_post_id (outcome : task_outcome) =
  "task-outcome:" ^ outcome.to_task_id

let hitl_resolution_decision_to_string = function
  | Hitl_approved -> "approve"
  | Hitl_rejected _ -> "reject"

type stimulus = {
  post_id : post_id;
  urgency : urgency;
  arrived_at : float;
  payload : stimulus_payload;
}

let scheduled_wake (stimulus : stimulus) =
  match stimulus.payload with
  | Schedule_due wake -> Some wake
  | Board_signal _
  | Board_routing_pending _
  | Board_attention _
  | Bootstrap
  | Fusion_completed _
  | Connector_attention _
  | Hitl_resolved _
  | Ask_answered _
  | Completion_authority_rejected _
  | Task_outcome _
  | Task_cancelled _
  | Workspace_message _
  | Delegate_completed _
  | Composition_completed _
  | Tool_result_ready _ | Owned_job_completed _ -> None
;;

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
  | Board_routing_pending signal -> Board_signal signal
  | Task_cancelled cancellation ->
    (* The reason is operator-facing prose whose wording can vary between
       retries of the same cancellation; identity is the task and who ended
       it. *)
    Task_cancelled { cancellation with tc_reason = None }
  | ( Board_signal _ | Board_attention _ | Bootstrap | Fusion_completed _
    | Schedule_due _ | Connector_attention _ | Hitl_resolved _
    | Ask_answered _
    | Completion_authority_rejected _ | Workspace_message _
    | Delegate_completed _ | Composition_completed _ | Tool_result_ready _ | Owned_job_completed _ | Task_outcome _
    ) as payload ->
    payload

type payload_identity =
  | Identity_board_post_created
  | Identity_board_comment_added of string
  | Identity_board_attention_comment_added of string * string
  | Identity_board_post_updated of float
  | Identity_board_attention_post_updated of string * float
  | Identity_fusion_completed of string * fusion_terminal * string
  | Identity_schedule_due
  | Identity_canonical_payload of stimulus_payload

type stimulus_identity =
  { id_post_id : post_id
  ; id_urgency : urgency
  ; id_payload : payload_identity
  }

let payload_identity_of_payload = function
  | Board_signal { kind = Post_created; _ }
  | Board_routing_pending { kind = Post_created; _ } -> Identity_board_post_created
  | Board_signal { kind = Comment_added comment; _ }
  | Board_routing_pending { kind = Comment_added comment; _ } ->
    Identity_board_comment_added comment.comment_id
  | Board_attention
      { candidate_id; signal = { kind = Comment_added comment; _ } } ->
    Identity_board_attention_comment_added (candidate_id, comment.comment_id)
  | Board_signal { kind = Post_updated update; _ }
  | Board_routing_pending { kind = Post_updated update; _ } ->
    Identity_board_post_updated update.content_updated_at
  | Board_attention
      { candidate_id; signal = { kind = Post_updated update; _ } } ->
    Identity_board_attention_post_updated
      (candidate_id, update.content_updated_at)
  | Fusion_completed fusion ->
    (* The first durably committed row owns recipient authority. The channel is
       recipient metadata, not result identity: a replay sources it from the
       durable delivery obligation, but a first commit can legitimately carry
       [Unrouted] (obligation unavailable at projection time) while a later
       startup recovery replays the same result with the recovered channel.
       Treating [channel] as event identity would turn that exact result replay
       into a false conflict. [enqueue_external_decision] retains the existing
       row, so excluding the channel here never overwrites the authoritative
       recipient. *)
    Identity_fusion_completed
      (fusion.run_id, fusion.terminal, fusion.board_post_id)
  | Schedule_due _ ->
    (* [post_id] is the scheduler occurrence identity. Pre-occurrence-id
       durable rows decode with an empty payload [occurrence_id], while a
       replay after upgrade carries the same occurrence in both places. The
       first committed row owns the payload, so comparing the payload again
       would turn that representation upgrade into a second execution. *)
    Identity_schedule_due
  | ( Board_signal { kind = Reaction_changed _ | Vote_cast _; _ }
    | Board_routing_pending { kind = Reaction_changed _ | Vote_cast _; _ }
    | Board_attention
        { signal =
            { kind = Post_created | Reaction_changed _ | Vote_cast _; _ }
        ; _
        }
    | Bootstrap
    | Connector_attention _
    | Hitl_resolved _
    | Ask_answered _
    | Completion_authority_rejected _
    | Task_cancelled _
    | Workspace_message _
    | Delegate_completed _
    | Composition_completed _
    | Tool_result_ready _
    | Owned_job_completed _
    | Task_outcome _ ) as payload ->
    Identity_canonical_payload (identity_payload payload)

let payload_identity_rank = function
  | Identity_board_post_created -> 0
  | Identity_board_comment_added _ -> 1
  | Identity_board_attention_comment_added _ -> 2
  | Identity_board_post_updated _ -> 3
  | Identity_board_attention_post_updated _ -> 4
  | Identity_fusion_completed _ -> 5
  | Identity_schedule_due -> 6
  | Identity_canonical_payload _ -> 7

let fusion_terminal_rank = function
  | Fusion_succeeded _ -> 0
  | Fusion_failed _ -> 1
  | Fusion_cancelled -> 2

let compare_fusion_terminal left right =
  match left, right with
  | Fusion_succeeded l, Fusion_succeeded r | Fusion_failed l, Fusion_failed r ->
    String.compare l r
  | Fusion_cancelled, Fusion_cancelled -> 0
  | ( (Fusion_succeeded _ | Fusion_failed _ | Fusion_cancelled)
    , (Fusion_succeeded _ | Fusion_failed _ | Fusion_cancelled) ) ->
    Int.compare (fusion_terminal_rank left) (fusion_terminal_rank right)

let compare_chain cmp next = if cmp <> 0 then cmp else next ()

let board_reaction_target_type_rank = function
  | Reaction_post -> 0
  | Reaction_comment -> 1

let compare_board_reaction_target_type left right =
  Int.compare
    (board_reaction_target_type_rank left)
    (board_reaction_target_type_rank right)

let compare_board_reaction_change
      (left : board_reaction_change)
      (right : board_reaction_change)
  =
  compare_chain
    (compare_board_reaction_target_type left.target_type right.target_type)
    (fun () ->
       compare_chain
         (String.compare left.target_id right.target_id)
         (fun () ->
            compare_chain
              (String.compare left.user_id right.user_id)
              (fun () ->
                 compare_chain
                   (String.compare left.emoji right.emoji)
                   (fun () -> Bool.compare left.reacted right.reacted))))

let board_vote_target_rank = function
  | Vote_on_post _ -> 0
  | Vote_on_comment _ -> 1

let compare_board_vote_target left right =
  match left, right with
  | Vote_on_post l, Vote_on_post r | Vote_on_comment l, Vote_on_comment r ->
    String.compare l r
  | (Vote_on_post _ | Vote_on_comment _), (Vote_on_post _ | Vote_on_comment _) ->
    Int.compare (board_vote_target_rank left) (board_vote_target_rank right)

let board_vote_direction_rank = function
  | Vote_up -> 0
  | Vote_down -> 1

let compare_board_vote_direction left right =
  Int.compare (board_vote_direction_rank left) (board_vote_direction_rank right)

let compare_board_vote_change
      (left : board_vote_change)
      (right : board_vote_change)
  =
  compare_chain
    (compare_board_vote_target left.target right.target)
    (fun () ->
       compare_chain
         (String.compare left.target_author right.target_author)
         (fun () ->
            compare_chain
              (String.compare left.voter right.voter)
              (fun () -> compare_board_vote_direction left.direction right.direction)))

let board_stimulus_kind_rank = function
  | Post_created -> 0
  | Post_updated _ -> 1
  | Comment_added _ -> 2
  | Reaction_changed _ -> 3
  | Vote_cast _ -> 4

let compare_board_stimulus_kind left right =
  match left, right with
  | Post_created, Post_created -> 0
  | ( Post_updated { content_updated_at = l }
    , Post_updated { content_updated_at = r } ) ->
    Float.compare l r
  | ( Comment_added { comment_id = l_cid; parent_id = l_pid }
    , Comment_added { comment_id = r_cid; parent_id = r_pid } ) ->
    compare_chain
      (String.compare l_cid r_cid)
      (fun () -> Option.compare String.compare l_pid r_pid)
  | Reaction_changed l, Reaction_changed r ->
    compare_board_reaction_change l r
  | Vote_cast l, Vote_cast r ->
    compare_board_vote_change l r
  | ( ( Post_created
      | Post_updated _
      | Comment_added _
      | Reaction_changed _
      | Vote_cast _ )
    , ( Post_created
      | Post_updated _
      | Comment_added _
      | Reaction_changed _
      | Vote_cast _ ) ) ->
    Int.compare (board_stimulus_kind_rank left) (board_stimulus_kind_rank right)

let compare_board_stimulus (left : board_stimulus) (right : board_stimulus) =
  compare_chain
    (compare_board_stimulus_kind left.kind right.kind)
    (fun () ->
       compare_chain
         (String.compare left.author right.author)
         (fun () ->
            compare_chain
              (String.compare left.title right.title)
              (fun () ->
                 compare_chain
                   (String.compare left.content right.content)
                   (fun () ->
                      compare_chain
                        (Option.compare String.compare left.hearth right.hearth)
                        (fun () ->
                           Option.compare Float.compare left.updated_at right.updated_at)))))

let continuation_channel_rank (channel : Keeper_continuation_channel.t) =
  match channel with
  | Keeper_continuation_channel.Dashboard _ -> 0
  | Keeper_continuation_channel.Discord _ -> 1
  | Keeper_continuation_channel.Slack _ -> 2
  | Keeper_continuation_channel.Telegram _ -> 3
  | Keeper_continuation_channel.Imessage _ -> 4
  | Keeper_continuation_channel.Keeper _ -> 5
  | Keeper_continuation_channel.Unrouted _ -> 6

let compare_continuation_channel
      (left : Keeper_continuation_channel.t)
      (right : Keeper_continuation_channel.t)
  =
  match left, right with
  | ( Keeper_continuation_channel.Dashboard { thread_id = l }
    , Keeper_continuation_channel.Dashboard { thread_id = r } ) ->
    String.compare l r
  | ( Keeper_continuation_channel.Discord l
    , Keeper_continuation_channel.Discord r ) ->
    compare_chain
      (Option.compare String.compare l.guild_id r.guild_id)
      (fun () ->
         compare_chain
           (String.compare l.channel_id r.channel_id)
           (fun () ->
              compare_chain
                (Option.compare String.compare l.parent_channel_id r.parent_channel_id)
                (fun () ->
                   compare_chain
                     (Option.compare String.compare l.thread_id r.thread_id)
                     (fun () ->
                        compare_chain
                          (Option.compare
                             String.compare
                             l.reply_to_message_id
                             r.reply_to_message_id)
                          (fun () -> String.compare l.user_id r.user_id)))))
  | ( Keeper_continuation_channel.Slack l
    , Keeper_continuation_channel.Slack r ) ->
    compare_chain
      (Option.compare String.compare l.team_id r.team_id)
      (fun () ->
         compare_chain
           (String.compare l.channel_id r.channel_id)
           (fun () ->
              compare_chain
                (Option.compare String.compare l.thread_ts r.thread_ts)
                (fun () -> String.compare l.user_id r.user_id)))
  | ( Keeper_continuation_channel.Telegram l
    , Keeper_continuation_channel.Telegram r ) ->
    compare_chain
      (Int64.compare l.bot_user_id r.bot_user_id)
      (fun () ->
         compare_chain
           (Int64.compare l.chat_id r.chat_id)
           (fun () ->
              compare_chain
                (Option.compare
                   Int64.compare
                   l.direct_messages_topic_id
                   r.direct_messages_topic_id)
                (fun () ->
                   compare_chain
                     (Option.compare Int.compare l.message_thread_id r.message_thread_id)
                     (fun () ->
                        compare_chain
                          (Option.compare
                             Int.compare
                             l.reply_to_message_id
                             r.reply_to_message_id)
                          (fun () -> Int64.compare l.user_id r.user_id)))))
  | ( Keeper_continuation_channel.Imessage l
    , Keeper_continuation_channel.Imessage r ) ->
    compare_chain
      (String.compare l.chat_identifier r.chat_identifier)
      (fun () ->
         compare_chain
           (Option.compare String.compare l.chat_guid r.chat_guid)
           (fun () -> String.compare l.user_id r.user_id))
  | ( Keeper_continuation_channel.Keeper { keeper_name = l }
    , Keeper_continuation_channel.Keeper { keeper_name = r } ) ->
    String.compare l r
  | ( Keeper_continuation_channel.Unrouted { reason = l }
    , Keeper_continuation_channel.Unrouted { reason = r } ) ->
    String.compare l r
  | ( ( Keeper_continuation_channel.Dashboard _
      | Keeper_continuation_channel.Discord _
      | Keeper_continuation_channel.Slack _
      | Keeper_continuation_channel.Telegram _
      | Keeper_continuation_channel.Imessage _
      | Keeper_continuation_channel.Keeper _
      | Keeper_continuation_channel.Unrouted _ )
    , ( Keeper_continuation_channel.Dashboard _
      | Keeper_continuation_channel.Discord _
      | Keeper_continuation_channel.Slack _
      | Keeper_continuation_channel.Telegram _
      | Keeper_continuation_channel.Imessage _
      | Keeper_continuation_channel.Keeper _
      | Keeper_continuation_channel.Unrouted _ ) ) ->
    Int.compare (continuation_channel_rank left) (continuation_channel_rank right)

let compare_hitl_resolution_decision left right =
  match left, right with
  | Hitl_approved, Hitl_approved -> 0
  | Hitl_rejected l, Hitl_rejected r -> String.compare l r
  | Hitl_approved, Hitl_rejected _ -> -1
  | Hitl_rejected _, Hitl_approved -> 1

let compare_completion_authority
      (left : Masc_domain.completion_authority)
      (right : Masc_domain.completion_authority)
  =
  match left, right with
  | ( Masc_domain.Human_operator { operator_id = l }
    , Masc_domain.Human_operator { operator_id = r } ) ->
    String.compare l r
  | ( Masc_domain.System_llm_agent { agent_run_id = l }
    , Masc_domain.System_llm_agent { agent_run_id = r } ) ->
    String.compare l r
  | Masc_domain.Human_operator _, Masc_domain.System_llm_agent _ -> -1
  | Masc_domain.System_llm_agent _, Masc_domain.Human_operator _ -> 1

let delegate_terminal_rank = function
  | Delegate_replied _ -> 0
  | Delegate_no_reply -> 1
  | Delegate_failed _ -> 2

let compare_delegate_terminal left right =
  match left, right with
  | Delegate_replied l, Delegate_replied r | Delegate_failed l, Delegate_failed r ->
    String.compare l r
  | Delegate_no_reply, Delegate_no_reply -> 0
  | ( (Delegate_replied _ | Delegate_no_reply | Delegate_failed _)
    , (Delegate_replied _ | Delegate_no_reply | Delegate_failed _) ) ->
    Int.compare (delegate_terminal_rank left) (delegate_terminal_rank right)

let composition_terminal_rank = function
  | Composition_succeeded -> 0
  | Composition_failed _ -> 1
  | Composition_cancelled _ -> 2

let compare_composition_terminal left right =
  match left, right with
  | Composition_succeeded, Composition_succeeded -> 0
  | Composition_failed l, Composition_failed r
  | Composition_cancelled l, Composition_cancelled r ->
    String.compare l r
  | ( (Composition_succeeded | Composition_failed _ | Composition_cancelled _)
    , (Composition_succeeded | Composition_failed _ | Composition_cancelled _) ) ->
    Int.compare (composition_terminal_rank left) (composition_terminal_rank right)

let compare_turn_ref (left : Ids.Turn_ref.t) (right : Ids.Turn_ref.t) =
  compare_chain
    (String.compare (Ids.Turn_ref.trace_id left) (Ids.Turn_ref.trace_id right))
    (fun () ->
       Int.compare
         (Ids.Turn_ref.absolute_turn left)
         (Ids.Turn_ref.absolute_turn right))

let compare_owned_job_source
      (left : Keeper_owned_job_identity.source)
      (right : Keeper_owned_job_identity.source)
  =
  compare_chain
    (Option.compare String.compare left.task_id right.task_id)
    (fun () ->
       compare_chain
         (Option.compare compare_turn_ref left.turn_ref right.turn_ref)
         (fun () ->
            compare_chain
              (Option.compare String.compare left.tool_use_id right.tool_use_id)
              (fun () ->
                 compare_chain
                   (Option.compare String.compare left.trace_id right.trace_id)
                   (fun () ->
                      Option.compare Int.compare left.keeper_turn_id right.keeper_turn_id))))

let stimulus_payload_rank = function
  | Board_signal _ -> 0
  | Board_routing_pending _ -> 16
  | Board_attention _ -> 1
  | Bootstrap -> 2
  | Tool_result_ready _ -> 3
  | Fusion_completed _ -> 4
  | Schedule_due _ -> 5
  | Connector_attention _ -> 6
  | Hitl_resolved _ -> 7
  | Ask_answered _ -> 8
  | Completion_authority_rejected _ -> 9
  | Task_cancelled _ -> 10
  | Workspace_message _ -> 11
  | Delegate_completed _ -> 12
  | Composition_completed _ -> 13
  | Owned_job_completed _ -> 14
  | Task_outcome _ -> 15

let compare_stimulus_payload (left : stimulus_payload) (right : stimulus_payload) =
  match left, right with
  | Board_signal l, Board_signal r -> compare_board_stimulus l r
  | Board_routing_pending l, Board_routing_pending r -> compare_board_stimulus l r
  | Board_attention l, Board_attention r ->
    compare_chain
      (String.compare l.candidate_id r.candidate_id)
      (fun () -> compare_board_stimulus l.signal r.signal)
  | Bootstrap, Bootstrap -> 0
  | Tool_result_ready l, Tool_result_ready r -> String.compare l r
  | Fusion_completed l, Fusion_completed r ->
    compare_chain
      (String.compare l.run_id r.run_id)
      (fun () ->
         compare_chain
           (compare_fusion_terminal l.terminal r.terminal)
           (fun () ->
              compare_chain
                (String.compare l.board_post_id r.board_post_id)
                (fun () -> compare_continuation_channel l.channel r.channel)))
  | Schedule_due l, Schedule_due r ->
    compare_chain
      (String.compare l.occurrence_id r.occurrence_id)
      (fun () ->
         compare_chain
           (String.compare l.schedule_instance_id r.schedule_instance_id)
           (fun () ->
              compare_chain
                (String.compare l.schedule_id r.schedule_id)
                (fun () ->
                   compare_chain
                     (Float.compare l.due_at r.due_at)
                     (fun () ->
                        compare_chain
                          (String.compare l.payload_digest r.payload_digest)
                          (fun () ->
                             compare_chain
                               (Option.compare String.compare l.title r.title)
                               (fun () ->
                                  compare_chain
                                    (String.compare l.message r.message)
                                    (fun () ->
                                       Option.compare
                                         compare_continuation_channel
                                         l.result_delivery
                                         r.result_delivery)))))))
  | Connector_attention l, Connector_attention r ->
    compare_chain
      (String.compare l.event_id r.event_id)
      (fun () -> compare_continuation_channel l.channel r.channel)
  | Hitl_resolved l, Hitl_resolved r ->
    compare_chain
      (String.compare l.approval_id r.approval_id)
      (fun () ->
         compare_chain
           (compare_hitl_resolution_decision l.decision r.decision)
           (fun () -> compare_continuation_channel l.channel r.channel))
  | Ask_answered l, Ask_answered r ->
    compare_chain
      (String.compare l.ask_id r.ask_id)
      (fun () -> compare_continuation_channel l.channel r.channel)
  | Completion_authority_rejected l, Completion_authority_rejected r ->
    compare_chain
      (String.compare l.car_task_id r.car_task_id)
      (fun () ->
         compare_chain
           (String.compare l.car_verification_id r.car_verification_id)
           (fun () ->
              compare_chain
                (String.compare l.car_reason r.car_reason)
                (fun () ->
                   compare_completion_authority l.car_authority r.car_authority)))
  | Task_cancelled l, Task_cancelled r ->
    compare_chain
      (String.compare l.tc_task_id r.tc_task_id)
      (fun () ->
         compare_chain
           (String.compare l.tc_cancelled_by r.tc_cancelled_by)
           (fun () -> Option.compare String.compare l.tc_reason r.tc_reason))
  | Workspace_message l, Workspace_message r ->
    compare_chain
      (String.compare l.wmsg_request_id r.wmsg_request_id)
      (fun () -> String.compare l.wmsg_from r.wmsg_from)
  | Delegate_completed l, Delegate_completed r ->
    compare_chain
      (String.compare l.dc_operation_id r.dc_operation_id)
      (fun () ->
         compare_chain
           (String.compare l.dc_keeper r.dc_keeper)
           (fun () -> compare_delegate_terminal l.dc_terminal r.dc_terminal))
  | Composition_completed l, Composition_completed r ->
    compare_chain
      (String.compare l.cc_request_id r.cc_request_id)
      (fun () ->
         compare_chain
           (String.compare l.cc_tool r.cc_tool)
           (fun () -> compare_composition_terminal l.cc_terminal r.cc_terminal))
  | Owned_job_completed l, Owned_job_completed r ->
    compare_chain
      (String.compare
         (Keeper_owned_job_identity.Job_id.to_string l.oj_job_id)
         (Keeper_owned_job_identity.Job_id.to_string r.oj_job_id))
      (fun () ->
         compare_chain
           (compare_owned_job_source l.oj_source r.oj_source)
           (fun () -> compare_continuation_channel l.oj_channel r.oj_channel))
  | Task_outcome l, Task_outcome r ->
    compare_chain
      (String.compare l.to_task_id r.to_task_id)
      (fun () ->
         compare_chain
           (String.compare l.to_verification_id r.to_verification_id)
           (fun () ->
              compare_chain
                (String.compare l.to_producer r.to_producer)
                (fun () ->
                   compare_completion_authority l.to_authority r.to_authority)))
  | ( ( Board_signal _
      | Board_routing_pending _
      | Board_attention _
      | Bootstrap
      | Tool_result_ready _
      | Fusion_completed _
      | Schedule_due _
      | Connector_attention _
      | Hitl_resolved _
      | Ask_answered _
      | Completion_authority_rejected _
      | Task_cancelled _
      | Workspace_message _
      | Delegate_completed _
      | Composition_completed _
      | Owned_job_completed _
      | Task_outcome _ )
    , ( Board_signal _
      | Board_routing_pending _
      | Board_attention _
      | Bootstrap
      | Tool_result_ready _
      | Fusion_completed _
      | Schedule_due _
      | Connector_attention _
      | Hitl_resolved _
      | Ask_answered _
      | Completion_authority_rejected _
      | Task_cancelled _
      | Workspace_message _
      | Delegate_completed _
      | Composition_completed _
      | Owned_job_completed _
      | Task_outcome _ ) ) ->
    Int.compare (stimulus_payload_rank left) (stimulus_payload_rank right)

let compare_payload_identity left right =
  match left, right with
  | Identity_board_post_created, Identity_board_post_created
  | Identity_schedule_due, Identity_schedule_due ->
    0
  | Identity_board_comment_added l_cid, Identity_board_comment_added r_cid ->
    String.compare l_cid r_cid
  | ( Identity_board_attention_comment_added (l_cand, l_cid)
    , Identity_board_attention_comment_added (r_cand, r_cid) ) ->
    let cmp = String.compare l_cand r_cand in
    if cmp <> 0 then cmp else String.compare l_cid r_cid
  | Identity_board_post_updated l_ts, Identity_board_post_updated r_ts ->
    Float.compare l_ts r_ts
  | ( Identity_board_attention_post_updated (l_cand, l_ts)
    , Identity_board_attention_post_updated (r_cand, r_ts) ) ->
    let cmp = String.compare l_cand r_cand in
    if cmp <> 0 then cmp else Float.compare l_ts r_ts
  | ( Identity_fusion_completed (l_run, l_term, l_post)
    , Identity_fusion_completed (r_run, r_term, r_post) ) ->
    let cmp = String.compare l_run r_run in
    if cmp <> 0
    then cmp
    else (
      let cmp = compare_fusion_terminal l_term r_term in
      if cmp <> 0 then cmp else String.compare l_post r_post)
  | Identity_canonical_payload l_payload, Identity_canonical_payload r_payload ->
    compare_stimulus_payload l_payload r_payload
  | ( ( Identity_board_post_created
      | Identity_board_comment_added _
      | Identity_board_attention_comment_added _
      | Identity_board_post_updated _
      | Identity_board_attention_post_updated _
      | Identity_fusion_completed _
      | Identity_schedule_due
      | Identity_canonical_payload _ )
    , ( Identity_board_post_created
      | Identity_board_comment_added _
      | Identity_board_attention_comment_added _
      | Identity_board_post_updated _
      | Identity_board_attention_post_updated _
      | Identity_fusion_completed _
      | Identity_schedule_due
      | Identity_canonical_payload _ ) ) ->
    Int.compare (payload_identity_rank left) (payload_identity_rank right)

let compare_stimulus_identity (a : stimulus_identity) (b : stimulus_identity) =
  let cmp = String.compare a.id_post_id b.id_post_id in
  if cmp <> 0
  then cmp
  else (
    let cmp = Int.compare (urgency_rank a.id_urgency) (urgency_rank b.id_urgency) in
    if cmp <> 0 then cmp else compare_payload_identity a.id_payload b.id_payload)

let stimulus_identity (s : stimulus) : stimulus_identity =
  { id_post_id = s.post_id
  ; id_urgency = s.urgency
  ; id_payload = payload_identity_of_payload s.payload
  }

module Stimulus_identity_order = struct
  type t = stimulus_identity

  let compare = compare_stimulus_identity
end

module Stimulus_identity_set = Set.Make (Stimulus_identity_order)
module Stimulus_identity_map = Map.Make (Stimulus_identity_order)

let stimulus_identity_equal a b =
  Stimulus_identity_order.compare (stimulus_identity a) (stimulus_identity b) = 0

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

(* Scans both halves of the queue directly instead of rebuilding it through
   repeated [dequeue], so membership stays allocation-free. *)
let contains (queue : t) (stimulus : stimulus) : bool =
  let target = stimulus_identity stimulus in
  let same head = Stimulus_identity_order.compare (stimulus_identity head) target = 0 in
  List.exists same queue.front || List.exists same queue.back_rev

let uniq_stimuli stimuli =
  let _, rev_acc =
    List.fold_left
      (fun (seen, acc) stimulus ->
         let key = stimulus_identity stimulus in
         if Stimulus_identity_set.mem key seen
         then seen, acc
         else Stimulus_identity_set.add key seen, stimulus :: acc)
      (Stimulus_identity_set.empty, [])
      stimuli
  in
  List.rev rev_acc

let sort_by_urgency (queue : t) : t =
  queue
  |> to_list
  |> List.stable_sort
       (fun a b -> Int.compare (urgency_rank a.urgency) (urgency_rank b.urgency))
  |> of_list

(* For a single selection, [Immediate] receives rank 0. Between [Normal]
   and [Low], prefer the lane opposite the supplied last non-immediate urgency
   without wall-clock aging thresholds. This preference does not bound an
   individual item's wait behind other entries in the same lane. *)
let preferred_non_immediate_urgency ~last_non_immediate_served =
  match last_non_immediate_served with
  | Some Normal -> Low
  | None | Some (Low | Immediate) -> Normal
;;

let selection_urgency_rank ~last_non_immediate_served urgency =
  match urgency with
  | Immediate -> 0
  | (Normal | Low) as candidate ->
    if candidate = preferred_non_immediate_urgency ~last_non_immediate_served
    then 1
    else 2
;;

let compare_selection_urgency ~last_non_immediate_served left right =
  Int.compare
    (selection_urgency_rank ~last_non_immediate_served left)
    (selection_urgency_rank ~last_non_immediate_served right)
;;

let payload_kind_label = function
  | Board_signal _ -> "board_signal"
  | Board_routing_pending _ -> "board_routing_pending"
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
  | Tool_result_ready _ -> "tool_result_ready"
  | Owned_job_completed _ -> "owned_job_completed"
  | Task_outcome _ -> "task_outcome"

(* RFC-0377: the batch-intake predicate needs the routed channel without
   repeating the payload match at every call site. Exhaustive on purpose:
   a new payload kind must decide here at compile time whether it carries a
   conversation channel. *)
let connector_attention_channel = function
  | Connector_attention { channel; _ } -> Some channel
  (* [Ask_answered] carries a channel but answers [None] here on purpose. This
     predicate holds a stimulus back when another conversation has already
     claimed the batch; an answer to a question this keeper asked is not
     ambient conversation traffic and must not wait behind one. *)
  | Ask_answered _
  | Board_signal _ | Board_routing_pending _ | Board_attention _ | Bootstrap | Fusion_completed _
  | Schedule_due _ | Hitl_resolved _
  | Completion_authority_rejected _ | Task_cancelled _ | Workspace_message _
  | Delegate_completed _ | Composition_completed _ | Tool_result_ready _ | Owned_job_completed _ | Task_outcome _ ->
    None

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
  | Post_updated _ -> "post_updated"
  | Comment_added _ -> "comment_added"
  | Reaction_changed _ -> "reaction_changed"
  | Vote_cast _ -> "vote_cast"

let board_stimulus_kind_of_string = function
  | "post_created" -> Ok Post_created
  | "post_updated" -> Error "post_updated board stimulus requires content_updated_at"
  | "comment_added" -> Error "comment_added board stimulus requires exact comment identity"
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

open Result.Syntax

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

let board_audience_to_yojson = function
  | Audience_targets targets ->
    `Assoc
      [ "kind", `String "targets"
      ; "targets", `List (List.map (fun target -> `String target) targets)
      ]
  | Audience_broadcast -> `Assoc [ "kind", `String "broadcast" ]
  | Audience_thread_participants -> `Assoc [ "kind", `String "thread_participants" ]
  | Audience_discoverable -> `Assoc [ "kind", `String "discoverable" ]
;;

let board_audience_of_yojson ~context json =
  match json with
  | `Assoc fields ->
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ "kind", `String "targets"; "targets", `List values ] ->
       let rec parse acc = function
         | [] ->
           (match List.rev acc with
            | [] -> Error (context ^ ".audience.targets must not be empty")
            | _ :: _ as targets -> Ok (Audience_targets targets))
         | `String value :: rest ->
           if String.trim value = ""
           then Error (context ^ ".audience.targets must not be empty")
           else parse (value :: acc) rest
         | _ :: _ -> Error (context ^ ".audience.targets must be strings")
       in
       parse [] values
     | [ "kind", `String "broadcast" ] -> Ok Audience_broadcast
     | [ "kind", `String "thread_participants" ] -> Ok Audience_thread_participants
     | [ "kind", `String "discoverable" ] -> Ok Audience_discoverable
     | _ -> Error (context ^ ".audience has unknown shape"))
  | _ -> Error (context ^ ".audience must be an object")
;;

let board_stimulus_fields board =
  [ "board_kind", `String (board_stimulus_kind_to_string board.kind)
  ; "author", `String board.author
  ; "title", `String board.title
  ; "content", `String board.content
  ; "hearth", option_json (fun value -> `String value) board.hearth
  ; "updated_at_unix", option_json (fun value -> `Float value) board.updated_at
  ; "audience", board_audience_to_yojson board.audience
  ]
  @
  match board.kind with
  | Post_created -> []
  | Post_updated { content_updated_at } -> [ "content_updated_at", `Float content_updated_at ]
  | Comment_added { comment_id; parent_id } ->
    [ "comment_id", `String comment_id
    ; "parent_id", option_json (fun value -> `String value) parent_id
    ]
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
  | Board_routing_pending board ->
    `Assoc
      ([ "kind", `String "board_routing_pending" ] @ board_stimulus_fields board)
  | Board_attention attention ->
    `Assoc
      ([ "kind", `String "board_attention"
       ; "candidate_id", `String attention.candidate_id
       ]
       @ board_stimulus_fields attention.signal)
  | Bootstrap -> `Assoc [ "kind", `String "bootstrap" ]
  | Tool_result_ready receipt_id ->
    `Assoc [ "kind", `String "tool_result_ready"; "receipt_id", `String receipt_id ]
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
  | Owned_job_completed completion ->
    `Assoc [ "kind", `String "owned_job_completed"
           ; "job_id", `String (Keeper_owned_job_identity.Job_id.to_string completion.oj_job_id)
           ; "source", Keeper_owned_job_identity.source_to_json completion.oj_source
           ; "channel", Keeper_continuation_channel.to_yojson completion.oj_channel ]
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
  | Task_outcome outcome ->
    `Assoc
      [ "kind", `String "task_outcome"
      ; "task_id", `String outcome.to_task_id
      ; "verification_id", `String outcome.to_verification_id
      ; "producer", `String outcome.to_producer
      ; ( "authority_kind"
        , `String
            (Masc_domain.completion_authority_kind outcome.to_authority) )
      ; ( "authority_actor"
        , `String
            (Masc_domain.completion_authority_actor outcome.to_authority) )
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
      | "post_updated" ->
        let expected =
          ([ "kind"; "board_kind"; "author"; "title"; "content";
             "hearth"; "updated_at_unix"; "audience"; "content_updated_at" ]
           @ if kind = "board_attention" then [ "candidate_id" ] else [])
        in
        let* () = exact_fields ~context ~expected fields in
        let* content_updated_at = float_field ~context "content_updated_at" fields in
        if Float.is_finite content_updated_at then Ok (Post_updated {content_updated_at})
        else Error (context ^ ".content_updated_at must be finite")
      | "comment_added" ->
        let expected =
          ([ "kind"; "board_kind"; "author"; "title"; "content";
             "hearth"; "updated_at_unix"; "audience"; "comment_id"; "parent_id" ]
           @ if kind = "board_attention" then [ "candidate_id" ] else [])
        in
        let* () = exact_fields ~context ~expected fields in
        let nonempty_id name =
          let* value = string_field ~context name fields in
          if String.trim value = "" then Error (context ^ "." ^ name ^ " must not be empty")
          else Ok value
        in
        let* comment_id = nonempty_id "comment_id" in
        let* parent_json = required_field ~context "parent_id" fields in
        let* parent_id =
          match parent_json with
          | `Null -> Ok None
          | _ -> let* value = nonempty_id "parent_id" in Ok (Some value)
        in
        Ok (Comment_added { comment_id; parent_id })
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
    let* audience =
      let* json = required_field ~context "audience" fields in
      board_audience_of_yojson ~context json
    in
    Ok { kind; author; title; content; hearth; updated_at; audience }
  in
  match kind with
  | "board_signal" ->
    let* signal = parse_board_stimulus () in
    Ok (Board_signal signal)
  | "board_routing_pending" ->
    let* signal = parse_board_stimulus () in
    let expected = "kind" :: List.map fst (board_stimulus_fields signal) in
    let* () = exact_fields ~context ~expected fields in
    let* () = match signal.updated_at with
      | Some timestamp when not (Float.is_finite timestamp) ->
        Error (context ^ ".updated_at_unix must be finite")
      | None | Some _ -> Ok ()
    in
    Ok (Board_routing_pending signal)
  | "board_attention" ->
    let* candidate_id = string_field ~context "candidate_id" fields in
    if String.equal candidate_id ""
    then Error "stimulus.payload.candidate_id must not be empty"
    else
      let* signal = parse_board_stimulus () in
      Ok (Board_attention { candidate_id; signal })
  | "tool_result_ready" ->
    let* () = exact_fields ~context ~expected:[ "kind"; "receipt_id" ] fields in
    let* receipt_id = string_field ~context "receipt_id" fields in
    if String.length receipt_id = 64 && String.for_all
        (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) receipt_id
    then Ok (Tool_result_ready receipt_id)
    else Error "tool result receipt_id must be a lowercase SHA256"
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
    let with_message terminal =
      let* () =
        exact_fields
          ~context:"stimulus.payload.terminal"
          ~expected:[ "kind"; "message" ]
          terminal_fields
      in
      let* message =
        string_field ~context:"stimulus.payload.terminal" "message" terminal_fields
      in
      Ok (terminal message)
    in
    let* terminal =
      match terminal_kind with
      | "replied" -> with_message (fun message -> Delegate_replied message)
      | "failed" -> with_message (fun message -> Delegate_failed message)
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
  | "task_outcome" ->
    let* () =
      exact_fields
        ~context
        ~expected:
          [ "kind"
          ; "task_id"
          ; "verification_id"
          ; "producer"
          ; "authority_kind"
          ; "authority_actor"
          ]
        fields
    in
    let* task_id = string_field ~context "task_id" fields in
    let* verification_id = string_field ~context "verification_id" fields in
    let* producer = string_field ~context "producer" fields in
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
      (Task_outcome
         { to_task_id = task_id
         ; to_verification_id = verification_id
         ; to_producer = producer
         ; to_authority = authority
         })
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
    let with_message terminal =
      let* () =
        exact_fields
          ~context:"stimulus.payload.terminal"
          ~expected:[ "kind"; "message" ]
          terminal_fields
      in
      let* message =
        string_field ~context:"stimulus.payload.terminal" "message" terminal_fields
      in
      Ok (terminal message)
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
      | "failed" -> with_message (fun message -> Composition_failed message)
      | "cancelled" -> with_message (fun message -> Composition_cancelled message)
      | value ->
        Error (Printf.sprintf "unknown keeper composition terminal kind: %s" value)
    in
    Ok
      (Composition_completed
         { cc_request_id = request_id; cc_tool = tool; cc_terminal = terminal })
  | "owned_job_completed" ->
    let* () = exact_fields ~context ~expected:["kind";"job_id";"source";"channel"] fields in
    let* id = string_field ~context "job_id" fields in
    let* oj_job_id = Keeper_owned_job_identity.Job_id.of_string id in
    let* source = required_field ~context "source" fields in
    let* oj_source = Keeper_owned_job_identity.source_of_json source in
    let* channel = required_field ~context "channel" fields in
    let* oj_channel = Keeper_continuation_channel.of_yojson channel in
    Ok (Owned_job_completed {oj_job_id;oj_source;oj_channel})
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

let schema = "keeper.event_queue.v3"

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
  | Owned_job_completed completion -> Some completion.oj_channel
  | Tool_result_ready _ -> None
  | Schedule_due wake -> wake.result_delivery
  | Board_signal _
  | Board_routing_pending _
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
  | Composition_completed _
  (* The producer is the one being woken; there is nowhere further to route
     it. *)
  | Task_outcome _ -> None
;;
