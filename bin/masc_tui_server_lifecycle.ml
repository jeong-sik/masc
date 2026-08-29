(* Opt-in, on-demand masc server start from inside the TUI.
   RFC tui-server-lifecycle. See the .mli for the contract. *)

type discovery =
  | Sibling of string
  | On_path of string
  | Not_found of { manual_command : string }

(* The server and the TUI ship as siblings (scripts/install.sh installs
   [masc] and [masc-tui] into the same prefix), so this is the basename to
   look for beside the running TUI binary and on the PATH. *)
let server_binary_basename = "masc"

let manual_start_command ~base_path ~host ~port =
  Printf.sprintf "masc --base-path %s --host %s --port %d" base_path host port

let discover_server_binary ~tui_exe ~file_exists ~path_lookup ~base_path ~host
    ~port =
  let sibling =
    Filename.concat (Filename.dirname tui_exe) server_binary_basename
  in
  if file_exists sibling then Sibling sibling
  else
    match path_lookup server_binary_basename with
    | Some path -> On_path path
    | None ->
        Not_found { manual_command = manual_start_command ~base_path ~host ~port }

let server_argv ~masc_bin ~base_path ~host ~port =
  [
    masc_bin;
    "--base-path";
    base_path;
    "--host";
    host;
    "--port";
    string_of_int port;
  ]

type health_outcome =
  | Ready
  | Server_exited
  | Timed_out of int

let wait_healthy ~health_ok ~child_alive ~attempts ~sleep =
  let rec loop n =
    if health_ok () then Ready
    else if not (child_alive ()) then Server_exited
    else if n >= attempts then Timed_out n
    else (
      sleep ();
      loop (n + 1))
  in
  if attempts <= 0 then Timed_out 0 else loop 1

type owned_server = {
  pgid : int;
  port : int;
}

let owned_pgid t = t.pgid
let owned_port t = t.port

let start ~masc_bin ~base_path ~host ~port ~env =
  let argv = server_argv ~masc_bin ~base_path ~host ~port in
  match Process_eio_detached.spawn_detached_devnull ~argv ~env ~cwd:base_path with
  | Ok handle -> Ok { pgid = handle.Process_eio_detached.devnull_pgid; port }
  | Error msg -> Error msg

let stop t ~grace_sec =
  Process_eio_detached.tree_kill ~pgid:t.pgid ~signal:Sys.sigterm ~grace_sec
