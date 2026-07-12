(** RFC-0313 W2 — total failure routing over [Agent_sdk.Error.sdk_error].

    Every turn-failure error maps to exactly one typed route; there is no
    [None] family and no catch-all arm. In W2 the route is recorded
    (telemetry + shadow pacing + judgment stimulus) alongside the existing
    streak/pause/rotation machinery, which stays authoritative until the
    RFC-0313 W3 flip.

    Route semantics (RFC-0313 §2):
    - [Retry_after_pacing] — the failure is provider/infrastructure-paced:
      widen the failed runtime's revisit deadline and continue on the next
      eligible runtime. Carries the typed provider [retry_after] hint when
      one exists.
    - [Rotate_now] — a different runtime may succeed immediately
      (credentials, model availability, no-progress recovery hints);
      today's same-turn degraded rotation behavior, kept.
    - [Escalate_judgment] — deterministic failure: mechanical retry or
      rotation cannot change the outcome (oas#2482 class). The keeper keeps
      running; the failure becomes a typed stimulus
      ([Keeper_event_queue.Failure_judgment]) for an LLM-boundary verdict.

    Classification is typed-only: this module deliberately does not import
    the CLI-wrapped hard-quota substring scan
    ([Keeper_turn_driver.message_looks_like_cli_wrapped_hard_quota]); a
    quota error that only a string scan would catch routes by its typed
    class instead. Divergence between this route and the legacy
    [Keeper_error_classify.recoverable_runtime_failure_reason] opinion is
    expected W2 shadow data, not a bug (#23483 retired the scan's most
    recent false positive).

    The one string-derived input is [Llm_provider.Retry.is_hard_quota],
    OAS's own boundary predicate over its [api_error] payloads — consuming
    it is the allowed MASC→OAS direction; replacing its internals with a
    typed variant is OAS-side work tracked by RFC-0313 §6. *)

(** Why a runtime's revisit is widened instead of retried immediately. *)
type pacing_class =
  | Rate_limited  (** soft 429 throttle; rotation keeps the credential-pool filter *)
  | Hard_quota  (** account-level quota/balance exhaustion (402 family) *)
  | Capacity_backpressure
      (** provider overload / Cloudflare 524 / capacity-exhausted pools;
          the 2026-07-06 storm class *)
  | Server_error  (** transient 5xx / provider unavailable *)
  | Network_transient  (** transport-level network failure *)
  | Provider_timeout  (** provider or transport deadline expiry *)
  | Turn_timeout  (** keeper turn budget expiry *)
  | Admission_backpressure  (** MASC lane admission queue timeout/rejection *)

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
  | No_progress_read_only
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
  | Mutating_ambiguity
      (** ambiguous post-commit failure after mutating tools; needs
          reconcile-grade judgment, HITL for mutating scope *)
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
    it. [Oas_agent_idle_detected] retains the behavioral counter that was
    previously collapsed into [Contract_violation]. [Legacy_unattributed] is a
    decode-only state for persisted pre-provenance stimuli and is never emitted
    by current producers. *)
type judgment_provenance =
  | Oas_api_error
  | Oas_provider_error
  | Oas_agent_idle_detected of { consecutive_idle_turns : int }
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
  | Retry_after_pacing of
      { pacing : pacing_class
      ; retry_after : float option
        (** typed provider hint, seconds; [None] when the provider gave
            none. Clamping to the pacing policy cap happens in
            [Keeper_pacing.on_failure], not here. *)
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
(** [Some hint] only for [Retry_after_pacing] carrying a provider hint.
    W2 threads this into [Keeper_pacing_shadow.observe_failure]. *)

val route_kind_label : route -> string
(** Stable telemetry label: ["retry_after_pacing" | "rotate_now" |
    "escalate_judgment"]. *)

val pacing_class_label : pacing_class -> string
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
(** The route's class label ([pacing_class_label] / [rotate_class_label] /
    [judgment_class_label] respectively). *)

val judgment_class_of_label : string -> judgment_class option
(** Closed inverse of [judgment_class_label] for durable queue snapshots;
    unknown labels are [None] (fail-closed at the parse boundary). *)
