(** Private declared reader producer. Called on the admitted Keeper turn's
    owning fiber under the existing workspace process lease and serialized
    Keeper turn; this module does not acquire a replacement authority. *)
type t
type error = Keeper_media_reading.external_failure
val error_to_string : error -> string

val create :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  media_store:Agent_core.History.media_store ->
  declarations:Runtime_schema.media_reader_decl list option ->
  causal_context:Keeper_gate.causal_context option ->
  continuation_channel:Keeper_continuation_channel.t option -> unit -> t
(** Freeze these admitted turn values and the existing per-call Io timeout.
    No endpoint, original, approval, reader or replacement factory is created.
    The supplied declarations are a snapshot, never a Runtime lookup closure. *)

val observe : t -> Keeper_media_reading.source_reader
(** Inspect all originals for this exact Stored subject before selection or
    cache use. Never submit, append progress, acquire an endpoint or invoke a
    reader. Pending outcomes preserve all per-original observations. *)
val read : t -> Keeper_media_reading.source_reader
(** The same inventory-first boundary, with authority to retain and run the
    one selected declaration. Existing unknown/denied work never authorizes
    redispatch. Proven Request_not_sent closes that invocation and may permit
    a fresh original/Gate in a later turn, never reuse of the same invocation.
    Returned SDK bytes are retained before interpretation or channel close;
    actual transport evidence is retained separately on the same original. *)

val replay :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  grant:Keeper_gate.cycle_grant -> approval_id:string ->
  input:Yojson.Safe.t -> (Keeper_tool_execution.t, error) result
(** Validate the approved input against the retained original and exact queue
    identity, recreate and compare its current declaration/launch, and require
    Allow from this same one-shot resolution. The original's context/channel
    are used. No policy fallback can spend a stale grant. Errors require
    retention/owner repair and must not be settled as a terminal Gate result.
    A retained SDK adapter failure is [Ok] with a failed execution and its
    private retained artifacts. After channel cleanup, finish retention of
    the same in-memory reply/transport without another RPC. If this still
    fails, an unpersisted reply has no recovery guarantee after this call
    returns or the process exits. No global buffer registry is created.
    Cancellation propagates. *)

val recover_reply :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  approval_id:string -> input:Yojson.Safe.t ->
  (Keeper_tool_execution.t option, error) result
(** Strictly read the approved identity, original, reply and actual transport
    facts. No Runtime declaration, factory, Gate decision or RPC. [None] is
    unknown, never permission to execute. A linked missing/corrupt blob is an
    error. The returned execution retains private artifact roots without
    making them model artifacts or claiming a successful process exit. *)

module For_testing : sig
  val create :
    endpoint:(unit -> (Keeper_sandbox_remote.t, string) result) ->
    ?retain_original:(store:Lane_addon_store.t -> Keeper_media_reading_original.t ->
      (Keeper_media_reading_owner.retained, Keeper_media_reading_owner.error) result) ->
    config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
    turn_sandbox_factory:Keeper_sandbox_factory.t option ->
    media_store:Agent_core.History.media_store ->
    declarations:Runtime_schema.media_reader_decl list option ->
    causal_context:Keeper_gate.causal_context option ->
    continuation_channel:Keeper_continuation_channel.t option -> unit -> t
  (** The production path with endpoint resolution and the actual original
      retention call replaceable. Gate, Channel, transport, blob publication
      and original validation are unchanged. *)
end
