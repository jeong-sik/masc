module Store = Keeper_owned_job_store
open Result.Syntax

type invocation = { trace_id : string; turn_ref : Ids.Turn_ref.t; tool_use_id : string }
type replay = { invocation : invocation; source : Store.source }
type reservation =
  { job_id : Store.Job_id.t; base_path : string; keeper_name : string
  ; source : Store.source; request_sha256 : string }
type binding = Fresh of reservation | Existing of reservation
type error = { job_id : Store.Job_id.t option; cause : Store.error }

let invocation_of_source (source : Store.source) =
  match source.trace_id, source.turn_ref, source.tool_use_id with
  | Some trace_id, Some turn_ref, Some tool_use_id ->
      if trace_id = "" || tool_use_id = "" || String.contains tool_use_id '\000'
         || not (String.equal trace_id (Ids.Turn_ref.trace_id turn_ref))
      then Error "owned job invocation has contradictory or invalid identities"
      else Ok (Some {trace_id;turn_ref;tool_use_id})
  | None, _, _ | _, None, _ | _, _, None -> Ok None

let replay_of_source (source : Store.source) =
  let* _ = Store.source_of_json (Store.source_to_json source)
      |> Result.map_error Store.error_to_string in
  let* invocation = invocation_of_source source in
  match invocation with
  | Some invocation -> Ok {invocation;source}
  | None -> Error "interrupted launch requires its complete original invocation"

let replay_source (replay : replay) = replay.source

let invocation_json keeper_name invocation =
  `Assoc ["keeper_name", `String keeper_name; "trace_id", `String invocation.trace_id;
          "turn_ref", Ids.Turn_ref.to_yojson invocation.turn_ref;
          "tool_use_id", `String invocation.tool_use_id]
let sha json = Agent_core_sha256.(to_hex (digest_string (Yojson.Safe.to_string json)))
let request_sha argv (inputs : Store.input list) =
  sha (`Assoc ["argv", `List (List.map (fun value -> `String value) argv);
       "inputs", `List (List.map (fun (input : Store.input) ->
           `Assoc ["path", `String input.path;
                   "artifact", Tool_output.normalized_artifact_ref_to_json input.artifact]) inputs)])
let path ~base_path ~keeper_name invocation =
  Filename.concat
    (Filename.concat
       (Filename.concat (Common.masc_dir_from_base_path ~base_path) "keeper_msg_requests")
       "owned_job_invocations")
    (sha (invocation_json keeper_name invocation) ^ ".json")
let reservation_json (reservation : reservation) =
  `Assoc ["version", `Int 1; "job_id", `String (Store.Job_id.to_string reservation.job_id);
          "base_path", `String reservation.base_path; "keeper_name", `String reservation.keeper_name;
          "source", Store.source_to_json reservation.source;
          "request_sha256", `String reservation.request_sha256]
