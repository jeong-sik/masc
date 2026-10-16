(** Canonical named-composition result reads, without submission or collection. *)
type readiness = Keeper_composition_dependency.readiness = Waiting | Ready
val readiness :
  base_path:string -> keeper_name:string -> Keeper_composition_dependency.composition ->
  (readiness, string) result
(** Ready requires a matching original source and canonical durable terminal;
    terminal failure/cancellation is ready for a typed failure read too. *)

val handle :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t -> Keeper_tool_execution.t
(** Pending work returns the producer-owned exact dependency. Only successful
    canonical named-composition results provide composable exports. *)

module For_testing : sig
  val handle :
    after_owner_read:(Keeper_msg_async.entry -> unit) ->
    config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
    args:Yojson.Safe.t -> Keeper_tool_execution.t
  (** Interleave an actual successor after the canonical owner observation.
      The same result handler must reobserve a changed logical owner. *)
end
