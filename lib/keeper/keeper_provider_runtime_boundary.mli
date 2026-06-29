(** Provider/runtime failure boundary for SDK errors crossing from OAS into
    keeper policy.

    This module deliberately does not classify keeper tool invocation or task
    workflow rejections. Those are MASC domain outcomes, not provider/runtime
    failures. *)

type timeout_source =
  | Oas_api
  | Oas_provider
  | Masc_internal

type provider_timeout =
  { phase : Keeper_failure_policy.timeout_phase option
  ; source : timeout_source
  }

type t =
  | Provider_timeout of provider_timeout
  | Not_provider_runtime_failure

val classify_sdk_error : Agent_sdk.Error.sdk_error -> t

val classify_provider_runtime_error_record
  :  code:string
  -> detail:string
  -> t
(** Classify a persisted [Provider_runtime_error] catch-all record.  This is
    narrower than parsing arbitrary messages: it only recognizes the OAS
    provider timeout wire markers such as
    ["provider_error_timeout:http_operation"]. [detail] remains in the
    signature for existing callers, but is not trusted for classification. *)

val is_provider_timeout : t -> bool
val is_provider_timeout_error : Agent_sdk.Error.sdk_error -> bool

val provider_timeout_failure
  :  strikes:int option
  -> liveness:Keeper_failure_policy.liveness_evidence
  -> provider_timeout
  -> Keeper_failure_policy.failure

val provider_timeout_policy_decision
  :  strikes:int
  -> liveness:Keeper_failure_policy.liveness_evidence
  -> Agent_sdk.Error.sdk_error
  -> Keeper_failure_policy.decision option
