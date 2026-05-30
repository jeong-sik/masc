(** Runtime = Provider + Model + Spec(binding).

    cascade→Runtime 전환 (RFC-0206). cascade 의 routes/cascade_name/tier/profile
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

(** {1 Lazy default runtime singleton}

    Initialized once at startup via {!init_default}.  All consumer
    code that previously resolved a cascade name now calls
    {!get_default_runtime_id} instead. *)

val init_default : config_path:string -> (unit, string) result
val get_default_runtime : unit -> t option

val get_default_runtime_id : unit -> string
(** @raise Failure if {!init_default} has not run. No silent fallback
    (RFC-0206 §2.1): an unresolved default is a startup-ordering bug, not a
    recoverable condition. Callers must invoke this at runtime, never as a
    module-level [let] binding (would crash config-less test binaries). *)

val config_path : unit -> string option
(** Path to the runtime config TOML, or [None] if unresolved. Re-homed from
    deleted [Runtime.config_path] (delegates to
    [Config_dir_resolver]). *)
