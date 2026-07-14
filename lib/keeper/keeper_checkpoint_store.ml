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

(* Unguarded write body. Public [save_oas] (defined after [load_oas]
   below) wraps this with the RFC-0225 §3.2 stale-write guard. *)
let save_oas_unguarded ~(session_dir : string) (ckpt : Agent_sdk.Checkpoint.t)
  : (unit, string) result =
  if String.length ckpt.session_id = 0 then
    (* Fail loud at the persistence boundary: a checkpoint with an empty
       session_id is unpersistable. The primary Eio path already rejects it
       ([Checkpoint_store.save] validates session_id), but the non-Eio
       [fallback] below would otherwise silently write "<session_dir>/.json"
       and drop the checkpoint. Callers must stamp a validated, non-empty
       session_id (the keeper trace_id) before persisting. *)
    Error "save_oas: refusing checkpoint with empty session_id"
  else
  let fallback () =
    match Keeper_fs.save_atomic
      (oas_checkpoint_path ~session_dir ~session_id:ckpt.session_id)
      (Agent_sdk.Checkpoint.to_string ckpt) with
    | Ok () ->
      (try save_oas_history ~session_dir ckpt with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Keeper.warn "OAS snapshot archive write failed for %s: %s"
             ckpt.session_id (Printexc.to_string exn);
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string CheckpointFailures)
             ~labels:[("site", Keeper_checkpoint_store_failure_site.(to_label Oas_archive_fallback))]
             ());
      Ok ()
    | Error msg -> Error msg
  in
  try
    ignore (Keeper_fs.ensure_dir session_dir);
    match Fs_compat.get_fs_opt () with
    | Some fs when Eio_guard.is_ready () ->
        let dir = Eio.Path.(fs / session_dir) in
        (match Agent_sdk.Checkpoint_store.create dir with
         | Ok store -> (
             match Agent_sdk.Checkpoint_store.save store ckpt with
             | Ok () ->
                 (try save_oas_history ~session_dir ckpt with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                      Log.Keeper.warn "OAS snapshot archive write failed for %s: %s"
                        ckpt.session_id (Printexc.to_string exn);
                      Otel_metric_store.inc_counter
                        Keeper_metrics.(to_string CheckpointFailures)
                        ~labels:[("site", Keeper_checkpoint_store_failure_site.(to_label Oas_archive_primary))]
                        ());
                 Ok ()
             | Error err -> Error (Agent_sdk.Error.to_string err))
         | Error err -> Error (Agent_sdk.Error.to_string err))
    | Some _ | None ->
        fallback ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printf.sprintf "save_oas: %s" (Printexc.to_string exn))

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
  | Some fs when Eio_guard.is_ready () ->
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

(* ── RFC-0225 §3.2: stale checkpoint write guard ─────────────────────
   Two writers for the same session are last-writer-wins on disk; a
   stale writer (e.g. a lane that resumed from an older snapshot)
   overwrote the conversation the newer writer had just persisted
   (2026-06-10 voice incident: oas turn_count 1355 clobbered by 1324).
   The checkpoint carrier is OAS-owned, so the version is tracked on
   the MASC side: a process-local map of the highest turn_count saved
   per checkpoint path, backfilled from disk once per session. *)

let last_saved_oas_turn_count_mu = Stdlib.Mutex.create ()
let last_saved_oas_turn_count : (string, int) Hashtbl.t = Hashtbl.create 16

let known_oas_turn_count ~session_dir ~session_id =
  let key = oas_checkpoint_path ~session_dir ~session_id in
  let cached =
    (* Stdlib mutex on purpose: the critical section is a pure Hashtbl
       lookup, never yields. Disk backfill happens outside the lock. *)
    Stdlib.Mutex.protect last_saved_oas_turn_count_mu (fun () ->
      Hashtbl.find_opt last_saved_oas_turn_count key)
  in
  match cached with
  | Some _ as hit -> hit
  | None ->
    (match load_oas ~session_dir ~session_id with
     | Ok existing -> Some existing.turn_count
     | Error _ -> None)

let record_saved_oas_turn_count ~session_dir ~session_id turn_count =
  let key = oas_checkpoint_path ~session_dir ~session_id in
  Stdlib.Mutex.protect last_saved_oas_turn_count_mu (fun () ->
    match Hashtbl.find_opt last_saved_oas_turn_count key with
    | Some known when known >= turn_count -> ()
    | Some _ | None -> Hashtbl.replace last_saved_oas_turn_count key turn_count)

type save_oas_relation = [ `Cold | `Forward | `Equal ]

type save_oas_outcome =
  | Saved of { relation : save_oas_relation; turn_count : int }
  | Stale_noop of { incoming_turn_count : int; known_turn_count : int }

let save_relation ~known ~incoming =
  match known with
  | None -> `Cold
  | Some previous when incoming > previous -> `Forward
  | Some _ -> `Equal

let save_oas_classified ~(session_dir : string) (ckpt : Agent_sdk.Checkpoint.t)
  : (save_oas_outcome, string) result =
  let known = known_oas_turn_count ~session_dir ~session_id:ckpt.session_id in
  match known with
  | Some known when ckpt.turn_count < known ->
    Log.Keeper.warn
      "stale OAS checkpoint write skipped for %s: incoming turn_count=%d, last saved=%d"
      ckpt.session_id ckpt.turn_count known;
    Otel_metric_store.inc_counter
      "masc_keeper_checkpoint_stale_noop_total"
      ~labels:[("site", "store_watermark")]
      ();
    Ok (Stale_noop
          { incoming_turn_count = ckpt.turn_count
          ; known_turn_count = known
          })
  | Some _ | None ->
    (match save_oas_unguarded ~session_dir ckpt with
     | Ok () ->
       record_saved_oas_turn_count
         ~session_dir ~session_id:ckpt.session_id ckpt.turn_count;
       Ok
         (Saved
            { relation = save_relation ~known ~incoming:ckpt.turn_count
            ; turn_count = ckpt.turn_count
            })
     | Error _ as e -> e)

let save_oas ~(session_dir : string) (ckpt : Agent_sdk.Checkpoint.t)
  : (unit, string) result =
  match save_oas_classified ~session_dir ckpt with
  | Ok (Saved _) | Ok (Stale_noop _) -> Ok ()
  | Error _ as e -> e

module For_testing = struct
  let reset_stale_write_guard () =
    Stdlib.Mutex.protect last_saved_oas_turn_count_mu (fun () ->
      Hashtbl.reset last_saved_oas_turn_count)
end
