(** Provider-based LLM concurrency pool.

    Each (provider, model) pair gets its own [Eio.Semaphore] so that
    e.g. GLM concurrency does not block Claude slots and vice versa.
    [with_slot] blocks the calling fiber until a permit is available
    or the queue timeout expires.

    @since 2.96.0 *)

type provider_id = string
type model_id = string

type slot_key = {
  provider : provider_id;
  model : model_id;
}

(** Opaque pool handle.  Create once at startup, share across fibers. *)
type t

(** [create ~clock configs] builds a pool.
    Each element is [(slot_key, concurrency_limit, queue_timeout_sec)].
    Duplicate slot_keys are silently overwritten (last wins). *)
val create :
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  (slot_key * int * float) list ->
  t

(** [with_slot t key f] acquires a permit for [key], runs [f ()],
    releases the permit (even on exception), and returns [Ok result].

    Returns [Error msg] when:
    - [key] is not registered in the pool
    - The queue timeout expires before a permit is available

    Re-raises [Eio.Cancel.Cancelled] without wrapping. *)
val with_slot : t -> slot_key -> (unit -> 'a) -> ('a, string) result

(** Per-slot statistics: [(slot_key, in_use, capacity)]. *)
val stats : t -> (slot_key * int * int) list

(** [has_capacity t key] is [true] when at least one permit is free.
    Returns [false] for unknown keys. *)
val has_capacity : t -> slot_key -> bool

(** [slot_key_to_string key] returns ["provider:model"]. *)
val slot_key_to_string : slot_key -> string
