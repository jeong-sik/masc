type invalid_input =
  | Executable | Arguments | Environment | Directory | Payload_uid | Payload_gid
  | Shared_uid | Controller_not_root

type stage =
  | Allocate | Duplicate_stdio | Open_directory | Create_gate | Mask_signals | Create_child
  | Child_descriptors | Child_close_descriptors | Child_session | Child_directory
  | Child_credentials | Child_capabilities | Child_signals | Child_ready | Child_gate | Child_exec
  | Control_io | Signal_main | Wait_main | Close_handle | Duplicate_watch

type error =
  | Unsupported
  | Invalid_input of invalid_input
  | Syscall_failed of { stage : stage; error : Unix.error }
  | Child_rejected of { stage : stage; error : Unix.error }
  | Protocol_error | Not_ready | Already_decided | Control_lost | Closed | Exit_unavailable
  | Cleanup_failed of { primary : error option; error : Unix.error }

let stage_name = function
  | Allocate -> "allocate" | Duplicate_stdio -> "duplicate stdio"
  | Open_directory -> "open directory" | Create_gate -> "create gate"
  | Mask_signals -> "mask signals" | Create_child -> "create child"
  | Child_descriptors -> "child descriptors" | Child_close_descriptors -> "child close descriptors"
  | Child_session -> "child session" | Child_directory -> "child directory"
  | Child_credentials -> "child credentials" | Child_capabilities -> "child capabilities"
  | Child_signals -> "child signals" | Child_ready -> "child ready" | Child_gate -> "child gate"
  | Child_exec -> "child exec" | Control_io -> "control IO" | Signal_main -> "signal main"
  | Wait_main -> "wait main" | Close_handle -> "close handle" | Duplicate_watch -> "duplicate watch"

let invalid_name = function
  | Executable -> "executable" | Arguments -> "arguments" | Environment -> "environment"
  | Directory -> "directory" | Payload_uid -> "payload UID" | Payload_gid -> "payload GID"
  | Shared_uid -> "shared UID" | Controller_not_root -> "controller is not root"

let rec error_to_string = function
  | Unsupported -> "original-process gate unsupported"
  | Invalid_input input -> "invalid " ^ invalid_name input
  | Syscall_failed {stage; error} -> stage_name stage ^ ": " ^ Unix.error_message error
  | Child_rejected {stage; error} -> "child rejected " ^ stage_name stage ^ ": " ^ Unix.error_message error
  | Protocol_error -> "invalid private gate protocol"
  | Not_ready -> "child is not ready" | Already_decided -> "gate already decided"
  | Control_lost -> "private gate closed" | Closed -> "process handle closed"
  | Exit_unavailable -> "original child wait authority unavailable"
  | Cleanup_failed {primary; error} ->
      let prefix = match primary with None -> "" | Some e -> error_to_string e ^ "; " in
      prefix ^ "cleanup: " ^ Unix.error_message error

exception Release_failed of error

type decision = Undecided | Activate_requested | Abort_requested
type preparation = Pending | Ready | Rejected of { stage : stage; error : Unix.error }
type control = Open | Ended
type boundary = { preparation : preparation; decision : decision; control : control }
type exit_status = Exited of int | Signaled of int
type exit_observation = { status : exit_status; boundary : boundary }
type termination = Terminate | Kill
type signal_result = Requested | Already_exited

type raw
external linux_build : unit -> bool = "masc_endpoint_gate_linux"
external spawn_raw :
  string * string array * string array * string * int * int *
  (Unix.file_descr * Unix.file_descr * Unix.file_descr) -> int * Unix.error option * raw
  = "masc_endpoint_gate_spawn"
external control_raw : raw -> int * int * Unix.error option = "masc_endpoint_gate_control"
external decide_raw : raw -> bool -> int * Unix.error option = "masc_endpoint_gate_decide"
external signal_raw : raw -> bool -> Unix.error option = "masc_endpoint_gate_signal"
external wait_raw : raw -> int * int * Unix.error option = "masc_endpoint_gate_wait"
external watch_raw : raw -> bool -> Unix.file_descr * Unix.error option = "masc_endpoint_gate_watch"
external close_raw : raw -> Unix.error option = "masc_endpoint_gate_close"

type t = {
  raw : raw;
  mutex : Mutex.t;
  mutable boundary : boundary;
  mutable control_error : error option;
  mutable terminal : (exit_observation, error) result option;
  mutable closed : bool;
  closed_signal : unit Eio.Promise.t;
  closed_resolver : unit Eio.Promise.u;
  release_mutex : Eio.Mutex.t;
  mutable release_result : (exit_observation, error) result option;
}

