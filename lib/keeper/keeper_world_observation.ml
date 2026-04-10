(** Keeper_world_observation — Structured world state for unified keeper turns.

    Extracts and normalizes observation signals from room state, keeper meta,
    and context so the unified prompt and turn runner consume a single snapshot.

    @since Unified Keeper Loop *)

open Keeper_types
open Keeper_memory
open Keeper_exec_context

type pending_board_event = {
  post_id : string;
  author : string;
  title : string;
  preview : string;
  hearth : string option;
  post_kind : Board.post_kind;
  updated_at : float;
  explicit_mention : bool;
  matched_targets : string list;
  self_commented : bool;
  new_external_since : int;
  latest_external_author : string option;
  latest_external_preview : string option;
}

type world_observation = {
  pending_mentions : (string * string) list;
  pending_board_events : pending_board_event list;
  pending_scope_messages : (string * string) list;
  message_cursor_updates : (string * int) list;
  idle_seconds : int;
  active_goals : string list;
  continuity_summary : string;
  worktree_change_summary : string option;
  context_ratio : float;
  economic_pressure : Agent_economy.pressure_mode;
  unclaimed_task_count : int;
  failed_task_count : int;
  active_agent_count : int;
  room_signal_interpretation : Meta_cognition.interpretation option;
  room_signal_digest_ref : Meta_cognition.digest_ref option;
  last_turn_budget : (int * int) option;
  last_tools_used : string list;
    (** Tools used in the previous cycle. Empty on first cycle.
        Used by the unified prompt to generate data-driven anti-repetition hints. *)
  work_discovery_due : bool;
  behavioral_stats : Keeper_telemetry_feedback.behavioral_stats option;
}

type unified_turn_channel =
  | Reactive
  | Scheduled_autonomous

type turn_reason =
  | Mention_pending
  | Board_event_pending
  | Scope_message_pending
  | Scheduled_autonomous_turn
  | Idle_cooldown_elapsed of { idle_sec : int; cooldown : int }
  | Cooldown_elapsed
  | Task_backlog of { unclaimed : int; failed : int }
  | Task_reactive_cooldown_elapsed
  | Never_started

type skip_reason =
  | Scheduled_autonomous_disabled
  | Idle_gate_pending of { remaining_sec : int }
  | Cooldown_pending of { remaining_sec : int }
  | No_signal

type turn_verdict =
  | Run of { reasons : turn_reason * turn_reason list }
  | Skip of { reasons : skip_reason * skip_reason list }

let turn_reason_to_string = function
  | Mention_pending -> "pending_mentions"
  | Board_event_pending -> "pending_board_events"
  | Scope_message_pending -> "pending_scope_messages"
  | Scheduled_autonomous_turn -> "scheduled_autonomous_turn"
  | Idle_cooldown_elapsed _ -> "idle_gate_elapsed"
  | Cooldown_elapsed -> "cooldown_elapsed"
  | Task_backlog _ -> "actionable_backlog"
  | Task_reactive_cooldown_elapsed -> "task_reactive_cooldown_elapsed"
  | Never_started -> "never_started"

let skip_reason_to_string = function
  | Scheduled_autonomous_disabled -> "scheduled_autonomous_disabled"
  | Idle_gate_pending _ -> "idle_gate_wait"
  | Cooldown_pending _ -> "cooldown_wait"
  | No_signal -> "no_signal"

let channel_to_string = function
  | Reactive -> "reactive"
  | Scheduled_autonomous -> "scheduled_autonomous"

let turn_reason_legacy_tokens = function
  | Task_backlog { unclaimed; failed } ->
      [ Some "actionable_backlog";
        (if unclaimed > 0 then Some "unclaimed_tasks" else None);
        (if failed > 0 then Some "failed_tasks" else None) ]
      |> List.filter_map Fun.id
  | reason -> [ turn_reason_to_string reason ]

