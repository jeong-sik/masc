(** Shutdown — what the server's shutdown reads: its durations, the hard
    process deadline, the cleanup hook registry and the global shutdown flag.

    The SIGTERM/SIGINT path in [bin/main_eio.ml] runs the shutdown itself:
    it notifies SSE clients, runs the hooks through [Shutdown_hooks], flushes
    the Board and cancels the server. The process entrypoint owns the hard
    [force_timeout_s] watchdog outside the Eio switch.

    @since 2.102.0 *)

(** {1 Configuration} *)

type config = {
  notify_delay_s : float;   (** Time after the SSE notice before the hooks run *)
  cleanup_timeout_s : float;(** Max time for cleanup hooks *)
  force_timeout_s : float;  (** Total max time before force exit *)
}

let default_config = {
  notify_delay_s = 0.2;
  cleanup_timeout_s = 3.0;
  force_timeout_s = 10.0;
}

type config_field =
  | Notify_delay
  | Cleanup_timeout
  | Force_timeout

let config_field_env_name = function
  | Notify_delay -> "MASC_SHUTDOWN_NOTIFY_DELAY"
  | Cleanup_timeout -> "MASC_SHUTDOWN_CLEANUP_TIMEOUT"
  | Force_timeout -> "MASC_SHUTDOWN_FORCE_TIMEOUT"

type config_error =
  | Invalid_config_number of { field : config_field; raw_value : string }
  | Non_finite_config_duration of { field : config_field; value : float }
  | Negative_config_duration of { field : config_field; value : float }
  | Non_positive_config_duration of { field : config_field; value : float }

let config_error_to_string = function
  | Invalid_config_number { field; raw_value } ->
      Printf.sprintf "%s must be a number (received %S)"
        (config_field_env_name field) raw_value
  | Non_finite_config_duration { field; value } ->
      Printf.sprintf "%s must be finite (received %g)"
        (config_field_env_name field) value
  | Negative_config_duration { field; value } ->
      Printf.sprintf "%s must be non-negative (received %g)"
        (config_field_env_name field) value
  | Non_positive_config_duration { field; value } ->
      Printf.sprintf "%s must be greater than zero (received %g)"
        (config_field_env_name field) value

let config_from_env_result () =
  let get_duration field ~default ~positive =
    match Sys.getenv_opt (config_field_env_name field) with
    | None -> Ok default
    | Some raw_value ->
        (match float_of_string_opt raw_value with
         | None -> Error (Invalid_config_number { field; raw_value })
         | Some value when not (Float.is_finite value) ->
             Error (Non_finite_config_duration { field; value })
         | Some value when positive && value <= 0.0 ->
             Error (Non_positive_config_duration { field; value })
         | Some value when value < 0.0 ->
             Error (Negative_config_duration { field; value })
         | Some value -> Ok value)
  in
  let open Result.Syntax in
  let* notify_delay_s =
    get_duration Notify_delay ~default:default_config.notify_delay_s
      ~positive:false
  in
  let* cleanup_timeout_s =
    get_duration Cleanup_timeout ~default:default_config.cleanup_timeout_s
      ~positive:false
  in
  let* force_timeout_s =
    get_duration Force_timeout ~default:default_config.force_timeout_s
      ~positive:true
  in
  Ok { notify_delay_s; cleanup_timeout_s; force_timeout_s }

(** {1 Process deadline supervision} *)

type deadline_error =
  | Non_finite_deadline_timeout of float
  | Non_positive_deadline_timeout of float
  | Watchdog_thread_start_failed of string

let deadline_error_to_string = function
  | Non_finite_deadline_timeout value ->
      Printf.sprintf "deadline timeout must be finite (received %g)" value
  | Non_positive_deadline_timeout value ->
      Printf.sprintf
        "deadline timeout must be greater than zero (received %g)"
        value
  | Watchdog_thread_start_failed reason ->
      Printf.sprintf "deadline watchdog thread failed to start: %s" reason

type watchdog_state =
  | Armed
  | Disarmed_state
  | Fired

type watchdog = {
  state : watchdog_state Atomic.t;
  thread : Thread.t;
}

type disarm_result =
  | Disarmed
  | Already_disarmed
  | Already_fired

let process_deadline_exit_code = 124
let process_deadline_start_failure_exit_code = 125

let start_process_deadline_watchdog ~timeout_s =
  if not (Float.is_finite timeout_s) then
    Error (Non_finite_deadline_timeout timeout_s)
  else if timeout_s <= 0.0 then
    Error (Non_positive_deadline_timeout timeout_s)
  else
    let state = Atomic.make Armed in
    (match
       try
         Ok
           (Thread.create
              (fun () ->
                try
                  Thread.delay timeout_s;
                  if Atomic.compare_and_set state Armed Fired then (
                    (* The expiry is silent otherwise: the process dies by
                       [_exit] with no log, which is exactly the symptom this
                       watchdog exists to explain. [_exit] skips the log
                       sink, so say it on stderr the way the other [FATAL]
                       arms do. *)
                    Printf.eprintf
                      "[FATAL] process deadline %.1fs expired; exiting %d\n%!"
                      timeout_s process_deadline_exit_code;
                    Unix._exit process_deadline_exit_code)
                with _ ->  (* cancel-guard-ok: raw Thread.create body: Cancelled cannot arrive *)
                  if Atomic.compare_and_set state Armed Fired then
                    Unix._exit process_deadline_start_failure_exit_code)
              ())
       with exn -> Error (Watchdog_thread_start_failed (Printexc.to_string exn))  (* cancel-guard-ok: Thread.create failure, not an Eio context *)
     with
     | Ok thread -> Ok { state; thread }
     | Error _ as error -> error)

