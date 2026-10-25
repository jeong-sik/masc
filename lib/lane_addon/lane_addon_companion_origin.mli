(** Original Keeper invocation retained before issuing a companion grant.
    This records ownership; it neither delivers a wake nor certifies a login. *)
type error = Invalid_source | Binding_conflict | Corrupt | Unavailable | Commit_unconfirmed
val error_to_string : error -> string

type source = private {
  keeper_name : string;
  turn_ref : Ids.Turn_ref.t;
  tool_use_id : string;
  task_id : string option;
  channel : Keeper_continuation_channel.t;
}
val source : keeper_name:string -> turn_ref:Ids.Turn_ref.t option ->
  tool_use_id:string option -> trace_id:string option ->
  source_context:Keeper_tool_call_log_context.turn_context option ->
  channel:Keeper_continuation_channel.t option -> (source, error) result
(** Missing original turn/tool identity or contradictory observed coordinates
    refuse. Task identity comes only from this call's immutable source context.
    An observed Keeper name must agree with [keeper_name].
    Missing conversation routing stays explicitly unrouted. *)

type destination = {
  instance_id : string;
  package_id : string;
  package_revision : string;
  tool : string;
  declaration_id : string option;
  configuration_revision : string option;
}
type record = private {
  id : string;
  base_path : string;
  source : source;
  destination : destination;
  arguments_sha256 : string;
}
type reservation = Fresh of record | Existing of record
val reserve : fs:Eio.Fs.dir_ty Eio.Path.t ->
  config:Workspace.config -> source:source -> destination:destination ->
  arguments:Yojson.Safe.t -> (reservation, error) result
(** The exact Keeper/turn/tool-use tuple chooses the immutable original key.
    Preserve source, route, destination and input digest before dispatch.
    [Existing] is read/reconciliation evidence and never permits another grant.
    Only this call's successful durable exclusive creation can return [Fresh].
    Existing empty or incomplete files refuse; they never become fresh again.
    A concurrent first writer may still be publishing, in which case strict
    reconciliation refuses instead of waiting or replaying its invocation.
    Setup, locking and strict private-file durability use the existing host
    filesystem boundary. Capabilities and private Browser arguments are absent. *)
val lookup : config:Workspace.config -> source:source -> (record option, error) result
(** Strict read of that original key. No directory, binding or effect is created.
    A changed source or workspace cannot borrow an existing record. *)
