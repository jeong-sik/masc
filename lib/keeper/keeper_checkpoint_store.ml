(** Keeper_checkpoint_store — checkpoint file I/O.

    Handles saving, loading, listing, and pruning OAS checkpoint JSON files
    within a session directory. Separated from [Keeper_working_context]
    so that file I/O concerns do not mix with context types and
    pure operations.

    @since keeper-ctx-split *)

open Printf

(* ================================================================ *)
(* OAS Checkpoints                                                    *)
(* ================================================================ *)

let oas_checkpoint_path ~(session_dir : string) ~(session_id : string) =
  Filename.concat session_dir (session_id ^ ".json")

let oas_history_prefix = "oas-snapshot-"
let oas_history_suffix = ".json"

let is_oas_history_file (filename : string) : bool =
  let len = String.length filename in
  len > String.length oas_history_prefix + String.length oas_history_suffix
  && String.sub filename 0 (String.length oas_history_prefix) = oas_history_prefix
  && String.sub filename (len - String.length oas_history_suffix)
       (String.length oas_history_suffix) = oas_history_suffix

let list_oas_history_files ~(session_dir : string) : string list =
  if not (Fs_compat.file_exists session_dir) then []
  else
    Sys.readdir session_dir
    |> Array.to_list
    |> List.filter is_oas_history_file
    |> List.sort (fun a b -> compare b a)

let max_oas_history_retained = 12

let oas_history_path ~(session_dir : string) ~(snapshot_id : string) =
  Filename.concat session_dir snapshot_id

(* A name below the session root ([leaf] of a session_dir, or a
   [snapshot_id] appended by [oas_history_path]) must denote exactly one
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
    (Agent_sdk.Checkpoint.t, Agent_sdk.Error.sdk_error) result =
  offload_checkpoint_cpu (fun () -> Agent_sdk.Checkpoint.of_string content)

let encode_checkpoint_string_off_scheduler (ckpt : Agent_sdk.Checkpoint.t) :
    string =
  offload_checkpoint_cpu (fun () -> Agent_sdk.Checkpoint.to_string ckpt)

let keeper_generation_context_key = "keeper_generation"

let keeper_generation_of_context (context : Agent_sdk.Context.t) : int =
  match
    Agent_sdk.Context.get_scoped context Agent_sdk.Context.Session
      keeper_generation_context_key
  with
  | Some (`Int n) -> n
  | Some (`Intlit raw) -> Option.value ~default:0 (int_of_string_opt raw)
  | _ -> 0

let oas_history_snapshot_id_of_checkpoint (ckpt : Agent_sdk.Checkpoint.t) : string =
  let generation = keeper_generation_of_context ckpt.context in
  let created_ms = max 0 (int_of_float (ckpt.created_at *. 1000.0)) in
  Printf.sprintf "%s%013d-g%d%s"
    oas_history_prefix created_ms generation oas_history_suffix

let prune_oas_history ~(session_dir : string) : unit =
  let files = list_oas_history_files ~session_dir in
  if List.length files > max_oas_history_retained then
    files
    |> List.filteri (fun index _ -> index >= max_oas_history_retained)
    |> List.iter (fun filename ->
         let path = oas_history_path ~session_dir ~snapshot_id:filename in
         try Sys.remove path with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             Log.Keeper.warn "OAS snapshot cleanup failed for %s: %s"
               path (Printexc.to_string exn);
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string CheckpointFailures)
               ~labels:[("site", Keeper_checkpoint_store_failure_site.(to_label Oas_cleanup))]
               ())

let hardlink_oas_history_from_canonical
    ~(session_dir : string)
    ~(session_id : string)
    ~(snapshot_id : string) : (unit, string) result =
  let canonical_path = oas_checkpoint_path ~session_dir ~session_id in
  let snapshot_path = oas_history_path ~session_dir ~snapshot_id in
  if not (Fs_compat.file_exists canonical_path) then
    Error "canonical OAS checkpoint is missing"
  else
    try
      if Fs_compat.file_exists snapshot_path then Sys.remove snapshot_path;
      Unix.link canonical_path snapshot_path;
      Ok ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Error (Printexc.to_string exn)

