(** Keeper_world_observation — Structured world state for keeper cycles.

    Extracts and normalizes observation signals from workspace state, keeper meta,
    and context so the unified prompt and turn runner consume a single snapshot.

    @since Unified Keeper Loop *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_memory

type board_reaction_event =
  { target_type : Board.reaction_target_type
  ; target_id : string
  ; user_id : string
  ; emoji : string
  ; reacted : bool
  }

type pending_board_event_kind =
  | Board_post_created
  | Board_comment_added
  | Board_reaction_changed of board_reaction_event
  | Board_vote_cast of Board_dispatch.board_vote_change
  | Fusion_completed
  | Delegate_completed
  | Ask_answered_row
      (** A human answered a question this Keeper asked. Like
          {!Composition_completed} the row carries the answer itself: the
          asker has nowhere else to read it mid-cycle, and a wake with no
          content is a wake it cannot act on. *)
  | Composition_completed
  | Schedule_due of Keeper_event_queue.scheduled_wake
  | External_attention of Keeper_counterpart_observation.t
  | Completion_authority_rejected of Keeper_event_queue.completion_authority_rejection
  | Task_cancelled of Keeper_event_queue.task_cancellation

type pending_board_event =
  { event_kind : pending_board_event_kind
  ; post_id : string
  ; author : string
  ; title : string
  ; preview : string
  ; hearth : string option
  ; post_kind : Board.post_kind
  ; updated_at : float
  ; explicit_mention : bool
  ; matched_targets : string list
  ; self_commented : bool
  ; new_external_since : int
  ; latest_external_author : string option
  ; latest_external_preview : string option
  }

let is_board_activity_event (event : pending_board_event) =
  match event.event_kind with
  | Schedule_due _ -> false
  | Board_post_created
  | Board_comment_added
  | Board_reaction_changed _
  | Board_vote_cast _
  | Fusion_completed
  (* Like [Fusion_completed] this has no Board post behind its id, and for the
     same reason it is still counted here: this block is the only one that
     renders the row's title and preview, and the answer is the whole point of
     the wake. Excluded, the Keeper would be woken with nothing to read. *)
  | Delegate_completed
  (* Same shape: no Board post behind the id, and this block is the only one
     that renders the row, so leaving it out would wake the Keeper with an
     empty pending-events list. *)
  | Composition_completed
  (* Same again: this block renders the row's title and preview, and the
     answer is the whole point of the wake. *)
  | Ask_answered_row
  | External_attention _ -> true
  (* Neither carries a Board post, so routing either here would count a
     non-existent post in [board_activity_count]. Each has its own renderer. *)
  | Completion_authority_rejected _ | Task_cancelled _ -> false
;;

let is_scheduled_automation_event (event : pending_board_event) =
  match event.event_kind with
  | Schedule_due _ -> true
  | Board_post_created
  | Board_comment_added
  | Board_reaction_changed _
  | Board_vote_cast _
  | Fusion_completed
  | Delegate_completed
  | Composition_completed
  | Ask_answered_row
  | External_attention _
  | Completion_authority_rejected _
  | Task_cancelled _ -> false
;;

let is_completion_authority_rejection_event (event : pending_board_event) =
  match event.event_kind with
  | Completion_authority_rejected _ -> true
  | Board_post_created
  | Board_comment_added
  | Board_reaction_changed _
  | Board_vote_cast _
  | Fusion_completed
  | Delegate_completed
  | Composition_completed
  | Ask_answered_row
  | Schedule_due _
  | External_attention _
  | Task_cancelled _ -> false
;;

(* A cancellation of a Task this Keeper authored. Kept off the Board Activity
   and Scheduled Automation renderers: it has no Board post to point at and no
   schedule behind it. *)
let is_task_cancellation_event (event : pending_board_event) =
  match event.event_kind with
  | Task_cancelled _ -> true
  | Delegate_completed
  | Composition_completed
  | Ask_answered_row
  | Board_post_created
  | Board_comment_added
  | Board_reaction_changed _
  | Board_vote_cast _
  | Fusion_completed
  | Schedule_due _
  | External_attention _
  | Completion_authority_rejected _ -> false
;;

type scheduled_automation_item =
  { schedule_id : string
  ; action : string
  ; status : string
  ; payload_kind : string option
  ; recurrence_summary : string
  ; due_at : float
  }

type scheduled_automation_observation =
  { active_count : int
  ; due_ready_count : int
  ; next_due_at : float option
  ; items : scheduled_automation_item list
  }

let empty_scheduled_automation_observation =
  { active_count = 0
  ; due_ready_count = 0
  ; next_due_at = None
  ; items = []
  }
;;

type pending_approval_observation =
  { approval_id : string
  ; tool_name : string
  ; sequence : int
  ; requested_at : float
  ; task_id : string option
  ; goal_id : string option
  }

type approval_authority_state =
  | Approval_authority_complete
  | Approval_authority_partial of { read_error_count : int }
  | Approval_authority_unavailable

type approval_authority_observation =
  { revision : int
  ; state : approval_authority_state
  ; pending : pending_approval_observation list
  }

let pending_approval_observation_of_entry
      (entry : Keeper_approval_queue_rules_types.pending_approval)
  =
  { approval_id = entry.id
  ; tool_name = entry.tool_name
  ; sequence = entry.sequence
  ; requested_at = entry.requested_at
  ; task_id = entry.task_id
  ; goal_id = entry.goal_id
  }
;;

let read_approval_authority_observation
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
  =
  match
    Keeper_approval_queue.pending_entries_snapshot_for_workspace
      ~base_path:config.base_path
  with
  | Error _error ->
    { revision =
        Keeper_approval_queue.store_revision_for_workspace
          ~base_path:config.base_path
    ; state = Approval_authority_unavailable
    ; pending = []
    }
  | Ok snapshot ->
    let pending =
      snapshot.entries
      |> List.filter (fun
        (entry : Keeper_approval_queue_rules_types.pending_approval) ->
        String.equal entry.keeper_name meta.name)
      |> List.map pending_approval_observation_of_entry
    in
    let state =
      match snapshot.read_errors with
      | [] -> Approval_authority_complete
      | _ ->
        Approval_authority_partial
          { read_error_count = List.length snapshot.read_errors }
    in
    { revision = snapshot.revision; state; pending }
;;

module Inputs = Keeper_world_observation_inputs

type world_observation =
  { pending_messages : Keeper_world_observation_message_scope.pending_message list
  ; pending_board_events : pending_board_event list
  ; idle_seconds : int
  ; active_goals : string list
  ; unclaimed_task_count : int
  ; claimable_tasks : Inputs.claimable_task_identity list
  ; held_task_skills : Inputs.held_task_skills list
  ; failed_task_count : int
  ; scheduled_automation : scheduled_automation_observation
  ; approval_authority : approval_authority_observation
  ; backlog_revision : int option
  ; running_keeper_fiber_count : int
  ; connected_surfaces : Gate_surface.surface_presence list
  ; connected_surface_failures : Gate_surface.presence_failure list
  ; own_recent_board_posts : Board.post list
  ; fleet_messages : Keeper_world_observation_message_scope.fleet_message list
  ; own_recent_actions : Keeper_own_recent_actions.turn list
  }

type keeper_cycle_channel =
  Keeper_world_observation_turn_types.keeper_cycle_channel =
  | Reactive
  | Scheduled_autonomous

type event_queue_trigger =
  Keeper_world_observation_turn_types.event_queue_trigger =
  | Bootstrap_stimulus
  | Scheduled_automation_stimulus
  | Connector_attention_stimulus
  | Ask_answered_stimulus
  | Hitl_resolved_stimulus
  | Completion_authority_rejection_stimulus
  | Task_cancellation_stimulus
  | Workspace_message_stimulus

type turn_reason = Keeper_world_observation_turn_types.turn_reason =
  | Mention_pending
  | Board_event_pending
  | Scope_message_pending
  | Bootstrap_stimulus_pending
  | Connector_attention_pending
  | Ask_answered_pending
  | Hitl_resolved_pending
  | Completion_authority_rejection_pending
  | Task_cancellation_pending
  | Workspace_message_pending
  | Scheduled_autonomous_turn
  | Scheduled_automation_due
  | Task_backlog of
      { unclaimed : int
      ; failed : int
      }
  | Never_started

type skip_reason = Keeper_world_observation_turn_types.skip_reason =
  | Keeper_paused
  | Scheduled_autonomous_disabled
  | Reactive_disabled

type turn_verdict = Keeper_world_observation_turn_types.turn_verdict =
  | Run of { reasons : turn_reason * turn_reason list }
  | Skip of { reasons : skip_reason * skip_reason list }

let turn_reason_to_string =
  Keeper_world_observation_turn_types.turn_reason_to_string
let turn_reason_of_event_queue_trigger =
  Keeper_world_observation_turn_types.turn_reason_of_event_queue_trigger
let skip_reason_to_string =
  Keeper_world_observation_turn_types.skip_reason_to_string
let channel_to_string = Keeper_world_observation_turn_types.channel_to_string
let channel_of_string = Keeper_world_observation_turn_types.channel_of_string
let is_autonomous = Keeper_world_observation_turn_types.is_autonomous
let verdict_reasons_to_strings =
  Keeper_world_observation_turn_types.verdict_reasons_to_strings

type keeper_cycle_decision =
  { should_run : bool
  ; channel : keeper_cycle_channel
  ; verdict : turn_verdict
  ; since_last_scheduled_autonomous : int option
  }

module Board_signal = Keeper_world_observation_board_signal
module Board_audience = Keeper_board_audience

type board_signal_match = Board_signal.match_result =
  { explicit_mention : bool
  ; matched_targets : string list
  }

module Message_scope = Keeper_world_observation_message_scope

let self_ids = Message_scope.self_ids
let is_self_author = Message_scope.is_self_author

let collect_message_scope_and_fleet = Message_scope.collect_message_scope_and_fleet
let read_backlog_snapshot = Inputs.read_backlog_snapshot

let claimable_task_count observation = List.length observation.claimable_tasks
let count_running_keeper_fibers = Inputs.count_running_keeper_fibers
let compute_idle_seconds = Inputs.compute_idle_seconds
let board_signal_match = Board_signal.match_signal
let check_self_comment_status = Board_signal.check_self_comment_status
let compare_board_cursor_token = Board_signal.compare_cursor_token
let board_cursor_token_of_post = Board_signal.cursor_token_of_post
let list_board_posts_after_cursor = Board_signal.list_posts_after_cursor

(** The keeper's own latest board posts, newest first. Cursor-independent:
    the board-event collector above filters out self-authored posts and only
    looks past the cursor, so without this a keeper never observes its own
    published posts in-prompt (production: one keeper posted 23 near-duplicate
    posts in a single hour). Raw observation only — bounded by
    [Keeper_config.keeper_board_own_recent_max]; no dedup gate. *)
let collect_own_recent_board_posts ~(meta : keeper_meta) : Board.post list =
  let max_posts = Keeper_config.keeper_board_own_recent_max () in
  if max_posts <= 0
  then []
  else (
    let self_ids = self_ids meta in
    try
      Board_dispatch.list_recent_posts_matching_author
        ~author_matches:(fun author ->
          is_self_author ~self_ids (Board.Agent_id.to_string author))
        ~limit:max_posts
        ()
    with
    | exn ->
      (* Same fail-loud contract as board event collection: counted, warned,
         re-raised — never an empty list on a storage failure. *)
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ObservationQueryFailures)
        ~labels:[ ("operation", Runtime_observation_query_operation.(to_label Board_events)) ]
        ();
      Log.Keeper.warn
        "own recent board posts collection failed keeper=%s: %s"
        meta.name
        (Printexc.to_string exn);
      raise exn)
