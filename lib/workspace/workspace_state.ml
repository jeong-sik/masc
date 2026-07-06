(** Workspace State - Workspace state I/O, sequence, and pause.

    After responsibility split (Epic #7261 Step 5), this module retains:
    - State read/write/update with file locking
    - Sequence counter (next_seq)
    - Pause state (is_paused, pause_info)
    - State recovery (recover_workspace_state)
    - Shared string utilities (String_util.option_trim, normalized_string_list)

    Extracted owner modules:
    - Workspace_bootstrap: default_workspace_state, ensure_workspace_bootstrap
    - Workspace_identity: generate_session_id, get_hostname, get_tty, resolve_agent_name
    - Workspace_task_id: task_id_to_int, archive management, next_task_number
    - Workspace_backlog: read_backlog, write_backlog
    - Workspace_broadcast: broadcast, emit_message_activity *)

open Masc_domain
open Workspace_utils
open Result.Syntax

(* ============================================ *)
(* Shared String Utilities                      *)
(* ============================================ *)

let normalized_string_list values =
  let seen = Hashtbl.create (List.length values) in
  values
  |> List.filter_map (fun value -> String_util.option_trim (Some value))
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
  | `String name -> String_util.option_trim (Some name)
  | _ -> None

let recover_workspace_state config json =
  let defaults = Workspace_bootstrap.default_workspace_state config in
  let active_agents =
    match Safe_ops.json_list_opt "active_agents" json with
    | Some agents -> List.filter_map recover_active_agent_name agents
    | None -> defaults.active_agents
  in
  {
    protocol_version =
      String_util.option_trim (Safe_ops.json_string_opt "protocol_version" json)
      |> Option.value ~default:defaults.protocol_version;
    project =
      String_util.option_trim (Safe_ops.json_string_opt "project" json)
      |> Option.value ~default:defaults.project;
    started_at =
      String_util.option_trim (Safe_ops.json_string_opt "started_at" json)
      |> Option.value ~default:defaults.started_at;
    message_seq = Safe_ops.json_int ~default:defaults.message_seq "message_seq" json;
    active_agents;
    paused = Safe_ops.json_bool ~default:defaults.paused "paused" json;
    pause_reason =
      String_util.option_trim (Safe_ops.json_string_opt "pause_reason" json);
    paused_by =
      String_util.option_trim (Safe_ops.json_string_opt "paused_by" json);
    paused_at =
      String_util.option_trim (Safe_ops.json_string_opt "paused_at" json);
    search_strategy_default =
      (match
         String_util.option_trim
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

let write_state_result config state =
  let json = workspace_state_to_yojson state in
  write_json_result config (state_path config) json

let write_state config state =
  match write_state_result config state with
  | Ok () -> ()
  | Error error -> raise (Sys_error error)

type read_state_error =
  | State_read_failed of string
  | State_repair_write_failed of
      { decode_error : string
      ; write_error : string
      ; recovered_state : Masc_domain.workspace_state
      }

let read_state_error_to_string = function
  | State_read_failed error ->
      Printf.sprintf "workspace_state read failed: %s" error
  | State_repair_write_failed { decode_error; write_error; _ } ->
      Printf.sprintf
        "workspace_state repair write failed after decode error (%s): %s"
        decode_error write_error

type read_state_status =
  | State_authoritative
  | State_recovered_unpersisted
  | State_default_from_read_error

let read_state_status_to_string = function
  | State_authoritative -> "authoritative"
  | State_recovered_unpersisted -> "recovered_unpersisted"
  | State_default_from_read_error -> "default_from_read_error"

type read_state_snapshot =
  { state : Masc_domain.workspace_state
  ; status : read_state_status
  ; read_errors : string list
  }

let workspace_state_raw_snippet json =
  let s = Yojson.Safe.to_string json in
  if String.length s <= 500 then s else String.sub s 0 500 ^ "...(truncated)"

let read_state_result config =
  let* json =
    read_json_result config (state_path config)
    |> Result.map_error (fun error -> State_read_failed error)
  in
  match workspace_state_of_yojson json with
  | Ok state -> Ok state
  | Error msg ->
      let repaired = recover_workspace_state config json in
      Log.Misc.warn
        "read_state: deserialization failed (%s), raw=%s — repairing and rewriting"
        msg (workspace_state_raw_snippet json);
      (match write_state_result config repaired with
       | Ok () -> Ok repaired
       | Error error ->
           Error
             (State_repair_write_failed
                { decode_error = msg; write_error = error; recovered_state = repaired }))

let read_state_snapshot config =
  match read_state_result config with
  | Ok state -> { state; status = State_authoritative; read_errors = [] }
  | Error (State_repair_write_failed { recovered_state; _ } as error) ->
      let message = read_state_error_to_string error in
      Log.Misc.warn "read_state: %s" message;
      { state = recovered_state
      ; status = State_recovered_unpersisted
      ; read_errors = [ message ]
      }
  | Error (State_read_failed _ as error) ->
      let message = read_state_error_to_string error in
      Log.Misc.warn "read_state: %s" message;
      { state = Workspace_bootstrap.default_workspace_state config
      ; status = State_default_from_read_error
      ; read_errors = [ message ]
      }

let read_state config =
  (read_state_snapshot config).state

let update_state_result config f =
  with_file_lock config (state_path config) (fun () ->
    let snapshot = read_state_snapshot config in
    match snapshot.status with
    | State_default_from_read_error ->
      Error (String.concat "; " snapshot.read_errors)
    | State_authoritative | State_recovered_unpersisted ->
      let new_state = f snapshot.state in
      (match write_state_result config new_state with
       | Ok () -> Ok new_state
       | Error msg -> Error msg)
  )

let update_state config f =
  match update_state_result config f with
  | Ok state -> state
  | Error msg -> raise (Sys_error msg)

(* ============================================ *)
(* Sequence Numbers                             *)
(* ============================================ *)

let next_seq config =
  let state = update_state config (fun s -> { s with message_seq = s.message_seq + 1 }) in
  state.message_seq

(* ============================================ *)
(* Pause State                                  *)
(* ============================================ *)

let is_paused_result config =
  let snapshot = read_state_snapshot config in
  match snapshot.status with
  | State_default_from_read_error -> Error (String.concat "; " snapshot.read_errors)
  | State_authoritative | State_recovered_unpersisted -> Ok snapshot.state.paused

let is_paused config =
  match is_paused_result config with
  | Ok paused -> paused
  | Error msg ->
    Log.Workspace.error "is_paused failed: %s" msg;
    false

let pause_info_result config =
  let snapshot = read_state_snapshot config in
  match snapshot.status with
  | State_default_from_read_error -> Error (String.concat "; " snapshot.read_errors)
  | State_authoritative | State_recovered_unpersisted ->
    let state = snapshot.state in
    if state.paused
    then Ok (Some (state.paused_by, state.pause_reason, state.paused_at))
    else Ok None

let pause_info config =
  match pause_info_result config with
  | Ok info -> info
  | Error msg ->
    Log.Workspace.error "pause_info failed: %s" msg;
    None

(* Broadcast moved to Workspace_broadcast (exported via Workspace aggregator).
   Cannot re-export here — broadcast depends on next_seq, which would
   create a circular dep workspace_state <-> workspace_broadcast. *)

(* ============================================ *)
(* Re-exports: Zombie Detection (Resilience)    *)
(* ============================================ *)

let heartbeat_timeout_seconds = Workspace_resilience.default_zombie_threshold
let parse_iso_time_opt = Workspace_resilience.Time.parse_iso8601_opt

let parse_iso_time iso_str =
  match parse_iso_time_opt iso_str with
  | Some t -> t
  | None -> Workspace_resilience.Time.now ()

let is_zombie_agent ?agent_type ?agent_meta ~agent_name last_seen_iso =
  Workspace_resilience.Zombie.is_zombie_for_agent
    ?agent_type
    ?agent_meta
    ~agent_name
    last_seen_iso

let take = List.take
