open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime
open Keeper_path_rejection

let resolve_missing_cwd cwd =
  Error
    (Keeper_alerting_path.caller_refusal
       (Keeper_alerting_path.Missing_cwd { cwd; read_hint = None }))

type execute_cwd_resolution_error =
  | Cwd_missing of { cwd : string }
  | Cwd_not_directory of { cwd : string }
  | Cwd_rejected of Keeper_path_rejection.keeper_path_rejection
  | Cwd_root_verification_failed of { detail : string }
  | Cwd_namespace_unavailable of string

let execute_cwd_resolution_error_class = function
  | Cwd_namespace_unavailable _ -> Tool_result.Dependency_unavailable
  | Cwd_missing _ | Cwd_not_directory _ | Cwd_rejected _
  | Cwd_root_verification_failed _ -> Tool_result.Policy_rejection

let execute_cwd_resolution_error_code = function
  | Cwd_namespace_unavailable _ -> "remote_ssh_endpoint_unavailable"
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
  | Cwd_namespace_unavailable detail -> detail
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
  | Cwd_namespace_unavailable detail -> detail
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
    else resolve_keeper_read_path ~config ~meta ~raw_path:raw_cwd
  in
  match resolved with
  | Error _ as err -> err
  | Ok cwd ->
    (match cwd_existence ~meta cwd with
     | Endpoint_decides | Host_directory -> Ok cwd
     | Host_missing -> resolve_missing_cwd cwd
     | Host_file ->
       Error
         (Keeper_alerting_path.caller_refusal
            (Keeper_alerting_path.Cwd_is_file { cwd })))

let requested_tool_execute_cwd ~config ~meta ~write_enabled ~args =
  (* A write-enabled Execute materializes the Keeper's sandbox root before it
     names any cwd, so a relative cwd such as "." on a fresh Keeper resolves
     inside it; a read-only one creates nothing. The cwd itself is never
     created. *)
  let root =
    if write_enabled
    then keeper_default_write_root ~config ~meta
    else Keeper_sandbox_repo_path.playground_root_no_create ~config ~meta
  in
  match
    host_path_of_keeper_visible_path
      ~config
      ~meta
      (Safe_ops.json_string ~default:"" "cwd" args)
  with
  | Some cwd -> cwd
  | None -> root

(* Existence is asked of the filesystem that holds the tree
   ([cwd_existence], RFC-0427 A-1). On a shared mount the allowed-root
   identity is verified here as well. A tree the endpoint owns is still
   confined lexically above, the remote lane maps it lexically
   ([Keeper_remote_path.host_to_remote]), and the endpoint's shim chdirs
   into it inside its own jail and answers ENOENT itself. *)
let resolve_tool_execute_cwd_typed ~remote_workspace_root ~config ~meta ~write_enabled ~args =
  let open Result.Syntax in
  let caller_cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  let raw_path = requested_tool_execute_cwd ~config ~meta ~write_enabled ~args in
  let* raw_path = match remote_workspace_root with
    | Some remote_workspace_root ->
      (* Omitted and relative cwd have already become internal coordinates.
         Only an absolute caller value belongs to the endpoint namespace. *)
      if caller_cwd = "" || Filename.is_relative caller_cwd then Ok raw_path
      else Ok (Keeper_workspace_namespace.project_input
        ~remote_workspace_root ~config ~meta raw_path)
    | None ->
      (match meta.sandbox_profile with
       | Remote_ssh -> Error (Cwd_namespace_unavailable "remote_ssh_namespace_unresolved")
       | Docker | Micro_vm -> Ok raw_path) in
  (* Execute returns the container-visible cwd. A caller may use that exact
     directory again: [requested_tool_execute_cwd] mapped it through the
     admitted Keeper's own mount, and the same confinement and root-identity
     checks apply here. *)
  match resolve_keeper_execute_cwd_typed ~config ~meta ~raw_path with
  | Error rejection -> Error (Cwd_rejected rejection)
  | Ok confined ->
    let cwd = Keeper_alerting_path.confined_host_path confined in
    (match cwd_existence ~meta cwd with
     | Endpoint_decides -> Ok cwd
     | Host_directory ->
       (match Keeper_tool_shared_runtime.verify_keeper_confined_root confined with
        | Ok () -> Ok cwd
        | Error detail -> Error (Cwd_root_verification_failed { detail }))
     | Host_missing -> Error (Cwd_missing { cwd })
     | Host_file -> Error (Cwd_not_directory { cwd }))

let resolve_tool_execute_cwd ~remote_workspace_root ~config ~meta ~write_enabled ~args =
  resolve_tool_execute_cwd_typed ~remote_workspace_root ~config ~meta ~write_enabled ~args
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
    else resolve_keeper_read_path_in_cwd ~config ~meta ~host_cwd:cwd ~raw_path
