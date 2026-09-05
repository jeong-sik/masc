(** Total typed failure routing over [Agent_core.Error.t].

    Every turn-failure error maps to exactly one typed route; there is no
    [None] family and no catch-all arm. A route is an observation for telemetry
    and downstream handling; it cannot pause a Keeper or invent a wake-up
    deadline.

    Route semantics:
    - [Retry_after_observed] — a typed provider/infrastructure failure was
      observed. Carries the provider's exact [retry_after] hint when one
      exists, but does not synthesize or enforce a delay.
    - [Rotate_now] — a different runtime may succeed immediately
      (credentials, model availability, no-progress recovery hints).
    - [Exhausted_visible_alive] — deterministic failure: mechanical retry or
      rotation cannot change the outcome. The keeper keeps running and exposes
      the typed terminal observation; it does not dispatch a second LLM call.

    Classification is typed-only: a quota error routes by its typed class.
    Divergence between this route and the legacy
    [Keeper_error_classify.recoverable_runtime_failure_reason] opinion is
    an explicit typed-boundary mismatch, not scheduling authority.

    Hard quota is recognized only from the typed [PaymentRequired] and
    [HardQuota] constructors. Rate-limit messages and status prose are never
    reclassified. *)

(** Typed class of the observed retryable provider/runtime failure. *)
type retry_class =
  | Rate_limited  (** soft 429 throttle; declared runtimes remain eligible *)
  | Hard_quota  (** account-level quota/balance exhaustion (402 family) *)
  | Capacity_backpressure
      (** typed provider overload / capacity-exhausted pools *)
  | Server_error  (** typed server failure / provider unavailable *)
  | Network_transient  (** transport-level network failure *)
  | Provider_timeout  (** provider or transport deadline expiry *)

val core_error_is_hard_quota : Agent_core.Error.t -> bool
(** True only for the typed [PaymentRequired] and provider [HardQuota]
    constructors. Free-form messages and numeric status codes are ignored. *)

(** Why a different runtime is tried in the same turn. *)
type rotate_class =
  | Auth_failed
      (** this runtime's credential is invalid or lacks authorization;
          other runtimes may use a different credential scope *)
  | Model_unavailable  (** model/endpoint not found on this runtime *)
  | Resumable_cli_session  (** CLI session can resume on a recovery lane *)
  | Candidates_filtered  (** candidate set emptied after cycles *)
  | Runtime_exhausted  (** generic whole-runtime exhaustion *)
  | No_progress_empty
  | No_progress_thinking_only
  | No_progress_truncated
      (** accept-rejections carrying a no-progress recovery hint: the response
          was empty, thinking-only, or cut at [MaxTokens] after the
          continuation on this runtime did not deliver; a different model may
          make progress *)

(** Typed terminal classes that mechanical retry or rotation cannot change. *)
type terminal_class =
  | Deterministic_request  (** request-body/schema rejections; retry is futile *)
  | Context_overflow  (** typed context-window overflow *)
  | Contract_violation
      (** completion/progress contract rejections without a recovery hint,
          max-tokens ceiling violations, internal contract rejections *)
  | Protocol_error  (** MCP protocol failures *)
  | Config_mismatch  (** invalid/missing configuration or API key *)
  | Provider_integration
      (** provider response unparseable / unknown variant / provider-terminal
          / sub-500 unclassified server errors *)
  | Terminal_effect_dependency_unavailable
  | Terminal_effect_policy_rejection
  | Terminal_effect_runtime_failure
  | Terminal_effect_workflow_rejection
  | Terminal_effect_operator_cancelled
  | Provider_attempt_effect_fenced
  | Tool_correction_lost
  | Internal_opaque
      (** unhandled internal exceptions, serialization/io/orchestration/agent
          family errors; the failure stays visible while the keeper remains
          alive *)

(** Typed origin of a terminal observation. *)
type failure_provenance =
  | Agent_core_api_error
  | Agent_core_provider_error
  | Agent_core_agent_error
  | Agent_core_mcp_error
  | Agent_core_config_error
  | Agent_core_serialization_error
  | Agent_core_io_error
  | Agent_core_orchestration_error
  | Agent_core_internal_error
  | Masc_internal_error
  | Completion_contract

type error_boundary =
  | Masc_execution
  | Agent_core_execution
(** Actual producer boundary supplied by the caller. Ambiguous agent-core constructors
    such as [Config] and [Internal] do not carry their own origin. *)

type route =
  | Retry_after_observed of
      { retry_class : retry_class
      ; retry_after : float option
        (** typed provider hint, seconds; [None] when the provider gave
            none. The value is preserved rather than clamped or replaced. *)
      }
  | Rotate_now of { rotate : rotate_class }
  | Exhausted_visible_alive of
      { terminal : terminal_class
      ; provenance : failure_provenance
      ; detail : string
        (** Display-only bounded failure summary. Never matched. *)
      }

val route_of_error : boundary:error_boundary -> Agent_core.Error.t -> route
(** Total over every [core_error] class. The caller supplies the actual execution
    boundary so constructors shared by MASC and AGENT_CORE are never used as provenance
    inference. MASC-internal typed envelopes are decoded only at
    [Masc_execution], except [Terminal_effect_failed]: that MASC-owned effect
    crosses the live AGENT_CORE tool boundary and is therefore decoded at either
    boundary. No arm returns "no route". *)

val retry_after_of_route : route -> float option
(** [Some hint] only for [Retry_after_observed] carrying a provider hint. *)

val route_kind_label : route -> string
(** Stable telemetry label: ["retry_after_observed" | "rotate_now" |
    "exhausted_visible_alive"]. *)

val route_class_label : route -> string
(** The route's class label ([retry_class_label] / [rotate_class_label] /
    [terminal_class_label] respectively). *)
