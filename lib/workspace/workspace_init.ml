(** Workspace Init - Workspace initialization, reset, pause, and resume.

    Extracted from Workspace module. Handles workspace directory bootstrapping,
    state creation, and pause/resume lifecycle. *)

open Masc_domain
open Workspace_utils
open Workspace_state
open Workspace_broadcast

type initialization_error =
  | Cold_memory_has_local_document of string
  | Document_presence_unavailable of { path : string; detail : string }
  | State_present_without_backend_initialization of string
  | Backlog_seed_failed of string
  | Backlog_seed_committed_with_mirror_error of string
  | Backlog_seed_lease_refused of Workspace_utils_ops.lease_commit_refusal
  | State_seed_failed of string
  | State_seed_lease_refused of Workspace_utils_ops.lease_commit_refusal
  | Mirror_unverified of { path : string; detail : string }

exception Initialization_failed of initialization_error

let initialization_error_to_string = function
  | Cold_memory_has_local_document path ->
      Printf.sprintf "cold Memory backend cannot adopt local workspace document %s" path
  | Document_presence_unavailable { path; detail } ->
      Printf.sprintf "cannot determine whether workspace document %s exists: %s" path detail
  | State_present_without_backend_initialization path ->
      Printf.sprintf "workspace state is present but not initialized by the backend: %s" path
  | Backlog_seed_failed detail -> "backlog seed did not commit: " ^ detail
  | Backlog_seed_committed_with_mirror_error detail ->
      "backlog seed committed but its local mirror failed: " ^ detail
  | Backlog_seed_lease_refused refusal ->
      "backlog seed refused: " ^ lease_commit_refusal_to_string refusal
  | State_seed_failed detail -> "workspace state seed did not commit: " ^ detail
  | State_seed_lease_refused refusal ->
      "workspace state seed refused: " ^ lease_commit_refusal_to_string refusal
  | Mirror_unverified { path; detail } ->
      Printf.sprintf "local mirror of %s is not verified: %s" path detail

let () =
  Printexc.register_printer (function
    | Initialization_failed error -> Some (initialization_error_to_string error)
    | _ -> None)

type document_presence = Present | Absent | Unavailable of string

(* [Sys.file_exists] follows symlinks and collapses some errors into false.
   An existing dangling link or an inaccessible path is not a fresh store. *)
let local_presence path =
  match Unix.lstat path with
  | _ -> Present
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Absent
  | exception Unix.Unix_error (error, operation, argument) ->
      Unavailable
        (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))

let document_presence config path =
  match local_presence path with
  | Present -> Present
  | Unavailable _ as unavailable -> unavailable
  | Absent ->
      (match key_of_path config path with
       | None -> Absent
       | Some key ->
           match backend_get config ~key with
           | Ok (Some _) -> Present
           | Ok None -> Absent
           | Error error -> Unavailable (Backend_types.show_error error))

let require_known_presence path = function
  | Present -> true
  | Absent -> false
  | Unavailable detail ->
      raise (Initialization_failed (Document_presence_unavailable { path; detail }))

(* A previous init may have committed a Memory document and its mirror before
   state creation was interrupted. Compare its digest against a regular file
   read below a held root, including when the requested .masc root is a link. *)
