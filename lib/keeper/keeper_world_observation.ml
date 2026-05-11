(** Keeper_world_observation — Structured world state for keeper cycles.

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
  claimable_task_count : int;
  failed_task_count : int;
  pending_verification_count : int;
  backlog_updated_since_last_scheduled_autonomous : bool;
  active_agent_count : int;
  last_turn_budget : (int * int) option;
  work_discovery_due : bool;
}

type keeper_cycle_channel =
  | Reactive
  | Scheduled_autonomous

type unified_turn_channel = keeper_cycle_channel

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
  | Min_interval_elapsed
  | Entropic_oscillation

type skip_reason =
  | Keeper_paused
  | Approval_pending
  | Scheduled_autonomous_disabled
  | Provider_cooldown_pending of { remaining_sec : int }
  | Idle_gate_pending of { remaining_sec : int }
  | Cooldown_pending of { remaining_sec : int }
  | No_signal

type turn_verdict =
  | Run of { reasons : turn_reason * turn_reason list }
  | Skip of { reasons : skip_reason * skip_reason list }

let turn_reason_to_string = function
  | Mention_pending -> "mention_pending"
  | Board_event_pending -> "board_event_pending"
  | Scope_message_pending -> "scope_message_pending"
  | Scheduled_autonomous_turn -> "scheduled_autonomous_turn"
  | Idle_cooldown_elapsed _ -> "idle_cooldown_elapsed"
  | Cooldown_elapsed -> "cooldown_elapsed"
  | Task_backlog _ -> "task_backlog"
  | Task_reactive_cooldown_elapsed -> "task_reactive_cooldown_elapsed"
  | Never_started -> "never_started"
  | Min_interval_elapsed -> "min_interval_elapsed"
  | Entropic_oscillation -> "entropic_oscillation"

let skip_reason_to_string = function
  | Keeper_paused -> "keeper_paused"
  | Approval_pending -> "approval_pending"
  | Scheduled_autonomous_disabled -> "scheduled_autonomous_disabled"
  | Provider_cooldown_pending _ -> "provider_cooldown_pending"
  | Idle_gate_pending _ -> "idle_gate_pending"
  | Cooldown_pending _ -> "cooldown_pending"
  | No_signal -> "no_signal"

let channel_to_string = function
  | Reactive -> "reactive"
  | Scheduled_autonomous -> "scheduled_autonomous"

let is_autonomous_channel (channel : string) : bool =
  String.equal channel "scheduled_autonomous"
  || String.equal channel "proactive"

let verdict_reasons_to_strings = function
  | Run { reasons = (first, rest) } ->
      List.map turn_reason_to_string (first :: rest)
  | Skip { reasons = (first, rest) } ->
      List.map skip_reason_to_string (first :: rest)
type keeper_cycle_decision = {
  should_run : bool;
  channel : keeper_cycle_channel;
  verdict : turn_verdict;
  since_last_scheduled_autonomous : int option;
  effective_cooldown : int option;
  task_reactive_cooldown : int option;
  idle_gate_sec : int option;
}

type unified_turn_decision = keeper_cycle_decision

type board_signal_match = {
  explicit_mention : bool;
  matched_targets : string list;
  score : int;
}

let scope_message_feed_enabled (meta : keeper_meta) : bool =
  meta.room_signal_prompt_enabled

let message_feed_targets (meta : keeper_meta) =
  if meta.mention_targets <> [] then meta.mention_targets else [ meta.name ]

let normalized_identity_token value =
  let trimmed = String.lowercase_ascii (String.trim value) in
  if trimmed = "" then None else Some trimmed

let identity_tokens_of_value value =
  let trimmed = String.trim value in
  [
    normalized_identity_token trimmed;
    Option.bind
      (Keeper_identity.canonical_keeper_name_from_agent_name trimmed)
      normalized_identity_token;
    Option.bind (Keeper_identity.canonical_keeper_name trimmed)
      normalized_identity_token;
  ]
  |> List.filter_map (fun value -> value)
  |> List.sort_uniq String.compare

let self_identity_tokens (meta : keeper_meta) =
  [ meta.name; meta.agent_name ]
  |> List.map identity_tokens_of_value
  |> List.flatten
  |> List.sort_uniq String.compare

