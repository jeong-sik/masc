(** Verifier — Cheap-model action verification for feedback loops.

    After each action in the perpetual loop, a cheap model validates
    whether the action was correct and aligned with the goal.
    This implements the "verify" step of think → act → observe → verify.

    Uses a provider-aware default verifier model when the caller does not
    specify one, with a max 200-token budget per verification.

    Read-only actions (file reads, searches) are skipped.

    @since 2.61.0 *)

(** {1 Types} *)

(** Verification request — what happened and what should have happened. *)
type verification_request = {
  action_description : string;  (** What the agent did *)
  action_result : string;       (** What happened *)
  goal : string;                (** What we're trying to achieve *)
  context_summary : string;     (** Brief context for the verifier *)
}

(** Verdict from the verifier. *)
type verdict =
  | Pass                (** Action is correct, proceed *)
  | Warn of string      (** Proceed but note concern *)
  | Fail of string      (** Retry with this feedback *)

(** {1 Core Functions} *)

(** Verify an action using the given model.
    Max 200 output tokens to keep cost low.
    @return verdict based on cheap model analysis. *)
val verify : model:Llm_types.model_spec -> verification_request -> verdict

(** Check if an action should skip verification (read-only ops). *)
val should_skip : action_description:string -> bool

(** Convert verdict to string for logging. *)
val verdict_to_string : verdict -> string

(** Parse verdict from LLM text response. *)
val parse_verdict : string -> verdict
