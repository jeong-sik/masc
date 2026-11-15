module Plan = Keeper_microvm_boot_plan

(* apple/container's vminitd (1.6.1) connects to the agent at
   [/run/container/<guest name>/rootfs] followed by this path, as written.
   Linux holds 107 bytes and a NUL in [sun_path], and a guest name has at
   most 63 characters ({!Keeper_sandbox_container_name}), which leaves this
   path at most 22 bytes. Past that, vminitd logs
   "is too long for a Unix Domain Socket path" and the host sees each
   connection end with no hello. The directory is the agent's own; the file
   name is what stays short. *)
let guest_path = "/run/masc-agent/sock"

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

let plan ~uid ~gid ~host_socket ~image ~guest_size ~mounts ~network ~environment ~labels
  : Plan.t
  =
  { Plan.image
  ; guest_size
  ; user = "0:0"
  ; working_directory = Keeper_sandbox_microvm.work_volume_guest_root
  ; command =
      [ Keeper_sandbox_microvm.shim_guest_path
      ; Exec_ssh_protocol.Relay.serve_flag
      ; guest_path
      ; Printf.sprintf "%d:%d" uid gid
      ]
  ; mounts
  ; isolation = List.filter agent_keeps Keeper_microvm_backend.all_guest_constraints
  ; capabilities_added = [ Plan.Cap_setuid; Plan.Cap_setgid; Plan.Cap_sys_admin ]
  ; published_sockets = [ { Plan.host_path = host_socket; guest_path } ]
  ; network
  ; environment =
      environment
      @ Keeper_sandbox_microvm.request_environment
          ~shim_config_path:Keeper_sandbox_microvm.shim_config_guest_path
  ; labels = labels @ [ relay_label ]
  }
;;

let publishes_agent ~base_path ~guest_name (facts : Plan.facts) =
  List.mem { Plan.host_path = host_path ~base_path ~guest_name; guest_path } facts.published_sockets
;;

type agent_check =
  | Agent_answered
  | Agent_unusable of string
  | Check_unavailable of string

let check_agent ~host_socket ~expected ~connect_budget_sec ~budget_sec =
  match Fs_compat.execution_context (), Eio_context.get_net_opt (), Eio_context.get_clock_opt () with
  | Fs_compat.Non_eio, (Some _ | None), (Some _ | None) ->
    Check_unavailable "a guest agent is reached only from an Eio fiber"
  | Fs_compat.Eio_fiber, None, (Some _ | None) | Fs_compat.Eio_fiber, Some _, None ->
    Check_unavailable "this process has no Eio network or clock to reach the guest agent with"
  | Fs_compat.Eio_fiber, Some net, Some clock ->
    (match
       Keeper_guest_socket.run ~net ~clock ~accept:(Keeper_guest_socket.refusal ~expected)
         ~socket:host_socket ~connect_budget_sec ~budget_sec Keeper_guest_socket.Probe
     with
     | Keeper_guest_socket.Exited { code = 0; _ } -> Agent_answered
     | Keeper_guest_socket.Exited { code; _ } ->
       Agent_unusable (Printf.sprintf "the shim's probe exited %d" code)
     | Keeper_guest_socket.Not_sent (Keeper_guest_socket.Unreachable { attempts; last }) ->
       Agent_unusable
         (Printf.sprintf "no hello over %d connections: %s" attempts last)
     | Keeper_guest_socket.Not_sent (Keeper_guest_socket.Refused refusal) ->
       Agent_unusable ("its hello was refused: " ^ Keeper_guest_socket.refusal_to_string refusal)
     | Keeper_guest_socket.Not_sent (Keeper_guest_socket.Incompatible detail) ->
       Agent_unusable ("it answered in a way this host cannot read: " ^ detail)
     | Keeper_guest_socket.Not_sent (Keeper_guest_socket.Bad_budget { connect_budget_sec; budget_sec }) ->
       Check_unavailable
         (Printf.sprintf "the check's budget is not finite and positive (connect %g, whole %g)"
            connect_budget_sec budget_sec)
     | Keeper_guest_socket.Timed_out _ -> Agent_unusable "the probe ran out of time"
     | Keeper_guest_socket.Broken { reason; _ } -> Agent_unusable reason)
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
