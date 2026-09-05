open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime
open Keeper_path_rejection

let resolve_missing_cwd cwd =
  Error (Printf.sprintf "cwd_not_directory: %s (directory does not exist)" cwd)

type execute_cwd_resolution_error =
  | Cwd_missing of { cwd : string }
  | Cwd_not_directory of { cwd : string }
  | Cwd_rejected of Keeper_path_rejection.keeper_path_rejection
  | Cwd_root_verification_failed of { detail : string }

let execute_cwd_resolution_error_code = function
  | Cwd_missing _ -> "cwd_missing"
  | Cwd_not_directory _ -> "cwd_not_directory"
  | Cwd_rejected (Outside_sandbox _) -> "cwd_outside_sandbox"
  | Cwd_root_verification_failed _ -> "cwd_root_verification_failed"
  | Cwd_rejected
      ( Path_required
      | Invalid_lexical_endpoint
      | Invalid_normalized_path_projection _
      | Sandbox_roots_normalized_empty _ ) ->
    "cwd_invalid"

let execute_cwd_resolution_error_public_message = function
  | Cwd_missing _ -> "Requested cwd does not exist in the Keeper-visible workspace."
  | Cwd_not_directory _ -> "Requested cwd is not a directory."
  | Cwd_rejected (Outside_sandbox _) -> "Requested cwd is outside the Keeper sandbox."
  | Cwd_root_verification_failed _ ->
    "Requested cwd containment could not be verified."
  | Cwd_rejected
      ( Path_required
      | Invalid_lexical_endpoint
      | Invalid_normalized_path_projection _
      | Sandbox_roots_normalized_empty _ ) ->
    "Requested cwd is invalid."

let execute_cwd_resolution_error_private_message = function
  | Cwd_missing { cwd } ->
    Printf.sprintf "cwd_not_directory: %s (directory does not exist)" cwd
  | Cwd_not_directory { cwd } ->
    Printf.sprintf "cwd_not_directory: %s (path_is_file_not_directory)" cwd
  | Cwd_root_verification_failed { detail } ->
    Printf.sprintf "cwd_root_verification_failed: %s" detail
  | Cwd_rejected rejection ->
    Keeper_path_rejection.rejection_to_user_message rejection

let resolve_tool_read_cwd
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  let resolved =
    if raw_cwd = ""
    then Ok (Keeper_sandbox_repo_path.playground_root_no_create ~config ~meta)
    else resolve_keeper_read_cwd ~config ~meta ~raw_path:raw_cwd
  in
  match resolved with
  | Error _ as err -> err
  | Ok cwd when Fs_compat.file_exists cwd && Sys.is_directory cwd -> Ok cwd
  | Ok cwd ->
    if not (Fs_compat.file_exists cwd) then resolve_missing_cwd cwd
    else
      Error (Printf.sprintf "cwd_not_directory: %s (path_is_file_not_directory)" cwd)

let requested_tool_execute_cwd ~config ~meta ~write_enabled ~args =
  let raw_cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  if raw_cwd = ""
  then
    if write_enabled
    then keeper_default_write_root ~config ~meta
    else Keeper_sandbox_repo_path.playground_root_no_create ~config ~meta
  else if Filename.is_relative raw_cwd
  then Filename.concat (keeper_default_write_root ~config ~meta) raw_cwd
  else raw_cwd

(* Whose filesystem says whether the cwd exists follows where the tree is
   (RFC-0427 A-1). A shared-mount tree is on this host, so the host answers
   and the allowed-root identity is verified here. A tree the endpoint owns
   (a microvm work volume, a remote_ssh account) is not: the host directory
   of the same name is the bookkeeping bundle, and asking it refused 38
   Execute calls on 2026-09-05 whose cwd existed in the guest. The path is
   still confined lexically above, the remote lane maps it lexically
   ([Keeper_remote_path.host_to_remote]), and the endpoint's shim chdirs
   into it inside its own jail and answers ENOENT itself. *)
let resolve_tool_execute_cwd_typed ~config ~meta ~write_enabled ~args =
  let raw_path = requested_tool_execute_cwd ~config ~meta ~write_enabled ~args in
  match resolve_keeper_execute_cwd_typed ~config ~meta ~raw_path with
  | Error rejection -> Error (Cwd_rejected rejection)
  | Ok confined ->
    let cwd = Keeper_alerting_path.confined_host_path confined in
    (match Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile with
     | Keeper_types_profile_sandbox.Endpoint_owned -> Ok cwd
     | Keeper_types_profile_sandbox.Shared_mount ->
       if Fs_compat.file_exists cwd && Sys.is_directory cwd
       then
         (match Keeper_tool_shared_runtime.verify_keeper_confined_root confined with
          | Ok () -> Ok cwd
          | Error detail -> Error (Cwd_root_verification_failed { detail }))
       else if not (Fs_compat.file_exists cwd)
       then Error (Cwd_missing { cwd })
       else Error (Cwd_not_directory { cwd }))

let resolve_tool_execute_cwd ~config ~meta ~write_enabled ~args =
  resolve_tool_execute_cwd_typed ~config ~meta ~write_enabled ~args
  |> Result.map_error execute_cwd_resolution_error_private_message

let resolve_tool_read_path
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
  match resolve_tool_read_cwd ~config ~meta ~args with
  | Error _ as error -> error
  | Ok cwd ->
    if raw_path = ""
    then Ok cwd
    else
      let projected_path =
        if Filename.is_relative raw_path then Filename.concat cwd raw_path else raw_path
      in
      resolve_projected_keeper_read_path
        ~config
        ~meta
        ~raw_for_error:raw_path
        ~projected_path

let shell_command_available name =
  Executable_path.command_available name

let normalize_for_containment path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

let in_playground ~root ~cwd ~meta =
  let cwd_canonical = normalize_for_containment cwd in
  let playground_rel = Keeper_sandbox.sandbox_root_rel_of_meta ~meta in
  let playground_abs = normalize_for_containment (Filename.concat root playground_rel) in
  String.starts_with ~prefix:(playground_abs ^ "/") (cwd_canonical ^ "/")
  || String.equal playground_abs cwd_canonical