let start_process_deadline_watchdog_or_exit ~timeout_s =
  match start_process_deadline_watchdog ~timeout_s with
  | Ok watchdog -> watchdog
  | Error _ -> Unix._exit process_deadline_start_failure_exit_code

let rec disarm_deadline_watchdog watchdog =
  if Atomic.compare_and_set watchdog.state Armed Disarmed_state then
    Disarmed
  else
    match Atomic.get watchdog.state with
    | Disarmed_state -> Already_disarmed
    | Fired -> Already_fired
    | Armed ->
        (* A concurrent timeout can only move [Armed] to [Fired]. Retry so the
           caller never receives an observation that contradicts the CAS. *)
        disarm_deadline_watchdog watchdog

let await_deadline_watchdog watchdog = Thread.join watchdog.thread

(** {1 Hook Registry} *)

type hook = {
  name : string;
  priority : int;  (** Lower = runs first *)
  action : unit -> unit;
}

(** Global shutdown-started flag. The SIGTERM/SIGINT handler in
    [bin/main_eio.ml] sets it through [mark_shutting_down]. This flag is
    sticky: it is never cleared, so it indicates that shutdown has started,
    not that shutdown is currently in progress. In production the process
    exits shortly after shutdown, so the sticky semantics are safe. A test
    that sets it sees it stay [true] for the rest of its process. *)
let shutting_down_flag = Atomic.make false

let is_shutting_down_global () = Atomic.get shutting_down_flag

(* Async-signal-safe marker. [Atomic.set] is lock-free, so it can be invoked
   from an OCaml signal handler. Idempotent; later calls are no-ops once the
   sticky flag is [true]. [bin/main_eio.ml]'s signal handler calls it before
   the watcher fiber starts the shutdown, so a Keeper fiber cancelled by that
   shutdown reads [is_shutting_down_global] as [true] and the supervisor
   records a graceful drop rather than a crash. *)
let mark_shutting_down () = Atomic.set shutting_down_flag true

type signal =
  | Sigterm
  | Sigint

let signal_name = function
  | Sigterm -> "SIGTERM"
  | Sigint -> "SIGINT"

let hooks : hook list Atomic.t = Atomic.make []

let register ~name ?(priority = 50) action =
  let new_hook = { name; priority; action } in
  let rec loop () =
    let old = Atomic.get hooks in
    if not (Atomic.compare_and_set hooks old (new_hook :: old)) then loop ()
  in
  loop ()

let sorted_hooks () =
  let snapshot = Atomic.get hooks in
  List.sort (fun a b -> compare a.priority b.priority) snapshot

let run_registered_hooks () =
  let all_hooks = sorted_hooks () in
  let failed = ref 0 in
  List.iter
    (fun hook ->
      try
        hook.action ();
        Log.Server.debug "[Shutdown] hook '%s' completed" hook.name
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        incr failed;
        Log.Server.warn
          "[Shutdown] hook '%s' failed: %s"
          hook.name
          (Printexc.to_string exn))
    all_hooks;
  !failed

(** {1 Termination classification} *)

let rec is_benign_termination ~benign exn =
  benign exn
  ||
  match exn with
  | Eio.Exn.Multiple exns ->
    (* Failing the switch to end shutdown cancels in-flight fibers; Eio combines
       the switch's own [benign] exception with what those fibers raise into one
       [Multiple]. A shutdown whose every member is itself benign (recursively)
       is still a clean shutdown, not a crash. An empty list is not reachable
       from [Eio.Exn.combine] but is treated as non-benign to avoid asserting
       cleanliness with no evidence. *)
    (match exns with
     | [] -> false
     | _ :: _ ->
       List.for_all (fun (member, _bt) -> is_benign_termination ~benign member) exns)
  | Stdlib.Fun.Finally_raised inner ->
    (* A cancellable [Fun.protect ~finally] whose finalizer touches a
       cancellation point during shutdown raises [Cancelled], which OCaml wraps
       as [Finally_raised]. [Eio.Exn.combine] keeps this wrapper over a bare
       [Cancelled] (it discards bare [Cancelled] in favour of "something
       better"), so the observed shutdown [Multiple] carries the wrapper, not a
       bare [Cancelled]. Unwrap it and classify the finalizer's own exception. *)
    is_benign_termination ~benign inner
  | _ -> false
;;