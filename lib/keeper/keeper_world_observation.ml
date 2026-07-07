(** Keeper_world_observation — Structured world state for keeper cycles.

    Extracts and normalizes observation signals from workspace state, keeper meta,
    and context so the unified prompt and turn runner consume a single snapshot.

    @since Unified Keeper Loop *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_memory

(* RFC-0247: typed provenance of a board observation. Classified once at the
   world-observation boundary (see {!provenance_of}) from primitives that
   already exist on every pending_board_event ([post_kind], [author],
   [is_self_author]). The renderer uses {!should_quarantine} to route
   fleet-authored narrative into the observational-data envelope so a keeper
   cannot treat its own or a peer's board narrative as trusted instruction. *)
type observation_provenance =
  | Self_narrative
      (* this keeper's own prior post — highest confabulation risk *)
  | Peer_keeper
      (* another keeper's post, by typed keeper identity *)
  | Human_direct
      (* a human's post ([Board.Human_post]) — operator-direction-adjacent *)
  | Automation
      (* non-keeper automation: harness/qa/probe/smoke authors *)
  | Unknown
      (* classification drift (e.g. [Human_post] but author parses as a keeper
         id); defaults to the quarantine side — see {!should_quarantine} *)
[@@deriving show, eq]

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
  | Goal_verification_failed
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
  ; provenance : observation_provenance
      (* RFC-0247: computed at construction; drives trusted-vs-observational split *)
  }

type scheduled_automation_item =
  { schedule_id : string
  ; action : string
  ; status : string
  ; payload_kind : string option
  ; recurrence_summary : string
  ; risk_class : string
  ; due_at : float
  ; keeper_next_tool : string option
  ; keeper_next_action : string
  }

type scheduled_automation_observation =
  { active_count : int
  ; due_ready_count : int
  ; blocked_approval_count : int
  ; next_due_at : float option
  ; items : scheduled_automation_item list
  }

let empty_scheduled_automation_observation =
  { active_count = 0
  ; due_ready_count = 0
  ; blocked_approval_count = 0
  ; next_due_at = None
  ; items = []
  }
;;

type world_observation =
  { pending_mentions : (string * string) list
  ; pending_board_events : pending_board_event list
  ; pending_scope_messages : (string * string) list
  ; idle_seconds : int
  ; active_goals : string list
  ; continuity_summary : string
  ; context_ratio : float Lazy.t
  ; unclaimed_task_count : int
  ; claimable_task_count : int
  ; provider_capacity_blocked_task_count : int
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
  | No_progress_recovery_stimulus
  | Scheduled_automation_stimulus
  | Connector_attention_stimulus

type turn_reason = Keeper_world_observation_turn_types.turn_reason =
  | Mention_pending
  | Board_event_pending
  | Scope_message_pending
  | Bootstrap_stimulus_pending
  | No_progress_recovery_stimulus_pending
  | Connector_attention_pending
  | Scheduled_autonomous_turn
  | Scheduled_automation_due
  | Idle_cooldown_elapsed of
      { idle_sec : int
      ; cooldown : int
      }
  | Cooldown_elapsed
  | Task_backlog of
      { unclaimed : int
      ; failed : int
      }
  | Task_reactive_cooldown_elapsed
  | Never_started
  | Min_interval_elapsed

type skip_reason = Keeper_world_observation_turn_types.skip_reason =
  | Keeper_paused
  | Approval_pending
  | Scheduled_autonomous_disabled
  | Reactive_disabled
  | Provider_cooldown_pending of { remaining_sec : int }
  | Idle_gate_pending of { remaining_sec : int }
  | Cooldown_pending of { remaining_sec : int }
  | No_signal

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
  ; effective_cooldown : int option
  ; task_reactive_cooldown : int option
  ; idle_gate_sec : int option
  }

module Board_signal = Keeper_world_observation_board_signal

type board_signal_match = Board_signal.match_result =
  { explicit_mention : bool
  ; matched_targets : string list
  ; score : int
  }

module Message_scope = Keeper_world_observation_message_scope
module Inputs = Keeper_world_observation_inputs

let self_ids = Message_scope.self_ids
let is_self_author = Message_scope.is_self_author

(* RFC-0247: classify a board event's provenance from primitives already present
   at the boundary. Pure function of [post_kind] + [author] + the keeper's own
   identity set ([self_ids]). No new data plumbing — every pending_board_event
   already carries [post_kind] and [author]. *)
let provenance_of ~self_ids (post_kind : Board.post_kind) ~author : observation_provenance
  =
  if is_self_author ~self_ids author then Self_narrative
  else
    match post_kind with
    | Board.Human_post ->
      (* Drift guard: a Human_post whose author is nevertheless a typed keeper
         identity (e.g. a keeper posted via the dashboard where post_kind falls
         back to Human_post) is classification drift, not human direction —
         quarantine rather than trust. *)
      (match Keeper_identity.canonical_keeper_name_from_agent_name author with
       | Some _ -> Unknown
       | None -> Human_direct)
    | Board.Automation_post | Board.System_post ->
      (* Board.post_kind has no Keeper variant, so a peer keeper's narrative and
         a CI probe both land here as automation; the typed keeper-name check
         separates them. *)
      (match Keeper_identity.canonical_keeper_name_from_agent_name author with
       | Some _ -> Peer_keeper
       | None -> Automation)
;;

(* RFC-0247: trust tier. [Unknown] defaults to the quarantine side
   (defense-in-depth: an unclassifiable event is treated as untrusted fleet
   output, never as trusted operator direction). *)
let should_quarantine (p : observation_provenance) : bool =
  match p with
  | Self_narrative | Peer_keeper | Automation | Unknown -> true
  | Human_direct -> false
;;

let collect_message_scope = Message_scope.collect_message_scope
let read_backlog_counts = Inputs.read_backlog_counts
let count_running_keeper_fibers = Inputs.count_running_keeper_fibers
let compute_idle_seconds = Inputs.compute_idle_seconds
let read_context_ratio = Inputs.read_context_ratio
let board_signal_match = Board_signal.match_signal
let check_self_comment_status = Board_signal.check_self_comment_status
let board_signal_wake_reason = Board_signal.wake_reason
let compare_board_cursor_token = Board_signal.compare_cursor_token
let board_cursor_token_of_post = Board_signal.cursor_token_of_post
let list_board_posts_after_cursor = Board_signal.list_posts_after_cursor

module Continuity = Keeper_world_observation_continuity

let read_continuity_summary = Continuity.read_continuity_summary

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
  | (Pending_approval | Scheduled | Due), Some expires_at when expires_at <= now ->
    true
  | ( Pending_approval | Scheduled | Due | Running | Succeeded | Failed | Rejected
    | Cancelled | Expired )
    , _ ->
    false
;;

let schedule_effectively_active ~now (request : Schedule_domain.schedule_request) =
  (not (Schedule_domain.is_terminal request.status))
  && not (schedule_effectively_expired ~now request)
;;

let schedule_blocked_approval ~now state (request : Schedule_domain.schedule_request)
  =
  let open Schedule_domain in
  request.due_at <= now
  && (not (schedule_effectively_expired ~now request))
  && Schedule_domain.requires_separate_human_grant request
  &&
  match request.status with
  | Pending_approval -> true
  | Due -> not (Schedule_store.has_current_approved_grant state request)
  | Scheduled | Running | Succeeded | Failed | Rejected | Cancelled | Expired -> false
;;

let schedule_attention_item action (request : Schedule_domain.schedule_request) =
  { schedule_id = request.schedule_id
  ; action = Schedule_projection.attention_action_to_string action
  ; status = Schedule_domain.schedule_status_to_string request.status
  ; payload_kind = schedule_payload_kind request
  ; recurrence_summary = Schedule_domain.recurrence_summary request.recurrence
  ; risk_class = Schedule_domain.risk_class_to_string request.risk_class
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
    let blocked = schedules |> List.filter (schedule_blocked_approval ~now state) in
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
    let blocked_items =
      List.map
        (schedule_attention_item Schedule_projection.Approve_or_reject)
        blocked
    in
    { active_count
    ; due_ready_count = List.length due_ready
    ; blocked_approval_count = List.length blocked
    ; next_due_at = next_active_schedule_due_at ~now schedules
    ; items =
        due_items @ blocked_items
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
      ~continuity_summary
      ~(meta : keeper_meta)
      ~(arrived_at : float)
      (signal : Board_dispatch.board_signal)
  : pending_board_event
  =
  let self_ids = self_ids meta in
  let matched = board_signal_match ~continuity_summary ~meta ~signal in
  let post_snapshot =
    match Board_dispatch.get_post ~post_id:signal.post_id with
    | Ok post -> Some post
    | Error _ -> None
  in
  let title, preview, hearth, post_kind, updated_at =
    match post_snapshot with
    | Some (post : Board.post) ->
      ( post.title
      , short_preview ~max_len:80 post.content
      , post.hearth
      , post.post_kind
      , post.updated_at )
    | None ->
      ( signal.title
      , short_preview ~max_len:80 signal.content
      , signal.hearth
      , Board.Human_post
      , arrived_at )
  in
  let event_kind = pending_board_event_kind_of_signal signal in
  let self_commented, new_external_since, latest_external_author, latest_external_preview =
    match signal.kind with
    | Board_dispatch.Board_post_created -> false, 0, None, None
    | Board_dispatch.Board_comment_added ->
      (match check_self_comment_status ~self_ids ~post_id:signal.post_id with
       | `New_external (count, author, preview) -> true, count, Some author, Some preview
       | `No_new_external ->
         true, 0, Some signal.author, Some (short_preview ~max_len:60 signal.content)
       | `Never ->
         false, 1, Some signal.author, Some (short_preview ~max_len:60 signal.content))
    | Board_dispatch.Board_reaction_changed _ ->
      (match check_self_comment_status ~self_ids ~post_id:signal.post_id with
       | `Never -> false, 0, None, None
       | `No_new_external | `New_external _ -> true, 0, None, None)
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
  ; provenance = provenance_of ~self_ids post_kind ~author:signal.author
  }
;;

(* RFC-0266: fusion answers are the deliberation result the keeper requested,
   so the in-prompt preview is longer than a board headline preview (80). The
   full answer also persists in the sink's board post + chat lane. *)
let fusion_result_preview_max_len = 480

(* RFC-0266: turn a completed async fusion deliberation into actionable turn
   input. The sink already created a System_post board record (authored by this
   keeper) carrying the panel/judge detail; here we surface that result as a
   just-arrived [pending_board_event] so the woken turn's act judgment fires
   (actionable_signal_present only checks [pending_board_events <> []], not
   provenance/mention). Provenance is classified exactly as the keeper would see
   the real post on the normal board path — own author + System_post ->
   Self_narrative -> rendered inside the observational-data envelope (RFC-0247:
   a keeper reasons over the deliberation it requested, it is not trusted
   operator instruction). When the sink failed to create the board post
   ([board_post_id = ""]) we still deliver the answer under a synthetic
   [fusion-run:<id>] id so it is never silently dropped. *)
let pending_board_event_of_fusion_completion
      ~(meta : keeper_meta)
      ~(arrived_at : float)
      (fc : Keeper_event_queue.fusion_completion)
  : pending_board_event
  =
  let self_ids = self_ids meta in
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
  ; provenance = provenance_of ~self_ids Board.System_post ~author:meta.name
  }
;;

let bg_job_completion_message = function
  | Keeper_event_queue.Bg_ok output -> output
  | Keeper_event_queue.Bg_failed reason -> reason
;;

(* RFC-0290: mirror the async-fusion delivery contract for generic background
   jobs. A [Bg_completed] stimulus already means the background producer has
   decided the job is finished; converting it here keeps the queue consumer from
   silently dropping the result while still classifying the synthesized event as
   observational data, not operator direction. *)
let pending_board_event_of_bg_job_completion
      ~(meta : keeper_meta)
      ~(arrived_at : float)
      (c : Keeper_event_queue.bg_job_completion)
  : pending_board_event
  =
  let self_ids = self_ids meta in
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
  ; provenance = provenance_of ~self_ids Board.System_post ~author:meta.name
  }
;;

let scheduled_automation_actor = "scheduled_automation"

let pending_board_event_of_scheduled_wake
      ~(meta : keeper_meta)
      ~(arrived_at : float)
      (sw : Keeper_event_queue.scheduled_wake)
  : pending_board_event
  =
  let self_ids = self_ids meta in
  let title =
    match sw.title with
    | Some title -> title
    | None -> Printf.sprintf "Scheduled keeper wake due (schedule %s)" sw.schedule_id
  in
  { event_kind = Schedule_due
  ; post_id = Keeper_event_queue.schedule_due_post_id sw
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
  ; provenance = provenance_of ~self_ids Board.System_post ~author:scheduled_automation_actor
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
  ; provenance = Unknown
  }
;;

let goal_verification_failure_author =
  Tool_name.Goal_name.to_string Tool_name.Goal_name.Goal_verify
;;

let goal_verification_failure_preview
      (failure : Keeper_event_queue.goal_verification_failure)
  =
  let metric_line =
    match failure.metric, failure.target_value with
    | Some metric, Some target ->
      Printf.sprintf " metric=%s target=%s" metric target
    | Some metric, None -> Printf.sprintf " metric=%s" metric
    | None, Some target -> Printf.sprintf " target=%s" target
    | None, None -> ""
  in
  let note_line =
    match failure.note with
    | Some note when String.trim note <> "" -> " note=" ^ note
    | Some _ | None -> ""
  in
  let evidence_line =
    match failure.evidence_refs with
    | [] -> ""
    | refs -> " evidence_refs=" ^ String.concat "," refs
  in
  Printf.sprintf
    "Goal verification rejected by %s; goal returned to phase=%s.%s%s%s"
    failure.rejected_by
    failure.phase
    metric_line
    note_line
    evidence_line
;;

let pending_board_event_of_goal_verification_failure
      ~(meta : keeper_meta)
      ~(arrived_at : float)
      (failure : Keeper_event_queue.goal_verification_failure)
  : pending_board_event
  =
  let author = goal_verification_failure_author in
  let self_ids = self_ids meta in
  { event_kind = Goal_verification_failed
  ; post_id = Keeper_event_queue.goal_verification_failure_post_id failure
  ; author
  ; title = Printf.sprintf "Goal verification failed: %s" failure.goal_title
  ; preview =
      short_preview
        ~max_len:fusion_result_preview_max_len
        (goal_verification_failure_preview failure)
  ; hearth = None
  ; post_kind = Board.System_post
  ; updated_at = arrived_at
  ; explicit_mention = false
  ; matched_targets = []
  ; self_commented = false
  ; new_external_since = 1
  ; latest_external_author = Some failure.rejected_by
  ; latest_external_preview = failure.note
  ; provenance = provenance_of ~self_ids Board.System_post ~author
  }
;;

(* RFC-0313 W2: surface a deterministic turn failure as actionable turn input
   for an LLM-boundary verdict. Same provenance choice as
   [pending_board_event_of_fusion_completion]: own author + System_post ->
   Self_narrative -> rendered inside the observational-data envelope
   (RFC-0247) — a keeper reasons over its own failure, it is not trusted
   operator instruction. *)
let pending_board_event_of_failure_judgment
      ~(meta : keeper_meta)
      ~(arrived_at : float)
      (fj : Keeper_event_queue.failure_judgment)
  : pending_board_event
  =
  let self_ids = self_ids meta in
  let author = meta.name in
  { event_kind = Failure_judgment
  ; post_id = Keeper_event_queue.failure_judgment_post_id fj
  ; author
  ; title =
      Printf.sprintf
        "Turn failure escalated for judgment: %s on %s"
        (Keeper_runtime_failure_route.judgment_class_label fj.fj_judgment)
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
  ; provenance = provenance_of ~self_ids Board.System_post ~author
  }

(* RFC-0315 P3 W0: surface a fresh goal assignment as actionable turn input.
   Author is the assigning actor (tool caller or "toml_reconcile"), rendered
   as a System_post inside the observational-data envelope — the keeper
   decides what to do with the goal; the event only states the fact. *)
let pending_board_event_of_goal_assignment
      ~(meta : keeper_meta)
      ~(arrived_at : float)
      (ga : Keeper_event_queue.goal_assignment)
  : pending_board_event
  =
  let self_ids = self_ids meta in
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
  ; provenance = provenance_of ~self_ids Board.System_post ~author
  }
;;

let pending_board_event_of_stimulus
      ~continuity_summary
      ~(meta : keeper_meta)
  (stimulus : Keeper_event_queue.stimulus)
  : pending_board_event option
  =
  match stimulus.payload with
  | Keeper_event_queue.Board_signal bs ->
    Some
      (pending_board_event_of_board_signal
         ~continuity_summary
         ~meta
         ~arrived_at:stimulus.arrived_at
         (Board_signal.board_signal_of_board_stimulus ~post_id:stimulus.post_id bs))
  | Keeper_event_queue.Fusion_completed fc ->
    Some (pending_board_event_of_fusion_completion ~meta ~arrived_at:stimulus.arrived_at fc)
  | Keeper_event_queue.Bg_completed c ->
    Some
      (pending_board_event_of_bg_job_completion ~meta ~arrived_at:stimulus.arrived_at c)
  | Keeper_event_queue.Schedule_due sw ->
    Some (pending_board_event_of_scheduled_wake ~meta ~arrived_at:stimulus.arrived_at sw)
  | Keeper_event_queue.Goal_verification_failed failure ->
    Some
      (pending_board_event_of_goal_verification_failure
         ~meta
         ~arrived_at:stimulus.arrived_at
         failure)
  | Keeper_event_queue.Failure_judgment fj ->
    Some (pending_board_event_of_failure_judgment ~meta ~arrived_at:stimulus.arrived_at fj)
  | Keeper_event_queue.Goal_assigned ga ->
    Some
      (pending_board_event_of_goal_assignment
         ~meta
         ~arrived_at:stimulus.arrived_at
         ga)
  | Keeper_event_queue.Bootstrap
  | Keeper_event_queue.No_progress_recovery
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
      ~(continuity_summary : string)
      ~(meta : keeper_meta)
  : pending_board_event list * int * int
  =
  try
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
    let targets =
      if meta.mention_targets <> [] then meta.mention_targets else [ meta.name ]
    in
    let mention_count =
      List.length
        (List.filter
           (fun (p : Board.post) ->
              let haystack =
                String.lowercase_ascii (p.title ^ " " ^ p.body ^ " " ^ p.content)
              in
              List.exists
                (fun target ->
                   let needle = "@" ^ String.lowercase_ascii target in
                   String_util.contains_substring haystack needle)
                targets)
           recent)
    in
    let rec consume_posts last_cursor acc = function
      | [] -> List.rev acc, last_cursor
      | (p : Board.post) :: rest ->
        let post_id = Board.Post_id.to_string p.id in
        let next_cursor = board_cursor_token_of_post p in
        let comment_status = check_self_comment_status ~self_ids ~post_id in
        (match comment_status with
         | `No_new_external ->
           Log.Keeper.debug
             "board dedup: skipping post_id=%s (no new external since my comment)"
             post_id;
           consume_posts (Some next_cursor) acc rest
         | `Never ->
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
           let matched = board_signal_match ~continuity_summary ~meta ~signal in
           if not matched.explicit_mention
           then (
             Log.Keeper.debug
               "board dedup: skipping post_id=%s (no explicit mention and no prior \
                keeper participation)"
               post_id;
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
                ; provenance =
                    provenance_of ~self_ids p.post_kind
                      ~author:(Board.Agent_id.to_string p.author)
                }
                :: acc)
               rest
         | `New_external (count, ext_author, ext_preview) ->
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
             let matched = board_signal_match ~continuity_summary ~meta ~signal in
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
                ; provenance =
                    provenance_of ~self_ids p.post_kind
                      ~author:(Board.Agent_id.to_string p.author)
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
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ObservationQueryFailures)
      ~labels:[ ("operation", Runtime_observation_query_operation.(to_label Board_events)) ]
      ();
    Log.Keeper.warn "board event collection failed: %s" (Printexc.to_string exn);
    [], 0, 0
;;

let collect_board_events
      ~(base_path : string)
      ~(continuity_summary : string)
      ~(meta : keeper_meta)
  : pending_board_event list * int * int
  =
  collect_board_events_with_cursor_policy
    ~advance_cursor:true
    ~base_path
    ~continuity_summary
    ~meta
;;

let collect_board_events_without_advancing_cursor
      ~(base_path : string)
      ~(continuity_summary : string)
      ~(meta : keeper_meta)
  : pending_board_event list * int * int
  =
  collect_board_events_with_cursor_policy
    ~advance_cursor:false
    ~base_path
    ~continuity_summary
    ~meta
;;

include Keeper_world_observation_provider_cooldown

let observe
      ~(pending_board_events : pending_board_event list option)
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
  : world_observation
  =
  let pending_mentions, pending_scope_messages =
    collect_message_scope ~config ~meta
  in
  let ( unclaimed_task_count
      , claimable_task_count
      , failed_task_count
      , pending_verification_count
      , backlog_updated_since_last_scheduled_autonomous )
    =
    read_backlog_counts ~config ~meta
  in
  let provider_capacity_blocked_task_count =
    provider_capacity_blocked_task_count ~meta ~claimable_task_count ()
  in
  let running_keeper_fiber_count = count_running_keeper_fibers ~config in
  let idle_seconds = compute_idle_seconds ~meta in
  let scheduled_automation =
    read_scheduled_automation_observation
      ~keeper_name:(Some meta.name)
      ~config
      ~now:(Time_compat.now ())
  in
  (* Defer the checkpoint load (file read + Yojson parse + sanitize + O(n)
     tool-pair repair) out of [observe]. Most cycles are no-op skips where
     the gate decides not to run; on those, [context_ratio] is never forced
     so the checkpoint is not loaded. The post-gate Run-path consumers
     (build_prompt, append_decision_record) force it exactly once per run
     cycle. Verified the gate never reads it. *)
  let context_ratio = Lazy.from_fun (fun () -> read_context_ratio ~config ~meta) in
  let continuity_summary = read_continuity_summary ~config ~meta in
  let pending_board_events =
    match pending_board_events with
    | Some events -> events
    | None ->
      let events, _board_new_count, _board_mention_count =
        collect_board_events ~base_path:config.base_path ~meta ~continuity_summary
      in
      events
  in
  { pending_mentions
  ; pending_board_events
  ; pending_scope_messages
  ; idle_seconds
  ; active_goals = meta.active_goal_ids
  ; continuity_summary
  ; context_ratio
  ; unclaimed_task_count
  ; claimable_task_count
  ; provider_capacity_blocked_task_count
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
  let provider_capacity_blocked_task_count =
    provider_capacity_blocked_task_count ~meta ~claimable_task_count ()
  in
  let scheduled_automation =
    read_scheduled_automation_observation
      ~keeper_name:(Some meta.name)
      ~config
      ~now:(Time_compat.now ())
  in
  { pending_mentions = []
  ; pending_board_events = []
  ; pending_scope_messages = []
  ; idle_seconds = compute_idle_seconds ~meta
  ; active_goals = meta.active_goal_ids
  ; continuity_summary = read_continuity_summary ~config ~meta
  ; context_ratio = Lazy.from_fun (fun () -> read_context_ratio ~config ~meta)
  ; unclaimed_task_count
  ; claimable_task_count
  ; provider_capacity_blocked_task_count
  ; failed_task_count
  ; pending_verification_count
  ; scheduled_automation
  ; backlog_updated_since_last_scheduled_autonomous
  ; running_keeper_fiber_count = count_running_keeper_fibers ~config
  ; connected_surfaces =
      Gate_surface.connected_surfaces_for_keeper ~keeper_name:meta.name
  }
;;

(* RFC-keeper-proactive-wake-actionability-invariant: a task-backlog signal drives a proactive turn only if the
   affordance it grants can mutate task state (and thus clear the signal that
   surfaced it).  [failed_task] grants only [Task_audit], whose tools are
   read-only, so [failed_drives_wake] is structurally [false]: a keeper cannot
   clear an orphan it does not own, and waking it on that signal produces an
   unbounded no-op livelock (the failed_task incident, 2026-06-21..24).

   Routing every task signal through [Keeper_agent_tool_surface.affordance_can_mutate]
   (rather than hand-deleting failed_task at each call site) keeps the
   policy<->affordance coupling a single source of truth: a future signal whose
   affordance is read-only is excluded automatically, and its consistency with
   [tools_for_affordance] is pinned by
   test_advisory_only_affordance_never_drives_wake. *)
let claimable_drives_wake claimable_task_count =
  claimable_task_count > 0
  && Keeper_agent_tool_surface.affordance_can_mutate
       Keeper_agent_tool_surface.Task_claim

let failed_drives_wake failed_task_count =
  failed_task_count > 0
  && Keeper_agent_tool_surface.affordance_can_mutate
       Keeper_agent_tool_surface.Task_audit

let verification_drives_wake pending_verification_count =
  pending_verification_count > 0
  && Keeper_agent_tool_surface.affordance_can_mutate
       Keeper_agent_tool_surface.Task_verify

let durable_signal_present
      ~pending_board_events
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
  : bool
  =
  let pending_mentions, pending_scope_messages =
    collect_message_scope ~config ~meta
  in
  let ( _unclaimed_task_count
      , claimable_task_count
      , failed_task_count
      , pending_verification_count
      , _backlog_updated_since_last_scheduled_autonomous )
    =
    read_backlog_counts ~config ~meta
  in
  let pending_board_events =
    match pending_board_events with
    | Some events -> events
    | None ->
      let events, _board_new_count, _board_mention_count =
        collect_board_events_without_advancing_cursor
          ~base_path:config.base_path
          ~meta
          ~continuity_summary:meta.continuity_summary
      in
      events
  in
  let scheduled_automation =
    read_scheduled_automation_observation
      ~keeper_name:(Some meta.name)
      ~config
      ~now:(Time_compat.now ())
  in
  pending_mentions <> []
  || pending_board_events <> []
  || pending_scope_messages <> []
  || claimable_drives_wake claimable_task_count
  || failed_drives_wake failed_task_count
  || verification_drives_wake pending_verification_count
  || scheduled_automation.due_ready_count > 0
  || scheduled_automation.blocked_approval_count > 0
;;

let actionable_signal_present (observation : world_observation) =
  observation.pending_mentions <> []
  || observation.pending_board_events <> []
  || observation.pending_scope_messages <> []
  || claimable_drives_wake observation.claimable_task_count
  || failed_drives_wake observation.failed_task_count
  || verification_drives_wake observation.pending_verification_count
  || observation.scheduled_automation.due_ready_count > 0
  || observation.scheduled_automation.blocked_approval_count > 0
;;

let proactive_work_signal_present ~(meta : keeper_meta) (observation : world_observation) =
  let task_backlog_signal =
    claimable_drives_wake observation.claimable_task_count
     || failed_drives_wake observation.failed_task_count
     || verification_drives_wake observation.pending_verification_count
  in
  observation.pending_mentions <> []
  || observation.pending_board_events <> []
  || observation.pending_scope_messages <> []
  || task_backlog_signal
  || observation.scheduled_automation.due_ready_count > 0
  || observation.scheduled_automation.blocked_approval_count > 0
  || Option.is_some meta.current_task_id
;;

(** Compute effective scheduled autonomous cooldown with idle decay.
    After extended idle (> base cooldown), halve the cooldown each
    additional period, down to a configurable floor.  This prevents
    permanent silence when no external events arrive.

    Board health no longer adjusts this cooldown: the curation
    health_score was an LLM-submitted projection with no rubric, and
    gating keeper polling on it violated the projection-only contract
    declared in [Board_curation].  Removed in board-karma-v2 (S1). *)
let effective_scheduled_autonomous_cooldown
      ~(base_cooldown : int)
      ~(since_last : int)
      ?(consecutive_noop_count = 0)
      ()
  : int
  =
  (* Noop backoff: consecutive observation-only cycles multiply the base
     cooldown by [2^shift], where [shift] is a named runtime policy. This
     prevents token waste when the keeper repeatedly reads board_list without
     acting, without burying the cap as a local heuristic. *)
  let noop_backoff_max_shift = Keeper_config.keeper_proactive_noop_backoff_max_shift () in
  let noop_multiplier =
    if consecutive_noop_count <= 0
    then 1
    else 1 lsl min consecutive_noop_count noop_backoff_max_shift
  in
  let effective_base = base_cooldown * noop_multiplier in
  let min_cooldown = Keeper_config.keeper_proactive_min_cooldown_sec () in
  (* Floor must not exceed the effective base cooldown — otherwise decay would
     paradoxically increase a short cooldown. *)
  let floor = min min_cooldown effective_base in
  if since_last <= effective_base
  then effective_base
  else (
    let decay_periods = (since_last - effective_base) / max 1 effective_base in
    let capped_periods =
      min decay_periods (Keeper_config.keeper_proactive_idle_decay_max_periods ())
    in
    let factor = 1.0 /. Float.pow 2.0 (float_of_int capped_periods) in
    max floor (int_of_float (Float.round (float_of_int effective_base *. factor))))
;;

let keeper_cycle_decision
      ?(provider_cooldown_remaining_sec = provider_cooldown_remaining_sec_for_runtime)
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
  let event_queue_reactive_triggers =
    List.map turn_reason_of_event_queue_trigger event_queue_triggers
  in
  let reactive_triggers =
    [ (if observation.pending_mentions <> [] then Some Mention_pending else None)
    ; (if observation.pending_board_events <> [] then Some Board_event_pending else None)
    ; (if observation.pending_scope_messages <> []
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
    ; effective_cooldown = None
    ; task_reactive_cooldown = None
    ; idle_gate_sec = None
    }
  in
  if meta.paused
  then blocked Keeper_paused
  else if Keeper_approval_queue.has_pending_for_keeper ~keeper_name:meta.name
  then blocked Approval_pending
  else (
    let scheduled_autonomous_decision () =
      let since_last_scheduled_autonomous =
        if meta.runtime.proactive_rt.last_ts <= 0.0
        then max_int
        else
          int_of_float (max 0.0 (Time_compat.now () -. meta.runtime.proactive_rt.last_ts))
      in
      let idle_gate_sec = meta.proactive.idle_sec in
      if not proactive_gate_enabled
      then
        { should_run = false
        ; channel = Scheduled_autonomous
        ; verdict = Skip { reasons = Scheduled_autonomous_disabled, [] }
        ; since_last_scheduled_autonomous = Some since_last_scheduled_autonomous
        ; effective_cooldown = None
        ; task_reactive_cooldown = None
        ; idle_gate_sec = Some idle_gate_sec
        }
      else (
        let effective_cooldown =
          effective_scheduled_autonomous_cooldown
            ~base_cooldown:meta.proactive.cooldown_sec
            ~since_last:since_last_scheduled_autonomous
            ~consecutive_noop_count:meta.runtime.proactive_rt.consecutive_noop_count
            ()
        in
        let task_cooldown_divisor =
          Keeper_config.keeper_proactive_task_cooldown_divisor ()
        in
        let task_cooldown_floor =
          Keeper_config.keeper_proactive_task_min_cooldown_sec ()
        in
        let task_reactive_cooldown =
          max task_cooldown_floor (effective_cooldown / max 1 task_cooldown_divisor)
        in
        (* RFC-keeper-proactive-wake-actionability-invariant: failed_task no longer contributes — Task_audit is
           advisory-only, so an orphan this keeper cannot clear must not drive
           the backlog cadence.  claimable (Task_claim) remains actionable. *)
        let has_actionable_tasks =
          claimable_drives_wake observation.claimable_task_count
          || failed_drives_wake observation.failed_task_count
        in
        let has_actionable_schedule =
          observation.scheduled_automation.due_ready_count > 0
          || observation.scheduled_automation.blocked_approval_count > 0
        in
        let idle_gate_elapsed = observation.idle_seconds >= idle_gate_sec in
        let cooldown_elapsed = since_last_scheduled_autonomous >= effective_cooldown in
        let backlog_elapsed =
          has_actionable_tasks
          && since_last_scheduled_autonomous >= task_reactive_cooldown
        in
        let schedule_elapsed =
          has_actionable_schedule
          && since_last_scheduled_autonomous >= task_reactive_cooldown
        in
        let backlog_fresh =
          has_actionable_tasks
          && observation.backlog_updated_since_last_scheduled_autonomous
        in
        let proactive_work_ready = proactive_work_signal_present ~meta observation in
        (* Phase 1 — Bootstrap bypass: keeper has never completed a scheduled
           autonomous turn (last_ts <= 0.0, so since_last = max_int). Fire
           immediately without requiring work signals or time gates, so a
           fresh keeper always gets at least one warm-up turn regardless of
           observable backlog state.  This breaks the "no signal → no turn →
           no signal" bootstrap deadlock. *)
        let is_bootstrap = since_last_scheduled_autonomous = max_int in
        (* Phase 2 — Minimum proactive cadence rate-limit: tracks whether the
           minimum interval has elapsed since the last scheduled-autonomous
           turn.  Default: 900s (15 min).  Controlled by
           MASC_KEEPER_PROACTIVE_MIN_INTERVAL_SEC
           / keeper.proactive.min_interval_sec.
           RFC-0303 Phase 2: this no longer fires a housekeeping turn on its
           own with no work signals.  It is stimulus-gated behind
           [proactive_work_ready] at the should_run site below, so it only
           rate-limits cadence turns when the keeper already has an
           opportunity.  Liveness under genuine silence is preserved by the
           bootstrap turn and by external Reactive-channel wakes, not by this
           blind cadence. *)
        let proactive_min_interval_sec =
          Keeper_config.keeper_proactive_min_interval_sec ()
        in
        let min_interval_elapsed =
          (* Exclude the bootstrap case: when is_bootstrap is true, the bootstrap
             bypass already fires the turn and emits Never_started.  Using
             min_interval_elapsed here would also set Min_interval_elapsed on a
             bootstrap turn, which is misleading — the two paths are mutually
             exclusive by design. *)
          (not is_bootstrap)
          && since_last_scheduled_autonomous >= proactive_min_interval_sec
        in
        (* Backlog bypass: when actionable tasks exist and task_reactive_cooldown
           has elapsed, skip the idle_gate check. task_reactive_cooldown is
           already a (shorter) subdivision of idle_gate; requiring idle_gate_elapsed
           on top defeats its purpose. Without this bypass, keepers ignore
           unclaimed work for idle_gate seconds even when the backlog signal
           is ready to fire. Ref: #7226 claim-first + idle_gate observation. *)
        (* Reactive-wake gate (thundering-herd fix). When this evaluation runs
           because an external broadcast woke the keeper early ([reactive_wake]),
           the GLOBAL task backlog must not, on its own, drive a turn: otherwise
           a single task release/add broadcasts to every keeper and all of them
           run a full LLM turn against the shared (claimable-by-anyone) pool — N
           turns for work at most one keeper can claim. Global backlog is instead
           picked up on the keeper's own cadence (sleep Timeout) and by the
           supervisor sweep. Per-keeper signals (mention/board/scope) are handled
           by the Reactive channel above and are unaffected. Time-based liveness
           reasons key on the keeper's own clock, so they stay ungated BY THIS
           reactive-wake check. Note this is a separate axis from the RFC-0303
           Phase 2 gate below: [min_interval] and [idle_gate+cooldown] are
           additionally stimulus-gated behind [proactive_work_ready], so they
           cannot independently drive a scheduled-autonomous run. Only
           [bootstrap] and a due schedule remain fully self-driving stimuli. *)
        let backlog_drives_turn =
          (not reactive_wake) && (backlog_fresh || backlog_elapsed)
        in
        let schedule_drives_turn = (not reactive_wake) && schedule_elapsed in
        (* RFC-0303 Phase 2: stimulus-gate the self-cadence wake.
           [min_interval_elapsed] no longer drives a turn ON ITS OWN — a blind
           cadence turn
           with no work signal is what manufactured the "passive" turns the
           no-progress stack then chased (detect -> pause -> tombstone). It is
           now a rate-limit INSIDE the [proactive_work_ready] guard: a keeper
           spends a cadence turn only when it actually has an opportunity (a
           claimed task, mentions, board/scope activity, or task backlog). With
           no opportunity the keeper stays idle (verdict [No_signal]) instead of
           spending a passive turn. Bootstrap (first warm-up turn) and a due
           schedule remain ungated — each is itself the stimulus. External
           signals still wake the keeper via the Reactive channel, so gating the
           blind cadence cannot cause a deadlock. *)
        let should_run =
          is_bootstrap
          || schedule_drives_turn
          || (proactive_work_ready
              && (min_interval_elapsed
                  || backlog_drives_turn
                  || (idle_gate_elapsed && cooldown_elapsed)))
        in
        let runtime_id = runtime_id_of_meta meta in
        let provider_cooldown_remaining_sec =
          if should_run
          then
            provider_cooldown_remaining_sec
              ~keeper_name:meta.name
              ~runtime_id:(runtime_id)
          else None
        in
        let provider_cooldown_fail_open =
          match provider_cooldown_remaining_sec with
          | Some _ ->
            fallback_runtime_for_provider_cooldown
              ~base_runtime:runtime_id
              ~effective_runtime:runtime_id
          | None -> None
        in
        let verdict =
          if
            Option.is_some provider_cooldown_remaining_sec
            && Option.is_none provider_cooldown_fail_open
          then (
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string ProviderCooldownSkip)
              ~labels:
                [ ("keeper", meta.name)
                ; ("from_runtime", runtime_id)
                ; ("to_runtime", "skipped")
                ]
              ();
            Skip
              { reasons =
                  ( Provider_cooldown_pending
                      { remaining_sec =
                          Option.value ~default:0 provider_cooldown_remaining_sec
                      }
                  , [] )
              })
          else if should_run
          then (
            let run_reasons =
              [ Some Scheduled_autonomous_turn
              ; (if is_bootstrap then Some Never_started else None)
              ; (if min_interval_elapsed then Some Min_interval_elapsed else None)
              ; (if idle_gate_elapsed
                 then
                   Some
                     (Idle_cooldown_elapsed
                        { idle_sec = observation.idle_seconds
                        ; cooldown = effective_cooldown
                        })
                 else None)
              ; (if cooldown_elapsed then Some Cooldown_elapsed else None)
              ; (if has_actionable_tasks
                 then
                   Some
                     (Task_backlog
                        { unclaimed = observation.claimable_task_count
                        ; failed = observation.failed_task_count
                        })
                 else None)
              ; (if has_actionable_schedule then Some Scheduled_automation_due else None)
              ; (if backlog_fresh || backlog_elapsed || schedule_elapsed
                 then Some Task_reactive_cooldown_elapsed
                 else None)
              ]
              |> List.filter_map Fun.id
            in
            (* NEL: scheduled autonomous runs always emit the synthetic
               Scheduled_autonomous_turn tag first, so the reason list
               cannot be empty even if future edits change the payload list. *)
            match run_reasons with
            | first :: rest -> Run { reasons = first, rest }
            | [] ->
              (* Structurally unreachable: the synthetic Scheduled_autonomous_turn
                   tag is always added first, so the list is never empty.
                   Defensive: log warning and fall through to skip so that
                   should_run (derived below) stays consistent with verdict. *)
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string ObservationQueryFailures)
                ~labels:
                  [ ("operation", Runtime_observation_query_operation.(to_label Empty_run_reasons))
                  ]
                ();
              Log.Keeper.warn "unreachable: should_run=true but run_reasons is empty";
              Skip { reasons = No_signal, [] })
          else (
            let skip_reasons =
              [ (if not proactive_work_ready then Some No_signal else None)
              ; (if not idle_gate_elapsed
                 then
                   Some
                     (Idle_gate_pending
                        { remaining_sec = idle_gate_sec - observation.idle_seconds })
                 else None)
              ; (if idle_gate_elapsed && not cooldown_elapsed
                 then
                   Some
                     (Cooldown_pending
                        { remaining_sec =
                            effective_cooldown - since_last_scheduled_autonomous
                        })
                 else None)
              ]
              |> List.filter_map Fun.id
            in
            match skip_reasons with
            | first :: rest -> Skip { reasons = first, rest }
            | [] -> Skip { reasons = No_signal, [] })
        in
        (* Derive should_run from verdict to guarantee consistency.
           The earlier [let should_run] is an intent signal; verdict is
           authoritative after the reason-list construction. *)
        let should_run =
          match verdict with
          | Run _ -> true
          | Skip _ -> false
        in
        { should_run
        ; channel = Scheduled_autonomous
        ; verdict
        ; since_last_scheduled_autonomous = Some since_last_scheduled_autonomous
        ; effective_cooldown = Some effective_cooldown
        ; task_reactive_cooldown = Some task_reactive_cooldown
        ; idle_gate_sec = Some idle_gate_sec
        })
    in
    match reactive_triggers with
    | first :: rest when reactive_gate_enabled ->
      { should_run = true
      ; channel = Reactive
      ; verdict = Run { reasons = first, rest }
      ; since_last_scheduled_autonomous = None
      ; effective_cooldown = None
      ; task_reactive_cooldown = None
      ; idle_gate_sec = None
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
