(** Durable content-addressed store for {!Keeper_plan_proposal}. *)

module Proposal = Keeper_plan_proposal

type save_result =
  | Stored
  | Already_present

type error =
  | Invalid_proposal of Proposal.error
  | Invalid_proposal_id of string
  | Proposal_not_found of Proposal.Proposal_id.t
  | Tampered_existing_file of Proposal.Proposal_id.t
  | Read_failed of Fs_compat.owned_regular_file_read_error
  | Directory_prepare_failed of Keeper_fs_durable_directory.failure
  | Capability_filesystem_unavailable
  | Exclusive_write_failed of Fs_compat.capability_write_error

val store_dir : Workspace.config -> string
val proposal_path : Workspace.config -> Proposal.Proposal_id.t -> string

val save : Workspace.config -> Proposal.t -> (save_result, error) result

val load
  :  descriptors:Keeper_tool_descriptor.t list
  -> Workspace.config
  -> Proposal.Proposal_id.t
  -> (Proposal.t, error) result

val load_string_id
  :  descriptors:Keeper_tool_descriptor.t list
  -> Workspace.config
  -> string
  -> (Proposal.t, error) result

val error_to_yojson : error -> Yojson.Safe.t

module For_testing : sig
  val save_after_absence_observed
    :  before_exclusive_create:(path:string -> unit)
    -> Workspace.config
    -> Proposal.t
    -> (save_result, error) result
end
