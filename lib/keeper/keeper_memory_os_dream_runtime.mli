(** Keeper_memory_os_dream_runtime — LLM wiring for the dream consolidation pass.

    The read -> prompt -> LLM -> parse -> apply -> write-back loop. The LLM call is
    an injectable [complete_fn] so the loop is testable with a fake completion. The
    structure is deterministic; the only judgement is the model's consolidation
    plan ({!Keeper_memory_os_dream}). *)

type complete_fn = Keeper_memory_llm_summary.complete_fn

type outcome =
  | Skipped_too_few of int
  | Transport_failed of string
  | Unparseable of string
  | Consolidated of
      { before : int
      ; after : int
      }

(** Read [keeper_id]'s facts, ask the model for a consolidation plan, apply it,
    and (unless [dry_run]) rewrite the store atomically. Below a minimum fact
    count it skips the LLM call. Returns the outcome without raising for the
    expected failure modes so a caller fiber stays alive. *)
val consolidate_keeper
  :  ?complete:complete_fn
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?timeout_sec:float
  -> ?dry_run:bool
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> provider_cfg:Llm_provider.Provider_config.t
  -> now:float
  -> keeper_id:string
  -> unit
  -> outcome
