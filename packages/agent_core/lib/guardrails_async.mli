(** Async guardrails: parallel input/output validation.

    Validators run concurrently inside a dedicated [Eio.Switch]. Validator
    failures and ordinary exceptions are contained to that
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

(** Run input validators concurrently. Returns first failure or [Pass]. *)
val run_input : input_validator list -> Types.message list -> validation_result

(** Run output validators concurrently. Returns first failure or [Pass]. *)
val run_output : output_validator list -> Types.api_response -> validation_result

(** Run input validation, action, output validation in sequence.
    Input failure skips the action. *)
val guarded
  :  config:t
  -> messages:Types.message list
  -> action:(unit -> (Types.api_response, 'e) Result.t)
  -> unit
  -> (Types.api_response, [ `Validation of validation_result | `Action of 'e ]) Result.t

val result_to_string : validation_result -> string
