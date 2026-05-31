(** Runtime = Provider + Model + Spec(binding).

    cascade→Runtime 전환 (RFC-0206). cascade 의 routes/cascade_name/tier/profile
    간접 레이어를 제거하고, binding(provider × model) 하나를 곧 하나의 Runtime
    으로 본다. 소비자는 Runtime 목록 + default Runtime 을 직접 소비한다.

    타입은 자립 모듈 {!Runtime_schema} 소유 (삭제된 [Cascade_declarative_types]
    대체). parse 는 {!Runtime_toml}, hot-path materialize 는 {!Runtime_adapter}
    가 담당한다 — 셋 다 [Cascade_*] 코드 의존 0. *)

open Runtime_schema

type t =
  { id : string
    (** binding key ["provider.model"], 예 ["runpod_mtp.qwen-runpod"] *)
  ; provider : provider
  ; model : model_spec
  ; binding : binding
  ; provider_config : Llm_provider.Provider_config.t
    (** load 시점에 materialize 된 hot-path provider config. 소비자는
        routing 없이 이걸 곧장 LLM dispatch 로 넘긴다. *)
  }

(* id 파생의 단일 출처는 {!Runtime_schema.binding_key} — runtime 을 id 로
   인덱싱하는 모든 호출자와 동일한 ["provider.model"] 규칙을 공유한다. *)
let id_of_binding (b : binding) : string = binding_key b

(** binding 을 Runtime 으로 변환. provider/model resolve 또는 provider_config
    materialize 가 실패하면 [None] (fail-closed — partial-boot 없음, 해당
    binding 은 가용 Runtime 목록에서 제외). *)
let of_binding (cfg : config) (b : binding) : t option =
  match provider_of_id cfg b.provider_id, model_of_id cfg b.model_id with
  | Some provider, Some model ->
    (match Runtime_adapter.binding_to_provider_config cfg b with
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
  match Runtime_toml.parse_file config_path with
  | Error errs ->
    Error
      (Printf.sprintf
         "runtime config parse failed (%s): %d error(s)"
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

(* fail-fast: uninitialized = startup-ordering bug, NOT a recoverable
   condition. 이전 [| None -> "tool_strict"] 하드코딩 fallback 은 90 사이트에
   조작된 id 를 흘리는 Unknown→Permissive 안티패턴이라 제거했다 (RFC-0206 §2.1).
   불변식: [init_default] 가 startup 에서 성공해야 한다(아니면 startup abort).
   NB(R2): 함수 호출 시점에만 raise 하므로 호출자는 이 값을 모듈 top-level
   [let] 로 eager 바인딩하면 안 된다(config-less 테스트 바이너리 load crash). *)
let get_default_runtime_id () =
  match !default_runtime_ref with
  | Some rt -> rt.id
  | None ->
    failwith
      "Runtime.get_default_runtime_id: default runtime not initialized; \
       Runtime.init_default must run at startup (no silent fallback — RFC-0206 §2.1)"
;;

let config_path () : string option =
  Config_dir_resolver.log_warnings ~context:"Runtime" ();
  let resolution = Config_dir_resolver.resolve () in
  match resolution.config_root.source with
  | Env | Local_masc ->
      let path =
        Filename.concat resolution.config_root.path
          Config_dir_resolver.keeper_runtime_toml_filename
      in
      if Sys.file_exists path then Some path else None
  | Invalid_env | Missing -> None
;;

(* RFC-0206 single-binding: the deleted [Cascade_runtime.resolve_*_max_context]
   scanned model labels across a cascade's candidates and folded the max. Under
   single-binding every keeper uses the default runtime, so the context budget
   is that runtime's [model.max_context]. Falls back to
   [Runtime_constants.fallback_context_window] when the default is not yet
   initialized (config-less test binaries). *)
let default_max_context () : int =
  match get_default_runtime () with
  | Some rt -> rt.model.max_context
  | None -> Runtime_constants.fallback_context_window
;;

(* RFC-0206 single-binding: the deleted
   [Cascade_runtime.default_local_model_label_and_id] scanned configured/available
   labels and returned the model-id substring. Under single-binding the model
   name sent to the runtime endpoint is the default runtime's [model.api_name].
   Falls back to ["auto"] before {!init_default} runs. *)
let default_model_api_name () : string =
  match get_default_runtime () with
  | Some rt -> rt.model.api_name
  | None -> "auto"
;;
