(** Workspace State - Workspace state I/O and sequence.

    After responsibility split (Epic #7261 Step 5), this module retains:
    - State read/write/update with file locking
    - Sequence counter (next_seq)
    - State observation and recovery (observe_state, update_state)
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

let recover_workspace_state ~defaults json =
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
(* State Observation (read only)                *)
(* ============================================ *)

type state_read_fault =
  | State_document_fault of json_doc_error
  | State_schema_fault of
      { reason : string
      ; document : Yojson.Safe.t
      }

type state_observation =
  | State_absent of workspace_state
  | State_decoded of workspace_state
  | State_recovered of
      { state : workspace_state
      ; fault : state_read_fault
      }

let state_read_fault_to_string = function
  | State_document_fault error -> json_doc_error_to_string error
  | State_schema_fault { reason; document = _ } -> "schema mismatch: " ^ reason

let state_of_observation = function
  | State_absent state | State_decoded state | State_recovered { state; fault = _ } ->
    state

let state_observation_to_yojson = function
  | State_absent _ -> `Assoc [ "outcome", `String "absent" ]
  | State_decoded _ -> `Assoc [ "outcome", `String "decoded" ]
  | State_recovered { state = _; fault } ->
    `Assoc
      [ "outcome", `String "recovered"
      ; "fault", `String (state_read_fault_to_string fault)
      ]

(* Deciding what an undecodable document means takes the document and the
   declared defaults, and nothing that can write: the store is not an
   argument, so this step cannot put a repaired value back (#51419).
   [defaults] is a thunk because computing it lists the message store, which
   a document that decodes never needs. *)
let observe_state_doc ~defaults = function
  | Ok None -> State_absent (defaults ())
  | Ok (Some document) ->
    (match workspace_state_of_yojson document with
     | Ok state -> State_decoded state
     | Error reason ->
       State_recovered
         { state = recover_workspace_state ~defaults:(defaults ()) document
         ; fault = State_schema_fault { reason; document }
         })
  | Error error ->
    State_recovered { state = defaults (); fault = State_document_fault error }

type state_file_stamp =
  { sf_dev : int
  ; sf_ino : int
  ; sf_size : int
  ; sf_mtime : float
  ; sf_ctime : float
  ; sf_perm : int
  ; sf_uid : int
  ; sf_gid : int
  }

let equal_state_file_stamp a b =
  a.sf_dev = b.sf_dev
  && a.sf_ino = b.sf_ino
  && a.sf_size = b.sf_size
  && Float.equal a.sf_mtime b.sf_mtime
  && Float.equal a.sf_ctime b.sf_ctime
  && a.sf_perm = b.sf_perm
  && a.sf_uid = b.sf_uid
  && a.sf_gid = b.sf_gid

let stat_state_file_opt path =
  match Unix.lstat path with
  | stat when stat.Unix.st_kind = Unix.S_REG ->
    Some
      { sf_dev = stat.st_dev
      ; sf_ino = stat.st_ino
      ; sf_size = stat.st_size
      ; sf_mtime = stat.st_mtime
      ; sf_ctime = stat.st_ctime
      ; sf_perm = stat.st_perm
      ; sf_uid = stat.st_uid
      ; sf_gid = stat.st_gid
      }
  | _ -> None
  | exception Unix.Unix_error _ -> None

let state_stamp_is_settled ~now stamp =
  now -. stamp.sf_mtime > 0.05 && now -. stamp.sf_ctime > 0.05

let state_cache_mu = Stdlib.Mutex.create ()
let state_cache : (string, int * state_file_stamp * workspace_state) Hashtbl.t =
  Hashtbl.create 8
let state_cache_max = 64

let invalidate_state_cache path =
  note_workspace_state_written ();
  Stdlib.Mutex.protect state_cache_mu (fun () -> Hashtbl.remove state_cache path)

let observe_state_uncached config =
  let path = state_path config in
  observe_state_doc
    ~defaults:(fun () -> Workspace_bootstrap.default_workspace_state config)
    (read_json_doc config path)

(* [state.json] is what [is_initialized] reads, so a read never creates it:
   a workspace without one gets the declared default, unwritten. A document
   that is there but does not decode is not rewritten either: the caller gets
   the recovered value together with the fault. *)
let observe_state config =
  let path = state_path config in
  let use_cache =
    match config.backend with
    | FileSystem _ -> true
    | Memory _ -> false
  in
  let gen_before = workspace_state_write_generation () in
  let cached =
    if not use_cache then None
    else
      let now = Time_compat.now () in
      match stat_state_file_opt path with
      | Some stamp when state_stamp_is_settled ~now stamp ->
        Stdlib.Mutex.protect state_cache_mu (fun () ->
          match Hashtbl.find_opt state_cache path with
          | Some (cached_gen, s, state)
            when cached_gen = gen_before && equal_state_file_stamp s stamp ->
            Some state
          | Some _ | None -> None)
      | Some _ | None -> None
  in
  match cached with
  | Some state -> State_decoded state
  | None ->
    let now_before = if use_cache then Time_compat.now () else 0.0 in
    let before = if use_cache then stat_state_file_opt path else None in
    let obs = observe_state_uncached config in
    (match obs with
     | State_decoded state when use_cache ->
       (match before, stat_state_file_opt path with
        | Some s1, Some s2
          when state_stamp_is_settled ~now:now_before s1
               && equal_state_file_stamp s1 s2
               && state_stamp_is_settled ~now:(Time_compat.now ()) s2
               && workspace_state_write_generation () = gen_before ->
          Stdlib.Mutex.protect state_cache_mu (fun () ->
            if Hashtbl.length state_cache >= state_cache_max
               && not (Hashtbl.mem state_cache path)
            then Hashtbl.clear state_cache;
            Hashtbl.replace state_cache path (gen_before, s2, state))
        | _ -> ())
     | State_decoded _ | State_absent _ | State_recovered _ -> ());
    obs

let read_state config =
  match observe_state config with
  | State_absent state | State_decoded state -> state
  | State_recovered { state; fault } ->
    Log.Misc.warn
      "read_state: state.json did not decode (%s); answering with recovered values"
      (state_read_fault_to_string fault);
    state

(* ============================================ *)
(* State Write / Update                         *)
(* ============================================ *)

let write_state config state =
  let path = state_path config in
  let json = workspace_state_to_yojson state in
  write_json config path json;
  invalidate_state_cache path

let raw_snippet_max_bytes = 500

(* The one place an undecodable document is about to be replaced, so the one
   place its bytes are worth logging. *)
let state_to_overwrite = function
  | State_absent state | State_decoded state -> state
  | State_recovered { state; fault } ->
    let raw_snippet =
      match fault with
      | State_document_fault _ -> ""
      | State_schema_fault { reason = _; document } ->
        let s = Yojson.Safe.to_string document in
        if String.length s <= raw_snippet_max_bytes
        then s
        else
          String_util.utf8_prefix ~max_bytes:raw_snippet_max_bytes s ^ "...(truncated)"
    in
    Log.Misc.warn
      "workspace state: state.json did not decode (%s), raw=%s — replacing it with \
       recovered values"
      (state_read_fault_to_string fault)
      raw_snippet;
    state

let update_state config f =
  with_file_lock config (state_path config) (fun () ->
    let state = state_to_overwrite (observe_state_uncached config) in
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
