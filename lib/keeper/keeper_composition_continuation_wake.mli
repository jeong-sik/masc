(** Provider-free resumption of canonically ready prepared job-result waits.
    Discovery is a hint; current profile, metadata and exact journal admission
    remain the only execution authority. *)
type error =
  | Profile_unavailable of Keeper_types_profile.keeper_toml_load_error
  | Metadata_unavailable of Keeper_meta_store.current_meta_rejection
  | Metadata_missing
  | Metadata_owner_mismatch
  | Profile_rejected of string
  | Keeper_paused
  | Snapshot_lookup_failed of Config_dir_resolver.canonical_base_path_error
  | Snapshot_missing
  | Snapshot_rejected of Skill_catalog_snapshot.config_state
  | Runtime_failed of string
  | Original_activation_unavailable of Keeper_composition_draft.error
  | Original_task_skills_unavailable of Keeper_task_skill_turn.error

val error_to_string : error -> string

type recovery_hold =
  | Original_run_unavailable of Keeper_composition_draft.error
  | Task_skill_publication_unavailable of
      { error : Keeper_task_skill_turn.error
      ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
      }
  | Explicit_recovery_required of string
(** Pre-intake original evidence can be revalidated after exact run restoration
    or a changed published Skill projection. Surface/worker holds require
    explicit recovery: their diagnostic text is never a retry decision. *)

val recovery_hold_to_string : recovery_hold -> string
val resume :
  ?on_recovery_held:(request_id:string -> cause:recovery_hold -> unit) ->
  context:'a Keeper_types_profile.context ->
  Keeper_tool_execution_journal.continuation -> (Tool_result.result, error) result