let ( let* ) = Result.bind
let locked t fn = Mutex.lock t.mutex; Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) fn

let stage_of_code = function
  | 1 -> Some Allocate | 2 -> Some Duplicate_stdio | 3 -> Some Open_directory
  | 4 -> Some Create_gate | 5 -> Some Mask_signals | 6 -> Some Create_child
  | 7 -> Some Child_descriptors | 8 -> Some Child_close_descriptors | 9 -> Some Child_session
  | 10 -> Some Child_directory | 11 -> Some Child_credentials | 12 -> Some Child_capabilities
  | 13 -> Some Child_signals | 14 -> Some Child_ready | 15 -> Some Child_gate | 16 -> Some Child_exec
  | 17 -> Some Control_io | 18 -> Some Signal_main | 19 -> Some Wait_main
  | 20 -> Some Close_handle | 21 -> Some Duplicate_watch | _ -> None

(* All calls while locked are nonblocking. In particular, no fiber wait or
   blocking system-thread submission happens while holding this mutex. *)
let rec drain_control t =
  match t.control_error with
  | Some error -> Error error
  | None ->
      match t.boundary.control with
      | Ended -> Ok ()
      | Open ->
          let kind, code, error = control_raw t.raw in
          let protocol_error () = t.control_error <- Some Protocol_error; Error Protocol_error in
          match kind, code, error with
          | 0, 0, None -> Ok ()
          | 1, 0, None ->
              (match t.boundary.preparation with
               | Pending -> t.boundary <- {t.boundary with preparation=Ready}; drain_control t
               | Ready | Rejected _ -> protocol_error ())
          | 2, _, Some error ->
              (match stage_of_code code, t.boundary.preparation with
               | Some stage, (Pending | Ready) ->
                   t.boundary <- {t.boundary with preparation=Rejected {stage; error}};
                   drain_control t
               | None, (Pending | Ready | Rejected _) | Some _, Rejected _ -> protocol_error ())
          | 3, 0, None -> t.boundary <- {t.boundary with control=Ended}; Ok ()
          | 4, _, Some error ->
              let error = Syscall_failed {stage=Control_io; error} in
              t.control_error <- Some error; Error error
          | _ -> protocol_error ()

let observe_boundary t = locked t (fun () ->
    if t.closed then Error Closed else let* () = drain_control t in Ok t.boundary)

let wait_readable t ~exit =
  let watcher = locked t (fun () ->
      if t.closed then Error Closed else
        let fd, error = watch_raw t.raw exit in
        match error with
        | None -> Ok fd
        | Some error -> Error (Syscall_failed {stage=Duplicate_watch; error})) in
  let* fd = watcher in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      Eio.Fiber.first
        (fun () -> Eio_unix.await_readable fd)
        (fun () -> Eio.Promise.await t.closed_signal);
      Ok ())

let rec await_ready t =
  let* boundary = observe_boundary t in
  match boundary.preparation with
  | Ready -> Ok ()
  | Rejected {stage; error} -> Error (Child_rejected {stage; error})
  | Pending ->
      match boundary.control with
      | Ended -> Error Control_lost
      | Open -> let* () = wait_readable t ~exit:false in await_ready t

let decide t activation = locked t (fun () ->
    if t.closed then Error Closed else
      (* A recorded decision remains authoritative after the peer exits. *)
      match t.boundary.decision with
      | Activate_requested | Abort_requested -> Error Already_decided
      | Undecided ->
          let* () = drain_control t in
          match t.boundary.control, t.boundary.preparation with
          | Ended, (Pending | Ready | Rejected _) -> Error Control_lost
          | Open, Rejected {stage; error} -> Error (Child_rejected {stage; error})
          | Open, Pending when activation -> Error Not_ready
          | Open, (Pending | Ready) ->
              let code, error = decide_raw t.raw activation in
              match code, error with
              | 0, None ->
                  t.boundary <- {t.boundary with decision=
                      (if activation then Activate_requested else Abort_requested)};
                  Ok ()
              | _, Some error -> Error (Syscall_failed {stage=Control_io; error})
              | _, None -> Error Protocol_error)
let activate t = decide t true
let abort t = decide t false

