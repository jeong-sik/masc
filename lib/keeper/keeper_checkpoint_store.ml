(** Keeper_checkpoint_store — checkpoint file I/O.

    Handles saving, loading, listing, and pruning AGENT_CORE checkpoint JSON files
    within a session directory. Separated from [Keeper_working_context]
    so that file I/O concerns do not mix with context types and
    pure operations.

    @since keeper-ctx-split *)

open Printf

(* ================================================================ *)
(* AGENT_CORE Checkpoints                                                    *)
(* ================================================================ *)

let agent_core_checkpoint_path ~(session_dir : string) ~(session_id : string) =
  Filename.concat session_dir (session_id ^ ".json")

let agent_core_history_prefix = "agent-core-snapshot-"
let agent_core_history_suffix = ".json"

let is_agent_core_history_file (filename : string) : bool =
  let len = String.length filename in
  len > String.length agent_core_history_prefix + String.length agent_core_history_suffix
  && String.sub filename 0 (String.length agent_core_history_prefix) = agent_core_history_prefix
  && String.sub filename (len - String.length agent_core_history_suffix)
       (String.length agent_core_history_suffix) = agent_core_history_suffix

let list_agent_core_history_files ~(session_dir : string) : string list =
  if not (Fs_compat.file_exists session_dir) then []
  else
    Sys.readdir session_dir
    |> Array.to_list
    |> List.filter is_agent_core_history_file
    |> List.sort (fun a b -> compare b a)

let max_agent_core_history_retained = 12

let agent_core_history_path ~(session_dir : string) ~(snapshot_id : string) =
  Filename.concat session_dir snapshot_id

(* A name below the session root ([leaf] of a session_dir, or a
   [snapshot_id] appended by [agent_core_history_path]) must denote exactly one
   directory entry. An empty, ".", ".." or separator-bearing name makes
   [Filename.concat parent name] (and the [^ ".checkpoint.lock"] sibling
   derived from a session location) resolve outside the session root, so
   every downstream consumer would inherit the escape. A NUL byte would
   truncate the path at the syscall boundary, so it is rejected here before
   any filesystem side effect. *)
let leaf_is_real_segment leaf =
  (not (String.equal leaf ""))
  && (not (String.equal leaf Filename.current_dir_name))
  && (not (String.equal leaf Filename.parent_dir_name))
  && not
       (String.exists
          (fun c -> String.contains Filename.dir_sep c || Char.equal c '\000')
          leaf)

(* Checkpoint payloads serialize to 0.7-1.4MB (see the [~pretty:false] note on
   [Keeper_fs.save_json_durable_atomic]). Encoding or decoding one on the
   calling fiber stalls every other fiber on the single-domain scheduler for
   the whole conversion (issue #25077; same class as the board_attention
   ledger re-parse hangs). Route the pure conversions through
   [Domain_pool_ref.submit_cpu_or_inline] — the typed CPU-weight policy layer
   keeper call sites are documented to prefer over the raw
   [Executor_pool_ref]; it re-raises job exceptions instead of rerunning the
   closure inline on failure, and falls back to inline execution for
   non-Eio callers itself (#25158) — the store is also reachable from raw
   Domains (see the stale-guard "raw Domain saves through Unix context"
   test). *)
let offload_checkpoint_cpu (f : unit -> 'a) : 'a =
  Domain_pool_ref.submit_cpu_or_inline f

let decode_checkpoint_off_scheduler (content : string) :
    (Agent_core.Checkpoint.t, Agent_core.Error.t) result =
  offload_checkpoint_cpu (fun () -> Agent_core.Checkpoint.of_string content)

let encode_checkpoint_string_off_scheduler (ckpt : Agent_core.Checkpoint.t) :
    string =
  offload_checkpoint_cpu (fun () -> Agent_core.Checkpoint.to_string ckpt)

let agent_core_history_snapshot_id_of_checkpoint (ckpt : Agent_core.Checkpoint.t) : string =
  let created_ms = max 0 (int_of_float (ckpt.created_at *. 1000.0)) in
  Printf.sprintf "%s%013d%s"
    agent_core_history_prefix created_ms agent_core_history_suffix

let prune_agent_core_history ~(session_dir : string) : unit =
  let files = list_agent_core_history_files ~session_dir in
  if List.length files > max_agent_core_history_retained then
    files
    |> List.filteri (fun index _ -> index >= max_agent_core_history_retained)
    |> List.iter (fun filename ->
         let path = agent_core_history_path ~session_dir ~snapshot_id:filename in
         try Sys.remove path with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             Log.Keeper.warn "AGENT_CORE snapshot cleanup failed for %s: %s"
               path (Printexc.to_string exn);
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string CheckpointFailures)
               ~labels:[("site", Keeper_checkpoint_store_failure_site.(to_label Agent_core_cleanup))]
               ())

let hardlink_agent_core_history_from_canonical
    ~(session_dir : string)
    ~(session_id : string)
    ~(snapshot_id : string) : (unit, string) result =
  let canonical_path = agent_core_checkpoint_path ~session_dir ~session_id in
  let snapshot_path = agent_core_history_path ~session_dir ~snapshot_id in
  if not (Fs_compat.file_exists canonical_path) then
    Error "canonical AGENT_CORE checkpoint is missing"
  else
    try
      if Fs_compat.file_exists snapshot_path then Sys.remove snapshot_path;
      Unix.link canonical_path snapshot_path;
      Ok ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Error (Printexc.to_string exn)

let save_agent_core_history ~(session_dir : string) (ckpt : Agent_core.Checkpoint.t) : unit =
  let snapshot_id = agent_core_history_snapshot_id_of_checkpoint ckpt in
  let save_snapshot_file () =
    Keeper_fs.save_atomic
      (agent_core_history_path ~session_dir ~snapshot_id)
      (encode_checkpoint_string_off_scheduler ckpt)
  in
  let save_result =
    match
      hardlink_agent_core_history_from_canonical
        ~session_dir ~session_id:ckpt.session_id ~snapshot_id
    with
    | Ok () -> Ok ()
    | Error _ -> save_snapshot_file ()
  in
  match save_result with
  | Ok () ->
    prune_agent_core_history ~session_dir
  | Error msg ->
    Log.Keeper.warn "save_agent_core_history failed for %s: %s" snapshot_id msg;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string CheckpointFailures)
      ~labels:[("site", Keeper_checkpoint_store_failure_site.(to_label Agent_core_save))]
      ()

