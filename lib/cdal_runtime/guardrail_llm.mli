(** LLM-powered content guardrails.

    Wraps an externally-injected judge function as a
    {!Guardrails_async.input_validator} or {!Guardrails_async.output_validator}.

    The judge function is a closure — the SDK does not call the LLM directly.
    This prevents re-entrant guardrail loops (guardrail -> LLM -> guardrail)
    and ensures the guardrail LLM call uses an unguarded path.

    The judge evaluates content against a policy prompt and returns pass/fail.

    Det/NonDet: LLM-powered guardrails are non-deterministic. Tests must
    use mock judge closures (no real LLM calls).

    @stability Evolving
    @since 0.102.0 *)

(** {1 Types} *)

(** A judge evaluates text against a policy and returns [(pass, reason)].
    The boolean is [true] for pass, [false] for fail.
    The string provides the reason (useful for fail cases). *)
type judge = string -> (bool * string, string) result

(** {1 Constructors} *)

(** Create an input validator backed by a judge closure.
    The judge receives a serialized summary of the messages
    prepended with the policy prompt. *)
val make_input_validator
  :  name:string
  -> policy_prompt:string
  -> judge:judge
  -> Guardrails_async.input_validator

(** Create an output validator backed by a judge closure.
    The judge receives the concatenated text content of the response
    prepended with the policy prompt. *)
val make_output_validator
  :  name:string
  -> policy_prompt:string
  -> judge:judge
  -> Guardrails_async.output_validator

(** {1 Utilities} *)

(** Parse a judge response in "PASS" / "FAIL: reason" format. *)
val parse_judge_response : string -> (bool * string, string) result
