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

(** Per-keeper cursor for board event collection.
    Tracks the last check timestamp so no posts are missed between heartbeats.
    In-memory only — first run after restart uses a 300s bootstrap window (300s). *)
let board_cursors_mu = Eio.Mutex.create ()
let board_cursors : (string, float) Hashtbl.t = Hashtbl.create 8

let bootstrap_window_sec = 300.0

(* TODO: wire to keeper_down / succession to prevent stale cursor accumulation *)
let reset_board_cursor name =
  Eio.Mutex.use_rw ~protect:true board_cursors_mu (fun () ->
    Hashtbl.remove board_cursors name) [@@warning "-32"]

(** Collect recent board activity using cursor-based tracking.
    Returns (event summaries, new post count, mention count). *)
let collect_board_events ~(meta : keeper_meta) : string list * int * int =
  try
    let since_ts =
      Eio.Mutex.use_ro board_cursors_mu (fun () ->
        match Hashtbl.find_opt board_cursors meta.name with
        | Some ts -> ts
        | None -> Time_compat.now () -. bootstrap_window_sec)
    in
    (* Capture cursor watermark BEFORE fetch to avoid blind window:
       posts created between fetch and cursor update would be missed. *)
    let cursor_watermark = Time_compat.now () in
    let posts =
      Board_dispatch.list_posts ~sort_by:Board_dispatch.Recent ~limit:20 ()
    in
    (* Update cursor AFTER successful read to avoid losing events on I/O failure *)
    Eio.Mutex.use_rw ~protect:true board_cursors_mu (fun () ->
      Hashtbl.replace board_cursors meta.name cursor_watermark);
    let recent =
      List.filter (fun (p : Board.post) -> p.created_at >= since_ts) posts
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

let observe ~(config : Room.config) ~(meta : keeper_meta) : world_observation =
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
  let pending_board_events, _board_new_count, _board_mention_count =
    collect_board_events ~meta
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
  }
