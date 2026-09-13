module Id = Keeper_shutdown_types.Operation_id
let ( let* ) = Result.bind

type state = Prepared | Cleanup_required of string | Artifacts_removed | Removed
type receipt = {
  operation_id : Id.t;
  keeper_name : string;
  actor : string;
  source_sha256 : string;
  source_path : string;
  requested_at : string;
  updated_at : string;
  state : state;
  last_error : string option;
}
type inventory = { receipts : receipt list; errors : string list }
type error = Invalid_request of string | Conflict of string | Storage_error of string
let error_to_string = function
  | Invalid_request detail | Conflict detail | Storage_error detail -> detail

let directory config =
  Filename.concat (Workspace.keepers_runtime_dir config) ".configuration-removals"
let owner_directory config keeper_name =
  Filename.concat (directory config) ("_" ^ keeper_name)
let record_path config keeper_name operation_id =
  Filename.concat (owner_directory config keeper_name) (Id.to_string operation_id ^ ".json")
let manifest_path config keeper_name =
  Filename.concat (Config_dir_resolver.keepers_dir_for_base_path
    ~base_path:config.Workspace.base_path) (keeper_name ^ ".toml")
let validate_name name =
  match Keeper_id.Keeper_name.of_string name with
  | Ok name -> Ok (Keeper_id.Keeper_name.to_string name)
  | Error detail -> Error (Invalid_request detail)

let to_json receipt =
  let phase, failure = match receipt.state with
    | Prepared -> "prepared", `Null
    | Cleanup_required detail -> "cleanup_required", `String detail
    | Artifacts_removed -> "artifacts_removed", `Null
    | Removed -> "removed", `Null in
  `Assoc ["kind", `String "configuration_removal";
    "operation_id", `String (Id.to_string receipt.operation_id);
    "keeper_name", `String receipt.keeper_name; "actor", `String receipt.actor;
    "source_sha256", `String receipt.source_sha256;
    "source_path", `String receipt.source_path;
    "requested_at", `String receipt.requested_at;
    "updated_at", `String receipt.updated_at;
    "state", `Assoc ["kind", `String phase;
      "error", (match receipt.last_error with Some detail -> `String detail | None -> failure)]]

let of_json json =
  let open Yojson.Safe.Util in
  let text key = match member key json with
    | `String value when String.trim value <> "" -> Ok value
    | _ -> Error (Storage_error ("invalid configuration removal field: " ^ key)) in
  try
    let* kind = text "kind" in
    let* () = if kind = "configuration_removal" then Ok ()
      else Error (Storage_error "unexpected configuration removal kind") in
    let* raw_id = text "operation_id" in
    let* operation_id = Id.of_string raw_id |> Result.map_error (fun s -> Storage_error s) in
    let* keeper_name = text "keeper_name" in
    let* keeper_name = validate_name keeper_name in
    let* actor = text "actor" in
    let* source_sha256 = text "source_sha256" in
    let* source_path = text "source_path" in
    let* requested_at = text "requested_at" in
    let* updated_at = text "updated_at" in
    let state_json = member "state" json in
    let* phase = match member "kind" state_json with
      | `String phase -> Ok phase | _ -> Error (Storage_error "missing removal state kind") in
    let last_error = match phase, member "error" state_json with
      | "artifacts_removed", `String detail -> Some detail
      | _ -> None in
    let* state = match phase, member "error" state_json with
      | "prepared", `Null -> Ok Prepared
      | "artifacts_removed", (`Null | `String _) -> Ok Artifacts_removed
      | "removed", `Null -> Ok Removed
      | "cleanup_required", `String detail when String.trim detail <> "" -> Ok (Cleanup_required detail)
      | _ -> Error (Storage_error "invalid configuration removal phase/failure") in
    Ok {operation_id; keeper_name; actor; source_sha256; source_path;
      requested_at; updated_at; state; last_error}
  with Yojson.Safe.Util.Type_error (detail, _) -> Error (Storage_error detail)

let protect f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Storage_error (Printexc.to_string exn))

