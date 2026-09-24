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
  | Provider_capacity
      (** the provider refused for its own capacity: an HTTP 529 overload,
          a provider [CapacityExhausted] pool, or the MASC envelope that
          carries one. A fact about the attempted candidate, like a server
          error. *)
  | Empty_completion of { stop_reason : Llm_provider.Types.stop_reason }
      (** provider completed the request with no thinking, text, or tool calls;
          the typed stop reason remains available to scheduling policy and
          telemetry, and the model observed the input *)
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
  | Refusal_body_not_received
      (** the provider refused and the body naming the cause did not arrive
          before the caller's window closed
          ({!Llm_provider.Retry.Refusal_body_not_received}); the lane moves
          to its next candidate, the refusal's reason being unread rather
          than determinate *)
  | Generation_repeated
      (** the model's generation repeated one unit past the threshold and the
          client ended the stream ([Llm_provider.Error.RepeatingGeneration]).
          The connection delivered every byte, so this is neither a wire
          fault nor a provider integration defect: the lane rotates, and the
          driver leaves the model, not only the provider, behind *)
  | Attempt_rejected
      (** the request was refused before the wire by this candidate's own
          policy (a reasoning-effort ladder, an explicit disable) rather than
          by the provider; the driver's [attempt_rejected_should_try_next]
          moves the lane to its next declared candidate in the same turn, so
          the route names that rotation instead of calling the failure
          deterministic *)
  | Provider_reported_failure
      (** the provider itself reported a structured failure for this attempt
          ([Llm_provider.Error.ProviderReportedError]: a CLI-adapter turn
          failure, an RPC error, or a post-activity context-window report).
          The fact is scoped to this candidate's attempt, matching
          [Llm_provider.Error.RepeatingGeneration]'s [Generation_repeated]
          sibling: [Runtime_attempt_fsm.should_try_next] already rotates on
          every [Http_client.ProviderFailure] kind, so a route that called
          this terminal disagreed with the walk that already moves on
          (task-1642) *)
  | Request_refused
      (** the provider refused this request body without a machine-readable
          reason, or with a size status
          ({!Llm_provider.Retry.Unknown_invalid_request},
          {!Llm_provider.Retry.Request_body_refused_by_provider}). Another
          declared candidate may accept the same semantic input, and the
          driver's [attempt_rejected_should_try_next] moves the lane there in
          the same turn *)
  | Provider_wire_defect
      (** the bytes that arrived broke the provider's declared wire format
          ([Malformed_payload], [Unknown_event], [Oversized_payload]). The
          same path sends the same bytes again; the next candidate is a
          different provider attempt, and
          [Runtime_attempt_fsm.should_try_next] rotates on every
          [Http_client.ProviderFailure] kind *)
  | Server_error_not_transient
      (** a 5xx the provider marked as not transient. The same path answers
          the same way; the walk rotates on every 5xx *)