let delete_agent_core_history_files ~(session_dir : string) ~(snapshot_ids : string list)
    : string list * string list =
  List.fold_left
    (fun (deleted, missing) snapshot_id ->
      (* [snapshot_ids] arrive verbatim from the dashboard POST body; a
         non-segment id ("../..") would aim [Sys.remove] outside the
         session directory. Such an id can never name a history entry, so
         it is reported [missing] without touching the filesystem. *)
      if not (leaf_is_real_segment snapshot_id) then
        (deleted, snapshot_id :: missing)
      else
      let path = agent_core_history_path ~session_dir ~snapshot_id in
      if Fs_compat.file_exists path then (
        try
          Sys.remove path;
          (snapshot_id :: deleted, missing)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Log.Keeper.warn "AGENT_CORE snapshot delete failed for %s: %s"
              path (Printexc.to_string exn);
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string CheckpointFailures)
              ~labels:[("site", Keeper_checkpoint_store_failure_site.(to_label Agent_core_delete))]
              ();
            (deleted, snapshot_id :: missing))
      else
        (deleted, snapshot_id :: missing))
    ([], [])
    snapshot_ids
  |> fun (deleted, missing) -> (List.rev deleted, List.rev missing)

(* Delta Checkpoint Shadow-Apply removed: Agent_core.Checkpoint.delta
   type was removed upstream. Functions had zero callers. *)