let memory_document_matches_local config path =
  let unavailable detail =
    raise (Initialization_failed (Document_presence_unavailable { path; detail }))
  in
  match key_of_path config path with
  | None -> false
  | Some key ->
      match backend_get config ~key with
      | Error error -> unavailable (Backend_types.show_error error)
      | Ok None -> false
      | Ok (Some expected) ->
          let root = masc_dir config in
          let prefix = root ^ Filename.dir_sep in
          if not (String.starts_with ~prefix path) then
            unavailable "document is outside the workspace root";
          let relative = String.sub path (String.length prefix) (String.length path - String.length prefix) in
          let relative =
            match Fs_compat.owned_relative_path (String.split_on_char '/' relative) with
            | Ok relative -> relative
            | Error detail -> unavailable detail
          in
          let read () =
            Fs_compat.with_owned_inventory_root root (fun held ->
              Fs_compat.owned_inventory_entry_digest held relative
              |> Result.map (fun (actual : Fs_compat.owned_regular_file_range_digest) ->
                   String.equal actual.sha256 Agent_core_sha256.(digest_string expected |> to_hex)))
          in
          let observed =
            match Eio_guard.execution_context () with
            | Eio_guard.Eio_fiber -> Eio_unix.run_in_systhread read
            | Eio_guard.Non_eio -> read ()
          in
          match observed with
          | Ok matches -> matches
          | Error error ->
              (match error.failure with
               | Fs_compat.Path_is_not_regular_file _ when Option.is_none error.close_failure -> false
               | Fs_compat.Path_is_not_regular_file _
               | Fs_compat.Ownership_boundary_rejected _
               | Fs_compat.Filesystem_identity_changed _
               | Fs_compat.Owned_path_owner_mismatch _
               | Fs_compat.Owned_path_writable_by_others _
               | Fs_compat.Owned_file_operation_failed _ ->
                   unavailable (Fs_compat.owned_regular_file_read_error_to_string error))

(* Memory is a separate authority and mirrors writes to the filesystem. A
   fresh map cannot safely adopt unrelated local files by overwriting them. *)
let refuse_cold_memory_over_local_documents config =
  match config.backend with
  | FileSystem _ -> ()
  | Memory _ when path_exists config (state_path config) -> ()
  | Memory _ ->
      List.iter
        (fun path ->
          match local_presence path with
          | Present when memory_document_matches_local config path -> ()
          | Present -> raise (Initialization_failed (Cold_memory_has_local_document path))
          | Absent -> ()
          | Unavailable detail ->
              raise (Initialization_failed (Document_presence_unavailable { path; detail })))
        [ state_path config
        ; backlog_path config
        ; Workspace_backlog.backlog_recovery_path config
        ]

(* Ordinary Memory backlog mutations and state updates use these document
   locks. Reinit checks both copies under that lock but does not replace a
   differing local document: it could have been written by another backend.
   Other repair paths remain outside this contract. *)
let verify_local_mirror config ~lock_path path =
  if should_dual_write_local config
  then
    with_file_lock config lock_path (fun () ->
      match local_presence path with
      | Absent ->
          raise (Initialization_failed
                   (Mirror_unverified { path; detail = "local document is absent" }))
      | Unavailable detail ->
          raise (Initialization_failed (Document_presence_unavailable { path; detail }))
      | Present when memory_document_matches_local config path -> ()
      | Present ->
          raise (Initialization_failed
                   (Mirror_unverified { path; detail = "local document differs from the backend" })))
;;

let seed_backlog_if_fresh config =
  let backlog = backlog_path config in
  let lock_path = Workspace_backlog.backlog_lock_path config in
  let initialize_under_lease () =
    let present path = require_known_presence path (document_presence config path) in
    if present backlog then `Existing
    else if present (state_path config)
            || present (Workspace_backlog.backlog_recovery_path config)
    then `Recovery_required
    else
      match
        write_json_commit_result config backlog
          (backlog_to_yojson (Workspace_bootstrap.empty_backlog ()))
      with
      | Error detail -> raise (Initialization_failed (Backlog_seed_failed detail))
      | Ok { mirror_error = Some detail } ->
          raise (Initialization_failed (Backlog_seed_committed_with_mirror_error detail))
      | Ok { mirror_error = None } -> `Seeded
  in
  let outcome =
    with_file_lock config lock_path (fun () ->
      match commit_under_held_lease config lock_path initialize_under_lease with
      | Ok outcome -> outcome
      | Error refusal ->
          raise (Initialization_failed (Backlog_seed_lease_refused refusal)))
  in
  match outcome with
  | `Existing ->
      if path_exists config backlog then
        verify_local_mirror config ~lock_path backlog
  | `Seeded -> ()
  | `Recovery_required ->
      Log.Workspace.warn
        "init: backlog is absent while workspace state or recovery exists; leaving it for recovery"
