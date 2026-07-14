(** Total typed failure routing over [Agent_sdk.Error.sdk_error].

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
    - [Escalate_judgment] — deterministic failure: mechanical retry or
      rotation cannot change the outcome. The keeper keeps running; the
      failure becomes a typed stimulus
      ([Keeper_event_queue.Failure_judgment]) for an LLM-boundary verdict.

    Classification is typed-only: a quota error routes by its typed class.
    Divergence between this route and the legacy
    [Keeper_error_classify.recoverable_runtime_failure_reason] opinion is
    an explicit typed-boundary mismatch, not scheduling authority.

    Hard quota is recognized only from the typed [PaymentRequired] and
    [HardQuota] constructors. Rate-limit messages and status prose are never
    reclassified. *)

(** Typed class of the observed retryable provider/runtime failure. *)
type retry_class =
  | Rate_limited  (** soft 429 throttle; rotation keeps the credential-pool filter *)
  | Hard_quota  (** account-level quota/balance exhaustion (402 family) *)
  | Capacity_backpressure
      (** typed provider overload / capacity-exhausted pools *)
  | Server_error  (** typed server failure / provider unavailable *)
  | Network_transient  (** transport-level network failure *)
  | Provider_timeout  (** provider or transport deadline expiry *)

val sdk_error_is_hard_quota : Agent_sdk.Error.sdk_error -> bool
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
      (** accept-rejections carrying an explicit no-progress recovery hint:
          a different model may make progress *)

(** Deterministic-failure classes escalated for an LLM-boundary verdict. *)
type judgment_class =
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
  | Internal_opaque
      (** unhandled internal exceptions, serialization/io/orchestration/agent
          family errors; judgment is the fail-open route that keeps the
          keeper alive *)

(** Typed origin of a judgment request. The route class says what kind of
    decision is needed; this provenance says which execution boundary produced
    it. [Legacy_unattributed] is a decode-only state for persisted
    pre-provenance stimuli and is never emitted by current producers. *)
type judgment_provenance =
  | Oas_api_error
  | Oas_provider_error
  | Oas_agent_error
  | Oas_mcp_error
  | Oas_config_error
  | Oas_serialization_error
  | Oas_io_error
  | Oas_orchestration_error
  | Oas_internal_error
  | Masc_internal_error
  | Completion_contract
  | Legacy_unattributed

type error_boundary =
  | Masc_execution
  | Oas_execution
(** Actual producer boundary supplied by the caller. Ambiguous SDK constructors
    such as [Config] and [Internal] do not carry their own origin. *)

type route =
  | Retry_after_observed of
      { retry_class : retry_class
      ; retry_after : float option
        (** typed provider hint, seconds; [None] when the provider gave
            none. The value is preserved rather than clamped or replaced. *)
      }
  | Rotate_now of { rotate : rotate_class }
  | Escalate_judgment of
      { judgment : judgment_class
      ; provenance : judgment_provenance
      ; detail : string
        (** display-only failure summary for the judgment prompt, bounded
            by [Keeper_internal_error.cap_blocker_detail]. Never matched. *)
      }

val route_of_error : boundary:error_boundary -> Agent_sdk.Error.sdk_error -> route
(** Total over every [sdk_error] class. The caller supplies the actual execution
    boundary so constructors shared by MASC and OAS are never used as provenance
    inference. MASC-internal typed envelopes are decoded only at
    [Masc_execution]. No arm returns "no route". *)

val retry_after_of_route : route -> float option
(** [Some hint] only for [Retry_after_observed] carrying a provider hint. *)

val route_kind_label : route -> string
(** Stable telemetry label: ["retry_after_observed" | "rotate_now" |
    "escalate_judgment"]. *)

val retry_class_label : retry_class -> string
val rotate_class_label : rotate_class -> string
val judgment_class_label : judgment_class -> string

val judgment_provenance_label : judgment_provenance -> string
(** Stable wire/telemetry label. The idle counter remains a typed field and is
    not embedded in this label. *)

val judgment_provenance_same_boundary :
  judgment_provenance -> judgment_provenance -> bool
(** Typed durable-identity comparison. Two idle-detected values share the same
    producer boundary even when their observation counts differ; no routing
    decision is derived from wire labels. *)

val judgment_provenance_to_yojson : judgment_provenance -> Yojson.Safe.t

val judgment_provenance_of_yojson :
  Yojson.Safe.t -> (judgment_provenance, string) result
(** Total codec for durable queue stimuli. Unknown kinds and invalid idle
    counters are explicit [Error] values. *)

val route_class_label : route -> string
(** The route's class label ([retry_class_label] / [rotate_class_label] /
    [judgment_class_label] respectively). *)

val judgment_class_of_label : string -> judgment_class option
(** Closed inverse of [judgment_class_label] for durable queue snapshots;
    unknown labels are [None] (fail-closed at the parse boundary). *)
