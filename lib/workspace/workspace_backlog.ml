(** Workspace Backlog - Backlog I/O.

    Extracted from workspace_state.ml. *)

open Masc_domain
open Workspace_utils

let backlog_path = Workspace_utils.backlog_path

let backlog_lock_path config =
  Filename.concat (Filename.dirname (backlog_path config)) ".backlog"

let backlog_recovery_path config =
  backlog_path config ^ Common.recovery_mirror_suffix

(* A task field the decoder refuses stays on the task as a typed unreadable
   value ([Masc_domain.Handoff_unreadable]) and is written back unchanged, so
   decoding here neither drops it nor needs to report a drop (#38219). *)
let decode_backlog ~path json =
  backlog_of_yojson json
  |> Result.map_error (fun msg ->
    Printf.sprintf "[read_backlog] backlog decode failed for %s: %s" path msg)

module Task_id_map = Map.Make (String)
module Task_id_set = Set.Make (String)

type prepared_backlog =
  { backlog : backlog
  ; tasks_by_id : task Task_id_map.t
  ; active_assignees_by_task_id : string Task_id_map.t
  ; priority_ordered_tasks : task list
  ; claimable_ordered_tasks : task list
  }

let compare_task_priority_order (a : task) (b : task) =
  let priority_cmp = Int.compare a.priority b.priority in
  if priority_cmp <> 0
  then priority_cmp
  else (
    let created_cmp = String.compare a.created_at b.created_at in
    if created_cmp <> 0 then created_cmp else String.compare a.id b.id)

let build_prepared_backlog (backlog : backlog) : prepared_backlog =
  let tasks_by_id, active_assignees_by_task_id =
    List.fold_left
      (fun (by_id, active) (task : task) ->
         (* Preserve first-row precedence so [Task_id_map.find_opt] agrees with
            [List.find_opt] when a backlog contains duplicate task IDs. *)
         let by_id =
           Task_id_map.update
             task.id
             (function
               | Some existing -> Some existing
               | None -> Some task)
             by_id
         in
         let active =
           match task.task_status with
           | Claimed { assignee; _ } | InProgress { assignee; _ } ->
             Task_id_map.update
               task.id
               (function
                 | Some existing -> Some existing
                 | None -> Some assignee)
               active
           | Todo | AwaitingVerification _ | Done _ | Cancelled _ -> active
         in
         by_id, active)
      (Task_id_map.empty, Task_id_map.empty)
      backlog.tasks
  in
  let priority_ordered_tasks =
    List.sort compare_task_priority_order backlog.tasks
  in
  let claimable_ordered_tasks =
    List.filter
      Masc_domain.task_claim_next_action_is_claimable
      priority_ordered_tasks
  in
  { backlog
  ; tasks_by_id
  ; active_assignees_by_task_id
  ; priority_ordered_tasks
  ; claimable_ordered_tasks
  }

let last_prepared_backlog : prepared_backlog option Atomic.t = Atomic.make None

let prepare_backlog (backlog : backlog) : prepared_backlog =
  match Atomic.get last_prepared_backlog with
  | Some prepared when prepared.backlog == backlog -> prepared
  | Some _ | None ->
    let prepared = build_prepared_backlog backlog in
    Atomic.set last_prepared_backlog (Some prepared);
    prepared

let find_task_in_backlog_opt (backlog : backlog) (task_id : string) : task option =
  Task_id_map.find_opt task_id (prepare_backlog backlog).tasks_by_id

type decoded_backlog =
  { backlog : backlog
  ; prepared : prepared_backlog option Atomic.t
  }

let decoded_backlog backlog = { backlog; prepared = Atomic.make None }

(* Only the filesystem primary uses this cache. The prepared index is a
   projection of the same immutable backlog, built when first requested. *)
let backlog_cache : decoded_backlog File_version_cache.t = File_version_cache.create ()

(* Test seam for an in-flight miss racing invalidation. *)
let before_backlog_cache_registration_hook = Atomic.make (fun () -> ())

let invalidate_backlog_cache config = File_version_cache.forget backlog_cache (backlog_path config)

type backlog_recovery = {
  primary_error : string;
  recovery_path : string;
}

type backlog_observation = {
  observed_backlog : backlog;
  recovered_from : backlog_recovery option;
}

type prepared_backlog_observation = {
  observed_prepared : prepared_backlog;
  recovered_from : backlog_recovery option;
}

let read_decoded_backlog_with_source_r config =
  let path = backlog_path config in
  let recover primary_msg =
    let recovery_path = backlog_recovery_path config in
    match read_json_doc config recovery_path with
    | Ok None ->
      Error
        (Printf.sprintf "%s; no recovery mirror at %s" primary_msg recovery_path)
    | Ok (Some json) ->
      (match decode_backlog ~path:recovery_path json with
       | Ok backlog ->
         Log.Misc.warn
           "read_backlog: primary backlog unreadable, recovered from %s (%s)"
           recovery_path
           primary_msg;
         Ok (decoded_backlog backlog, Some { primary_error = primary_msg; recovery_path })
       | Error recovery_msg ->
         Error
           (Printf.sprintf
              "%s; recovery failed: %s"
              primary_msg
              recovery_msg))
    | Error recovery_error ->
      Error
        (Printf.sprintf
           "%s; recovery read failed for %s: %s"
           primary_msg
           recovery_path
           (json_doc_error_to_string recovery_error))
  in
  let read_primary () =
    match
      Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
        Result.map (Option.map (decode_backlog ~path)) (read_json_doc config path))
    with
    | Ok None -> Error (Printf.sprintf "no backlog at %s" path)
    | Ok (Some decoded) -> Result.map decoded_backlog decoded
    | Error primary_error ->
      Error
        (Printf.sprintf "backlog read failed for %s: %s" path
           (json_doc_error_to_string primary_error))
  in
  let primary =
    match config.backend with
    | Memory _ -> read_primary ()
    | FileSystem _ ->
      File_version_cache.load backlog_cache path ~decode:(fun () ->
        Result.map (fun decoded ->
          (Atomic.get before_backlog_cache_registration_hook) ();
          decoded) (read_primary ()))
  in
  match primary with
  | Ok decoded -> Ok (decoded, None)
  | Error detail -> recover detail

let read_backlog_with_source_r config =
  read_decoded_backlog_with_source_r config
  |> Result.map (fun (decoded, recovered_from) ->
       { observed_backlog = decoded.backlog; recovered_from })

let read_prepared_backlog_with_source_r config =
  read_decoded_backlog_with_source_r config
  |> Result.map (fun (decoded, recovered_from) ->
       let observed_prepared =
         match Atomic.get decoded.prepared with
         | Some prepared -> prepared
         | None ->
           let prepared =
             match Atomic.get last_prepared_backlog with
             | Some prepared when prepared.backlog == decoded.backlog -> prepared
             | Some _ | None ->
               Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
                 prepare_backlog decoded.backlog)
           in
           if Atomic.compare_and_set decoded.prepared None (Some prepared)
           then prepared
           else Option.value (Atomic.get decoded.prepared) ~default:prepared
       in
       { observed_prepared; recovered_from })

