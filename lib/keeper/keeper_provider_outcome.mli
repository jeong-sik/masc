(** Keeper_provider_outcome — provider call outcome type.

    Re-homed from the deleted [Cascade_fsm] module (RFC-0206 L2). The
    multi-provider failover [decide]/[decision] routing engine was NOT
    re-homed: it had no live callers (referenced only in doc comments) and
    belongs to the cascade routing layer being collapsed under single-binding.
    Only the [provider_outcome] type and its string projections survive; they
    are consumed by the typed SDK-error classification layer
    ([Keeper_sdk_error_classify]) and the turn-driver facade. *)

type provider_outcome =
  | Call_ok of Llm_provider.Types.api_response
  | Call_err of Llm_provider.Http_client.http_error
  | Accept_rejected of {
      response : Llm_provider.Types.api_response;
      reason : string;
    }

val provider_outcome_to_string : provider_outcome -> string
val provider_outcome_option_to_string : provider_outcome option -> string
