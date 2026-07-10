
(** Public facade for keeper MCP tools. *)

type 'a context = 'a Keeper_types_profile.context = {
  config : Workspace.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
}

type tool_result = Keeper_types_profile.tool_result

val schemas : Masc_domain.tool_schema list

val dispatch :
  ?continuation_channel:Keeper_continuation_channel.t ->
  _ context -> name:string -> args:Yojson.Safe.t -> tool_result option

module For_testing : sig
  val reset_keeper_list_cache : unit -> unit
  val invalidate_keeper_list_cache : unit -> unit

  val cached_keeper_list_text :
    key:string -> ttl_s:float -> (unit -> string) -> string
end

(** Streaming dispatch: handles keeper_msg with real-time text delta callback.
    The [on_text_delta] callback receives each text fragment from the MODEL
    as it arrives. Returns [None] for tool names other than [masc_keeper_msg].

    @since 2.110.0 *)
val dispatch_stream :
  ?on_text_delta:(string -> unit) ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  _ context -> name:string -> args:Yojson.Safe.t -> tool_result option
