(** Workspace Init - Workspace initialization, reset, pause, and resume.

    Extracted from Workspace module. Handles workspace directory bootstrapping,
    state creation, and pause/resume lifecycle. *)

open Masc_domain
open Workspace_utils
open Workspace_state
open Workspace_broadcast

(* A backend that keeps its own copy (Memory) mirrors a document to the local
   file so a filesystem fallback reads fresh data. On the filesystem backend
   the document already is that file. *)
let sync_local_mirror config ~label path =
  if should_dual_write_local config
  then
    match write_json_local path (read_json config path) with
    | Ok () -> ()
    | Error msg -> Log.Workspace.warn "init: local sync of %s failed: %s" label msg
;;

(** Initialize MASC workspace state. On a workspace that is already
    initialized, the server's boot path, it raises a message counter that
    fell behind the filed messages. *)
let init config ~agent_name =
  invalidate_initialized_cache ();
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
  then
    write_json config backlog
      (backlog_to_yojson (Workspace_bootstrap.empty_backlog ()))
  else sync_local_mirror config ~label:"backlog" backlog;
  if is_initialized config
  then (
    sync_local_mirror config ~label:"state" (state_path config);
    Workspace_bootstrap.reconcile_message_seq config (state_path config);
    "MASC already initialized.")
  else (
    write_state config (Workspace_bootstrap.default_workspace_state config);
    invalidate_initialized_cache ();
    let result = "MASC workspace created!" in
    (* Auto-join if agent specified — uses Workspace_lifecycle.join via the caller *)
    match agent_name with
    | Some _name -> result (* Caller is responsible for joining after init *)
    | None -> result)
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
