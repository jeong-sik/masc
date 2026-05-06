(** Coord State - Coordination state I/O, sequence, and pause.

    After responsibility split (Epic #7261 Step 5), this module retains:
    - State read/write/update with file locking
    - Sequence counter (next_seq)
    - Pause state (is_paused, pause_info)
    - State recovery (recover_room_state)
    - Shared string utilities (non_empty_string_opt, normalized_string_list)

    Extracted to separate modules:
    - Coord_bootstrap: default_room_state, ensure_room_bootstrap
    - Coord_identity: generate_session_id, get_hostname, get_tty, resolve_agent_name
    - Coord_task_id: task_id_to_int, archive management, next_task_number
    - Coord_backlog: read_backlog, write_backlog
    - Coord_broadcast: broadcast, emit_message_activity *)

open Masc_domain
open Coord_utils

(* ============================================ *)
(* Re-exports (backward compat)                 *)
(* ============================================ *)

let default_room_state = Coord_bootstrap.default_room_state
let ensure_room_bootstrap = Coord_bootstrap.ensure_room_bootstrap
let generate_session_id = Coord_identity.generate_session_id
let get_hostname = Coord_identity.get_hostname
let get_tty = Coord_identity.get_tty
let resolve_agent_name = Coord_identity.resolve_agent_name
let task_id_to_int = Coord_task_id.task_id_to_int
let read_archive_task_ids = Coord_task_id.read_archive_task_ids
let append_archive_tasks = Coord_task_id.append_archive_tasks
let next_task_number = Coord_task_id.next_task_number
let read_backlog_r = Coord_backlog.read_backlog_r
let read_backlog = Coord_backlog.read_backlog
let write_backlog = Coord_backlog.write_backlog

(* ============================================ *)
(* Shared String Utilities                      *)
(* ============================================ *)

let non_empty_string_opt = function
  | Some value ->
      let value = String.trim value in
      if value = "" then None else Some value
  | None -> None

let normalized_string_list values =
  let seen = Hashtbl.create (List.length values) in
  values
  |> List.filter_map (fun value -> non_empty_string_opt (Some value))
  |> List.filter (fun value ->
         if Hashtbl.mem seen value then
           false
         else (
           Hashtbl.add seen value ();
           true))

(* ============================================ *)
(* State Recovery                               *)
(* ============================================ *)

let recover_active_agent_name = function
  | `String name -> non_empty_string_opt (Some name)
  | `Assoc _ as json ->
      (match non_empty_string_opt (Safe_ops.json_string_opt "name" json) with
       | Some name -> Some name
       | None ->
           non_empty_string_opt (Safe_ops.json_string_opt "agent_name" json))
  | _ -> None

let recover_room_state config json =
  let defaults = default_room_state config in
  let active_agents =
    match Safe_ops.json_list_opt "active_agents" json with
    | Some agents -> List.filter_map recover_active_agent_name agents
    | None -> defaults.active_agents
  in
  {
    protocol_version =
      non_empty_string_opt (Safe_ops.json_string_opt "protocol_version" json)
      |> Option.value ~default:defaults.protocol_version;
    project =
      non_empty_string_opt (Safe_ops.json_string_opt "project" json)
      |> Option.value ~default:defaults.project;
    started_at =
      non_empty_string_opt (Safe_ops.json_string_opt "started_at" json)
      |> Option.value ~default:defaults.started_at;
    message_seq = Safe_ops.json_int ~default:defaults.message_seq "message_seq" json;
    active_agents;
    paused = Safe_ops.json_bool ~default:defaults.paused "paused" json;
    pause_reason =
      non_empty_string_opt (Safe_ops.json_string_opt "pause_reason" json);
    paused_by =
      non_empty_string_opt (Safe_ops.json_string_opt "paused_by" json);
    paused_at =
      non_empty_string_opt (Safe_ops.json_string_opt "paused_at" json);
    search_strategy_default =
      (match
         non_empty_string_opt
           (Safe_ops.json_string_opt "search_strategy_default" json)
       with
       | Some value -> Some value
       | None -> defaults.search_strategy_default);
    speculation_enabled =
      Safe_ops.json_bool ~default:defaults.speculation_enabled
        "speculation_enabled" json;
    speculation_budget =
      Safe_ops.json_int_opt "speculation_budget" json;
  }

(* ============================================ *)
(* State Read / Write / Update                  *)
(* ============================================ *)

let write_state config state =
  let json = room_state_to_yojson state in
  write_json config (state_path config) json

let read_state config =
  let json = read_json config (state_path config) in
  match room_state_of_yojson json with
  | Ok state -> state
  | Error msg ->
      let repaired = recover_room_state config json in
      let raw_snippet =
        let s = Yojson.Safe.to_string json in
        if String.length s <= 500 then s
        else String.sub s 0 500 ^ "...(truncated)"
      in
      Log.Misc.warn
        "read_state: deserialization failed (%s), raw=%s — repairing and rewriting"
        msg raw_snippet;
      (try write_state config repaired
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Misc.warn "read_state: failed to persist repaired state: %s"
             (Printexc.to_string exn));
      repaired

let update_state config f =
  with_file_lock config (state_path config) (fun () ->
    let state = read_state config in
    let new_state = f state in
    write_state config new_state;
    new_state
  )

(* ============================================ *)
(* Sequence Numbers                             *)
(* ============================================ *)

let next_seq config =
  let state = update_state config (fun s -> { s with message_seq = s.message_seq + 1 }) in
  state.message_seq

(* ============================================ *)
(* Pause State                                  *)
(* ============================================ *)

let is_paused config =
  let state = read_state config in
  state.paused

let pause_info config =
  let state = read_state config in
  if state.paused then
    Some (state.paused_by, state.pause_reason, state.paused_at)
  else
    None

(* Broadcast moved to Coord_broadcast (exported via Coord aggregator).
   Cannot re-export here — broadcast depends on next_seq, which would
   create a circular dep room_state <-> room_broadcast. *)

(* ============================================ *)
(* Re-exports: Zombie Detection (Resilience)    *)
(* ============================================ *)

let heartbeat_timeout_seconds = Coord_resilience.default_zombie_threshold
let parse_iso_time_opt = Coord_resilience.Time.parse_iso8601_opt

let parse_iso_time iso_str =
  match parse_iso_time_opt iso_str with
  | Some t -> t
  | None -> Coord_resilience.Time.now ()

let is_zombie_agent ?agent_type ~agent_name last_seen_iso =
  Coord_resilience.Zombie.is_zombie_for_agent
    ?agent_type
    ~agent_name
    last_seen_iso

let take n xs =
  if n <= 0 then []
  else
    let rec loop i acc = function
      | [] -> List.rev acc
      | _ when i <= 0 -> List.rev acc
      | x :: rest -> loop (i - 1) (x :: acc) rest
    in
    loop n [] xs