(* Single source of truth for "is this author one of us?".  Two inline
   copies of this predicate used to live in [collect_message_scope] and
   [board_signal_match]; centralising avoids the scatter-drift
   anti-pattern when [identity_tokens_of_value] is ever extended. *)
let is_self_author ~self_tokens (author : string) : bool =
  identity_tokens_of_value author
  |> List.exists (fun author_token -> List.mem author_token self_tokens)

let is_keeper_authored_message author =
  Option.is_some (Keeper_identity.canonical_keeper_name_from_agent_name author)

let collect_message_scope ~(config : Coord.config) ~(meta : keeper_meta) :
    ((string * string) list * (string * string) list * (string * int) list) =
  let targets = message_feed_targets meta in
  let broad_scope = scope_message_feed_enabled meta in
  let self_tokens = self_identity_tokens meta in
  let batch_limit = Keeper_config.keeper_batch_limit () in
  let rec consume_room_messages remaining last_processed mentions scope_messages =
    function
    | [] -> (`Done, remaining, last_processed, List.rev mentions, List.rev scope_messages)
    | (msg : Masc_domain.message) :: rest ->
        let author = String.trim msg.from_agent in
        if author = "" || is_self_author ~self_tokens author then
          consume_room_messages remaining msg.seq mentions scope_messages rest
        else if
          Coord_task_cache_invariant.stale_active_task_signal_present
            ~config
            ~from_agent:author
            ~module_name:"keeper_world_observation"
            ~content:msg.content
        then
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
          (* Broad room scope is for operator/human context; direct mentions
             above still allow explicit keeper-to-keeper handoff. *)
          if is_keeper_authored_message author then
            consume_room_messages remaining msg.seq mentions scope_messages rest
          else if remaining <= 0 then
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
            Coord.get_all_messages_raw config ~since_seq
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | _ -> []
        in
        let status, remaining, last_processed, room_mentions, scoped_messages =
          consume_room_messages remaining since_seq [] [] messages
        in
        let cursor_acc =
          if last_processed > since_seq then (room_id, last_processed) :: cursor_acc
          else cursor_acc
        in
        let mentions_acc = mentions_acc @ room_mentions in
        let scope_acc = scope_acc @ scoped_messages in
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

let backlog_updated_since_last_scheduled_autonomous
    ~(meta : keeper_meta)
    ~(backlog : Masc_domain.backlog) : bool =
  let last_ts = meta.runtime.proactive_rt.last_ts in
  if last_ts <= 0.0 then backlog.tasks <> []
  else
    match Coord_resilience.Time.parse_iso8601_opt backlog.last_updated with
    | Some updated_at -> updated_at > last_ts
    | None -> false

let claim_goal_scope_filter ?agent_tool_names ~(config : Coord.config)
    ~(meta : keeper_meta) () =
  let scope =
    Keeper_runtime_contract.resolve_observation_claim_goal_scope
      ?agent_tool_names ~config ~meta ()
  in
  scope.task_filter

(** Read room backlog counts. *)
let read_backlog_counts ~allowed_tool_names ~(config : Coord.config)
    ~(meta : keeper_meta) :
    int * int * int * int * bool =
  try
    let backlog = Coord.read_backlog config in
    let unclaimed_tasks =
      List.filter
        (fun (t : Masc_domain.task) -> t.task_status = Masc_domain.Todo)
        backlog.tasks
    in
    let unclaimed = List.length unclaimed_tasks in
    let claim_scope_filter =
      claim_goal_scope_filter
        ?agent_tool_names:allowed_tool_names
        ~config
        ~meta
        ()
    in
    (* Build the allowed-set once and reuse across all candidates in
       the [unclaimed_tasks] filter below — see PR #14826 for the
       O(R+A) rationale. *)
    let required_tools_allowed =
      Coord_task_schedule.make_required_tools_predicate
        ?agent_tool_names:allowed_tool_names
        ()
    in
    let claimable =
      List.length
        (List.filter
           (fun task ->
             Coord_task_schedule.task_is_claim_pool_candidate task
             && claim_scope_filter task
             && required_tools_allowed
                  (Coord_task_schedule.task_required_tools task))
           unclaimed_tasks)
    in
    let failed =
      List.length
        (List.filter
           (fun (t : Masc_domain.task) ->
             match t.task_status with
             | Masc_domain.Cancelled _ -> true
             | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _
             | Masc_domain.AwaitingVerification _ | Masc_domain.Done _ -> false)
           backlog.tasks)
    in
    let pending_verification =
      List.length
        (List.filter
           (fun (t : Masc_domain.task) ->
             match t.task_status with
             | Masc_domain.AwaitingVerification _ -> true
             | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _
             | Masc_domain.Done _ | Masc_domain.Cancelled _ -> false)
           backlog.tasks)
    in
    let backlog_updated_since_last_scheduled_autonomous =
      backlog_updated_since_last_scheduled_autonomous ~meta ~backlog
    in
    ( unclaimed,
      claimable,
      failed,
      pending_verification,
      backlog_updated_since_last_scheduled_autonomous )
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | ex ->
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_observation_query_failures
        ~labels:[("operation", Observation_query_operation.(to_label Read_backlog_counts))]
        ();
      Log.Keeper.warn "read_backlog_counts failed: %s" (Printexc.to_string ex);
      (0, 0, 0, 0, false)

(** Count active agents in room. *)
let count_active_agents ~(config : Coord.config) : int =
  try List.length (Coord.get_agents_raw config)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | ex ->
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_observation_query_failures
        ~labels:[("operation", Observation_query_operation.(to_label Count_active_agents))]
        ();
      Log.Keeper.warn "count_active_agents failed: %s" (Printexc.to_string ex);
      0

(** Compute idle seconds from keeper timestamps. *)
let compute_idle_seconds ~(meta : keeper_meta) : int =
  let now_ts = Time_compat.now () in
  let created_ts =
    Coord_resilience.Time.parse_iso8601_opt meta.created_at
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
  Board_dispatch.list_posts ~sort_by:Board_dispatch.Updated ~limit:max_int ()
  |> List.filter is_after_cursor
  |> List.sort (fun (a : Board.post) (b : Board.post) ->
       compare_board_cursor_token
         (board_cursor_token_of_post a)
         (board_cursor_token_of_post b))

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
  let self_tokens = self_identity_tokens meta in
  if is_self_author ~self_tokens signal.author then
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
             && String_util.contains_substring haystack needle)
    in
    if matched_targets <> [] then
      { explicit_mention = true; matched_targets; score = 100 }
    else { explicit_mention = false; matched_targets = []; score = 0 }

(** Read context ratio from checkpoint if available. *)
let read_context_ratio ~(config : Coord.config) ~(meta : keeper_meta) : float =
  try
    let cascade_models =
      Keeper_model_labels.configured_model_labels_of_meta meta
    in
    let primary_max_context =
      let resolution =
        Keeper_exec_context.resolve_max_context_resolution
          ~requested_override:meta.max_context_override
          cascade_models
      in
      resolution.effective_budget
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
let read_continuity_summary ~(config : Coord.config) ~(meta : keeper_meta)
    : string =
  try
    match Keeper_memory_policy.read_progress_snapshot ~config ~name:meta.name with
    | Some snapshot ->
        keeper_state_snapshot_to_summary_text snapshot
    | None ->
    let cascade_models =
      Keeper_model_labels.configured_model_labels_of_meta meta
    in
    let primary_max_context =
      let resolution =
        Keeper_exec_context.resolve_max_context_resolution
          ~requested_override:meta.max_context_override
          cascade_models
      in
      resolution.effective_budget
    in
    let base_dir = session_base_dir config in
    let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    let session, ctx_opt =
      load_context_from_checkpoint
        ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages
        ~trace_id
        ~primary_model_max_tokens:primary_max_context ~base_dir
    in
      match ctx_opt with
      | Some c ->
          let structured_snapshot =
            match
              Keeper_checkpoint_store.load_oas
                ~session_dir:session.session_dir ~session_id:trace_id
            with
            | Ok cp ->
                (match cp.Agent_sdk.Checkpoint.working_context with
                 | Some json ->
                     Keeper_memory_policy
                     .snapshot_of_structured_working_context json
                 | None -> None)
            | Error _ -> None
          in
          let snapshot =
            match latest_state_snapshot_from_messages (messages_of_context c) with
            | Some _ as snapshot -> snapshot
            | None -> structured_snapshot
          in
          (match snapshot with
           | Some s -> keeper_state_snapshot_to_summary_text s
           | None ->
               continuity_fallback_summary_text
                 ~continuity_summary:meta.continuity_summary
                 ~last_continuity_update_ts:meta.runtime.last_continuity_update_ts)
      | None ->
          continuity_fallback_summary_text
            ~continuity_summary:meta.continuity_summary
            ~last_continuity_update_ts:meta.runtime.last_continuity_update_ts
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ ->
      continuity_fallback_summary_text
        ~continuity_summary:meta.continuity_summary
        ~last_continuity_update_ts:meta.runtime.last_continuity_update_ts

(** Board event cursor bootstrap window (seconds). *)
let bootstrap_window_sec = Env_config.InternalTimers.bootstrap_window_sec

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

type stigmergy_match_result = { overall_score : int }

let stigmergy_match ~(meta : keeper_meta)
    ~(signal : Board_dispatch.keeper_board_signal) : stigmergy_match_result =
  let signal_text = String.lowercase_ascii (board_signal_text signal) in
  let goal_keywords =
    [ meta.goal; meta.short_goal; meta.mid_goal; meta.long_goal ]
    |> List.filter (fun s -> String.trim s <> "")
    |> List.concat_map (fun g ->
         String.split_on_char ' ' (String.lowercase_ascii g)
         |> List.map String.trim
         |> List.filter (fun s -> String.length s > 3))
    |> List.sort_uniq String.compare
  in
  let score =
    List.fold_left
      (fun acc kw ->
        if String_util.contains_substring signal_text kw then acc + 5 else acc)
      0 goal_keywords
  in
  { overall_score = min score 50 }

let board_signal_wake_reason
    ~continuity_summary
    ~(meta : keeper_meta)
    ~(signal : Board_dispatch.keeper_board_signal) : string option =
  let matched = board_signal_match ~continuity_summary ~meta ~signal in
  if matched.explicit_mention then
    Some "explicit_mention"
  else if scope_message_feed_enabled meta then
    Some "board_activity"
  else
    let stigmergy = stigmergy_match ~meta ~signal in
    if stigmergy.overall_score > 0 then
      Some ("stigmergy: score=" ^ string_of_int stigmergy.overall_score)
    else
      let self_tokens = self_identity_tokens meta in
      match signal.kind with
      | Board_dispatch.Board_comment_added ->
          (match check_self_comment_status ~self_tokens ~post_id:signal.post_id with
           | `New_external _ -> Some "thread_reply_after_self_comment"
           | `Never | `No_new_external -> None)
      | Board_dispatch.Board_post_created -> None

