(** Async guardrails: parallel input/output validation.

    Validators run concurrently inside a dedicated [Eio.Switch]. Validator
    failures, timeouts, and ordinary exceptions are contained to that
    validator's [Fail] result so sibling validators can finish. Parent switch
    cancellation still propagates through Eio structured concurrency.

    @since 0.67.0

    @stability Evolving
    @since 0.93.1 *)

(** Input validator: checks messages before the LLM call. *)
type input_validator =
  { name : string
  ; validate : Types.message list -> (unit, string) Result.t
  }

(** Output validator: checks the response after the LLM call. *)
type output_validator =
  { name : string
  ; validate : Types.api_response -> (unit, string) Result.t
  }

type validation_result =
  | Pass
  | Fail of
      { validator_name : string
      ; reason : string
      }

type t =
  { input_validators : input_validator list
  ; output_validators : output_validator list
  }

val empty : t

(** Per-validator deadline. When passed to {!run_input} / {!run_output}
    each validator is wrapped in [Eio.Time.with_timeout_exn], so a
    stuck validator returns [Fail "validator timed out"] instead of
    blocking sibling fibers and the rest of the turn. *)
type deadline =
  { clock : float Eio.Time.clock_ty Eio.Resource.t
  ; timeout_sec : float
  }

(** Run input validators concurrently. Returns first failure or [Pass].

    When [?deadline] is provided each validator gets a hard deadline
    via [Eio.Time.with_timeout_exn]. *)
val run_input
  :  ?deadline:deadline
  -> input_validator list
  -> Types.message list
  -> validation_result

(** Run output validators concurrently. Returns first failure or [Pass].

    Same [?deadline] semantics as {!run_input}. *)
val run_output
  :  ?deadline:deadline
  -> output_validator list
  -> Types.api_response
  -> validation_result

(** Run input validation, action, output validation in sequence.
    Input failure skips the action. [?deadline] is forwarded to both
    {!run_input} and {!run_output}. *)
val guarded
  :  ?deadline:deadline
  -> config:t
  -> messages:Types.message list
  -> action:(unit -> (Types.api_response, 'e) Result.t)
  -> unit
  -> (Types.api_response, [ `Validation of validation_result | `Action of 'e ]) Result.t

val result_to_string : validation_result -> string