let skip_reason_legacy_tokens = function
  | Scheduled_autonomous_disabled -> [ "scheduled_autonomous_disabled" ]
  | Idle_gate_pending _ -> [ "scheduled_autonomous_turn"; "idle_gate_wait" ]
  | Cooldown_pending _ -> [ "scheduled_autonomous_turn"; "idle_gate_elapsed" ]
  | No_signal -> [ "scheduled_autonomous_turn"; "idle_gate_elapsed" ]

let verdict_reasons_to_strings = function
  | Run { reasons = (first, rest) } ->
      List.concat_map turn_reason_legacy_tokens (first :: rest)
  | Skip { reasons = (first, rest) } ->
      List.concat_map skip_reason_legacy_tokens (first :: rest)
type unified_turn_decision = {
  should_run : bool;
  channel : unified_turn_channel;
  verdict : turn_verdict;
  since_last_scheduled_autonomous : int option;
  effective_cooldown : int option;
  task_reactive_cooldown : int option;
  idle_gate_sec : int option;
}

type board_signal_match = {
  explicit_mention : bool;
  matched_targets : string list;
  score : int;
}

let scope_message_feed_enabled (meta : keeper_meta) : bool =
  match Keeper_contract.scope_kind_of_string meta.scope_kind with
  | Keeper_contract.Global -> true
  | Keeper_contract.Local -> false

let message_feed_targets (meta : keeper_meta) =
  if meta.mention_targets <> [] then meta.mention_targets else [ meta.name ]

