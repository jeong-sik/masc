type protection =
  | Controller_not_root | Invalid_parent | Invalid_name | Unsafe_ancestor
  | Not_cgroup_v2 | Group_identity_changed | Group_not_private

type stage =
  | Allocate | Open_parent | Create_group | Open_group | Open_events
  | Create_watch | Read_events | Kill_tree | Remove_group | Close_group | Close_watch

type error =
  | Unsupported | Refused of protection | Syscall_failed of { stage : stage; error : Unix.error }
  | Protocol_error | Malformed_events | Retiring | Closed
  | Cleanup_failed of { primary : error option; error : Unix.error }

let protection_name = function
  | Controller_not_root -> "controller is not root"
  | Invalid_parent -> "invalid parent" | Invalid_name -> "invalid leaf name"
  | Unsafe_ancestor -> "unprotected ancestor" | Not_cgroup_v2 -> "not cgroup v2"
  | Group_identity_changed -> "original group identity changed"
  | Group_not_private -> "original group is not private"
let stage_name = function
  | Allocate -> "allocate" | Open_parent -> "open parent" | Create_group -> "create group"
  | Open_group -> "open group" | Open_events -> "open events" | Create_watch -> "create watch"
  | Read_events -> "read events" | Kill_tree -> "kill tree" | Remove_group -> "remove group"
  | Close_group -> "close group" | Close_watch -> "close watch"
let rec error_to_string = function
  | Unsupported -> "kernel process tree unsupported"
  | Refused reason -> protection_name reason
  | Syscall_failed {stage; error} -> stage_name stage ^ ": " ^ Unix.error_message error
  | Protocol_error -> "invalid native group observation"
  | Malformed_events -> "invalid kernel group events"
  | Retiring -> "group admission retired" | Closed -> "group handles closed"
  | Cleanup_failed {primary; error} ->
      let prefix=match primary with None -> "" | Some error -> error_to_string error ^ "; " in
      prefix ^ "cleanup: " ^ Unix.error_message error
exception Release_failed of error

type raw
external linux_build : unit -> bool = "masc_endpoint_gate_linux"
external create_raw : string -> string -> int * Unix.error option * int * Unix.error option * raw
  = "masc_endpoint_group_create"
external read_raw : raw -> string * Unix.error option * int = "masc_endpoint_group_read"
external kill_raw : raw -> int * Unix.error option * int = "masc_endpoint_group_kill"
external remove_raw : raw -> int * Unix.error option * int = "masc_endpoint_group_remove"
external directory_raw : raw -> Unix.file_descr = "masc_endpoint_group_directory"
external close_raw : raw -> Unix.error option = "masc_endpoint_group_close"
type waiter
external create_waiter_raw : raw -> int * Unix.error option * int * Unix.error option * waiter = "masc_endpoint_group_waiter_create"
external read_waiter_raw : raw -> waiter -> string * Unix.error option * int = "masc_endpoint_group_waiter_read"
external waiter_fd_raw : waiter -> Unix.file_descr = "masc_endpoint_group_waiter_fd"
external close_waiter_raw : waiter -> Unix.error option = "masc_endpoint_group_waiter_close"

type lifecycle = Admitting | Admission_retired | Handles_closed of (unit, error) result
type t = {
  raw : raw; mutex : Eio.Mutex.t; release_mutex : Eio.Mutex.t;
  mutable lifecycle : lifecycle;
  closed_signal : unit Eio.Promise.t; closed_resolver : unit Eio.Promise.u;
}
let ( let* ) = Result.bind

(* Every exception leaves the explicit lifecycle consistent. A cancelled wait
   or failed spawn must not poison the mutex and prevent owner cleanup. *)
let serialized t fn =
  Eio.Mutex.lock t.mutex;
  Eio.Cancel.protect (fun () ->
      Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) fn)

let stage_of_code = function
  | 1 -> Some Allocate | 2 -> Some Open_parent | 3 -> Some Create_group
  | 4 -> Some Open_group | 5 -> Some Open_events | 6 -> Some Create_watch
  | 7 -> Some Read_events | 8 -> Some Kill_tree | 9 -> Some Remove_group
  | 10 -> Some Close_group | 11 -> Some Close_watch | _ -> None
let protection_of_code = function
  | 1 -> Some Controller_not_root | 2 -> Some Invalid_parent | 3 -> Some Invalid_name
  | 4 -> Some Unsafe_ancestor | 5 -> Some Not_cgroup_v2
  | 6 -> Some Group_identity_changed | 7 -> Some Group_not_private | _ -> None

let native_status (code, error, protection) =
  if protection=0 then
    match error with
    | None -> Ok ()
    | Some error ->
        (match stage_of_code code with
         | Some stage -> Error (Syscall_failed {stage; error}) | None -> Error Protocol_error)
  else
    match protection_of_code protection, error with
    | Some reason, None -> Error (Refused reason)
    | None, (None | Some _) | Some _, Some _ -> Error Protocol_error

(* This is a Linux kernel ABI decoder, not payload-text control. Missing,
   duplicate and unknown keys are refused; no empty/parse-error fallback. *)
let decode_events bytes =
  let bit = function "0" -> Some false | "1" -> Some true | _ -> None in
  let rec loop population frozen = function
    | [] | [""] ->
        (match population, frozen with
         | Some population, Some _ -> Ok population
         | None, (None | Some _) | Some _, None -> Error Malformed_events)
    | line :: rest ->
        match String.split_on_char ' ' line with
        | ["populated"; value] ->
            (match population, bit value with
             | None, Some value -> loop (Some value) frozen rest
             | Some _, (None | Some _) | None, None -> Error Malformed_events)
        | ["frozen"; value] ->
            (match frozen, bit value with
             | None, Some value -> loop population (Some value) rest
             | Some _, (None | Some _) | None, None -> Error Malformed_events)
        | _ -> Error Malformed_events in
  loop None None (String.split_on_char '\n' bytes)