let read_prepared_backlog_observation_with_source_r =
  read_prepared_backlog_with_source_r

let read_prepared_backlog_r config =
  match read_prepared_backlog_with_source_r config with
  | Ok { observed_prepared; recovered_from = None } -> Ok observed_prepared
  | Ok
      {
        observed_prepared;
        recovered_from = Some { primary_error; recovery_path };
      } ->
    Error
      (Printf.sprintf
         "%s; recovery snapshot at %s revision=%d is available but non-authoritative for mutation"
         primary_error
         recovery_path
         observed_prepared.backlog.version)
  | Error _ as error -> error

let read_backlog_r config =
  match read_backlog_with_source_r config with
  | Ok { observed_backlog; recovered_from = None } -> Ok observed_backlog
  | Ok
      {
        observed_backlog;
        recovered_from = Some { primary_error; recovery_path };
      } ->
    Error
      (Printf.sprintf
         "%s; recovery snapshot at %s revision=%d is available but non-authoritative for mutation"
         primary_error
         recovery_path
         observed_backlog.version)
  | Error _ as error -> error

let read_backlog_observation_with_source_r = read_backlog_with_source_r

let read_backlog_observation_r config =
  match read_backlog_with_source_r config with
  | Ok { observed_backlog; _ } -> Ok observed_backlog
  | Error _ as error -> error

exception Backlog_read_failed of string
exception Backlog_write_failed of string

let protect_backlog_commit_settlement f =
  match Eio_guard.execution_context () with
  | Eio_guard.Eio_fiber -> Eio.Cancel.protect f
  | Eio_guard.Non_eio -> f ()
;;

let read_backlog config =
  match read_backlog_with_source_r config with
  | Ok { observed_backlog; _ } -> observed_backlog
  | Error msg ->
    Log.Misc.error "%s" msg;
    raise (Backlog_read_failed msg)

type write_backlog_outcome =
  { committed_revision : int
  ; primary_mirror_error : string option
  ; recovery_error : string option
  ; post_commit_error : string option
  }