let json_string_member name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | _ -> None

let json_string_null_member name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | Some `Null | None -> None
  | _ -> None

let board_signal_kind_of_string = function
  | "post_created" | "post" -> Some Board_dispatch.Board_post_created
  | "comment_added" | "comment" -> Some Board_dispatch.Board_comment_added
  | _ -> None

let board_signal_of_stimulus_payload payload =
  try
    match Yojson.Safe.from_string payload with
    | `Assoc fields
      when Option.equal String.equal
             (json_string_member "source" fields)
             (Some "board_signal") ->
        (match
           ( json_string_member "kind" fields,
             json_string_member "post_id" fields,
             json_string_member "author" fields,
             json_string_member "title" fields,
             json_string_member "content" fields )
         with
         | Some kind, Some post_id, Some author, Some title, Some content ->
             Option.map
               (fun kind ->
                 {
                   Board_dispatch.kind;
                   post_id;
                   author;
                   title;
                   content;
                   hearth = json_string_null_member "hearth" fields;
                 })
               (board_signal_kind_of_string kind)
         | _ -> None)
    | _ -> None
  with Yojson.Json_error _ -> None

let pending_board_event_of_board_signal ~continuity_summary ~(meta : keeper_meta)
    ~(arrived_at : float) (signal : Board_dispatch.keeper_board_signal) :
    pending_board_event =
  let self_tokens = self_identity_tokens meta in
  let matched = board_signal_match ~continuity_summary ~meta ~signal in
  let post_snapshot =
    match Board_dispatch.get_post ~post_id:signal.post_id with
    | Ok post -> Some post
    | Error _ -> None
  in
  let title, preview, hearth, post_kind, updated_at =
    match post_snapshot with
    | Some (post : Board.post) ->
        ( post.title,
          short_preview ~max_len:80 post.content,
          post.hearth,
          post.post_kind,
          post.updated_at )
    | None ->
        ( signal.title,
          short_preview ~max_len:80 signal.content,
          signal.hearth,
          Board.Human_post,
          arrived_at )
  in
  let self_commented, new_external_since, latest_external_author,
      latest_external_preview =
    match signal.kind with
    | Board_dispatch.Board_post_created -> (false, 0, None, None)
    | Board_dispatch.Board_comment_added ->
        (match check_self_comment_status ~self_tokens ~post_id:signal.post_id with
         | `New_external (count, author, preview) ->
             (true, count, Some author, Some preview)
         | `No_new_external ->
             ( true,
               0,
               Some signal.author,
               Some (short_preview ~max_len:60 signal.content) )
         | `Never ->
             ( false,
               1,
               Some signal.author,
               Some (short_preview ~max_len:60 signal.content) ))
  in
  {
    post_id = signal.post_id;
    author = signal.author;
    title;
    preview;
    hearth;
    post_kind;
    updated_at;
    explicit_mention = matched.explicit_mention;
    matched_targets = matched.matched_targets;
    self_commented;
    new_external_since;
    latest_external_author;
    latest_external_preview;
  }

let pending_board_event_of_stimulus ~continuity_summary ~(meta : keeper_meta)
    (stimulus : Keeper_event_queue.stimulus) : pending_board_event option =
  board_signal_of_stimulus_payload stimulus.payload
  |> Option.map
       (pending_board_event_of_board_signal ~continuity_summary ~meta
          ~arrived_at:stimulus.arrived_at)

(** Collect recent board activity using cursor-based tracking.
    Cursor state lives in Keeper_registry as [(updated_at, post_id)].
    Returns (structured events, new post count, mention count).

    Comment-stream dedup: after the initial cursor + author filter,
    each candidate post is scanned for self-authored comments.
    Posts where the keeper has already commented and no new external
    replies have arrived are excluded. This prevents duplicate reactive
    comments while allowing legitimate follow-ups. *)
let collect_board_events_with_cursor_policy ~advance_cursor ~(base_path : string)
    ~(continuity_summary : string) ~(meta : keeper_meta) :
    pending_board_event list * int * int =
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
    let self_tokens = self_identity_tokens meta in
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
                 let needle = "@" ^ String.lowercase_ascii target in
                 String_util.contains_substring haystack needle)
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
    if advance_cursor then (
      match last_cursor with
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
        if final_events <> [] then begin
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_observation_query_failures
            ~labels:[("operation", Observation_query_operation.(to_label Cursor_stale))]
            ();
          Log.Keeper.warn
            "board cursor not updated for %s despite %d events processed"
            meta.name (List.length final_events)
        end);
    (final_events, new_count, mention_count)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_observation_query_failures
      ~labels:[("operation", Observation_query_operation.(to_label Board_events))]
      ();
    Log.Keeper.warn "board event collection failed: %s"
      (Printexc.to_string exn);
    ([], 0, 0)

let collect_board_events ~(base_path : string) ~(continuity_summary : string)
    ~(meta : keeper_meta) : pending_board_event list * int * int =
  collect_board_events_with_cursor_policy ~advance_cursor:true ~base_path
    ~continuity_summary ~meta

let collect_board_events_without_advancing_cursor ~(base_path : string)
    ~(continuity_summary : string) ~(meta : keeper_meta) :
    pending_board_event list * int * int =
  collect_board_events_with_cursor_policy ~advance_cursor:false ~base_path
    ~continuity_summary ~meta

let observe ~allowed_tool_names
    ~(pending_board_events : pending_board_event list option)
    ~(config : Coord.config)
    ~(meta : keeper_meta) :
    world_observation =
  let pending_mentions, pending_scope_messages, message_cursor_updates =
    collect_message_scope ~config ~meta
  in
  let ( unclaimed_task_count,
        claimable_task_count,
        failed_task_count,
        pending_verification_count,
        backlog_updated_since_last_scheduled_autonomous ) =
    read_backlog_counts ~allowed_tool_names ~config ~meta
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
  let pending_board_events =
    match pending_board_events with
    | Some events -> events
    | None ->
        let events, _board_new_count, _board_mention_count =
          collect_board_events ~base_path:config.base_path ~meta ~continuity_summary
        in
        events
  in
  (* Work Discovery: check if scan interval has elapsed.
     None means "not explicitly configured" — default to enabled so
     keepers that lack explicit work_discovery_enabled in their profile
     still discover work autonomously.  Only Some false explicitly
     disables the mechanism.  Ref: P0 keeper activity investigation,
     15/16 keepers had None → idle forever. *)
  let work_discovery_due =
    match meta.work_discovery_enabled with
    | Some false -> false
    | _ ->
      let interval =
        Option.value ~default:600 meta.work_discovery_interval_sec
      in
      let since_last =
        Time_compat.now () -. meta.runtime.proactive_rt.last_work_discovery_ts
      in
      since_last >= float_of_int interval
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
    claimable_task_count;
    failed_task_count;
    pending_verification_count;
    backlog_updated_since_last_scheduled_autonomous;
    active_agent_count;
    last_turn_budget = None;
    work_discovery_due;
  }

let durable_signal_present ~allowed_tool_names ~pending_board_events
    ~(config : Coord.config) ~(meta : keeper_meta) : bool =
  let pending_mentions, pending_scope_messages, _message_cursor_updates =
    collect_message_scope ~config ~meta
  in
  let ( _unclaimed_task_count,
        claimable_task_count,
        failed_task_count,
        pending_verification_count,
        _backlog_updated_since_last_scheduled_autonomous ) =
    read_backlog_counts ~allowed_tool_names ~config ~meta
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
  let work_discovery_due =
    match meta.work_discovery_enabled with
    | Some false -> false
    | _ ->
      let interval =
        Option.value ~default:600 meta.work_discovery_interval_sec
      in
      Time_compat.now () -. meta.runtime.proactive_rt.last_work_discovery_ts
      >= float_of_int interval
  in
  pending_mentions <> []
  || pending_board_events <> []
  || pending_scope_messages <> []
  || claimable_task_count > 0
  || failed_task_count > 0
  || pending_verification_count > 0
  || work_discovery_due

let actionable_signal_present (observation : world_observation) =
  observation.pending_mentions <> []
  || observation.pending_board_events <> []
  || observation.pending_scope_messages <> []
  || Option.is_some observation.worktree_change_summary
  || observation.claimable_task_count > 0
  || observation.failed_task_count > 0
  || observation.pending_verification_count > 0
  || observation.work_discovery_due

let proactive_work_signal_present ~(meta : keeper_meta)
    (observation : world_observation) =
  actionable_signal_present observation
  || Option.is_some meta.current_task_id

(** Compute effective scheduled autonomous cooldown with idle decay.
    After extended idle (> base cooldown), halve the cooldown each
    additional period, down to a configurable floor.  This prevents
    permanent silence when no external events arrive. *)
let effective_scheduled_autonomous_cooldown
    ~(base_cooldown : int) ~(since_last : int)
    ?(consecutive_noop_count = 0) () : int =
  (* Noop backoff: consecutive observation-only cycles multiply the base
     cooldown by 2^min(n, 3), capping at 8x. This prevents token waste when
     the keeper repeatedly reads board_list without taking action. *)
  let noop_multiplier =
    if consecutive_noop_count <= 0 then 1
    else 1 lsl (min consecutive_noop_count 3)  (* 1, 2, 4, 8 *)
  in
  let effective_base = base_cooldown * noop_multiplier in
  let min_cooldown = Keeper_config.keeper_proactive_min_cooldown_sec () in
  (* Floor must not exceed the effective base cooldown — otherwise decay would
     paradoxically increase a short cooldown. *)
  let floor = min min_cooldown effective_base in
  if since_last <= effective_base then effective_base
  else
    let decay_periods = (since_last - effective_base) / (max 1 effective_base) in
    let capped_periods = min decay_periods 4 in
    let factor = 1.0 /. (Float.pow 2.0 (float_of_int capped_periods)) in
    max floor (int_of_float (float_of_int effective_base *. factor))

let effective_proactive_cooldown =
  effective_scheduled_autonomous_cooldown

let fallback_cascade_for_provider_cooldown
    ~(base_cascade : string)
    ~(effective_cascade : string) : string option =
  let normalized_base =
    Keeper_cascade_profile.normalize_declared_name base_cascade
  in
  let normalized_effective =
    Keeper_cascade_profile.normalize_declared_name effective_cascade
  in
  if not (String.equal normalized_effective normalized_base)
  then Some normalized_base
  else if
    String.equal normalized_effective Keeper_config.local_only_cascade_name
    || String.equal normalized_effective (Keeper_config.default_cascade_name ())
  then None
  else Some (Keeper_config.default_cascade_name ())

let provider_cooldown_remaining_sec_for_cascade
    ~(cascade_name : Keeper_cascade_profile.runtime_name) : int option =
  let model_ids =
    Cascade_runtime.models_of_cascade_name
      cascade_name
    |> Cascade_config.parse_model_strings
    |> List.map (fun (cfg : Llm_provider.Provider_config.t) ->
           String.trim cfg.model_id)
    |> List.filter (fun model_id -> model_id <> "")
    |> List.sort_uniq String.compare
  in
  match model_ids with
  | [] -> None
  | _ ->
      let provider_infos =
        List.map
          (fun provider_key ->
             Cascade_health_tracker.provider_info
               Cascade_health_tracker.global ~provider_key)
          model_ids
      in
      if not (List.for_all Option.is_some provider_infos) then None
      else
        let provider_infos = List.filter_map Fun.id provider_infos in
        if not (List.for_all (fun info -> info.Cascade_health_tracker.in_cooldown) provider_infos)
        then None
        else
          let now = Time_compat.now () in
          provider_infos
          |> List.filter_map
               (fun info -> info.Cascade_health_tracker.cooldown_expires_at)
          |> List.map (fun expires_at ->
                 int_of_float
                   (Float.max 0.0 (Float.ceil (expires_at -. now))))
          |> function
          | [] -> Some 0
          | first :: rest -> Some (List.fold_left min first rest)

let entropic_oscillation_interval_sec = 600

let entropic_oscillation_probability_percent = 5

let should_inject_entropic_oscillation
    ~since_last_scheduled_autonomous ~draw_percent =
  since_last_scheduled_autonomous >= entropic_oscillation_interval_sec
  && draw_percent >= 0
  && draw_percent < entropic_oscillation_probability_percent

let keeper_cycle_decision
    ?(provider_cooldown_remaining_sec =
        provider_cooldown_remaining_sec_for_cascade)
    ~(meta : keeper_meta)
    (observation : world_observation) =
  let reactive_triggers =
    [
      (if observation.pending_mentions <> [] then Some Mention_pending else None);
      (if observation.pending_board_events <> [] then Some Board_event_pending else None);
      (if observation.pending_scope_messages <> [] then Some Scope_message_pending else None);
    ]
    |> List.filter_map Fun.id
  in
  let blocked_channel =
    match reactive_triggers with
    | _ :: _ -> Reactive
    | [] -> Scheduled_autonomous
  in
  let blocked reason =
    {
      should_run = false;
      channel = blocked_channel;
      verdict = Skip { reasons = (reason, []) };
      since_last_scheduled_autonomous = None;
      effective_cooldown = None;
      task_reactive_cooldown = None;
      idle_gate_sec = None;
    }
  in
  if meta.paused then
    blocked Keeper_paused
  else if Keeper_approval_queue.has_pending_for_keeper ~keeper_name:meta.name then
    blocked Approval_pending
  else
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
          max task_cooldown_floor
            (effective_cooldown / max 1 task_cooldown_divisor)
        in
        let has_actionable_tasks =
          observation.claimable_task_count > 0 || observation.failed_task_count > 0
        in
        let idle_gate_elapsed = observation.idle_seconds >= idle_gate_sec in
        let cooldown_elapsed =
          since_last_scheduled_autonomous >= effective_cooldown
        in
        let backlog_elapsed =
          has_actionable_tasks
          && since_last_scheduled_autonomous >= task_reactive_cooldown
        in
        let backlog_fresh =
          has_actionable_tasks
          && observation.backlog_updated_since_last_scheduled_autonomous
        in
        let proactive_work_ready =
          proactive_work_signal_present ~meta observation
        in
        (* Phase 1 — Bootstrap bypass: keeper has never completed a scheduled
           autonomous turn (last_ts <= 0.0, so since_last = max_int). Fire
           immediately without requiring work signals or time gates, so a
           fresh keeper always gets at least one warm-up turn regardless of
           observable backlog state.  This breaks the "no signal → no turn →
           no signal" bootstrap deadlock. *)
        let is_bootstrap = since_last_scheduled_autonomous = max_int in
        (* Phase 2 — Minimum proactive cadence: even with no observable work
           signals, fire a housekeeping turn once the minimum interval has
           elapsed.  Default: 900s (15 min).  Prevents permanent silence when
           external events never arrive and decouples liveness from signal
           availability.  Controlled by MASC_KEEPER_PROACTIVE_MIN_INTERVAL_SEC
           / keeper.proactive.min_interval_sec. *)
        let proactive_min_interval_sec =
          Keeper_config.keeper_proactive_min_interval_sec ()
        in
        let min_interval_elapsed =
          (* Exclude the bootstrap case: when is_bootstrap is true, the bootstrap
             bypass already fires the turn and emits Never_started.  Using
             min_interval_elapsed here would also set Min_interval_elapsed on a
             bootstrap turn, which is misleading — the two paths are mutually
             exclusive by design. *)
          not is_bootstrap
          && since_last_scheduled_autonomous >= proactive_min_interval_sec
        in
        (* Backlog bypass: when actionable tasks exist and task_reactive_cooldown
           has elapsed, skip the idle_gate check. task_reactive_cooldown is
           already a (shorter) subdivision of idle_gate; requiring idle_gate_elapsed
           on top defeats its purpose. Without this bypass, keepers ignore
           unclaimed work for idle_gate seconds even when the backlog signal
           is ready to fire. Ref: #7226 claim-first + idle_gate observation. *)
        let should_oscillate =
          (not min_interval_elapsed)
          && should_inject_entropic_oscillation
               ~since_last_scheduled_autonomous
               ~draw_percent:(Random.int 100)
        in
        let should_run =
          is_bootstrap
          || should_oscillate
          || min_interval_elapsed
          || (proactive_work_ready
              && (backlog_fresh
                  || backlog_elapsed
                  || (idle_gate_elapsed && cooldown_elapsed)))
        in
        let cascade_name = cascade_name_of_meta meta in
        let provider_cooldown_remaining_sec =
          if should_run
          then
            provider_cooldown_remaining_sec
              ~cascade_name:(Keeper_cascade_profile.runtime_name_of_string cascade_name)
          else None
        in
        let provider_cooldown_fail_open =
          match provider_cooldown_remaining_sec with
          | Some _ ->
              fallback_cascade_for_provider_cooldown
                ~base_cascade:cascade_name
                ~effective_cascade:cascade_name
          | None -> None
        in
        let verdict =
          if
            Option.is_some provider_cooldown_remaining_sec
            && Option.is_none provider_cooldown_fail_open
          then
            Skip {
              reasons = (
                Provider_cooldown_pending {
                  remaining_sec =
                    Option.value ~default:0 provider_cooldown_remaining_sec;
                },
                [] );
            }
          else if should_run then
            let run_reasons =
              [
                Some Scheduled_autonomous_turn;
                (if should_oscillate then Some Entropic_oscillation else None);
                (if is_bootstrap
                 then Some Never_started else None);
                (if min_interval_elapsed
                 then Some Min_interval_elapsed else None);
                (if idle_gate_elapsed
                 then Some (Idle_cooldown_elapsed
                              { idle_sec = observation.idle_seconds;
                                cooldown = effective_cooldown }) else None);
                (if cooldown_elapsed then Some Cooldown_elapsed else None);
                (if has_actionable_tasks
                 then Some (Task_backlog
                              { unclaimed = observation.claimable_task_count;
                                failed = observation.failed_task_count }) else None);
                (if backlog_fresh || backlog_elapsed
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
                (* Structurally unreachable: the synthetic Scheduled_autonomous_turn
                   tag is always added first, so the list is never empty.
                   Defensive: log warning and fall through to skip so that
                   should_run (derived below) stays consistent with verdict. *)
                Prometheus.inc_counter
                  Keeper_metrics.metric_keeper_observation_query_failures
                  ~labels:[("operation", Observation_query_operation.(to_label Empty_run_reasons))]
                  ();
                Log.Keeper.warn
                  "unreachable: should_run=true but run_reasons is empty";
                Skip { reasons = (No_signal, []) }
          else
            let skip_reasons =
              [
                (if not proactive_work_ready then Some No_signal else None);
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

let unified_turn_decision = keeper_cycle_decision

let should_run_keeper_cycle ~(meta : keeper_meta) (observation : world_observation) =
  (keeper_cycle_decision ~meta observation).should_run

let should_run_unified_turn = should_run_keeper_cycle