let populated_with read t = serialized t (fun () ->
    match t.lifecycle with
    | Handles_closed (Ok ()) -> Ok false
    | Handles_closed (Error error) -> Error error
    | Admitting | Admission_retired ->
        let bytes, error, protection = Eio_unix.run_in_systhread (fun () -> read t.raw) in
        let* () = native_status (7, error, protection) in decode_events bytes)

let populated t = populated_with read_raw t

let await_empty_with_hook ~after_populated t = Eio.Switch.run (fun sw ->
    let* waiter = serialized t (fun () ->
        match t.lifecycle with
        | Handles_closed result -> Result.map (fun () -> None) result
        | Admitting | Admission_retired ->
            let code, error, protection, cleanup, waiter =
              Eio_unix.run_in_systhread (fun () -> create_waiter_raw t.raw) in
            let status = native_status (code,error,protection) in
            let* () = match cleanup with
              | None -> status
              | Some error ->
                  let primary=match status with Ok () -> None | Error error -> Some error in
                  Error (Cleanup_failed {primary;error}) in
            (* serialized protects acquisition through registration. The local
               switch drains wait fibers before closing these private fds. *)
            Eio.Switch.on_release sw (fun () ->
                match close_waiter_raw waiter with
                | None -> ()
                | Some error -> raise (Release_failed (Syscall_failed {stage=Close_watch;error})));
            Ok (Some waiter)) in
    match waiter with
    | None -> Ok ()
    | Some waiter ->
        let rec loop () =
          let* has_processes = populated_with (fun raw -> read_waiter_raw raw waiter) t in
          after_populated has_processes;
          if not has_processes then Ok () else begin
            Eio.Fiber.first
              (fun () -> Eio_unix.await_readable (waiter_fd_raw waiter))
              (fun () -> Eio.Promise.await t.closed_signal);
            Eio.Fiber.yield ();
            loop ()
          end in
        loop ())

let await_empty t = await_empty_with_hook ~after_populated:(fun _ -> ()) t

let kill_tree t = Eio.Cancel.protect (fun () -> serialized t (fun () ->
    match t.lifecycle with
    | Handles_closed result -> result
    | Admitting | Admission_retired ->
        t.lifecycle <- Admission_retired;
        Eio_unix.run_in_systhread (fun () -> kill_raw t.raw) |> native_status))

let release t = Eio.Cancel.protect (fun () ->
    Eio.Mutex.use_ro t.release_mutex (fun () ->
        let* () = kill_tree t in
        let* () = await_empty t in
        let result, notify = serialized t (fun () ->
            match t.lifecycle with
            | Handles_closed result -> Ok (result, false)
            | Admitting -> Error Protocol_error
            | Admission_retired ->
                let* () = Eio_unix.run_in_systhread (fun () -> remove_raw t.raw) |> native_status in
                let result = match close_raw t.raw with
                  | None -> Ok ()
                  | Some error -> Error (Cleanup_failed {primary=None; error}) in
                t.lifecycle <- Handles_closed result;
                Ok (result, true)) |> function
            | Ok pair -> pair | Error error -> Error error, false in
        if notify then Eio.Promise.resolve t.closed_resolver ();
        result))

let with_spawn t fn = serialized t (fun () ->
    match t.lifecycle with
    | Admission_retired -> Error Retiring
    | Handles_closed _ -> Error Closed
    | Admitting ->
        (* Revalidate through the original native handles before exposing the
           borrowed directory to this library's bounded clone3 callback. *)
        let bytes, error, protection = Eio_unix.run_in_systhread (fun () -> read_raw t.raw) in
        let* () = native_status (7,error,protection) in
        let* _ = decode_events bytes in
        Ok (fn (directory_raw t.raw)))

let create ~sw ~parent_path ~name =
  let invalid =
    if String.length parent_path=0 || parent_path.[0]<>'/' || String.contains parent_path '\000'
    then Some Invalid_parent
    else if name="" || name="." || name=".." || String.contains name '/' || String.contains name '\000'
    then Some Invalid_name
    else if Unix.geteuid ()<>0 then Some Controller_not_root
    else None in
  if not (linux_build ()) then Error Unsupported else
    match invalid with
    | Some reason -> Error (Refused reason)
    | None ->
        Eio.Switch.check sw;
        Eio.Cancel.protect (fun () ->
            let code, error, protection, cleanup, raw =
              Eio_unix.run_in_systhread (fun () -> create_raw parent_path name) in
            let status =
              if error=Some Unix.ENOSYS && protection=0 then Error Unsupported
              else native_status (code,error,protection) in
            let* () = match cleanup with
              | None -> status
              | Some error ->
                  let primary=match status with Ok () -> None | Error error -> Some error in
                  Error (Cleanup_failed {primary; error}) in
            let closed_signal, closed_resolver = Eio.Promise.create () in
            let t={raw; mutex=Eio.Mutex.create (); release_mutex=Eio.Mutex.create ();
                   lifecycle=Admitting; closed_signal; closed_resolver} in
            Eio.Switch.on_release sw (fun () ->
                match release t with Ok () -> () | Error error -> raise (Release_failed error));
            Ok t)

module For_testing = struct
  let linux_build = linux_build ()
  let await_empty = await_empty_with_hook
end
