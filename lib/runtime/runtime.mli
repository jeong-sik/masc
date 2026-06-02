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
val load_list : config_path:string -> (t list * t, string) result
val runtime_ids : t list -> string list

val runtime_supports_required_tools : t -> bool
(** [true] when a runtime can carry required keeper tool-use turns through
    runtime MCP tooling and model-level tool-choice support. *)

val required_tool_runtime_ids : t list -> string list
(** Tool-capable runtime ids, preserving the TOML binding order. *)

(** {1 Lazy default runtime singleton}

    Initialized once at startup via {!init_default}.  All consumer
    code that previously resolved a runtime name now calls
    {!get_default_runtime_id} instead. *)

val init_default : config_path:string -> (unit, string) result
val get_default_runtime : unit -> t option
val get_runtimes : unit -> t list
val get_runtime_ids : unit -> string list
val get_required_tool_runtime_ids : unit -> string list

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

val get_default_runtime_id : unit -> string
(** @raise Failure if {!init_default} has not run. No silent fallback
    (RFC-0206 §2.1): an unresolved default is a startup-ordering bug, not a
    recoverable condition. Callers must invoke this at runtime, never as a
    module-level [let] binding (would crash config-less test binaries). *)

val config_path : unit -> string option
(** Path to the runtime config TOML, or [None] if unresolved. Re-homed from
    deleted [Runtime.config_path] (delegates to
    [Config_dir_resolver]). *)

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
