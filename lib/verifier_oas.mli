(** Verifier_oas — OAS adapter for verification engine.

    Bridges Verifier_core types to the OAS agent runtime. Core verification
    types and parsing live in Verifier_core (no OAS dependency).

    @since 2.233.0 *)

(** {1 Verification Prompt} *)

val build_prompt : Verifier_core.verification_request -> string

(** {1 Verification} *)

val verify : Verifier_core.verification_request -> (Verifier_core.verdict, string) result

module For_testing : sig
  val parse_verdict_from_response_text :
    string -> (Verifier_core.verdict, string) result
end
