module Dependency = Keeper_composition_dependency
module Async = Keeper_msg_async
open Result.Syntax

let protect f =
  try f () with
  | Sys_error detail -> Error detail
  | Unix.Unix_error (code, operation, path) ->
    Error (Printf.sprintf "%s(%s): %s" operation path (Unix.error_message code))

let canonical_base_path path =
  try Ok (Fs_compat.realpath path) with
  | Unix.Unix_error (code, operation, path) ->
    Error (Printf.sprintf "%s(%s): %s" operation path (Unix.error_message code))

let record ~base_path ~keeper_name binding =
  `Assoc ["schema", `String "keeper.named_composition_run.v1";
    "base_path", `String base_path; "keeper_name", `String keeper_name;
    "binding", Dependency.composition_to_json binding]

let path ~base_path ~keeper_name binding =
  let identity = `List [`String keeper_name;
      `String (Keeper_tool_plan.Composition_run_id.to_string binding.Dependency.composition_run_id)] in
  let name = Agent_core_sha256.(digest_string (Yojson.Safe.to_string identity) |> to_hex) ^ ".json" in
  Filename.concat
    (Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path)
       "keeper_msg_requests") "named_composition_runs") name

let read ~root location =
  let* contents = Fs_compat.load_owned_regular_file_with_snapshot
      ~owner_uid:(Unix.getuid ()) ~ownership_root:root location
    |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string in
  match contents with
  | None -> Ok None
  | Some contents when contents.snapshot.Fs_compat.permissions land 0o077 = 0 ->
    Ok (Some contents.content)
  | Some _ -> Error "named composition membership record is not private"

let equal_record expected bytes =
  try
    let json = Yojson.Safe.from_string bytes in
    let* _ = Agent_core.Execution_json.object_fields ~context:"named composition membership"
        ~required:["schema";"base_path";"keeper_name";"binding"] ~optional:[] json in
    if Yojson.Safe.equal (Yojson.Safe.sort expected) (Yojson.Safe.sort json) then Ok ()
    else Error "named composition request is not the originally admitted member"
  with Yojson.Json_error detail -> Error detail

let validate ~base_path ~keeper_name binding = protect (fun () ->
  let* base_path = canonical_base_path base_path in
  let root = Common.masc_dir_from_base_path ~base_path in
  let* bytes = read ~root (path ~base_path ~keeper_name binding) in
  match bytes with
  | None -> Error "original named composition membership is absent"
  | Some bytes -> equal_record (record ~base_path ~keeper_name binding) bytes)

let admit ~base_path ~keeper_name binding = protect (fun () ->
  let* proof = Async.load_canonical_durable_queued ~base_path ~caller:keeper_name binding.Dependency.request_id
    |> Result.map_error Async.canonical_queued_error_to_string in
  let entry = Async.durable_queued_entry proof in
  let* () = if String.equal entry.keeper_name keeper_name then Ok ()
    else Error "named composition admission belongs to another Keeper" in
  let* source = match entry.request_context with
    | None -> Error "named composition admission has no original source"
    | Some fields -> Dependency.composition_of_request_context ~request_id:entry.request_id fields in
  let* () = if Dependency.composition_to_json source = Dependency.composition_to_json binding then Ok ()
    else Error "named composition admission differs from its accepted source" in
  let base_path = entry.base_path in
  let root = Common.masc_dir_from_base_path ~base_path in
  let location = path ~base_path ~keeper_name binding in
  let expected = record ~base_path ~keeper_name binding in
  let* () = match Keeper_fs_durable_directory.ensure ~before_prepare:(fun () -> ())
      ~before_directory_fsync:(fun _ -> ()) ~ownership_root:root (Filename.dirname location) with
    | Ok _ -> Ok () | Error _ -> Error "named composition membership directory preparation failed" in
  let* prior = read ~root location in
  let* () = match prior with None -> Ok () | Some bytes -> equal_record expected bytes in
  let decide bytes =
    let decision =
      let* current = read ~root location in
      if current <> Some bytes then Error "named composition membership path changed during admission"
      else if bytes = "" && prior = None then Ok true
      else let* () = equal_record expected bytes in Ok false in
    match decision with
    | Error detail -> None, Error detail
    | Ok false -> None, Ok ()
    | Ok true -> Some (Yojson.Safe.to_string expected ^ "\n"), Ok () in
  match Fs_compat.update_private_file_durable_locked_result location decide with
  | Fs_compat.Private_file_succeeded result -> result
  | Private_file_succeeded_with_cleanup_failure {value=_;cleanup_failure} ->
    Error ("named composition membership commit is unconfirmed: " ^
      Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
  | Private_file_failed error -> Error (Fs_compat.durable_append_error_to_string error)
  | Private_file_failed_with_cleanup_failure {error;cleanup_failure} ->
    Error (Fs_compat.durable_append_error_to_string error ^ "; " ^
      Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
