(** One durable Librarian pass over a keeper's finished turns.

    Boundary lines, the two read positions and then the canonical checkpoint
    are read, in that order, so the selected range and its slice use the same
    immutable checkpoint value. Agent-Core turns are read as atoms of that
    checkpoint; official-client turns, whose end lines carry no atoms, are
    read as the fragments their [turn_ref] names in the history files of
    their trace ({!Keeper_turn_fragments}, RFC librarian-lifecycle §10-3). A
    pass hands the Librarian both kinds in the order their end lines were
    appended. Each kind has its own position: the atom position
    ({!Keeper_librarian_progress}) and the official one
    ({!Keeper_librarian_official_progress}), and a consumed pass advances
    them only when [commit] reports that the Memory OS snapshot committed.
    Establishing an initial baseline writes the atom position without a
    Memory commit. *)

type outcome =
  | Nothing_to_read
  | Baseline_advanced of Keeper_librarian_progress.t
  | Memory_not_committed
  | Progress_advanced of Keeper_librarian_progress.t
      (** A pass of atoms only. *)
  | Official_advanced of
      { atom : Keeper_librarian_progress.t option
      ; official : Keeper_librarian_official_progress.t
      }
      (** A pass that read official-client lines, with the atoms it read
          alongside if any. Lines whose fragments are all gone or all untagged
          are passed without a model call. *)

type error =
  | Keeper_meta_absent
  | Keeper_meta_unreadable of string
  | Boundary_log_unreadable of string
  | Progress_unreadable of Keeper_librarian_progress.read_error
  | Checkpoint_unreadable of
      { trace_id : string
      ; error : Keeper_checkpoint_store.checkpoint_load_error
      }
  | Position_in_other_trace of Keeper_librarian_progress.position
  | Position_not_in_history of Keeper_librarian_progress.position
      (** The position names no atom of the current checkpoint and no restart
          line explains it (RFC §4.4 row 5). Only {!unread_turns} answers
          with this; a pass reports the same state as [Range_stopped]. *)
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
  | Official_progress_unreadable of Keeper_librarian_official_progress.read_error
  | Official_progress_write_failed of Keeper_librarian_official_progress.write_error
  | Official_progress_boundary_missing of Keeper_librarian_official_progress.t
      (** The official position names a line that is not an official turn's
          end line. *)
  | Committed_official_range_mismatch
      (** A saved Memory receipt names different official turns from the
          current boundary log. Neither cursor nor Memory may advance. *)
  | Official_range_stopped of
      { line : int
      ; error : Keeper_turn_boundaries.read_error
      }
      (** A refused line beyond the official position (RFC §4.4 row 2c). *)
  | Fragment_store_unreadable of
      { trace_id : string
      ; file : Keeper_turn_fragments.file
      ; detail : string
      }
  | Fragment_line_unreadable of
      { trace_id : string
      ; file : Keeper_turn_fragments.file
      ; line : int
      ; error : Keeper_turn_fragments.read_error
      }
      (** A refused history line after the first that names a turn. *)

val error_to_string : error -> string

(** How far behind the keeper's Librarian is standing (RFC §4.9, invariant
    I4): finished turns beyond each read position, counted over the boundary
    log, the two positions and the current checkpoint. Read-only, and
    separate from a pass so that an operator surface can ask without moving
    anything.

    A refused line or a failed commit does not hide the count -- how far
    behind is exactly what an operator needs while a round is stopped. What
    is not counted: restart lines, lines of a history that has been
    renumbered (§4.4 row 2a), and turns that failed before writing an end
    line. *)
type unread =
  { atoms : int
  ; official : int
  }

val unread_turns : config:Workspace.config -> keeper_name:string -> (unread, error) result

val consume_one
  :  config:Workspace.config
  -> keeper_name:string
  -> commit:
       (expected_revision:int option
        -> range_id:Keeper_memory_os_current.durable_range_id option
          -> official_range_id:Keeper_memory_os_current.official_range_id option
        -> Keeper_librarian.input
        -> bool)
  -> (outcome, error) result
