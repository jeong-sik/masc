(** In-memory, append-only journal for one finite execution scope.

    A journal admits exactly one top-level [Agent_run] and any child runs
    recursively invoked beneath exact [Tool_attempt] occurrences. It owns one
    global logical sequence across that tree. Timestamps are observations only;
    ordering uses [seq].

    Events remain in memory for the lifetime of [t]. A claimed durable writer
    hides the physical store behind this semantic boundary; consumers obtain
    immutable event snapshots through [events] or bounded [read_page] calls. *)

type run

val run_id : run -> Execution_event.Run_id.t
val run_root : run -> Execution_event.Node_id.t
val equal_run : run -> run -> bool

(** A value together with the exact immutable event that materialized it. *)
type 'a event_record = private
  { event : Execution_event.t
  ; value : 'a
  }

type node_status =
  | Open
  | Closed of Execution_event.terminal event_record

type materialized =
  | Agent_run_state
  | Agent_turn_state
  | Provider_attempt_state of { response : Llm_provider.Types.api_response option }
  | Output_block_state of { snapshot : Llm_provider.Types.content_block option }
  | Tool_invocation_state of
      { input : Llm_provider.Types.content_block option
      ; result : Llm_provider.Types.content_block option
      }
  | Tool_attempt_state

type node_view = private
  { node : Execution_event.node
  ; opened : Execution_event.node event_record
  ; status : node_status
  ; updates : Execution_event.node_update event_record list
  ; children : Execution_event.node event_record list
  ; materialized : materialized
  ; through_seq : int
  }

type run_status =
  | Running
  | Finished of Execution_event.terminal event_record

type run_view = private
  { run : run
  ; opened : Execution_event.node event_record
  ; parent_attempt : Execution_event.Node_id.t option
  ; status : run_status
  ; through_seq : int
  }

(** Journal-scoped event cursor. A cursor from another journal is rejected even
    when its numeric sequence happens to fit this journal. *)
type cursor = Execution_event_store.cursor

val cursor_seq : cursor -> int
val cursor_to_yojson : cursor -> Yojson.Safe.t
val cursor_of_yojson : Yojson.Safe.t -> (cursor, string) result

type invariant_violation =
  | Sequence_mismatch of
      { expected : int
      ; actual : int
      }
  | Duplicate_event_id of Execution_event.Event_id.t
  | Unknown_parent_event of Execution_event.Event_id.t
  | Unknown_cause_event of Execution_event.Event_id.t
  | Correlation_mismatch of
      { expected : Execution_event.Correlation_id.t
      ; actual : Execution_event.Correlation_id.t
      }
  | Event_run_mismatch of
      { envelope_run_id : Execution_event.Run_id.t
      ; payload_run_id : Execution_event.Run_id.t
      }
  | Duplicate_node_id of Execution_event.Node_id.t
  | Unknown_node of Execution_event.Node_id.t
  | Duplicate_run_id of Execution_event.Run_id.t
  | Unknown_run of Execution_event.Run_id.t
  | Run_already_finished of Execution_event.Run_id.t
  | Node_already_closed of Execution_event.Node_id.t
  | Parent_required of Execution_event.Node_id.t
  | Unknown_parent_node of Execution_event.Node_id.t
  | Parent_node_closed of Execution_event.Node_id.t
  | Cross_run_parent of
      { node_run_id : Execution_event.Run_id.t
      ; parent_run_id : Execution_event.Run_id.t
      }
  | Invalid_parent_kind of
      { parent : Execution_event.Node_id.t
      ; child : Execution_event.Node_id.t
      }
  | Child_run_parent_not_tool_attempt of Execution_event.Node_id.t
  | Root_parent_event_mismatch
  | Parent_event_mismatch of
      { expected : Execution_event.Event_id.t
      ; actual : Execution_event.Event_id.t option
      }
  | Invalid_update_for_node of Execution_event.Node_id.t
  | Provider_response_already_materialized of Execution_event.Node_id.t
  | Output_snapshot_already_materialized of Execution_event.Node_id.t
  | Output_snapshot_kind_mismatch of
      { node : Execution_event.Node_id.t
      ; expected : Execution_event.output_block_kind
      ; actual : Execution_event.content_block_classification
      }
  | Output_delta_after_snapshot of Execution_event.Node_id.t
  | Output_snapshot_not_materialized of Execution_event.Node_id.t
  | Tool_input_already_materialized of Execution_event.Node_id.t
  | Tool_input_snapshot_not_tool_use of Execution_event.Node_id.t
  | Tool_input_snapshot_identity_mismatch of Execution_event.Node_id.t
  | Tool_input_delta_after_snapshot of Execution_event.Node_id.t
  | Tool_input_not_materialized of Execution_event.Node_id.t
  | Tool_invocation_requires_atomic_open
  | Occurrence_already_opened of Execution_event.Node_id.t
  | Tool_occurrence_conflict of
      { parent : Execution_event.Node_id.t
      ; planned_index : int
      ; existing : Execution_event.Node_id.t
      }
  | Tool_result_already_materialized of Execution_event.Node_id.t
  | Tool_result_snapshot_not_tool_result of Execution_event.Node_id.t
  | Tool_result_snapshot_identity_mismatch of Execution_event.Node_id.t
  | Tool_result_while_children_open of Execution_event.Node_id.t
  | Tool_result_not_materialized of Execution_event.Node_id.t
  | Child_after_tool_result of Execution_event.Node_id.t
  | Node_has_open_children of Execution_event.Node_id.t
  | Run_has_open_nodes of Execution_event.Run_id.t
  | Root_must_use_finish_run of Execution_event.Node_id.t
  | Agent_run_must_use_start_run
  | Top_level_run_already_exists