let save_oas_history ~(session_dir : string) (ckpt : Agent_sdk.Checkpoint.t) : unit =
  let snapshot_id = oas_history_snapshot_id_of_checkpoint ckpt in
  let save_snapshot_file () =
    Keeper_fs.save_atomic
      (oas_history_path ~session_dir ~snapshot_id)
      (encode_checkpoint_string_off_scheduler ckpt)
  in
  let save_result =
    match
      hardlink_oas_history_from_canonical
        ~session_dir ~session_id:ckpt.session_id ~snapshot_id
    with
    | Ok () -> Ok ()
    | Error _ -> save_snapshot_file ()
  in
  match save_result with
  | Ok () ->
    prune_oas_history ~session_dir
  | Error msg ->
    Log.Keeper.warn "save_oas_history failed for %s: %s" snapshot_id msg;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string CheckpointFailures)
      ~labels:[("site", Keeper_checkpoint_store_failure_site.(to_label Oas_save))]
      ()

let delete_oas_history_files ~(session_dir : string) ~(snapshot_ids : string list)
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
      let path = oas_history_path ~session_dir ~snapshot_id in
      if Fs_compat.file_exists path then (
        try
          Sys.remove path;
          (snapshot_id :: deleted, missing)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Log.Keeper.warn "OAS snapshot delete failed for %s: %s"
              path (Printexc.to_string exn);
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string CheckpointFailures)
              ~labels:[("site", Keeper_checkpoint_store_failure_site.(to_label Oas_delete))]
              ();
            (deleted, snapshot_id :: missing))
      else
        (deleted, snapshot_id :: missing))
    ([], [])
    snapshot_ids
  |> fun (deleted, missing) -> (List.rev deleted, List.rev missing)

(* Delta Checkpoint Shadow-Apply removed: Agent_sdk.Checkpoint.delta
   type was removed upstream. Functions had zero callers. *)

