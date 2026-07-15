(** Boundary for calling keeper tools from non-keeper entrypoints.

    This module owns conversion into {!Keeper_tool_surface.context} so server/tool
    dispatch code does not need to know keeper runtime context internals. *)

type 'a context = {
  config : Workspace.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
  publication_recovery_provider :
    Keeper_publication_recovery_availability.provider;
}

val create :
  config:Workspace.config ->
  agent_name:string ->
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option ->
  publication_recovery_provider:
    Keeper_publication_recovery_availability.provider ->
  'a context

val dispatch :
  _ context -> name:string -> args:Yojson.Safe.t -> Keeper_types_profile.tool_result option

val delegated_dispatch :
  config:Workspace.config ->
  agent_name:string ->
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option ->
  publication_recovery_provider:
    Keeper_publication_recovery_availability.provider ->
  name:string ->
  args:Yojson.Safe.t ->
  Keeper_types_profile.tool_result option