(** The first attempt reads all unread cut points and official lines. A
    failed commit, typed error, or cancellation keeps a process-local marker;
    the next attempt for that cluster-scoped Keeper reads only the oldest
    unread turn, of whichever kind ends first in the log. A small successful
    cut keeps that mode until the backlog is empty; a successful all-unread
    pass or a baseline also clears the marker. Durable progress remains the
    authority across process restarts.

    [range_id] is the receipt identity of the atoms in the pass, [None] when
    the pass read official lines only: the receipt recovers a Memory commit
    whose atom position write did not land, and official lines are re-read
    in that case rather than skipped.

    [Baseline_advanced] means an absent position was durably initialized at
    the smallest matching cut point. [Progress_advanced] means a non-empty
    selected range committed and its resulting position was durably written.
    Without a newly observed restart, its [end_atom] is strictly greater than
    the position read by this call. A newer restart instead increases
    [boundary_lines_seen] and starts from atom zero: the resulting [end_atom]
    may equal or precede the old one. When metadata moves to another trace,
    an available prior checkpoint is drained first. Once it is exhausted, or
    when owner/session removal made it unavailable, the traces that started
    after it are read in the order their fresh/restart boundary appears in the
    log, each from atom zero, up to the current trace; a trace with nothing to
    read is passed, and so is one whose checkpoint holds a version this build
    supersedes, because no turn rewrites a retired trace's checkpoint and
    stopping there would stop every trace after it. Any other unreadable
    checkpoint stops the pass and names its trace. The counterpart lower bound stays at the prior position's
    boundary across that move. With no started trace to move to, the old
    cursor stays and the pass reports [Position_in_other_trace].

    Under the progress store's single-writer contract, a fixed boundary
    snapshot and checkpoint therefore cannot select the same range again
    after an advance; repeated successful passes exhaust their cut points.
    New boundary appends can extend a drain while it is running.

    The Memory WAL sidecar stores the exact [range_id] passed to a successful
    [commit]. If the separate progress write then fails, the next pass first
    checks the original all-unread selection, before process-local retry
    narrowing, and advances to the committed endpoint without calling [commit]
    again. Later Memory writers preserve every runtime cluster's receipt until
    a newer durable range in that same cluster replaces it.

    Official-client turns have their own receipt in that same Memory WAL,
    naming the exact ordered boundary rows and turn references. It is recovered
    before checkpoint selection or retry narrowing. A mixed Memory commit
    records both kinds together; a failed write of either progress file never
    requires synthesizing that committed input again. A receipt whose official
    identities no longer match the log stops the pass. *)

(** Production commit edge. The selected range bypasses the retired recent
    message window; [true] means the current Memory OS snapshot committed. *)
val commit_with_runtime
  :  base_path:string
  -> keepers_dir:string
  -> keeper_id:string
  -> expected_revision:int option
  -> range_id:Keeper_memory_os_current.durable_range_id option
          -> official_range_id:Keeper_memory_os_current.official_range_id option
  -> Keeper_librarian.input
  -> bool

module For_testing : sig
  val consume_one_with_progress_writer
    :  write_progress_store:
         (keepers_dir:string
          -> keeper_id:string
          -> Keeper_librarian_progress.t
          -> (unit, Keeper_librarian_progress.write_error) result)
    -> write_official_progress_store:
         (keepers_dir:string
          -> keeper_id:string
          -> Keeper_librarian_official_progress.t
          -> (unit, Keeper_librarian_official_progress.write_error) result)
    -> config:Workspace.config
    -> keeper_name:string
    -> commit:
         (expected_revision:int option
          -> range_id:Keeper_memory_os_current.durable_range_id option
          -> official_range_id:Keeper_memory_os_current.official_range_id option
          -> Keeper_librarian.input
          -> bool)
    -> (outcome, error) result

  val reset_process_state : unit -> unit
end
