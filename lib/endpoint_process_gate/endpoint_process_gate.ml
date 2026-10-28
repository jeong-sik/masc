module Group = Endpoint_process_group_internal

type invalid_input =
  | Executable | Arguments | Environment | Directory | Payload_uid | Payload_gid
  | Shared_uid | Controller_not_root

type stage =
  | Allocate | Duplicate_stdio | Open_directory | Create_gate | Mask_signals | Create_child
  | Child_descriptors | Child_close_descriptors | Child_session | Child_directory
  | Child_credentials | Child_capabilities | Child_signals | Child_ready | Child_gate | Child_exec
  | Control_io | Signal_main | Wait_main | Close_handle | Duplicate_watch | Duplicate_group

type error =
  | Unsupported
  | Group_error of Group.error
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
  | Duplicate_group -> "duplicate group"

let invalid_name = function
  | Executable -> "executable" | Arguments -> "arguments" | Environment -> "environment"
  | Directory -> "directory" | Payload_uid -> "payload UID" | Payload_gid -> "payload GID"
  | Shared_uid -> "shared UID" | Controller_not_root -> "controller is not root"

let rec error_to_string = function
  | Unsupported -> "original-process gate unsupported"
  | Group_error error -> "process group: " ^ Group.error_to_string error
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
type control_failure = Protocol_violation | Receive_failed of Unix.error
type control = Open | Ended | Failed of control_failure
type boundary = { preparation : preparation; decision : decision; control : control }
let control_failure_error = function
  | Protocol_violation -> Protocol_error
  | Receive_failed error -> Syscall_failed {stage=Control_io; error}
type exit_status = Exited of int | Signaled of int
type exit_observation = { status : exit_status; boundary : boundary }
type termination = Terminate | Kill
type signal_result = Requested | Already_exited

type raw
external linux_build : unit -> bool = "masc_endpoint_gate_linux"
external spawn_raw :
  string * string array * string array * string * int * int *
  (Unix.file_descr * Unix.file_descr * Unix.file_descr) * Unix.file_descr option -> int * Unix.error option * raw
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
  | 20 -> Some Close_handle | 21 -> Some Duplicate_watch | 22 -> Some Duplicate_group | _ -> None

(* All calls while locked are nonblocking. In particular, no fiber wait or
   blocking system-thread submission happens while holding this mutex.
   A channel failure becomes control=Failed, after which nothing is read. *)
let rec drain_control_with control t =
  match t.boundary.control with
  | Ended | Failed _ -> ()
  | Open ->
      let kind, code, error = control t.raw in
      let fail failure = t.boundary <- {t.boundary with control=Failed failure} in
      match kind, code, error with
      | 0, 0, None -> ()
      | 1, 0, None ->
          (match t.boundary.preparation with
           | Pending -> t.boundary <- {t.boundary with preparation=Ready}; drain_control_with control t
           | Ready | Rejected _ -> fail Protocol_violation)
      | 2, _, Some error ->
          (match stage_of_code code, t.boundary.preparation with
           | Some stage, (Pending | Ready) ->
               t.boundary <- {t.boundary with preparation=Rejected {stage; error}};
               drain_control_with control t
           | None, (Pending | Ready | Rejected _) | Some _, Rejected _ -> fail Protocol_violation)
      | 3, 0, None -> t.boundary <- {t.boundary with control=Ended}
      | 4, _, Some error -> fail (Receive_failed error)
      | _ -> fail Protocol_violation
let drain_control = drain_control_with control_raw

let observe_boundary t = locked t (fun () ->
    if t.closed then Error Closed else (drain_control t; Ok t.boundary))

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
  (* A failed channel is reported before any preparation it may have cut short. *)
  match boundary.control, boundary.preparation with
  | Failed failure, (Pending | Ready | Rejected _) -> Error (control_failure_error failure)
  | (Open | Ended), Ready -> Ok ()
  | (Open | Ended), Rejected {stage; error} -> Error (Child_rejected {stage; error})
  | Ended, Pending -> Error Control_lost
  | Open, Pending -> let* () = wait_readable t ~exit:false in await_ready t

