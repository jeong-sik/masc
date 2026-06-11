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

val load_list :
  config_path:string -> (t list * t * (string * string) list, string) result
(** [load_list ~config_path] parses runtime.toml into [(runtimes, default,
    keeper_assignments)]. Fails ([Error]) if [\[runtime\].default] is missing /
    unresolved, or if any [\[runtime.assignments\]] target does not resolve to a
    configured runtime (mirrors default validation — no silent fallback for a
    typo'd assignment). [keeper_assignments] is the keeper→runtime-id list. *)

val runtime_ids : t list -> string list

(** {1 Lazy default runtime singleton}

    Initialized once at startup via {!init_default}.  All consumer
    code that previously resolved a runtime name now calls
    {!get_default_runtime_id} instead. *)

val init_default : config_path:string -> (unit, string) result
val get_default_runtime : unit -> t option
val get_runtimes : unit -> t list
val get_runtime_ids : unit -> string list

val runtime_id_for_keeper : string -> string option
(** [runtime_id_for_keeper keeper_name] is the runtime id assigned to
    [keeper_name] in [\[runtime.assignments\]] (runtime.toml SSOT), or [None]
    when no explicit assignment exists (caller falls back to
    {!get_default_runtime_id}). The id is opaque (only the OAS adapter parses
    it). persona⊥{model,runtime}: keeper→runtime assignment is NOT sourced from
    persona JSON or keeper TOML. *)

val get_runtime_by_id : string -> t option
(** [get_runtime_by_id id] is the materialized runtime whose binding-key id
    ["provider.model"] equals [id], or [None] if no such runtime is configured.
    Used by the keeper turn driver to dispatch to the requested runtime (a
    keeper's persona [model] selection or the default); [None] makes the driver
    fail fast rather than silently substituting the default (RFC-0207). *)

val max_context_of_runtime_id : string -> int option
(** Context window for the materialized runtime [id], or [None] when the id is
    not configured.  Budgeting callers use this to size a per-keeper routed turn
    against the same runtime that dispatch will use. *)

val thinking_support_of_runtime_id : string -> bool option
(** [thinking-support] capability of the model bound to runtime [id], or [None]
    when the id is not configured (e.g. before {!init_default}).  Consumed by
    {!Runtime_inference.for_runtime} to gate keeper thinking per model from the
    runtime.toml SSOT. *)

val preserve_thinking_of_runtime_id : string -> bool option
(** [Some true] when the model bound to runtime [id] opts into
    [preserve-thinking].  [None] means unknown runtime, uninitialized cache, or
    the default false value.  Consumed by {!Runtime_inference.for_runtime} to
    preserve Qwen3.6 reasoning traces on OpenAI-compatible runtimes that
    support it without spraying explicit false fields at every provider. *)

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

val default_max_context : unit -> int
(** Context-window budget of the default runtime's model (RFC-0206
    single-binding). Replaces the deleted [Runtime_runtime.resolve_*_max_context]
    label scans. Falls back to [Runtime_constants.fallback_context_window]
    before {!init_default} runs. *)

val default_model_api_name : unit -> string
(** API model name of the default runtime, sent to the runtime completion
    endpoint (RFC-0206 single-binding). Replaces the deleted
    [Runtime_runtime.default_local_model_label_and_id]. Falls back to ["auto"]
    before {!init_default} runs. *)