let read_regular path = protect (fun () ->
  match Unix.lstat path with
  | stat when stat.Unix.st_kind = Unix.S_REG ->
    Ok (Some (In_channel.with_open_bin path In_channel.input_all))
  | _ -> Error (Storage_error ("expected regular file: " ^ path))
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None)

let load config keeper_name operation_id =
  let* bytes = read_regular (record_path config keeper_name operation_id) in
  match bytes with
  | None -> Error (Invalid_request "configuration removal operation not found")
  | Some bytes -> protect (fun () ->
    let* receipt = of_json (Yojson.Safe.from_string bytes) in
    if Id.equal receipt.operation_id operation_id
       && String.equal receipt.keeper_name keeper_name
       && String.equal receipt.source_path (manifest_path config receipt.keeper_name)
    then Ok receipt
    else Error (Storage_error "configuration removal record identity mismatch"))

let save config receipt =
  Keeper_fs.save_json_durable_atomic ~ownership_root:config.Workspace.base_path
    (record_path config receipt.keeper_name receipt.operation_id) (to_json receipt)
  |> Result.map_error (fun error -> Storage_error (Keeper_fs.durable_write_error_to_string error))
  |> Result.map (fun () -> receipt)

let list_owner config keeper_name = protect (fun () ->
  let dir = owner_directory config keeper_name in
  match Unix.lstat dir with
  | stat when stat.Unix.st_kind = Unix.S_DIR ->
    let receipts, errors = Array.fold_left (fun (receipts, errors) name ->
      if Filename.extension name <> ".json" then receipts, errors
      else match Id.of_string (Filename.remove_extension name) with
        | Error detail -> receipts, (keeper_name ^ "/" ^ name ^ ": " ^ detail) :: errors
        | Ok id -> match load config keeper_name id with
          | Ok receipt -> receipt :: receipts, errors
          | Error error -> receipts, (keeper_name ^ "/" ^ name ^ ": " ^ error_to_string error) :: errors)
      ([], []) (Sys.readdir dir) in
    Ok {receipts; errors = List.rev errors}
  | _ -> Error (Storage_error ("expected removal receipt directory: " ^ dir))
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok {receipts=[]; errors=[]})

let list ~config = protect (fun () ->
  let dir = directory config in
  match Unix.lstat dir with
  | stat when stat.Unix.st_kind = Unix.S_DIR ->
    let inventory = Array.fold_left (fun inventory entry ->
      let owner = if String.length entry > 1 && entry.[0] = '_'
        then validate_name (String.sub entry 1 (String.length entry - 1))
        else Error (Storage_error ("invalid removal owner directory: " ^ entry)) in
      match owner with
      | Error error -> {inventory with errors=error_to_string error :: inventory.errors}
      | Ok keeper_name -> match list_owner config keeper_name with
        | Error error -> {inventory with errors=error_to_string error :: inventory.errors}
        | Ok owner -> {receipts=owner.receipts @ inventory.receipts;
            errors=owner.errors @ inventory.errors}) {receipts=[]; errors=[]} (Sys.readdir dir) in
    Ok {inventory with receipts=List.sort (fun a b -> String.compare a.requested_at b.requested_at) inventory.receipts}
  | _ -> Error (Storage_error ("expected removal inventory directory: " ^ dir))
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok {receipts=[]; errors=[]})

