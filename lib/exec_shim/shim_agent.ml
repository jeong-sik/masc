(* The masc-exec-shim guest agent; see shim_agent.mli. agent_stub.c holds the
   syscalls OCaml's Unix library does not have. *)

module Relay = Exec_ssh_protocol.Relay

external remount_root_read_only : unit -> unit
  = "ocaml_shim_agent_remount_root_read_only"

external drop_privileges : int -> int -> unit = "ocaml_shim_agent_drop_privileges"
external root_read_only : unit -> bool = "ocaml_shim_agent_root_read_only"
external no_new_privs : unit -> bool = "ocaml_shim_agent_no_new_privs"

external mark_inherited_descriptors_close_on_exec : unit -> unit
  = "ocaml_shim_agent_cloexec_inherited"

type owner =
  { uid : int
  ; gid : int
  }

(* (uid_t)-1 tells setresuid to leave an id as it is, so the largest id a
   process can hold is one less. *)
let largest_id = 0xFFFF_FFFE

let parse_id text =
  if text <> "" && String.for_all (fun c -> c >= '0' && c <= '9') text
  then (
    match int_of_string_opt text with
    | Some id when id <= largest_id -> Some id
    | Some _ | None -> None)
  else None
;;

let parse_owner text =
  let not_owner () = Error (Printf.sprintf "owner %S is not UID:GID in decimal" text) in
  match String.split_on_char ':' text with
  | [ uid_text; gid_text ] ->
    (match parse_id uid_text, parse_id gid_text with
     | Some uid, Some gid ->
       if uid = 0 || gid = 0
       then
         Error
           (Printf.sprintf
              "owner %S names root; the agent serves only as a Keeper's uid and gid"
              text)
       else Ok { uid; gid }
     | None, (Some _ | None) | Some _, None -> not_owner ())
  | [] | [ _ ] | _ :: _ :: _ :: _ -> not_owner ()
;;

type start_error =
  | Not_root of { euid : int }
  | Socket_path_relative of string
  | Socket_directory_failed of
      { directory : string
      ; detail : string
      }
  | Socket_directory_off_root of { directory : string }
  | Listen_failed of
      { socket : string
      ; detail : string
      }
  | Remount_failed of string
  | Drop_failed of string

let start_error_to_string = function
  | Not_root { euid } ->
    Printf.sprintf
      "the agent starts as root to bind its socket and then drops to the Keeper's \
       uid; its effective uid is %d"
      euid
  | Socket_path_relative socket -> Printf.sprintf "socket path %S is relative" socket
  | Socket_directory_failed { directory; detail } ->
    Printf.sprintf "socket directory %s: %s" directory detail
  | Socket_directory_off_root { directory } ->
    Printf.sprintf
      "socket directory %s is on another filesystem than /; the --publish-socket relay \
       reaches only sockets on the container's root filesystem"
      directory
  | Listen_failed { socket; detail } -> Printf.sprintf "listen on %s: %s" socket detail
  | Remount_failed detail -> "re-mount / read-only: " ^ detail
  | Drop_failed detail -> "drop to the Keeper's uid and gid: " ^ detail
;;

let unix_detail error call argument =
  if argument = ""
  then Printf.sprintf "%s: %s" call (Unix.error_message error)
  else Printf.sprintf "%s %s: %s" call argument (Unix.error_message error)
;;

(* Root's, and nobody else's: a payload runs as the Keeper's uid and cannot
   enter it, so it can neither remove the socket nor bind its own there. *)
let socket_directory_perm = 0o700

(* Connections the kernel holds while the agent forks a relay. A Keeper's
   concurrent requests stay far below it; the measured stand-in used the
   same value (RFC section 4.3). *)
let listen_backlog = 64

let make_socket_directory directory =
  let failed detail = Error (Socket_directory_failed { directory; detail }) in
  match Unix.mkdir directory socket_directory_perm with
  | exception Unix.Unix_error (error, call, argument) ->
    failed (unix_detail error call argument)
  | () ->
    (* mkdir's mode passes through the umask; set it exactly. *)
    (match Unix.chmod directory socket_directory_perm with
     | () -> Ok ()
     | exception Unix.Unix_error (error, call, argument) ->
       failed (unix_detail error call argument))
;;

let on_root_filesystem directory =
  match Unix.stat directory, Unix.stat "/" with
  | here, root ->
    if here.Unix.st_dev = root.Unix.st_dev
    then Ok ()
    else Error (Socket_directory_off_root { directory })
  | exception Unix.Unix_error (error, call, argument) ->
    Error (Socket_directory_failed { directory; detail = unix_detail error call argument })
;;

let listen socket =
  let failed error call argument =
    Error (Listen_failed { socket; detail = unix_detail error call argument })
  in
  match Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 with
  | exception Unix.Unix_error (error, call, argument) -> failed error call argument
  | listener ->
    (match
       Unix.bind listener (Unix.ADDR_UNIX socket);
       Unix.listen listener listen_backlog
     with
     | () -> Ok listener
     | exception Unix.Unix_error (error, call, argument) ->
       Unix.close listener;
       failed error call argument)
;;

let remount () =
  match remount_root_read_only () with
  | () -> Ok ()
  | exception Unix.Unix_error (error, call, argument) ->
    Error (Remount_failed (unix_detail error call argument))
;;

let drop owner =
  match drop_privileges owner.uid owner.gid with
  | () -> Ok ()
  | exception Unix.Unix_error (error, call, argument) ->
    Error (Drop_failed (unix_detail error call argument))
  | exception Failure detail -> Error (Drop_failed detail)
;;

let start ~socket ~owner =
  let ( let* ) = Result.bind in
  let euid = Unix.geteuid () in
  if euid <> 0
  then Error (Not_root { euid })
  else if Filename.is_relative socket
  then Error (Socket_path_relative socket)
  else (
    let directory = Filename.dirname socket in
    let* () = make_socket_directory directory in
    let* () = on_root_filesystem directory in
    let* listener = listen socket in
    (* The socket exists on the root filesystem now, so it can go read-only;
       and while the agent is still root, so it can re-mount at all. *)
    match
      let* () = remount () in
      drop owner
    with
    | Ok () -> Ok listener
    | Error error ->
      Unix.close listener;
      Error error)
;;

let hello () : Relay.hello =
  { Relay.relay_version = Relay.version
  ; root_read_only = root_read_only ()
  ; uid = Unix.geteuid ()
  ; gid = Unix.getegid ()
  ; no_new_privs = no_new_privs ()
  }
;;

(* Bytes waiting for a nonblocking descriptor, oldest first. *)
module Pending = struct
  type t =
    { pieces : string Queue.t
    ; mutable offset : int (* bytes of the oldest piece already written *)
    ; mutable length : int (* bytes still waiting, over every piece *)
    }

  let create () = { pieces = Queue.create (); offset = 0; length = 0 }
  let length t = t.length
  let is_empty t = t.length = 0

  let push t piece =
    if piece <> ""
    then (
      Queue.push piece t.pieces;
      t.length <- t.length + String.length piece)
  ;;

  let clear t =
    Queue.clear t.pieces;
    t.offset <- 0;
    t.length <- 0
  ;;

  (* Writes what [fd] takes now from the oldest piece. Raises what
     [Unix.single_write_substring] raises. *)
  let write_some t fd =
    match Queue.peek_opt t.pieces with
    | None -> ()
    | Some piece ->
      let remaining = String.length piece - t.offset in
      let written = Unix.single_write_substring fd piece t.offset remaining in
      t.length <- t.length - written;
      if written = remaining
      then (
        ignore (Queue.pop t.pieces : string);
        t.offset <- 0)
      else t.offset <- t.offset + written
  ;;
end

(* How many bytes may wait in one direction before the relay stops reading
   the side that fills it. The shim then blocks on a full pipe: the same
   back-pressure a slow reader puts on [container exec] today. *)
let pending_high_water = 4 * Relay.max_payload_bytes

type output =
  { fd : Unix.file_descr
  ; chunk : string -> Relay.chunk
  }

let rec write_all fd text offset =
  if offset < String.length text
  then (
    match Unix.single_write_substring fd text offset (String.length text - offset) with
    | written -> write_all fd text (offset + written)
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> write_all fd text offset)
;;

let rec waitpid_retrying pid =
  match Unix.waitpid [] pid with
  | _, status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_retrying pid
;;

let exit_of_status ~host_signal_number = function
  | Unix.WEXITED code -> Relay.Exited code
  | Unix.WSIGNALED signal -> Relay.Signaled (host_signal_number signal)
  (* waitpid without WUNTRACED never reports a stop; read like a signal, as
     Exec_shim.trailer_of_status reads it. *)
  | Unix.WSTOPPED signal -> Relay.Signaled (host_signal_number signal)
;;

(* Moves bytes until the shim has closed its stdout and stderr, then reaps it
   and sends the exit chunk. *)
let pump ~conn ~pid ~stdin_w ~outputs ~host_signal_number =
  Unix.set_nonblock conn;
  Unix.set_nonblock stdin_w;
  List.iter (fun output -> Unix.set_nonblock output.fd) outputs;
  let to_child = Pending.create () in
  let to_host = Pending.create () in
  let child_stdin = ref (Some stdin_w) in
  let open_outputs = ref outputs in
  let host_sending = ref true in
  let host_reading = ref true in
  let close_child_stdin () =
    match !child_stdin with
    | None -> ()
    | Some fd ->
      Unix.close fd;
      child_stdin := None;
      Pending.clear to_child
  in
  (* The shim reads its stdin closing as a cancel. *)
  let host_gone () =
    host_sending := false;
    host_reading := false;
    Pending.clear to_host;
    close_child_stdin ()
  in
  let buffer = Bytes.create Relay.max_payload_bytes in
  while !open_outputs <> [] do
    let reads =
      (if !host_sending && Pending.length to_child < pending_high_water
       then [ conn ]
       else [])
      @
      if Pending.length to_host < pending_high_water
      then List.map (fun output -> output.fd) !open_outputs
      else []
    in
    let writes =
      (match !child_stdin with
       | Some fd when not (Pending.is_empty to_child) -> [ fd ]
       | Some _ | None -> [])
      @ if !host_reading && not (Pending.is_empty to_host) then [ conn ] else []
    in
    match Unix.select reads writes [] (-1.0) with
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> ()
    | readable, writable, _ ->
      if List.memq conn readable
      then (
        match Unix.read conn buffer 0 (Bytes.length buffer) with
        | 0 ->
          (* The host has said all it will. Bytes it sent before still go to
             the shim; its stdin closes once they have. *)
          host_sending := false;
          if Pending.is_empty to_child then close_child_stdin ()
        | read ->
          if Option.is_some !child_stdin
          then Pending.push to_child (Bytes.sub_string buffer 0 read)
        | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _)
          -> ()
        | exception Unix.Unix_error ((Unix.ECONNRESET | Unix.EPIPE), _, _) -> host_gone ());
      (match !child_stdin with
       | Some fd when List.memq fd writable ->
         (match Pending.write_some to_child fd with
          | () ->
            if (not !host_sending) && Pending.is_empty to_child then close_child_stdin ()
          | exception
              Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) -> ()
          | exception Unix.Unix_error (Unix.EPIPE, _, _) -> close_child_stdin ())
       | Some _ | None -> ());
      let current = !open_outputs in
      List.iter
        (fun output ->
          if List.memq output.fd readable
          then (
            match Unix.read output.fd buffer 0 (Bytes.length buffer) with
            | 0 ->
              Unix.close output.fd;
              open_outputs := List.filter (fun other -> other.fd != output.fd) !open_outputs
            | read ->
              (* After the host has gone the bytes are read and dropped, so the
                 shim never blocks and still sees its stdin close and its
                 deadline. *)
              if !host_reading
              then
                Pending.push to_host
                  (Relay.encode (output.chunk (Bytes.sub_string buffer 0 read)))
            | exception
                Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) -> ()))
        current;
      if !host_reading && List.memq conn writable
      then (
        match Pending.write_some to_host conn with
        | () -> ()
        | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _)
          -> ()
        | exception Unix.Unix_error ((Unix.EPIPE | Unix.ECONNRESET), _, _) -> host_gone ())
  done;
  close_child_stdin ();
  let status = waitpid_retrying pid in
  if !host_reading
  then (
    Pending.push to_host (Relay.encode (Relay.Exit (exit_of_status ~host_signal_number status)));
    Unix.clear_nonblock conn;
    let rec flush () =
      if not (Pending.is_empty to_host)
      then (
        match Pending.write_some to_host conn with
        | () -> flush ()
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> flush ()
        | exception Unix.Unix_error ((Unix.EPIPE | Unix.ECONNRESET), _, _) -> ())
    in
    flush ())
