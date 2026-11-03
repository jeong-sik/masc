module Plan = Keeper_microvm_boot_plan

let guest_path = "/run/masc-agent/agent.sock"

(* 64 bits of the guest name's digest: two guests of one base path do not
   meet by chance, and the path stays far below the socket limit. *)
let socket_name_hex_length = 16

let host_path ~base_path ~guest_name =
  let digest = Agent_core_sha256.(digest_string guest_name |> to_hex) in
  Filename.concat
    (Config_dir_resolver.microvm_agent_socket_dir ~base_path)
    (String.sub digest 0 socket_name_hex_length ^ ".sock")
;;

let relay_label = "masc.mcp.agent_relay", string_of_int Exec_ssh_protocol.Relay.version

(* The agent re-mounts the root itself after binding there; the other
   constraints hold for it as for any guest. *)
let agent_keeps = function
  | Keeper_microvm_backend.Read_only_rootfs -> false
  | Keeper_microvm_backend.Drop_all_capabilities
  | Keeper_microvm_backend.Remove_on_exit
  | Keeper_microvm_backend.Scratch_tmpfs -> true
;;

let plan ~uid ~gid ~host_socket (exec_plan : Plan.t) : Plan.t =
  { exec_plan with
    user = "0:0"
  ; command =
      [ Keeper_sandbox_microvm.shim_guest_path
      ; Exec_ssh_protocol.Relay.serve_flag
      ; guest_path
      ; Printf.sprintf "%d:%d" uid gid
      ]
  ; isolation = List.filter agent_keeps exec_plan.isolation
  ; capabilities_added = [ Plan.Cap_setuid; Plan.Cap_setgid; Plan.Cap_sys_admin ]
  ; published_sockets = [ { Plan.host_path = host_socket; guest_path } ]
  ; environment =
      exec_plan.environment
      @ Keeper_sandbox_microvm.request_environment
          ~shim_config_path:Keeper_sandbox_microvm.shim_config_guest_path
  ; labels = exec_plan.labels @ [ relay_label ]
  }
;;

type preparation_error =
  | Directory_unusable of
      { path : string
      ; detail : string
      }
  | Socket_path_unusable of
      { path : string
      ; detail : string
      }
  | Path_occupied of { path : string }
  | Guest_presence_unknown of string
  | Guest_still_present

let preparation_error_message = function
  | Directory_unusable { path; detail } ->
    Printf.sprintf "microvm_agent_socket_directory_unusable: %s: %s" path detail
  | Socket_path_unusable { path; detail } ->
    Printf.sprintf "microvm_agent_socket_path_unusable: %s: %s" path detail
  | Path_occupied { path } ->
    Printf.sprintf
      "microvm_agent_socket_path_occupied: %s holds something other than a socket; \
       it is left for the operator rather than removed"
      path
  | Guest_presence_unknown detail ->
    "microvm_agent_socket_guest_presence_unknown: the runtime could not say \
     whether the guest is gone, so its old socket file is left in place: "
    ^ detail
  | Guest_still_present ->
    "microvm_agent_socket_guest_present: a guest of this name is still listed, \
     so the socket file it may own is left in place"
;;

let private_directory_permissions = 0o700

(* The parent is the shared [microvm] directory, which the shim and identity
   directories also live under: made when missing, left as it is otherwise. *)
let ensure_private_directory path =
  let check () =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; st_uid; st_perm; _ } when st_uid = Unix.geteuid () ->
      if st_perm = private_directory_permissions
      then Ok ()
      else (
        match Unix.chmod path private_directory_permissions with
        | () -> Ok ()
        | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error))
    | { Unix.st_kind = Unix.S_DIR; _ } -> Error "owned by another user"
    | { Unix.st_kind =
          Unix.(S_REG | S_CHR | S_BLK | S_LNK | S_FIFO | S_SOCK)
      ; _
      } -> Error "not a directory"
    | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  in
  let make path =
    match Unix.mkdir path private_directory_permissions with
    | () -> Ok ()
    | exception Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
    | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  in
  Result.bind (make (Filename.dirname path)) (fun () ->
    Result.bind (make path) check)
;;

let prepare_host_socket ~guest_presence path =
  let directory = Filename.dirname path in
  match ensure_private_directory directory with
  | Error detail -> Error (Directory_unusable { path = directory; detail })
  | Ok () ->
    (match Unix.lstat path with
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
     | exception Unix.Unix_error (error, _, _) ->
       Error (Socket_path_unusable { path; detail = Unix.error_message error })
     | { Unix.st_kind = Unix.(S_REG | S_DIR | S_CHR | S_BLK | S_LNK | S_FIFO); _ } ->
       Error (Path_occupied { path })
     | { Unix.st_kind = Unix.S_SOCK; _ } ->
       (match guest_presence () with
        | Error detail -> Error (Guest_presence_unknown detail)
        | Ok Keeper_microvm_guest_inventory.Present -> Error Guest_still_present
        | Ok Keeper_microvm_guest_inventory.Absent ->
          (match Unix.unlink path with
           | () -> Ok ()
           | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
           | exception Unix.Unix_error (error, _, _) ->
             Error (Socket_path_unusable { path; detail = Unix.error_message error }))))
;;
