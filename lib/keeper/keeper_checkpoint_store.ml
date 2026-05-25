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

let oas_history_snapshot_id_of_checkpoint (ckpt : Agent_sdk.Checkpoint.t) : string =
  let generation =
    match ckpt.working_context with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "keeper_generation" fields with
        | Some (`Int n) -> n
        | Some (`Intlit raw) -> Option.value ~default:0 (int_of_string_opt raw)
        | _ -> 0)
    | _ -> 0
  in
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
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_checkpoint_failures
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
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_checkpoint_failures
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
            Prometheus.inc_counter
              Keeper_metrics.metric_keeper_checkpoint_failures
              ~labels:[("site", Keeper_checkpoint_store_failure_site.(to_label Oas_delete))]
              ();
            (deleted, snapshot_id :: missing))
      else
        (deleted, snapshot_id :: missing))
    ([], [])
    snapshot_ids
  |> fun (deleted, missing) -> (List.rev deleted, List.rev missing)

let save_oas ~(session_dir : string) (ckpt : Agent_sdk.Checkpoint.t)
  : (unit, string) result =
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
           Prometheus.inc_counter
             Keeper_metrics.metric_keeper_checkpoint_failures
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
                      Prometheus.inc_counter
                        Keeper_metrics.metric_keeper_checkpoint_failures
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
  | Orchestration _ | A2a _ | Internal _ ->
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