;;

let read_kind conn =
  let byte = Bytes.create 1 in
  let rec read () =
    match Unix.read conn byte 0 1 with
    | 0 -> None
    | _ -> Relay.request_kind_of_byte (Bytes.get byte 0)
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> read ()
    | exception Unix.Unix_error ((Unix.ECONNRESET | Unix.EPIPE), _, _) -> None
  in
  read ()
;;

let run_child ~conn ~program ~argv ~env ~host_signal_number =
  let stdin_r, stdin_w = Unix.pipe ~cloexec:true () in
  let stdout_r, stdout_w = Unix.pipe ~cloexec:true () in
  let stderr_r, stderr_w = Unix.pipe ~cloexec:true () in
  let spawned =
    match Unix.create_process_env program argv env stdin_r stdout_w stderr_w with
    | pid -> Ok pid
    | exception Unix.Unix_error (error, call, argument) ->
      Error (unix_detail error call argument)
  in
  List.iter Unix.close [ stdin_r; stdout_w; stderr_w ];
  match spawned with
  | Error detail ->
    (* No exit chunk: the host reads a connection that ends without one as a
       transport failure, which is what a shim that never ran is. *)
    prerr_endline (Printf.sprintf "masc-exec-shim --serve: run %s: %s" program detail);
    List.iter Unix.close [ stdin_w; stdout_r; stderr_r ]
  | Ok pid ->
    pump ~conn ~pid ~stdin_w
      ~outputs:
        [ { fd = stdout_r; chunk = (fun bytes -> Relay.Stdout bytes) }
        ; { fd = stderr_r; chunk = (fun bytes -> Relay.Stderr bytes) }
        ]
      ~host_signal_number
