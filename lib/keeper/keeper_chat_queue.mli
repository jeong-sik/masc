(** Durable per-Keeper chat receipt queue.

    Every accepted message receives a stable receipt before the first durable
    write.  The receipt then follows exactly one closed lifecycle:
    [Pending -> Inflight -> Delivered | Failed].  A process restart moves an
    unfinalized [Inflight] receipt back to [Pending] without changing its id.

    Queue delivery is at-least-once.  Same-source receipts may share one turn,
    but their identities are never merged: a lease and its terminal transition
    always carry every constituent receipt.

    @since 2.145.0 *)

type message_source =
  | Dashboard
  | Discord of { channel_id : string; user_id : string }
  | Slack of {
      channel_id : string;
      user_id : string;
      user_name : string;
      team_id : string option;
      thread_ts : string option;
    }

type transcript_context =
  { surface : Surface_ref.t
  ; conversation_id : string option
  ; external_message_id : string option
  ; speaker : Keeper_chat_store.speaker
  ; extra_mentions : Keeper_identity.Keeper_id.t list
  }

type transcript_ownership =
  | Queue_owned
  | Upstream_recorded
(** Durable user-row ownership. [Queue_owned] means the consumer atomically
    appends this receipt's user row with the turn terminal row.
    [Upstream_recorded] is only for explicitly reconciled legacy input whose
    user row is already durable. *)

type queued_message = {
  content : string;
  user_blocks : Keeper_multimodal_input.user_input_block list;
  attachments : Keeper_chat_store.attachment list;
  timestamp : float;
  source : message_source;
  transcript_context : transcript_context option;
  transcript_ownership : transcript_ownership;
}

module Receipt_id : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

type completion = {
  completed_at : float;
  outcome_ref : string option;
}

type failure_kind =
  | Turn_failed
  | Timed_out
  | No_visible_reply
  | Transcript_persist_failed
  | Connector_unavailable
  | Delivery_failed
  | Cancelled
  | Internal_error

val failure_kind_to_string : failure_kind -> string

type failure = {
  completed_at : float;
  kind : failure_kind;
  detail : string;
  outcome_ref : string option;
}

type receipt_state =
  | Pending
  | Inflight of { lease_id : string; started_at : float }
  | Delivered of completion
  | Failed of failure

type leased_message = {
  receipt_id : Receipt_id.t;
  message : queued_message;
}

type lease = {
  lease_id : string;
  items : leased_message list;
}

type finalization =
  | Mark_delivered of completion
  | Mark_failed of failure

type snapshot_load_error_kind =
  | Invalid_path
  | Read_failed
  | Parse_failed
  | Migration_failed
  | Recovery_failed

type snapshot_load_error = {
  kind : snapshot_load_error_kind;
  path : string option;
  message : string;
}

type mutation_error =
  | Persistence_not_configured
  | Snapshot_unavailable of snapshot_load_error
  | Invalid_input of string
  | Revision_exhausted
  | Persist_failed of string

val snapshot_load_error_kind_to_string : snapshot_load_error_kind -> string
val mutation_error_to_string : mutation_error -> string

type active_receipt = {
  receipt_id : Receipt_id.t;
  message : queued_message;
  state : receipt_state;
}

type receipt_view = {
  receipt_id : Receipt_id.t;
  state : receipt_state;
}

type receipt_lookup = {
  revision : int64;
  receipt : receipt_view option;
}

type diagnostic_snapshot = {
  revision : int64;
  pending : active_receipt list;
  inflight : active_receipt list;
  terminal : receipt_view list;
  load_errors : snapshot_load_error list;
}

type enqueue_receipt = {
  receipt_id : Receipt_id.t;
  revision : int64;
  pending_count : int;
  inflight_count : int;
}

type configure_report = {
  restored_keeper_count : int;
  migrated_keeper_count : int;
  recovered_receipt_count : int;
  load_errors : (string option * snapshot_load_error) list;
}

type transition_observer = keeper_name:string -> revision:int64 -> unit

(** Install the single post-commit invalidation observer.  It is invoked after
    every successful queue mutation and always outside queue mutexes.  Observer
    failures are logged and never roll back or disguise a committed mutation. *)
val set_transition_observer : transition_observer option -> unit

val continuation_channel_of_message_source :
  ?dashboard_thread_id:string -> message_source -> Keeper_continuation_channel.t

(** Enable persistence in the canonical cluster-aware Keeper runtime directory
    resolved from [config], and restore every per-Keeper snapshot. Safe
    version-1/version-2 files are decoded only by explicit parsers and
    atomically rewritten as strict version 3. Active legacy connector messages
    without a transcript-ownership decision fail migration closed. A malformed
    snapshot is retained, registered as unavailable, and reported here; it is
    never replaced by an empty queue. Reconfiguration clears the prior
    in-memory registry before loading the new workspace/cluster ownership
    boundary, and never scans a different cluster as a migration fallback. *)
val configure_persistence : config:Workspace.config -> configure_report

val persistence_configured : unit -> bool

val persistence_matches_config : config:Workspace.config -> bool
(** [persistence_matches_config ~config] is [true] when persistence has not yet
    been configured or when [config] resolves to the exact configured Keeper
    storage root. A process-lifetime consumer must reject live workspace/root
    switches when this returns [false]. *)

(** Enqueue only after the receipt-bearing version-3 snapshot commits. *)
val enqueue :
  keeper_name:string -> queued_message -> (enqueue_receipt, mutation_error) result

val same_source : message_source -> message_source -> bool

val lease_batch :
  keeper_name:string ->
  [ `Leased of lease
  | `Empty
  | `Already_leased of string
  | `Error of mutation_error
  ]

(** Atomically finalize every receipt in the matching lease.  Terminal records
    retain correlation metadata and normally discard message bodies and
    attachments. [Transcript_persist_failed] retains the queued message in the
    owner-only snapshot so a failed transcript write cannot erase its only
    durable copy; diagnostic projections do not expose that body. *)
val finalize :
  keeper_name:string ->
  lease_id:string ->
  outcome:finalization ->
  [ `Finalized of Receipt_id.t list
  | `Unknown_lease
  | `Error of mutation_error
  ]

(** Return every receipt in the matching lease to [Pending], preserving ids and
    FIFO order. *)
val nack :
  keeper_name:string ->
  lease_id:string ->
  [ `Requeued of Receipt_id.t list
  | `Unknown_lease
  | `Error of mutation_error
  ]

(** Coalesce a leased same-source run into one turn payload without erasing the
    receipt list carried by the lease. *)
val merge_batch : leased_message list -> queued_message option

val pending_count : keeper_name:string -> (int, mutation_error) result
val inflight_count : keeper_name:string -> (int, mutation_error) result
val has_active_receipts : keeper_name:string -> (bool, mutation_error) result
val snapshot : keeper_name:string -> diagnostic_snapshot

val lookup_receipt :
  keeper_name:string ->
  receipt_id:Receipt_id.t ->
  (receipt_lookup, mutation_error) result
(** Atomically return the receipt observation with the queue revision that
    produced it. *)

val all_keeper_names : unit -> string list

val configuration_errors : unit -> snapshot_load_error list
(** Queue-registry errors that are not owned by one valid Keeper entry, such
    as a failed storage-root migration decision or an invalid snapshot-bearing
    directory name. Per-Keeper snapshot errors remain on {!snapshot}. *)

module For_testing : sig
  val reset : unit -> unit
  val fail_next_persist : unit -> unit
end