[@@deriving show]

type error =
  | Invalid_argument of string
  | Invalid_event of string
  | Identity_failure of string
  | Empty_batch
  | Durable_batch_owner_mismatch
  | Direct_mutation_forbidden
  | Durable_writer_owner_mismatch
  | Durable_store_unavailable
  | Durable_construction_cleanup_failed of
      { construction_error : error
      ; cleanup_error : Execution_event_store.error
      }
  | Reconciliation_scope_mismatch
  | Reconciliation_correlation_mismatch
  | Reconciliation_content_conflict of
      { first_seq : int
      ; last_seq : int
      }
  | Reconciliation_conflict of
      { base_seq : int
      ; final_seq : int
      ; current_seq : int
      }
  | Reconciliation_store_diverged of
      { first_seq : int
      ; last_seq : int
      }
  | Projection_index_diverged of
      { expected_seq : int
      ; high_watermark : int
      }
  | Stale_batch of
      { expected_last_seq : int
      ; actual_last_seq : int
      }
  | Cursor_scope_mismatch
  | Cursor_ahead of
      { after_seq : int
      ; last_seq : int
      }
  | Persistence_failure of Execution_event_store.error
  | Invariant_violation of invariant_violation

val error_to_string : error -> string

type commit_error_disposition =
  | Reconcile_required
  | Final_failure

(** Closed classification for writer actors. This is the only API outside this
    module that needs to distinguish an authority outcome requiring reopen;
    callers never inspect store errors or error strings. *)
val commit_error_disposition : error -> commit_error_disposition

(** Narrow read-only durable source for execution projections. Physical store
    ownership and store-error translation remain inside this journal boundary. *)
module Durable_read : sig
  module Scope_id : sig
    type t

    val of_string : string -> (t, string) result
    val to_string : t -> string
    val equal : t -> t -> bool
  end

  type unexpected_store_error =
    | Writer_already_active
    | Store_already_attached
    | Store_released
    | Store_release_forbidden
    | Resource_cleanup_failed
    | Construction_cleanup_failed
    | Store_already_exists
    | Correlation_mismatch
    | Sequence_conflict
    | Committed_content_conflict
    | Cursor_scope_mismatch
    | Cursor_ahead
    | Store_poisoned
    | Commit_outcome_unknown

  type storage_failure =
    | Invalid_store_argument of string
    | Store_identity_failure of string
    | Store_io_failure of
        { operation : string
        ; detail : string
        }
    | Store_codec_failure of string
    | Store_not_found
    | Store_initialization_incomplete
    | Store_initialization_conflict
    | Unsupported_store_version of
        { expected : int
        ; actual : int
        }
    | Corrupt_store of
        { offset : int64
        ; detail : string
        }
    | Commit_authority_identity_changed
    | Commit_authority_regressed of
        { previous_committed_offset : int64
        ; actual_committed_offset : int64
        ; previous_last_seq : int
        ; actual_last_seq : int
        }
    | Unexpected_store_failure of
        { kind : unexpected_store_error
        ; detail : string
        }

  type snapshot

  val read_snapshot
    :  codec:Execution_codec_executor.t
    -> dir:Eio.Fs.dir_ty Eio.Path.t
    -> ?previous:snapshot
    -> unit
    -> (snapshot, storage_failure) result

  val same_snapshot : snapshot -> snapshot -> bool
  val scope_id : snapshot -> Scope_id.t
  val committed_offset : snapshot -> int64
  val last_seq : snapshot -> int
  val appended_events : snapshot -> Execution_event.t list
end

(** Pure immutable reducer used to validate and project the event stream. *)
module Reducer : sig
  type t

  val empty : t
  val apply : t -> Execution_event.t -> (t, invariant_violation) result
  val last_seq : t -> int
  val find_node : t -> Execution_event.Node_id.t -> node_view option
  val find_run : t -> Execution_event.Run_id.t -> run_view option
