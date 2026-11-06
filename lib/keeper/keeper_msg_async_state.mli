(** The worker outcome, the canonical queued error and the process-local
    tables of [Keeper_msg_async].

    [worker_outcome] is what a background worker reports: it finished, it was
    interrupted, or it waits for original dependencies.
    [worker_waiting_for_dependencies] builds the waiting case and returns an
    error unless the result is deferred and names a dependency.
    [durable_queued_proof] holds a queued entry read from its durable record,
    and [canonical_queued_error] says why no such record can be used;
    [canonical_queued_error_to_string] renders it. The functions taken over
    from [Keeper_msg_async_record] keep their names here.
    [Request_key], [Store_transition_key] and [Keeper_lane_key] are the keys of
    the tables that follow: the pending entries, the active switches, the
    reserved request ids and the lock registries. [mu] is the one mutex that
    the code of [Keeper_msg_async] takes around changes to these tables.
    [Keeper_msg_async] includes this module. *)
open Keeper_types_profile
open Keeper_msg_async_types

type worker_outcome =
  | Worker_finished of tool_result
  | Worker_interrupted of {reason : string}
  | Worker_waiting of
      { dependencies : Keeper_composition_dependency.t list
      ; result : tool_result }

val worker_finished : tool_result -> worker_outcome

val worker_interrupted : reason:string -> worker_outcome

val worker_waiting_for_dependencies :
  dependencies:Keeper_composition_dependency.t list ->
  tool_result -> (worker_outcome, string) result

type durable_queued_proof = { queued_entry : entry }

type canonical_queued_error =
  | Canonical_queued_absent
  | Canonical_queued_unreadable of string
  | Canonical_queued_access_rejected of access_rejection
  | Canonical_queued_runtime_nonqueued of request_status
  | Canonical_queued_publication_ambiguous of request_status
  | Canonical_queued_runtime_conflict
  | Canonical_queued_not_queued of request_status
  | Canonical_queued_noncanonical_location of request_status

val worker_cancel_source_to_string :
  worker_cancel_source -> string

val same_entry_record : entry -> entry -> bool

val canonical_terminal_error_to_string : canonical_terminal_error -> string

val durable_terminal_entry : durable_terminal_proof -> entry

val persistence_target_to_string : persistence_target -> string

val status_to_string : request_status -> string

val access_rejection_to_json : access_rejection -> Yojson.Safe.t

val submit_error_to_json : submit_error -> Yojson.Safe.t

val submit_outcome_to_json : submit_outcome -> Yojson.Safe.t

val cancel_result_to_json : request_id:string -> cancel_result -> Yojson.Safe.t

val durable_queued_entry : durable_queued_proof -> entry

val canonical_queued_error_to_string : canonical_queued_error -> string

module Request_key :
  sig
    type t = {
      base_path : string;
      submitted_by : string;
      request_id : string;
    }
    val equal : t -> t -> bool
    val hash : t -> int
  end

module Request_table : Hashtbl.S with type key = Request_key.t

module Store_transition_key :
  sig
    type t = { base_path : string; request_id : string; }
    val equal : t -> t -> bool
    val hash : t -> int
  end

module Store_transition_table : Hashtbl.S with type key = Store_transition_key.t

module Keeper_lane_key :
  sig
    type t = { base_path : string; keeper_name : Keeper_id.Keeper_name.t; }
    val equal : t -> t -> bool
    val hash : t -> int
  end

module Keeper_lane_table : Hashtbl.S with type key = Keeper_lane_key.t

type store_transition_lock =
  { mutex : Eio.Mutex.t
  ; mutable users : int
  }

(** Per-Keeper lane gate, deliberately distinct from [store_transition_lock].
    The gate is an [Eio.Semaphore] with one token so admission can be bounded
    by a deadline: [Eio.Semaphore.acquire] is cancellation-safe (a cancelled
    waiter returns its token via the [Sem_state] handoff protocol) and resumes
    waiters FIFO. [Eio.Mutex.lock] offers no bounded wait at all, which is how
    a hung durable write used to leak the lane permanently and hang every
    later submit for that keeper (#25398). *)
type lane_gate =
  { sem : Eio.Semaphore.t
  ; mutable users : int
  }

val mu : Eio.Mutex.t

val pending : entry Request_table.t

val transition_locks : Eio.Mutex.t Request_table.t

val active_switches : Eio.Switch.t Request_table.t

val store_transition_locks : store_transition_lock Store_transition_table.t

val reserved_request_ids : unit Store_transition_table.t

val keeper_submission_locks : lane_gate Keeper_lane_table.t

val keeper_persistence_locks : lane_gate Keeper_lane_table.t
