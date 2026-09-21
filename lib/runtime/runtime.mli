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
  ; candidate_backpressure : Runtime_candidate_backpressure.candidate
    (** Candidate-only backpressure tied to the frozen dispatch binding. *)
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

val config_observation : path:string -> string -> config_observation
(** Pure source identity used inside callers' locked config edits. *)

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
    lock must always acquire that manifest lock first. An unresolved journal
    rejects the callback before it observes or mutates the assignment. *)

val keeper_assignment_revision :
  keeper_assignment_transaction -> keeper_assignment_revision

val keeper_assignment_transaction_path : keeper_assignment_transaction -> string option

val commit_keeper_assignment :
  ?egress_allow:string list ->
  keeper_assignment_transaction ->
  runtime_id:string option ->
  (keeper_assignment_write, string) result
(** Compose the assignment and optional egress allowlist into one source
    commit. [runtime_id=None] clears the assignment; omitted [egress_allow]
    preserves the allowlist. The receipt describes the final source revision.
    [Assignment_unchanged] means neither setting changed the source bytes. *)

val restore_keeper_assignment_transaction :
  keeper_assignment_transaction -> (keeper_assignment_write, string) result
(** Restore the exact [runtime.toml] source bytes captured when the
    transaction began. The caller must still be inside the transaction
    callback, so no other admitted runtime writer can interleave. *)

val commit_keeper_removal :
  keeper_assignment_transaction -> (keeper_assignment_write, string) result
(** Remove this exact Keeper's runtime assignment and egress override in one
    source commit, preserving other Keepers' settings. *)

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

type reference_shape =
  | Scalar
  | List_entry
      (** How a reference names its id. A list entry reads as [field entry "id"]
          and a scalar as [field = "id"]; keeping both apart stops a message
          from telling an operator a list field equals one id. *)

type resolution_failure =
  { unresolved_id : string
  ; declared_drop : drop_reason option
  ; runtime_count : int
  }
(** Why an id did not resolve to a runtime. [reason] is the binding's own drop
    reason when one was declared under that id, [None] when nothing declared
    it. *)

type load_failure =
  | Toml_unparsable of Runtime_toml.parse_error list
  | Undeclared_bindings of (string * drop_reason) list
  | Default_runtime_absent
  | Default_runtime_unresolved of resolution_failure
  | Reference_unresolved of
      { site : string
      ; shape : reference_shape
      ; resolution : resolution_failure
      }
  | Lane_candidate_unresolved of
      { lane_id : string
      ; resolution : resolution_failure
      }
  | Max_context_absent of
      { runtime_id : string
      ; execution_model : string
      ; declared_model : string
      }
  | Context_marks_exceed_max_context of
      { runtime_id : string
      ; high_water_tokens : int
      ; max_context : int
      }
      (** Why {!load_list} refused a configuration. Closed, so a consumer
          decides per case instead of matching rendered text — the contract
          {!drop_reason} keeps one level down. [Toml_unparsable] is the one case
          whose text comes from the parser and can quote operator input; the
          rest name ids and config keys this repository authored. *)

val to_diagnostic_text : config_path:string -> load_failure -> string
(** The operator-facing account of a refused configuration, and the wording the
    CLI has always printed. A consumer that shows a failure to a person on a
    surface where parser text is unwelcome should match on the case instead. *)

val to_operator_text : config_path:string -> load_failure -> string
(** The same account with the parser's own text withheld: {!Toml_unparsable}
    renders as a count and a pointer at [masc runtime-probe], every other case
    identically to {!to_diagnostic_text}. *)

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


type missing_catalog_model =
  { runtime_id : string
  ; provider_id : string
  ; provider_label : string
  ; model_id : string
  }
(** Runtime binding whose concrete provider/model pair is absent from the AGENT_CORE
    capability catalog. [provider_label] is the exact AGENT_CORE capability namespace
    used for lookup. *)

val missing_catalog_model_to_string : missing_catalog_model -> string
(** Exact configured runtime/provider/model identity for unavailable-route diagnostics. *)

type missing_catalog_report =
  { config_path : string
  ; missing_models : missing_catalog_model list
  }

type unavailable_runtime_assignment =
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
  ; unavailable_assignments : unavailable_runtime_assignment list
  ; dropped_routes : dropped_runtime_route list
  ; dropped_media_failover : string list
  ; dropped_lane_candidates : dropped_runtime_lane list
  ; dropped_lanes : dropped_runtime_lane list
  }