end

type t
type durable_writer

(** An immutable, O(1)-captured reducer snapshot. Materializing node histories
    from it does not hold the journal mutex, and every projection shares one
    [through_seq] watermark. *)
type snapshot

(** Create an explicitly volatile execution scope. Durable scopes are created
    only through {!create_durable_writer}; no caller can obtain an unclaimed
    durable journal or bypass its claimed writer authority. *)
val create : ?correlation_id:Execution_event.Correlation_id.t -> unit -> (t, error) result

(** Explicit durable construction. The directory is caller-owned and dedicated
    to one execution scope; no path or runtime mode is inferred. The abstract
    capability is the proof required by a durability-owning writer actor. *)
val create_durable_writer
  :  sw:Eio.Switch.t
  -> codec:Execution_codec_executor.t
  -> dir:Eio.Fs.dir_ty Eio.Path.t
  -> ?correlation_id:Execution_event.Correlation_id.t
  -> unit
  -> (durable_writer * Execution_event_store.initialization, error) result

val open_durable_writer
  :  sw:Eio.Switch.t
  -> codec:Execution_codec_executor.t
  -> dir:Eio.Fs.dir_ty Eio.Path.t
  -> (durable_writer * Execution_event_store.recovery, error) result

(** Read/projection access. Direct mutation functions reject this journal with
    [Direct_mutation_forbidden]; only typed writer transactions can mutate it. *)
val durable_writer_journal : durable_writer -> t

val length : t -> int
val last_seq : t -> int
val events : t -> Execution_event.t list
val beginning_cursor : t -> cursor
val current_cursor : t -> cursor

type page = private
  { events : Execution_event.t list
  ; next_cursor : cursor
  ; high_watermark : cursor
  ; has_more : bool
  }

(** Read a bounded immutable projection page. Omitting [through] captures the
    current journal high watermark; passing that cursor on later calls freezes
    the projection while new events continue to append. [limit] is a transport
    resource boundary only and never controls execution admission or lifetime. *)
val read_page
  :  t
  -> after:cursor
  -> ?through:cursor
  -> limit:int
  -> unit
  -> (page, error) result

val snapshot : t -> snapshot
val snapshot_cursor : snapshot -> cursor
val snapshot_find_node : snapshot -> Execution_event.Node_id.t -> node_view option
val snapshot_find_run : snapshot -> Execution_event.Run_id.t -> run_view option
val find_node : t -> Execution_event.Node_id.t -> node_view option
val find_run : t -> Execution_event.Run_id.t -> run_view option

(** An immutable semantic transaction staged from one exact journal snapshot.
    Callers can construct only the closed journal mutation set below, never raw
    events or caller-selected sequence and identity fields. A rejected stage
    leaves the input [batch] unchanged.

    Event and node identities are allocated while staging and retained by the
    returned batch. Retrying [commit_batch] therefore submits the exact same
    canonical events; callers must not rebuild a failed batch to retry durable
    persistence. *)
type batch

type batch_metadata = private
  { base_cursor : cursor
  ; final_cursor : cursor
  ; correlation_id : Execution_event.Correlation_id.t
  }

val begin_batch : t -> batch

