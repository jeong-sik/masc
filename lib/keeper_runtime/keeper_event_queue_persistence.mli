(** Durable snapshot store for per-keeper Event Layer queues.

    This module lives in [masc.keeper_runtime] so queue persistence stays with
    the queue DTO/codec and does not grow the main keeper surface. *)

val load : base_path:string -> keeper_name:string -> Keeper_event_queue.t
(** Restore a keeper queue snapshot, returning [Keeper_event_queue.empty] when
    no snapshot exists or the snapshot cannot be parsed. [load] is synchronized
    by the canonical per-owner lock shared with pending/inflight writes, so
    callers cannot observe a split snapshot transition. *)

type snapshot_pair =
  { pending : Keeper_event_queue.t
  ; inflight : Keeper_event_queue.t
  }

type snapshot_read_error_kind =
  | Invalid_path
  | Read_failed
  | Parse_failed

type snapshot_read_error =
  { kind : snapshot_read_error_kind
  ; path : string option
  ; message : string
  }

type snapshot_pair_with_errors =
  { pending : Keeper_event_queue.t
  ; inflight : Keeper_event_queue.t
  ; read_errors : snapshot_read_error list
  }

type snapshot_discovery =
  { keeper_names : string list
  ; read_error : string option
  }

val snapshot_read_error_kind_to_string : snapshot_read_error_kind -> string

val discover_keeper_names_with_snapshots : base_path:string -> snapshot_discovery
(** Discover keeper names that have durable pending or in-flight queue snapshot
    files under the runtime keeper directory. Missing keeper roots are an empty
    discovery; unreadable roots or invalid snapshot-bearing keeper directories
    are surfaced in [read_error] so health callers do not silently report a false
    empty backlog. *)

val load_snapshot_pair : base_path:string -> keeper_name:string -> snapshot_pair
(** Restore the pending and in-flight snapshots as separate typed queues under
    the same lock used by {!load}. Use this for operator health surfaces that
    must distinguish queued work from leased work without parsing file paths
    independently. *)

val load_snapshot_pair_with_errors :
  base_path:string -> keeper_name:string -> snapshot_pair_with_errors
(** Like {!load_snapshot_pair}, but preserves read/parse/path failures for
    operator health surfaces. Queue replay semantics remain conservative:
    failed snapshots contribute [Keeper_event_queue.empty], while
    [read_errors] records the exact reason so full health cannot silently
    report a false empty backlog. *)

val persist :
  base_path:string -> keeper_name:string -> Keeper_event_queue.t -> unit
(** Atomically write the latest queue snapshot. Runtime fibers use a yielding
    per-owner Eio gate; non-Eio setup/test callers synchronize through the same
    owner's cross-context Stdlib mutex. Different keeper owners do not share an
    I/O lock.
    Persistence failures are logged and do not roll back the already-applied
    in-memory registry CAS update. *)

val update :
  base_path:string -> keeper_name:string -> (Keeper_event_queue.t -> Keeper_event_queue.t) -> unit
(** Load, transform, and atomically write the queue snapshot while holding the
    persistence write lock. Use this for pre-registry mutation paths that do not
    have a live registry CAS cell yet. *)

val update_result :
  ?after_commit:(unit -> unit)
  -> base_path:string
  -> keeper_name:string
  -> (Keeper_event_queue.t -> Keeper_event_queue.t)
  -> (unit, string) result
(** Result-returning form of {!update}. Critical delivery paths use this so a
    failed durable write cannot be reported as a committed wake.
    [after_commit] runs under the same write lock only after the snapshot is
    durable, allowing a live queue publication without a generation gap. *)

val update_checked_result :
  ?after_commit:(unit -> unit)
  -> base_path:string
  -> keeper_name:string
  -> (Keeper_event_queue.t -> (Keeper_event_queue.t, string) result)
  -> (unit, string) result
(** Checked transform form of {!update_result}. A transform error leaves the
    existing durable snapshot and live queue unchanged. *)

val persist_snapshot :
  base_path:string -> keeper_name:string -> (unit -> Keeper_event_queue.t) -> unit
(** Evaluate [snapshot] while holding the persistence write lock, then atomically
    write it. Use this after live registry CAS mutations so an older writer
    cannot overwrite a newer live queue snapshot after waiting on the file lock. *)

val record_inflight :
  base_path:string -> keeper_name:string -> Keeper_event_queue.stimulus list -> unit
(** Mark drained stimuli as in-flight before they are removed from the pending
    snapshot. [load] merges these rows back in front of pending rows, giving a
    restart at-least-once replay boundary until {!ack_inflight} acknowledges
    them. *)

val ack_inflight :
  base_path:string -> keeper_name:string -> Keeper_event_queue.stimulus list -> unit
(** Remove acknowledged stimuli from the in-flight lease after the heartbeat
    stimuli have been requeued into the pending snapshot. Genuine turn-complete
    acknowledgement uses {!ack_consumed} instead. *)

val ack_consumed :
  base_path:string
  -> keeper_name:string
  -> Keeper_event_queue.stimulus list
  -> (unit, string) result
(** Remove consumed stimuli from pending and in-flight snapshots under one
    persistence lock. Returns [Error _] when durable acknowledgement fails so
    the caller can avoid treating the stimuli as acknowledged. *)

val drop_by_post_id :
  base_path:string
  -> keeper_name:string
  -> post_id:string
  -> (Keeper_event_queue.stimulus list, string) result
(** Remove matching stimuli from pending and in-flight snapshots under one
    persistence lock, returning the exact removed stimuli for ledger
    acknowledgement. *)

val fleet_summary_json : now:float -> base_path:string -> Yojson.Safe.t
(** Diagnostic fleet summary of durable pending and in-flight queue snapshots.
    Each pending/in-flight pair is read under that keeper's owner lock; the
    fleet is not globally serialized. This is read-only and does not mutate or
    de-duplicate files. Parse/read failures are surfaced in the JSON instead of
    being collapsed to an empty queue, so health probes cannot report a false
    green while durable queue state is unreadable. *)
