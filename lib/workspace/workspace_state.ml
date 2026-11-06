(** Workspace State - Workspace state I/O and sequence.

    After responsibility split (Epic #7261 Step 5), this module retains:
    - State read/write/update with file locking
    - Sequence counter (next_seq)
    - State recovery (recover_workspace_state)
    - Shared string utilities (String_util.option_trim, normalized_string_list)

    Extracted owner modules:
    - Workspace_bootstrap: default_workspace_state, reconcile_message_seq
    - Workspace_identity: generate_session_id, get_hostname, get_tty, resolve_agent_name
    - Workspace_task_id: task_id_to_int, archive management, next_task_number
    - Workspace_backlog: read_backlog, write_backlog
    - Workspace_broadcast: broadcast, emit_message_activity *)

open Masc_domain
open Workspace_utils

(* ============================================ *)
(* Shared String Utilities                      *)
(* ============================================ *)

let normalized_string_list values =
  let module String_set = Set.Make (String) in
  let _seen, rev_acc =
    List.fold_left
      (fun (seen, acc) raw ->
         match String_util.trim_nonempty raw with
         | None -> seen, acc
         | Some value ->
           if String_set.mem value seen
           then seen, acc
           else String_set.add value seen, value :: acc)
      (String_set.empty, [])
      values
  in
  List.rev rev_acc

(* ============================================ *)
(* State Recovery                               *)
(* ============================================ *)

let recover_active_agent_name = function
  | `String name -> String_util.trim_nonempty name
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
  }

(* ============================================ *)
(* State Read / Write / Update                  *)
(* ============================================ *)

let write_state config state =
  let json = workspace_state_to_yojson state in
  write_json config (state_path config) json

let raw_snippet_max_bytes = 500

let read_present_state config json =
  match workspace_state_of_yojson json with
  | Ok state -> state
  | Error msg ->
      let repaired = recover_workspace_state config json in
      let raw_snippet =
        let s = Yojson.Safe.to_string json in
        if String.length s <= raw_snippet_max_bytes then s
        else String_util.utf8_prefix ~max_bytes:raw_snippet_max_bytes s ^ "...(truncated)"
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

(* [state.json] is what [is_initialized] reads, so a read never creates it:
   a workspace without one gets the declared default, unwritten. A document
   that is there but does not decode is repaired and written back. *)
let read_state config =
  match read_json_doc config (state_path config) with
  | Ok None -> Workspace_bootstrap.default_workspace_state config
  | Ok (Some json) -> read_present_state config json
  | Error error ->
      Log.Misc.warn "read_state: %s" (json_doc_error_to_string error);
      read_present_state config (`Assoc [])

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

(* Broadcast moved to Workspace_broadcast (exported via Workspace aggregator).
   Cannot re-export here — broadcast depends on next_seq, which would
   create a circular dep workspace_state <-> workspace_broadcast. *)

let take = List.take
