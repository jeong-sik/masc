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
  | Fusion_completed
  | Bg_completed
  | Schedule_due
  | External_attention
  | Failure_judgment
  | Goal_assigned

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

type scheduled_automation_item =
  { schedule_id : string
  ; action : string
  ; status : string
  ; payload_kind : string option
  ; recurrence_summary : string
  ; due_at : float
  ; keeper_next_tool : string option
  ; keeper_next_action : string
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

type world_observation =
  { pending_messages : Keeper_world_observation_message_scope.pending_message list
  ; pending_board_events : pending_board_event list
  ; idle_seconds : int
  ; active_goals : string list
  ; unclaimed_task_count : int
  ; claimable_task_count : int
  ; failed_task_count : int
  ; pending_verification_count : int
  ; scheduled_automation : scheduled_automation_observation
  ; backlog_updated_since_last_scheduled_autonomous : bool
  ; running_keeper_fiber_count : int
  ; connected_surfaces : Gate_surface.surface_presence list
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
  | Hitl_resolved_stimulus
  | Failure_judgment_stimulus

type turn_reason = Keeper_world_observation_turn_types.turn_reason =
  | Mention_pending
  | Board_event_pending
  | Scope_message_pending
  | Bootstrap_stimulus_pending
  | Connector_attention_pending
  | Hitl_resolved_pending
  | Failure_judgment_pending
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

type board_signal_match = Board_signal.match_result =
  { explicit_mention : bool
  ; matched_targets : string list
  }

module Message_scope = Keeper_world_observation_message_scope
module Inputs = Keeper_world_observation_inputs

let self_ids = Message_scope.self_ids
let is_self_author = Message_scope.is_self_author

let collect_message_scope = Message_scope.collect_message_scope
let read_backlog_counts = Inputs.read_backlog_counts
let count_running_keeper_fibers = Inputs.count_running_keeper_fibers
let compute_idle_seconds = Inputs.compute_idle_seconds
let board_signal_match = Board_signal.match_signal
let check_self_comment_status = Board_signal.check_self_comment_status
let board_signal_wake_reason = Board_signal.wake_reason
let compare_board_cursor_token = Board_signal.compare_cursor_token
let board_cursor_token_of_post = Board_signal.cursor_token_of_post
let list_board_posts_after_cursor = Board_signal.list_posts_after_cursor

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
  ; keeper_next_tool = Schedule_projection.keeper_next_tool_for_attention_action action
  ; keeper_next_action = Schedule_projection.keeper_next_action_for_attention_action action
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

let schedule_visible_to_keeper keeper_name (request : Schedule_domain.schedule_request)
  =
  match keeper_name with
  | None -> true
  | Some keeper_name ->
    (match request.scheduled_by.kind with
     | Schedule_domain.Automated_actor -> String.equal request.scheduled_by.id keeper_name
     | Schedule_domain.Human_operator | Schedule_domain.System -> false)
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
      Schedule_store.due_execution_candidates state
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

(** Board event cursor bootstrap window (seconds). *)
let bootstrap_window_sec = Env_config.InternalTimers.bootstrap_window_sec

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
;;

let pending_board_event_of_board_signal
      ~(meta : keeper_meta)
      ~arrived_at:(_ : float)
      (signal : Board_dispatch.board_signal)
  : pending_board_event
  =
  let self_ids = self_ids meta in
  let matched = board_signal_match ~meta ~signal in
  let post_snapshot =
    match Board_dispatch.get_post ~post_id:signal.post_id with
    | Ok post -> post
    | Error error ->
      Board_signal.raise_unavailable
        { operation = Board_signal.Get_post; post_id = signal.post_id; error }
  in
  let title, preview, hearth, post_kind, updated_at =
    let post : Board.post = post_snapshot in
    ( post.title
    , short_preview ~max_len:80 post.content
    , post.hearth
    , post.post_kind
    , post.updated_at )
  in
  let event_kind = pending_board_event_kind_of_signal signal in
  let self_commented, new_external_since, latest_external_author, latest_external_preview =
    match signal.kind with
    | Board_dispatch.Board_post_created -> false, 0, None, None
    | Board_dispatch.Board_comment_added ->
      (match check_self_comment_status ~self_ids ~post_id:signal.post_id with
       | Board_signal.Unavailable unavailable ->
         Board_signal.raise_unavailable unavailable
       | Board_signal.Available (`New_external (count, author, preview)) ->
         true, count, Some author, Some preview
       | Board_signal.Available `No_new_external ->
         true, 0, Some signal.author, Some (short_preview ~max_len:60 signal.content)
       | Board_signal.Available `Never ->
         false, 1, Some signal.author, Some (short_preview ~max_len:60 signal.content))
    | Board_dispatch.Board_reaction_changed _ ->
      (match check_self_comment_status ~self_ids ~post_id:signal.post_id with
       | Board_signal.Unavailable unavailable ->
         Board_signal.raise_unavailable unavailable
       | Board_signal.Available `Never -> false, 0, None, None
       | Board_signal.Available (`No_new_external | `New_external _) ->
         true, 0, None, None)
  in
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
  }
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
  let title =
    if fc.ok
    then Printf.sprintf "Fusion deliberation complete (run %s)" fc.run_id
    else Printf.sprintf "Fusion deliberation failed (run %s)" fc.run_id
  in
  { event_kind = Fusion_completed
  ; post_id
  ; author = meta.name
  ; title
  ; preview = short_preview ~max_len:fusion_result_preview_max_len fc.resolved_answer
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

let bg_job_completion_message = function
  | Keeper_event_queue.Bg_ok output -> output
  | Keeper_event_queue.Bg_failed reason -> reason
;;

(* RFC-0290: mirror the async-fusion delivery contract for generic background
   jobs. A [Bg_completed] stimulus already means the background producer has
   decided the job is finished; converting it here keeps the queue consumer from
   silently dropping the result. *)
let pending_board_event_of_bg_job_completion
      ~(meta : keeper_meta)
      ~(arrived_at : float)
      (c : Keeper_event_queue.bg_job_completion)
  : pending_board_event
  =
  let post_id = Keeper_event_queue.bg_job_completion_post_id c in
  let kind = Keeper_event_queue.bg_job_kind_to_string c.bg_kind in
  let title =
    match c.bg_outcome with
    | Keeper_event_queue.Bg_ok _ ->
      Printf.sprintf "Background %s complete (run %s)" kind c.bg_run_id
    | Keeper_event_queue.Bg_failed _ ->
      Printf.sprintf "Background %s failed (run %s)" kind c.bg_run_id
  in
  { event_kind = Bg_completed
  ; post_id
  ; author = meta.name
  ; title
  ; preview =
      short_preview
        ~max_len:fusion_result_preview_max_len
        (bg_job_completion_message c.bg_outcome)
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
  let title =
    match sw.title with
    | Some title -> title
    | None -> Printf.sprintf "Scheduled keeper wake due (schedule %s)" sw.schedule_id
  in
  { event_kind = Schedule_due
  ; post_id
  ; author = scheduled_automation_actor
  ; title
  ; preview = short_preview ~max_len:fusion_result_preview_max_len sw.message
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
  let explicit_mention, matched_targets =
    match item.urgency with
    | Keeper_external_attention.Mention
    | Keeper_external_attention.Direct_message ->
      true, [ meta.name ]
    | Keeper_external_attention.Ambient
    | Keeper_external_attention.System ->
      false, []
  in
  { event_kind = External_attention
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

(* RFC-0313 W2: surface a deterministic turn failure as actionable turn input
   for an LLM-boundary verdict. *)
let pending_board_event_of_failure_judgment
      ~(meta : keeper_meta)
      ~(arrived_at : float)
      (fj : Keeper_event_queue.failure_judgment)
  : pending_board_event
  =
  let author = meta.name in
  { event_kind = Failure_judgment
  ; post_id = Keeper_event_queue.failure_judgment_post_id fj
  ; author
  ; title =
      Printf.sprintf
        "Turn failure escalated for judgment: %s from %s on %s"
        (Keeper_runtime_failure_route.judgment_class_label fj.fj_judgment)
        (Keeper_runtime_failure_route.judgment_provenance_label fj.fj_provenance)
        fj.fj_runtime_id
  ; preview = short_preview ~max_len:fusion_result_preview_max_len fj.fj_detail
  ; hearth = None
  ; post_kind = Board.System_post
  ; updated_at = arrived_at
  ; explicit_mention = false
  ; matched_targets = []
  ; self_commented = false
  ; new_external_since = 1
  ; latest_external_author = None
  ; latest_external_preview = None
  }

let apply_failure_judgment_guidance
      ~post_id
      ~judge_runtime_id
      ~guidance
      ~rationale
      events
  =
  let matching =
    List.filter
      (fun event ->
         event.event_kind = Failure_judgment
         && String.equal event.post_id post_id)
      events
  in
  match matching with
  | [] ->
    Error
      (Printf.sprintf
         "failure judgment guidance has no matching observation: %s"
         post_id)
  | _ :: _ :: _ ->
    Error
      (Printf.sprintf
         "failure judgment guidance has duplicate observations: %s"
         post_id)
  | [ _ ] ->
    let verdict =
      Keeper_failure_judgment_contract.Resume_with_guidance
        { guidance; rationale }
    in
    let preview =
      `Assoc
        [ "judge_runtime_id", `String judge_runtime_id
        ; "verdict", Keeper_failure_judgment_contract.to_yojson verdict
        ]
      |> Yojson.Safe.to_string
    in
    Ok
      (List.map
         (fun event ->
            if
              event.event_kind = Failure_judgment
              && String.equal event.post_id post_id
            then
              { event with
                title = "Independent failure judgment authorized a Keeper action turn"
              ; preview
              }
            else event)
         events)
;;

(* RFC-0315 P3 W0: surface a fresh goal assignment as actionable turn input.
   Author is the assigning actor (tool caller or "toml_reconcile"); the event
   records the assignment context and the keeper decides what to do with it. *)
let pending_board_event_of_goal_assignment
      ~meta:(_ : keeper_meta)
      ~(arrived_at : float)
      (ga : Keeper_event_queue.goal_assignment)
  : pending_board_event
  =
  let author = ga.ga_assigned_by in
  { event_kind = Goal_assigned
  ; post_id = Keeper_event_queue.goal_assignment_post_id ga
  ; author
  ; title = Printf.sprintf "Goal assigned: %s" ga.ga_goal_title
  ; preview =
      short_preview
        ~max_len:fusion_result_preview_max_len
        (Printf.sprintf
           "Goal %s is now in your active goals (assigned by %s). Review it \
            in Active Goals and either break it into a claimable task or \
            post your plan."
           ga.ga_goal_id
           ga.ga_assigned_by)
  ; hearth = None
  ; post_kind = Board.System_post
  ; updated_at = arrived_at
  ; explicit_mention = false
  ; matched_targets = []
  ; self_commented = false
  ; new_external_since = 1
  ; latest_external_author = Some ga.ga_assigned_by
  ; latest_external_preview = None
  }
;;

let pending_board_event_of_stimulus
      ~(meta : keeper_meta)
  (stimulus : Keeper_event_queue.stimulus)
  : pending_board_event option
  =
  match stimulus.payload with
  | Keeper_event_queue.Board_signal bs ->
    Some
      (pending_board_event_of_board_signal
         ~meta
         ~arrived_at:stimulus.arrived_at
         (Board_signal.board_signal_of_board_stimulus ~post_id:stimulus.post_id bs))
  | Keeper_event_queue.Board_attention attention ->
    Some
      (pending_board_event_of_board_signal
         ~meta
         ~arrived_at:stimulus.arrived_at
         (Board_signal.board_signal_of_board_stimulus
            ~post_id:stimulus.post_id
            attention.signal))
  | Keeper_event_queue.Fusion_completed fc ->
    Some (pending_board_event_of_fusion_completion ~meta ~arrived_at:stimulus.arrived_at fc)
  | Keeper_event_queue.Bg_completed c ->
    Some
      (pending_board_event_of_bg_job_completion ~meta ~arrived_at:stimulus.arrived_at c)
  | Keeper_event_queue.Schedule_due sw ->
    Some
      (pending_board_event_of_scheduled_wake
         ~meta
         ~post_id:stimulus.post_id
         ~arrived_at:stimulus.arrived_at
         sw)
  | Keeper_event_queue.Failure_judgment fj ->
    Some (pending_board_event_of_failure_judgment ~meta ~arrived_at:stimulus.arrived_at fj)
  | Keeper_event_queue.Goal_assigned ga ->
    Some
      (pending_board_event_of_goal_assignment
         ~meta
         ~arrived_at:stimulus.arrived_at
         ga)
  | Keeper_event_queue.Bootstrap
  | Keeper_event_queue.Connector_attention _
  | Keeper_event_queue.Hitl_resolved _ ->
    (* RFC-connector-ambient-attention-wake P1: not a board event. The wake
       fires via the trigger itself; [Hitl_resolved] carries no observation to
       inject — the keeper resumes on its own state once the approval is gone
       from the queue. *)
    None
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
    (match
       Keeper_board_attention_candidate.resume_pending
         ~base_path
         ~keeper_name:meta.name
     with
     | Ok _ -> ()
     | Error detail ->
       raise (Keeper_board_attention_candidate.Candidate_unavailable detail));
    let cursor_ts, cursor_post_id =
      Keeper_registry.get_board_cursor ~base_path meta.name
    in
    let base_cursor =
      if cursor_ts > 0.0
      then cursor_ts, cursor_post_id
      else Time_compat.now () -. bootstrap_window_sec, None
    in
    let posts = list_board_posts_after_cursor base_cursor in
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
                ; content = p.content
                ; hearth = p.hearth
                ; updated_at = Some p.updated_at
                }
              in
              (board_signal_match ~meta ~signal).explicit_mention)
           recent)
    in
    let rec consume_posts last_cursor acc = function
      | [] -> List.rev acc, last_cursor
      | (p : Board.post) :: rest ->
        let post_id = Board.Post_id.to_string p.id in
        let next_cursor = board_cursor_token_of_post p in
        let comment_status = check_self_comment_status ~self_ids ~post_id in
        (match comment_status with
         | Board_signal.Unavailable unavailable ->
           Board_signal.raise_unavailable unavailable
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
             ; content = p.content
             ; hearth = p.hearth
             ; updated_at = Some p.updated_at
             }
           in
           let matched = board_signal_match ~meta ~signal in
           if not matched.explicit_mention
           then (
             (match
                Keeper_board_attention_candidate.of_board_signal
                  ~meta
                  ~recorded_at:(Time_compat.now ())
                  signal
              with
              | Board_signal.Unavailable unavailable ->
                Board_signal.raise_unavailable unavailable
              | Board_signal.Available candidate ->
                (match
                   Keeper_board_attention_candidate.record_and_start
                     ~base_path
                     candidate
                 with
                 | Ok _ -> ()
                 | Error detail ->
                   raise
                     (Keeper_board_attention_candidate.Candidate_unavailable
                        detail)));
             consume_posts (Some next_cursor) acc rest)
           else
             consume_posts
               
               (Some next_cursor)
               ({ event_kind = Board_post_created
                ; post_id
                ; author = Board.Agent_id.to_string p.author
                ; title = p.title
                ; preview = short_preview ~max_len:80 p.content
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
               rest
         | Board_signal.Available (`New_external (count, ext_author, ext_preview)) ->
           (
             let signal : Board_dispatch.board_signal =
               { kind = Board_dispatch.Board_post_created
               ; post_id
               ; author = Board.Agent_id.to_string p.author
               ; title = p.title
               ; content = p.content
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
                ; preview = short_preview ~max_len:80 p.content
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
      match last_cursor with
      | Some (ts, post_id)
        when compare_board_cursor_token
               (ts, post_id)
               (fst base_cursor, Option.value ~default:"" (snd base_cursor))
             > 0 ->
        Keeper_reaction_ledger.record_board_cursor_ack
          ~base_path
          ~keeper_name:meta.name
          ~stimulus_id:(Keeper_reaction_ledger.board_stimulus_id ~post_id)
          ~cursor_ts:ts
          ~post_id:(Some post_id)
          ();
        Keeper_registry.set_board_cursor ~base_path meta.name ts (Some post_id)
      | Some (ts, post_id) ->
        Log.Keeper.debug
          "board cursor not advanced for %s: new=(%f, %s) not greater than base=(%f, %s)"
          meta.name
          ts
          post_id
          (fst base_cursor)
          (Option.value ~default:"" (snd base_cursor))
      | None ->
        if final_events <> []
        then (
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string ObservationQueryFailures)
            ~labels:[ ("operation", Runtime_observation_query_operation.(to_label Cursor_stale)) ]
            ();
          Log.Keeper.warn
            "board cursor not updated for %s despite %d events processed"
            meta.name
            (List.length final_events)));
    final_events, new_count, mention_count
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Board_signal.Board_unavailable unavailable as exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ObservationQueryFailures)
      ~labels:
        [ ( "operation"
          , Runtime_observation_query_operation.(to_label Board_events) )
        ]
      ();
    Log.Keeper.warn
      "board event collection retained cursor: %s"
      (Board_signal.unavailable_to_string unavailable);
    raise exn
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

let observe
      ~(pending_board_events : pending_board_event list option)
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
  : world_observation
  =
  let pending_messages = collect_message_scope ~config ~meta in
  let ( unclaimed_task_count
      , claimable_task_count
      , failed_task_count
      , pending_verification_count
      , backlog_updated_since_last_scheduled_autonomous )
    =
    read_backlog_counts ~config ~meta
  in
  let running_keeper_fiber_count = count_running_keeper_fibers ~config in
  let idle_seconds = compute_idle_seconds ~meta in
  let scheduled_automation =
    read_scheduled_automation_observation
      ~keeper_name:(Some meta.name)
      ~config
      ~now:(Time_compat.now ())
  in
  let pending_board_events =
    match pending_board_events with
    | Some events -> events
    | None ->
      let events, _board_new_count, _board_mention_count =
        collect_board_events ~base_path:config.base_path ~meta
      in
      events
  in
  { pending_messages
  ; pending_board_events
  ; idle_seconds
  ; active_goals = meta.active_goal_ids
  ; unclaimed_task_count
  ; claimable_task_count
  ; failed_task_count
  ; pending_verification_count
  ; scheduled_automation
  ; backlog_updated_since_last_scheduled_autonomous
  ; running_keeper_fiber_count
  ; connected_surfaces =
      Gate_surface.connected_surfaces_for_keeper ~keeper_name:meta.name
  }
;;

let observe_direct_keeper_msg ~(config : Workspace.config) ~(meta : keeper_meta)
  : world_observation
  =
  let ( unclaimed_task_count
      , claimable_task_count
      , failed_task_count
      , pending_verification_count
      , backlog_updated_since_last_scheduled_autonomous )
    =
    read_backlog_counts ~config ~meta
  in
  let scheduled_automation =
    read_scheduled_automation_observation
      ~keeper_name:(Some meta.name)
      ~config
      ~now:(Time_compat.now ())
  in
  { pending_messages = []
  ; pending_board_events = []
  ; idle_seconds = compute_idle_seconds ~meta
  ; active_goals = meta.active_goal_ids
  ; unclaimed_task_count
  ; claimable_task_count
  ; failed_task_count
  ; pending_verification_count
  ; scheduled_automation
  ; backlog_updated_since_last_scheduled_autonomous
  ; running_keeper_fiber_count = count_running_keeper_fibers ~config
  ; connected_surfaces =
      Gate_surface.connected_surfaces_for_keeper ~keeper_name:meta.name
  }
;;

(* Backlog facts are raw wake observations. Whether and how to act is a model
   decision after wake; local tool-name or mutation semantics must not suppress
   a signal before the Keeper can observe it. *)
let claimable_drives_wake claimable_task_count = claimable_task_count > 0
let failed_drives_wake failed_task_count = failed_task_count > 0
let verification_drives_wake pending_verification_count =
  pending_verification_count > 0

let actionable_signal_present (observation : world_observation) =
  observation.pending_messages <> []
  || observation.pending_board_events <> []
  || claimable_drives_wake observation.claimable_task_count
  || failed_drives_wake observation.failed_task_count
  || verification_drives_wake observation.pending_verification_count
  || observation.scheduled_automation.due_ready_count > 0
;;

let keeper_cycle_decision
      ?(reactive_wake = false)
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
  let _ = reactive_wake in
  let event_queue_reactive_triggers =
    List.map turn_reason_of_event_queue_trigger event_queue_triggers
  in
  let failure_judgment_control =
    List.exists
      (function
        | Failure_judgment_stimulus -> true
        | Bootstrap_stimulus
        | Scheduled_automation_stimulus
        | Connector_attention_stimulus
        | Hitl_resolved_stimulus ->
          false)
      event_queue_triggers
  in
  let reactive_triggers =
    [ (if Message_scope.has_kind Message_scope.Mention observation.pending_messages
       then Some Mention_pending
       else None)
    ; (if observation.pending_board_events <> [] then Some Board_event_pending else None)
    ; (if Message_scope.has_kind Message_scope.Scope observation.pending_messages
       then Some Scope_message_pending
       else None)
    ]
    |> List.filter_map Fun.id
    |> fun triggers -> triggers @ event_queue_reactive_triggers
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
  else if failure_judgment_control
  then
    (* The judge is the recovery control plane for the failure that may have
       disabled ordinary reactive execution. It must run to a typed verdict,
       but explicit Keeper pause remains authoritative operator intent. The
       owning lease is requeued while paused and resumes through this branch
       after the operator re-enables the Keeper. *)
    { should_run = true
    ; channel = Reactive
    ; verdict = Run { reasons = Failure_judgment_pending, [] }
    ; since_last_scheduled_autonomous = None
    }
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
          claimable_drives_wake observation.claimable_task_count
          || failed_drives_wake observation.failed_task_count
        in
        let has_actionable_schedule =
          observation.scheduled_automation.due_ready_count > 0
        in
        let is_bootstrap = since_last_scheduled_autonomous = max_int in
        let run_reasons =
          [ (if is_bootstrap then Some Never_started else None)
          ; (if has_actionable_tasks
             then
               Some
                 (Task_backlog
                    { unclaimed = observation.claimable_task_count
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

let should_run_keeper_cycle ~(meta : keeper_meta) (observation : world_observation) =
  (keeper_cycle_decision ~meta observation).should_run
;;