type checkpoint_load_error =
  | Not_found
  | Store_error of string
  | Parse_error of string
  | Io_error of string
  (** Catch-all for SDK errors outside the Io / Serialization families
      (Api / Agent / Mcp / Config / Orchestration / Internal).
      Distinct from Io_error so observers can tell a local
      checkpoint-store I/O failure apart from an SDK-level failure that
      surfaced during a load. (#8605 family) *)
  | Sdk_other_error of string

(* RFC-0089 G4 (#15514-sibling): [Not_found] classification was previously
   string-matched against [FileOpFailed.detail] across four prefixes
   ("no_such_file", "no such file", "unix_error (enoent", "eio.io fs
   not_found") + a substring fallback. This was a string classifier
   workaround (CLAUDE.md §워크어라운드 #2): [Agent_sdk.Error] is already a
   closed sum type, but [FileOpFailed.detail] flattens the underlying
   filesystem exception via [Printexc.to_string], throwing away typed
   provenance.

   Root fix: lift ENOENT detection to the OS boundary *before* invoking
   the SDK. [Agent_sdk.Checkpoint_store.exists : t -> string -> bool] gives
   us a typed presence check, so the cold-start "file absent" case is now
   first-class [bool] and never reaches [classify_sdk_error]. Any SDK error
   that *does* surface from [load] is, by construction, a real I/O /
   serialization / SDK fault and routes to [Io_error] / [Store_error] /
   [Parse_error] / [Sdk_other_error] without inspecting strings.

   #8605 family: exhaustive on [Agent_sdk.Error.sdk_error] top-level
   variants. The wildcards on Io _ and Serialization _ remain narrow (one
   level deep) so a future inner variant lands in the semantically correct
   category, and a future top-level sdk_error variant becomes a build
   error forcing a deliberate routing decision. *)
let classify_sdk_error (e : Agent_sdk.Error.sdk_error) : checkpoint_load_error =
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
  | Orchestration _ | Internal _ ->
      Sdk_other_error (Agent_sdk.Error.to_string e)

let load_oas_history_file ~(session_dir : string) ~(snapshot_id : string) :
    (Agent_sdk.Checkpoint.t, checkpoint_load_error) result =
  (* [snapshot_id] reaches this entry point from the dashboard HTTP
     surface; a non-segment id ("../..") would read outside the session
     directory, so it is refused as absent before any filesystem access. *)
  if not (leaf_is_real_segment snapshot_id) then Error Not_found
  else (
    let path = oas_history_path ~session_dir ~snapshot_id in
    if Fs_compat.file_exists path then
      try
        match decode_checkpoint_off_scheduler (Fs_compat.load_file path) with
        | Ok ckpt -> Ok ckpt
        | Error e -> Error (classify_sdk_error e)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> Error (Io_error (Printexc.to_string exn))
    else Error Not_found)

let load_oas ~(session_dir : string) ~(session_id : string) :
    (Agent_sdk.Checkpoint.t, checkpoint_load_error) result =
  (* RFC-0089 G4: typed ENOENT classification at the OS boundary.
     [Fs_compat.file_exists] answers cold-start absence as a [bool] before
     any read, so a missing checkpoint is never inferred from a stringified
     error detail and [classify_sdk_error] keeps no [Not_found] arm.

     One read path for Eio and non-Eio contexts: [Fs_compat.load_file] is
     Eio-native when the fs capability is installed, and the decode is
     routed off the calling fiber (#25077). The previous
     [Agent_sdk.Checkpoint_store.load] branch read the same file but
     decoded the 0.7-1.4MB payload inline in the SDK on the calling fiber
     (oas#2676), and its [create] could mkdir on a pure read. The SDK
     branch also validated [session_id] (empty / separator / NUL); the
     segment check below keeps that rejection, mapped to [Store_error]
     exactly as the SDK's ValidationFailed was via [classify_sdk_error]. *)
  if not (leaf_is_real_segment session_id) then
    Error (Store_error "session_id is not a real path segment")
  else
  let path = oas_checkpoint_path ~session_dir ~session_id in
  if Fs_compat.file_exists path then
    try
      match decode_checkpoint_off_scheduler (Fs_compat.load_file path) with
      | Ok ckpt -> Ok ckpt
      | Error e -> Error (classify_sdk_error e)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Error (Io_error (Printexc.to_string exn))
  else Error Not_found

(* ── RFC-0225 §3.2: disk-SSOT monotonic checkpoint transaction ──────
   One stable per-session lock covers canonical disk load, comparison,
   durable publication, and history capture. The canonical file is the only
   admission watermark; no process-local checkpoint truth is retained. *)

type save_oas_relation = [ `Cold | `Forward | `Equal ]

type save_oas_outcome =
  | Saved of { relation : save_oas_relation; turn_count : int }
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

type save_oas_error =
  | Invalid_session_id of string
  | Session_directory_unavailable of directory_failure
  | Existing_checkpoint_unreadable of checkpoint_load_error
  | Canonical_write_failed of Keeper_fs.durable_write_error
  | Transaction_lock_failed of File_lock_eio.durable_lock_error

let checkpoint_load_error_to_string = function
  | Not_found -> "checkpoint not found"
  | Store_error detail
  | Parse_error detail
  | Io_error detail
  | Sdk_other_error detail -> detail

let save_oas_error_to_string = function
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
  |> Result.map_error save_oas_error_to_string

let archive_oas_history_best_effort ~session_dir ckpt =
  try save_oas_history ~session_dir ckpt with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.warn "OAS snapshot archive write failed for %s: %s"
      ckpt.session_id (Printexc.to_string exn);
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string CheckpointFailures)
      ~labels:
        [ ( "site"
          , Keeper_checkpoint_store_failure_site.(to_label Oas_archive) )
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
    | _ ->
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
         Ok (Some content)
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
  | Ok (Some content) ->
    (* This decode runs inside the durable session lock, so the caller now
       waits on worker-pool capacity while holding it (the submit is a
       rendezvous at CPU weight). Accepted trade-off: the wait is bounded
       by pool job runtimes and only delays this one session's
       transaction, whereas the previous inline parse stalled every fiber
       on the scheduler domain for the whole conversion. *)
    (match decode_checkpoint_off_scheduler content with
     | Ok checkpoint -> Ok (Some (content, checkpoint))
     | Error error -> Error (classify_sdk_error error))

let load_canonical_strict path =
  load_canonical_bytes_and_checkpoint_strict path
  |> Result.map (Option.map snd)

type watermark = { session_id : string; turn_count : int }

let known_watermark ~canonical_path
  : (watermark option, checkpoint_load_error) result =
  load_canonical_strict canonical_path
  |> Result.map
       (Option.map (fun (existing : Agent_sdk.Checkpoint.t) ->
          { session_id = existing.session_id; turn_count = existing.turn_count }))

type checkpoint_identity_error =
  | Session_id_invalid of string
  | Generation_missing
  | Generation_not_integer
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
  { checkpoint : Agent_sdk.Checkpoint.t
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
  | Commit_durability_unknown of
      { installed_ref : Keeper_checkpoint_ref.t
      ; error : Keeper_fs.durable_write_error
      }
  | Transaction_outcome_unknown of
      { possible_installed_ref : Keeper_checkpoint_ref.t
      ; error : File_lock_eio.durable_lock_error
      }

let checkpoint_generation_strict (checkpoint : Agent_sdk.Checkpoint.t) =
  match
    Agent_sdk.Context.get_scoped checkpoint.Agent_sdk.Checkpoint.context
      Agent_sdk.Context.Session keeper_generation_context_key
  with
  | None -> Error Generation_missing
  | Some (`Int generation) -> Ok generation
  | Some (`Intlit raw) ->
    (match int_of_string_opt raw with
     | Some generation -> Ok generation
     | None -> Error Generation_not_integer)
  | Some _ -> Error Generation_not_integer

(* [generation_fallback] closes the pre-#25046 checkpoint gap (#25217): a
   keeper's OAS turn-persist path serializes the live context, which does not
   carry [keeper_generation] in its Session scope, so its primary checkpoint
   is written without the key that #25046's strict identity requires. On the
   load side the keeper's own [meta.runtime.generation] is the authoritative
   generation SSOT — using it when (and only when) the persisted key is
   absent recovers identity from an equally-authoritative source rather than
   fabricating one. Only [Generation_missing] is recovered; a present-but-
   malformed value ([Generation_not_integer]) stays a hard error. The save
   path never passes a fallback, so the write invariant "a freshly built
   checkpoint must carry its own generation" is unchanged. *)
let checkpoint_generation_with_fallback ?generation_fallback checkpoint =
  match checkpoint_generation_strict checkpoint, generation_fallback with
  | Ok generation, _ -> Ok generation
  | Error Generation_missing, Some fallback ->
    Log.Keeper.warn
      "checkpoint generation key absent; recovering from meta SSOT \
       generation=%d (pre-#25046 checkpoint, #25217)"
      fallback;
    (* A successful recovery is not an execution error — dashboard.ml aggregates
       [OasExecutionErrors] into its error total, so counting it there inflated
       the error signal. Record it on a dedicated non-error counter instead. *)
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string CheckpointGenerationRecovered)
      ~labels:
        [ "source", "meta_ssot"; "context", "compaction_checkpoint_load" ]
      ();
    Ok fallback
  | Error _ as error, _ -> error

let checkpoint_ref_of_canonical_bytes ?generation_fallback canonical_bytes
    (checkpoint : Agent_sdk.Checkpoint.t) =
  match Keeper_id.Trace_id.of_string checkpoint.Agent_sdk.Checkpoint.session_id with
  | Error reason -> Error (Session_id_invalid reason)
  | Ok trace_id ->
    (match checkpoint_generation_with_fallback ?generation_fallback checkpoint with
     | Error _ as error -> error
     | Ok generation ->
       Keeper_checkpoint_ref.create
         ~trace_id
         ~generation
         ~turn_count:checkpoint.turn_count
         ~canonical_checkpoint_bytes:canonical_bytes
       |> Result.map_error (fun error -> Ref_create_failed error))

let exact_snapshot_of_checkpoint ?generation_fallback ~expected_session_id
    ~canonical_bytes checkpoint =
  match
    checkpoint_ref_of_canonical_bytes ?generation_fallback canonical_bytes
      checkpoint
  with
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

let exact_snapshot_of_canonical_bytes ?generation_fallback ~expected_session_id
    canonical_bytes =
  match decode_checkpoint_off_scheduler canonical_bytes with
  | Error error -> Error (Ref_read_failed (classify_sdk_error error))
  | Ok checkpoint ->
    exact_snapshot_of_checkpoint
      ?generation_fallback
      ~expected_session_id
      ~canonical_bytes
      checkpoint
;;

let load_ref_locked ?generation_fallback ~session_dir ~expected_session_id () =
  let canonical_path =
    oas_checkpoint_path
      ~session_dir
      ~session_id:(Keeper_id.Trace_id.to_string expected_session_id)
  in
  match load_canonical_bytes_and_checkpoint_strict canonical_path with
  | Error error -> Error (Ref_read_failed error)
  | Ok None -> Error Ref_not_found
  | Ok (Some (canonical_bytes, checkpoint)) ->
    exact_snapshot_of_checkpoint
      ?generation_fallback
      ~expected_session_id
      ~canonical_bytes
      checkpoint

let load_oas_exact_snapshot ?generation_fallback ~session_dir ~session_id () =
  match Keeper_id.Trace_id.of_string session_id with
  | Error reason -> Error (Ref_identity_invalid (Session_id_invalid reason))
  | Ok expected_session_id ->
    (match
       with_session_lock ~session_dir (fun session_dir ->
         load_ref_locked ?generation_fallback ~session_dir ~expected_session_id ())
     with
     | Ok result -> result
     | Error detail -> Error (Ref_lock_failed detail))

let load_oas_with_ref ?generation_fallback ~session_dir ~session_id () =
  load_oas_exact_snapshot ?generation_fallback ~session_dir ~session_id ()
  |> Result.map (fun snapshot ->
    exact_snapshot_checkpoint snapshot, exact_snapshot_reference snapshot)
;;

let with_checkpoint_cas_lock ~session_dir ~candidate_ref f =
  match canonical_session_location session_dir with
  | Error error ->
    Error
      (Source_unavailable
         (Ref_lock_failed (save_oas_error_to_string error)))
  | Ok session_dir ->
    let lock_path = session_dir ^ ".checkpoint.lock" in
    (match File_lock_eio.with_durable_lock ~lock_path (fun () -> f session_dir) with
     | Ok result -> result
     | Error error ->
       (match error.File_lock_eio.phase with
        | File_lock_eio.Release_process_lock ->
          Error
            (Transaction_outcome_unknown
               { possible_installed_ref = candidate_ref; error })
        | File_lock_eio.Open_lock_file
        | File_lock_eio.Acquire_process_lock ->
          Error
            (Source_unavailable
               (Ref_lock_failed
                  (File_lock_eio.durable_lock_error_to_string error)))))

let save_oas_if_source
    ?generation_fallback
    ~session_dir
    ~(expected_source_ref : Keeper_checkpoint_ref.t)
    (candidate : Agent_sdk.Checkpoint.t) =
  let candidate_bytes =
    offload_checkpoint_cpu (fun () ->
      Yojson.Safe.to_string (Agent_sdk.Checkpoint.to_json candidate))
  in
  match checkpoint_ref_of_canonical_bytes candidate_bytes candidate with
  | Error error -> Error (Candidate_identity_invalid error)
  | Ok candidate_ref
    when not
           (Keeper_id.Trace_id.equal
              expected_source_ref.trace_id candidate_ref.trace_id) ->
    Error
      (Candidate_session_mismatch
         { expected = expected_source_ref.trace_id
         ; candidate = candidate_ref.trace_id
         })
  | Ok candidate_ref
    when not (Int.equal expected_source_ref.generation candidate_ref.generation) ->
    Error
      (Candidate_generation_mismatch
         { expected = expected_source_ref.generation
         ; candidate = candidate_ref.generation
         })
  | Ok candidate_ref
    when candidate_ref.turn_count < expected_source_ref.turn_count ->
    Error
      (Candidate_turn_regressed
         { source_turn = expected_source_ref.turn_count
         ; candidate_turn = candidate_ref.turn_count
         })
  | Ok candidate_ref ->
    let expected_session_id = expected_source_ref.trace_id in
    with_checkpoint_cas_lock ~session_dir ~candidate_ref (fun session_dir ->
      (* The CAS source reread re-reads the EXISTING installed checkpoint (not
         the freshly built candidate) to detect a concurrent change. For a
         pre-#25046 source that checkpoint lacks [keeper_generation], so it
         needs the same [generation_fallback] the initial recovery load used —
         and [expected_source_ref] was itself built with that fallback, so a
         strict reread would both fail closed AND disagree with the ref it is
         compared against. The candidate above is still built strictly from
         [~generation], preserving the write invariant. *)
      match
        load_ref_locked ?generation_fallback ~session_dir ~expected_session_id ()
      with
      | Error error -> Error (Source_unavailable error)
      | Ok snapshot
        when not
               (Keeper_checkpoint_ref.equal
                  expected_source_ref
                  (exact_snapshot_reference snapshot)) ->
        Error (Source_changed (exact_snapshot_reference snapshot))
      | Ok _ ->
           let canonical_path =
             oas_checkpoint_path
               ~session_dir
               ~session_id:(Keeper_id.Trace_id.to_string expected_session_id)
           in
           let ownership_root = Filename.dirname session_dir in
           (match
              Keeper_fs.save_bytes_durable_atomic
                ~ownership_root
                canonical_path
                candidate_bytes
            with
            | Error error when error.Keeper_fs.renamed ->
              Error
                (Commit_durability_unknown
                   { installed_ref = candidate_ref; error })
            | Error error -> Error (Commit_not_installed error)
            | Ok () ->
              (* The durable writer installs [candidate_bytes] verbatim — the
                 exact bytes [candidate_ref] was derived from — so the
                 published file and the returned ref agree by construction,
                 not by an encoding contract. Once the writer returns [Ok],
                 rename and both durability fsyncs have completed; a
                 post-commit read cannot downgrade that committed outcome to
                 a retryable failure. *)
              Ok candidate_ref))

let save_oas_classified_typed
    ~(session_dir : string)
    (ckpt : Agent_sdk.Checkpoint.t)
  : (save_oas_outcome, save_oas_error) result =
  match Keeper_id.Trace_id.of_string ckpt.session_id with
  | Error reason -> Error (Invalid_session_id reason)
  | Ok trace_id ->
    with_session_lock_typed ~session_dir (fun session_dir ->
      let session_id = Keeper_id.Trace_id.to_string trace_id in
      let canonical_path = oas_checkpoint_path ~session_dir ~session_id in
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
          "stale OAS checkpoint write skipped for %s: incoming turn_count=%d, last saved=%d"
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
        (match
           Keeper_fs.save_json_durable_atomic_from
             ~ownership_root
             ~pretty:false
             canonical_path
             (fun () -> Agent_sdk.Checkpoint.to_json ckpt)
         with
         | Error error -> Error (Canonical_write_failed error)
         | Ok () ->
           archive_oas_history_best_effort ~session_dir ckpt;
           Ok
             (Saved
                { relation = save_relation ~known ~incoming:ckpt.turn_count
                ; turn_count = ckpt.turn_count
                })))

let save_oas_classified ~(session_dir : string) (ckpt : Agent_sdk.Checkpoint.t)
  : (save_oas_outcome, string) result =
  save_oas_classified_typed ~session_dir ckpt
  |> Result.map_error save_oas_error_to_string