;;

let scheduled_automation_item_limit = 5

let schedule_payload_kind (request : Schedule_domain.schedule_request) =
  match Schedule_domain.payload_to_yojson request.payload with
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String kind) -> Some kind
     | _ -> None)
  | _ -> None
;;

let schedule_effectively_expired ~now (request : Schedule_domain.schedule_request) =
  let open Schedule_domain in
  match request.status, request.expires_at with
  | (Scheduled | Due), Some expires_at when expires_at <= now ->
    true
  | (Scheduled | Due | Running | Succeeded | Failed | Cancelled | Expired)
    , _ ->
    false
;;

let schedule_effectively_active ~now (request : Schedule_domain.schedule_request) =
  (not (Schedule_domain.is_terminal request.status))
  && not (schedule_effectively_expired ~now request)
;;

let schedule_attention_item action (request : Schedule_domain.schedule_request) =
  { schedule_id = request.schedule_id
  ; action = Schedule_projection.attention_action_to_string action
  ; status = Schedule_domain.schedule_status_to_string request.status
  ; payload_kind = schedule_payload_kind request
  ; recurrence_summary = Schedule_domain.recurrence_summary request.recurrence
  ; due_at = request.due_at
  }
;;

let compare_schedule_attention_item left right =
  match compare left.due_at right.due_at with
  | 0 -> String.compare left.schedule_id right.schedule_id
  | cmp -> cmp
;;

let take n values =
  let rec loop acc remaining = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | item :: rest -> loop (item :: acc) (remaining - 1) rest
  in
  loop [] n values
;;

let next_active_schedule_due_at ~now schedules =
  schedules
  |> List.filter (schedule_effectively_active ~now)
  |> List.fold_left
       (fun acc (request : Schedule_domain.schedule_request) ->
          match acc with
          | None -> Some request.due_at
          | Some due_at -> Some (min due_at request.due_at))
       None
;;

let schedule_query_failure_message = function
  | Schedule_store.Corrupt_ledger_exn { primary_err; recovery_err } ->
    (match recovery_err with
     | None ->
       Printf.sprintf
         "schedule ledger corrupt while reading keeper observation: %s"
         primary_err
     | Some recovery_err ->
       Printf.sprintf
         "schedule ledger corrupt while reading keeper observation: %s; recovery: %s"
         primary_err
         recovery_err)
  | exn -> Printexc.to_string exn
;;