let decode bytes =
  let corrupt detail = Error (Store.Corrupt detail) in
  try
    match Yojson.Safe.from_string bytes with
    | `Assoc fields when List.sort String.compare (List.map fst fields)
        = ["base_path";"job_id";"keeper_name";"request_sha256";"source";"version"] ->
        let get name = List.assoc name fields in
        let string = function `String value when value <> "" -> Ok value
          | _ -> corrupt "invalid invocation binding string" in
        let* () = if get "version" = `Int 1 then Ok () else corrupt "unknown invocation binding version" in
        let* value = string (get "job_id") in
        let* job_id = Store.Job_id.of_string value |> Result.map_error (fun detail -> Store.Corrupt detail) in
        let* base_path = string (get "base_path") in
        let* keeper_name = string (get "keeper_name") in
        let* source = Store.source_of_json (get "source") in
        let* request_sha256 = string (get "request_sha256") in
        let* () = if String.length request_sha256 = 64
            && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) request_sha256
          then Ok () else corrupt "invalid invocation request digest" in
        Ok {job_id;base_path;keeper_name;source;request_sha256}
    | _ -> corrupt "missing, duplicate or unknown invocation binding field"
  with Yojson.Json_error detail -> corrupt detail

let protect work =
  try work () with
  | Sys_error detail -> Error {job_id=None;cause=Store.Io_failed detail}
  | Unix.Unix_error (code, operation, location) ->
      Error {job_id=None;cause=Store.Io_failed
        (operation ^ " " ^ location ^ ": " ^ Unix.error_message code)}
let wrap ?job_id cause = {job_id;cause}
let canonical_base_path base_path = Store.canonical_base_path base_path |> Result.map_error wrap

let validate_path ~base_path ~location ~create =
  let inspect () =
    let root = Common.masc_dir_from_base_path ~base_path in
    let* directories = Fs_compat.owned_directory_paths ~ownership_root:root (Filename.dirname location)
      |> Result.map_error (fun error -> Store.Invalid_authority
          (Fs_compat.owned_directory_chain_rejection_to_string error)) in
    let check kind path = match Unix.lstat path with
      | stat when stat.Unix.st_kind = kind && stat.st_uid = Unix.getuid ()
          && stat.st_perm land 0o022 = 0
          && (kind <> Unix.S_REG || stat.st_nlink = 1 && stat.st_perm land 0o077 = 0) -> Ok ()
      | _ -> Error (Store.Invalid_authority "invocation binding path is not private and process-owned")
      | exception Unix.Unix_error (Unix.ENOENT,_,_) ->
          if create && path = location then Ok () else Error Store.Missing in
    let* () = List.fold_left (fun prior directory ->
        let* () = prior in check Unix.S_DIR directory) (Ok ()) (root :: directories) in
    check Unix.S_REG location in
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> inspect ()
  | Fs_compat.Eio_fiber -> Eio_unix.run_in_systhread ~label:"owned-job-invocation-authority" inspect

let check_scope ~base_path ~keeper_name ~invocation (reservation : reservation) =
  let* found = invocation_of_source reservation.source
      |> Result.map_error (fun detail -> Store.Corrupt detail) in
  if reservation.base_path = base_path && reservation.keeper_name = keeper_name
     && found = Some invocation
  then Ok () else Error (Store.Invalid_authority "invocation binding belongs to another owner or call")

let reserve ~base_path ~keeper_name ~invocation ~source ~argv ~inputs = protect (fun () ->
  let* base_path = canonical_base_path base_path in
  let* _ = Store.source_of_json (Store.source_to_json source) |> Result.map_error wrap in
  let* actual = invocation_of_source source |> Result.map_error (fun detail -> wrap (Store.Invalid_authority detail)) in
  let* () = if keeper_name <> "" && actual = Some invocation then Ok ()
    else Error (wrap (Store.Invalid_authority "invocation source differs from its exact key")) in
  let location = path ~base_path ~keeper_name invocation in
  let directory = Filename.dirname location in
  let* () = match Keeper_fs_durable_directory.ensure ~before_prepare:(fun () -> ())
      ~before_directory_fsync:(fun _ -> ()) ~ownership_root:base_path directory with
    | Ok _ -> Ok ()
    | Error _ -> Error (wrap (Store.Io_failed "invocation binding directory preparation failed")) in
  let* () = validate_path ~base_path ~location ~create:true |> Result.map_error wrap in
  let proposed = {job_id=Store.Job_id.fresh ();base_path;keeper_name;source;
                  request_sha256=request_sha argv inputs} in
  let decide bytes =
    match validate_path ~base_path ~location ~create:false with
    | Error cause -> None, Error (wrap cause)
    | Ok () when bytes = "" -> Some (Yojson.Safe.to_string (reservation_json proposed) ^ "\n"), Ok (Fresh proposed)
    | Ok () ->
        let result =
          let* prior = decode bytes |> Result.map_error wrap in
          let* () = check_scope ~base_path ~keeper_name ~invocation prior
              |> Result.map_error (wrap ~job_id:prior.job_id) in
          if Store.source_to_json prior.source = Store.source_to_json source
             && prior.request_sha256 = proposed.request_sha256
          then Ok (Existing prior)
          else Error (wrap ~job_id:prior.job_id (Store.Invalid_authority
              "the original invocation already owns a different immutable source or request")) in
        None, result in
  match Fs_compat.update_private_file_durable_locked_result location decide with
  | Fs_compat.Private_file_succeeded result -> result
  | Private_file_succeeded_with_cleanup_failure {value;cleanup_failure} ->
      let job_id = match value with Ok (Fresh value | Existing value) -> Some value.job_id
        | Error error -> error.job_id in
      Error {job_id;cause=Store.Commit_unconfirmed (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)}
  | Private_file_failed error -> Error (wrap (Store.Io_failed (Fs_compat.durable_append_error_to_string error)))
  | Private_file_failed_with_cleanup_failure {error;cleanup_failure} ->
      Error (wrap (Store.Io_failed (Fs_compat.durable_append_error_to_string error ^ "; " ^
          Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))))

let reserve_existing ~base_path ~keeper_name (replay : replay) ~argv ~inputs = protect (fun () ->
  let* base_path = canonical_base_path base_path in
  let invocation = replay.invocation in
  let location = path ~base_path ~keeper_name invocation in
  let* () = validate_path ~base_path ~location ~create:false |> Result.map_error wrap in
  let decide bytes =
    let result =
      let* () = validate_path ~base_path ~location ~create:false |> Result.map_error wrap in
      let* prior = decode bytes |> Result.map_error wrap in
      let* () = check_scope ~base_path ~keeper_name ~invocation prior
          |> Result.map_error (wrap ~job_id:prior.job_id) in
      if Store.source_to_json prior.source = Store.source_to_json replay.source
         && prior.request_sha256 = request_sha argv inputs
      then Ok prior
      else Error (wrap ~job_id:prior.job_id (Store.Invalid_authority
          "interrupted launch differs from its original invocation source or request")) in
    None, result in
  match Fs_compat.update_private_file_durable_locked_result ~create:false location decide with
  | Fs_compat.Private_file_succeeded result -> result
  | Private_file_succeeded_with_cleanup_failure {value;cleanup_failure} ->
      let job_id = match value with
        | Ok reservation -> Some reservation.job_id
        | Error error -> error.job_id in
      Error {job_id;cause=Store.Commit_unconfirmed
          (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)}
  | Private_file_failed error ->
      Error (wrap (Store.Io_failed (Fs_compat.durable_append_error_to_string error)))
  | Private_file_failed_with_cleanup_failure {error;cleanup_failure} ->
      Error (wrap (Store.Io_failed (Fs_compat.durable_append_error_to_string error ^ "; " ^
          Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))))

let lookup ~base_path ~keeper_name invocation = protect (fun () ->
  let* base_path = canonical_base_path base_path in
  let location = path ~base_path ~keeper_name invocation in
  match validate_path ~base_path ~location ~create:false with
  | Error Store.Missing -> Ok None
  | Error ((Store.Invalid_authority _ | Store.Corrupt _ | Store.Conflict
           | Store.Io_failed _ | Store.Commit_unconfirmed _) as cause) ->
    Error (wrap cause)
  | Ok () ->
      let* contents = Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.getuid ())
          ~ownership_root:(Common.masc_dir_from_base_path ~base_path) location
          |> Result.map_error (fun error -> wrap (Store.Io_failed
              (Fs_compat.owned_regular_file_read_error_to_string error))) in
      match contents with
      | None -> Ok None
      | Some contents ->
          let* () = validate_path ~base_path ~location ~create:false |> Result.map_error wrap in
          let* () = if contents.snapshot.Fs_compat.permissions land 0o077 = 0 then Ok ()
            else Error (wrap (Store.Invalid_authority "invocation binding file is no longer private")) in
          let* reservation = decode contents.content |> Result.map_error wrap in
          let* () = check_scope ~base_path ~keeper_name ~invocation reservation
              |> Result.map_error (wrap ~job_id:reservation.job_id) in
          Ok (Some reservation))
