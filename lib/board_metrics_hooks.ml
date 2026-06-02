(** Board-owned metric hooks.

    Board core modules call this neutral hook surface instead of reaching into
    Prometheus directly. The composition layer installs the concrete observer. *)

type observer = {
  observe_persist_lock_acquire_sec : float -> unit;
  observe_persist_lock_held_sec : float -> unit;
  inc_dispatch_flusher_start_outcome : outcome:string -> unit;
  inc_vote_fixture_detected : count:int -> unit;
  inc_persistence_read_drop : surface:string -> reason:string -> unit;
  inc_legacy_migrate_post_kind : author:string -> automation_label:string -> unit;
}

let noop_observer = {
  observe_persist_lock_acquire_sec = (fun _ -> ());
  observe_persist_lock_held_sec = (fun _ -> ());
  inc_dispatch_flusher_start_outcome = (fun ~outcome:_ -> ());
  inc_vote_fixture_detected = (fun ~count:_ -> ());
  inc_persistence_read_drop = (fun ~surface:_ ~reason:_ -> ());
  inc_legacy_migrate_post_kind =
    (fun ~author:_ ~automation_label:_ -> ());
}

let observer = Atomic.make noop_observer

let set_observer hooks = Atomic.set observer hooks
let reset_for_test () = Atomic.set observer noop_observer

let observe_persist_lock_acquire_sec seconds =
  (Atomic.get observer).observe_persist_lock_acquire_sec seconds

let observe_persist_lock_held_sec seconds =
  (Atomic.get observer).observe_persist_lock_held_sec seconds

let inc_dispatch_flusher_start_outcome ~outcome =
  (Atomic.get observer).inc_dispatch_flusher_start_outcome ~outcome

let inc_vote_fixture_detected ~count =
  (Atomic.get observer).inc_vote_fixture_detected ~count

let inc_persistence_read_drop ~surface ~reason =
  (Atomic.get observer).inc_persistence_read_drop ~surface ~reason

let inc_legacy_migrate_post_kind ~author ~automation_label =
  (Atomic.get observer).inc_legacy_migrate_post_kind ~author ~automation_label