(* The encode can wait behind other jobs on the shared CPU pool while the
   caller holds the backlog lock, and on the FileSystem backend that lock is
   a lease that may run out during the wait. The primary write therefore
   runs as the protected step of the caller's own lease: inside the lock
   key's fence the owner is checked, the lease renewed and the write made
   before any competing acquisition can take the lease. When another
   acquisition holds it by then, it may already have committed a newer
   revision, so nothing is written. *)
(* Test seam: runs inside the fence between the primary write and the
   recovery copy write. Production never sets it. *)
let between_backlog_copy_writes_hook : (unit -> unit) Atomic.t =
  Atomic.make (fun () -> ())

let publish_under_backlog_lease config ~action publish =
  match commit_under_held_lease config (backlog_lock_path config) publish with
  | Ok published -> published
  | Error refusal ->
    let detail = lease_commit_refusal_to_string refusal in
    Log.TaskState.error "backlog %s refused, nothing written: %s" action detail;
    Error
      (Printf.sprintf "[write_backlog] %s refused, nothing written: %s" action
         detail)

(** Result-returning variant with the primary backlog as the commit point.
    Once the primary write succeeds, recovery-copy failure is returned as an
    explicit committed outcome rather than a false mutation failure.

    Commits the NEXT revision of the given snapshot: [version] is stamped to
    [backlog.version + 1] and [last_updated] to now at this single commit
    point, so revision monotonicity is structural instead of a convention
    spread across every caller. Callers pass the snapshot they read, with
    mutated [tasks], and never hand-bump. *)
(* Who hears that the task backlog or its Goal links committed, with the
   workspace that holds them. Installed by the dataset feed; a commit with
   no listener installed announces nothing. *)
let committed_observer : (base_path:string -> unit) Atomic.t =
  Atomic.make (fun ~base_path:_ -> ())

let install_committed_observer observer = Atomic.set committed_observer observer

let announce_committed (config : Workspace_utils_backend_setup.config) =
  (Atomic.get committed_observer) ~base_path:config.base_path

let write_backlog_result ?after_commit config backlog =
  if backlog.version = max_int then
    Error
      (Printf.sprintf
         "[write_backlog] revision exhausted at %d; refusing to wrap"
         backlog.version)
  else
  let committed_revision = backlog.version + 1 in
  let primary_path = backlog_path config in
  let recovery_path = backlog_recovery_path config in
  (* [last_updated] is stamped inside the job, after any wait for a pool
     worker, so the stamp is taken next to the primary write rather than
     when the job was queued. *)
  let encoded =
    Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
      encode_json_pretty
        (backlog_to_yojson
           { backlog with version = committed_revision; last_updated = now_iso () }))
  in
  (* The recovery copy is written inside the same fence as the primary. A
     recovery write made after the fence is released could land after a
     writer that took the lease over has committed a newer primary and
     recovery copy, and would put this older snapshot back into the recovery
     copy, which a reader falls back to when the primary cannot be read.
     The primary stays the commit point: once it is written, a failed
     recovery write is reported in the outcome and does not undo the
     commit. *)
  let write_recovery_copy () =
    match write_encoded_json_commit_result config recovery_path encoded with
    | Ok { mirror_error = None } -> None
    | Ok { mirror_error = Some message } ->
      Log.TaskState.error
        "backlog primary and recovery backend committed but recovery local \
         mirror write failed path=%s error=%s"
        recovery_path
        message;
      Some message
    | Error message ->
      Log.TaskState.error
        "backlog primary committed but recovery copy write failed path=%s error=%s"
        recovery_path
        message;
      Some message
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn ->
      let message = Printexc.to_string exn in
      Log.TaskState.error
        "backlog primary committed but recovery copy write raised path=%s error=%s"
        recovery_path
        message;
      Some message
  in
  match
    publish_under_backlog_lease config
      ~action:(Printf.sprintf "commit of revision %d" committed_revision)
      (fun () ->
         match write_encoded_json_commit_result config primary_path encoded with
         | Error _ as error -> error
         | Ok primary_commit ->
           (* The primary is the commit point, so from here on a
              cancellation must not skip the recovery copy, the observer or
              [after_commit]. The fenced FileSystem path already runs
              [publish] protected, but the Memory backend and a write
              without a held lease call [publish] directly, and the
              recovery write yields. *)
           protect_backlog_commit_settlement (fun () ->
             (Atomic.get between_backlog_copy_writes_hook) ();
             Ok (primary_commit, write_recovery_copy ())))
  with
  | Error msg -> Error msg
  | Ok (primary_commit, recovery_error) ->
    protect_backlog_commit_settlement (fun () ->
    Option.iter
      (fun message ->
         Log.TaskState.error
           "backlog primary committed but local mirror write failed path=%s error=%s"
           primary_path
           message)
      primary_commit.mirror_error;
    invalidate_backlog_cache config;
    announce_committed config;
    let mutation_observer_error =
      try
        (Atomic.get Workspace_hooks.on_task_mutation_fn) ();
        None
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        let message = Printexc.to_string exn in
        Log.TaskState.error
          "backlog primary committed but task mutation observer failed path=%s \
           error=%s"
          primary_path
          message;
        Some message
    in
    let caller_post_commit_error =
      match after_commit with
      | None -> None
      | Some f ->
        (try
           f ();
           None
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           let message = Printexc.to_string exn in
           Log.TaskState.error
             "backlog primary committed but post-commit callback failed path=%s \
              error=%s"
             primary_path
             message;
           Some message)
    in
    let post_commit_error =
      match mutation_observer_error, caller_post_commit_error with
      | None, None -> None
      | Some message, None | None, Some message -> Some message
      | Some observer_error, Some caller_error ->
        Some
          (Printf.sprintf
             "task mutation observer: %s; caller post-commit: %s"
             observer_error
             caller_error)
    in
    Ok
      { committed_revision
      ; primary_mirror_error = primary_commit.mirror_error
      ; recovery_error
      ; post_commit_error
      })

