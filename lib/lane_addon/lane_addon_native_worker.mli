(** Live ownership of a host-process Addon. Uses the shared MCP protocol and
    an owned foreground process group; makes no container isolation claim.
    Requires durable admission before scheduling. Descendants leaving the group are outside
    its release receipt and need their package's explicit resource cleanup. *)
type command = { executable : string; arguments : string list }
type release = {
  instance_id : string;
  pid : int;
  started : string option;
  exit_status : Eio.Process.exit_status;
}
type error = Invalid_specification of string | Start_failed of string
  | Admission of Native_addon_lease.error
  | Protocol of Lane_addon_worker_protocol.error | Cleanup_unconfirmed of string
  | Stopped
val error_to_string : error -> string
type t
type phase = Initializing | Validating_owner | Serving | Retired
val phase : t -> phase
val host_requests : t -> (Yojson.Safe.t, error) result
val host_result : t -> arguments:Yojson.Safe.t -> (Yojson.Safe.t, error) result
val process_identity : t -> Lane_addon_lifecycle.resource option
(** The actual connected child, available before discovery; not signal authority. *)
val start : sw:Eio.Switch.t -> clock:_ Eio.Time.clock ->
  grace_seconds:float -> admission:Native_addon_lease.t -> launcher:string ->
  contract:Lane_addon_worker_protocol.contract -> command:command ->
  ?cwd:Eio.Fs.dir_ty Eio.Path.t -> ?env:string array ->
  ?artifact_store:Lane_addon_store.t ->
  ?on_created:(t -> (unit, string) result) -> unit -> (t, error) result
(** The switch belongs to the host owner, not a Keeper turn. Calls are admitted
    only after discovery and exact kernel-owner validation succeed. Instance ID
    comes from [admission]; [launcher] is the trusted installed host executable.
    Scheduling transfers this claim to one host owner; before scheduling, errors
    or cancellation leave retirement to the caller. [on_created] runs before discovery and can
    retain this exact handle or request stop while initialization is blocked.
    Cancellation of startup or an operation requests background cleanup and
    propagates. No retry.
    Call and lifecycle operations run on the host owner's Eio domain. *)
val request_stop : t -> unit
(** Non-blocking revocation and stop request, including from [on_created]. *)
val stop : t -> (release, error) result
(** Revoke first, then terminate/reap the owned group. A release is returned
    only after exact child exit, durable retirement and admission settlement.
    Retirement and owned-group cleanup run concurrently so a launcher holding
    its gates cannot prevent its own termination. Neither alone proves release.
    Repeated calls await the same child completion, then retry idempotent
    retirement of this exact admission and reread settlement. A failed durable
    write is not a permanent child-cleanup result. No command is restarted. *)
val release : t -> (release, error) result option
(** A confirmed receipt remains evidence for this original incarnation after
    replacement. An exited child with unconfirmed retirement remains retryable
    through this same handle. Pending checks may yield for kernel/file writes
    and observations; they never admit a new execution. *)
val exported_tools : t -> Mcp_protocol.Mcp_types.tool list
val action_schema : t -> Yojson.Safe.t option
val observe : t -> binding:Yojson.Safe.t -> sources:Yojson.Safe.t ->
  (Lane_addon_types.output, error) result
val act : t -> arguments:Yojson.Safe.t -> (Lane_addon_action.package_result, error) result
val call_exported_tool : ?on_result:(Mcp_protocol.Mcp_types.tool_result -> unit) ->
  ?authorize:Lane_addon_call_context.mediation ->
  ?principal:Lane_addon_call_context.principal -> t -> name:string ->
  arguments:Yojson.Safe.t -> (Mcp_protocol.Mcp_types.tool_result, error) result
