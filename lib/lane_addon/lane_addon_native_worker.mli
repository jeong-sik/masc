(** Live ownership of a host-process Addon. Uses the shared MCP protocol and
    an owned foreground process group; makes no container isolation claim.
    Caller admission and durable slot/restart recovery remain separate from
    this live handle. Descendants deliberately leaving the group are outside
    its release receipt and need their package's explicit resource cleanup. *)
type command = { executable : string; arguments : string list }
type release = {
  instance_id : string;
  pid : int;
  started : string option;
  exit_status : Eio.Process.exit_status;
}
type error = Invalid_specification of string | Start_failed of string
  | Protocol of Lane_addon_worker_protocol.error | Cleanup_unconfirmed of string
  | Stopped
type t
val start : sw:Eio.Switch.t -> clock:_ Eio.Time.clock ->
  grace_seconds:float -> instance_id:string ->
  contract:Lane_addon_worker_protocol.contract -> command:command ->
  ?cwd:Eio.Fs.dir_ty Eio.Path.t -> ?env:string array ->
  ?artifact_store:Lane_addon_store.t ->
  ?on_created:(t -> (unit, string) result) -> unit -> (t, error) result
(** The switch belongs to the host owner, not a Keeper turn. Calls are admitted
    only after discovery succeeds. [on_created] runs before discovery and can
    retain this exact handle or request stop while initialization is blocked.
    Cancellation of startup or an operation requests background cleanup and
    propagates. No retry.
    Call and lifecycle operations run on the host owner's Eio domain. *)
val request_stop : t -> unit
(** Non-blocking revocation and stop request, including from [on_created]. *)
val stop : t -> (release, error) result
(** Revoke first, then terminate/reap the owned group. A release is returned
    only after the exact child exit and an observed empty process group.
    Repeated calls await the same completion; they never restart a command. *)
val release : t -> (release, error) result option
val exported_tools : t -> Mcp_protocol.Mcp_types.tool list
val observe : t -> binding:Yojson.Safe.t -> sources:Yojson.Safe.t ->
  (Lane_addon_types.output, error) result
val act : t -> arguments:Yojson.Safe.t -> (Lane_addon_action.package_result, error) result
val call_exported_tool : ?on_result:(Mcp_protocol.Mcp_types.tool_result -> unit) ->
  ?authorize:Lane_addon_call_context.mediation ->
  ?principal:Lane_addon_call_context.principal -> t -> name:string ->
  arguments:Yojson.Safe.t -> (Mcp_protocol.Mcp_types.tool_result, error) result
