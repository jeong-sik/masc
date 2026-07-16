(** Keeper_memory_os_consolidation_runtime — LLM wiring for the consolidation pass.

    The read -> prompt -> LLM -> parse -> apply -> write-back loop. The LLM call is
    an injectable [complete_fn] so the loop is testable with a fake completion. The
    structure is deterministic; the only judgement is the model's consolidation
    plan ({!Keeper_memory_os_consolidation}). *)

type complete_fn = Keeper_memory_llm_summary.complete_fn

(** Default completion function: routes to [Llm_provider.Complete.complete]. *)
val default_complete : complete_fn

type outcome =
  | Skipped_too_few of int
  | Transport_timed_out
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

module For_testing : sig
  val provider_for_consolidation
    :  Llm_provider.Provider_config.t
    -> Llm_provider.Provider_config.t
end

(** Read [keeper_id]'s facts, ask the model for a consolidation plan, apply it,
    and (unless [dry_run]) rewrite the store atomically only if the fact snapshot
    still matches the model's input. Only an empty store skips the LLM call; a
    numeric fact-count threshold never suppresses model judgment. Returns the
    outcome without raising for the expected failure modes so a
    caller fiber stays alive. The call runs to natural completion without a
    MASC wall-clock budget. A genuine inner transport [Eio.Time.Timeout]
    surfaces as [Transport_timed_out], while parent cancellation propagates.
    [runtime_id] remains paired with
    [provider_cfg] so model-level temperature declarations survive request
    tuning. *)
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
