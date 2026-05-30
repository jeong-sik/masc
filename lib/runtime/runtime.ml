(** Runtime = Provider + Model + Spec(binding).

    cascade→Runtime 전환 (B0). cascade 의 routes/cascade_name/tier/profile
    간접 레이어를 제거하고, binding(provider × model) 하나를 곧 하나의 Runtime
    으로 본다. 소비자는 Runtime 목록 + default Runtime 을 직접 소비한다.

    B0 는 additive: 기존 [Cascade_declarative_types] 를 합성만 한다(새 nominal
    타입 없음 — 264파일 강결합에서 새 타입은 conversion 폭증을 부른다).
    provider_cfg (hot-path materialize) 는 소비자 연결 단계(B2)에서 추가. *)

open Cascade_declarative_types

type t =
  { id : string
    (** binding key ["provider.model"], 예 ["runpod_mtp.qwen-runpod"] *)
  ; provider : cascade_provider
  ; model : cascade_model_spec
  ; binding : cascade_binding
  ; provider_config : Llm_provider.Provider_config.t
    (** load 시점에 materialize 된 hot-path provider config. 소비자는
        routing 없이 이걸 곧장 LLM dispatch 로 넘긴다. *)
  }

let id_of_binding (b : cascade_binding) : string =
  Printf.sprintf "%s.%s" b.provider_id b.model_id
;;

(** binding 을 Runtime 으로 변환. provider/model resolve 또는 provider_config
    materialize 가 실패하면 [None] (fail-closed — partial-boot 없음, 해당
    binding 은 가용 Runtime 목록에서 제외). *)
let of_binding (cfg : cascade_config) (b : cascade_binding) : t option =
  match provider_of_id cfg b.provider_id, model_of_id cfg b.model_id with
  | Some provider, Some model ->
    (match Cascade_declarative_adapter.binding_to_provider_config cfg b with
     | Ok provider_config ->
       Some { id = id_of_binding b; provider; model; binding = b; provider_config }
     | Error _ -> None)
  | _ -> None
;;

(** TOML 에서 Runtime 목록과 default Runtime 을 로드한다.

    fail-fast: [\[runtime\] default] 가 없거나 그 id 가 목록에 없으면 [Error].
    silent fallback 일절 없음 (cascade→Runtime 비전: TOML 에 default 없으면
    프로그램 실행 불가). *)
let load_list ~(config_path : string) : (t list * t, string) result =
  match Cascade_declarative_parser.parse_file config_path with
  | Error errs ->
    Error
      (Printf.sprintf
         "cascade config parse failed (%s): %d error(s)"
         config_path
         (List.length errs))
  | Ok cfg ->
    let runtimes = List.filter_map (of_binding cfg) cfg.bindings in
    (match cfg.default_runtime_id with
     | None ->
       Error
         (Printf.sprintf
            "%s: [runtime].default is required (no default runtime configured; \
             silent fallback removed)"
            config_path)
     | Some did ->
       (match List.find_opt (fun (r : t) -> String.equal r.id did) runtimes with
        | Some rt -> Ok (runtimes, rt)
        | None ->
          Error
            (Printf.sprintf
               "%s: [runtime].default = %S not found among %d runtimes"
               config_path
               did
               (List.length runtimes))))

(* ---- Lazy default runtime singleton ---- *)

let default_runtime_ref : t option ref = ref None

let init_default ~config_path =
  match load_list ~config_path with
  | Ok (_, rt) ->
    default_runtime_ref := Some rt;
    Ok ()
  | Error _ as e -> e

let get_default_runtime () = !default_runtime_ref

let get_default_runtime_id () =
  match !default_runtime_ref with
  | Some rt -> rt.id
  | None -> "tool_strict"
;;
