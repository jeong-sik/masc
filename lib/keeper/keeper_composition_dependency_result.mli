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

val read :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t -> (Keeper_tool_execution.t, Keeper_tool_execution.t) result
(** [Ok] is an authoritative canonical observation, including a genuinely
    failed child. [Error] means observation or result publication is unavailable;
    its execution keeps the original tool disposition and failure class.
    Neither case grants submission or replay authority. *)

module For_testing : sig
  val read :
    after_owner_read:(Keeper_msg_async.entry -> unit) ->
    before_manifest_publication:(unit -> unit) ->
    config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
    args:Yojson.Safe.t -> (Keeper_tool_execution.t, Keeper_tool_execution.t) result
  (** Fault the actual outer publication after the canonical observation and
      inner result artifact, without fabricating a reader failure. *)
  val handle :
    after_owner_read:(Keeper_msg_async.entry -> unit) ->
    config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
    args:Yojson.Safe.t -> Keeper_tool_execution.t
  (** Interleave an actual successor after the canonical owner observation.
      The same result handler must reobserve a changed logical owner. *)
end