let require_configuration_only config keeper_name =
  let* shutdowns = Keeper_shutdown_store.list_for_keeper ~config ~keeper_name
    |> Result.map_error (fun error -> Storage_error (Keeper_shutdown_store.error_to_string error)) in
  let* () = if List.exists Keeper_shutdown_types.requires_admission_fence shutdowns
    then Error (Conflict "Keeper has an unsettled durable shutdown operation")
    else Ok () in
  let* meta = Keeper_meta_store.read_meta_file_path_read_only
    ~ownership_root:config.Workspace.base_path
    (Keeper_types_profile.keeper_meta_path config keeper_name)
    |> Result.map_error (function
      | Keeper_meta_store.Unreadable detail -> Storage_error ("Keeper metadata unreadable: " ^ detail)
      | Keeper_meta_store.Not_current detail -> Conflict ("Keeper metadata requires reconciliation: " ^ detail)) in
  let* () = match meta, Keeper_registry.get ~base_path:config.Workspace.base_path keeper_name with
    | None, None -> Ok ()
    | _ -> Error (Conflict "Keeper runtime exists; use its shutdown operation") in
  let* () = match Keeper_owner_registry.get ~base_path:config.base_path ~keeper_name with
    | Error (Keeper_owner_registry.Owner_not_found _) -> Ok ()
    | Ok _ -> Error (Conflict "Keeper owner still exists; configuration-only removal refused")
    | Error error -> Error (Storage_error (Keeper_owner_registry.lookup_error_to_string error)) in
  let* backlog = Workspace_backlog.read_backlog_r config
    |> Result.map_error (fun error -> Storage_error error) in
  let owned = List.exists (fun (task : Masc_domain.task) ->
    match task.task_status with
    | Masc_domain.Claimed {assignee; _}
    | InProgress {assignee; _}
    | AwaitingVerification {assignee; _} ->
      Workspace_task_classify.same_task_actor config keeper_name assignee
    | Todo | Done _ | Cancelled _ -> false) backlog.tasks in
  if owned then Error (Conflict "Keeper still owns active Tasks; reconcile ownership before configuration removal")
  else Ok ()

let with_authority config keeper_name f = protect (fun () ->
  match Keeper_shutdown_intake_fence.run_durable_intake_if_open
    ~base_path:config.Workspace.base_path ~keeper_name (fun _ ->
      match Keeper_lifecycle_reservation.acquire ~base_path:config.base_path
        ~keeper_name ~purpose:Configuration_removal with
      | Error (Already_reserved snapshot) -> Error (Conflict (Keeper_lifecycle_reservation.snapshot_to_string snapshot))
      | Ok token ->
        (* The reservation is released on every exit, including the ones that
           leave the TOML in place. That is not what keeps a half-removed
           Keeper from coming back -- the reservation is process-local by
           contract, so a restart drops it either way. The durable record is
           the receipt, and no boot or registration path reads it (#34768).

           The outcome is not discarded, though. [Release_not_owner] says a
           different owner holds the reservation this transaction acquired,
           which the transaction cannot correct here and must not swallow.
           [keeper_paused_work_source_terminal_transaction] carries the same
           outcome into its error for the same reason. *)
        let release_outcome = ref None in
        let result =
          Fun.protect
            ~finally:(fun () ->
              release_outcome := Some (Keeper_lifecycle_reservation.release token))
            (fun () ->
              let path = manifest_path config keeper_name in
              match
                File_lock_eio.with_durable_lock_observed ~lock_path:(path ^ ".lock") f
              with
              | Lock_not_acquired error ->
                Error (Storage_error (File_lock_eio.durable_lock_error_to_string error))
              | Body_completed { value; release_error = None } -> value
              | Body_completed { release_error = Some error; _ } ->
                Error (Storage_error (File_lock_eio.durable_lock_error_to_string error)))
        in
        (match !release_outcome with
         | Some (Keeper_lifecycle_reservation.Release_not_owner snapshot) ->
           Error
             (Conflict
                ("lifecycle reservation was taken over during configuration \
                  removal: "
                 ^ Keeper_lifecycle_reservation.snapshot_to_string snapshot))
         | Some (Keeper_lifecycle_reservation.Released
                | Keeper_lifecycle_reservation.Release_missing)
         | None -> result)) with
  | Intake_committed result -> result
  | Intake_shutdown_reserved id -> Error (Conflict ("Keeper shutdown already owns intake: " ^ Id.to_string id)))

let advance config receipt state =
  save config {receipt with state; last_error=None; updated_at=Masc_domain.now_iso ()}

let finish config receipt ~cleanup =
  let runtime_config_path =
    Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:config.Workspace.base_path in
  (* The manifest lock is already held. Do not hold the runtime lock across
     cleanup: its runtime-assignment removal acquires that lock itself. *)
  let* () = Runtime.with_config_lock ~runtime_config_path (fun () -> Ok ())
    |> Result.map_error (fun detail -> Storage_error detail) in
  let* () = require_configuration_only config receipt.keeper_name in
  let* source = read_regular receipt.source_path in
  let* () = match source, receipt.state with
    | None, Artifacts_removed -> Ok ()
    | Some source, _ when Digestif.SHA256.(digest_string source |> to_hex) = receipt.source_sha256 -> Ok ()
    | _ -> Error (Conflict "configuration source changed since deletion was requested") in
  let* receipt = match receipt.state with
    | Prepared | Cleanup_required _ ->
      (match protect (fun () -> cleanup receipt.keeper_name |> Result.map_error (fun detail -> Storage_error detail)) with
       | Error error -> advance config receipt (Cleanup_required (error_to_string error))
       | Ok () -> advance config receipt Artifacts_removed)
    | Artifacts_removed | Removed -> Ok receipt in
  match receipt.state with
  | Prepared | Cleanup_required _ | Removed -> Ok receipt
  | Artifacts_removed ->
    (match Runtime.with_config_lock ~runtime_config_path (fun () ->
       Keeper_fs.remove_file_durable
         ~ownership_root:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path)
         receipt.source_path
       |> Result.map_error Keeper_fs.durable_remove_error_to_string) with
     | Error detail -> save config {receipt with updated_at=Masc_domain.now_iso ();
         last_error=Some detail}
     | Ok () ->
       Keeper_types_profile.invalidate_keeper_profile_defaults_cache receipt.keeper_name;
       advance config receipt Removed)

