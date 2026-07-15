
(** Public facade for keeper MCP tools. *)

type 'a context = 'a Keeper_types_profile.context = {
  config : Workspace.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
  publication_recovery_provider :
    Keeper_publication_recovery_availability.provider;
}

type tool_result = Keeper_types_profile.tool_result

val schemas : Masc_domain.tool_schema list

val dispatch :
  ?continuation_channel:Keeper_continuation_channel.t ->
  _ context -> name:string -> args:Yojson.Safe.t -> tool_result option

(** Internal async-message entry point for adapters whose authenticated
    submission principal differs from the target turn's [ctx.agent_name].
    [submitted_by] is trusted boundary context, never model input. *)
val dispatch_keeper_msg
  :  submitted_by:string
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> _ context
  -> args:Yojson.Safe.t
  -> tool_result

module For_testing : sig
  val reset_keeper_list_cache : unit -> unit
  val invalidate_keeper_list_cache : unit -> unit

  val cached_keeper_list_data :
    key:string -> ttl_s:float -> (unit -> Yojson.Safe.t) -> Yojson.Safe.t
end

(** Streaming dispatch: handles keeper_msg with real-time text delta callback.
    The [on_text_delta] callback receives each text fragment from the MODEL
    as it arrives. Returns [None] for tool names other than [masc_keeper_msg].

    @since 2.110.0 *)
val dispatch_stream :
  ?on_text_delta:(string -> unit) ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?on_admission_rejected:(Keeper_turn_admission.rejection -> unit) ->
  ?on_admitted:(unit -> (unit, string) result) ->
  _ context -> name:string -> args:Yojson.Safe.t -> tool_result option

(** Non-blocking streaming dispatch for direct chat admission. The Keeper turn
    slot performs the authoritative post-lock durable-queue recheck; [`Busy]
    callers must route the accepted message to their deferred transport. *)
val dispatch_stream_if_free :
  ?on_text_delta:(string -> unit) ->
  ?on_event:(Agent_sdk.Types.sse_event -> unit) ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  _ context ->
  name:string ->
  args:Yojson.Safe.t ->
  [ `Ran of tool_result option | `Busy of Keeper_turn_admission.rejection ]