(** What the driver had observed of tool effects when it fenced a provider
    attempt. Only the two dispositions that fence an attempt appear here:
    [No_effect_observed] never fences (it routes to [Contract_violation]).
    Carried on the route because the two answer differently to
    {!response_observed}: an attempted effect is a model answer, an
    unavailable observation is set before any answer (#32956 review). *)
type fence_disposition =
  | Fenced_effect_attempted
      (** a dynamic tool handler was entered; another candidate could
          duplicate the effect *)
  | Fenced_observation_unavailable
      (** the adapter cannot prove whether an effect was attempted; the
          claude-code lane sets it on spawn, the codex lane when the turn
          input could not be written *)

(** Typed terminal classes that mechanical retry or rotation cannot change. *)
type terminal_class =
  | Deterministic_request
      (** a request body that did not parse, or an input past a declared
          serving bound; no candidate accepts it *)
  | Context_overflow  (** typed context-window overflow *)
  | Session_claim_refused
      (** an official client refused its durable session claim before provider
          dispatch; the held recovery requires explicit operator resolution *)
  | Transcript_refused
      (** the turn's history was refused before provider dispatch: its tool
          transcript is incomplete or structurally broken, so no request
          carried the turn's input *)
  | Contract_violation
      (** completion/progress contract rejections without a recovery hint,
          max-tokens ceiling violations, internal contract rejections *)
  | Protocol_error  (** MCP protocol failures *)
  | Config_mismatch  (** invalid/missing configuration or API key *)
  | Provider_integration
      (** provider response unparseable / unknown variant / provider-terminal
          / a non-transient server error whose code is outside the 5xx class *)
  | Terminal_effect_dependency_unavailable
  | Terminal_effect_policy_rejection
  | Terminal_effect_runtime_failure
  | Terminal_effect_workflow_rejection
  | Terminal_effect_operator_cancelled
  | Provider_attempt_effect_fenced of fence_disposition
  | Tool_correction_lost of fence_disposition
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

val usable_retry_after : float option -> float option
(** The provider hint that names a wait: present, finite, above zero. A
    hint that is absent, zero, negative, infinite or NaN names none, and every
    reader of a hint answers from this one rule — the candidate's rate limit
    ([Runtime_candidate_backpressure_state.note_rate_limit]) stays until a
    success, {!path_rest_sec} rests the class's own
    default for it, {!route_resumes_on_same_path} refuses to resume a quota on
    it, and the driver records a quota it cannot date as observed rather than
    planting a window that is already over. *)

val path_rest_sec :
  cap_sec:float -> retry_class:retry_class -> retry_after_hint:float option -> float
(** How long a path rests after it answered [retry_class]
    (RFC-provider-path-rest). A usable provider hint rests that long, at
    least one second. Without one (absent, zero, negative, NaN), [Hard_quota]
    rests [cap_sec] and every other class rests
    {!Env_config_keeper.KeeperKeepalive.rate_limit_backoff_floor_sec}. The
    result is clamped to [cap_sec]. The keeper cadence is not an input. *)

val route_kind_label : route -> string
(** Stable telemetry label: ["retry_after_observed" | "rotate_now" |
    "exhausted_visible_alive"]. *)

val route_class_label : route -> string
(** The route's class label ([retry_class_label] / [rotate_class_label] /
    [terminal_class_label] respectively). *)

val response_observed : route -> bool
(** Whether the provider answered the request that carried the turn's input,
    so that what failed is the answer or what the turn did with it, not the
    delivery of the input. A Gate continuation that fails on such a route has
    already shown the model its replay evidence; the heartbeat settles the
    approval instead of carrying the same evidence into the next cycle
    (#32956: one approval rode 24 turns in 51 minutes, every turn ending at
    [MaxTokens]).

    [true]: [Empty_completion], the three [No_progress_*] rotations (the
    accept gate rejected an answer), [Contract_violation] (a proven
    pre-effect tool failure, or an effect fence with no effect observed), the five
    [Terminal_effect_*] classes (a tool the model called failed terminally),
    and the two effect fences with [Fenced_effect_attempted] (a tool handler
    was entered, so the model had answered).

    [false]: every other [Retry_after_observed] class, every other rotation,
    [Session_claim_refused], [Transcript_refused], every other unlisted
    terminal class, and the two
    effect fences with
    [Fenced_observation_unavailable], which the lanes set before any answer.
    [Internal_opaque] is [false] although it also holds an accept rejection
    without a no-progress hint: the route cannot tell that apart from an
    unhandled exception, so the evidence keeps its wake. *)

val route_resumes_on_same_path : route -> bool
(** Whether a failure passes with time on the path that answered it, so a chat
    operation whose last candidate failed after saving tool results continues
    on that same path (RFC last-path-resumes-after-progress §3.3).

    [true]: [Rate_limited], [Provider_capacity], [Empty_completion] with
    [EndTurn], [MaxTokens], or [StopSequence], [Server_error],
    [Network_transient], [Provider_timeout], and [Hard_quota] with a usable
    reset hint (positive, not NaN). The empty-completion reasons resume a
    direct operation once so its saved tool results are not discarded; another
    resume still requires a newly saved tool result.

    [false]: [Empty_completion] with [Refusal], [ContentFilter],
    [RepetitionTruncation], [StopToolUse], [PauseTurn], [Compaction],
    [ContextWindowExceeded], [UnmatchedToolCalls], or [Unknown _]. The first
    three are deterministic for the same input, matching
    [Refusal_body_not_received] and [Generation_repeated]. [PauseTurn] and
    [Compaction] need the provider's assistant response to continue; an empty
    completion error carries no such response, so replaying its pre-response
    checkpoint is not a valid continuation. [Hard_quota] without a reset,
    every rotation, and every terminal class are also [false]. How long the
    path rests is not read here: the chat lane's wait follows the rest recorded
    on the path. *)