let collect_message_scope ~(config : Room.config) ~(meta : keeper_meta) :
    ((string * string) list * (string * string) list * (string * int) list) =
  let targets = message_feed_targets meta in
  let broad_scope = scope_message_feed_enabled meta in
  let self_tokens =
    [ meta.name; meta.agent_name ]
    |> List.map (fun value -> String.lowercase_ascii (String.trim value))
  in
  let batch_limit = Keeper_config.keeper_batch_limit () in
  let rec consume_room_messages remaining last_processed mentions scope_messages =
    function
    | [] -> (`Done, remaining, last_processed, List.rev mentions, List.rev scope_messages)
    | (msg : Types.message) :: rest ->
        let author =
          String.lowercase_ascii (String.trim msg.from_agent)
        in
        if author = "" || List.mem author self_tokens then
          consume_room_messages remaining msg.seq mentions scope_messages rest
        else if exact_direct_mention_present ~targets msg.content then
          if remaining <= 0 then
            (`Saturated, remaining, last_processed, List.rev mentions, List.rev scope_messages)
          else
            consume_room_messages
              (remaining - 1)
              msg.seq
              ((msg.from_agent, msg.content) :: mentions)
              scope_messages
              rest
        else if broad_scope then
          if remaining <= 0 then
            (`Saturated, remaining, last_processed, List.rev mentions, List.rev scope_messages)
          else
            consume_room_messages
              (remaining - 1)
              msg.seq
              mentions
              ((msg.from_agent, msg.content) :: scope_messages)
              rest
        else
          consume_room_messages remaining msg.seq mentions scope_messages rest
  in
  let rec consume_rooms remaining mentions_acc scope_acc cursor_acc = function
    | [] -> (mentions_acc, scope_acc, List.rev cursor_acc)
    | _ when remaining <= 0 -> (mentions_acc, scope_acc, List.rev cursor_acc)
    | room_id :: rest ->
        let since_seq = room_cursor_for meta room_id in
        let messages =
          try
            Room.get_all_messages_raw config ~since_seq
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | _ -> []
        in
        let status, remaining, last_processed, room_mentions, room_scope_messages =
          consume_room_messages remaining since_seq [] [] messages
        in
        let cursor_acc =
          if last_processed > since_seq then (room_id, last_processed) :: cursor_acc
          else cursor_acc
        in
        let mentions_acc = mentions_acc @ room_mentions in
        let scope_acc = scope_acc @ room_scope_messages in
        match status with
        | `Done -> consume_rooms remaining mentions_acc scope_acc cursor_acc rest
        | `Saturated -> (mentions_acc, scope_acc, List.rev cursor_acc)
  in
  consume_rooms batch_limit [] [] [] meta.joined_room_ids

let apply_message_cursor_updates (meta : keeper_meta)
    (updates : (string * int) list) : keeper_meta =
  List.fold_left
    (fun acc (room_id, seq) -> set_room_cursor acc room_id seq)
    meta updates

(** Read room backlog counts. *)
let read_backlog_counts ~(config : Room.config) : int * int =
  try
    let backlog = Room.read_backlog config in
    let unclaimed =
      List.length
        (List.filter
           (fun (t : Types.task) -> t.task_status = Types.Todo)
           backlog.tasks)
    in
    let failed =
      List.length
        (List.filter
           (fun (t : Types.task) ->
             match t.task_status with Types.Cancelled _ -> true | _ -> false)
           backlog.tasks)
    in
    (unclaimed, failed)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> (0, 0)

(** Count active agents in room. *)
let count_active_agents ~(config : Room.config) : int =
  try List.length (Room.get_agents_raw config)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> 0

(** Compute idle seconds from keeper timestamps. *)
let compute_idle_seconds ~(meta : keeper_meta) : int =
  let now_ts = Time_compat.now () in
  let created_ts =
    Resilience.Time.parse_iso8601_opt meta.created_at
    |> Option.value ~default:0.0
  in
  let activity_ts =
    List.fold_left max created_ts
      [
        meta.runtime.proactive_rt.last_ts;
      ]
  in
  if activity_ts <= 0.0 then 0
  else int_of_float (max 0.0 (now_ts -. activity_ts))

let board_post_id_string (post : Board.post) =
  Board.Post_id.to_string post.id

let compare_board_cursor_token (ts_a, post_id_a) (ts_b, post_id_b) =
  let cmp = Float.compare ts_a ts_b in
  if cmp <> 0 then cmp else String.compare post_id_a post_id_b

let board_cursor_token_of_post (post : Board.post) =
  (post.updated_at, board_post_id_string post)

let list_board_posts_after_cursor (cursor_ts, cursor_post_id) =
  let cursor_post_id = Option.value ~default:"" cursor_post_id in
  let is_after_cursor post =
    compare_board_cursor_token
      (board_cursor_token_of_post post)
      (cursor_ts, cursor_post_id)
    > 0
  in
  match Board_dispatch.backend () with
  | Board_dispatch.Jsonl store ->
      Board.search_posts store ~predicate:(fun _ -> true) ~limit:max_int
      |> List.filter is_after_cursor
      |> List.sort (fun (a : Board.post) (b : Board.post) ->
           compare_board_cursor_token
             (board_cursor_token_of_post a)
             (board_cursor_token_of_post b))
  | Board_dispatch.Postgres t ->
      Board_pg.list_posts_updated_since t ~since_ts:cursor_ts
      |> List.filter is_after_cursor

let board_signal_text (signal : Board_dispatch.keeper_board_signal) =
  String.concat "\n"
    (List.filter (fun part -> String.trim part <> "")
       [
         signal.title;
         signal.content;
         (match signal.hearth with Some hearth -> hearth | None -> "");
       ])

let board_signal_match
    ~continuity_summary:(_ : string)
    ~(meta : keeper_meta)
    ~(signal : Board_dispatch.keeper_board_signal) : board_signal_match =
  let author = String.lowercase_ascii (String.trim signal.author) in
  let self_tokens =
    [ meta.name; meta.agent_name ]
    |> List.map (fun value -> String.lowercase_ascii (String.trim value))
  in
  if List.mem author self_tokens then
    { explicit_mention = false; matched_targets = []; score = 0 }
  else
    let targets =
      if meta.mention_targets <> [] then meta.mention_targets else [ meta.name ]
    in
    let haystack = String.lowercase_ascii (board_signal_text signal) in
    let matched_targets =
      targets
      |> List.filter (fun target ->
             let needle = "@" ^ String.lowercase_ascii (String.trim target) in
             needle <> "@"
             && Re.execp (Re.str needle |> Re.compile) haystack)
    in
    if matched_targets <> [] then
      { explicit_mention = true; matched_targets; score = 100 }
    else { explicit_mention = false; matched_targets = []; score = 0 }

(** Read context ratio from checkpoint if available. *)
let read_context_ratio ~(config : Room.config) ~(meta : keeper_meta) : float =
  try
    let cascade_models =
      Oas_model_resolve.models_of_cascade_name meta.cascade_name
    in
    let primary_max_context =
      Oas_model_resolve.resolve_max_cascade_context cascade_models
    in
    let base_dir = session_base_dir config in
    let _session, ctx_opt =
      load_context_from_checkpoint
        ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages
        ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
        ~primary_model_max_tokens:primary_max_context ~base_dir
    in
    match ctx_opt with
    | Some c -> Keeper_exec_context.context_ratio c
    | None -> 0.0
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> 0.0

(** Read continuity summary from checkpoint messages or meta fallback. *)
let read_continuity_summary ~(config : Room.config) ~(meta : keeper_meta)
    : string =
  try
    let cascade_models =
      Oas_model_resolve.models_of_cascade_name meta.cascade_name
    in
    let primary_max_context =
      Oas_model_resolve.resolve_max_cascade_context cascade_models
    in
    let base_dir = session_base_dir config in
    let _session, ctx_opt =
      load_context_from_checkpoint
        ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages
        ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
        ~primary_model_max_tokens:primary_max_context ~base_dir
    in
    match ctx_opt with
    | Some c ->
        let snapshot = latest_state_snapshot_from_messages c.messages in
        (match snapshot with
         | Some s -> keeper_state_snapshot_to_summary_text s
         | None ->
             let trimmed = String.trim meta.continuity_summary in
             if trimmed = "" then "No continuity snapshot available."
             else trimmed)
    | None ->
        let trimmed = String.trim meta.continuity_summary in
        if trimmed = "" then "No continuity snapshot available." else trimmed
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ ->
      let trimmed = String.trim meta.continuity_summary in
      if trimmed = "" then "No continuity snapshot available." else trimmed

(** Board event cursor bootstrap window (seconds). *)
let bootstrap_window_sec = Env_config.InternalTimers.bootstrap_window_sec

let is_self_author ~self_tokens (author : string) : bool =
  List.mem (String.lowercase_ascii (String.trim author)) self_tokens

(** Check whether this keeper has commented on a post, and whether new
    external comments arrived after the keeper's latest comment.
    Uses actual comment stream as ground truth (no proxy like reply_count
    or updated_at). Based on BDI commitment reconsideration: a committed
    response is only re-evaluated when new external beliefs arrive. *)
let check_self_comment_status ~self_tokens ~(post_id : string)
    : [ `Never | `No_new_external | `New_external of int * string * string ] =
  match Board_dispatch.get_comments ~post_id with
  | Error _ -> `Never
  | Ok comments ->
      let my_comments =
        List.filter
          (fun (c : Board.comment) ->
            is_self_author ~self_tokens (Board.Agent_id.to_string c.author))
          comments
      in
      if my_comments = [] then `Never
      else
        let my_latest_ts =
          List.fold_left
            (fun acc (c : Board.comment) -> max acc c.created_at)
            0.0 my_comments
        in
        let external_after =
          List.filter
            (fun (c : Board.comment) ->
              not (is_self_author ~self_tokens (Board.Agent_id.to_string c.author))
              && c.created_at > my_latest_ts)
            comments
        in
        match external_after with
        | [] -> `No_new_external
        | hd :: tl ->
          let latest =
            List.fold_left
              (fun (acc : Board.comment) (c : Board.comment) ->
                if c.created_at > acc.created_at then c else acc)
              hd tl
          in
          `New_external
            ( List.length external_after,
              Board.Agent_id.to_string latest.author,
              short_preview ~max_len:60 latest.content )

