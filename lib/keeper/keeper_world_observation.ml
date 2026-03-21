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
  autonomy_level : Keeper_autonomy.autonomy_level;
  continuity_summary : string;
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
    let base = max meta.last_turn_ts meta.last_proactive_ts in
    if base > 0.0 then base else created_ts
  in
  if activity_ts <= 0.0 then 0
  else int_of_float (max 0.0 (now_ts -. activity_ts))

(** Read context ratio from checkpoint if available. *)
let read_context_ratio ~(config : Room.config) ~(meta : keeper_meta) : float =
  try
    let primary_model =
      match
        Model_spec.available_model_specs_of_strings meta.models
      with
      | p :: _ -> p
      | [] -> Model_spec.default_local_model_spec ()
    in
    let base_dir = session_base_dir config in
    let _session, ctx_opt =
      load_context_from_checkpoint ~trace_id:meta.trace_id
        ~primary_model_max_tokens:primary_model.max_context ~base_dir
    in
    match ctx_opt with
    | Some c -> Context_manager.context_ratio c
    | None -> 0.0
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> 0.0

(** Read continuity summary from checkpoint messages or meta fallback. *)
let read_continuity_summary ~(config : Room.config) ~(meta : keeper_meta)
    : string =
  try
    let primary_model =
      match
        Model_spec.available_model_specs_of_strings meta.models
      with
      | p :: _ -> p
      | [] -> Model_spec.default_local_model_spec ()
    in
    let base_dir = session_base_dir config in
    let _session, ctx_opt =
      load_context_from_checkpoint ~trace_id:meta.trace_id
        ~primary_model_max_tokens:primary_model.max_context ~base_dir
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

let observe ~(config : Room.config) ~(meta : keeper_meta) : world_observation =
  let pending_mentions = collect_pending_mentions ~config ~meta in
  let unclaimed_task_count, failed_task_count =
    read_backlog_counts ~config
  in
  let active_agent_count = count_active_agents ~config in
  let idle_seconds = compute_idle_seconds ~meta in
  let autonomy_level =
    Keeper_contract.parse_autonomy_level meta.autonomy_level
    |> Option.value ~default:Keeper_autonomy.L1_Reactive
  in
  let context_ratio = read_context_ratio ~config ~meta in
  let continuity_summary = read_continuity_summary ~config ~meta in
  let economic_pressure =
    Agent_economy.economic_pressure ~base_path:config.base_path
      ~agent_name:meta.name
  in
  {
    pending_mentions;
    pending_board_events = [];
    idle_seconds;
    active_goals = meta.active_goal_ids;
    autonomy_level;
    continuity_summary;
    context_ratio;
    economic_pressure;
    unclaimed_task_count;
    failed_task_count;
    active_agent_count;
    triage_triggers = meta.last_triage_triggers;
  }
