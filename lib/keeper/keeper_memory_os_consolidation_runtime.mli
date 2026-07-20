(** Keeper_memory_os_consolidation_runtime — LLM wiring for the consolidation pass.

    The read -> prompt -> LLM -> parse -> apply -> write-back loop. The LLM call is
    an injectable [complete_fn] so the loop is testable with a fake completion. The
    structure is deterministic; the only judgement is the model's consolidation
    plan ({!Keeper_memory_os_consolidation}). *)

type complete_fn = Keeper_provider_subcall.complete_fn

type outcome =
  | Skipped_too_few of int
  | Transport_failed of string
  | Unparseable of string
  | Empty_response
  | Invalid_structured_response of string
  | Snapshot_changed of
      { before : int
      ; current : int
      }
  | Consolidated of
      { before : int
      ; after : int
      }
  | Plan_rejected_total_deletion of { before : int }
      (** The plan retained no survivor from a non-empty store. Emptying a
          keeper's whole long-term memory is not a consolidation judgement the
          model is asked to make, so the plan is discarded and the store is left
          untouched. Deliberately narrower than a ratio guard: a store whose rows
          are mostly redundant has a legitimately large deletion, and only total
          erasure is refused. *)

module For_testing : sig
  val provider_for_consolidation
    :  Llm_provider.Provider_config.t
    -> Llm_provider.Provider_config.t
end

(** Tune the runtime's provider config for the consolidation request: output
    budget, no tool use, thinking disabled, and no wire response format. Call
    once per consolidation tick and pass the result to every
    {!consolidate_keeper} in that tick — the tuning depends only on the provider
    config, never on the keeper. Total: the request asks for no output schema,
    so no provider capability can reject it. *)
val resolve_provider_for_consolidation
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t

(** Read [keeper_id]'s facts, ask the model for a consolidation plan, apply it,
    and (unless [dry_run]) rewrite the store atomically only if the fact snapshot
    still matches the model's input. Only an empty store skips the LLM call; a
    numeric fact-count threshold never suppresses model judgment. Returns the
    outcome without raising for the expected failure modes so a
    caller fiber stays alive. [runtime_id] remains paired with [provider_cfg]
    so model-level temperature declarations survive request tuning.
    [provider_cfg] must already be tier-resolved via
    {!resolve_provider_for_consolidation}; the contract is not re-applied per
    keeper. *)
val consolidate_keeper
  :  ?complete:complete_fn
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?dry_run:bool
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> runtime_id:string
  -> provider_cfg:Llm_provider.Provider_config.t
  -> now:float
  -> keeper_id:string
  -> unit
  -> outcome
