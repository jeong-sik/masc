(** One official-client candidate attempt as the lane walk receives it.

    The four official-client adapters (Antigravity, Claude Code, Codex, Muse)
    return this one outcome and record into this one effect cell. What makes a
    client's reading an effect stays in its adapter; how readings combine is
    decided here. *)

type outcome =
  { result : (Runtime_agent.run_result, Agent_core.Error.t) result
  ; settled_session : Keeper_official_client_session_store.t option
  ; pending_result_receipts : Keeper_client_tool_outbox.consumption option
      (** [Some] names exact receipt snapshots of a durably settled candidate,
          not acceptance. [None] carries no authority on failed/prevalidation
          results. The caller accepts first, then settles with its final stop reason. *)
  ; effect_disposition : Keeper_provider_attempt_effect.t
  }

val refused_before_dispatch : Agent_core.Error.t -> outcome
(** An attempt that ended before the client was reached: no settled session,
    no receipts, and [No_effect_observed]. *)

module Effect_cell : sig
  type t
  (** The effect reading of one attempt. It starts at [No_effect_observed]. *)

  val create : unit -> t

  val attempted : t -> unit
  (** An effect-capable handler was entered. This replaces any weaker
      reading. *)

  val unobserved : t -> unit
  (** Effects may have run out of MASC's sight. Only [No_effect_observed]
      moves, to [Observation_unavailable]; [Effect_attempted] stays. *)

  val quiet : t -> unit
  (** The client's own durable record shows it did nothing outside its
      session. Only [Observation_unavailable] moves, back to
      [No_effect_observed]; [Effect_attempted] stays. *)

  val read : t -> Keeper_provider_attempt_effect.t
end

val fence_effect_capable_call :
  observe_effect_attempted:(unit -> unit) ->
  Keeper_official_client_host.dynamic_tool ->
  Keeper_official_client_host.dynamic_tool
(** The tool every official client calls MASC through. Entering it for an
    input its producer declares [Effect_possible] calls
    [observe_effect_attempted] before the handler runs: the handler may commit
    and then raise or be cancelled, so observing only its return would reopen
    a duplicate-effect window. An input declared [Read_only] cannot change the
    work and observes nothing (#53702). *)

type recorder =
  { on_session_settled : Keeper_official_client_session_store.t -> unit
  ; on_results_ready : Keeper_client_tool_outbox.consumption option -> unit
  ; effect_cell : Effect_cell.t
  }
(** Where one attempt reports what {!outcome} carries. The last report wins. *)

val run :
  event_bus:Agent_core.Event_bus.t option ->
  keeper_name:string ->
  (result_scope:Eio.Switch.t ->
   recorder ->
   (Runtime_agent.run_result, Agent_core.Error.t) result) ->
  outcome
(** Runs one attempt in its own switch, inside
    {!Keeper_official_client_host.with_run_lifecycle_events}. The outcome keeps
    the reported receipts only when the attempt returns [Ok]. *)
