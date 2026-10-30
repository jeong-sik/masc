
(** Tool_local_runtime_verify — Runtime contract verification for
    local LLM runtime pools (llama.cpp / Ollama).

    Exposes 3 verification entries. Verify is the contract layer; HTTP
    helper plumbing is kept out of this public interface.

    Internal helpers stay private: discovery resolution, endpoint field
    projectors, chat-completions probing, and the discovery-backed
    renderer behind {!runtime_verify_json}.  The old single-host legacy
    probe fallback is gone; verification now requires AGENT_CORE discovery. *)

module For_testing : sig
  val select_endpoint_urls_for_pool :
    ?runtime_pool:string -> string list -> string list option
  (** Regression seam for the fail-closed explicit-pool selector. *)
end

val runtime_verify_json :
  ?runtime_pool:string ->
  ?expected_slots:int ->
  ?expected_ctx:int ->
  ?expected_model:string ->
  unit ->
  Yojson.Safe.t
(** [runtime_verify_json ?runtime_pool ?expected_slots
      ?expected_ctx ?expected_model ()] runs the full runtime
    verification pipeline against the AGENT_CORE discovery cache.

    Returns a JSON object with health/slot/ctx/model
    diagnostics + the {!classify_runtime_blocker} verdict.  [?runtime_pool]
    selects the pool by name; default behaviour verifies every discovered
    endpoint. An explicit pool that matches no endpoint fails closed rather
    than probing the full pool. When discovery has no resolvable endpoints,
    the local-runtime diagnostic fails
    closed with [runtime_blocker = "agent_core_discovery_unavailable"]. The
    response also pins [verification_scope =
    "local_openai_compatible_runtime_pool"], [blocks_keeper_turns = false],
    and [fleet_provider_health = "not_assessed"] so callers cannot treat
    absence of this optional local pool as a fleet-wide provider outage. *)
