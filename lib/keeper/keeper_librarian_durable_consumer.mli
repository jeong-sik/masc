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
    Memory commit. Verified unread evidence is durably accumulated under the
    Memory lock before external acknowledgements or either progress write.
    Recovering a hole-bearing range also checks its exact source messages. *)

type commit_result =
  | Memory_committed
  | Memory_refused of Keeper_librarian_runtime.not_committed list
      (** All failure reports in callback order. An empty list means the pass
          returned without committing or supplying classified evidence. Neither
          form authorizes progress or proves that the source is too large. *)

type outcome =
  | Nothing_to_read
  | Baseline_advanced of Keeper_librarian_progress.t
  | Memory_not_committed of Keeper_librarian_runtime.not_committed list
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
      (** A refused line beyond the official position (RFC §4.4 row 2c). It
          holds the official lines only (RFC §4.10): a pass whose atom part
          has a range reads it and advances the atom position, and a pass
          answers with this error once its atom part has nothing to read. *)
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
        -> commit_result)
  -> (outcome, error) result
(** The first attempt reads all unread cut points and official lines. A
    failed commit, typed error, or cancellation keeps a process-local marker;
    the next attempt for that Keeper reads only the oldest
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
    supersedes ({!Keeper_checkpoint_store.saved_history}). On the current
    trace such a checkpoint leaves the atom part nothing to read, and the
    trace's official lines are still read. Any other unreadable
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
    again. Later Memory writers preserve every receipt scope's receipt until
    a newer durable range in that same scope replaces it.

    The continuity round saves Memory itself for a completed range this
    consumer has not committed, under its own receipt scope
    ({!Keeper_librarian_continuity.path}), and publishes its snapshot only
    after that save. When its receipt or its published snapshot reaches past
    the atom position in the same history, a pass advances to the furthest
    such end the same way, without calling [commit], so those atoms are not
    sent to the model a second time.

    Official-client turns have their own receipt in that same Memory WAL,
    naming the exact ordered boundary rows and turn references. It is recovered
    before checkpoint selection or retry narrowing. A mixed Memory commit
    records both kinds together; a failed write of either progress file never
    requires synthesizing that committed input again. A receipt whose official
    identities no longer match the log stops the pass. *)

val consume_one_with_runtime
  : ?cli_runner:Keeper_lane_cli_oneshot.runner
  -> config:Workspace.config
  -> keeper_name:string
  -> unit
  -> (outcome, error) result
(** Production source-aware consumer. After the normal pass reaches a single
    checkpoint cut or official turn and a failure that can warrant reading
    less, infer its exact messages into a process-local ordered Memory program.
    A checkpoint cut may span several atoms, including in a retired trace;
    message coordinates keep the original complete checkpoint numbering.
    Retain the original source and cursors, then revalidate under that selected
    source's stable session lock before publishing once at the original
    boundary. Checkpoint validation includes the full original prefix and a
    fresh selection, rejecting body changes and later history restarts while
    permitting an appended suffix. Official turns retain all main/internal
    fragments and host observations under the actual writers' same lock.
    Only Runtime's actual exhausted API walk evidence may authorize unread
    holes. Inherited WAL recovery archives holes before external acknowledgement
    and progress. Generic [consume_one ~commit] never turns an injected commit
    refusal into skip authority. *)

val tool_observations : Agent_core.Types.message list -> Keeper_librarian.tool_observation list
(** The tool calls in [messages], each with how its result ended ([Unknown]
    when no result follows). What a pass hands the Librarian for the atoms it
    reads; the continuity round's Memory pass uses it for the same atoms. *)

(** Production commit edge. The selected range bypasses the retired recent
    message window. [Memory_committed] means the current Memory OS snapshot
    committed; otherwise the pass preserves every classified runtime report.
    This adapter does not catch cancellation or exceptions that escape
    [Keeper_librarian_runtime.run_best_effort]. *)
val commit_with_runtime
  :  base_path:string
  -> keepers_dir:string
  -> keeper_id:string
  -> expected_revision:int option
  -> range_id:Keeper_memory_os_current.durable_range_id option
          -> official_range_id:Keeper_memory_os_current.official_range_id option
  -> Keeper_librarian.input
  -> commit_result

module For_testing : sig
  val consume_one_with_runtime_and_progress_writers
    : ?cli_runner:Keeper_lane_cli_oneshot.runner
    -> write_progress_store:
         (keepers_dir:string -> keeper_id:string -> Keeper_librarian_progress.t ->
          (unit, Keeper_librarian_progress.write_error) result)
    -> write_official_progress_store:
         (keepers_dir:string -> keeper_id:string -> Keeper_librarian_official_progress.t ->
          (unit, Keeper_librarian_official_progress.write_error) result)
    -> config:Workspace.config
    -> keeper_name:string
    -> unit
    -> (outcome, error) result

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
          -> commit_result)
    -> (outcome, error) result

  val reset_process_state : unit -> unit
end
