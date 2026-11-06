(** The request I/O hooks, the locks and the exceptions that stop a worker in
    [Keeper_msg_async].

    [request_ops] gathers the durable write and remove calls, the request id
    source, a hook that runs before an integrity projection and the cancel
    signal that the code persisting, settling and cancelling requests calls;
    [production_request_ops] is the real set. [with_store_transition_lock]
    runs a function under the lock of one request in one store.
    [with_keeper_submission_lock] and [with_keeper_persistence_lock] run a
    function inside the submission or persistence lane of one Keeper; an
    optional [wait_budget] bounds the wait and [Lane_admission_timeout] is
    raised when it runs out. The persistence lane counts waits, pending work
    and in-flight work: [persistence_lane_samples] lists those three metrics
    and this module registers it with [Otel_metrics] when it loads.
    [elapsed_seconds] measures the seconds since a monotonic start time.
    [CancelledByOperator] stops a worker an operator cancelled;
    [Worker_preempted] and [Worker_already_settled] stop a worker whose request
    vanished or was already settled before the worker started.
    [server_background_switch] returns the server root switch or says it is
    unavailable.
    [Keeper_msg_async] includes this module. *)
open Keeper_msg_async_types

type request_ops =
  { save_json_durable :
      ownership_root:string
      -> temp_dir:string
      -> string
      -> Yojson.Safe.t
      -> (unit, Keeper_fs.durable_write_error) result
  ; remove_file_durable :
      ownership_root:string
      -> string
      -> (unit, Keeper_fs.durable_remove_error) result
  ; generate_request_id : unit -> string
  ; before_integrity_projection : unit -> unit
  ; signal_cancel : Eio.Switch.t -> exn -> unit
  }

val production_request_ops : request_ops

val with_store_transition_lock :
  base_path:string -> request_id:string -> (unit -> 'a) -> 'a

val persistence_lane_samples : unit -> Otel_metrics.sample list

val elapsed_seconds : Mtime.t -> float

exception Lane_admission_timeout of string

val with_keeper_submission_lock :
  ?wait_budget:float ->
  base_path:string ->
  keeper_name:Keeper_id.Keeper_name.t -> (unit -> 'a) -> 'a

val with_keeper_persistence_lock :
  ?wait_budget:float ->
  base_path:string ->
  keeper_name:Keeper_id.Keeper_name.t -> (unit -> 'a) -> 'a

exception CancelledByOperator

exception Worker_preempted of string

exception Worker_already_settled of entry

val server_background_switch : unit -> (Eio.Switch.t, submit_error) result