let signal_main t termination = locked t (fun () ->
    match t.terminal with
    | Some (Ok _) -> Ok Already_exited
    | None | Some (Error _) ->
        if t.closed then Error Closed else
          let kill = match termination with Terminate -> false | Kill -> true in
          match signal_raw t.raw kill with
          | None -> Ok Requested
          | Some error ->
              if error = Unix.ESRCH then Ok Already_exited
              else Error (Syscall_failed {stage=Signal_main; error}))

let poll_exit t = locked t (fun () ->
    match t.terminal with
    | Some (Ok exit) -> Ok (Some exit)
    | Some (Error error) -> Error error
    | None ->
        if t.closed then Error Closed else
          let kind, status, error = wait_raw t.raw in
          match kind, error with
          | 0, None -> Ok None
          | (1 | 2), None ->
              let result =
                let* () = drain_control t in
                let status = if kind = 1 then Exited status else Signaled status in
                Ok {status; boundary=t.boundary} in
              t.terminal <- Some result;
              Result.map Option.some result
          | _, Some error ->
              let error = if error = Unix.ECHILD then Exit_unavailable
                else Syscall_failed {stage=Wait_main; error} in
              t.terminal <- Some (Error error); Error error
          | _, None -> t.terminal <- Some (Error Protocol_error); Error Protocol_error)

let rec await_exit t =
  let* exit = poll_exit t in
  match exit with
  | Some exit -> Ok exit
  | None ->
      (* A release can close the handle between observation and watch creation.
         Its cached settlement is read again rather than losing that result. *)
      match wait_readable t ~exit:true with
      | Ok () -> Eio.Fiber.yield (); await_exit t
      | Error error ->
          if error = Closed then
            (match poll_exit t with
             | Ok (Some exit) -> Ok exit
             | Ok None -> Error Closed
             | Error error -> Error error)
          else Error error

let close_settled t primary =
  let error, notify = locked t (fun () ->
      if t.closed then None, false else begin
        let error = close_raw t.raw in
        t.closed <- true;
        error, true
      end) in
  if notify then Eio.Promise.resolve t.closed_resolver ();
  match error with
  | None -> primary
  | Some error ->
      let primary = match primary with Ok _ -> None | Error error -> Some error in
      Error (Cleanup_failed {primary; error})

let release t = Eio.Cancel.protect (fun () ->
    Eio.Mutex.use_rw ~protect:true t.release_mutex (fun () ->
        match t.release_result with
        | Some result -> result
        | None ->
            let* _ = signal_main t Kill in
            let result = close_settled t (await_exit t) in
            t.release_result <- Some result;
            result))

let valid_string s = not (String.contains s '\000')
let absolute s = String.length s > 0 && s.[0] = '/' && valid_string s

let create ~sw ~executable ~argv ~env ~cwd ~payload_uid ~payload_gid ~stdin ~stdout ~stderr =
  let invalid =
    if not (absolute executable) then Some Executable
    else if Array.length argv = 0 || not (Array.for_all valid_string argv) then Some Arguments
    else if not (Array.for_all valid_string env) then Some Environment
    else if not (absolute cwd) then Some Directory
    else if payload_uid <= 0 then Some Payload_uid
    else if payload_gid < 0 then Some Payload_gid
    else if payload_uid = Unix.geteuid () then Some Shared_uid
    else if Unix.geteuid () <> 0 then Some Controller_not_root
    else None in
  if not (linux_build ()) then Error Unsupported else
  match invalid with
  | Some input -> Error (Invalid_input input)
  | None ->
      begin
        Eio.Switch.check sw;
        Eio.Cancel.protect (fun () ->
            let code, error, raw = Eio_unix.run_in_systhread (fun () ->
                spawn_raw (executable, argv, env, cwd, payload_uid, payload_gid, (stdin, stdout, stderr))) in
            match error with
            | Some error ->
                if error = Unix.ENOSYS then Error Unsupported else
                  (match stage_of_code code with
                   | None -> Error Protocol_error
                   | Some stage -> Error (Syscall_failed {stage; error}))
            | None ->
                let closed_signal, closed_resolver = Eio.Promise.create () in
                let t = {raw; mutex=Mutex.create ();
                         boundary={preparation=Pending; decision=Undecided; control=Open};
                         control_error=None; terminal=None; closed=false; closed_signal; closed_resolver;
                         release_mutex=Eio.Mutex.create (); release_result=None} in
                (* If sw finished concurrently, on_release runs cleanup immediately
                   before raising. In either case the child has an owner. *)
                Eio.Switch.on_release sw (fun () ->
                    match release t with Ok _ -> () | Error error -> raise (Release_failed error));
                Ok t)
      end

module For_testing = struct let linux_build = linux_build () end