type checkpoint_load_error =
  | Not_found
  | Store_error of string
  | Parse_error of string
  | Io_error of string
  (** Catch-all for agent-core errors outside the Io / Serialization families
      (Api / Agent / Mcp / Config / Orchestration / Internal).
      Distinct from Io_error so observers can tell a local
      checkpoint-store I/O failure apart from an agent-core failure that
      surfaced during a load. (#8605 family) *)
  | Agent_core_error of string

(* RFC-0089 G4 (#15514-sibling): [Not_found] classification was previously
   string-matched against [FileOpFailed.detail] across four prefixes
   ("no_such_file", "no such file", "unix_error (enoent", "eio.io fs
   not_found") + a substring fallback. This was a string classifier
   workaround (CLAUDE.md §워크어라운드 #2): [Agent_core.Error] is already a
   closed sum type, but [FileOpFailed.detail] flattens the underlying
   filesystem exception via [Printexc.to_string], throwing away typed
   provenance.

   Root fix: lift ENOENT detection to the OS boundary *before* invoking
   agent core. [Agent_core.Checkpoint_store.exists : t -> string -> bool] gives
   us a typed presence check, so the cold-start "file absent" case is now
   first-class [bool] and never reaches [classify_core_error]. Any agent-core error
   that *does* surface from [load] is, by construction, a real I/O /
   serialization / agent-core fault and routes to [Io_error] / [Store_error] /
   [Parse_error] / [Agent_core_error] without inspecting strings.

   #8605 family: exhaustive on [Agent_core.Error.t] top-level
   variants. The wildcards on Io _ and Serialization _ remain narrow (one
   level deep) so a future inner variant lands in the semantically correct
   category, and a future top-level core_error variant becomes a build
   error forcing a deliberate routing decision. *)
let classify_core_error (e : Agent_core.Error.t) : checkpoint_load_error =
  match e with
  | Io (FileOpFailed r) ->
      Io_error (sprintf "file %s failed on %s: %s" r.op r.path r.detail)
  | Io (ValidationFailed r) -> Store_error r.detail
  | Serialization (JsonParseError r) -> Parse_error r.detail
  | Serialization (VersionMismatch r) ->
      Parse_error (sprintf "version mismatch: expected %d, got %d" r.expected r.got)
  | Serialization (UnknownVariant r) ->
      Parse_error (sprintf "unknown variant %s: %s" r.type_name r.value)
  | Api _ | Provider _ | Agent _ | Mcp _ | Config _
  | Orchestration _ | Internal _ | Internal_carried { message = _; _ } ->
      Agent_core_error (Agent_core.Error.to_string e)

(* Both checkpoint reads take their bytes through
   [Fs_compat.load_owned_regular_file]: the read runs on a system thread when
   the Eio filesystem is active, and the file must sit inside the owned chain
   the writers publish into ([~ownership_root], the parent of the session
   directory), so a symbolic link or a changed parent is refused. Until
   2026-09-05 the bytes came through [Fs_compat.load_file], whose Eio branch
   ([Eio.Path.load]) copied the 13-35 MB file on the calling fiber and held
   the main domain 45-180 ms per turn — the [openat -> switch] class of RFC
   main-domain-scheduler-latency §8.8. *)
let read_checkpoint_bytes ~(session_dir : string) path : (string, checkpoint_load_error) result =
  match
    Fs_compat.load_owned_regular_file
      ~ownership_root:(Filename.dirname session_dir)
      path
  with
  | Ok (Some bytes) -> Ok bytes
  | Ok None -> Error Not_found
  | Error error ->
    Error (Io_error (Fs_compat.owned_regular_file_read_error_to_string error))

let load_agent_core_history_file ~(session_dir : string) ~(snapshot_id : string) :
    (Agent_core.Checkpoint.t, checkpoint_load_error) result =
  (* [snapshot_id] reaches this entry point from the dashboard HTTP
     surface; a non-segment id ("../..") would read outside the session
     directory, so it is refused as absent before any filesystem access. *)
  if not (leaf_is_real_segment snapshot_id) then Error Not_found
  else (
    let path = agent_core_history_path ~session_dir ~snapshot_id in
    if Fs_compat.file_exists path then
      try
        match read_checkpoint_bytes ~session_dir path with
        | Error e -> Error e
        | Ok bytes ->
          (match decode_checkpoint_off_scheduler bytes with
           | Ok ckpt -> Ok ckpt
           | Error e -> Error (classify_core_error e))
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> Error (Io_error (Printexc.to_string exn))
    else Error Not_found)

(* ── Canonical summary (RFC main-domain-scheduler-latency §8 P4b) ────
   The scalars other paths need from the canonical checkpoint — session_id
   and turn_count for the save watermark, the message count for the
   heartbeat — are kept per canonical path together with the identity of the
   file they describe. Every writer publishes the canonical file by atomic
   rename, so a changed file is a new inode; equal (device, inode, size,
   mtime) therefore means the file the summary describes is still the one on
   disk. A summary is filled from a parse of the bytes on disk, or from the
   value a writer installed. The whole checkpoint value is never cached: its
   codec round trip is not proven exact, and a second copy of a 13-20 MB
   checkpoint per keeper would grow the live heap the major GC walks.
   Measured 2026-09-05: the save watermark alone re-read and re-parsed the
   canonical file on every turn, 5.2 GB allocated per 4 minutes across the
   fleet, and every heartbeat did the same for one integer. *)
type canonical_identity =
  { device : int
  ; inode : int
  ; size : int
  ; mtime : float
  }

type canonical_summary =
  { identity : canonical_identity
  ; summary_session_id : string
  ; summary_turn_count : int
  ; summary_message_count : int
  }

let canonical_summaries : (string, canonical_summary) Hashtbl.t = Hashtbl.create 16

(* Stdlib mutex on purpose: touched from systhread and main-domain paths; the
   critical section is a Hashtbl lookup with no yield. *)
let canonical_summaries_mutex = Stdlib.Mutex.create ()

let canonical_identity_equal left right =
  Int.equal left.device right.device
  && Int.equal left.inode right.inode
  && Int.equal left.size right.size
  && Float.equal left.mtime right.mtime

let canonical_identity_of_stats (stats : Unix.stats) =
  { device = stats.st_dev
  ; inode = stats.st_ino
  ; size = stats.st_size
  ; mtime = stats.st_mtime
  }

let canonical_identity_opt path =
  match Unix.stat path with
  | stats when stats.Unix.st_kind = Unix.S_REG -> Some (canonical_identity_of_stats stats)
  | _ -> None
  | exception Unix.Unix_error _ -> None

(* [Some summary] only while the file at [canonical_path] is the one the
   summary was taken from. *)
let cached_summary ~canonical_path =
  match canonical_identity_opt canonical_path with
  | None -> None
  | Some identity ->
    Stdlib.Mutex.protect canonical_summaries_mutex (fun () ->
      match Hashtbl.find_opt canonical_summaries canonical_path with
      | Some summary when canonical_identity_equal summary.identity identity ->
        Some summary
      | Some _ | None -> None)

let summary_of_checkpoint ~identity (checkpoint : Agent_core.Checkpoint.t) =
  { identity
  ; summary_session_id = checkpoint.session_id
  ; summary_turn_count = checkpoint.turn_count
  ; summary_message_count = List.length checkpoint.messages
  }

let publish_summary ~canonical_path summary =
  Stdlib.Mutex.protect canonical_summaries_mutex (fun () ->
    Hashtbl.replace canonical_summaries canonical_path summary)

(* After a parse: the summary describes the bytes parsed only if the file
   identity is the same before and after the read. Otherwise a rename landed
   during the read and nothing is published; the next access reads again. *)
let publish_summary_after_parse ~canonical_path ~identity_before checkpoint =
  match identity_before, canonical_identity_opt canonical_path with
  | Some before, Some after when canonical_identity_equal before after ->
    publish_summary ~canonical_path (summary_of_checkpoint ~identity:before checkpoint)
  | Some _, (Some _ | None) | None, (Some _ | None) -> ()

(* After a durable atomic write under the session lock: the file at the path
   is the one just installed. *)
let publish_summary_after_write ~canonical_path checkpoint =
  match canonical_identity_opt canonical_path with
  | Some identity ->
    publish_summary ~canonical_path (summary_of_checkpoint ~identity checkpoint)
  | None -> ()

let load_agent_core ~(session_dir : string) ~(session_id : string) :
    (Agent_core.Checkpoint.t, checkpoint_load_error) result =
  (* RFC-0089 G4: typed ENOENT classification at the OS boundary.
     [Fs_compat.file_exists] answers cold-start absence as a [bool] before
     any read, so a missing checkpoint is never inferred from a stringified
     error detail and [classify_core_error] keeps no [Not_found] arm.

     One read path for Eio and non-Eio contexts: [read_checkpoint_bytes]
     reads on a system thread when the fs capability is installed, and the
     decode is routed off the calling fiber (#25077). The previous
     [Agent_core.Checkpoint_store.load] branch read the same file but
     decoded the 0.7-1.4MB payload inline in agent core on the calling fiber
     (agent-core boundary), and its [create] could mkdir on a pure read. Agent Core
     branch also validated [session_id] (empty / separator / NUL); the
     segment check below keeps that rejection, mapped to [Store_error]
     exactly as agent core's ValidationFailed was via [classify_core_error]. *)
  if not (leaf_is_real_segment session_id) then
    Error (Store_error "session_id is not a real path segment")
  else
  let path = agent_core_checkpoint_path ~session_dir ~session_id in
  if Fs_compat.file_exists path then
    let identity_before = canonical_identity_opt path in
    try
      match read_checkpoint_bytes ~session_dir path with
      | Error e -> Error e
      | Ok bytes ->
        (match decode_checkpoint_off_scheduler bytes with
         | Ok ckpt ->
           publish_summary_after_parse ~canonical_path:path ~identity_before ckpt;
           Ok ckpt
         | Error e -> Error (classify_core_error e))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Error (Io_error (Printexc.to_string exn))
  else Error Not_found

(** Message count of the canonical checkpoint. Answered from the canonical
    summary while the file on disk is the one the summary was taken from;
    otherwise the checkpoint is loaded and parsed once, which fills the
    summary. [Ok None] when there is no checkpoint. *)
let canonical_message_count ~(session_dir : string) ~(session_id : string)
  : (int option, checkpoint_load_error) result =
  if not (leaf_is_real_segment session_id) then
    Error (Store_error "session_id is not a real path segment")
  else
    let canonical_path = agent_core_checkpoint_path ~session_dir ~session_id in
    match cached_summary ~canonical_path with
    | Some summary -> Ok (Some summary.summary_message_count)
    | None ->
      (match load_agent_core ~session_dir ~session_id with
       | Ok checkpoint -> Ok (Some (List.length checkpoint.messages))
       | Error Not_found -> Ok None
       | Error error -> Error error)

let canonical_byte_count ~(session_dir : string) ~(session_id : string)
  : (int option, checkpoint_load_error) result =
  if not (leaf_is_real_segment session_id) then
    Error (Store_error "session_id is not a real path segment")
  else
    let canonical_path = agent_core_checkpoint_path ~session_dir ~session_id in
    match cached_summary ~canonical_path with
    | Some summary -> Ok (Some summary.identity.size)
    | None ->
      (match Unix.stat canonical_path with
       | stats when stats.Unix.st_kind = Unix.S_REG -> Ok (Some stats.Unix.st_size)
       | _ -> Error (Store_error "canonical checkpoint is not a regular file")
       | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
       | exception Unix.Unix_error (code, _, _) ->
         Error
           (Store_error
              ("canonical checkpoint stat failed: " ^ Unix.error_message code)))

(* ── RFC-0225 §3.2: disk-SSOT monotonic checkpoint transaction ──────
   One stable per-session lock covers canonical disk load, comparison,
   durable publication, and history capture. The canonical file is the only
   admission watermark; no process-local checkpoint truth is retained. *)

type save_agent_core_relation = [ `Cold | `Forward | `Equal ]

type save_agent_core_outcome =
  | Saved of { relation : save_agent_core_relation; turn_count : int }
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
  | Store_error detail
  | Parse_error detail
  | Io_error detail
  | Agent_core_error detail -> detail

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
        Eio_guard.run_in_systhread (fun () ->
          let parent = Unix.realpath parent in
          if (Unix.stat parent).Unix.st_kind <> Unix.S_DIR
          then
            raise
              (Unix.Unix_error
                 (Unix.ENOTDIR, "checkpoint_session_parent", parent));
          let location = Filename.concat parent leaf in
          (match Unix.lstat location with
           | { Unix.st_kind = Unix.S_LNK; _ } ->
             raise
               (Unix.Unix_error
                  (Unix.ELOOP, "checkpoint_session_leaf", location))
           | _ -> ()
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

let archive_agent_core_history_best_effort ~session_dir ckpt =
  try save_agent_core_history ~session_dir ckpt with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.warn "AGENT_CORE snapshot archive write failed for %s: %s"
      ckpt.session_id (Printexc.to_string exn);
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string CheckpointFailures)
      ~labels:
        [ ( "site"
          , Keeper_checkpoint_store_failure_site.(to_label Agent_core_archive) )
        ]
      ()

let load_canonical_bytes_strict path =
  let unix_error error operation argument =
    Io_error
      (Printf.sprintf "%s(%s): %s"
         operation argument (Unix.error_message error))
  in
  let read () =
    match Unix.lstat path with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
    | exception Unix.Unix_error (error, operation, argument) ->
      Error (unix_error error operation argument)
    | stat when stat.Unix.st_kind <> Unix.S_REG ->
      Error (Io_error ("canonical checkpoint is not a regular file: " ^ path))
    | stats ->
      let identity_before = canonical_identity_of_stats stats in
      (try
         let buffer = Buffer.create 4096 in
         let bytes = Bytes.create 65536 in
         let rec read_fd fd =
           match Unix.read fd bytes 0 (Bytes.length bytes) with
           | 0 -> Buffer.contents buffer
           | count ->
             Buffer.add_subbytes buffer bytes 0 count;
             read_fd fd
           | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_fd fd
         in
         let fd = Unix.openfile path [ Unix.O_CLOEXEC; Unix.O_RDONLY ] 0 in
         let content =
           Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> read_fd fd)
         in
         Ok (Some (identity_before, content))
       with
       | Unix.Unix_error (error, operation, argument) ->
         Error (unix_error error operation argument))
  in
  match Eio_guard.run_in_systhread read with
  | Ok content -> Ok content
  | Error _ as error -> error
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Io_error (Printexc.to_string exn))

let load_canonical_bytes_and_checkpoint_strict path =
  match load_canonical_bytes_strict path with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some (identity_before, content)) ->
    (* This decode runs inside the durable session lock, so the caller now
       waits on worker-pool capacity while holding it (the submit is a
       rendezvous at CPU weight). Accepted trade-off: the wait is bounded
       by pool job runtimes and only delays this one session's
       transaction, whereas the previous inline parse stalled every fiber
       on the scheduler domain for the whole conversion. *)
    (match decode_checkpoint_off_scheduler content with
     | Ok checkpoint ->
       publish_summary_after_parse
         ~canonical_path:path
         ~identity_before:(Some identity_before)
         checkpoint;
       Ok (Some (content, checkpoint))
     | Error error -> Error (classify_core_error error))

let load_canonical_strict path =
  load_canonical_bytes_and_checkpoint_strict path
  |> Result.map (Option.map snd)

type watermark = { session_id : string; turn_count : int }

let known_watermark ~canonical_path
  : (watermark option, checkpoint_load_error) result =
  match cached_summary ~canonical_path with
  | Some summary ->
    Ok
      (Some
         { session_id = summary.summary_session_id
         ; turn_count = summary.summary_turn_count
         })
  | None ->
    load_canonical_strict canonical_path
    |> Result.map
         (Option.map (fun (existing : Agent_core.Checkpoint.t) ->
            { session_id = existing.session_id; turn_count = existing.turn_count }))

type checkpoint_identity_error =
  | Session_id_invalid of string
  | Ref_create_failed of Keeper_checkpoint_ref.create_error

type checkpoint_ref_load_error =
  | Ref_not_found
  | Ref_read_failed of checkpoint_load_error
  | Ref_identity_invalid of checkpoint_identity_error
  | Ref_session_mismatch of
      { expected : Keeper_id.Trace_id.t
      ; actual : Keeper_id.Trace_id.t
      }
  | Ref_lock_failed of string

type exact_checkpoint_snapshot =
  { checkpoint : Agent_core.Checkpoint.t
  ; reference : Keeper_checkpoint_ref.t
  ; canonical_bytes : string
  }

let exact_snapshot_checkpoint snapshot = snapshot.checkpoint
let exact_snapshot_reference snapshot = snapshot.reference
let exact_snapshot_canonical_bytes snapshot = snapshot.canonical_bytes

type checkpoint_cas_error =
  | Source_unavailable of checkpoint_ref_load_error
  | Source_changed of Keeper_checkpoint_ref.t
  | Candidate_identity_invalid of checkpoint_identity_error
  | Candidate_session_mismatch of
      { expected : Keeper_id.Trace_id.t
      ; candidate : Keeper_id.Trace_id.t
      }
  | Candidate_generation_mismatch of
      { expected : int
      ; candidate : int
      }
   | Candidate_turn_regressed of
       { source_turn : int
       ; candidate_turn : int
       }
   | Commit_not_installed of Keeper_fs.durable_write_error

type checkpoint_installation_auxiliary =
  | Commit_durability_unknown of Keeper_fs.durable_write_error
  | Commit_observer_failed of Eio.Exn.with_bt
  | Release_process_lock_failed of File_lock_eio.durable_lock_error
  | Post_commit_unwind_interrupted of Eio.Exn.with_bt
  | History_write_failed of Eio.Exn.with_bt

type not_installed_checkpoint =
  { cause : checkpoint_cas_error
  ; auxiliary : checkpoint_installation_auxiliary list
  }

type installed_checkpoint =
  { installed_ref : Keeper_checkpoint_ref.t
  ; auxiliary : checkpoint_installation_auxiliary list
  }

type checkpoint_installation =
  | Not_installed of not_installed_checkpoint
  | Installed of installed_checkpoint

let not_installed cause = Not_installed { cause; auxiliary = [] }

let append_installation_auxiliary installation auxiliary =
  match installation with
  | Not_installed outcome ->
    Not_installed
      { outcome with
        auxiliary = outcome.auxiliary @ [ auxiliary ]
      }
  | Installed outcome ->
    Installed
      { outcome with
        auxiliary = outcome.auxiliary @ [ auxiliary ]
      }
;;

let checkpoint_ref_of_canonical_bytes canonical_bytes
    (checkpoint : Agent_core.Checkpoint.t) =
  match Keeper_id.Trace_id.of_string checkpoint.Agent_core.Checkpoint.session_id with
  | Error reason -> Error (Session_id_invalid reason)
  | Ok trace_id ->
    Keeper_checkpoint_ref.create
      ~trace_id
      ~turn_count:checkpoint.turn_count
      ~canonical_checkpoint_bytes:canonical_bytes
    |> Result.map_error (fun error -> Ref_create_failed error)

let exact_snapshot_of_checkpoint ~expected_session_id ~canonical_bytes checkpoint =
  match checkpoint_ref_of_canonical_bytes canonical_bytes checkpoint with
  | Error error -> Error (Ref_identity_invalid error)
  | Ok reference
    when not
           (Keeper_id.Trace_id.equal
              expected_session_id reference.trace_id) ->
    Error
      (Ref_session_mismatch
         { expected = expected_session_id; actual = reference.trace_id })
  | Ok reference -> Ok { checkpoint; reference; canonical_bytes }
;;

let exact_snapshot_of_canonical_bytes ~expected_session_id canonical_bytes =
  match decode_checkpoint_off_scheduler canonical_bytes with
  | Error error -> Error (Ref_read_failed (classify_core_error error))
  | Ok checkpoint ->
    exact_snapshot_of_checkpoint
      ~expected_session_id
      ~canonical_bytes
      checkpoint
;;

let load_ref_locked ~session_dir ~expected_session_id =
  let canonical_path =
    agent_core_checkpoint_path
      ~session_dir
      ~session_id:(Keeper_id.Trace_id.to_string expected_session_id)
  in
  match load_canonical_bytes_and_checkpoint_strict canonical_path with
  | Error error -> Error (Ref_read_failed error)
  | Ok None -> Error Ref_not_found
  | Ok (Some (canonical_bytes, checkpoint)) ->
    exact_snapshot_of_checkpoint
      ~expected_session_id
      ~canonical_bytes
      checkpoint

let load_agent_core_exact_snapshot ~session_dir ~session_id =
  match Keeper_id.Trace_id.of_string session_id with
  | Error reason -> Error (Ref_identity_invalid (Session_id_invalid reason))
  | Ok expected_session_id ->
    (match
       with_session_lock ~session_dir (fun session_dir ->
         load_ref_locked ~session_dir ~expected_session_id)
     with
     | Ok result -> result
     | Error detail -> Error (Ref_lock_failed detail))

let load_agent_core_with_ref ~session_dir ~session_id =
  load_agent_core_exact_snapshot ~session_dir ~session_id
  |> Result.map (fun snapshot ->
    exact_snapshot_checkpoint snapshot, exact_snapshot_reference snapshot)
;;

let lock_failure_not_installed error =
  not_installed
    (Source_unavailable
       (Ref_lock_failed (File_lock_eio.durable_lock_error_to_string error)))
;;

let installation_of_lock_observation = function
  | File_lock_eio.Lock_not_acquired error -> lock_failure_not_installed error
  | File_lock_eio.Body_completed { value; release_error = None } -> value
  | File_lock_eio.Body_completed { value; release_error = Some error } ->
    append_installation_auxiliary value (Release_process_lock_failed error)
;;

let with_checkpoint_cas_lock ~session_dir f =
  match canonical_session_location session_dir with
  | Error error ->
    not_installed
      (Source_unavailable
         (Ref_lock_failed (save_agent_core_error_to_string error)))
  | Ok session_dir ->
    let lock_path = session_dir ^ ".checkpoint.lock" in
    File_lock_eio.with_durable_lock_observed
      ~lock_path
      (fun () -> f session_dir)
    |> installation_of_lock_observation

let save_agent_core_if_source_with
    ~with_checkpoint_cas_lock
    ~write_checkpoint_bytes
    ~(on_checkpoint_commit_observer : Keeper_checkpoint_ref.t -> unit)
    ~session_dir
    ~(expected_source_ref : Keeper_checkpoint_ref.t)
    (candidate : Agent_core.Checkpoint.t) =
  let candidate_bytes =
    offload_checkpoint_cpu (fun () ->
      Yojson.Safe.to_string (Agent_core.Checkpoint.to_json candidate))
  in
  match checkpoint_ref_of_canonical_bytes candidate_bytes candidate with
  | Error error -> not_installed (Candidate_identity_invalid error)
  | Ok candidate_ref
    when not
           (Keeper_id.Trace_id.equal
              expected_source_ref.trace_id candidate_ref.trace_id) ->
    not_installed
      (Candidate_session_mismatch
         { expected = expected_source_ref.trace_id
         ; candidate = candidate_ref.trace_id
         })
  | Ok candidate_ref
    when candidate_ref.turn_count < expected_source_ref.turn_count ->
    not_installed
      (Candidate_turn_regressed
         { source_turn = expected_source_ref.turn_count
         ; candidate_turn = candidate_ref.turn_count
         })
  | Ok candidate_ref ->
    let expected_session_id = expected_source_ref.trace_id in
    let observed_ref = ref None in
    let committed_installation = ref None in
    let publish auxiliary =
      let installed = { installed_ref = candidate_ref; auxiliary } in
      committed_installation := Some installed;
      Installed installed
    in
    let observe_commit () =
      observed_ref := Some candidate_ref;
      on_checkpoint_commit_observer candidate_ref
    in
    let outcome =
      try
        `Returned
          (with_checkpoint_cas_lock ~session_dir (fun session_dir ->
         match load_ref_locked ~session_dir ~expected_session_id with
         | Error error -> not_installed (Source_unavailable error)
         | Ok snapshot
           when not
                  (Keeper_checkpoint_ref.equal
                     expected_source_ref
                     (exact_snapshot_reference snapshot)) ->
           not_installed (Source_changed (exact_snapshot_reference snapshot))
         | Ok _ ->
           let canonical_path =
             agent_core_checkpoint_path
               ~session_dir
               ~session_id:(Keeper_id.Trace_id.to_string expected_session_id)
           in
           let ownership_root = Filename.dirname session_dir in
           (match
              write_checkpoint_bytes
                ~on_durable_commit:observe_commit
                ~ownership_root
                ~path:canonical_path
                ~bytes:candidate_bytes
            with
            | Error error when error.Keeper_fs.renamed ->
              publish [ Commit_durability_unknown error ]
            | Error error -> not_installed (Commit_not_installed error)
            | Ok Keeper_fs.Committed ->
              (* The durable writer installs [candidate_bytes] verbatim - the
                 exact bytes [candidate_ref] was derived from - so the
                 published file and the returned ref agree by construction.
                 The hint is auxiliary and cannot downgrade that fact. *)
              publish []
            | Ok (Keeper_fs.Committed_but_observer_failed failure) ->
              publish [ Commit_observer_failed failure ])))
      with
      | exn -> `Raised (exn, Printexc.get_raw_backtrace ())
    in
    let observed_installation installed_ref =
      match !committed_installation with
      | Some installed -> installed
      | None -> { installed_ref; auxiliary = [] }
    in
    let known_installed_ref () =
      match !committed_installation with
      | Some installed -> Some installed.installed_ref
      | None -> !observed_ref
    in
    (match outcome with
     | `Returned installation -> installation
     | `Raised (exn, backtrace) ->
       (match known_installed_ref () with
        | Some installed_ref ->
          append_installation_auxiliary
            (Installed (observed_installation installed_ref))
            (Post_commit_unwind_interrupted (exn, backtrace))
        | None -> Printexc.raise_with_backtrace exn backtrace))

let write_checkpoint_bytes
    ~on_durable_commit
    ~ownership_root
    ~path
    ~bytes =
  Keeper_fs.save_bytes_durable_atomic_observed
    ~on_durable_commit
    ~ownership_root
    path
    bytes
;;

let save_agent_core_if_source ~session_dir ~expected_source_ref candidate =
  save_agent_core_if_source_with
    ~with_checkpoint_cas_lock
    ~write_checkpoint_bytes
    ~on_checkpoint_commit_observer:(fun _ -> ())
    ~session_dir
    ~expected_source_ref
    candidate
;;

module For_testing = struct
  let save_agent_core_if_source_with_observer
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      candidate =
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      candidate
  ;;

  let save_agent_core_if_source_with_release_failure
      ~release_failure
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      candidate =
    let with_release_failure ~session_dir f =
      match canonical_session_location session_dir with
      | Error error ->
        not_installed
          (Source_unavailable
             (Ref_lock_failed (save_agent_core_error_to_string error)))
      | Ok session_dir ->
        let lock_path = session_dir ^ ".checkpoint.lock" in
        File_lock_eio.For_testing.with_durable_lock_observed_with_release_failure
          ~release_failure
          ~lock_path
          (fun () -> f session_dir)
        |> installation_of_lock_observation
    in
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock:with_release_failure
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      candidate
  ;;

  let save_agent_core_if_source_with_acquire_failure
      ~acquire_failure
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      candidate =
    let with_acquire_failure ~session_dir:_ _f =
      installation_of_lock_observation
        (File_lock_eio.Lock_not_acquired acquire_failure)
    in
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock:with_acquire_failure
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      candidate
  ;;

  let save_agent_core_if_source_with_writer
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      candidate =
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      candidate
  ;;

  let save_agent_core_if_source_with_post_commit_unwind
      ~post_commit_unwind
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      candidate =
    let with_post_commit_unwind ~session_dir f =
      match with_checkpoint_cas_lock ~session_dir f with
      | Installed _ as installation ->
        post_commit_unwind ();
        installation
      | Not_installed _ as outcome -> outcome
    in
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock:with_post_commit_unwind
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      candidate
  ;;
end

let save_outcome_after_write ~session_dir ~canonical_path ~known ckpt =
  publish_summary_after_write ~canonical_path ckpt;
  archive_agent_core_history_best_effort ~session_dir ckpt;
  Ok
    (Saved
       { relation = save_relation ~known ~incoming:ckpt.turn_count
       ; turn_count = ckpt.turn_count
       })

let save_agent_core_classified_typed
    ~(session_dir : string)
    (ckpt : Agent_core.Checkpoint.t)
  : (save_agent_core_outcome, save_agent_core_error) result =
  match Keeper_transcript_unit.validate ckpt.messages with
  | Error structural -> Error (Structurally_invalid structural)
  | Ok () ->
  match Keeper_id.Trace_id.of_string ckpt.session_id with
  | Error reason -> Error (Invalid_session_id reason)
  | Ok trace_id ->
    with_session_lock_typed ~session_dir (fun session_dir ->
      let session_id = Keeper_id.Trace_id.to_string trace_id in
      let canonical_path = agent_core_checkpoint_path ~session_dir ~session_id in
      match known_watermark ~canonical_path with
      | Error error -> Error (Existing_checkpoint_unreadable error)
      | Ok (Some existing) when not (String.equal existing.session_id session_id) ->
        Error
          (Existing_checkpoint_unreadable
             (Store_error
                (Printf.sprintf
                   "canonical checkpoint identity mismatch: expected=%s actual=%s"
                   session_id existing.session_id)))
      | Ok (Some existing) when ckpt.turn_count < existing.turn_count ->
        Log.Keeper.warn
          "stale AGENT_CORE checkpoint write skipped for %s: incoming turn_count=%d, last saved=%d"
          ckpt.session_id ckpt.turn_count existing.turn_count;
        Otel_metric_store.inc_counter
          "masc_keeper_checkpoint_stale_noop_total"
          ~labels:[("site", "store_watermark")]
          ();
        Ok
          (Stale_noop
             { incoming_turn_count = ckpt.turn_count
             ; known_turn_count = existing.turn_count
             })
      | Ok existing ->
        let known = Option.map (fun (w : watermark) -> w.turn_count) existing in
        let ownership_root = Filename.dirname session_dir in
        let write payload =
          Keeper_fs.save_json_durable_atomic_from
            ~ownership_root
            ~pretty:false
            canonical_path
            (fun () -> Agent_core.Checkpoint.to_json payload)
        in
        (match write ckpt with
         | Ok () -> save_outcome_after_write ~session_dir ~canonical_path ~known ckpt
         (* #31677: a payload-encode refusal means the in-memory checkpoint
            carries a json payload the v10 contract cannot encode — a
            provider-authored duplicate key or non-finite float. Without
            recovery the write refuses at this stage of every later turn,
            which is what bricked keepers for hours on 2026-08-29. The
            codec still rejects the original; this drop-and-retry-once
            stores the recovered copy, so the keeper survives and the next
            restart loads a clean checkpoint. Any other stage failure (or a
            refusal with nothing droppable) keeps the original error. *)
         | Error ({ stage = Keeper_fs.Payload_encode; _ } as error) -> (
           match Agent_core.Checkpoint.drop_unencodable_json ckpt with
           | None -> Error (Canonical_write_failed error)
           | Some recovered ->
             Log.Keeper.warn
               "checkpoint payload unencodable (%s); storing the recovery \
                copy with the offending json dropped for %s"
               (Keeper_fs.durable_write_error_to_string error)
               ckpt.session_id;
             (match write recovered with
              | Error retry_error -> Error (Canonical_write_failed retry_error)
              | Ok () ->
                save_outcome_after_write ~session_dir ~canonical_path ~known recovered))
         | Error error -> Error (Canonical_write_failed error)))

let save_agent_core_classified ~(session_dir : string) (ckpt : Agent_core.Checkpoint.t)
  : (save_agent_core_outcome, string) result =
  save_agent_core_classified_typed ~session_dir ckpt
  |> Result.map_error save_agent_core_error_to_string