;;

let relay ~conn ~program ~env ~host_signal_number =
  match write_all conn (Relay.encode (Relay.Hello (hello ()))) 0 with
  | exception Unix.Unix_error ((Unix.EPIPE | Unix.ECONNRESET), _, _) -> ()
  | () ->
    (match read_kind conn with
     | None -> ()
     | Some Relay.Run ->
       run_child ~conn ~program ~argv:[| program |] ~env ~host_signal_number
     | Some Relay.Probe ->
       run_child ~conn ~program ~argv:[| program; "--probe" |] ~env ~host_signal_number)
;;

(* As the VM's first process the agent inherits every orphan, and it reaps at
   least this often. SIGCHLD stays at its default: ignoring it would have the
   kernel reap a relay's shim child before the relay reads its status, because
   a forked relay inherits the ignored SIGCHLD. *)
let reap_interval_sec = 1.0

let rec reap_children () =
  match Unix.waitpid [ Unix.WNOHANG ] (-1) with
  | 0, _ -> ()
  | _, _ -> reap_children ()
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> ()
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap_children ()
;;

let fork_relay ~listener ~conn ~program ~env ~host_signal_number =
  match Unix.fork () with
  | 0 ->
    Unix.close listener;
    (match relay ~conn ~program ~env ~host_signal_number with
     | () -> Unix._exit 0
     | exception exn ->
       (* A forked relay must never return into the accept loop it was
          forked from. *)
       prerr_endline ("masc-exec-shim --serve: relay: " ^ Printexc.to_string exn);
       Unix._exit 1)
  | _relay -> Unix.close conn
  | exception Unix.Unix_error (error, call, argument) ->
    prerr_endline ("masc-exec-shim --serve: " ^ unix_detail error call argument);
    Unix.close conn
