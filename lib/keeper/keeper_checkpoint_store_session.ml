module Objects = Agent_core.Checkpoint_objects
open Keeper_checkpoint_store_history_files
open Keeper_checkpoint_store_decode
open Keeper_checkpoint_store_summary

(* ── RFC-0225 §3.2: disk-SSOT monotonic checkpoint transaction ──────
   One stable per-session lock covers canonical disk load, comparison,
   durable publication, and history capture. The canonical file is the only
   admission watermark; no process-local checkpoint truth is retained. *)

type save_agent_core_relation = [ `Cold | `Forward | `Equal ]

type save_agent_core_outcome =
  | Saved of
      { relation : save_agent_core_relation
      ; turn_count : int
      ; canonical_bytes : int
      ; checkpoint : Agent_core.Checkpoint.t
      }
  | Stale_noop of { incoming_turn_count : int; known_turn_count : int }

let save_relation ~known ~incoming =
  match known with
  | None -> `Cold
  | Some previous when incoming > previous -> `Forward
  | Some _ -> `Equal

type unix_failure =
  { error : Unix.error
  ; operation : string
  ; argument : string
  }

type directory_failure =
  | Directory_unix_failure of unix_failure
  | Directory_other_failure of string
  | Directory_leaf_invalid of
      { session_dir : string
      ; leaf : string
      }

type save_agent_core_error =
  | Invalid_session_id of string
  | Session_directory_unavailable of directory_failure
  | Existing_checkpoint_unreadable of checkpoint_load_error
  | Checkpoint_unencodable of Agent_core.Error.t
      (** The checkpoint codec refused the messages or the fields around them,
          and dropping unencodable json did not give a copy it accepts. *)
  | Objects_write_failed of Keeper_checkpoint_object_store.write_error
  | Canonical_write_failed of Keeper_fs.durable_write_error
  | Transaction_lock_failed of File_lock_eio.durable_lock_error
  | Structurally_invalid of Keeper_transcript_unit.structural_error
      (** The messages do not satisfy the tool-protocol contract a reload has
          to replay. One of the three writers ran this check before calling
          here; the mid-run sink and finalize assembled their checkpoint
          directly and did not, so a broken history was admitted by the two
          hottest paths (#25561). The check belongs at the write boundary
          every writer passes through. *)

let checkpoint_load_error_to_string = function
  | Not_found -> "checkpoint not found"
  | Superseded_version { expected; got } ->
    Printf.sprintf
      "checkpoint version %d is superseded by %d" got expected
  | Newer_version { expected; got } ->
    Printf.sprintf
      "checkpoint version %d was written by a later binary; this one reads %d"
      got expected
  | Store_error detail
  | Parse_error detail
  | Io_error detail
  | Read_failed { detail; _ }
  | Agent_core_error detail -> detail
  | Objects_invalid error -> Objects.load_error_to_string error

let save_agent_core_error_to_string = function
  | Invalid_session_id reason -> reason
  | Session_directory_unavailable (Directory_unix_failure failure) ->
    Printf.sprintf "checkpoint session directory unavailable: %s(%s): %s"
      failure.operation failure.argument (Unix.error_message failure.error)
  | Session_directory_unavailable (Directory_other_failure detail) ->
    "checkpoint session directory unavailable: " ^ detail
  | Session_directory_unavailable (Directory_leaf_invalid { session_dir; leaf }) ->
    Printf.sprintf
      "checkpoint session directory rejected: leaf %S of %S is not a real \
       path segment"
      leaf session_dir
  | Existing_checkpoint_unreadable error ->
    "existing checkpoint unreadable: " ^ checkpoint_load_error_to_string error
  | Checkpoint_unencodable error ->
    "checkpoint cannot be encoded: " ^ Agent_core.Error.to_string error
  | Objects_write_failed error -> Keeper_checkpoint_object_store.write_error_to_string error
  | Canonical_write_failed error ->
    "canonical checkpoint write failed: "
    ^ Keeper_fs.durable_write_error_to_string error
  | Transaction_lock_failed error ->
    "checkpoint transaction lock failed: "
    ^ File_lock_eio.durable_lock_error_to_string error
  | Structurally_invalid error ->
    "checkpoint messages are structurally invalid: "
    ^ Keeper_transcript_unit.show_structural_error error

let canonical_session_location session_dir =
  (* Containment boundary for every checkpoint path (issue #25077).
     [Keeper_fs.save_json_durable_atomic ~ownership_root] already rejects
     escapes on the durable-write directory chain, but the lock file, history
     archive, and read paths consume this location without that guard, so the
     leaf is validated here once, before any filesystem side effect. The
     canonical parent is [Unix.realpath] of the *configured* session root:
     resolving a symlinked deployment root to its physical location is the
     purpose of this function, so the parent resolution itself is trusted.
     The leaf, however, must not be a symlink: a link there would redirect
     every checkpoint and lock write through whatever target it names
     ([Keeper_fs] applies the same symlink rejection to its own write
     chains). The lstat check shares the TOCTOU
     caveat documented on [Keeper_fs]: OCaml 5.4 has no portable
     dirfd-relative API, so the caller keeps the subtree process-owned. *)
  let leaf = Filename.basename session_dir in
  if not (leaf_is_real_segment leaf)
  then
    Error
      (Session_directory_unavailable
         (Directory_leaf_invalid { session_dir; leaf }))
  else (
    let parent = Filename.dirname session_dir in
    try
      Fs_compat.mkdir_p parent;
      let location =
        Eio_guard.run_in_systhread ~label:"checkpoint-parent-stat" (fun () ->
          let spelling = parent in
          let parent = Unix.realpath parent in
          if (Unix.stat parent).Unix.st_kind <> Unix.S_DIR
          then
            raise
              (Unix.Unix_error
                 (Unix.ENOTDIR, "checkpoint_session_parent", parent));
          remember_session_root ~spelling parent;
          let location = Filename.concat parent leaf in
          (match Unix.lstat location with
           | { Unix.st_kind = Unix.S_LNK; _ } ->
             raise
               (Unix.Unix_error
                  (Unix.ELOOP, "checkpoint_session_leaf", location))
           | { Unix.st_kind =
                 ( Unix.S_REG
                 | Unix.S_DIR
                 | Unix.S_CHR
                 | Unix.S_BLK
                 | Unix.S_FIFO
                 | Unix.S_SOCK )
             ; _
             } -> ()
           | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
          location)
      in
      Ok location
    with
    | Unix.Unix_error (error, operation, argument) ->
      Error
        (Session_directory_unavailable
           (Directory_unix_failure { error; operation; argument }))
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Error
        (Session_directory_unavailable
           (Directory_other_failure (Printexc.to_string exn))))

let with_session_lock_typed ~session_dir f =
  match canonical_session_location session_dir with
  | Error _ as error -> error
  | Ok session_dir ->
    let lock_path = session_dir ^ ".checkpoint.lock" in
    (match File_lock_eio.with_durable_lock ~lock_path (fun () -> f session_dir) with
     | Ok result -> result
     | Error error -> Error (Transaction_lock_failed error))

let with_session_lock ~session_dir f =
  with_session_lock_typed ~session_dir (fun session_dir -> Ok (f session_dir))
  |> Result.map_error save_agent_core_error_to_string

let archive_agent_core_history_best_effort ~payload_writer ~session_dir ~retained ~head_bytes ckpt =
  try save_agent_core_history ~payload_writer ~session_dir ~retained ~head_bytes ckpt with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Checkpoint_payload_writer.note payload_writer None;
    Log.Keeper.warn "AGENT_CORE snapshot archive write failed for %s: %s"
      ckpt.session_id (Printexc.to_string exn);
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string CheckpointFailures)
      ~labels:
        [ ( "site"
          , Keeper_checkpoint_store_failure_site.(to_label Agent_core_archive) )
        ]
      ()
