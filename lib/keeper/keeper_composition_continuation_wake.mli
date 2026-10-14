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

val error_to_string : error -> string
val resume :
  context:'a Keeper_types_profile.context ->
  Keeper_tool_execution_journal.continuation -> (Tool_result.result, error) result
(** Strictly resolve current declarations (including name/duplicate ownership),
    metadata, published Skill snapshot and authorized lane descriptors, then use
    the original typed continuation intake. No
    provider call, current Task inference or reconstructed plan. *)

type 'a t constraint 'a = [> float Eio.Time.clock_ty ]
val create :
  context:'a Keeper_types_profile.context ->
  ?on_result:(Keeper_tool_execution_journal.continuation ->
    (Tool_result.result, error) result -> unit) -> unit -> 'a t
val pulse : sw:Eio.Switch.t -> 'a t -> (unit, Keeper_tool_execution_journal.error) result
(** Schedule independent ready-run intake fibers and return without joining
    them. The active set suppresses duplicate live intake only. Exact durable
    owner/node CAS still admits the worker. Single-domain Eio caller. No timer,
    timeout or retry cap. *)
