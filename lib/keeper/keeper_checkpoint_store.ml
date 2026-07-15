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

let keeper_generation_of_context (context : Agent_sdk.Context.t) : int =
  match
    Agent_sdk.Context.get_scoped context Agent_sdk.Context.Session
      "keeper_generation"
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
      (Agent_sdk.Checkpoint.to_string ckpt)
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
  let path = oas_history_path ~session_dir ~snapshot_id in
  if Fs_compat.file_exists path then
    try
      match Agent_sdk.Checkpoint.of_string (Fs_compat.load_file path) with
      | Ok ckpt -> Ok ckpt
      | Error e -> Error (classify_sdk_error e)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Error (Io_error (Printexc.to_string exn))
  else Error Not_found

let load_oas ~(session_dir : string) ~(session_id : string) :
    (Agent_sdk.Checkpoint.t, checkpoint_load_error) result =
  let fallback () =
    let path = oas_checkpoint_path ~session_dir ~session_id in
    if Fs_compat.file_exists path then
      try
        match Agent_sdk.Checkpoint.of_string (Fs_compat.load_file path) with
        | Ok ckpt -> Ok ckpt
        | Error e -> Error (classify_sdk_error e)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> Error (Io_error (Printexc.to_string exn))
    else Error Not_found
  in
  match Fs_compat.get_fs_opt () with
  | Some fs when Eio_guard.is_eio_fiber () ->
      let dir = Eio.Path.(fs / session_dir) in
      (match Agent_sdk.Checkpoint_store.create dir with
       | Ok store ->
           (* RFC-0089 G4: typed ENOENT classification at the OS boundary.
              [exists] returns a [bool] so a missing checkpoint never has to
              be inferred from a stringified exception detail. The SDK-side
              [load] is only reached when the file is present, so any error
              returned is a genuine I/O / parse / SDK failure (not cold-start
              absence). *)
           if not (Agent_sdk.Checkpoint_store.exists store session_id) then
             Error Not_found
           else (
             match Agent_sdk.Checkpoint_store.load store session_id with
             | Ok ckpt -> Ok ckpt
             | Error e -> Error (classify_sdk_error e))
       | Error e -> Error (Store_error (Agent_sdk.Error.to_string e)))
  | Some _ | None ->
      fallback ()

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
  | Existing_checkpoint_unreadable error ->
    "existing checkpoint unreadable: " ^ checkpoint_load_error_to_string error
  | Canonical_write_failed error ->
    "canonical checkpoint write failed: "
    ^ Keeper_fs.durable_write_error_to_string error
  | Transaction_lock_failed error ->
    "checkpoint transaction lock failed: "
    ^ File_lock_eio.durable_lock_error_to_string error

let canonical_session_location session_dir =
  let parent = Filename.dirname session_dir in
  try
    Fs_compat.mkdir_p parent;
    let parent =
      Eio_guard.run_in_systhread (fun () ->
        let parent = Unix.realpath parent in
        if (Unix.stat parent).Unix.st_kind <> Unix.S_DIR
        then
          raise
            (Unix.Unix_error
               (Unix.ENOTDIR, "checkpoint_session_parent", parent));
        parent)
    in
    Ok (Filename.concat parent (Filename.basename session_dir))
  with
  | Unix.Unix_error (error, operation, argument) ->
    Error
      (Session_directory_unavailable
         (Directory_unix_failure { error; operation; argument }))
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Session_directory_unavailable
         (Directory_other_failure (Printexc.to_string exn)))

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

let load_canonical_strict path =
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
  | Ok None -> Ok None
  | Error _ as error -> error
  | Ok (Some content) ->
    (match Agent_sdk.Checkpoint.of_string content with
     | Ok checkpoint -> Ok (Some checkpoint)
     | Error error -> Error (classify_sdk_error error))
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Io_error (Printexc.to_string exn))

(* masc P0 perf fix (checkpoint save-path read-modify-write): every save
   transaction for one session runs under [with_session_lock_typed], which
   serializes writers for that [canonical_path] across Eio fibers, raw
   Domains, and other OS processes (Eio.Mutex + Stdlib.Mutex + flock -- see
   File_lock_eio). Inside that single-writer critical section, a
   process-local watermark is exactly as authoritative as a fresh
   [load_canonical_strict] of the same path, because every successful write
   updates the cache before the session lock is released. A cache miss
   (process cold-start, or a session this process has never written) always
   falls back to [load_canonical_strict], preserving the original
   crash-recovery contract: RFC-0225 §3.2's "disk is the only admission
   watermark" invariant now reads as "disk is the only watermark this
   process has not already durably confirmed."

   The per-session lock does NOT protect the cache table itself: two
   DIFFERENT sessions' transactions run under two different lock_paths and
   can hold their save transactions concurrently on different Domains (the
   payload encode step already runs on the executor pool -- see
   [Executor_pool_ref.submit_or_inline] in [Keeper_fs]), so every access to
   [watermark_cache] -- a plain, non-domain-safe Hashtbl -- is additionally
   guarded by a dedicated [Stdlib.Mutex.t]. A plain OS mutex (not the
   cooperative-yield [File_lock_eio] machinery) is enough here because the
   guarded section is always a single O(1) Hashtbl operation: it is only ever
   held across [load_canonical_strict]'s disk I/O by NOT wrapping that call,
   so a cache miss for one session cannot stall a concurrent cache hit for
   another, and the brief cross-domain wait this mutex can impose is
   negligible next to the disk read it replaces.

   This does not protect against a writer bypassing [save_oas_classified]
   entirely (e.g. an operator manually restoring a checkpoint file while the
   server keeps running) -- rg confirms [oas_checkpoint_path] has exactly one
   production writer in lib/ (this module); every other reference is a
   read-only dashboard/history consumer. See the PR body for the full audit. *)
type watermark = { session_id : string; turn_count : int }

let watermark_cache : (string, watermark) Hashtbl.t = Hashtbl.create 64
let watermark_cache_mu = Stdlib.Mutex.create ()

let find_cached_watermark canonical_path =
  Stdlib.Mutex.protect watermark_cache_mu (fun () ->
    Hashtbl.find_opt watermark_cache canonical_path)

let record_watermark canonical_path watermark =
  Stdlib.Mutex.protect watermark_cache_mu (fun () ->
    Hashtbl.replace watermark_cache canonical_path watermark)

let known_watermark ~canonical_path
  : (watermark option, checkpoint_load_error) result =
  match find_cached_watermark canonical_path with
  | Some cached -> Ok (Some cached)
  | None ->
    (match load_canonical_strict canonical_path with
     | Error _ as error -> error
     | Ok None -> Ok None
     | Ok (Some existing) ->
       let watermark =
         { session_id = existing.session_id; turn_count = existing.turn_count }
       in
       record_watermark canonical_path watermark;
       Ok (Some watermark))

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
           Keeper_fs.save_json_durable_atomic
             ~ownership_root
             ~pretty:false
             canonical_path
             (Agent_sdk.Checkpoint.to_json ckpt)
         with
         | Error error -> Error (Canonical_write_failed error)
         | Ok () ->
           record_watermark canonical_path { session_id; turn_count = ckpt.turn_count };
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
