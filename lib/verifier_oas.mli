(** Verifier_oas — OAS adapter for verification engine.

    Bridges Verifier_core types to Agent_sdk Hooks/Guardrails.
    Core verification types and parsing live in Verifier_core (no OAS dependency).

    @since 2.233.0 *)

(** {1 Verification Prompt} *)

val build_prompt : Verifier_core.verification_request -> string

(** {1 Verification} *)

val verify : Verifier_core.verification_request -> (Verifier_core.verdict, string) result

(** {1 Verdict -> OAS Hook Decision} *)

val verdict_to_hook_decision : Verifier_core.verdict -> Agent_sdk.Hooks.hook_decision
val continue_with_degraded_verifier :
  tool_name:string -> reason:string -> Agent_sdk.Hooks.hook_decision

(** {1 PreToolUse Hook} *)

val handle_pre_tool_use :
  ?verify_fn:(Verifier_core.verification_request -> (Verifier_core.verdict, string) result) ->
  goal:string -> context_summary:string ->
  tool_name:string -> input:Yojson.Safe.t ->
  unit -> Agent_sdk.Hooks.hook_decision

val make_pre_tool_hook :
  ?verify_fn:(Verifier_core.verification_request -> (Verifier_core.verdict, string) result) ->
  goal:string -> context_summary:string ->
  Agent_sdk.Hooks.hook

val install_hook :
  hooks:Agent_sdk.Hooks.hooks ->
  goal:string -> context_summary:string ->
  Agent_sdk.Hooks.hooks

(** {1 Read-Only Detection} *)

val guardrails_with_read_only_tag :
  ?max_tool_calls_per_turn:int -> unit -> Agent_sdk.Guardrails.t

val read_only_predicate : Agent_sdk.Types.tool_schema -> bool

(** {1 Eval Gate Bridge} *)

val eval_gate_to_oas_guardrails :
  Eval_gate.gate_config -> Agent_sdk.Guardrails.t

module For_testing : sig
  val parse_verdict_from_response_text :
    string -> (Verifier_core.verdict, string) result
end
