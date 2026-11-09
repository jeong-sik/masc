(** Board-owned metric hooks.

    Board core modules call this neutral hook surface instead of reaching into
    Otel_metric_store directly. The composition layer installs the concrete observer. *)

type observer = {
  observe_persist_lock_acquire_sec : float -> unit;
  observe_persist_lock_held_sec : float -> unit;
  inc_dispatch_flusher_start_outcome : unit -> unit;
}

let noop_observer = {
  observe_persist_lock_acquire_sec = (fun _ -> ());
  observe_persist_lock_held_sec = (fun _ -> ());
  inc_dispatch_flusher_start_outcome = (fun () -> ());
}

let observer = Atomic.make noop_observer

let set_observer hooks = Atomic.set observer hooks

let observe_persist_lock_acquire_sec seconds =
  (Atomic.get observer).observe_persist_lock_acquire_sec seconds

let observe_persist_lock_held_sec seconds =
  (Atomic.get observer).observe_persist_lock_held_sec seconds

let inc_dispatch_flusher_start_outcome () =
  (Atomic.get observer).inc_dispatch_flusher_start_outcome ()
