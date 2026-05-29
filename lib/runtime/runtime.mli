(** Runtime = Provider + Model + Spec(binding).

    See {!runtime.ml} for design rationale (cascade→Runtime B0). *)

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
