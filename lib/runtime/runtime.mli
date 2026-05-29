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

val default : ?config_path:string -> unit -> (t, string) result
(** Process-cached default Runtime.

    [config_path] 미해결 또는 load 실패 시 [Error] (silent fallback 없음 —
    소비자가 fail-fast 하도록). 성공 결과만 resolved path 별로 캐시한다.
    [load_list] 는 순수(매 호출 TOML parse)이므로 hot-path 소비자를 위해
    memoize 한다. *)

val reset_cache_for_tests : unit -> unit
(** [default] 의 process 캐시를 비운다. 테스트에서 config 변경을 반영하기 위해
    사용. *)
