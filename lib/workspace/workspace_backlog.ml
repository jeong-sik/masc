(** Workspace Backlog - Backlog I/O.

    Extracted from workspace_state.ml. *)

open Masc_domain
open Workspace_utils

let backlog_path = Workspace_utils.backlog_path

let backlog_lock_path config =
  Filename.concat (Filename.dirname (backlog_path config)) ".backlog"

let backlog_recovery_path config =
  backlog_path config ^ ".last-good"

let decode_backlog ~path json =
  match backlog_of_yojson_with_diagnostics json with
  | Ok (backlog, dropped) ->
      (* #27499: the decoder drops a corrupt optional nested field instead of
         rejecting the whole backlog. Report each drop so the corruption is
         not silent, while the backlog still opens. *)
      List.iter
        (fun (entry : backlog_task_diagnostics) ->
          (match entry.dropped_outcomes.handoff_context_outcome with
           | Field_unreadable detail ->
               Log.Misc.warn
                 "[read_backlog] %s: task %s handoff_context unreadable, dropped: %s"
                 path
                 entry.dropped_task_id
                 detail
           | Field_absent | Field_decoded -> ());
          (match entry.dropped_outcomes.reclaim_policy_outcome with
           | Field_unreadable detail ->
               Log.Misc.warn
                 "[read_backlog] %s: task %s reclaim_policy unreadable, dropped: %s"
                 path
                 entry.dropped_task_id
                 detail
           | Field_absent | Field_decoded -> ());
          match entry.dropped_outcomes.legacy_intent_dropped with
          | Some Legacy_complete ->
              Log.Misc.warn
                "[read_backlog] %s: task %s legacy intent=complete dropped; completion submission retained"
                path entry.dropped_task_id
          | Some Legacy_cancel ->
              Log.Misc.warn
                "[read_backlog] %s: task %s legacy intent=cancel dropped; task restored to in_progress"
                path entry.dropped_task_id
          | None -> ())
        dropped;
      Ok backlog
  | Error msg ->
      Error
        (Printf.sprintf
           "[read_backlog] backlog decode failed for %s: %s"
           path
           msg)

(** Per-path backlog cache keyed by file mtime/size.

    CPU sampling showed that reading + Yojson-decoding backlog.json is one
    of the hottest paths in dashboard/keeper snapshot code, and the file is
    read many times between mutations.  Caching by mtime+size is safe because
    [write_backlog] invalidates the cache after persisting. *)
type backlog_cache_entry = {
  mtime : float;
  size : int;
  backlog : backlog;
}

let backlog_cache : (string, backlog_cache_entry) Hashtbl.t = Hashtbl.create 16
let backlog_cache_mu = Stdlib.Mutex.create ()

let file_stat_opt path =
  try Some (Unix.stat path) with Unix.Unix_error _ | Sys_error _ -> None

let clear_backlog_cache_for path =
  Stdlib.Mutex.protect backlog_cache_mu (fun () -> Hashtbl.remove backlog_cache path)

type backlog_recovery = {
  primary_error : string;
  recovery_path : string;
}

type backlog_observation = {
  observed_backlog : backlog;
  recovered_from : backlog_recovery option;
}

let read_backlog_with_source_r config =
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
         Ok
           {
             observed_backlog = backlog;
             recovered_from = Some { primary_error = primary_msg; recovery_path };
           }
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
  let cached =
    Stdlib.Mutex.protect backlog_cache_mu (fun () ->
        match Hashtbl.find_opt backlog_cache path with
        | None -> None
        | Some entry -> (
            match file_stat_opt path with
            | None -> None
            | Some st ->
                if st.Unix.st_mtime = entry.mtime && st.Unix.st_size = entry.size
                then Some entry.backlog
                else None))
  in
  match cached with
  | Some backlog ->
    Ok { observed_backlog = backlog; recovered_from = None }
  | None -> (
      (* Cache the decoded backlog keyed on the file's (mtime, size). A
         writer commits under [with_backlog_file_lock] and clears this cache
         after its write, but the reader takes no such lock: statting only
         after the read would register (new stat, old backlog) when a commit
         lands between the two — an entry the writer's clear has already
         passed, poisoning hits until the next write. Stat before the read
         too and only register when nothing changed across it. *)
      let stat_before = file_stat_opt path in
      (* The miss path — the read, the JSON parse and the typed decode of a
         file that is 2 MB on a live root — runs as one job on the domain
         pool when one is installed and inline otherwise. Every keeper wake
         reads the backlog and every writer's commit clears this cache, so on
         a busy fleet most reads miss; on the calling fiber each miss held
         the main domain about 60 ms (RFC main-domain-scheduler-latency
         §8.8). The stats stay on the fiber: they order the cache
         registration against a concurrent commit, not the decode. *)
      match
        Domain_pool_ref.submit_cpu_or_inline (fun () ->
          Result.map (Option.map (decode_backlog ~path)) (read_json_doc config path))
      with
      | Ok None -> recover (Printf.sprintf "no backlog at %s" path)
      | Ok (Some decoded) ->
          (match decoded with
          | Ok backlog ->
              (match (stat_before, file_stat_opt path) with
              | Some before, Some after
                when after.Unix.st_mtime = before.Unix.st_mtime
                     && after.Unix.st_size = before.Unix.st_size ->
                  Stdlib.Mutex.protect backlog_cache_mu (fun () ->
                      Hashtbl.replace backlog_cache path
                        { mtime = after.Unix.st_mtime
                        ; size = after.Unix.st_size
                        ; backlog
                        })
              | _ ->
                  (* The file moved under the read (or vanished before it):
                     hand back the value but leave the cache to the next
                     reader, which starts from a miss. *)
                  ());
              Ok { observed_backlog = backlog; recovered_from = None }
          | Error primary_msg -> recover primary_msg)
      | Error primary_error ->
          recover
            (Printf.sprintf "backlog read failed for %s: %s" path
               (json_doc_error_to_string primary_error)))

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
    Domain_pool_ref.submit_cpu_or_inline (fun () ->
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
    clear_backlog_cache_for primary_path;
    clear_backlog_cache_for recovery_path;
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
    Domain_pool_ref.submit_cpu_or_inline (fun () ->
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
        clear_backlog_cache_for primary_path;
        clear_backlog_cache_for recovery_path;
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
