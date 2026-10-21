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
    (Tool_result.result, error) result -> unit) -> unit -> 'a t
val pulse : sw:Eio.Switch.t -> 'a t -> (unit, Keeper_tool_execution_journal.error) result
(** Schedule each validated ready-run intake before inspecting later pending
    names and return without joining the intake workers. Each child yields
    inside its reservation cleanup before held-evidence probes, declaration
    acquisition or original intake. Discovery still runs in the caller and
    may yield to children before the full scan finishes; directory listing
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
    CAS still admits the worker. Eligible intakes in one pulse share one immutable
    declaration projection, acquired on first demand through the common I/O
    executor. A pulse containing only active candidates or unreleased holds performs no
    declaration read. A later pulse captures anew; metadata, Skill publication,
    original evidence and admission remain per intake. Cancelled acquisition may
    restart for a remaining caller after worker cleanup. Single-domain Eio caller.
    No timer, freshness interval or timeout. A cancelled/finished switch is
    rejected before discovery and each new active-run reservation; a declined
    [fork] cannot leave an original run falsely active. Cancellation is not a
    journal error. *)

val notify_result_ready : sw:Eio.Switch.t -> 'a t -> unit
(** Nonblocking lifecycle hint after an original job result is durable. New
    notification workers yield back to producers before discovery; callers
    only record demand. Notifications before the first read share
    that read, and notifications during a read request one subsequent fresh
    pulse. No timer, authority, cached discovery/profile or worker replacement
    is introduced. Explicit maintenance [pulse] remains independent.
    Cancellation/exception cleanup retires only this notification worker;
    durable discovery and later maintenance remain the recovery source.
    Debug observations retain callback count, discovery starts/settlements/errors
    and the drain boundary, not job counts, effect success or worker-exit proof.
    Single-domain Eio caller, using the controller's lifetime switch. *)

module For_testing : sig
  val notify_result_ready :
    resume:(on_recovery_held:(request_id:string -> cause:recovery_hold -> unit) ->
      profiles:Keeper_types_profile.keeper_profile_snapshot ->
      context:'a Keeper_types_profile.context ->
      Keeper_tool_execution_journal.continuation -> (Tool_result.result, error) result) ->
    sw:Eio.Switch.t -> 'a t -> unit
  (** Same notification scheduling and canonical discovery as production,
      with only the original intake outcome controlled. *)
  val pulse :
    resume:(on_recovery_held:(request_id:string -> cause:recovery_hold -> unit) ->
      profiles:Keeper_types_profile.keeper_profile_snapshot ->
      context:'a Keeper_types_profile.context ->
      Keeper_tool_execution_journal.continuation -> (Tool_result.result, error) result) ->
    sw:Eio.Switch.t -> 'a t -> (unit, Keeper_tool_execution_journal.error) result
  (** Use canonical discovery, declaration reads and the production scheduler
      with a controlled intake outcome. The callback receives the same immutable
      projection as production intake. No journal, request or backend state is
      fabricated. *)
end