(** Strictly resolve current declarations (including name/duplicate ownership),
    metadata, published Skill snapshot and authorized lane descriptors, then use
    the original typed continuation intake. Unavailable original activation or
    task Skill evidence reports [on_recovery_held] for the sealed request before
    worker admission, just as the worker's original-authority checks do. No
    provider call, current Task inference or reconstructed plan. Explicit resume
    captures a new declaration projection through the common I/O executor;
    it never borrows a maintenance pulse's projection. *)

type 'a t constraint 'a = [> float Eio.Time.clock_ty ]
val create :
  context:'a Keeper_types_profile.context ->
  ?on_result:(Keeper_tool_execution_journal.continuation ->
    (Tool_result.result, error) result -> unit) ->
  ?on_discovery:(base_path:string ->
    (unit, Keeper_tool_execution_journal.error) result -> unit) -> unit -> 'a t
(** [on_discovery] receives each actual discovery/intake-reservation result with
    its original base path. [Ok ()] means the pass returned, not that every
    marker was readable, intake finished or its DAG completed. Partial failures
    keep their original diagnostics. The default observer logs whole-pass errors.
    Ordinary observer failure cannot undo admission or consume new demand.

    Default supervisor discovery/recovery diagnostics include the original
    workspace base path, including existing failure/interruption records.
    Routine phase formatting remains lazy; existing other logging levels and
    frequency remain. Added quoted-path bytes/formatting are observation cost,
    not delivery authority or measured execution progress. *)
val pulse : sw:Eio.Switch.t -> 'a t -> unit
(** Record maintenance demand in the controller's switch-owned discovery drain
    and return without joining discovery or intake. The discovery child yields
    before its first pass. Maintenance and result-ready notifications share one
    drain: demand before a pass shares it, demand during discovery or observation
    requests a fresh subsequent pass. Maintenance promotes pending result hints
    to a full pass. Each pass obtains its own lazy declarations.
    No cached discovery/profile or execution permission is introduced.

    Within a pass, schedule each validated ready-run intake before inspecting
    later pending names. Each intake child yields
    inside its reservation cleanup before held-evidence probes, declaration
    acquisition or original intake. Discovery runs in the drain child and
    may yield to intakes before the full scan finishes; directory listing
    still completes first. A late discovery failure can coexist with earlier
    reserved workers; their exact admission and switch cleanup remain in force.
    Active intake and workers reporting held original authority suppress
    repeated automatic attempts for that exact canonical request. Before another
    intake, read-only probes can release [Original_run_unavailable] when its exact
    sealed run reads again, or [Task_skill_publication_unavailable] when a different
    configured Skill snapshot is published. Release only requests fresh original
    validation; it grants no effect authority. [Explicit_recovery_required] stays
    held until public recovery or a changed request owner. A new controller can
    retry intake. Holds are process-local
    scheduling hints, never durable effect authority. Exact durable owner/node
    CAS still admits the worker. Eligible intakes in one discovery pass share one immutable
    declaration projection, acquired on first demand through the common I/O
    executor. A pass containing only active candidates or unreleased holds performs no
    declaration read. A later pass captures anew; metadata, Skill publication,
    original evidence and admission remain per intake. Cancelled acquisition may
    restart for a remaining caller after worker cleanup. Single-domain Eio caller.
    No timer, freshness interval or timeout. Check the supplied lifetime switch
    before recording demand, discovery admission and each active-run reservation.
    The drain stays active through observation and cancellation cleanup. Failed
    scheduling releases its reservation; cancellation is not a journal error.
    Physical I/O can still delay shutdown. Draining demand does not prove intake
    completion or physical DAG worker exit. *)

val notify_result_ready :
  sw:Eio.Switch.t -> 'a t -> Keeper_tool_execution_journal.result_notification -> unit
(** Nonblocking lifecycle hint carrying the original canonical workspace,
    Keeper and typed job/composition dependency after its result is durable.
    Uses the same drain as maintenance [pulse]; callers only record demand. New
    workers yield back to producers before discovery. Notifications before the
    first read share their result scope; notifications during a read or its
    observation request a fresh subsequent pass. A maintenance pulse promotes
    pending hints to full discovery. Every pass retains marker/journal/terminal
    checks; only selected continuations re-read result dependencies. Original
    Lost work without dependencies remains included. Unrelated dependencies are
    not probed until maintenance, and are reported as unselected, not waiting.
    Hints are immutable pass demand, never a cached candidate or permission.
    Duplicate hints share a pass but remain in its temporary demand list. A
    local immutable key index deduplicates matching; its construction and lookups
    remain preparation cost. No imposed cap or cross-pass index reuse.
    Cancellation/exception cleanup retires only this discovery drain;
    durable discovery and later maintenance remain the recovery source.
    Observations distinguish maintenance/result demand, actual starts/returns,
    errors/raised passes, interruption and drain boundary; counts are not limits,
    job counts, effect success or worker-exit proof.
    Single-domain Eio caller, using the controller's lifetime switch. *)

module For_testing : sig
  val notify_result_ready :
    resume:(on_recovery_held:(request_id:string -> cause:recovery_hold -> unit) ->
      profiles:Keeper_types_profile.keeper_profile_snapshot ->
      context:'a Keeper_types_profile.context ->
      Keeper_tool_execution_journal.continuation -> (Tool_result.result, error) result) ->
    sw:Eio.Switch.t -> 'a t -> Keeper_tool_execution_journal.result_notification -> unit
  (** Same notification scheduling and canonical discovery as production,
      with only the original intake outcome controlled. *)
  val pulse :
    resume:(on_recovery_held:(request_id:string -> cause:recovery_hold -> unit) ->
      profiles:Keeper_types_profile.keeper_profile_snapshot ->
      context:'a Keeper_types_profile.context ->
      Keeper_tool_execution_journal.continuation -> (Tool_result.result, error) result) ->
    sw:Eio.Switch.t -> 'a t -> unit
  (** Use canonical discovery, declaration reads and the production scheduler
      with a controlled intake outcome. The callback receives the same immutable
      projection as production intake. Maintenance and notifications use the
      same drain; the first admitted resume callback owns that drain's passes.
      No journal, request or backend state is fabricated. *)
end