(** Operator-visible startup degradation. Missing-catalog runtime bindings are
    removed from the active runtime set so requests never dispatch through AGENT_CORE
    [provider_default]. The server may continue only when at least one
    catalog-known default remains and no default/lane/media route references a
    disabled runtime. Explicit Keeper assignments retain their configured IDs;
    only affected Keepers resolve to [Unavailable] and cannot dispatch. *)

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
     , load_failure )
     result
(** [load_list ~config_path] parses runtime.toml into [(runtimes, default,
    keeper_assignments, media_failover, lanes)].
    Fails ([Error]) if
    [\[runtime\].default] is missing / unresolved, if any
    [\[runtime.assignments\]] target names neither a declared lane nor a
    configured runtime, if any
    [\[runtime\].media_failover] entry does not resolve, or if any
    [\[runtime.lanes.<id>\]] candidate does not resolve (mirrors default
    validation — no silent fallback for a typo'd id). [keeper_assignments] is the
    keeper→lane-name-or-runtime-id list; [media_failover] is the vision read fleet;
    [lanes] is the ordered failover candidate lists. *)


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
(** Fail-closed startup entry point: {!init_default} plus the capability check
    on the materialized runtime list. Rejects ([Error]) a binding whose model
    the AGENT_CORE catalog does not carry and whose runtime block declares no
    capabilities of its own. Used by strict validation callers such as fusion
    run. *)

val init_default_strict_report :
  config_path:string -> (unit, strict_init_error) result
(** Typed form of {!init_default_strict}. Useful when callers need missing
    catalog models without string-matching the fatal error message. *)

val init_default_degraded_report :
  config_path:string -> (init_default_outcome, strict_init_error) result
(** Server bootstrap entry point. Applies the strict AGENT_CORE catalog gate, but when
    catalog-membership rows fail it can remove uncatalogued runtimes from the
    active set and continue in an operator-visible degraded mode. Explicit
    Keeper assignments retain their IDs and resolve to [Unavailable]. Parse
    errors, all-missing runtime sets, and missing default/lane/media routes
    remain fatal; no configured route is replaced by an implicit fallback. *)

val init_default_degraded_observation :
  config_observation -> (init_default_outcome, strict_init_error) result
(** Initialize from one immutable source observation so Runtime and sibling
    consumers can use the same exact bytes without a second filesystem read. *)

module For_testing : sig
  type snapshot

  val snapshot : unit -> snapshot
  val restore : snapshot -> unit

  val with_config_lock_with_journal_sync_parent :
    sync_parent:(string -> unit) -> runtime_config_path:string ->
    (unit -> unit) -> (unit, string) result
  (** Production writer admission with an injected journal-parent sync. *)

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
(** [runtime_id_for_keeper keeper_name] is the route [keeper_name] is assigned
    in [\[runtime.assignments\]] (runtime.toml SSOT) — a declared lane name or a
    runtime id — or [None] when no explicit assignment exists (caller falls back
    to {!get_default_runtime_id}). It is a routing label, not necessarily a
    materialized binding: pass it to {!resolve_assignment} to walk the lane, or
    to {!entry_runtime_id_of_route} for the binding the turn opens first. The id is opaque (only the AGENT_CORE adapter parses
    it). Keeper-to-runtime assignment is not sourced from keeper TOML. *)

val keeper_assignments : unit -> (string * string) list
(** Snapshot of explicit [keeper_name -> runtime_id] assignments loaded from
    [\[runtime.assignments\]]. The list is validated during {!init_default};
    a catalog-unavailable assignment retains its exact configured runtime ID.
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

type exact_lane =
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Workspace_curator
  | Verifier

val all_exact_lanes : exact_lane list
(** Every exact-output lane. *)

val exact_lane_id : exact_lane -> string
(** The lane table key under [\[runtime.exact_output_lanes\]]. *)

val exact_lane_of_id : string -> exact_lane option
(** Parse a lane table key into the closed exact-output lane variant. *)

val exact_lane_supports_cli_tail : exact_lane -> bool
(** Whether this exact lane can walk official-client [cli_slots] when HTTP
    provider slots are absent or exhausted. Verifier uses the managed tool-call
    runner and its typed verdict callback. *)

val verifier_exact_lane_id : string
(** ["verifier_exact"] — the [\[runtime.exact_output_lanes.verifier_exact\]]
    lane id (RFC-0361 D7(a)). *)

val verifier_runtime_admission : t -> (unit, string) result
(** The one answer to "can this runtime judge a completion review?", used by
    lane resolution, readiness, dispatch and the runtime-file writer.

    A verifier candidate must expose mediated tools without native reads, which
    Agent Core and Claude Code meet and other official clients do not. An Agent
    Core binding must additionally take inline tools and a system prompt,
    because the review is dispatched with required tools and the managed
    verification.system prompt: without either, the dispatch is refused one
    attempt later by [Keeper_required_tools] or by AGENT_CORE's
    [Unsupported_system_prompt] (#37382). *)

val verifier_cli_slot_admission : runtime_id:string -> (unit, string) result
(** Admit the exact official-client binding with required tool support, without
    expanding any same-named Keeper lane. Lane-only IDs, Agent Core runtimes,
    and clients without native-tool suppression are refused. *)

val verifier_cli_slot_admission_in
  :  runtimes:t list
  -> lane_ids:string list
  -> runtime_id:string
  -> (unit, string) result
(** {!verifier_cli_slot_admission} over an explicit runtime table, for the
    runtime-file writer, which judges the table it just parsed rather than the
    loaded one. Both entry points must reach the same verdict: a slot one
    spelling admits and another refuses is what #37179 was. *)

type verifier_slot_rejection =
  { position : int
  ; slot_id : string
  ; detail : string
  }
(** One declared [verifier_exact] slot the lane cannot judge through.
    [position] counts from 1 across the whole lane declaration, catalog slots
    first, so it names the same line of runtime.toml as the registry's own
    rejected-slot report. *)

type verifier_exact_lane_slots =
  { admitted_catalog_slot_ids : string list
  ; admitted_cli_slot_ids : string list
  ; slot_rejections : verifier_slot_rejection list
  }

val verifier_slot_rejection_to_string : verifier_slot_rejection -> string

val verifier_catalog_slot_admission : runtime_id:string -> (unit, string) result
(** {!verifier_runtime_admission} for an id written in [verifier_exact.slots].
    Judgement dispatches that id alone, so it must name a configured runtime;
    whether the same id is also an exact-output target is the registry's
    question, not this one. *)

val verifier_exact_lane_admission
  :  declared:Runtime_schema.exact_output_lane_decl
  -> registry_admitted_catalog_slots:string list
  -> verifier_exact_lane_slots
(** Split one declared lane into the ids that can judge and the ones that
    cannot, numbering positions from the declaration so a rejected sibling does
    not shift them. A catalog slot absent from
    [registry_admitted_catalog_slots] is skipped rather than rejected again:
    publication already reports it, with a cause this module cannot see. *)

val verifier_exact_lane_resolution : unit -> (verifier_exact_lane_slots, string) result
(** {!verifier_exact_lane_admission} applied to the published lane. The
    registry carries the ids verbatim because only this module holds the
    runtime table that answers admission. *)

val verifier_exact_lane_slot_ids : unit -> (string list, string) result
(** The slot ids this lane can judge through, catalog first then official
    clients, in declaration order — the single provider-selection SSOT for
    completion-authority judgement calls. [Error] names why the lane cannot
    judge (registry not published, lane unconfigured, or every declared slot
    rejected); there is no fallback to another route. *)

val verifier_exact_lane_readiness : unit -> (verifier_slot_rejection list, string) result
(** Whether the [verifier_exact] lane has a slot that can be dispatched now,
    for a caller that reports authority readiness rather than walking the lane.
    [Ok] carries the declared slots the lane cannot judge through, so a short
    lane says why it is short; [Error] names every rejection. This answers from
    the same admission as {!verifier_exact_lane_slot_ids}: the two used to
    apply different predicates to catalog slots, and that disagreement let the
    authority start on a lane that refused every review (#37382). *)

val verifier_exact_slot_admission : runtime_id:string -> (unit, string) result
(** Validate one configured direct slot. A declared CLI slot retains its
    execution-kind constraint; a replacing registry cannot grant admission. *)

val media_failover : unit -> string list
(** [\[runtime\].media_failover] — the vision read fleet: ordered runtime ids the
    vision tool calls, including the image readings made for a runtime that
    cannot take the image. A keeper turn never dispatches to them; its image
    reroute stays inside its lane. [[]] = no vision fleet. Every entry is
    validated at load so each resolves to a configured runtime. *)

val lanes : unit -> Runtime_lane.t list
(** [\[runtime.lanes.<id>\]] ordered failover candidate lists. Each lane carries
    an ordered list of runtime ids validated at load. *)

val lsp_servers : unit -> Lsp_process_manager.language -> string * string list
(** [\[lsp.servers\]] applied over the client's own table: the command that
    starts a language's server, the operator's where one was written for that
    language. Pass it as [~servers] to the language-server pool and spawn. *)

val get_lane_by_id : string -> Runtime_lane.t option
(** Lane with the given id, or [None] if no such lane is configured. *)

val resolve_assignment :
  string -> [ `Lane of Runtime_lane.t | `Unavailable of missing_catalog_model | `Missing ]
(** Resolve a keeper assignment to a lane. The id names a declared lane or a
    runtime, and a lane of that name is taken first; an id naming a bare runtime
    resolves to a lane holding that runtime alone. A lane walks exactly the
    candidates it declares.
    [Unavailable] preserves the configured identity when its capability catalog
    entry is absent. [Missing] means the id was not configured. Neither selects
    the default in place of the requested runtime. *)

val entry_runtime_id_of_route : string -> string option
(** The concrete binding id a route opens first: the declared lane's entry
    candidate, or the runtime itself when the route names one. [None] when the
    route names neither. Callers needing a materialized runtime resolve the
    route here first — {!get_runtime_by_id} knows nothing about lanes and
    answers [None] for a lane name. *)

val get_runtime_by_id : string -> t option
(** [get_runtime_by_id id] is the materialized runtime whose binding-key id
    ["provider.model"] equals [id], or [None] if that runtime is not active.
    {!resolve_assignment} distinguishes a catalog-unavailable configured ID
    from an unknown ID. Used by the keeper turn driver to dispatch to the requested runtime (a
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
(** Explicit [thinking-support] policy for the runtime's model. [None] means
    the field is absent or the runtime is not configured. Consumed by
    {!Runtime_inference.for_runtime}; absence must not become a disable request. *)

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

val context_marks_of_runtime_id : string -> Runtime_schema.context_marks option
(** The binding's eviction marks, or [None] when the binding declares none
    (the keeper then evicts carried history only on a provider refusal). *)

val validate_runtime_context_marks : t list -> (unit, load_failure) result
(** Refuses a runtime whose high-water mark exceeds its resolved max-context;
    such a request is refused by the provider before the mark is reached. *)

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

val set_first_run_runtime :
  ?runtime_config_path:string ->
  ?fallback_runtime_ids:string list ->
  ?bind_imp:bool ->
  runtime_id:string ->
  unit ->
  (config_commit_receipt, string) result
(** Atomically select the default runtime and bind the librarian, Board attention,
    Host Gate judge, and verifier exact-output lanes to that same runtime.
    The declared lane named after the primary runtime contains that runtime followed
    by [fallback_runtime_ids], in order. Exact-output lanes remain primary-only:
    HTTP runtimes use catalog slots; official clients use CLI slots. All candidates
    must be distinct, enabled, materialized runtime IDs. Keeper assignments are
    preserved unless [bind_imp] explicitly selects this lane for imp (default false).
    Other Keeper assignments are always preserved. Intended
    for an explicit first-install setup action, since existing lane choices
    are replaced. Validation failures leave the configuration unchanged. *)

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
    ([self]) becomes a declared lane the first time an operator adds a
    candidate to it. An empty [runtime_ids] is rejected: a lane that resolves to
    nothing is not the same edit as removing the lane. *)

val create_runtime_lane :
  ?runtime_config_path:string ->
  lane_id:string ->
  runtime_ids:string list ->
  unit ->
  (config_commit_receipt, string) result
(** Declare a new [\[runtime.lanes."<lane_id>"\]] with [runtime_ids] as its
    candidates, through the same validated write as
    {!set_runtime_lane_candidates}. Both refusals read the file under the
    write lock:
    - the file already declares that lane: a create that landed on it would
      replace its candidates without the operator having seen them;
    - [lane_id] is a declared runtime id: the lane would shadow that runtime
      for every keeper that names it, and for every unassigned keeper when it
      is the default. A runtime's own lane is edited with
      {!set_runtime_lane_candidates}. *)

val remove_runtime_lane :
  ?runtime_config_path:string ->
  lane_id:string ->
  unit ->
  (config_commit_receipt, string) result
(** Remove the [\[runtime.lanes."<lane_id>"\]] table through the runtime.toml
    SSOT writer. Refused while a keeper still routes through the lane id,
    naming each way it does: an entry of [\[runtime.assignments\]], or
    [\[runtime\].default], which every unassigned keeper walks. A keeper's
    route is read as a lane before a runtime ({!resolve_assignment}), so
    removing the lane would either fail the load or silently hand those
    keepers the runtime of the same id. Refused when the file does not declare
    the lane as its own table. *)

val set_exact_output_lane_slots :
  ?runtime_config_path:string ->
  lane:exact_lane ->
  slots:string list ->
  unit ->
  (config_commit_receipt, string) result
(** Persist [\[runtime.exact_output_lanes.<id>\]].slots the same way
    {!set_runtime_lane_candidates} persists conversation-lane candidates: the
    SSOT writer, full validation, atomic write, cache refresh. The list order
    is the walk order of the lane. An empty [slots] is rejected — mandatory
    exact lanes fail the boot fail-closed without one, so a lane that resolves
    to nothing is not the edit an operator is making. A lane the file does not
    declare yet gets its table; [lane] is one of the lanes the server runs, so
    that table is read. A lane the file declares other than as its own table
    (inline, or through dotted keys) is refused rather than declared twice, and
    so is a slot the lane already declares as a CLI slot. *)

val append_exact_output_lane_slot :
  ?runtime_config_path:string ->
  lane:exact_lane ->
  slot:string ->
  unit ->
  (config_commit_receipt, string) result
(** Add [slot] to the end of [\[runtime.exact_output_lanes.<id>\]].slots as
    the file declares them, read under the runtime.toml write lock, and commit
    the result like {!set_exact_output_lane_slots}. Declared slots the
    exact-output registry did not admit stay in place. Refused, by name, when
    the lane already declares [slot] as a slot or as a CLI slot. Tables are
    created and refused as {!set_exact_output_lane_slots} says. *)

type exact_slot_move =
  | Move_slot_up
  | Move_slot_down
      (** Which way {!move_exact_output_lane_slot} walks a slot through the
          declared order, which is the order the lane walks. *)

val drop_exact_output_lane_slot :
  ?runtime_config_path:string ->
  lane:exact_lane ->
  slot:string ->
  unit ->
  (config_commit_receipt, string) result
(** Take [slot] out of [\[runtime.exact_output_lanes.<id>\]].slots as the file
    declares them, read under the write lock for the reason
    {!append_exact_output_lane_slot} gives: the caller names one slot rather
    than an order rebuilt from the admitted view, so declared slots the
    registry rejected stay. Refused when the lane declares no such slot,
    naming what it does declare, and when [slot] is its last one -- a lane
    that resolves to nothing is not this edit; remove the lane's table. *)

val move_exact_output_lane_slot :
  ?runtime_config_path:string ->
  lane:exact_lane ->
  slot:string ->
  move:exact_slot_move ->
  unit ->
  (config_commit_receipt, string) result
(** Exchange [slot] with its neighbour in the declared order, read under the
    write lock like {!drop_exact_output_lane_slot}. Refused when the lane
    declares no such slot, and when the slot is already at the end the move
    heads for. CLI slots are a separate list and do not move. *)

val enter_setup_required : reason:Runtime_startup_state.reason -> unit -> unit
(** Clear model dispatch state after startup configuration failure. Owner and
    workspace readiness are managed independently by server bootstrap. *)

val with_config_lock : runtime_config_path:string -> (unit -> ('a, string) result) -> ('a, string) result
(** Serialize an owner configuration activation with the existing file writers.
    Reject an unresolved configuration journal before invoking the action.
    The action must not recursively invoke a config writer. *)

val with_manifest_config_lock :
  runtime_config_path:string -> manifest_path:string ->
  (unit -> ('a, string) result) -> ('a, string) result
(** Manifest-only mutations use the same manifest-then-runtime lock order as
    composite Keeper configuration writes. The action must not reacquire either
    lock. Both locks cover the authoritative read and mutation. *)
