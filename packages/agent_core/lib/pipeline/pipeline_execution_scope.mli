(** Private durable-execution ownership for one pipeline turn. *)

type t

(** A [Closed Succeeded] turn found at the resume frontier under a still-[Running]
    run: an idempotent completed boundary left by a crash between the provider
    close, the turn close, and the root finish. Opaque to the driver, which only
    threads it back through {!finalize_settled}. *)
type settled_boundary

(** Total classification of what a resume found at the durable turn frontier.
    [Fresh] runs a new turn; [Active] resumes an in-progress turn/provider;
    [Settled] surfaces an already-settled turn boundary (see {!finalize_settled}). *)
type resumed =
  | Fresh
  | Active of t
  | Settled of settled_boundary

val open_turn
  :  Execution_agent_scope.t option
  -> ordinal:int
  -> (t, Error.sdk_error) result

val resume_current : Execution_agent_scope.t option -> (resumed, Error.sdk_error) result

(** Complete an interrupted [close_success] for a settled boundary: closes the
    still-open turn when the crash landed between the provider close and the turn
    close. A fully-closed turn boundary needs no further journal write. *)
val finalize_settled : settled_boundary -> (unit, Error.sdk_error) result

val turn_ordinal : t -> int
val before_provider_attempt : t -> Binding_identity.t -> (unit, Error.sdk_error) result
val provider : t -> Execution_agent_scope.provider_attempt option

val record_provider_response
  :  t
  -> Llm_provider.Types.api_response
  -> (unit, Error.sdk_error) result

val provider_response : t -> (Llm_provider.Types.api_response, Error.sdk_error) result
val invocations_settled : t -> (bool, Error.sdk_error) result

val invocations
  :  t
  -> (Execution_agent_scope.invocation_authority list, Error.sdk_error) result

(** Exact settled result authority, reconstructed from persisted invocation
    nodes and ordered by their immutable planned index. *)
val settled_invocations_with_results
  :  t
  -> (Execution_agent_scope.settled_invocation list, Error.sdk_error) result

val settled_invocations
  :  settled_boundary
  -> (Execution_agent_scope.invocation_authority list, Error.sdk_error) result

val settled_response
  :  settled_boundary
  -> (Llm_provider.Types.api_response, Error.sdk_error) result

val close_success : t -> (unit, Error.sdk_error) result
