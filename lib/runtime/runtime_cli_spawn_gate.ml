(* See .mli for the incident derivation of every bound. *)

let max_concurrent_cli_spawns = 8
let child_fd_ceiling = 16000
let max_slot_wait_s = 120.0
let child_fd_probe_timeout_s = 5.0

exception Slot_timeout of { waited_s : float; limit_s : float }

let slots = Eio.Semaphore.make max_concurrent_cli_spawns
let active = Atomic.make 0

(* Waiter set: wall-start per queued waiter, newest first. Guarded by a
   plain mutex: the critical sections never suspend, and domains run
   them truly in parallel. *)
let waiter_mutex = Mutex.create ()
let waiter_starts : float list ref = ref []

let with_waiter_mutex f =
  Mutex.lock waiter_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock waiter_mutex) f
;;

let track_waiter f =
  let start = Unix.gettimeofday () in
  with_waiter_mutex (fun () -> waiter_starts := start :: !waiter_starts);
  Fun.protect
    ~finally:(fun () ->
      with_waiter_mutex (fun () ->
        let rec remove_first = function
          | [] -> []
          | t :: rest ->
            if Float.equal t start then rest else t :: remove_first rest
        in
        waiter_starts := remove_first !waiter_starts))
    f
;;

let active_cli_spawns () = Atomic.get active

let waiting_cli_spawns () =
  with_waiter_mutex (fun () -> List.length !waiter_starts)
;;

let oldest_cli_spawn_wait_s () =
  let now = Unix.gettimeofday () in
  with_waiter_mutex (fun () ->
    match !waiter_starts with
    | [] -> None
    | starts -> Some (now -. List.fold_left Float.min Float.infinity starts))
;;

let with_cli_spawn_slot ~clock ?(wait_timeout_s = max_slot_wait_s) f =
  let started = Unix.gettimeofday () in
  let acquired =
    track_waiter (fun () ->
      Eio.Time.with_timeout clock wait_timeout_s (fun () ->
        Eio.Semaphore.acquire slots;
        Ok ()))
  in
  (match acquired with
   | Error `Timeout ->
     let waited = Unix.gettimeofday () -. started in
     raise (Slot_timeout { waited_s = waited; limit_s = wait_timeout_s })
   | Ok () ->
     (* Acquire returned: the slot is held. Release cannot suspend, so
        the finally arm is total. *)
     let waited = Unix.gettimeofday () -. started in
     if Float.compare waited 1.0 > 0
     then
       Log.Runtime_agent.debug
         "CLI spawn slot acquired after %.1fs (%d still waiting)"
         waited
         (waiting_cli_spawns ());
     Atomic.incr active;
     Fun.protect
       ~finally:(fun () ->
         Atomic.decr active;
         Eio.Semaphore.release slots)
       (fun () -> Fd_accountant.observe ~kind:Fd_accountant.Provider_cli f))
;;

type child_fds =
  | Fd_count of int
  | Fds_unobservable
  | Fds_pressured

(* Only the file-table errors mean pressure. Anything else — dead pid,
   hidden /proc entries, a missing lsof — is a benign miss. Boolean, not
   a match: [Unix.error] must never gain a silent adopter. *)
let error_signals_pressure code = code = Unix.EMFILE || code = Unix.ENFILE

(* Unix.opendir (not Sys.readdir) so the errno survives for the pressure
   call above. Unix.readdir, unlike Sys.readdir, reports "." and "..". *)
let count_proc_fds ~pid =
  if pid <= 0
  then Fds_unobservable
  else (
    match Unix.opendir (Printf.sprintf "/proc/%d/fd" pid) with
    | exception Unix.Unix_error (code, _, _) ->
      if error_signals_pressure code then Fds_pressured else Fds_unobservable
    | dir ->
      Fun.protect
        ~finally:(fun () ->
          (try Unix.closedir dir with
           | Unix.Unix_error _ -> ()))
        (fun () ->
          let count = ref 0 in
          (try
             while true do
               let name = Unix.readdir dir in
               if name <> "." && name <> ".." then incr count
             done
           with
           | End_of_file -> ());
          Fd_count !count))
;;

(* Default lsof table: COMMAND PID USER FD TYPE ... Data rows whose FD
   field starts with a digit (3u, 12r) are open files; cwd/txt/mem rows
   are the process image, not its descriptor table. Fields left of FD
   never shift — only the trailing NAME may hold spaces. *)
let count_lsof_lines output =
  let fd_field_is_numeric fields =
    match fields with
    | _command :: _pid :: _user :: fd :: _rest ->
      String.length fd > 0 && fd.[0] >= '0' && fd.[0] <= '9'
    | [] | [_] | [_; _] | [_; _; _] -> false
  in
  match String.split_on_char '\n' output with
  | [] | [_] -> 0
  | _header :: rest ->
    List.fold_left
      (fun count line ->
        let fields =
          String.split_on_char ' ' (String.trim line)
          |> List.filter (fun field -> field <> "")
        in
        if fd_field_is_numeric fields then count + 1 else count)
      0
      rest
;;

let lsof_child_fds ~mgr ~cwd ~pid =
  if pid <= 0
  then Fds_unobservable
  else (
    try
      let stderr_buf = Buffer.create 256 in
      let output =
        Eio.Process.parse_out
          mgr
          Eio.Buf_read.take_all
          ~cwd
          ~stderr:(Eio.Flow.buffer_sink stderr_buf)
          [ "lsof"; "-p"; string_of_int pid ]
      in
      Fd_count (count_lsof_lines output)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Unix.Unix_error (code, _, _)
    | Eio.Io (Eio.Exn.X (Eio_unix.Unix_error (code, _, _)), _)
      when error_signals_pressure code -> Fds_pressured
    | exn ->
      Llm_provider.Reserved_exn.reraise_if_reserved exn;
      Fds_unobservable)
;;

(* /proc first where it exists; lsof covers macOS AND the corners where
   /proc hides the child (hidepid) but the question is still answerable.
   A dead child misses on both backends without failing. *)
let sample_child_fds ~mgr ~cwd ~pid =
  match count_proc_fds ~pid with
  | Fd_count _ as sample -> sample
  | Fds_pressured as sample -> sample
  | Fds_unobservable -> lsof_child_fds ~mgr ~cwd ~pid
;;

let child_is_alive ~pid =
  if pid <= 0
  then false
  else (
    match Unix.kill pid 0 with
    | () -> true
    | exception Unix.Unix_error (code, _, _) -> code <> Unix.ESRCH)
;;

module For_testing = struct
  let count_proc_fds = count_proc_fds
  let count_lsof_lines = count_lsof_lines
  let error_signals_pressure = error_signals_pressure
end
