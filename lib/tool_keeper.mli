(** Public facade for keeper MCP tools. *)

type 'a context = 'a Keeper_types.context = {
  config : Coord.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
}

type tool_result = Keeper_types.tool_result

val schemas : Types.tool_schema list

val dispatch :
  _ context -> name:string -> args:Yojson.Safe.t -> tool_result option

(** Streaming dispatch: handles keeper_msg with real-time text delta callback.
    The [on_text_delta] callback receives each text fragment from the MODEL
    as it arrives. Returns [None] for tool names other than [masc_keeper_msg].

    @since 2.110.0 *)
val dispatch_stream :
  on_text_delta:(string -> unit) ->
  _ context -> name:string -> args:Yojson.Safe.t -> tool_result option
