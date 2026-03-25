(** Keeper_world_observation — Structured world state for unified keeper turns.

    Extracts and normalizes observation signals from room state, keeper meta,
    and context so the unified prompt and turn runner consume a single snapshot.

    @since Unified Keeper Loop *)

open Keeper_types
open Keeper_memory
open Keeper_exec_context

type world_observation = {
  pending_mentions : (string * string) list;
  pending_board_events : string list;
  idle_seconds : int;
  active_goals : string list;
  continuity_summary : string;
  worktree_change_summary : string option;
  context_ratio : float;
  economic_pressure : Agent_economy.pressure_mode;
  unclaimed_task_count : int;
  failed_task_count : int;
  active_agent_count : int;
  triage_triggers : string;
  autonomy_trigger : string option;
  allow_noop : bool;
}

type board_signal_match = {
  explicit_mention : bool;
  matched_targets : string list;
  score : int;
}

(** Collect pending direct mentions from joined rooms since last cursor. *)
let collect_pending_mentions ~(config : Room.config) ~(meta : keeper_meta)
    : (string * string) list =
  let targets =
    if meta.mention_targets <> [] then meta.mention_targets else [ meta.name ]
  in
  let batch_limit = Keeper_config.keeper_batch_limit () in
  List.fold_left
    (fun acc room_id ->
      let since_seq = room_cursor_for meta room_id in
      let messages =
        try
          Room.get_messages_raw_in_room config ~room_id ~since_seq
            ~limit:batch_limit
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | _ -> []
      in
      List.fold_left
        (fun inner_acc (msg : Types.message) ->
          if msg.from_agent = meta.agent_name then inner_acc
          else if not (exact_direct_mention_present ~targets msg.content) then
            inner_acc
          else (msg.from_agent, msg.content) :: inner_acc)
        acc messages)
    [] meta.joined_room_ids
  |> List.rev

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
    let base = max meta.usage.last_turn_ts meta.proactive.last_ts in
    if base > 0.0 then base else created_ts
  in
  if activity_ts <= 0.0 then 0
  else int_of_float (max 0.0 (now_ts -. activity_ts))

let board_relevance_threshold = 4

let nontrivial_token_overlap (left : string list) (right : string list) : int =
  let left = dedupe_keep_order left in
  let right = dedupe_keep_order right in
  List.fold_left (fun acc token -> if List.mem token right then acc + 1 else acc) 0 left

let board_signal_text (signal : Board_dispatch.keeper_board_signal) =
  String.concat "\n"
    (List.filter (fun part -> String.trim part <> "")
       [
         signal.title;
         signal.content;
         (match signal.hearth with Some hearth -> hearth | None -> "");
       ])

let board_signal_match
    ~(continuity_summary : string)
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
             &&
             try
               let _ = Str.search_forward (Str.regexp_string needle) haystack 0 in
               true
             with Not_found -> false)
    in
    if matched_targets <> [] then
      { explicit_mention = true; matched_targets; score = 100 }
    else
      let signal_tokens = similarity_tokens haystack in
      let active_goal_tokens =
        meta.active_goal_ids |> List.concat_map similarity_tokens
      in
      let goal_tokens =
        [ meta.goal; meta.short_goal; meta.mid_goal; meta.long_goal; meta.instructions ]
        |> List.concat_map similarity_tokens
      in
      let continuity_tokens =
        continuity_summary |> similarity_tokens
      in
      let active_goal_score = nontrivial_token_overlap signal_tokens active_goal_tokens * 6 in
      let goal_score = nontrivial_token_overlap signal_tokens goal_tokens * 4 in
      let continuity_score = nontrivial_token_overlap signal_tokens continuity_tokens * 2 in
      let score = active_goal_score + goal_score + continuity_score in
      { explicit_mention = false; matched_targets = []; score }

(** Read context ratio from checkpoint if available. *)
let read_context_ratio ~(config : Room.config) ~(meta : keeper_meta) : float =
  try
    let cascade_models = Oas_model_resolve.models_of_cascade_name meta.cascade_name in
    let primary_max_context =
      Oas_model_resolve.resolve_primary_max_context cascade_models
    in
    let base_dir = session_base_dir config in
    let _session, ctx_opt =
      load_context_from_checkpoint ~trace_id:meta.trace_id
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
    let cascade_models = Oas_model_resolve.models_of_cascade_name meta.cascade_name in
    let primary_max_context =
      Oas_model_resolve.resolve_primary_max_context cascade_models
    in
    let base_dir = session_base_dir config in
    let _session, ctx_opt =
      load_context_from_checkpoint ~trace_id:meta.trace_id
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
let bootstrap_window_sec = 300.0

