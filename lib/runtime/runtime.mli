(** Runtime = Provider + Model + Spec(binding).

    runtime→Runtime 전환 (RFC-0206). runtime 의 routes/runtime_id/tier/profile
    간접 레이어를 제거하고, binding(provider × model) 하나를 곧 하나의 Runtime
    으로 본다. 소비자는 Runtime 목록 + default Runtime 을 직접 소비한다.
    타입은 자립 모듈 {!Runtime_schema} 소유. *)

open Runtime_schema

type t =
  { id : string
  ; provider : provider
  ; model : model_spec
  ; binding : binding
  ; execution : Runtime_execution.t
  ; quota_scope : Runtime_quota_window.scope
    (** Quota ownership key frozen at materialization, from the same
        credential-alias selection that resolved the dispatched API key. A
        later environment change must not re-select the alias at
        window-recording time, or the window is charged to an account the
        dispatch never used (PR #28219 review). *)
  }

type dispatch_credential_error =
  | Required_env_credential_missing of
      { provider_id : string
      ; env_key : string
      }
  | Declared_credential_unavailable of
      { provider_id : string
      ; carrier : Agent_core.Error.credential_carrier
      }

val dispatch_credential_error_to_string : dispatch_credential_error -> string

val dispatch_credential_error_to_core_error :
  dispatch_credential_error -> Agent_core.Error.t
(** Preserve a missing environment credential as the existing typed
    [MissingEnvVar] configuration error. Other unavailable credential carriers
    use the closed [CredentialUnavailable] variant, so consumers never infer
    terminal configuration state from broad [InvalidConfig] text. *)

val validate_dispatch_credential :
  provider_config:Llm_provider.Provider_config.t ->
  t ->
  (unit, dispatch_credential_error) result
(** Fail closed immediately before an Agent Core dispatch when the runtime
    declares a credential but the final provider config has no secret. A
    credential-free provider remains valid. This check intentionally happens
    after materialization so dashboard missing-auth projection stays intact. *)

type config_source_revision = private Config_source_revision of string
type config_commit_order = private Config_commit_order of int64

type config_observation = private
  { path : string
  ; source_text : string
  ; source_revision : config_source_revision
  }

type config_durability =
  | Durable
  | Durability_unconfirmed of { detail : string }

type config_commit_receipt = private
  { observation : config_observation
  ; durability : config_durability
  ; order : config_commit_order
  ; lock_warnings : config_lock_warning list
  }

and config_lock_warning =
  | Config_lock_release_unconfirmed of string

type keeper_assignment_state =
  | Assignment_missing
  | Assignment_present of string

type keeper_assignment_revision =
  | Runtime_config_missing
  | Runtime_config_present of
      { source_revision : config_source_revision
      ; assignment : keeper_assignment_state
      }

type keeper_assignment_cas_error =
  | Assignment_revision_conflict of keeper_assignment_revision
  | Assignment_io_error of string

type keeper_assignment_write =
  | Assignment_unchanged of keeper_assignment_revision
  | Assignment_committed of
      { receipt : config_commit_receipt
      ; revision : keeper_assignment_revision
      }

type keeper_assignment_transaction

type 'a config_lock_receipt = private
  { value : 'a
  ; warnings : config_lock_warning list
  }

val config_source_revision_to_string : config_source_revision -> string
val config_commit_order_to_string : config_commit_order -> string
val compare_config_commit_order : config_commit_order -> config_commit_order -> int
val config_lock_warning_to_yojson : config_lock_warning -> Yojson.Safe.t
val keeper_assignment_revision_to_yojson : keeper_assignment_revision -> Yojson.Safe.t
val keeper_assignment_revision_of_yojson :
  Yojson.Safe.t -> (keeper_assignment_revision, string) result

val with_keeper_assignment_transaction :
  ?runtime_config_path:string ->
  keeper_name:string ->
  (keeper_assignment_transaction -> 'a) ->
  ('a config_lock_receipt, string) result
(** Hold the process-wide and durable [runtime.toml] locks while observing and
    acting on one Keeper assignment. Callers that also hold a Keeper manifest
    lock must always acquire that manifest lock first. *)

val keeper_assignment_revision :
  keeper_assignment_transaction -> keeper_assignment_revision

val keeper_assignment_transaction_path : keeper_assignment_transaction -> string option

val commit_keeper_assignment :
  keeper_assignment_transaction ->
  runtime_id:string option ->
  (keeper_assignment_write, string) result
(** Commit the requested assignment from the exact source bytes captured by
    the transaction. [None] clears it. An unchanged assignment returns
    [Assignment_unchanged] without rewriting [runtime.toml]. *)

val commit_keeper_egress_allow :
  keeper_assignment_transaction ->
  allow:string list option ->
  (keeper_assignment_write, string) result
(** Write this keeper's [\[egress.keepers.<name>\]] allowlist from the exact
    source bytes the transaction captured (RFC-0415). [None] removes the
    table, which leaves the keeper reaching nothing rather than everything.

    Inside the same transaction as {!commit_keeper_assignment} on purpose:
    one lock, one file. A second transaction would let another admitted
    writer land between a keeper entering the policy lane and being told what
    it may reach, and a keeper in that gap reaches nothing while its config
    says otherwise. *)

val restore_keeper_assignment_transaction :
  keeper_assignment_transaction -> (keeper_assignment_write, string) result
(** Restore the exact [runtime.toml] source bytes captured when the
    transaction began. The caller must still be inside the transaction
    callback, so no other admitted runtime writer can interleave. *)

val observe_keeper_assignment :
  ?runtime_config_path:string ->
  keeper_name:string ->
  unit ->
  (keeper_assignment_revision config_lock_receipt, string) result

val set_keeper_assignment_if_revision :
  ?runtime_config_path:string ->
  keeper_name:string ->
  runtime_id:string option ->
  expected:keeper_assignment_revision ->
  unit ->
  (keeper_assignment_write config_lock_receipt,
   keeper_assignment_cas_error) result
(** Compare and replace under the same runtime-config transaction. [Error]
    carries the exact observed revision. *)

module Assignment_for_testing : sig
  val commit_with_replace_file :
    replace_file:
      (string ->
       string ->
       (unit, Fs_compat.atomic_replace_failure) result) ->
    keeper_assignment_transaction ->
    runtime_id:string option ->
    (keeper_assignment_write, string) result

  val restore_with_replace_file :
    replace_file:
      (string ->
       string ->
       (unit, Fs_compat.atomic_replace_failure) result) ->
    keeper_assignment_transaction ->
    (keeper_assignment_write, string) result

  val set_with_release_failure :
    release_failure:File_lock_eio.durable_lock_error ->
    runtime_config_path:string ->
    keeper_name:string ->
    runtime_id:string option ->
    expected:keeper_assignment_revision ->
    unit ->
    (keeper_assignment_write config_lock_receipt,
     keeper_assignment_cas_error) result
end

val id_of_binding : binding -> string

type drop_reason =
  | Binding_disabled
  | Provider_disabled of string
  | Provider_not_declared of string
  | Model_not_declared of string
  | Execution_unbuildable of string
      (** Why a binding did not become a runtime. Closed so consumers decide per
          case instead of matching the rendered text: the [*_not_declared] pair
          is a dangling reference (an operator typo, fatal at
          {!load_list}), while a disabled binding or provider is a choice the
          operator wrote down and [Execution_unbuildable] is an adapter
          capability limit — both non-fatal, per RFC-0206 §2.1. *)

val string_of_drop_reason : drop_reason -> string
(** Operator-facing rendering. Single source for the wording, so a reason read
    from a runtime message and one read from a load error cannot drift. *)

val of_binding : config -> binding -> (t, drop_reason) result
(** Materialize one binding while preserving failure information. [Error reason]
    when the binding is disabled, its provider/model id is unresolved, or the
    provider transport/protocol cannot be materialized into a
    {!Llm_provider.Provider_config.t} (e.g. a [messages-http]
    provider the runtime adapter has no provider_config path for). The binding is
    still excluded from the runtime list (fail-closed, RFC-0206 §2.1); this
    surfaces *why*, so [\[runtime\].default] / [\[runtime.assignments\]] / lane
    validation can report a dropped target's materialize failure instead of a
    bare "not found among N runtimes" that points at a non-existent typo. *)

val decide_capability_gate :
  config_path:string -> (string * bool) list -> (unit, string) result
(** Pure capability-gate decision applied at startup by [init_default_strict]
    (not by [load_list], which keeps only RFC-0206 routing validation so unit
    tests stay catalog-independent), exposed for testing. [entries] is
    [(label, known_to_agent_core_catalog)] per runtime binding. Returns [Error] when any
    configured model is unknown to the AGENT_CORE capability catalog: an unknown model
    resolves to [provider_default] and silently drops thinking/sampling control
    required by the binding. Empty entries are allowed for focused config
    probes. *)

type missing_catalog_model =
  { runtime_id : string
  ; provider_id : string
  ; provider_label : string
  ; model_id : string
  }
(** Runtime binding whose concrete provider/model pair is absent from the AGENT_CORE
    capability catalog. [provider_label] is the exact AGENT_CORE capability namespace
    used for lookup. *)

type missing_catalog_report =
  { config_path : string
  ; missing_models : missing_catalog_model list
  }

type dropped_runtime_assignment =
  { keeper_name : string
  ; runtime_id : string
  }

type dropped_runtime_route =
  { route_name : string
  ; runtime_id : string
  }

type dropped_runtime_lane =
  { lane_id : string
  ; runtime_ids : string list
  }

type startup_degradation =
  { report : missing_catalog_report
  ; configured_default_runtime_id : string
  ; effective_default_runtime_id : string
  ; disabled_runtime_ids : string list
  ; dropped_assignments : dropped_runtime_assignment list
  ; dropped_routes : dropped_runtime_route list
  ; dropped_media_failover : string list
  ; dropped_lane_candidates : dropped_runtime_lane list
  ; dropped_lanes : dropped_runtime_lane list
  }
(** Operator-visible startup degradation. Missing-catalog runtime bindings are
    removed from the active runtime set so requests never dispatch through AGENT_CORE
    [provider_default]. The server may continue only when at least one
    catalog-known runtime remains and no routing config references a disabled
    runtime id. *)

type init_default_outcome =
  | Initialized
  | Initialized_degraded of startup_degradation

type strict_init_error =
  | Runtime_config_error of string
  | Missing_catalog_models of missing_catalog_report

val strict_init_error_to_string : strict_init_error -> string
val startup_degradation_to_string : startup_degradation -> string
val startup_degradation_to_yojson : startup_degradation option -> Yojson.Safe.t

val load_list :
  config_path:string
  -> ( t list
       * t
       * (string * string) list
       * string list
       * Runtime_lane.t list
     , string )
     result
(** [load_list ~config_path] parses runtime.toml into [(runtimes, default,
    keeper_assignments, media_failover, lanes)].
    Fails ([Error]) if
    [\[runtime\].default] is missing / unresolved, if any
    [\[runtime.assignments\]] target does not resolve to a configured runtime, if any
    [\[runtime\].media_failover] entry does not resolve, or if any
    [\[runtime.lanes.<id>\]] candidate does not resolve (mirrors default
    validation — no silent fallback for a typo'd id). [keeper_assignments] is the
    keeper→runtime-id list; [media_failover] is the RFC-0265 ordered reroute
    list; [lanes] is the ordered failover candidate lists. *)

val runtime_ids : t list -> string list

type request_body_cap_error = Missing_or_non_positive_request_body_cap of
  { runtime_id : string
  }
(** A materialized runtime configuration reaches a Keeper provider boundary
    without a positive serialized-request body ceiling. *)

val request_body_cap_error_to_string : request_body_cap_error -> string

val validate_request_body_cap :
  runtime_id:string
  -> Llm_provider.Provider_config.t
  -> (int, request_body_cap_error) result
(** Pure final-provider-config guard shared by every Keeper provider-call
    boundary. Config admission uses it for statically reachable routes; call
    sites must invoke it again after feature-local transforms. The successful
    value is the exact positive cap validated on that final provider config. *)

type keeper_dispatch_readiness =
  | Dispatchable
  | Missing_request_body_cap of { table_path : string }
      (** Whether a materialized runtime could carry a keeper turn if one were
          routed to it, independent of whether anything routes to it today.
          Boot validation judges only reachable ids on purpose, which left a
          declared-but-unassigned blocked runtime with no observer: listed by
          [/api/v1/runtime/resolved], impossible to assign, and silent about
          why (masc#28404). *)

val keeper_dispatch_readiness : t -> keeper_dispatch_readiness
(** The single definition of "blocked", so the operator-facing projection and
    the fail-closed boot gate cannot disagree. Official-client runtimes are
    always [Dispatchable]: the spawned vendor client owns its own context
    window. *)

val keeper_dispatch_blocker : keeper_dispatch_readiness -> string option
(** Operator-facing reason, [None] when dispatchable. *)

val keeper_dispatch_blocked : t list -> (t * string) list
(** Every runtime a keeper could not be assigned to, in declaration order, with
    its reason. Empty is the healthy state. *)

(** {1 Lazy default runtime singleton}

    Initialized once at startup via {!init_default}.  All consumer
    code that previously resolved a runtime name now calls
    {!get_default_runtime_id} instead. *)

val init_default : config_path:string -> (unit, string) result
(** Parse + RFC-0206 routing validation + populate the singletons. Does NOT apply
    the AGENT_CORE capability-catalog gate (use {!init_default_strict} for fail-closed
    callers or {!init_default_degraded_report} for server boot). Safe for tests
    with arbitrary-model runtime fixtures. *)

val publish_exact_output_registry :
  ?required_lane_ids:string list ->
  lanes:Runtime_schema.exact_output_lane_decl list ->
  Agent_core.Exact_output.resolver_snapshot ->
  (Runtime_exact_output_registry.t, string) result
(** Publish one immutable AGENT_CORE resolver-and-lane snapshot and return that exact
    publication. [required_lane_ids] must each retain an admitted slot; that
    validation happens before the global publication changes. *)

val init_default_strict : config_path:string -> (unit, string) result
(** Fail-closed startup entry point: {!init_default} PLUS the AGENT_CORE
    capability-catalog gate ({!decide_capability_gate}). Rejects ([Error]) a
    runtime whose model is absent from the catalog before boot. Used by strict
    validation callers such as fusion run. *)

val init_default_strict_report :
  config_path:string -> (unit, strict_init_error) result
(** Typed form of {!init_default_strict}. Useful when callers need missing
    catalog models without string-matching the fatal error message. *)

val init_default_degraded_report :
  config_path:string -> (init_default_outcome, strict_init_error) result
(** Server bootstrap entry point. Applies the strict AGENT_CORE catalog gate, but when
    only unreferenced catalog-membership rows fail it can remove uncatalogued
    runtimes from the active runtime set and continue in an operator-visible
    degraded mode. Routing/parse errors, all-missing runtime sets, and explicit
    routing references to uncatalogued runtimes remain fatal so configured intent
    is never erased into default fallback. *)

val init_default_degraded_observation :
  config_observation -> (init_default_outcome, strict_init_error) result
(** Initialize from one immutable source observation so Runtime and sibling
    consumers can use the same exact bytes without a second filesystem read. *)

module For_testing : sig
  type snapshot

  val snapshot : unit -> snapshot
  val restore : snapshot -> unit

  val keeper_dispatch_runtime_ids :
    default_runtime_id:string ->
    assignments:(string * string) list ->
    verifier_exact_slot_ids:string list ->
    media_failover:string list ->
    lanes:Runtime_lane.t list ->
    string list
  (** Ordered, deduplicated runtime ids reachable by Keeper default/assignment
      roots (including a same-named lane's candidates), the explicit
      the [verifier_exact] exact-output lane's declared
      slots (the completion-authority judgement route, RFC-0361 D7(a)), and
      explicit runtime-only media failover routing. Dormant declared lanes are
      excluded. *)

  val save_config_text_with_sync_parent :
    ?runtime_config_path:string ->
    sync_parent:(string -> unit) ->
    string ->
    (config_commit_receipt, string) result
  (** Production-equivalent runtime config replacement with an injected
      parent-directory sync operation. *)

end

val get_default_runtime : unit -> t option
val get_runtimes : unit -> t list
val get_runtime_ids : unit -> string list
val startup_degradation : unit -> startup_degradation option
val startup_degraded : unit -> bool
val runtimes_and_media_failover : unit -> t list * string list
(** Atomically consistent snapshot of configured runtimes plus
    [\[runtime\].media_failover]. Use when both values drive one routing
    decision, so a runtime config refresh cannot interleave between two
    separate reads. *)

val runtime_id_for_keeper : string -> string option
(** [runtime_id_for_keeper keeper_name] is the runtime id assigned to
    [keeper_name] in [\[runtime.assignments\]] (runtime.toml SSOT), or [None]
    when no explicit assignment exists (caller falls back to
    {!get_default_runtime_id}). The id is opaque (only the AGENT_CORE adapter parses
    it). Keeper-to-runtime assignment is not sourced from keeper TOML. *)

val keeper_assignments : unit -> (string * string) list
(** Snapshot of explicit [keeper_name -> runtime_id] assignments loaded from
    [\[runtime.assignments\]]. The list is validated during {!init_default};
    every runtime id in the returned snapshot resolves to a configured runtime.
    Dashboard/operator surfaces use this to expose assignment blast radius
    without parsing TOML independently. *)

type dashboard_runtime_defaults_snapshot =
  { default_runtime : t option
  ; runtimes : t list
  ; media_failover : string list
  ; config_path : string option
  }

val dashboard_runtime_defaults_snapshot : unit -> dashboard_runtime_defaults_snapshot
(** Capture every value consumed by the dashboard runtime-defaults endpoint from
    one immutable loaded-state snapshot. *)

val verifier_exact_lane_id : string
(** ["verifier_exact"] — the [\[runtime.exact_output_lanes.verifier_exact\]]
    lane id (RFC-0361 D7(a)). *)

val verifier_exact_lane_slot_ids : unit -> (string list, string) result
(** Admitted [verifier_exact] slot ids in frozen declaration order from the
    published exact-output registry — the single provider-selection SSOT for
    completion-authority judgement calls. [Error] names why the lane cannot
    judge (registry not published, lane unconfigured, or no admitted slots);
    there is no fallback to another route. *)

val media_failover : unit -> string list
(** [\[runtime\].media_failover] (RFC-0265) — ordered runtime ids consulted when a
    turn's input modality exceeds the assigned runtime's declared capabilities;
    the turn reroutes to the first that admits it. [[]] = derive capable runtimes
    from declared [\[models.*.capabilities\]] in declaration order. Every entry is
    validated at load so each resolves to a configured runtime. *)

val lanes : unit -> Runtime_lane.t list
(** [\[runtime.lanes.<id>\]] ordered failover candidate lists. Each lane carries
    an ordered list of runtime ids validated at load. *)

val get_lane_by_id : string -> Runtime_lane.t option
(** Lane with the given id, or [None] if no such lane is configured. *)

val resolve_assignment : string -> [ `Lane of Runtime_lane.t | `Missing ]
(** Resolve a keeper assignment id to a lane. Declared lanes shadow runtimes;
    an id naming a bare runtime gets a lane of its own, because the lane id is
    what keys sticky candidate preference and quota demotion. Every lane ends
    at [\[runtime\].default], so a walk always has a next candidate.
    [Missing] means the id does not name a known lane or runtime. *)

val get_runtime_by_id : string -> t option
(** [get_runtime_by_id id] is the materialized runtime whose binding-key id
    ["provider.model"] equals [id], or [None] if no such runtime is configured.
    Used by the keeper turn driver to dispatch to the requested runtime (a
    keeper's runtime assignment or the default); [None] makes the driver
    fail fast rather than silently substituting the default (RFC-0207). *)

val is_local_runtime : t -> bool
(** [is_local_runtime rt] classifies runtime locality from the materialized
    provider schema: CLI transports are local; HTTP transports are local only
    when their endpoint is loopback and the provider declares no credential. *)

val is_local_runtime_id : string -> bool option
(** Locality classification for a configured runtime id, or [None] when the
    runtime id is not currently materialized. *)

type max_context_source =
  | Override (** runtime.toml [model.max-context] override applies as-is. *)
  | Capability (** no override configured; the AGENT_CORE capability catalog cap applies. *)
  | Override_clamped_by_capability
      (** an override is configured but exceeds the AGENT_CORE capability catalog
          cap, so the cap wins. *)

val max_context_source_to_string : max_context_source -> string
(** ["override"] / ["capability"] / ["override_clamped_by_capability"] — wire
    label for the [/api/v1/runtime/resolved] document. *)

val resolve_max_context_of_runtime : t -> (int * max_context_source) option
(** Effective input context window and the source that produced it. [None]
    when neither the runtime.toml [model.max-context] override nor the AGENT_CORE
    capability catalog declares a positive context window for this binding;
    [materialize_config] rejects such a runtime at load (fail-closed), so a
    materialized [t] obtained from {!get_runtimes}/{!get_runtime_by_id} never
    observes [None] here in practice. *)

val max_context_of_runtime : t -> int
(** Effective input context window for a materialized runtime.  This applies the
    same provider-cap clamp as [max_context_of_runtime_id] without re-resolving
    the runtime id. Derived from {!resolve_max_context_of_runtime}.
    @raise Failure if that resolves to [None] — unreachable for any [t]
    produced by {!materialize_config}, which rejects a runtime whose max
    context cannot be resolved at load time (no silent default —
    RFC-0206 §2.1). *)

val resolve_max_context_of_runtime_id : string -> (int * max_context_source) option
(** {!resolve_max_context_of_runtime} looked up by runtime id: the effective
    input context window together with the source that produced it, or [None]
    when the id is not configured. Budget surfaces must carry the source —
    dropping it rendered a runtime.toml override as ["runtime_provider_cap"]
    in keeper status JSON, which disguised the #25463 config drift as a
    provider fact. *)

val max_context_of_runtime_id : string -> int option
(** Effective input context window for the materialized runtime [id], or [None]
    when the id is not configured.  Budgeting callers use this to size a
    per-keeper routed turn against the same runtime that dispatch will use.
    When the AGENT_CORE provider capability catalog declares a context cap, the value
    is clamped to [min runtime.toml max-context provider cap] so MASC cannot
    admit a prompt larger than the provider-owned window. *)

val max_output_tokens_of_runtime_id : string -> int option
(** Declared max output tokens (AGENT_CORE capability catalog) for the model bound to
    runtime [id], or [None] when the id is not configured or the catalog leaves
    it unset. This is an observable capability ceiling only; AGENT_CORE owns request
    validation and clamp policy, and MASC never turns it into a request
    default. *)

val thinking_support_of_runtime_id : string -> bool option
(** [thinking-support] capability of the model bound to runtime [id], or [None]
    when the id is not configured (e.g. before {!init_default}).  Consumed by
    {!Runtime_inference.for_runtime} to gate keeper thinking per model from the
    runtime.toml SSOT. *)

val temperature_of_runtime_id : string -> float option
(** Per-model [temperature] override ([models.<id>.temperature] in runtime.toml)
    for the model bound to runtime [id], or [None] when the id is not configured
    or the model leaves it unset.  Consumed by
    {!Runtime_inference.resolve_temperature}: a keeper turn uses this value when
    set and its caller fallback ([MASC_KEEPER_UNIFIED_TEMP]) otherwise.  Required
    for models that reject the default temperature (Kimi K2.7 accepts only 1.0). *)

val reasoning_effort_of_runtime_id : string -> Llm_provider.Reasoning_effort.t option
(** Per-model [reasoning-effort] from runtime.toml, or [None] when unset or
    the runtime id is unknown. Consumed by
    {!Runtime_inference.resolve_reasoning_effort}. *)

val turn_timeout_s_of_runtime_id : string -> float option
(** Per-model [turn-timeout-s] from runtime.toml, or [None] when unset or the
    runtime id is unknown. Official-client adapters interpret it as the maximum
    silence between protocol messages, not total turn duration. [None] means
    "keep whatever bound the caller already has". Consumed by
    {!Runtime_inference.resolve_turn_timeout_s}. *)

val wall_clock_ceiling_s_of_runtime_id : string -> float option
(** Per-model [wall-clock-ceiling-s] from runtime.toml, or [None] when unset
    or the runtime id is unknown. Bounds one official-client turn's total
    duration and never resets on protocol messages ({!Runtime_wall_clock});
    [None] keeps the runtime default ceiling. Consumed by
    {!Runtime_inference.resolve_wall_clock_ceiling_s}. *)

val quota_scope_of_runtime : t -> Runtime_quota_window.scope
(** Non-secret quota-scope identity derived from this resolved runtime
    snapshot.  Use this form across a provider call so a concurrent catalog
    reload cannot rebind the response to a different credential account. *)

val quota_scope_of_runtime_id : string -> Runtime_quota_window.scope option
(** Non-secret quota-scope identity of the runtime's provider
    ({!Runtime_quota_window.scope_of_credential}): rows sharing one
    credential account share one scope, so an exhausted window recorded on
    one row demotes every sibling backed by the same account. [None] when
    the runtime id is unknown. Consumed by
    {!Runtime_quota_window.demote_order} and the matching note site. *)

val max_prompt_bytes_of_runtime_id : string -> int option
(** Declared [max-prompt-bytes] for the model bound to this runtime id, or
    [None] when the model declares none. *)

val declared_input_byte_ceiling_of_runtime_id : string -> int option
(** The smaller of the two byte ceilings a runtime declares over its model
    input: the model's [max-prompt-bytes] and the binding's
    [max-request-body-bytes]. Which one a given path enforces differs —
    [Keeper_antigravity_runtime] projects against the first, the generic
    driver against the second through {!validate_request_body_cap} — so a
    caller that must fit inside whatever this runtime enforces satisfies both.
    [None] when neither is declared, which is the same answer those paths give
    such a runtime.

    The two count different things (prompt bytes against whole-request bytes),
    so this is a ceiling for something known to be one part of the input, not
    a budget for the input itself. *)

val top_p_of_runtime_id : string -> float option
(** Request [top_p] from the materialized AGENT_CORE provider config for runtime [id],
    or [None] when the runtime is not configured or no explicit value is
    declared.  This projects the Provider_config SSOT used for dispatch. *)

(** Request [top_k] from the materialized AGENT_CORE provider config for runtime [id],
    or [None] when absent. *)

(** Request [min_p] from the materialized AGENT_CORE provider config for runtime [id],
    or [None] when absent. *)

val preserve_thinking_of_runtime_id : string -> bool option
(** Explicit [preserve-thinking] for runtime [id]. [None] means unknown runtime,
    uninitialized cache, or no explicit TOML field.

    AGENT_CORE owns provider/model capability truth and applies provider-required
    reasoning replay internally. MASC does not promote a request-side preserve
    capability into default keeper policy. Consumed by
    {!Runtime_inference.for_runtime} without provider/model string matching. *)

val pricing_of_runtime_id : string -> float option * float option
(** [(price_input, price_output)] per-million-token USD rates declared on the
    runtime [id] binding in runtime.toml, or [(None, None)] when the runtime is
    not configured or the operator left the rates unset.  Consumed by the
    turn-record writer (RFC-0233 §8) so the dashboard renders actual cost or
    absence rather than a fabricated Claude default. *)

val get_default_runtime_id : unit -> string
(** @raise Failure if {!init_default} has not run. No silent fallback
    (RFC-0206 §2.1): an unresolved default is a startup-ordering bug, not a
    recoverable condition. Callers must invoke this at runtime, never as a
    module-level [let] binding (would crash config-less test binaries). *)

val config_path : unit -> string option
(** Path to the runtime config TOML, or [None] if unresolved. Re-homed from
    deleted [Runtime.config_path] (delegates to
    [Config_dir_resolver]). *)

val runtime_config_path_missing_message : string
(** The one spelling of "no runtime config path resolves", shared by both
    error producers and the dashboard route that maps it to 404. Consumers
    that need to BRANCH on the condition use {!config_path} (or the typed
    results) rather than matching this sentence. *)

val load_config_observation :
  ?runtime_config_path:string -> unit -> (config_observation, string) result
(** Load one immutable runtime.toml observation, including its exact source
    revision. *)

val update_runtime_assignment_text :
  string -> keeper_name:string -> runtime_id:string -> string
(** runtime.toml text with [keeper_name] assigned to [runtime_id] in
    [\[runtime.assignments\]]: the row is replaced or appended, the section
    is created when absent, every other line is kept. Keys are quoted, so a
    dotted keeper name stays one key. Pure; the commit is the caller's. *)

val remove_runtime_assignment_text : string -> keeper_name:string -> string
(** runtime.toml text without [keeper_name]'s row. Pure. *)

val update_egress_allow_text : string -> keeper_name:string -> allow:string list -> string
(** runtime.toml text with [keeper_name]'s [\[egress.keepers.<name>\]] table
    holding exactly [allow] (RFC-0415). The table is replaced or appended,
    every other line is kept, and the replacement is wholesale rather than a
    merge: an allowlist is the complete statement of what a keeper may reach,
    so a write that kept unnamed entries would leave an operator unable to
    remove one. Pure; the commit is the caller's. *)

val remove_egress_allow_text : string -> keeper_name:string -> string
(** runtime.toml text without [keeper_name]'s egress table. The keeper then
    has no allowlist, which admits nothing rather than everything. Pure. *)

val save_config_text :
  ?runtime_config_path:string -> string -> (config_commit_receipt, string) result
(** Validate raw runtime.toml and prepare its exact-output replacement without
    changing or credential-resolving the active frozen registry. The writer
    then reserves that exact base and atomically replaces the file. A failure
    before rename leaves the published registry and runtime cache unchanged.
    Once rename is visible, the prepared immutable registry and runtime cache
    are synchronously converged even when parent-directory fsync fails; that
    durability-uncertain case returns an [Ok] receipt carrying
    [Durability_unconfirmed], because the replacement is already visible. A
    fully durable replacement returns an [Ok] receipt carrying [Durable]. Before exact-output registry bootstrap,
    the same write-stage rules apply to the runtime cache while the registry
    remains unpublished. *)

val edit_config_text :
  ?runtime_config_path:string ->
  (string -> string) ->
  (config_commit_receipt, string) result
(** Read runtime.toml, hand its text to [edit], and commit what comes back --
    all three inside the config write lock, so a write that lands between the
    read and the commit cannot be silently overwritten. Everything after the
    edit is {!save_config_text}'s: the same validation, the same atomic
    replace, the same receipt. Use this rather than loading the file and
    calling {!save_config_text}, which leaves that gap open. *)

val validate_config_text :
  ?runtime_config_path:string -> string -> (unit, string) result
(** Run the raw runtime.toml save precondition — TOML parse, ordered Skill
    source validation, config materialization, and dispatch-cap validation —
    without writing or mutating the active registry. Preview endpoints call
    this so [can_save] reflects the same rejection {!save_config_text}
    enforces. Returns [Ok ()] when the text would be accepted for save;
    [Error msg] with the reason otherwise. *)

val set_runtime_id_for_keeper :
  ?runtime_config_path:string ->
  keeper_name:string ->
  runtime_id:string ->
  unit ->
  (keeper_assignment_write config_lock_receipt, string) result
(** Persist [keeper_name] -> [runtime_id] in
    [\[runtime.assignments\]] (runtime.toml SSOT), validate the resulting
    runtime config, atomically write it, and refresh the in-process runtime
    assignment cache. *)

val clear_runtime_id_for_keeper :
  ?runtime_config_path:string ->
  keeper_name:string ->
  unit ->
  (keeper_assignment_write config_lock_receipt, string) result
(** Remove [keeper_name] from [\[runtime.assignments\]], validate the resulting
    runtime config, atomically write it, and refresh the in-process runtime
    assignment cache. *)

val set_runtime_default :
  ?runtime_config_path:string ->
  runtime_id:string ->
  unit ->
  (config_commit_receipt, string) result
(** Persist [\[runtime\]].default through the runtime.toml SSOT writer,
    validate the resulting config, atomically write it, and refresh the
    in-process runtime cache. *)

val set_runtime_media_failover :
  ?runtime_config_path:string ->
  runtime_ids:string list ->
  unit ->
  (config_commit_receipt, string) result
(** Persist [\[runtime\]].media_failover through the runtime.toml SSOT writer,
    validate the resulting config, atomically write it, and refresh the
    in-process runtime cache. The list order is preserved. *)

val set_runtime_lane_candidates :
  ?runtime_config_path:string ->
  lane_id:string ->
  runtime_ids:string list ->
  unit ->
  (config_commit_receipt, string) result
(** Persist [\[runtime.lanes."<lane_id>"\]].candidates through the runtime.toml
    SSOT writer, validate the resulting config, atomically write it, and refresh
    the in-process runtime cache. The list order is the failover order. Creates
    the lane table when the id has none — a runtime whose lane was synthesized
    ([self, default]) becomes a declared lane the first time an operator adds a
    candidate to it. An empty [runtime_ids] is rejected: a lane that resolves to
    nothing is not the same edit as removing the lane. *)

val default_max_context : unit -> int
(** Effective context-window budget of the default runtime's model (RFC-0206
    single-binding), clamped by the AGENT_CORE provider capability catalog when that
    cap is available. Replaces the deleted
    [Runtime_runtime.resolve_*_max_context] label scans. Falls back to
    [Runtime_constants.fallback_context_window] before {!init_default} runs. *)

(** API model name of the default runtime, sent to the runtime completion
    endpoint (RFC-0206 single-binding). Replaces the deleted
    [Runtime_runtime.default_local_model_label_and_id]. Falls back to ["auto"]
    before {!init_default} runs. *)
