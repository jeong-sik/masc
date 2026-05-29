(** Runtime = Provider + Model + Spec(binding).

    cascade→Runtime 전환 (B0). cascade 의 routes/cascade_name/tier/profile
    간접 레이어를 제거하고, binding(provider × model) 하나를 곧 하나의 Runtime
    으로 본다. 소비자는 Runtime 목록 + default Runtime 을 직접 소비한다. *)

open Cascade_declarative_types

type t =
  { id : string
  ; provider : cascade_provider
  ; model : cascade_model_spec
  ; binding : cascade_binding
  ; provider_config : Llm_provider.Provider_config.t
  }

val id_of_binding : cascade_binding -> string
val of_binding : cascade_config -> cascade_binding -> t option
val load_list : config_path:string -> (t list * t, string) result