let read_room_signal ~(config : Room.config) ~(meta : keeper_meta) =
  if not meta.room_signal_prompt_enabled then
    (None, None)
  else
    let summary_json = Meta_cognition.summary_json config in
    match Meta_cognition.parse_summary summary_json with
    | Ok summary ->
        let interpretation = Meta_cognition.interpret summary in
        let digest_ref = Meta_cognition.latest_digest_ref ~summary () in
        (Some interpretation, digest_ref)
    | Error err ->
        Log.Keeper.warn "room signal interpretation parse failed for %s: %s"
          meta.name err;
        (None, None)

(** Collect recent board activity using cursor-based tracking.
    Cursor state lives in Keeper_registry as [(updated_at, post_id)].
    Returns (structured events, new post count, mention count).

    Comment-stream dedup: after the initial cursor + author filter,
    each candidate post is scanned for self-authored comments.
    Posts where the keeper has already commented and no new external
    replies have arrived are excluded. This prevents duplicate reactive
    comments while allowing legitimate follow-ups. *)
let collect_board_events ~(base_path : string) ~(continuity_summary : string)
    ~(meta : keeper_meta) : pending_board_event list * int * int =
  try
    let broad_scope = scope_message_feed_enabled meta in
    let cursor_ts, cursor_post_id =
      Keeper_registry.get_board_cursor ~base_path meta.name
    in
    let base_cursor =
      if cursor_ts > 0.0 then
        (cursor_ts, cursor_post_id)
      else
        (Time_compat.now () -. bootstrap_window_sec, None)
    in
    let posts = list_board_posts_after_cursor base_cursor in
    let self_tokens =
      [ meta.name; meta.agent_name ]
      |> List.map (fun value -> String.lowercase_ascii (String.trim value))
    in
    let recent =
      List.filter
        (fun (p : Board.post) ->
          not (is_self_author ~self_tokens
                 (Board.Agent_id.to_string p.author)))
        posts
    in
    let new_count = List.length recent in
    let targets =
      if meta.mention_targets <> [] then meta.mention_targets
      else [ meta.name ]
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
                 let needle =
                   "@" ^ String.lowercase_ascii target
                 in
                 Re.execp (Re.str needle |> Re.compile) haystack)
               targets)
           recent)
    in
    let event_limit = Keeper_config.keeper_board_event_limit () in
    let rec consume_posts remaining last_cursor acc = function
      | [] -> (List.rev acc, last_cursor)
      | (p : Board.post) :: rest ->
          let post_id = Board.Post_id.to_string p.id in
          let next_cursor = board_cursor_token_of_post p in
          let comment_status = check_self_comment_status ~self_tokens ~post_id in
          match comment_status with
          | `No_new_external ->
              Log.Keeper.debug
                "board dedup: skipping post_id=%s (no new external since my comment)"
                post_id;
              consume_posts remaining (Some next_cursor) acc rest
          | `Never ->
              let signal : Board_dispatch.keeper_board_signal =
                {
                  kind = Board_dispatch.Board_post_created;
                  post_id;
                  author = Board.Agent_id.to_string p.author;
                  title = p.title;
                  content = p.content;
                  hearth = p.hearth;
                }
              in
              let matched = board_signal_match ~continuity_summary ~meta ~signal in
              if not (matched.explicit_mention || broad_scope) then (
                Log.Keeper.debug
                  "board dedup: skipping post_id=%s (no mention and no prior keeper participation)"
                  post_id;
                consume_posts remaining (Some next_cursor) acc rest)
              else if remaining <= 0 then
                (List.rev acc, last_cursor)
              else
                consume_posts
                  (remaining - 1)
                  (Some next_cursor)
                  ({
                     post_id;
                     author = Board.Agent_id.to_string p.author;
                     title = p.title;
                     preview = short_preview ~max_len:80 p.content;
                     hearth = p.hearth;
                     post_kind = p.post_kind;
                     updated_at = p.updated_at;
                     explicit_mention = matched.explicit_mention;
                     matched_targets = matched.matched_targets;
                     self_commented = false;
                     new_external_since = 0;
                     latest_external_author = None;
                     latest_external_preview = None;
                   }
                   :: acc)
                  rest
          | `New_external (count, ext_author, ext_preview) ->
              if remaining <= 0 then
                (List.rev acc, last_cursor)
              else
                let signal : Board_dispatch.keeper_board_signal =
                  {
                    kind = Board_dispatch.Board_post_created;
                    post_id;
                    author = Board.Agent_id.to_string p.author;
                    title = p.title;
                    content = p.content;
                    hearth = p.hearth;
                  }
                in
                let matched = board_signal_match ~continuity_summary ~meta ~signal in
                consume_posts
                  (remaining - 1)
                  (Some next_cursor)
                  ({
                     post_id;
                     author = Board.Agent_id.to_string p.author;
                     title = p.title;
                     preview = short_preview ~max_len:80 p.content;
                     hearth = p.hearth;
                     post_kind = p.post_kind;
                     updated_at = p.updated_at;
                     explicit_mention = matched.explicit_mention;
                     matched_targets = matched.matched_targets;
                     self_commented = true;
                     new_external_since = count;
                     latest_external_author = Some ext_author;
                     latest_external_preview = Some ext_preview;
                   }
                   :: acc)
                  rest
    in
    let final_events, last_cursor =
      consume_posts event_limit None [] recent
    in
    (match last_cursor with
     | Some (ts, post_id)
       when compare_board_cursor_token
              (ts, post_id)
              (fst base_cursor, Option.value ~default:"" (snd base_cursor))
            > 0 ->
         Keeper_registry.set_board_cursor ~base_path meta.name ts (Some post_id)
     | Some (ts, post_id) ->
       Log.Keeper.debug
         "board cursor not advanced for %s: new=(%f, %s) not greater than base=(%f, %s)"
         meta.name ts post_id (fst base_cursor)
         (Option.value ~default:"" (snd base_cursor))
     | None ->
       if final_events <> [] then
         Log.Keeper.warn
           "board cursor not updated for %s despite %d events processed"
           meta.name (List.length final_events));
    (final_events, new_count, mention_count)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn "board event collection failed: %s"
      (Printexc.to_string exn);
    ([], 0, 0)

let observe ~(pending_board_events : pending_board_event list option)
    ~(config : Room.config)
    ~(meta : keeper_meta) :
    world_observation =
  let pending_mentions, pending_scope_messages, message_cursor_updates =
    collect_message_scope ~config ~meta
  in
  let unclaimed_task_count, failed_task_count =
    read_backlog_counts ~config
  in
  let active_agent_count = count_active_agents ~config in
  let idle_seconds = compute_idle_seconds ~meta in
  let context_ratio = read_context_ratio ~config ~meta in
  let continuity_summary = read_continuity_summary ~config ~meta in
  let worktree_change_summary =
    Worktree_live_context.capture_change_block
      ~base_path:config.base_path ~actor_key:meta.name
  in
  let economic_pressure =
    Agent_economy.economic_pressure ~base_path:config.base_path
      ~agent_name:meta.name
  in
  let room_signal_interpretation, room_signal_digest_ref =
    read_room_signal ~config ~meta
  in
  let pending_board_events =
    match pending_board_events with
    | Some events -> events
    | None ->
        let events, _board_new_count, _board_mention_count =
          collect_board_events ~base_path:config.base_path ~meta ~continuity_summary
        in
        events
  in
  (* Work Discovery: check if scan interval has elapsed *)
  let work_discovery_due =
    match meta.work_discovery_enabled with
    | Some true ->
      let interval =
        Option.value ~default:600 meta.work_discovery_interval_sec
      in
      let since_last =
        Time_compat.now () -. meta.runtime.proactive_rt.last_work_discovery_ts
      in
      since_last >= float_of_int interval
    | _ -> false
  in
  (* Telemetry Feedback: read cached behavioral stats (proactive refresh) *)
  let behavioral_stats =
    match meta.telemetry_feedback_enabled with
    | Some true ->
      Keeper_telemetry_feedback.get_cached_stats ~keeper_name:meta.name
    | _ -> None
  in
  {
    pending_mentions;
    pending_board_events;
    pending_scope_messages;
    message_cursor_updates;
    idle_seconds;
    active_goals = meta.active_goal_ids;
    continuity_summary;
    worktree_change_summary;
    context_ratio;
    economic_pressure;
    unclaimed_task_count;
    failed_task_count;
    active_agent_count;
    room_signal_interpretation;
    room_signal_digest_ref;
    last_turn_budget = None;
    last_tools_used = [];
    work_discovery_due;
    behavioral_stats;
  }

let actionable_signal_present (observation : world_observation) =
  observation.pending_mentions <> []
  || observation.pending_board_events <> []
  || observation.pending_scope_messages <> []
  || observation.unclaimed_task_count > 0
  || observation.failed_task_count > 0
  || observation.work_discovery_due

(** Compute effective scheduled autonomous cooldown with idle decay.
    After extended idle (> base cooldown), halve the cooldown each
    additional period, down to a configurable floor.  This prevents
    permanent silence when no external events arrive. *)
let effective_scheduled_autonomous_cooldown
    ~(base_cooldown : int) ~(since_last : int) : int =
  let min_cooldown = Keeper_config.keeper_proactive_min_cooldown_sec () in
  (* Floor must not exceed the base cooldown — otherwise decay would
     paradoxically increase a short cooldown. *)
  let floor = min min_cooldown base_cooldown in
  if since_last <= base_cooldown then base_cooldown
  else
    let decay_periods = (since_last - base_cooldown) / (max 1 base_cooldown) in
    let capped_periods = min decay_periods 4 in
    let factor = 1.0 /. (Float.pow 2.0 (float_of_int capped_periods)) in
    max floor (int_of_float (float_of_int base_cooldown *. factor))

let effective_proactive_cooldown =
  effective_scheduled_autonomous_cooldown

let unified_turn_decision ~(meta : keeper_meta) (observation : world_observation) =
  let reactive_triggers =
    [
      (if observation.pending_mentions <> [] then Some Mention_pending else None);
      (if observation.pending_board_events <> [] then Some Board_event_pending else None);
      (if observation.pending_scope_messages <> [] then Some Scope_message_pending else None);
    ]
    |> List.filter_map Fun.id
  in
  match reactive_triggers with
  | first :: rest ->
      {
        should_run = true;
        channel = Reactive;
        verdict = Run { reasons = (first, rest) };
        since_last_scheduled_autonomous = None;
        effective_cooldown = None;
        task_reactive_cooldown = None;
        idle_gate_sec = None;
      }
  | [] ->
      let since_last_scheduled_autonomous =
        if meta.runtime.proactive_rt.last_ts <= 0.0 then max_int
        else
          int_of_float (max 0.0 (Time_compat.now () -. meta.runtime.proactive_rt.last_ts))
      in
      let idle_gate_sec = meta.proactive.idle_sec in
      if not meta.proactive.enabled then
        {
          should_run = false;
          channel = Scheduled_autonomous;
          verdict = Skip { reasons = (Scheduled_autonomous_disabled, []) };
          since_last_scheduled_autonomous = Some since_last_scheduled_autonomous;
          effective_cooldown = None;
          task_reactive_cooldown = None;
          idle_gate_sec = Some idle_gate_sec;
        }
      else
        let effective_cooldown =
          effective_scheduled_autonomous_cooldown
            ~base_cooldown:meta.proactive.cooldown_sec
            ~since_last:since_last_scheduled_autonomous
        in
        let task_cooldown_divisor =
          Keeper_config.keeper_proactive_task_cooldown_divisor ()
        in
        let task_cooldown_floor =
          Keeper_config.keeper_proactive_task_min_cooldown_sec ()
        in
        let task_reactive_cooldown =
          max task_cooldown_floor
            (effective_cooldown / max 1 task_cooldown_divisor)
        in
        let has_actionable_tasks =
          observation.unclaimed_task_count > 0 || observation.failed_task_count > 0
        in
        let idle_gate_elapsed = observation.idle_seconds >= idle_gate_sec in
        let cooldown_elapsed =
          since_last_scheduled_autonomous >= effective_cooldown
        in
        let backlog_elapsed =
          has_actionable_tasks
          && since_last_scheduled_autonomous >= task_reactive_cooldown
        in
        let should_run = idle_gate_elapsed && (cooldown_elapsed || backlog_elapsed) in
        let verdict =
          if should_run then
            let run_reasons =
              [
                Some Scheduled_autonomous_turn;
                (if since_last_scheduled_autonomous = max_int
                 then Some Never_started else None);
                (if idle_gate_elapsed
                 then Some (Idle_cooldown_elapsed
                              { idle_sec = observation.idle_seconds;
                                cooldown = effective_cooldown }) else None);
                (if cooldown_elapsed then Some Cooldown_elapsed else None);
                (if has_actionable_tasks
                 then Some (Task_backlog
                              { unclaimed = observation.unclaimed_task_count;
                                failed = observation.failed_task_count }) else None);
                (if backlog_elapsed
                 then Some Task_reactive_cooldown_elapsed else None);
              ]
              |> List.filter_map Fun.id
            in
            (* NEL: scheduled autonomous runs always emit the synthetic
               Scheduled_autonomous_turn tag first, so the reason list
               cannot be empty even if future edits change the payload list. *)
            match run_reasons with
            | first :: rest ->
                Run { reasons = (first, rest) }
            | [] ->
                (* Structurally unreachable: idle_gate_elapsed && should_run
                   and the synthetic Scheduled_autonomous_turn reason
                   guarantee a non-empty run reason list.
                   Defensive: log warning and fall through to skip so that
                   should_run (derived below) stays consistent with verdict. *)
                Log.Keeper.warn
                  "unreachable: should_run=true but run_reasons is empty";
                Skip { reasons = (No_signal, []) }
          else
            let skip_reasons =
              [
                (if not idle_gate_elapsed
                 then Some (Idle_gate_pending
                              { remaining_sec =
                                  idle_gate_sec - observation.idle_seconds })
                 else None);
                (if idle_gate_elapsed && not cooldown_elapsed
                 then Some (Cooldown_pending
                              { remaining_sec =
                                  effective_cooldown - since_last_scheduled_autonomous })
                 else None);
              ]
              |> List.filter_map Fun.id
            in
            match skip_reasons with
            | first :: rest ->
                Skip { reasons = (first, rest) }
            | [] ->
                Skip { reasons = (No_signal, []) }
        in
        (* Derive should_run from verdict to guarantee consistency.
           The earlier [let should_run] is an intent signal; verdict is
           authoritative after the reason-list construction. *)
        let should_run =
          match verdict with Run _ -> true | Skip _ -> false
        in
        {
          should_run;
          channel = Scheduled_autonomous;
          verdict;
          since_last_scheduled_autonomous = Some since_last_scheduled_autonomous;
          effective_cooldown = Some effective_cooldown;
          task_reactive_cooldown = Some task_reactive_cooldown;
          idle_gate_sec = Some idle_gate_sec;
        }

let should_run_unified_turn ~(meta : keeper_meta) (observation : world_observation) =
  (unified_turn_decision ~meta observation).should_run
