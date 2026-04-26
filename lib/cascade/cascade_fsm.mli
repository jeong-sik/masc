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
  | Call_ok of Llm_provider.Types.api_response
  | Call_err of Llm_provider.Http_client.http_error
  | Accept_rejected of
      { response : Llm_provider.Types.api_response
      ; reason : string
      }
  | Slot_full

(** {1 Cascade decision — what to do next} *)

type decision =
  | Accept of Llm_provider.Types.api_response
  (** Provider succeeded and accept predicate passed. Done. *)
  | Accept_on_exhaustion of
      { response : Llm_provider.Types.api_response
      ; reason : string
      }
  (** All providers rejected by accept, but [accept_on_exhaustion] is true.
          Return the last valid response as graceful degradation. *)
  | Try_next of { last_err : Llm_provider.Http_client.http_error option }
  (** Current provider failed or was rejected. Try the next one. *)
  | Exhausted of { last_err : Llm_provider.Http_client.http_error option }
  (** All providers exhausted. Final failure. *)

(** {1 Decision function} *)

(** Pure decision: given the outcome of trying one provider and whether
    it was the last in the cascade, return the next action.

    - [Call_ok _] → always [Accept] (accept predicate already passed)
    - [Accept_rejected _] on last + [accept_on_exhaustion] → [Accept_on_exhaustion]
    - [Accept_rejected _] on last + not exhaustion → [Exhausted]
    - [Accept_rejected _] on non-last → [Try_next]
    - [Call_err _] on cascadeable error → [Try_next]
    - [Call_err _] on non-cascadeable error → [Exhausted]
    - [Slot_full] → [Try_next] *)
val decide : accept_on_exhaustion:bool -> is_last:bool -> provider_outcome -> decision

(** {1 Error formatting} *)

(** Format the final error when all providers are exhausted. *)
val format_exhausted_error
  :  Llm_provider.Http_client.http_error option
  -> Llm_provider.Http_client.http_error
