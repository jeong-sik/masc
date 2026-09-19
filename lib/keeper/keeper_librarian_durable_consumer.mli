(** One durable Agent-Core Librarian pass.

    Boundary lines and progress are read before the canonical checkpoint. The
    selected range and its slice therefore use the same immutable checkpoint
    value. Progress is written only when [commit] reports that the Memory OS
    snapshot committed. *)

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
       (expected_revision:int option -> Keeper_librarian.input -> bool)
  -> (outcome, error) result
(** The first attempt reads all unread cut points. A failed commit, typed
    error, or cancellation keeps a process-local marker; the next attempt for
    that cluster-scoped Keeper reads only through the oldest unread cut point.
    Success or no unread range clears the marker. Durable progress remains the
    authority across process restarts. *)

(** Production commit edge. The selected range bypasses the retired recent
    message window; [true] means the current Memory OS snapshot committed. *)
val commit_with_runtime
  :  base_path:string
  -> keepers_dir:string
  -> keeper_id:string
  -> expected_revision:int option
  -> Keeper_librarian.input
  -> bool