let submit ~config ~keeper_name ~actor ~cleanup =
  let* keeper_name = validate_name keeper_name in
  if String.trim actor = "" then Error (Invalid_request "removal actor is required") else
  with_authority config keeper_name (fun () ->
    let* () = require_configuration_only config keeper_name in
    let* inventory = list_owner config keeper_name in
    let* () = if inventory.errors = [] then Ok () else Error (Storage_error (String.concat "; " inventory.errors)) in
    let existing = List.filter (fun receipt -> receipt.state <> Removed) inventory.receipts in
    match existing with
    | receipt :: [] -> finish config receipt ~cleanup
    | _ :: _ -> Error (Conflict "multiple pending configuration removal operations require reconciliation")
    | [] ->
      let source_path = manifest_path config keeper_name in
      let* source = read_regular source_path in
      match source with
      | None ->
        (* Two requests can both pass [Keeper_dashboard_purge.resolve], which
           runs before this and outside the durable lock, while the manifest is
           still there. They then serialize here. The one that arrives second
           finds the manifest already gone and a receipt that says Removed: the
           deletion it asked for did happen. Answering "does not exist" told the
           dashboard 409 for a delete that succeeded
           ([server_dashboard_http_delete_actions.ml] reports every submit error
           as Conflict), so the completed receipt is the answer. Outside the
           race a second delete never reaches here at all -- [resolve] returns
           [Ok None] once the manifest is gone. *)
        let removed =
          List.filter (fun receipt -> receipt.state = Removed) inventory.receipts
          |> List.sort (fun a b -> String.compare b.updated_at a.updated_at)
        in
        (match removed with
         | receipt :: _ -> Ok receipt
         | [] -> Error (Invalid_request "Keeper configuration does not exist"))
      | Some bytes ->
        let now = Masc_domain.now_iso () in
        let* receipt = save config {operation_id=Id.generate (); keeper_name; actor;
          source_path; source_sha256=Digestif.SHA256.(digest_string bytes |> to_hex);
          requested_at=now; updated_at=now; state=Prepared; last_error=None} in
        finish config receipt ~cleanup)

let retry ~config ~keeper_name ~operation_id ~cleanup =
  let* keeper_name = validate_name keeper_name in
  with_authority config keeper_name (fun () ->
    let* receipt = load config keeper_name operation_id in
    if receipt.keeper_name <> keeper_name then Error (Conflict "configuration removal Keeper identity mismatch")
    else match receipt.state with
      | Removed -> Ok receipt
      | _ -> finish config receipt ~cleanup)