let decide t activation = locked t (fun () ->
    if t.closed then Error Closed else
      (* A recorded decision remains authoritative after the peer exits. *)
      match t.boundary.decision with
      | Activate_requested | Abort_requested -> Error Already_decided
      | Undecided ->
          drain_control t;
          match t.boundary.control, t.boundary.preparation with
          | Failed failure, (Pending | Ready | Rejected _) -> Error (control_failure_error failure)
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

let signal_main_with signal t termination = locked t (fun () ->
    match t.terminal with
    | Some (Ok _) -> Ok Already_exited
    | None | Some (Error _) ->
        if t.closed then Error Closed else
          let kill = match termination with Terminate -> false | Kill -> true in
          match signal t.raw kill with
          | None -> Ok Requested
          | Some error ->
              if error = Unix.ESRCH then Ok Already_exited
              else Error (Syscall_failed {stage=Signal_main; error}))
let signal_main = signal_main_with signal_raw

let poll_exit_with control t = locked t (fun () ->
    match t.terminal with
    | Some (Ok exit) -> Ok (Some exit)
    | Some (Error error) -> Error error
    | None ->
        if t.closed then Error Closed else
          let kind, status, error = wait_raw t.raw in
          match kind, error with
          | 0, None -> Ok None
          | (1 | 2), None ->
              (* The reaped status cannot be read again. A control failure is
                 kept beside it as control=Failed and never replaces it. *)
              drain_control_with control t;
              let status = if kind = 1 then Exited status else Signaled status in
              let exit = {status; boundary=t.boundary} in
              t.terminal <- Some (Ok exit);
              Ok (Some exit)
          | _, Some error ->
              let error = if error = Unix.ECHILD then Exit_unavailable
                else Syscall_failed {stage=Wait_main; error} in
              t.terminal <- Some (Error error); Error error
          | _, None -> t.terminal <- Some (Error Protocol_error); Error Protocol_error)
let poll_exit = poll_exit_with control_raw

let rec await_exit_with control t =
  let* exit = poll_exit_with control t in
  match exit with
  | Some exit -> Ok exit
  | None ->
      (* A release can close the handle between observation and watch creation.
         Its cached settlement is read again rather than losing that result. *)
      match wait_readable t ~exit:true with
      | Ok () -> Eio.Fiber.yield (); await_exit_with control t
      | Error error ->
          if error = Closed then
            (match poll_exit_with control t with
             | Ok (Some exit) -> Ok exit
             | Ok None -> Error Closed
             | Error error -> Error error)
          else Error error
let await_exit = await_exit_with control_raw

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

let release_with signal t = Eio.Cancel.protect (fun () ->
    Eio.Mutex.use_rw ~protect:true t.release_mutex (fun () ->
        match t.release_result with
        | Some result -> result
        | None ->
            (* A failed signal still closes: an open handle would leave every
               closed_signal waiter blocked. Waiting for an exit the signal did
               not cause could block forever, so the signal failure is primary. *)
            let settled = match signal_main_with signal t Kill with
              | Ok (Requested | Already_exited) -> await_exit t
              | Error error -> Error error in
            let result = close_settled t settled in
            t.release_result <- Some result;
            result))
let release = release_with signal_raw

let valid_string s = not (String.contains s '\000')
let absolute s = String.length s > 0 && s.[0] = '/' && valid_string s

let create_captured ~before_spawn_in_worker ~group_fd ~sw ~executable ~argv ~env ~cwd ~payload_uid ~payload_gid ~stdin ~stdout ~stderr =
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
                before_spawn_in_worker ();
                spawn_raw (executable, argv, env, cwd, payload_uid, payload_gid, (stdin, stdout, stderr), group_fd)) in
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
                         terminal=None; closed=false; closed_signal; closed_resolver;
                         release_mutex=Eio.Mutex.create (); release_result=None} in
                (* If sw finished concurrently, on_release runs cleanup immediately
                   before raising. In either case the child has an owner. *)
                Eio.Switch.on_release sw (fun () ->
                    match release t with Ok _ -> () | Error error -> raise (Release_failed error));
                Ok t)
      end

let create_with_hook ~before_spawn_in_worker ~sw ~executable ~argv ~env ~cwd ~payload_uid ~payload_gid ~stdin ~stdout ~stderr =
  (* Capture before validation and before any worker/group wait can yield to
     callers that still own mutable source arrays. Strings are immutable. *)
  let argv = Array.copy argv and env = Array.copy env in
  create_captured ~before_spawn_in_worker ~group_fd:None ~sw ~executable ~argv ~env ~cwd
    ~payload_uid ~payload_gid ~stdin ~stdout ~stderr

let create = create_with_hook ~before_spawn_in_worker:(fun () -> ())

let create_in_group ~group ~sw ~executable ~argv ~env ~cwd ~payload_uid ~payload_gid ~stdin ~stdout ~stderr =
  let argv = Array.copy argv and env = Array.copy env in
  Eio.Switch.check sw;
  match Group.with_spawn group (fun group_fd ->
      create_captured ~before_spawn_in_worker:(fun () -> ()) ~group_fd:(Some group_fd)
        ~sw ~executable ~argv ~env ~cwd ~payload_uid ~payload_gid ~stdin ~stdout ~stderr) with
  | Ok result -> result
  | Error error -> Error (Group_error error)

module For_testing = struct
  let await_group_empty = Group.For_testing.await_empty
  let linux_build = linux_build ()
  let create = create_with_hook
  let release_with_signal_failure error = release_with (fun _ _ -> Some error)
  (* Kind 4 is the stub's receive-failure reading, matched in drain_control. *)
  let await_exit_with_control_failure error = await_exit_with (fun _ -> 4, 0, Some error)
end