;;

(* A second initializer or a state writer can arrive while the first is
   preparing the backlog. Recheck state under the state lease used by normal
   writers; fence this initializer's own publication against lease takeover. *)
let seed_state_if_missing config =
  let path = state_path config in
  with_file_lock config path (fun () ->
    match
      commit_under_held_lease config path (fun () ->
        invalidate_initialized_cache ();
        if is_initialized config then `Existing
        else if require_known_presence path (document_presence config path) then
          raise
            (Initialization_failed (State_present_without_backend_initialization path))
        else
          match
            write_json_commit_result config path
              (workspace_state_to_yojson (Workspace_bootstrap.default_workspace_state config))
          with
          | Error detail -> raise (Initialization_failed (State_seed_failed detail))
          | Ok { mirror_error } -> `Seeded mirror_error)
    with
    | Ok outcome -> outcome
    | Error refusal ->
        raise (Initialization_failed (State_seed_lease_refused refusal)))
;;

(** Initialize MASC workspace state. On a workspace that is already
    initialized, the server's boot path, it raises a message counter that
    fell behind the filed messages. *)
let init config ~agent_name =
  invalidate_initialized_cache ();
  refuse_cold_memory_over_local_documents config;
  List.iter
    mkdir_p
    [ agents_dir config
    ; keepers_runtime_dir config
    ; Filename.concat (masc_dir config) "traces"
    ; tasks_dir config
    ; messages_dir config
    ; Filename.concat config.base_path Playground_paths.all_playgrounds_prefix
    ];
  let backlog = backlog_path config in
  if not (path_exists config backlog)
  then seed_backlog_if_fresh config
  else
    verify_local_mirror config ~lock_path:(Workspace_backlog.backlog_lock_path config)
      backlog;
  let state =
    if is_initialized config then `Existing else seed_state_if_missing config
  in
  match state with
  | `Existing ->
    verify_local_mirror config ~lock_path:(state_path config) (state_path config);
    Workspace_bootstrap.reconcile_message_seq config (state_path config);
    "MASC already initialized."
  | `Seeded mirror_error ->
    invalidate_initialized_cache ();
    let result =
      match mirror_error with
      | None -> "MASC workspace created!"
      | Some detail ->
          Log.Workspace.warn "init: workspace state committed but local mirror failed: %s" detail;
          "MASC workspace created; local state mirror failed: " ^ detail
    in
    (* Auto-join if agent specified — uses Workspace_lifecycle.join via the caller *)
    match agent_name with
    | Some _name -> result (* Caller is responsible for joining after init *)
    | None -> result
;;

(** Pause workspace automation - stops orchestrator from spawning new agents *)
let pause config ~by ~reason =
  let _ =
    update_state config (fun s ->
      { s with
        paused = true
      ; pause_reason = Some reason
      ; paused_by = Some by
      ; paused_at = Some (now_iso ())
      })
  in
  (* Broadcast pause notification *)
  let _ =
    broadcast ~audience:System_record
      config
      ~from_agent:"system"
      ~content:(Printf.sprintf "⏸️ Workspace PAUSED by %s: %s" by reason)
  in
  ()
;;

(** Resume workspace automation *)
let resume config ~by =
  let state = read_state config in
  if not state.paused
  then `Already_running
  else (
    let _ =
      update_state config (fun s ->
        { s with paused = false; pause_reason = None; paused_by = None; paused_at = None })
    in
    (* Broadcast resume notification *)
    let _ =
      broadcast ~audience:System_record
        config
        ~from_agent:"system"
        ~content:(Printf.sprintf "▶️ Workspace RESUMED by %s" by)
    in
    `Resumed)
;;

(** Reset workspace state - delete .masc/ folder *)
let reset config =
  if not (is_initialized config)
  then "MASC not initialized. Nothing to reset."
  else (
    Fs_compat.remove_tree (masc_dir config);
    invalidate_initialized_cache ();
    Printf.sprintf "MASC workspace reset! (.masc/ deleted at %s)" config.base_path)
;;