(** Capture the claimed writer's current reducer snapshot. *)
val begin_durable_batch : durable_writer -> batch

val batch_length : batch -> int
val batch_metadata : batch -> batch_metadata

module Transaction : sig
  type 'a t

  val start_run
    :  ?parent_attempt:Execution_event.Node_id.t
    -> ?causes:Execution_event.cause list
    -> agent_name:string
    -> unit
    -> (run * Execution_event.t) t

  val open_node
    :  ?causes:Execution_event.cause list
    -> run:run
    -> parent:Execution_event.Node_id.t
    -> kind:Execution_event.node_kind
    -> unit
    -> (Execution_event.Node_id.t * Execution_event.t) t

  val update_node
    :  ?causes:Execution_event.cause list
    -> node:Execution_event.Node_id.t
    -> Execution_event.node_update
    -> Execution_event.t t

  val close_node
    :  ?causes:Execution_event.cause list
    -> node:Execution_event.Node_id.t
    -> Execution_event.terminal
    -> Execution_event.t t

  (** Open an attempt under a materialized invocation-derived run. *)
  val begin_tool_attempt
    :  invocation:Execution_event.Node_id.t
    -> unit
    -> (Execution_event.Node_id.t * Execution_event.t) t

  (** Atomically open and materialize one exact provider ToolUse occurrence.
      The invocation turn must match the parent provider attempt's turn. *)
  val open_tool_invocation
    :  run:run
    -> provider_attempt:Execution_event.Node_id.t
    -> invocation:Tool_contract.Invocation.t
    -> tool_name:string
    -> input:Yojson.Safe.t
    -> unit
    -> (Execution_event.Node_id.t * Execution_event.t list) t

  (** Atomically close attempt, materialize ToolResult, and close invocation. *)
  val settle_tool_attempt
    :  attempt:Execution_event.Node_id.t
    -> invocation:Execution_event.Node_id.t
    -> result:Llm_provider.Types.content_block
    -> unit
    -> Execution_event.t list t

  (** Atomically materialize a blocked ToolResult and close an invocation that
      has no effect attempt. This cannot settle an attempted or closed
      invocation. *)
  val settle_unattempted_tool_invocation
    :  invocation:Execution_event.Node_id.t
    -> result:Llm_provider.Types.content_block
    -> unit
    -> Execution_event.t list t

  val finish_run
    :  ?causes:Execution_event.cause list
    -> run:run
    -> Execution_event.terminal
    -> Execution_event.t t

  val abort_run
    :  ?causes:Execution_event.cause list
    -> run:run
    -> Execution_event.terminal
    -> Execution_event.t list t
end

(** Validate and stage one typed semantic transaction against the batch's
    current immutable reducer state. The result type is carried by
    [Transaction.t], allowing a writer actor to pair heterogeneous commands
    with correctly typed completion tickets. *)
val stage : batch -> 'a Transaction.t -> (batch * 'a, error) result

(** Commit every staged event with one store append and then publish the final
    immutable reducer state once. [Stale_batch] is returned before persistence
    if another mutation has advanced the journal since [begin_batch]. An empty
    batch is rejected explicitly. [Commit_outcome_unknown] remains a typed
    {!Persistence_failure}; reconciliation requires reopening the owning store,
    so this API does not pretend that a live journal can resolve it. *)
val commit_batch : batch -> (Execution_event.t list, error) result

(** Commit through the exclusive durable writer claim. A batch captured from
    any other live journal is rejected before persistence. *)
val commit_durable_batch
  :  durable_writer
  -> batch
  -> (Execution_event.t list, error) result

type durable_batch_reconciliation =
  | Applied of Execution_event.t list
  | Already_durable of Execution_event.t list

(** Reconcile one immutable pending batch against a newly reopened writer for
    the same scope and correlation. At the exact base cursor the original
    events are applied without regenerating identities. At the exact final
    cursor the committed range is compared byte-for-byte. No other cursor is
    inferred or retried. *)
val reconcile_durable_batch
  :  durable_writer
  -> batch
  -> (durable_batch_reconciliation, error) result

(** Start the journal's sole top-level run, or a child run beneath one exact
    open [Tool_attempt]. Once the top-level run has started, the journal can
    never be reused for another top-level run, including after it finishes. The
    journal allocates both run and root-node identity. *)
val start_run
  :  ?parent_attempt:Execution_event.Node_id.t
  -> ?causes:Execution_event.cause list
  -> t
  -> agent_name:string
  -> (run * Execution_event.t, error) result

(** Open a non-root node. The journal allocates node identity and enforces the
    hierarchy [Agent_run -> Agent_turn -> Provider_attempt ->
    (Output_block | Tool_invocation)], [Tool_invocation -> Tool_attempt], and
    recursive [Tool_attempt -> Tool_invocation]. *)
val open_node
  :  ?causes:Execution_event.cause list
  -> t
  -> run:run
  -> parent:Execution_event.Node_id.t
  -> kind:Execution_event.node_kind
  -> (Execution_event.Node_id.t * Execution_event.t, error) result

val update_node
  :  ?causes:Execution_event.cause list
  -> t
  -> node:Execution_event.Node_id.t
  -> Execution_event.node_update
  -> (Execution_event.t, error) result

(** Close a non-root node. A node with an open child cannot close. *)
val close_node
  :  ?causes:Execution_event.cause list
  -> t
  -> node:Execution_event.Node_id.t
  -> Execution_event.terminal
  -> (Execution_event.t, error) result

(** Close a run root. Every other node in the run, including nested child-run
    roots under its tool invocations, must already be closed. *)
val finish_run
  :  ?causes:Execution_event.cause list
  -> t
  -> run:run
  -> Execution_event.terminal
  -> (Execution_event.t, error) result

(** Atomically close every open descendant of [run] in post-order and then
    close the run root with the same failure or cancellation terminal. The
    staging traversal is cancellable and publishes no partial prefix. A
    journal-local writer gate fences concurrent mutations while traversal and
    validation run outside the state mutex. It yields between semantic nodes
    without releasing that fence, allowing unrelated fibers and other journal
    scopes on the same Eio domain to progress. Once staging completes, the
    immutable final state is published atomically. [Succeeded] is rejected:
    normal completion must use the explicit close/finish lifecycle. *)
val abort_run
  :  ?causes:Execution_event.cause list
  -> t
  -> run:run
  -> Execution_event.terminal
  -> (Execution_event.t list, error) result