(** Re-settle the current authoritative snapshot without creating a new
    revision. Caller holds the backlog lock and obtained [backlog] from its
    primary read. This repairs copies after a committed deletion's failed
    settlement, including on an already-absent Task retry. *)
let repair_backlog_copies_result config backlog =
  let primary_path = backlog_path config in
  let recovery_path = backlog_recovery_path config in
  let encoded =
    Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
      encode_json_pretty (backlog_to_yojson backlog))
  in
  let write path = match write_encoded_json_commit_result config path encoded with
    | Error message -> Error message
    | Ok {mirror_error=Some message} -> Error message
    | Ok {mirror_error=None} -> Ok () in
  (* Both copies are written inside the lease's fence, for the same reason
     as in [write_backlog_result]: a recovery write after the fence could
     overwrite the recovery copy of a newer revision committed by a writer
     that took the lease over. *)
  match
    publish_under_backlog_lease config
      ~action:(Printf.sprintf "repair of revision %d" backlog.version)
      (fun () ->
         match write primary_path with
         | Error _ as error -> error
         | Ok () ->
           (* Same as in [write_backlog_result]: once the primary is
              rewritten, a cancellation must not leave the recovery copy
              behind it on any backend. *)
           protect_backlog_commit_settlement (fun () ->
             (Atomic.get between_backlog_copy_writes_hook) ();
             write recovery_path))
  with
  | Error _ as error -> error
  | Ok () ->
      (* Same as in [write_backlog_result]: the primary is the commit point,
         so once both copies are written a cancellation must not skip the
         cache invalidation or the task mutation observer. Without this the
         repair had a different cancellation contract from a normal commit:
         a cancellation arriving while the observer yields was re-raised and
         the observer was skipped even though the repair had committed. *)
      protect_backlog_commit_settlement (fun () ->
        invalidate_backlog_cache config;
        announce_committed config;
        try (Atomic.get Workspace_hooks.on_task_mutation_fn) (); Ok () with
        | Eio.Cancel.Cancelled _ as error -> raise error
        | error -> Error (Printexc.to_string error))
;;

(** [write_backlog ?after_commit config backlog] persists the primary SSOT,
    then observes secondary recovery/mirror/projection failures without
    misreporting the committed mutation as a primary failure. *)
let write_backlog ?after_commit config backlog =
  match write_backlog_result ?after_commit config backlog with
  | Ok _ -> ()
  | Error message -> raise (Backlog_write_failed message)

type copy_consistency = Copies_consistent | Copies_unavailable of string list

let observe_copy_consistency config backlog =
  let compare label read = match read () with
    | Error message -> Some (label ^ ": " ^ message)
    | Ok json -> (match backlog_of_yojson json with
      | Error message -> Some (label ^ ": " ^ message)
      | Ok copy when copy = backlog -> None
      | Ok _ -> Some (label ^ ": does not match current primary snapshot")) in
  let recovery = compare "recovery" (fun () ->
    let recovery_path = backlog_recovery_path config in
    match read_json_doc config recovery_path with
    | Ok (Some json) -> Ok json
    | Ok None -> Error ("no recovery mirror at " ^ recovery_path)
    | Error error -> Error (json_doc_error_to_string error)) in
  let mirrors = match config.backend with
    | FileSystem _ -> []
    | Memory _ ->
      [compare "primary mirror" (fun () -> read_json_local_result (backlog_path config));
       compare "recovery mirror" (fun () -> read_json_local_result (backlog_recovery_path config))] in
  match List.filter_map Fun.id (recovery :: mirrors) with
  | [] -> Copies_consistent | errors -> Copies_unavailable errors
;;
