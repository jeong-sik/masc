(** Cascade FSM — pure decision logic for multi-provider failover.

    Separates the cascade decision tree from IO (HTTP calls, throttle,
    timeout). The executor feeds provider outcomes to [decide], which
    returns the next action without side effects.

    This module owns the "what to do next" logic. The executor owns
    the "how to do it" (network, slots, diagnostics).

    @stability Evolving
    @since 0.120.0 *)

(** {1 Provider outcome — result of attempting one provider} *)

type provider_outcome =
  | Call_ok of Llm_provider.Types.api_response [@tla.symbol "call_ok"]
  | Call_err of Llm_provider.Http_client.http_error [@tla.symbol "call_err"]
  | Accept_rejected of { response : Llm_provider.Types.api_response; reason : string }
      [@tla.symbol "accept_rejected"]
  | Slot_full [@tla.symbol "slot_full"]
[@@deriving tla]

(** {1 Cascade decision — what to do next} *)

type decision =
  | Accept of Llm_provider.Types.api_response [@tla.symbol "accept"]
      (** Provider succeeded and accept predicate passed. Done. *)
  | Accept_on_exhaustion of { response : Llm_provider.Types.api_response; reason : string }
      [@tla.symbol "accept_on_exhaustion"]
      (** All providers rejected by accept, but [accept_on_exhaustion] is true.
          Return the last valid response as graceful degradation. *)
  | Try_next of { last_err : Llm_provider.Http_client.http_error option }
      [@tla.symbol "try_next"]
      (** Current provider failed or was rejected. Try the next one. *)
  | Exhausted of { last_err : Llm_provider.Http_client.http_error option }
      [@tla.symbol "exhausted"]
      (** All providers exhausted. Final failure. *)

(** {1 Decision function} *)

val decide :
  accept_on_exhaustion:bool ->
  is_last:bool ->
  provider_outcome ->
  decision
(** Pure decision: given the outcome of trying one provider and whether
    it was the last in the cascade, return the next action.

    - [Call_ok _] → always [Accept] (accept predicate already passed)
    - [Accept_rejected _] on last + [accept_on_exhaustion] → [Accept_on_exhaustion]
    - [Accept_rejected _] on last + not exhaustion → [Exhausted]
    - [Accept_rejected _] on non-last → [Try_next]
    - [Call_err _] on cascadeable error → [Try_next]
    - [Call_err _] on non-cascadeable error → [Exhausted]
    - [Slot_full] → [Try_next] *)

val decide_and_record :
  cascade_name:string ->
  accept_on_exhaustion:bool ->
  is_last:bool -
  provider_outcome -
  decision
(** Observable wrapper around [decide]. Emits Prometheus counters for
    cascade decisions, fallbacks, and exhaustion events before returning
    the pure decision. *)

(** {1 Error formatting} *)

val to_user_message :
  Llm_provider.Http_client.http_error option ->
  string
(** Render the terminal cascade detail used in keeper/operator messages.
    This does not add the transport-level ["All models failed"] wrapper; use
    [format_exhausted_error] when constructing the final HTTP client error. *)

val format_exhausted_error :
  Llm_provider.Http_client.http_error option ->
  Llm_provider.Http_client.http_error
(** Format the final error when all providers are exhausted. *)

(** {1 Human-readable description} *)

val provider_outcome_to_string : provider_outcome -> string
(** Short label for a provider outcome: ["call-ok"], ["call-err"],
    ["accept-rejected"], ["slot-full"]. *)

val provider_outcome_option_to_string : provider_outcome option -> string
(** Same as [provider_outcome_to_string] wrapped with ["some-"] or ["none"].
    Useful for test failure messages. *)
