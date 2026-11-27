(** Keeper dispatch dependency inversion ref.

    Same pattern as [Workspace_dispatch_ref].
    [Keeper_tool_surface] lives in lib/ (late in module order) but is the
    natural home of keeper workspace tools.  Importing it from
    [Keeper_tool_in_process_runtime] (early in lib/keeper) would close
    a cycle.

    Resolution: register ctx-free entry points from [Keeper_tool_surface] into
    the ref at module load.  [Keeper_tool_in_process_runtime] reads the
    ref at dispatch time.

    The [~caller] parameter is the Keeper whose own turn makes the call
    ({!Turn_caller}). Its name lets tools like [masc_keeper_status] that
    fall back to "self" when the [name] arg is empty resolve the right
    target, and it is what makes a masc_keeper_msg or masc_keeper_delegate
    sent from here count as that Keeper's.

    The optional Eio resource params [?sw] / [?clock] / [?proc_mgr] /
    [?net] / [?mcp_session_id] serve Eio-bound tools such as
    [masc_keeper_msg] and [masc_keeper_up].
    [publication_recovery_provider] is a read-only projection of the runtime's
    live publication-recovery SSOT. Nested Keeper turns re-read it rather than
    inheriting the caller turn's capability snapshot. Existing registrations
    accept and ignore the optional Eio resources. The trailing
    [unit] argument is required so the OCaml compiler can determine
    when the optional defaults apply. *)

type external_effect_authorizer =
  operation:string ->
  input:Yojson.Safe.t ->
  continue:(unit -> Tool_result.result option) ->
  Tool_result.result option
(** Caller-owned boundary injected into concrete effect handlers. A handler
    that performs an external effect invokes this callback with its exact
    operation and complete input; read-only handlers do not invoke it. *)

(* HIGH-RISK-UNREVIEWED: the Keeper whose own running turn makes a Keeper
   tool call. A request that turn submits through masc_keeper_msg or
   masc_keeper_delegate is Keeper work, and the recipient's turn runs without
   the tool approval gate, as an autonomous cycle does (#55029).

   The in-process tool runtime makes one from the meta of the turn it runs
   ([Keeper_tool_in_process_runtime.handle_masc_keeper_with_outcome]); no
   other production code makes one. A caller that reaches Keeper tools over
   MCP or an HTTP route names itself with a string: MCP adopts the request's
   [_agent_name] / [agent_name], and with auth off, with no token required,
   or with the internal Keeper token and the [x-masc-keeper-name] header its
   holder chooses, nothing binds that name to the caller. A string has no way
   into this type, so whatever name such a caller gives, even a registered
   Keeper's, its request keeps the gate. *)
module Turn_caller : sig
  type t

  val of_running_turn : Keeper_meta_contract.keeper_meta -> t
  (** The Keeper of the turn [meta] belongs to. Call it only with the meta of
      a turn the calling code is running; a meta read from the store for a
      name somebody supplied is not one. *)

  val keeper_name : t -> string

  val sender : t -> Keeper_identity.Keeper_id.t option
  (** The sender Keeper a request from this turn is recorded under. [None]
      for a blank name, which leaves the request with the gate. *)
end

val dispatch
  : (config:Workspace.config
     -> caller:Turn_caller.t
     -> publication_recovery_provider:
          Keeper_publication_recovery_availability.provider
     -> ?sw:Eio.Switch.t
     -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
     -> ?proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
     -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
     -> ?mcp_session_id:string
     -> ?authorize_external_effect:external_effect_authorizer
     -> name:string
     -> args:Yojson.Safe.t
     -> unit
     -> Tool_result.result option)
      ref
