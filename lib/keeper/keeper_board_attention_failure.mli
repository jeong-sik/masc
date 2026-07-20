(** Typed failure evidence for the Board-attention judgment plane.

    Retry authority is never inferred from elapsed time, message text, or a
    local retry counter. A deadline exists only when the Provider supplied an
    exact typed retry-after hint. Other retryable states require the named
    external state transition. Deterministic failures are blocked rather than
    mechanically retried. *)

type retry_requirement =
  | Provider_retry_after of
      { retry_class : Keeper_runtime_failure_route.retry_class
      ; delay_seconds : float
      }
  | Provider_recovery of Keeper_runtime_failure_route.retry_class
  | Runtime_catalog_change of Keeper_runtime_failure_route.rotate_class
  | Runtime_configuration_change

type retryable =
  { requirement : retry_requirement
  ; detail : string
  ; failed_at : float
  }

type blocked_kind =
  | Prompt_contract_unavailable
  | Response_contract_unavailable
  | Provider_judgment_required of
      { judgment : Keeper_runtime_failure_route.judgment_class
      ; provenance : Keeper_runtime_failure_route.judgment_provenance
      }
  | Invalid_provider_retry_authority
  | Unexpected_judgment_exception

type blocked =
  { kind : blocked_kind
  ; detail : string
  ; blocked_at : float
  }

type attempt_failure =
  | Retryable of retryable
  | Blocked of blocked

val runtime_configuration_change : failed_at:float -> detail:string -> attempt_failure

val blocked : blocked_at:float -> kind:blocked_kind -> detail:string -> attempt_failure

val of_sdk_error : observed_at:float -> Agent_sdk.Error.sdk_error -> attempt_failure
(** Classify one OAS execution failure through the shared typed runtime route.
    Free-form error text is retained for display only and is never matched. *)

val retry_deadline : retryable -> float option
(** Exact wall-clock deadline derived only from a typed Provider retry-after
    hint. [None] means an external typed state-change signal is required. *)

val retry_requirement_label : retry_requirement -> string
val blocked_kind_label : blocked_kind -> string
(** Stable observability labels. They are projections only and are never parsed
    to make scheduling decisions. *)

val retryable_to_yojson : retryable -> Yojson.Safe.t
val retryable_of_yojson : Yojson.Safe.t -> (retryable, string) result
val blocked_to_yojson : blocked -> Yojson.Safe.t
val blocked_of_yojson : Yojson.Safe.t -> (blocked, string) result

val validate_retryable : retryable -> (unit, string) result
val validate_blocked : blocked -> (unit, string) result
