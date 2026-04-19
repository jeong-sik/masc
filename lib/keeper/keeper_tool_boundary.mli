(** Boundary for calling keeper tools from non-keeper entrypoints.

    This module owns conversion into {!Tool_keeper.context} so server/tool
    dispatch code does not need to know keeper runtime context internals. *)

type 'a context = {
  config : Coord.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
}

val create :
  config:Coord.config ->
  agent_name:string ->
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option ->
  'a context

val dispatch :
  _ context -> name:string -> args:Yojson.Safe.t -> Keeper_types.tool_result option

val dispatch_stream :
  on_text_delta:(string -> unit) ->
  _ context ->
  name:string ->
  args:Yojson.Safe.t ->
  Keeper_types.tool_result option
