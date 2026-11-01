type rejection =
  | Base_path_missing of string
  | Base_path_not_directory of string
  | Root_binding_changed of string
  | Workspace_directory_changed of string
  | Workspace_boundary_refused of Fs_compat.owned_directory_chain_rejection
  | Raised of { exception_ : exn; backtrace : Printexc.raw_backtrace }

type root = { path : string; device : int; inode : int }
type observation = { root : root; workspace_identity : (int * int) option }
type t = {
  requested_path : string;
  workspace_path : string;
  captured : (observation, rejection) result;
}

let raised_failure exception_ =
  Raised { exception_; backtrace = Printexc.get_raw_backtrace () }

let in_worker work =
  let capture () =
    match work () with
    | result -> result
    | exception exception_ -> Error (raised_failure exception_)
  in
  match (match Fs_compat.execution_context () with
    | Non_eio -> capture ()
    | Eio_fiber -> Eio_unix.run_in_systhread ~label:"board-workspace-binding" capture)
  with
  | result -> result
  | exception exception_ -> Error (raised_failure exception_)

let inspect_root path =
  match Unix.stat path with
  | stat when stat.Unix.st_kind = Unix.S_DIR -> Ok stat
  | _ -> Error (Base_path_not_directory path)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    Error (Base_path_missing path)

let same_identity root stat =
  stat.Unix.st_kind = Unix.S_DIR
  && stat.Unix.st_dev = root.device && stat.Unix.st_ino = root.inode

let inspect_workspace root =
  let path = Common.masc_dir_from_base_path ~base_path:root.path in
  match Fs_compat.inspect_owned_directory_chain ~ownership_root:root.path path with
  | Error error -> Error (Workspace_boundary_refused error)
  | Ok Owned_directory_missing -> Ok None
  | Ok (Owned_directory stat) -> Ok (Some (stat.Unix.st_dev, stat.Unix.st_ino))

let recheck_root requested_path root =
  let open Result.Syntax in
  let* requested = inspect_root requested_path in
  if not (same_identity root requested) then
    Error (Root_binding_changed requested_path)
  else
    let* canonical = inspect_root root.path in
    if same_identity root canonical then Ok ()
    else Error (Root_binding_changed root.path)

let capture ~base_path =
  if String.equal base_path "" then
    invalid_arg "Board_workspace_binding.capture: base_path must not be empty";
  let requested_path =
    if Filename.is_relative base_path then Filename.concat (Sys.getcwd ()) base_path
    else base_path
  in
  let captured = in_worker (fun () ->
    let open Result.Syntax in
    let* stat = inspect_root requested_path in
    let path = Unix.realpath requested_path in
    let root = { path; device = stat.Unix.st_dev; inode = stat.Unix.st_ino } in
    let* () = recheck_root requested_path root in
    let* workspace_identity = inspect_workspace root in
    Ok { root; workspace_identity })
  in
  let base = match captured with
    | Ok observation -> observation.root.path
    | Error _ -> requested_path
  in
  { requested_path; captured;
    workspace_path = Common.masc_dir_from_base_path ~base_path:base }

let workspace_masc_dir binding = binding.workspace_path

let same_workspace_identity left right =
  match left, right with
  | None, None -> true
  | Some (left_device, left_inode), Some (right_device, right_inode) ->
    Int.equal left_device right_device && Int.equal left_inode right_inode
  | None, Some _ | Some _, None -> false

let observe binding =
  match binding.captured with
  | Error _ as error -> error
  | Ok captured -> in_worker (fun () ->
      let open Result.Syntax in
      let* () = recheck_root binding.requested_path captured.root in
      let* workspace_identity = inspect_workspace captured.root in
      match captured.workspace_identity with
      | Some original
        when not (same_workspace_identity workspace_identity (Some original)) ->
        Error (Workspace_directory_changed binding.workspace_path)
      | Some _ | None -> Ok { root = captured.root; workspace_identity })

let same_root left right =
  String.equal left.root.path right.root.path
  && left.root.device = right.root.device && left.root.inode = right.root.inode

let workspace_directory_missing observation =
  Option.is_none observation.workspace_identity

let revalidate binding observation =
  match observe binding with
  | Error _ as error -> error
  | Ok current ->
    if not (same_root observation current) then
      Error (Root_binding_changed binding.requested_path)
    else if not (same_workspace_identity
                   observation.workspace_identity current.workspace_identity) then
      Error (Workspace_directory_changed binding.workspace_path)
    else Ok ()

let rejection_to_string = function
  | Base_path_missing path -> Printf.sprintf "Board BasePath is missing: %s" path
  | Base_path_not_directory path ->
    Printf.sprintf "Board BasePath is not a directory: %s" path
  | Root_binding_changed path -> Printf.sprintf "Board BasePath binding changed: %s" path
  | Workspace_directory_changed path ->
    Printf.sprintf "Board state directory identity changed: %s" path
  | Workspace_boundary_refused error ->
    Fs_compat.owned_directory_chain_rejection_to_string error
  | Raised { exception_; _ } -> Printexc.to_string exception_

let raised = function
  | Raised { exception_; backtrace } -> Some (exception_, backtrace)
  | Base_path_missing _ | Base_path_not_directory _ | Root_binding_changed _
  | Workspace_directory_changed _ | Workspace_boundary_refused _ -> None
