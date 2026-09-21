(** One durable Agent-Core Librarian pass.

    Boundary lines and progress are read before the canonical checkpoint. The
    selected range and its slice therefore use the same immutable checkpoint
    value. A consumed range advances progress only when [commit] reports that
    the Memory OS snapshot committed. Establishing an initial baseline writes
    progress without a Memory commit. *)

type outcome =
  | Nothing_to_read
  | Baseline_advanced of Keeper_librarian_progress.t
  | Memory_not_committed
  | Progress_advanced of Keeper_librarian_progress.t

type error =
  | Keeper_meta_absent
  | Keeper_meta_unreadable of string
  | Boundary_log_unreadable of string
  | Progress_unreadable of Keeper_librarian_progress.read_error
  | Checkpoint_unreadable of Keeper_checkpoint_store.checkpoint_load_error
  | Position_in_other_trace of Keeper_librarian_progress.position
  | Range_stopped of Keeper_librarian_range.stop
  | Range_end_boundary_missing of Keeper_librarian_range.range
  | Progress_boundary_missing of Keeper_librarian_progress.position
  | Memory_snapshot_unreadable of string
  | Counterpart_interval_non_monotone of
      { after : float
      ; before : float
      }
  | Counterpart_observations_unreadable of Keeper_librarian_input_sources.read_error
  | Progress_write_failed of Keeper_librarian_progress.write_error

val error_to_string : error -> string

val consume_one
  :  config:Workspace.config
  -> keeper_name:string
  -> commit:
       (expected_revision:int option
        -> range_id:Keeper_memory_os_current.durable_range_id
        -> Keeper_librarian.input
        -> bool)
  -> (outcome, error) result
(** The first attempt reads all unread cut points. A failed commit, typed
    error, or cancellation keeps a process-local marker; the next attempt for
    that cluster-scoped Keeper reads only through the oldest unread cut point.
    A small successful cut keeps that mode until the backlog is empty;
    a successful all-unread pass or a baseline also clears the marker.
    Durable progress remains the authority across process restarts.

    [Baseline_advanced] means an absent position was durably initialized at
    the smallest matching cut point. [Progress_advanced] means a non-empty
    selected range committed and its resulting position was durably written.
    Without a newly observed restart, its [end_atom] is strictly greater than
    the position read by this call. A newer restart instead increases
    [boundary_lines_seen] and starts from atom zero: the resulting [end_atom]
    may equal or precede the old one. When metadata moves to another trace,
    an available prior checkpoint is drained first. Once it is exhausted, or
    when owner/session removal made it unavailable, the current trace's own
    fresh/restart boundary authorizes the transition instead of leaving the
    old cursor as a permanent stop.

    Under the progress store's single-writer contract, a fixed boundary
    snapshot and checkpoint therefore cannot select the same range again
    after an advance; repeated successful passes exhaust their cut points.
    New boundary appends can extend a drain while it is running.

    The Memory WAL sidecar stores the exact [range_id] passed to a successful
    [commit]. If the separate progress write then fails, the next pass first
    checks the original all-unread selection, before process-local retry
    narrowing, and advances to the committed endpoint without calling [commit]
    again. Later Memory writers preserve every runtime cluster's receipt until
    a newer durable range in that same cluster replaces it. *)

(** Production commit edge. The selected range bypasses the retired recent
    message window; [true] means the current Memory OS snapshot committed. *)
val commit_with_runtime
  :  base_path:string
  -> keepers_dir:string
  -> keeper_id:string
  -> expected_revision:int option
  -> range_id:Keeper_memory_os_current.durable_range_id
  -> Keeper_librarian.input
  -> bool

module For_testing : sig
  val consume_one_with_progress_writer
    :  write_progress_store:
         (keepers_dir:string
          -> keeper_id:string
          -> Keeper_librarian_progress.t
          -> (unit, Keeper_librarian_progress.write_error) result)
    -> config:Workspace.config
    -> keeper_name:string
    -> commit:
         (expected_revision:int option
          -> range_id:Keeper_memory_os_current.durable_range_id
          -> Keeper_librarian.input
          -> bool)
    -> (outcome, error) result

  val reset_process_state : unit -> unit
end
