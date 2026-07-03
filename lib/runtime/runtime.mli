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
  ; provider_config : Llm_provider.Provider_config.t
  }

val id_of_binding : binding -> string
val of_binding : config -> binding -> t option

val of_binding_result : config -> binding -> (t, string) result
(** Reason-preserving form of {!of_binding}. [Error reason] when the binding's
    provider/model id is unresolved or the provider transport/protocol cannot be
    materialized into a {!Llm_provider.Provider_config.t} (e.g. a [messages-http]
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
    [(label, known_to_oas_catalog)] per runtime binding. Returns [Error] when any
    configured model is unknown to the OAS capability catalog: an unknown model
    resolves to [provider_default] and silently drops thinking/sampling control
    (corrupted the memory-os librarian for minimax-m3, 2026-06-19). Empty entries
    are allowed for focused config probes. *)

type missing_catalog_model =
  { runtime_id : string
  ; provider_id : string
  ; provider_label : string
  ; model_id : string
  }
(** Runtime binding whose concrete provider/model pair is absent from the OAS
    capability catalog. [provider_label] is the exact OAS capability namespace
    used for lookup. *)

type missing_catalog_report =
  { config_path : string
  ; missing_models : missing_catalog_model list
  }

type strict_init_error =
  | Runtime_config_error of string
  | Missing_catalog_models of missing_catalog_report

val strict_init_error_to_string : strict_init_error -> string

val load_list :
  config_path:string
  -> ( t list
       * t
       * (string * string) list
       * string option
       * string option
       * string option
       * string list
       * Runtime_lane.t list
     , string )
     result
(** [load_list ~config_path] parses runtime.toml into [(runtimes, default,
    keeper_assignments, librarian_runtime_id, structured_judge_runtime_id,
    cross_verifier_runtime_id, media_failover, lanes)]. Fails ([Error]) if
    [\[runtime\].default] is missing / unresolved, if any
    [\[runtime.assignments\]] target does not resolve to a configured runtime, if
    [\[runtime\].librarian] / [\[runtime\].structured_judge] /
    [\[runtime\].cross_verifier] is set to an unresolved id, if any
    [\[runtime\].media_failover] entry does not resolve, or if any
    [\[runtime.lanes.<id>\]] candidate does not resolve (mirrors default
    validation — no silent fallback for a typo'd id). [keeper_assignments] is the
    keeper→runtime-id list; [media_failover] is the RFC-0265 ordered reroute
    list; [lanes] is the ordered failover candidate lists. *)

val runtime_ids : t list -> string list

(** {1 Lazy default runtime singleton}

    Initialized once at startup via {!init_default}.  All consumer
    code that previously resolved a runtime name now calls
    {!get_default_runtime_id} instead. *)

val init_default : config_path:string -> (unit, string) result
(** Parse + RFC-0206 routing validation + populate the singletons. Does NOT apply
    the OAS capability-catalog gate (use {!init_default_strict} at production
    startup). Safe for tests with arbitrary-model runtime fixtures. *)

val init_default_strict : config_path:string -> (unit, string) result
(** Production startup entry point: {!init_default} PLUS the OAS capability-catalog
    gate ({!decide_capability_gate}). Rejects ([Error]) a runtime whose model is
    absent from the catalog before boot. Used by server boot and fusion run. *)

val init_default_strict_report :
  config_path:string -> (unit, strict_init_error) result
(** Typed form of {!init_default_strict}. Server bootstrap uses this to log
    missing catalog models without string-matching the fatal error message. *)

module For_testing : sig
  type snapshot

  val snapshot : unit -> snapshot
  val restore : snapshot -> unit
end

val get_default_runtime : unit -> t option
val get_runtimes : unit -> t list
val get_runtime_ids : unit -> string list
val runtimes_and_media_failover : unit -> t list * string list
(** Atomically consistent snapshot of configured runtimes plus
    [\[runtime\].media_failover]. Use when both values drive one routing
    decision, so a runtime config refresh cannot interleave between two
    separate reads. *)

val runtime_id_for_keeper : string -> string option
(** [runtime_id_for_keeper keeper_name] is the runtime id assigned to
    [keeper_name] in [\[runtime.assignments\]] (runtime.toml SSOT), or [None]
    when no explicit assignment exists (caller falls back to
    {!get_default_runtime_id}). The id is opaque (only the OAS adapter parses
    it). persona⊥{model,runtime}: keeper→runtime assignment is NOT sourced from
    persona JSON or keeper TOML. *)

val keeper_assignments : unit -> (string * string) list
(** Snapshot of explicit [keeper_name -> runtime_id] assignments loaded from
    [\[runtime.assignments\]]. The list is validated during {!init_default};
    every runtime id in the returned snapshot resolves to a configured runtime.
    Dashboard/operator surfaces use this to expose assignment blast radius
    without parsing TOML independently. *)

val cross_verifier_runtime_id : unit -> string option
(** [\[runtime\].cross_verifier] runtime id for the anti-rationalization
    evaluator, or [None] when unset (the evaluator uses [\[runtime\].default]).
    Validated at load so a [Some] always resolves to a configured runtime. *)

val librarian_runtime_id : unit -> string option
(** [\[runtime\].librarian] runtime id for the memory-os librarian, or [None]
    when unset (the librarian inherits each keeper's runtime). Validated at load
    so a [Some] always resolves to a configured runtime.
    [MASC_KEEPER_MEMORY_OS_LIBRARIAN_RUNTIME_ID] overrides this at the librarian
    call site. *)

val structured_judge_runtime_id : unit -> string option
(** [\[runtime\].structured_judge] runtime id for provider-native
    structured-output judge calls, or [None] when unset. Validated at load so a
    [Some] resolves to a configured runtime whose model declares
    [supports-structured-output]. *)

val runtime_id_for_structured_judge : unit -> string
(** Resolved runtime id for dashboard/operator/governance structured-output judge
    calls. Uses [\[runtime\].structured_judge] first, then the existing
    [\[runtime\].librarian] migration lane, then [\[runtime\].default]. The final
    default path still fails loudly at each caller's schema validation if the
    runtime cannot satisfy provider-native structured output. *)

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

val resolve_assignment :
  string -> [ `Lane of Runtime_lane.t | `Single_runtime of t | `Missing ]
(** Resolve a keeper assignment id to either a lane or a single runtime. Lanes
    shadow runtimes. [Missing] means the id does not name a known lane or
    runtime. *)

val pause_threshold : unit -> pause_threshold
(** [\[pause\]] threshold knobs from runtime.toml, or
    {!Runtime_schema.pause_threshold_default} when runtime.toml is unavailable or
    invalid. Operational pause decision paths use this accessor instead of the
    legacy top-level fallback constants. *)

val get_runtime_by_id : string -> t option
(** [get_runtime_by_id id] is the materialized runtime whose binding-key id
    ["provider.model"] equals [id], or [None] if no such runtime is configured.
    Used by the keeper turn driver to dispatch to the requested runtime (a
    keeper's persona [model] selection or the default); [None] makes the driver
    fail fast rather than silently substituting the default (RFC-0207). *)

val is_local_runtime : t -> bool
(** [is_local_runtime rt] classifies runtime locality from the materialized
    provider schema: CLI transports are local; HTTP transports are local only
    when their endpoint is loopback and the provider declares no credential. *)

val is_local_runtime_id : string -> bool option
(** Locality classification for a configured runtime id, or [None] when the
    runtime id is not currently materialized. *)

val max_context_of_runtime_id : string -> int option
(** Effective input context window for the materialized runtime [id], or [None]
    when the id is not configured.  Budgeting callers use this to size a
    per-keeper routed turn against the same runtime that dispatch will use.
    When the OAS provider capability catalog declares a context cap, the value
    is clamped to [min runtime.toml max-context provider cap] so MASC cannot
    admit a prompt larger than the provider-owned window. *)

val max_output_tokens_of_runtime_id : string -> int option
(** Declared max output tokens (OAS capability catalog) for the model bound to
    runtime [id], or [None] when the id is not configured or the catalog leaves
    it unset.  Consumed by {!Runtime_inference.resolve_max_tokens} to size a
    reasoning turn from the model's own output ceiling rather than the flat
    fallback. *)

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

val preserve_thinking_of_runtime_id : string -> bool option
(** Explicit [preserve-thinking] for runtime [id]. [None] means unknown runtime,
    uninitialized cache, or no explicit TOML field.

    OAS owns provider/model capability truth and applies provider-required
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

val load_config_text :
  ?runtime_config_path:string -> unit -> ((string * string), string) result
(** Load the raw runtime.toml source text. Returns [(path, source_text)]. *)

val save_config_text :
  ?runtime_config_path:string -> string -> (unit, string) result
(** Validate and atomically persist raw runtime.toml source text, then refresh
    the in-process runtime cache. *)

val set_runtime_id_for_keeper :
  ?runtime_config_path:string ->
  keeper_name:string ->
  runtime_id:string ->
  unit ->
  (unit, string) result
(** Persist [keeper_name] -> [runtime_id] in
    [\[runtime.assignments\]] (runtime.toml SSOT), validate the resulting
    runtime config, atomically write it, and refresh the in-process runtime
    assignment cache. *)

val clear_runtime_id_for_keeper :
  ?runtime_config_path:string -> keeper_name:string -> unit -> (unit, string) result
(** Remove [keeper_name] from [\[runtime.assignments\]], validate the resulting
    runtime config, atomically write it, and refresh the in-process runtime
    assignment cache. *)

val set_runtime_default :
  ?runtime_config_path:string -> runtime_id:string -> unit -> (unit, string) result
(** Persist [\[runtime\]].default through the runtime.toml SSOT writer,
    validate the resulting config, atomically write it, and refresh the
    in-process runtime cache. *)

val set_runtime_librarian :
  ?runtime_config_path:string -> runtime_id:string option -> unit -> (unit, string) result
(** Persist or clear [\[runtime\]].librarian through the runtime.toml SSOT
    writer, validate the resulting config, atomically write it, and refresh the
    in-process runtime cache. *)

val set_runtime_structured_judge :
  ?runtime_config_path:string -> runtime_id:string option -> unit -> (unit, string) result
(** Persist or clear [\[runtime\]].structured_judge through the runtime.toml
    SSOT writer, validate the resulting config, atomically write it, and refresh
    the in-process runtime cache. *)

val set_runtime_cross_verifier :
  ?runtime_config_path:string -> runtime_id:string option -> unit -> (unit, string) result
(** Persist or clear [\[runtime\]].cross_verifier through the runtime.toml SSOT
    writer, validate the resulting config, atomically write it, and refresh the
    in-process runtime cache. *)

val set_runtime_media_failover :
  ?runtime_config_path:string -> runtime_ids:string list -> unit -> (unit, string) result
(** Persist [\[runtime\]].media_failover through the runtime.toml SSOT writer,
    validate the resulting config, atomically write it, and refresh the
    in-process runtime cache. The list order is preserved. *)

val default_max_context : unit -> int
(** Effective context-window budget of the default runtime's model (RFC-0206
    single-binding), clamped by the OAS provider capability catalog when that
    cap is available. Replaces the deleted
    [Runtime_runtime.resolve_*_max_context] label scans. Falls back to
    [Runtime_constants.fallback_context_window] before {!init_default} runs. *)

val default_model_api_name : unit -> string
(** API model name of the default runtime, sent to the runtime completion
    endpoint (RFC-0206 single-binding). Replaces the deleted
    [Runtime_runtime.default_local_model_label_and_id]. Falls back to ["auto"]
    before {!init_default} runs. *)