;;

let serve ~listener ~program ~host_signal_number =
  let env = Unix.environment () in
  let rec loop () =
    reap_children ();
    (match Unix.select [ listener ] [] [] reap_interval_sec with
     | [], _, _ -> ()
     | _ :: _, _, _ ->
       (match Unix.accept ~cloexec:true listener with
        | conn, _ -> fork_relay ~listener ~conn ~program ~env ~host_signal_number
        | exception
            Unix.Unix_error
              ((Unix.EINTR | Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.ECONNABORTED), _, _) ->
          ()
        | exception Unix.Unix_error (error, call, argument) ->
          (* The agent holds one descriptor between connections, so this is
             the VM running out of something. Ending the agent ends the VM,
             and masc boots a new one. *)
          prerr_endline ("masc-exec-shim --serve: " ^ unix_detail error call argument);
          exit 1)
     | exception Unix.Unix_error (Unix.EINTR, _, _) -> ());
    loop ()
  in
  loop ()
;;

let fail message =
  prerr_endline ("masc-exec-shim --serve: " ^ message);
  exit 1
;;

let main ~host_signal_number ~argv0 ~socket ~owner =
  (* Every EPIPE branch above depends on this: with SIGPIPE at its default, a
     host that goes away would kill the relay writing to it. Forked relays
     inherit the disposition. *)
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  mark_inherited_descriptors_close_on_exec ();
  match parse_owner owner with
  | Error message -> fail message
  | Ok owner ->
    if Filename.is_relative argv0
    then
      fail
        (Printf.sprintf
           "started as %S; start it by its absolute path, which is the shim each \
            relay runs"
           argv0)
    else (
      match start ~socket ~owner with
      | Error error -> fail (start_error_to_string error)
      | Ok listener -> serve ~listener ~program:argv0 ~host_signal_number)
;;
