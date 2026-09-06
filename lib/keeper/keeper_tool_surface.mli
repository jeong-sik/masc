
(** Public keeper MCP tools. *)

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
  ?invocation_ref:Tool_invocation_ref.t ->
  _ context ->
  name:string ->
  args:Yojson.Safe.t ->
  tool_result option

(** Internal async-message entry point for adapters whose authenticated
    submission principal differs from the target turn's [ctx.agent_name].
    [submitted_by] is trusted boundary context, never model input. *)
val dispatch_keeper_msg
  :  submitted_by:string
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> _ context
  -> message:Keeper_invocation_contract.direct_message
  -> tool_result

module For_testing : sig
  val reset_keeper_list_cache : unit -> unit

end

val dispatch_keeper_msg_stream_admitted :
  admission_token:Keeper_turn_dispatch_authority.token ->
  ?on_text_delta:(string -> unit) ->
  ?on_event:(Agent_core.Types.sse_event -> unit) ->
  ?on_tool_stream_observation:
    (Keeper_hooks_agent_core.tool_stream_observation -> unit) ->
  ?on_tool_result_ready:(tool_call_id:string -> turn:int -> planned_index:int -> execution_id:Ids.Execution_id.t -> unit) ->
  ?approval_gate:Keeper_tool_approval_gate.t ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  _ context ->
  message:Keeper_invocation_contract.direct_message ->
  tool_result option