(* Two keepers can be involved in one schedule: the one that created it and
   the one the payload wakes. Filtering on [scheduled_by] alone showed it to
   the first and hid it from the second, so a wake an operator scheduled was
   invisible to every keeper while still being delivered to one of them
   (#25689). Show it to both — this only adds rows. *)
let schedule_visible_to_keeper keeper_name (request : Schedule_domain.schedule_request)
  =
  match keeper_name with
  | None -> true
  | Some keeper_name ->
    let scheduled_by_this_keeper =
      match request.scheduled_by.kind with
      | Schedule_domain.Automated_actor ->
        String.equal request.scheduled_by.id keeper_name
      | Schedule_domain.Human_operator | Schedule_domain.System -> false
    in
    let wakes_this_keeper =
      match
        Schedule_payload_projection.creation_keeper_wake_target
          ~payload:(Schedule_domain.payload_to_yojson request.payload)
      with
      | Ok (Some target) -> String.equal target keeper_name
      | Ok None | Error _ -> false
    in
    scheduled_by_this_keeper || wakes_this_keeper
;;

let read_scheduled_automation_observation
      ~(keeper_name : string option)
      ~(config : Workspace.config)
      ~now
  =
  try
    let state = Schedule_store.read_state config in
    let schedules =
      List.filter (schedule_visible_to_keeper keeper_name) state.schedules
    in
    let due_ready =
      Schedule_store.due_wake_candidates state
      |> List.filter (schedule_visible_to_keeper keeper_name)
      |> List.filter (fun request -> not (schedule_effectively_expired ~now request))
    in
    let active_count =
      schedules
      |> List.fold_left
           (fun count request ->
              if schedule_effectively_active ~now request then count + 1 else count)
           0
    in
    let due_items =
      List.map (schedule_attention_item Schedule_projection.Dispatch_ready) due_ready
    in
    { active_count
    ; due_ready_count = List.length due_ready
    ; next_due_at = next_active_schedule_due_at ~now schedules
    ; items =
        due_items
        |> List.sort compare_schedule_attention_item
        |> take scheduled_automation_item_limit
    }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ObservationQueryFailures)
      ~labels:
        [ ( "operation"
          , Runtime_observation_query_operation.(to_label Scheduled_automation) )
        ]
      ();
    Log.Keeper.warn "%s" (schedule_query_failure_message exn);
    empty_scheduled_automation_observation
;;

let board_reaction_event_of_dispatch
      (reaction : Board_dispatch.board_reaction_change)
  : board_reaction_event
  =
  { target_type = reaction.target_type
  ; target_id = reaction.target_id
  ; user_id = reaction.user_id
  ; emoji = reaction.emoji
  ; reacted = reaction.reacted
  }
;;

let pending_board_event_kind_of_signal (signal : Board_dispatch.board_signal) =
  match signal.kind with
  | Board_dispatch.Board_post_created -> Board_post_created
  | Board_dispatch.Board_comment_added -> Board_comment_added
  | Board_dispatch.Board_reaction_changed reaction ->
    Board_reaction_changed (board_reaction_event_of_dispatch reaction)
  | Board_dispatch.Board_vote_cast vote -> Board_vote_cast vote
;;

let pending_board_event_of_board_signal
      ~(meta : keeper_meta)
      ~arrived_at:(_ : float)
      (signal : Board_dispatch.board_signal)
  : (pending_board_event, Board_signal.board_unavailable) result
  =
  let self_ids = self_ids meta in
  let matched = board_signal_match ~meta ~signal in
  match Board_dispatch.get_post ~post_id:signal.post_id with
  | Error error ->
    Error { Board_signal.operation = Board_signal.Get_post; post_id = signal.post_id; error }
  | Ok post_snapshot ->
    let title, preview, hearth, post_kind, updated_at =
      let post : Board.post = post_snapshot in
      ( post.title
      , short_preview ~max_len:80 post.body
      , post.hearth
      , post.post_kind
      , post.updated_at )
    in
    let event_kind = pending_board_event_kind_of_signal signal in
    let comment_derived =
      match signal.kind with
      | Board_dispatch.Board_post_created -> Ok (false, 0, None, None)
      | Board_dispatch.Board_comment_added ->
        (match check_self_comment_status ~self_ids ~post_id:signal.post_id with
         | Board_signal.Unavailable unavailable -> Error unavailable
         | Board_signal.Available (`New_external (count, author, preview)) ->
           Ok (true, count, Some author, Some preview)
         | Board_signal.Available `No_new_external ->
           Ok (true, 0, Some signal.author, Some (short_preview ~max_len:60 signal.content))
         | Board_signal.Available `Never ->
           Ok (false, 1, Some signal.author, Some (short_preview ~max_len:60 signal.content)))
      | Board_dispatch.Board_reaction_changed _ ->
        (match check_self_comment_status ~self_ids ~post_id:signal.post_id with
         | Board_signal.Unavailable unavailable -> Error unavailable
         | Board_signal.Available `Never -> Ok (false, 0, None, None)
         | Board_signal.Available (`No_new_external | `New_external _) ->
           Ok (true, 0, None, None))
      (* The vote row states who voted which way on what; the reply counters
         belong to comment events, so none are derived here. *)
      | Board_dispatch.Board_vote_cast _ -> Ok (false, 0, None, None)
    in
    (match comment_derived with
     | Error unavailable -> Error unavailable
     | Ok (self_commented, new_external_since, latest_external_author, latest_external_preview) ->
       Ok
         { event_kind
         ; post_id = signal.post_id
         ; author = signal.author
         ; title
         ; preview
         ; hearth
         ; post_kind
         ; updated_at
         ; explicit_mention = matched.explicit_mention
         ; matched_targets = matched.matched_targets
         ; self_commented
         ; new_external_since
         ; latest_external_author
         ; latest_external_preview
         })
;;

(* RFC-0266: fusion answers are the deliberation result the keeper requested,
   so the in-prompt preview is longer than a board headline preview (80). The
   full answer also persists in the sink's board post + chat lane. *)
let fusion_result_preview_max_len = 480

(* RFC-0266: turn a completed async fusion deliberation into actionable turn
   input. The sink already created a System_post board record carrying the
   panel/judge detail; here we surface that result as a just-arrived
   [pending_board_event]. When the sink failed to create the board post
   ([board_post_id = ""]) we still deliver the answer under a synthetic
   [fusion-run:<id>] id so it is never silently dropped. *)
let pending_board_event_of_fusion_completion
      ~(meta : keeper_meta)
      ~(arrived_at : float)
      (fc : Keeper_event_queue.fusion_completion)
  : pending_board_event
  =
  let post_id = Keeper_event_queue.fusion_completion_post_id fc in
  let title, message =
    match fc.terminal with
    | Keeper_event_queue.Fusion_succeeded answer ->
      Printf.sprintf "Fusion deliberation complete (run %s)" fc.run_id, answer
    | Keeper_event_queue.Fusion_failed detail ->
      Printf.sprintf "Fusion deliberation failed (run %s)" fc.run_id, detail
    | Keeper_event_queue.Fusion_cancelled ->
      ( Printf.sprintf "Fusion deliberation cancelled (run %s)" fc.run_id
      , "The asynchronous Fusion run was structurally cancelled before producing a result." )
  in
  { event_kind = Fusion_completed
  ; post_id
  ; author = meta.name
  ; title
  ; preview = short_preview ~max_len:fusion_result_preview_max_len message
  ; hearth = None
  ; post_kind = Board.System_post
  ; updated_at = arrived_at
  ; explicit_mention = false
  ; matched_targets = []
  ; self_commented = false
  ; new_external_since = 0
  ; latest_external_author = None
  ; latest_external_preview = None
  }
;;


let delegate_reply_preview_max_len = 480

(* An async composition this Keeper submitted has settled. It arrives as a
   just-arrived board event for the same reason a delegation answer does: the
   submitter is mid-cycle and reads its pending events, not a request store.
   The Keeper is its own author here -- it submitted the work.

   A success carries no preview. The result lives in the async request record
   and [keeper_composition_status] reads it by the request id in the title;
   putting the body here would duplicate a durable store into the prompt.
   A failure or cancellation carries its detail, which exists nowhere the
   Keeper can otherwise act on. *)
let pending_board_event_of_composition_completion
      ~(keeper_name : string)
      ~(arrived_at : float)
      (cc : Keeper_event_queue.composition_completion)
  : pending_board_event
  =
  let outcome, message =
    match cc.cc_terminal with
    | Keeper_event_queue.Composition_succeeded -> "succeeded", ""
    | Keeper_event_queue.Composition_failed detail -> "failed", detail
    | Keeper_event_queue.Composition_cancelled reason -> "cancelled", reason
  in
  { event_kind = Composition_completed
  ; post_id = Keeper_event_queue.composition_completion_post_id cc
  ; author = keeper_name
    (* Joined rather than formatted: the ratchet counts a format literal as a
       model-facing prose slot, and the three fields already say everything
       the row states. *)
  ; title = String.concat " " [ cc.cc_tool; outcome; cc.cc_request_id ]
  ; preview = short_preview ~max_len:delegate_reply_preview_max_len message
  ; hearth = None
  ; post_kind = Board.System_post
  ; updated_at = arrived_at
  ; explicit_mention = false
  ; matched_targets = []
  ; self_commented = false
  ; new_external_since = 0
  ; latest_external_author = None
  ; latest_external_preview = None
  }
;;

(* The answer to a turn this Keeper asked another Keeper to run. It arrives as
   a just-arrived board event for the same reason a Fusion result does: the
   asker is mid-cycle and reads its pending events, not a request store. The
   Keeper that ran the turn is named as the author so the row reads as an
   answer from someone rather than a note this Keeper wrote to itself. *)
let pending_board_event_of_delegate_completion
      ~(arrived_at : float)
      (dc : Keeper_event_queue.delegate_completion)
  : pending_board_event
  =
  (* The row is already [event=... post_id=... author=... preview=...], so the
     title states the outcome and nothing else: a sentence here would repeat
     what the structured fields say, and model-facing prose belongs in the
     config prompt files rather than in this module (RFC
     prompts-and-tool-definitions-outside-ocaml). [Delegate_no_reply] has no
     preview because there was no text; the outcome is the whole fact. *)
  let outcome, message =
    match dc.dc_terminal with
    | Keeper_event_queue.Delegate_replied reply -> "replied", reply
    | Keeper_event_queue.Delegate_no_reply -> "no_reply", ""
    | Keeper_event_queue.Delegate_failed detail -> "failed", detail
  in
  { event_kind = Delegate_completed
  ; post_id = Keeper_event_queue.delegate_completion_post_id dc
  ; author = dc.dc_keeper
  ; title = Printf.sprintf "%s %s" dc.dc_keeper outcome
  ; preview = short_preview ~max_len:delegate_reply_preview_max_len message
  ; hearth = None
  ; post_kind = Board.System_post
  ; updated_at = arrived_at
  ; explicit_mention = false
  ; matched_targets = []
  ; self_commented = false
  ; new_external_since = 0
  ; latest_external_author = None
  ; latest_external_preview = None
  }
;;

let scheduled_automation_actor = "scheduled_automation"

let pending_board_event_of_scheduled_wake
      ~meta:(_ : keeper_meta)
      ~post_id
      ~(arrived_at : float)
      (sw : Keeper_event_queue.scheduled_wake)
  : pending_board_event
  =
  (* [schedule_id] rides in [event_kind] as a typed pointer, so the fallback
     title no longer smuggles it into prose. That string form only survived on
     the untitled path, which left the pointer unreachable whenever the request
     set a title. *)
  let title =
    match sw.title with
    | Some title -> title
    | None -> "Scheduled keeper wake due"
  in
  { event_kind = Schedule_due sw
  ; post_id
  ; author = scheduled_automation_actor
  ; title
  ; preview = sw.message
  ; hearth = None
  ; post_kind = Board.System_post
  ; updated_at = arrived_at
  ; explicit_mention = false
  ; matched_targets = []
  ; self_commented = false
  ; new_external_since = 0
  ; latest_external_author = None
  ; latest_external_preview = None
  }
;;

let external_attention_actor_label (item : Keeper_external_attention.item) =
  match item.actor.display_name with
  | Some name when String.trim name <> "" -> name
  | Some _ | None ->
    (match item.actor.actor_id with
     | Some id when String.trim id <> "" -> id
     | Some _ | None -> item.source_label)
;;

let pending_board_event_of_external_attention
      ~(meta : keeper_meta)
      (item : Keeper_external_attention.item)
  : pending_board_event
  =
  let surface_label = Surface_ref.lane_label item.conversation.surface in
  let urgency_label = Keeper_external_attention.urgency_to_string item.urgency in
  let actor = external_attention_actor_label item in
  let counterpart = Keeper_counterpart_observation.of_external_attention item in
  let explicit_mention, matched_targets =
    match item.urgency with
    | Keeper_external_attention.Mention
    | Keeper_external_attention.Direct_message ->
      true, [ meta.name ]
    | Keeper_external_attention.Ambient
    | Keeper_external_attention.System ->
      false, []
  in
  { event_kind = External_attention counterpart
  ; post_id = "connector-attention:" ^ item.event_id
  ; author = actor
  ; title =
      Printf.sprintf
        "External %s attention (%s, conversation %s)"
        surface_label
        urgency_label
        item.conversation.conversation_id
  ; preview = short_preview ~max_len:fusion_result_preview_max_len item.content_preview
  ; hearth = None
  ; post_kind = Board.Human_post
  ; updated_at = item.received_at
  ; explicit_mention
  ; matched_targets
  ; self_commented = false
  ; new_external_since = 1
  ; latest_external_author = Some actor
  ; latest_external_preview = Some (short_preview ~max_len:80 item.content_preview)
  }
;;

(* A human answered a question this Keeper asked. The row carries the answer
   itself for the same reason [Composition_completed] does: the asker has
   nowhere else to read it mid-cycle, and a wake with no content is a wake it
   cannot act on. Choice ids are resolved to labels here — the id is the
   durable identity, the label is what a reader understands. *)
let ask_answer_line (ask : Keeper_ask.ask) (answer : Keeper_ask.answer) =
  let question =
    List.find_opt
      (fun (q : Keeper_ask.question) ->
        String.equal q.Keeper_ask.question_id answer.Keeper_ask.question_id)
      ask.Keeper_ask.questions
  in
  let header =
    match question with
    | Some q -> q.Keeper_ask.header
    | None -> answer.Keeper_ask.question_id
  in
  let said =
    match answer.Keeper_ask.response with
    | Keeper_ask.Wrote text -> text
    | Keeper_ask.Skipped -> "(skipped)"
    | Keeper_ask.Chose { choice_ids } ->
      let label choice_id =
        match question with
        | None -> choice_id
        | Some q ->
          (match
             List.find_opt
               (fun (c : Keeper_ask.choice) ->
                 String.equal c.Keeper_ask.choice_id choice_id)
               q.Keeper_ask.choices
           with
           | Some c -> c.Keeper_ask.label
           (* A choice the question no longer offers. Naming the id beats
              dropping the answer: the Keeper can still see one was made. *)
           | None -> choice_id)
      in
      String.concat ", " (List.map label choice_ids)
  in
  header ^ ": " ^ said
;;

let pending_board_event_of_ask_answer
      ~(meta : keeper_meta)
      ~(ask : Keeper_ask.ask)
      ~(answers : Keeper_ask.answer list)
      ~(responder : Keeper_ask.responder)
      ~(answered_at : float)
  : pending_board_event
  =
  let who =
    match responder.Keeper_ask.display_name with
    | Some name -> name
    | None ->
      (match responder.Keeper_ask.actor_id with
       | Some id -> id
       | None -> Surface_ref.lane_label responder.Keeper_ask.surface)
  in
  let body = String.concat " · " (List.map (ask_answer_line ask) answers) in
  { event_kind = Ask_answered_row
  ; post_id = "keeper-ask:" ^ ask.Keeper_ask.ask_id
  ; author = who
  ; title =
      Printf.sprintf
        "Answer to your question (%s, from %s)"
        ask.Keeper_ask.ask_id
        (Surface_ref.lane_label responder.Keeper_ask.surface)
  ; preview = short_preview ~max_len:fusion_result_preview_max_len body
  ; hearth = None
    (* Not a Board post: masc wrote this row, nobody posted it. Marked
       [Human_post] the Keeper read it as a post it could fetch and spent a
       masc_board_post_get on "Invalid post_id: keeper-ask" — the same waste
       the reply-content fields above were added to stop. The four sibling
       rows with no Board post behind them all say [System_post]. *)
  ; post_kind = Board.System_post
  ; updated_at = answered_at
  ; explicit_mention = true
  ; matched_targets = [ meta.name ]
  ; self_commented = false
  ; new_external_since = 1
  ; latest_external_author = Some who
  ; latest_external_preview = Some (short_preview ~max_len:80 body)
  }
;;

let pending_board_event_of_completion_authority_rejection
      ~(arrived_at : float)
      (rejection : Keeper_event_queue.completion_authority_rejection)
  : pending_board_event
  =
  { event_kind = Completion_authority_rejected rejection
  ; post_id = Keeper_event_queue.completion_authority_rejection_post_id rejection
  ; author = Masc_domain.completion_authority_actor rejection.car_authority
  ; title =
      Printf.sprintf
        "Completion evidence rejected for task %s"
        rejection.car_task_id
  ; preview =
      short_preview
        ~max_len:fusion_result_preview_max_len
        (Printf.sprintf
           "Task %s verification %s was rejected by %s. Follow-up reason: %s"
           rejection.car_task_id
           rejection.car_verification_id
           (Masc_domain.completion_authority_kind rejection.car_authority)
           rejection.car_reason)
  ; hearth = None
  ; post_kind = Board.System_post
  ; updated_at = arrived_at
  ; explicit_mention = false
  ; matched_targets = []
  ; self_commented = false
  ; new_external_since = 1
  ; latest_external_author =
      Some (Masc_domain.completion_authority_actor rejection.car_authority)
  ; latest_external_preview = Some (short_preview ~max_len:80 rejection.car_reason)
  }
;;

(* The author asked for this work and another Keeper ended it. Without this
   projection the cancellation reached the author through no channel at all:
   completion posts a verdict to Board and submission posts a request, but a
   cancellation left only a backlog field and an activity row. *)
let pending_board_event_of_task_cancellation
      ~(arrived_at : float)
      (cancellation : Keeper_event_queue.task_cancellation)
  : pending_board_event
  =
  let reason_text =
    match cancellation.tc_reason with
    | Some reason when String.trim reason <> "" -> reason
    | Some _ | None -> "no reason was given"
  in
  { event_kind = Task_cancelled cancellation
  ; post_id = Keeper_event_queue.task_cancellation_post_id cancellation
  ; author = cancellation.tc_cancelled_by
  ; title = Printf.sprintf "Task %s was cancelled" cancellation.tc_task_id
  ; preview =
      short_preview
        ~max_len:fusion_result_preview_max_len
        (Printf.sprintf
           "Task %s, which you created, was cancelled by %s. Stated reason: %s"
           cancellation.tc_task_id
           cancellation.tc_cancelled_by
           reason_text)
  ; hearth = None
  ; post_kind = Board.System_post
  ; updated_at = arrived_at
  ; explicit_mention = false
  ; matched_targets = []
  ; self_commented = false
  ; new_external_since = 1
  ; latest_external_author = Some cancellation.tc_cancelled_by
  ; latest_external_preview = Some (short_preview ~max_len:80 reason_text)
  }
;;

let pending_board_event_of_stimulus
      ~(meta : keeper_meta)
  (stimulus : Keeper_event_queue.stimulus)
  : (pending_board_event option, Board_signal.board_unavailable) result
  =
  match stimulus.payload with
  | Keeper_event_queue.Board_signal bs ->
    Result.map
      (fun ev -> Some ev)
      (pending_board_event_of_board_signal
         ~meta
         ~arrived_at:stimulus.arrived_at
         (Board_signal.board_signal_of_board_stimulus ~post_id:stimulus.post_id bs))
  | Keeper_event_queue.Board_attention attention ->
    Result.map
      (fun ev -> Some ev)
      (pending_board_event_of_board_signal
         ~meta
         ~arrived_at:stimulus.arrived_at
         (Board_signal.board_signal_of_board_stimulus
            ~post_id:stimulus.post_id
            attention.signal))
  | Keeper_event_queue.Fusion_completed fc ->
    Ok (Some (pending_board_event_of_fusion_completion ~meta ~arrived_at:stimulus.arrived_at fc))
  | Keeper_event_queue.Schedule_due sw ->
    Ok
      (Some
         (pending_board_event_of_scheduled_wake
            ~meta
            ~post_id:stimulus.post_id
            ~arrived_at:stimulus.arrived_at
            sw))
  | Keeper_event_queue.Completion_authority_rejected rejection ->
    Ok
      (Some
         (pending_board_event_of_completion_authority_rejection
            ~arrived_at:stimulus.arrived_at
            rejection))
  | Keeper_event_queue.Task_cancelled cancellation ->
    Ok
      (Some
         (pending_board_event_of_task_cancellation
            ~arrived_at:stimulus.arrived_at
            cancellation))
  | Keeper_event_queue.Delegate_completed dc ->
    Ok
      (Some
         (pending_board_event_of_delegate_completion
            ~arrived_at:stimulus.arrived_at
            dc))
  | Keeper_event_queue.Composition_completed cc ->
    Ok
      (Some
         (pending_board_event_of_composition_completion
            ~keeper_name:meta.name
            ~arrived_at:stimulus.arrived_at
            cc))
  | Keeper_event_queue.Bootstrap
  | Keeper_event_queue.Connector_attention _
  | Keeper_event_queue.Hitl_resolved _
  (* Same as [Hitl_resolved]: the wake and its turn reason are what steer the
     keeper back to the question. The answer itself stays in
     [Keeper_ask_store], which the keeper reads with masc_ask_status, so
     nothing is injected here and the text lives in one place. *)
  | Keeper_event_queue.Ask_answered _
  | Keeper_event_queue.Workspace_message _ ->
    (* RFC-connector-ambient-attention-wake P1: not a board event. The wake
       fires via the trigger itself; [Hitl_resolved] carries no observation to
       inject — the keeper resumes on its own state once the approval is gone
       from the queue. [Workspace_message] carries a pointer to a transcript row
       the message lane already reads, so injecting a board event here would
       show the operator the same message twice. *)
    Ok None
;;

(** Collect recent board activity using cursor-based tracking.
    Cursor state lives in Keeper_registry as [(updated_at, post_id)].
    Returns (structured events, new post count, mention count).

    Comment-stream dedup: after the initial cursor + author filter,
    each candidate post is scanned for self-authored comments.
    Posts where the keeper has already commented and no new external
    replies have arrived are excluded. This prevents duplicate reactive
    comments while allowing legitimate follow-ups. *)
let collect_board_events_with_cursor_policy
      ~advance_cursor
      ~(base_path : string)
      ~(meta : keeper_meta)
  : pending_board_event list * int * int
  =
  try
    let cursor_ts, cursor_post_id =
      Keeper_registry.get_board_cursor ~base_path meta.name
    in
    let base_cursor =
      if cursor_ts > 0.0
      then Some (cursor_ts, cursor_post_id)
      else (
        let initial_cursor = Board_dispatch.current_post_cursor () in
        if advance_cursor
        then (
          let ts, post_id = initial_cursor in
          Keeper_registry.set_board_cursor ~base_path meta.name ts post_id;
          (match post_id with
           | Some post_id ->
             Log.Keeper.info
               "board cursor initialized at current head for %s: (%f, %s)"
               meta.name
               ts
               post_id
           | None ->
             Log.Keeper.info
               "board cursor initialized at empty current head for %s: (%f, no post)"
               meta.name
               ts));
        None)
    in
    let posts =
      match base_cursor with
      | None -> []
      | Some cursor -> list_board_posts_after_cursor cursor
    in
    let self_ids = self_ids meta in
    let recent =
      List.filter
        (fun (p : Board.post) ->
           not (is_self_author ~self_ids (Board.Agent_id.to_string p.author)))
        posts
    in
    let new_count = List.length recent in
    let mention_count =
      List.length
        (List.filter
           (fun (p : Board.post) ->
              let signal : Board_dispatch.board_signal =
                { kind = Board_dispatch.Board_post_created
                ; post_id = Board.Post_id.to_string p.id
                ; author = Board.Agent_id.to_string p.author
                ; title = p.title
                ; content = p.body
                ; hearth = p.hearth
                ; updated_at = Some p.updated_at
                }
              in
              (board_signal_match ~meta ~signal).explicit_mention)
           recent)
    in
    (* Board-unavailable-result: classify + log + count a failed read
       encountered mid-scan, without raising. [Permanent] means this one post
       can never resolve (e.g. swept from the store) — the caller skips it
       and keeps scanning. [Transient] means the caller stops scanning here
       and returns what it already has, so the cursor is not advanced past
       the blocked post and the same post is retried next cycle (preserves
       the pre-existing "retained cursor" semantics, now via Result instead
       of exception + re-raise). *)
    let log_and_count_unavailable ~context (unavailable : Board_signal.board_unavailable) =
      let disposition = Board_signal.disposition_of_unavailable unavailable in
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ObservationQueryFailures)
        ~labels:[ ("operation", Runtime_observation_query_operation.(to_label Board_events)) ]
        ();
      (match disposition with
       | Board_signal.Permanent ->
         Log.Keeper.warn
           "board event collection (%s): permanently unavailable, skipping post_id=%s \
            keeper=%s: %s"
           context
           unavailable.Board_signal.post_id
           meta.name
           (Board_signal.unavailable_to_string unavailable)
       | Board_signal.Transient ->
         Log.Keeper.warn
           "board event collection (%s): retained cursor (transient unavailable) \
            post_id=%s keeper=%s: %s"
           context
           unavailable.Board_signal.post_id
           meta.name
           (Board_signal.unavailable_to_string unavailable));
      disposition
    in
    let rec consume_posts last_cursor acc = function
      | [] -> List.rev acc, last_cursor
      | (p : Board.post) :: rest ->
        let post_id = Board.Post_id.to_string p.id in
        let next_cursor = board_cursor_token_of_post p in
        let comment_status = check_self_comment_status ~self_ids ~post_id in
        (match comment_status with
         | Board_signal.Unavailable unavailable ->
           (match log_and_count_unavailable ~context:"comment status" unavailable with
            | Board_signal.Permanent -> consume_posts (Some next_cursor) acc rest
            | Board_signal.Transient -> List.rev acc, last_cursor)
         | Board_signal.Available `No_new_external ->
           Log.Keeper.debug
             "board dedup: skipping post_id=%s (no new external since my comment)"
             post_id;
           consume_posts (Some next_cursor) acc rest
         | Board_signal.Available `Never ->
           let signal : Board_dispatch.board_signal =
             { kind = Board_dispatch.Board_post_created
             ; post_id
             ; author = Board.Agent_id.to_string p.author
             ; title = p.title
             ; content = p.body
             ; hearth = p.hearth
             ; updated_at = Some p.updated_at
             }
           in
           let matched = board_signal_match ~meta ~signal in
           (match Board_audience.classify ~visibility:p.visibility signal with
            | Error error ->
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string ObservationQueryFailures)
                ~labels:
                  [ ( "operation"
                    , Runtime_observation_query_operation.(to_label Board_events) )
                  ]
                ();
              Log.Keeper.warn
                "board replay audience rejected: keeper=%s post=%s error=%s"
                meta.name
                post_id
                (Board_audience.classification_error_to_string error);
              consume_posts (Some next_cursor) acc rest
            | Ok audience ->
              (match Board_audience.route_for_keeper ~audience ~meta ~signal with
               | Board_signal.Unavailable unavailable ->
                 (match
                    log_and_count_unavailable ~context:"audience" unavailable
                  with
                  | Board_signal.Permanent ->
                    consume_posts (Some next_cursor) acc rest
                  | Board_signal.Transient -> List.rev acc, last_cursor)
               | Board_signal.Available Board_audience.Ignore ->
                 consume_posts (Some next_cursor) acc rest
               | Board_signal.Available Board_audience.Judge_discoverable ->
                 (* Only the live Keeper collector owns durable candidate
                    production. Dashboard prompt preview uses
                    [advance_cursor:false] and must remain a read-only projection:
                    observing the page cannot schedule a model judgment or wake a
                    Keeper lane. *)
                 if not advance_cursor
                 then consume_posts (Some next_cursor) acc rest
                 else (
                   match
                     Keeper_board_attention_candidate.of_board_signal
                       ~meta
                       ~recorded_at:(Time_compat.now ())
                       signal
                   with
                   | Board_signal.Unavailable unavailable ->
                     (match
                        log_and_count_unavailable ~context:"candidate" unavailable
                      with
                      | Board_signal.Permanent ->
                        consume_posts (Some next_cursor) acc rest
                      | Board_signal.Transient -> List.rev acc, last_cursor)
                   | Board_signal.Available candidate ->
                     (match
                        Keeper_board_attention_candidate.record_and_wake
                          ~base_path
                          candidate
                      with
                      | Ok acceptance ->
                        let persistence =
                          match acceptance.persistence with
                          | Keeper_board_attention_candidate.Candidate_recorded ->
                            "recorded"
                          | Keeper_board_attention_candidate.Candidate_already_present ->
                            "duplicate"
                        in
                        Otel_metric_store.inc_counter
                          Keeper_metrics.(to_string BoardSignalAttentionCandidateTotal)
                          ~labels:
                            [ "keeper", meta.name
                            ; "kind", "post_created"
                            ; "audience", Board_audience.label audience
                            ; "persistence", persistence
                            ]
                          ()
                      | Error detail ->
                        raise
                          (Keeper_board_attention_candidate.Candidate_unavailable
                             detail));
                     consume_posts (Some next_cursor) acc rest)
               | Board_signal.Available (Board_audience.Deliver _) ->
                 (* [explicit_mention] mirrors mention parsing only:
                    Broadcast-routed deliveries (e.g. [@@all]) record
                    [false] because a broadcast has no per-keeper mention
                    target. The event's presence in this Deliver branch
                    already marks it as addressed; downstream
                    (the unified-prompt board event renderer)
                    uses the field solely to render a "[mentions ...]"
                    note. *)
                 consume_posts
                   (Some next_cursor)
                   ({ event_kind = Board_post_created
                    ; post_id
                    ; author = Board.Agent_id.to_string p.author
                    ; title = p.title
                    ; preview = short_preview ~max_len:80 p.body
                    ; hearth = p.hearth
                    ; post_kind = p.post_kind
                    ; updated_at = p.updated_at
                    ; explicit_mention = matched.explicit_mention
                    ; matched_targets = matched.matched_targets
                    ; self_commented = false
                    ; new_external_since = 0
                    ; latest_external_author = None
                    ; latest_external_preview = None
                    }
                    :: acc)
                   rest))
         | Board_signal.Available (`New_external (count, ext_author, ext_preview)) ->
           (
             let signal : Board_dispatch.board_signal =
               { kind = Board_dispatch.Board_post_created
               ; post_id
               ; author = Board.Agent_id.to_string p.author
               ; title = p.title
               ; content = p.body
               ; hearth = p.hearth
               ; updated_at = Some p.updated_at
               }
             in
             let matched = board_signal_match ~meta ~signal in
             consume_posts
               
               (Some next_cursor)
               ({ event_kind = Board_post_created
                ; post_id
                ; author = Board.Agent_id.to_string p.author
                ; title = p.title
                ; preview = short_preview ~max_len:80 p.body
                ; hearth = p.hearth
                ; post_kind = p.post_kind
                ; updated_at = p.updated_at
                ; explicit_mention = matched.explicit_mention
                ; matched_targets = matched.matched_targets
                ; self_commented = true
                ; new_external_since = count
                ; latest_external_author = Some ext_author
                ; latest_external_preview = Some ext_preview
                }
                :: acc)
               rest))
    in
    let final_events, last_cursor = consume_posts None [] recent in
    if advance_cursor
    then (
      match base_cursor, last_cursor with
      | None, _ -> ()
      | Some base_cursor, Some (ts, post_id)
        when compare_board_cursor_token
               (ts, post_id)
               (fst base_cursor, Option.value ~default:"" (snd base_cursor))
             > 0 ->
        Keeper_registry.set_board_cursor ~base_path meta.name ts (Some post_id)
      | Some base_cursor, Some (ts, post_id) ->
        Log.Keeper.debug
          "board cursor not advanced for %s: new=(%f, %s) not greater than base=(%f, %s)"
          meta.name
          ts
          post_id
          (fst base_cursor)
          (Option.value ~default:"" (snd base_cursor))
      | Some _, None ->
        if final_events <> []
        then (
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string ObservationQueryFailures)
            ~labels:[ ("operation", Runtime_observation_query_operation.(to_label Cursor_stale)) ]
            ();
          Log.Keeper.warn
            "board cursor not updated for %s despite %d events processed"
            meta.name
            (List.length final_events))
    );
    final_events, new_count, mention_count
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Keeper_board_attention_candidate.Candidate_unavailable detail as exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ObservationQueryFailures)
      ~labels:
        [ ( "operation"
          , Runtime_observation_query_operation.(to_label Board_events) )
        ]
      ();
    Log.Keeper.warn
      "board event collection retained cursor: candidate storage unavailable: %s"
      detail;
    raise exn
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ObservationQueryFailures)
      ~labels:[ ("operation", Runtime_observation_query_operation.(to_label Board_events)) ]
      ();
    Log.Keeper.warn "board event collection failed: %s" (Printexc.to_string exn);
    raise exn
;;

let collect_board_events
      ~(base_path : string)
      ~(meta : keeper_meta)
  : pending_board_event list * int * int
  =
  collect_board_events_with_cursor_policy
    ~advance_cursor:true
    ~base_path
    ~meta
;;

let collect_board_events_without_advancing_cursor
      ~(base_path : string)
      ~(meta : keeper_meta)
  : pending_board_event list * int * int
  =
  collect_board_events_with_cursor_policy
    ~advance_cursor:false
    ~base_path
    ~meta
;;

(* Goals are shared intent: the store is the only record of which ones are
   still open, so the observation reads it directly. *)
let open_goal_ids ~(config : Workspace.config) =
  Goal_store.list_goals config ()
  |> List.filter_map (fun (g : Goal_store.goal) ->
       if Goal_phase.admits_self_directed_progress g.phase then Some g.id else None)
;;

let observe
      ~(pending_board_events : pending_board_event list option)
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
  : world_observation
  =
  let pending_messages, fleet_messages =
    collect_message_scope_and_fleet
      ~config
      ~meta
      ~fleet_limit:(Keeper_config.keeper_fleet_messages_max ())
  in
  let backlog_snapshot = read_backlog_snapshot ~config ~meta in
  let unclaimed_task_count = backlog_snapshot.unclaimed_count in
  let claimable_tasks = backlog_snapshot.claimable_tasks in
  let failed_task_count = backlog_snapshot.failed_count in
  let backlog_revision = backlog_snapshot.revision in
  let running_keeper_fiber_count = count_running_keeper_fibers ~config in
  let idle_seconds = compute_idle_seconds ~meta in
  let scheduled_automation =
    read_scheduled_automation_observation
      ~keeper_name:(Some meta.name)
      ~config
      ~now:(Time_compat.now ())
  in
  let approval_authority = read_approval_authority_observation ~config ~meta in
  let pending_board_events =
    match pending_board_events with
    | Some events -> events
    | None ->
      let events, _board_new_count, _board_mention_count =
        collect_board_events ~base_path:config.base_path ~meta
      in
      events
  in
  let surface_presence =
    Gate_surface.connected_surfaces_for_keeper ~keeper_name:meta.name
  in
  { pending_messages
  ; pending_board_events
  ; idle_seconds
  ; active_goals = open_goal_ids ~config
  ; unclaimed_task_count
  ; claimable_tasks
  ; held_task_skills = backlog_snapshot.held_task_skills
  ; failed_task_count
  ; scheduled_automation
  ; approval_authority
  ; backlog_revision
  ; running_keeper_fiber_count
  ; connected_surfaces = surface_presence.surfaces
  ; connected_surface_failures = surface_presence.failures
  ; own_recent_board_posts = collect_own_recent_board_posts ~meta
  ; fleet_messages
  ; own_recent_actions =
      Keeper_own_recent_actions.collect
        ~keeper_name:meta.name
        ~max_turns:(Keeper_config.keeper_own_recent_turns_max ())
  }
;;

let observe_direct_keeper_msg ~(config : Workspace.config) ~(meta : keeper_meta)
  : world_observation
  =
  let backlog_snapshot = read_backlog_snapshot ~config ~meta in
  let unclaimed_task_count = backlog_snapshot.unclaimed_count in
  let claimable_tasks = backlog_snapshot.claimable_tasks in
  let failed_task_count = backlog_snapshot.failed_count in
  let backlog_revision = backlog_snapshot.revision in
  let scheduled_automation =
    read_scheduled_automation_observation
      ~keeper_name:(Some meta.name)
      ~config
      ~now:(Time_compat.now ())
  in
  let approval_authority = read_approval_authority_observation ~config ~meta in
  let surface_presence =
    Gate_surface.connected_surfaces_for_keeper ~keeper_name:meta.name
  in
  { pending_messages = []
  ; pending_board_events = []
  ; idle_seconds = compute_idle_seconds ~meta
  ; active_goals = open_goal_ids ~config
  ; unclaimed_task_count
  ; claimable_tasks
  ; held_task_skills = backlog_snapshot.held_task_skills
  ; failed_task_count
  ; scheduled_automation
  ; approval_authority
  ; backlog_revision
  ; running_keeper_fiber_count = count_running_keeper_fibers ~config
  ; connected_surfaces = surface_presence.surfaces
  ; connected_surface_failures = surface_presence.failures
  ; own_recent_board_posts = collect_own_recent_board_posts ~meta
    (* No fleet layer here. This path answers a direct keeper message and
       empties the reactive lanes because the triggering message is the point,
       and collecting fleet rows would mean a full transcript read
       ([Keeper_chat_store.load_all], 1.8 MB in production) on a path that
       performs no transcript I/O at all. The keeper sees fleet context on its
       next [observe] turn, where the same load already happens. *)
  ; fleet_messages = []
  ; own_recent_actions = []
  }
;;

(* Backlog facts are raw wake observations. Whether and how to act is a model
   decision after wake; local tool-name or mutation semantics must not suppress
   a signal before the Keeper can observe it. *)
let claimable_drives_wake claimable_task_count = claimable_task_count > 0
let failed_drives_wake failed_task_count = failed_task_count > 0
(* An AwaitingVerification obligation is NOT a Keeper wake signal: the
   application-owned system LLM completion authority or authenticated HITL
   operator decides it out of band. Neither authority is a Keeper. Surfacing
   it here would hand Keepers work that is not theirs — which is how a Keeper
   named "verifier" came to hold approval authority in the first place. *)
let actionable_signal_present (observation : world_observation) =
  observation.pending_messages <> []
  || observation.pending_board_events <> []
  || claimable_drives_wake (claimable_task_count observation)
  || failed_drives_wake observation.failed_task_count
  || observation.scheduled_automation.due_ready_count > 0
;;

let has_pending_board_activity (observation : world_observation) =
  List.exists is_board_activity_event observation.pending_board_events

let has_pending_completion_authority_rejection
      (observation : world_observation)
  =
  List.exists
    is_completion_authority_rejection_event
    observation.pending_board_events
;;

let has_pending_task_cancellation (observation : world_observation) =
  List.exists is_task_cancellation_event observation.pending_board_events
;;

let keeper_cycle_decision
      ?(event_queue_triggers = [])
      ~(meta : keeper_meta)
      (observation : world_observation)
  =
  (* RFC-0297 P0-1: reactive and proactive turns run only when their lifecycle
     gate is enabled — the global kill-switch AND the per-keeper flag. Resolved
     through the single SSOT [Keeper_lifecycle_gate_env.enabled] so the enabled
     decision is not re-derived inline. Before this the global switches did not
     exist, so [reactive]/[proactive] enabled = false were silently dropped. *)
  let reactive_gate_enabled =
    Keeper_lifecycle_gate_env.enabled Keeper_lifecycle_gate.Reactive meta
  in
  let proactive_gate_enabled =
    Keeper_lifecycle_gate_env.enabled Keeper_lifecycle_gate.Proactive meta
  in
  (* A scheduler wake delivered through the event queue is a scheduled
     stimulus, not a reactive one. Routing it through the reactive trigger
     list ran the turn with [channel = Reactive], which applied the
     reactive prompt/sleep semantics and dropped the wake from every
     [channel = Scheduled_autonomous] reader (proactive evidence, decision
     log proof). The due signal joins the scheduled-autonomous decision
     below instead; a wake that coincides with a real reactive trigger
     still attributes to that trigger. *)
  let scheduled_due_from_queue, event_queue_reactive_triggers =
    List.map turn_reason_of_event_queue_trigger event_queue_triggers
    |> List.partition (function
      | Scheduled_automation_due -> true
      | Mention_pending
      | Board_event_pending
      | Scope_message_pending
      | Bootstrap_stimulus_pending
      | Connector_attention_pending
      | Ask_answered_pending
      | Hitl_resolved_pending
      | Completion_authority_rejection_pending
      | Task_cancellation_pending
      | Workspace_message_pending
      | Scheduled_autonomous_turn
      | Task_backlog _
      | Never_started -> false)
  in
  let scheduled_due_from_queue = scheduled_due_from_queue <> [] in
  let reactive_triggers =
    [ (if Message_scope.has_kind Message_scope.Mention observation.pending_messages
       then Some Mention_pending
       else None)
    ; (if has_pending_board_activity observation then Some Board_event_pending else None)
    ; (if Message_scope.has_kind Message_scope.Scope observation.pending_messages
       then Some Scope_message_pending
       else None)
    ]
    |> List.filter_map Fun.id
    |> fun triggers -> triggers @ event_queue_reactive_triggers
    |> fun triggers ->
    if has_pending_completion_authority_rejection observation
       && not
            (List.exists
               (function
                 | Completion_authority_rejection_pending -> true
                 | Mention_pending
                 | Board_event_pending
                 | Scope_message_pending
                 | Bootstrap_stimulus_pending
                 | Connector_attention_pending
                 | Ask_answered_pending
                 | Hitl_resolved_pending
                 | Task_cancellation_pending
                 | Workspace_message_pending
                 | Scheduled_autonomous_turn
                 | Scheduled_automation_due
                 | Task_backlog _
                 | Never_started -> false)
               triggers)
    then triggers @ [ Completion_authority_rejection_pending ]
    else triggers
    (* Same shape as the rejection injection above: the observation may carry a
       cancellation whose stimulus was already consumed from the event queue by
       an earlier cycle, and the turn must still be attributable to it rather
       than reported as an unexplained autonomous tick. *)
  |> fun triggers ->
    if has_pending_task_cancellation observation
       && not (List.mem Task_cancellation_pending triggers)
    then triggers @ [ Task_cancellation_pending ]
    else triggers
  in
  let blocked_channel =
    match reactive_triggers with
    | _ :: _ -> Reactive
    | [] -> Scheduled_autonomous
  in
  let blocked reason =
    { should_run = false
    ; channel = blocked_channel
    ; verdict = Skip { reasons = reason, [] }
    ; since_last_scheduled_autonomous = None
    }
  in
  if meta.paused
  then blocked Keeper_paused
  else (
    let scheduled_autonomous_decision () =
      let since_last_scheduled_autonomous =
        if meta.runtime.proactive_rt.last_ts <= 0.0
        then max_int
        else
          int_of_float (max 0.0 (Time_compat.now () -. meta.runtime.proactive_rt.last_ts))
      in
      if not proactive_gate_enabled
      then
        { should_run = false
        ; channel = Scheduled_autonomous
        ; verdict = Skip { reasons = Scheduled_autonomous_disabled, [] }
        ; since_last_scheduled_autonomous = Some since_last_scheduled_autonomous
        }
      else (
        (* A scheduled heartbeat is itself the wake signal. Backlog, schedule,
           idle time, and previous-turn age remain observations for the model;
           fixed local thresholds never suppress a Keeper cycle. *)
        let has_actionable_tasks =
          claimable_drives_wake (claimable_task_count observation)
          || failed_drives_wake observation.failed_task_count
        in
        let has_actionable_schedule =
          observation.scheduled_automation.due_ready_count > 0
          || scheduled_due_from_queue
        in
        let is_bootstrap = since_last_scheduled_autonomous = max_int in
        let run_reasons =
          [ (if is_bootstrap then Some Never_started else None)
          ; (if has_actionable_tasks
             then
               Some
                 (Task_backlog
                    { unclaimed = claimable_task_count observation
                    ; failed = observation.failed_task_count
                    })
             else None)
          ; (if has_actionable_schedule then Some Scheduled_automation_due else None)
          ]
          |> List.filter_map Fun.id
        in
        { should_run = true
        ; channel = Scheduled_autonomous
        ; verdict = Run { reasons = Scheduled_autonomous_turn, run_reasons }
        ; since_last_scheduled_autonomous = Some since_last_scheduled_autonomous
        })
    in
    match reactive_triggers with
    | first :: rest when reactive_gate_enabled ->
      { should_run = true
      ; channel = Reactive
      ; verdict = Run { reasons = first, rest }
      ; since_last_scheduled_autonomous = None
      }
    | _ ->
      (* RFC-0297 P0-1: when the reactive gate is disabled, a pending reactive
         trigger must not itself starve the scheduled-autonomous decision --
         otherwise a persistent trigger (e.g. a stuck mention) permanently
         blocks proactive turns even when MASC_KEEPER_PROACTIVE_ENABLED=true.
         This arm also covers the original no-reactive-trigger ([]) case.
         Only relabel the verdict as [Reactive_disabled] when
         scheduled-autonomous also declines to run, so the more specific,
         actionable reason survives when a suppressed reactive signal was the
         only thing pending. Review-flagged. *)
      let decision = scheduled_autonomous_decision () in
      if decision.should_run || reactive_gate_enabled || reactive_triggers = []
      then decision
      else
        { decision with
          channel = Reactive
        ; verdict = Skip { reasons = Reactive_disabled, [] }
        })
;;
