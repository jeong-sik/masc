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
val resume :
  ?on_recovery_held:(request_id:string -> reason:string -> unit) ->
  context:'a Keeper_types_profile.context ->
  Keeper_tool_execution_journal.continuation -> (Tool_result.result, error) result
(** Strictly resolve current declarations (including name/duplicate ownership),
    metadata, published Skill snapshot and authorized lane descriptors, then use
    the original typed continuation intake. Unavailable original activation or
    task Skill evidence reports [on_recovery_held] for the sealed request before
    worker admission, just as the worker's original-authority checks do. No
    provider call, current Task inference or reconstructed plan. *)

type 'a t constraint 'a = [> float Eio.Time.clock_ty ]
val create :
  context:'a Keeper_types_profile.context ->
  ?on_result:(Keeper_tool_execution_journal.continuation ->
    (Tool_result.result, error) result -> unit) -> unit -> 'a t
val pulse : sw:Eio.Switch.t -> 'a t -> (unit, Keeper_tool_execution_journal.error) result
(** Schedule independent ready-run intake fibers and return without joining
    them. Active intake and workers reporting held original authority suppress
    repeated automatic attempts for that exact canonical request. Explicit
    public resume or a new controller may retry after authority is repaired;
    a changed request owner is re-admitted normally. Holds are process-local
    scheduling hints, never durable effect authority. Exact durable owner/node
    CAS still admits the worker. Single-domain Eio caller. No timer or timeout. *)

module For_testing : sig
  val pulse :
    resume:(on_recovery_held:(request_id:string -> reason:string -> unit) ->
      context:'a Keeper_types_profile.context ->
      Keeper_tool_execution_journal.continuation -> (Tool_result.result, error) result) ->
    sw:Eio.Switch.t -> 'a t -> (unit, Keeper_tool_execution_journal.error) result
  (** Use canonical discovery and the production scheduler with a controlled
      intake outcome. No journal, request or backend state is fabricated. *)
end