(** Collect recent board activity using cursor-based tracking.
    Cursor state lives in Keeper_registry (board_cursor_ts field).
    Returns (event summaries, new post count, mention count). *)
let collect_board_events ~(base_path : string) ~(continuity_summary : string)
    ~(meta : keeper_meta) : string list * int * int =
  try
    let since_ts =
      let ts = Keeper_registry.get_board_cursor_ts ~base_path meta.name in
      if ts > 0.0 then ts
      else Time_compat.now () -. bootstrap_window_sec
    in
    let cursor_watermark = Time_compat.now () in
    let posts =
      Board_dispatch.list_posts ~sort_by:Board_dispatch.Updated ~limit:20 ()
    in
    Keeper_registry.set_board_cursor_ts ~base_path meta.name cursor_watermark;
    let recent =
      List.filter (fun (p : Board.post) -> p.updated_at >= since_ts) posts
      |> List.filter (fun (p : Board.post) ->
             let signal : Board_dispatch.keeper_board_signal =
               {
                 kind = Board_dispatch.Board_post_created;
                 post_id = Board.Post_id.to_string p.id;
                 author = Board.Agent_id.to_string p.author;
                 title = p.title;
                 content = p.content;
                 hearth = p.hearth;
               }
             in
             let matched =
               board_signal_match ~continuity_summary ~meta ~signal
             in
             matched.explicit_mention || matched.score >= board_relevance_threshold)
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
                 try
                   let _ =
                     Str.search_forward (Str.regexp_string needle) haystack 0
                   in
                   true
                 with Not_found -> false)
               targets)
           recent)
    in
    let events =
      let capped =
        if List.length recent > 5 then
          List.filteri (fun i _ -> i < 5) recent
        else recent
      in
      List.map
        (fun (p : Board.post) ->
          Printf.sprintf "[%s] %s: %s"
            (Board.Agent_id.to_string p.author)
            p.title
            (short_preview ~max_len:80 p.content))
        capped
    in
    (events, new_count, mention_count)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn "board event collection failed: %s"
      (Printexc.to_string exn);
    ([], 0, 0)

let observe ~(pending_board_events : string list option) ~(config : Room.config)
    ~(meta : keeper_meta) :
    world_observation =
  let pending_mentions = collect_pending_mentions ~config ~meta in
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
  let pending_board_events =
    match pending_board_events with
    | Some events -> events
    | None ->
        let events, _board_new_count, _board_mention_count =
          collect_board_events ~base_path:config.base_path ~meta ~continuity_summary
        in
        events
  in
  let since_last_proactive =
    if meta.proactive.last_ts <= 0.0 then max_int
    else int_of_float (max 0.0 (Time_compat.now () -. meta.proactive.last_ts))
  in
  let proactive_due =
    meta.proactive.enabled
    && idle_seconds >= meta.proactive.idle_sec
    && since_last_proactive >= meta.proactive.cooldown_sec
  in
  let autonomy_trigger =
    if pending_mentions <> [] then Some "mention_reactive"
    else if pending_board_events <> [] then Some "board_reactive"
    else if failed_task_count > 0 || unclaimed_task_count > 0 then Some "task_reactive"
    else if proactive_due then Some "proactive_idle"
    else None
  in
  {
    pending_mentions;
    pending_board_events;
    idle_seconds;
    active_goals = meta.active_goal_ids;
    continuity_summary;
    worktree_change_summary;
    context_ratio;
    economic_pressure;
    unclaimed_task_count;
    failed_task_count;
    active_agent_count;
    triage_triggers = meta.last_triage_triggers;
    autonomy_trigger;
    allow_noop = Option.is_none autonomy_trigger;
  }

let should_run_unified_turn ~(meta : keeper_meta) (observation : world_observation) =
  match observation.autonomy_trigger with
  | Some _ -> true
  | None ->
      meta.proactive.enabled
      && observation.idle_seconds >= meta.proactive.idle_sec
