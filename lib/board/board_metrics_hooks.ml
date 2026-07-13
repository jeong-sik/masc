(** Board-owned metric hooks.

    Board core modules call this neutral hook surface instead of reaching into
    Otel_metric_store directly. The composition layer installs the concrete observer.

    Label dimensions are typed closed sums so the compiler checks every label
    value at each call site. The variant -> Otel_metric_store label string mapping
    lives only in the adapter (board_metric_hooks_adapter.ml). *)

(** Persistence surface that recorded a read drop. Single value today; the
    sum keeps the dimension typed and adding a surface a compile obligation.
    This is a board-persistence-row surface, unrelated to the deleted
    Tool-layer [surface] type (#19854). *)
type board_persist_surface = Board_post_meta_json

(** Outcome of an attempt to start the board dispatch flusher actor. *)
type flusher_outcome =
  | Switch_finished  (** Switch was already finished when startup ran. *)
  | Cas_exhausted    (** CAS contention exhausted the retry budget. *)

type observer = {
  observe_persist_lock_acquire_sec : float -> unit;
  observe_persist_lock_held_sec : float -> unit;
  inc_dispatch_flusher_start_outcome : outcome:flusher_outcome -> unit;
  inc_persistence_read_drop :
    surface:board_persist_surface -> reason:Read_drop_reason.t -> unit;
}

let noop_observer = {
  observe_persist_lock_acquire_sec = (fun _ -> ());
  observe_persist_lock_held_sec = (fun _ -> ());
  inc_dispatch_flusher_start_outcome = (fun ~outcome:_ -> ());
  inc_persistence_read_drop = (fun ~surface:_ ~reason:_ -> ());
}

let observer = Atomic.make noop_observer

let set_observer hooks = Atomic.set observer hooks

let observe_persist_lock_acquire_sec seconds =
  (Atomic.get observer).observe_persist_lock_acquire_sec seconds

let observe_persist_lock_held_sec seconds =
  (Atomic.get observer).observe_persist_lock_held_sec seconds

let inc_dispatch_flusher_start_outcome ~outcome =
  (Atomic.get observer).inc_dispatch_flusher_start_outcome ~outcome

let inc_persistence_read_drop ~surface ~reason =
  (Atomic.get observer).inc_persistence_read_drop ~surface ~reason
