(** Runtime = Provider + Model + Spec(binding).

    runtime→Runtime 전환 (RFC-0206). runtime 의 routes/runtime_id/tier/profile
    간접 레이어를 제거하고, binding(provider × model) 하나를 곧 하나의 Runtime
    으로 본다. 소비자는 Runtime 목록 + default Runtime 을 직접 소비한다.

    타입은 자립 모듈 {!Runtime_schema} 소유 (삭제된 [Runtime_declarative_types]
    대체). parse 는 {!Runtime_toml}, hot-path materialize 는 {!Runtime_adapter}
    가 담당한다 — 셋 다 [Runtime_*] 코드 의존 0. *)

open Runtime_schema
open Result.Syntax

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
    silent fallback 일절 없음 (runtime→Runtime 비전: TOML 에 default 없으면
    프로그램 실행 불가). *)
(* RFC keeper→runtime assignment validation: every [[runtime.assignments]]
   target must resolve to a configured runtime. An unknown id is an operator
   error rejected at load (mirrors [runtime].default validation), NOT a silent
   fallback to the default — that would mask a typo'd assignment
   (Unknown→Permissive anti-pattern). A keeper *absent* from the table is the
   intended designed fallback to the default and is handled at lookup time, not
   here. *)
let validate_keeper_assignments ~(config_path : string) (runtimes : t list)
    (assignments : (string * string) list) : (unit, string) result =
  let runtime_exists id =
    List.exists (fun (r : t) -> String.equal r.id id) runtimes
  in
  match
    List.find_opt (fun (_, runtime_id) -> not (runtime_exists runtime_id)) assignments
  with
  | None -> Ok ()
  | Some (keeper_name, runtime_id) ->
    Error
      (Printf.sprintf
         "%s: [runtime.assignments].%s = %S not found among %d runtimes"
         config_path
         keeper_name
         runtime_id
         (List.length runtimes))
;;

(* [runtime].librarian must resolve to a configured runtime when set, mirroring
   [runtime].default / [runtime.assignments] validation: an unknown id is an
   operator typo rejected at load, not a silent fallback (Unknown→Permissive
   anti-pattern). [None] is the designed "inherit the keeper's runtime" case. *)
let validate_librarian_runtime ~(config_path : string) (runtimes : t list)
    (librarian_id : string option) : (unit, string) result =
  match librarian_id with
  | None -> Ok ()
  | Some id ->
    if List.exists (fun (r : t) -> String.equal r.id id) runtimes
    then Ok ()
    else
      Error
        (Printf.sprintf
           "%s: [runtime].librarian = %S not found among %d runtimes"
           config_path
           id
           (List.length runtimes))
;;

(* [runtime].cross_verifier mirrors [runtime].librarian validation: an unknown
   id is an operator typo rejected at load, not a silent fallback
   (Unknown→Permissive anti-pattern). [None] is the designed "inherit
   [runtime].default" case. *)
let validate_cross_verifier_runtime ~(config_path : string) (runtimes : t list)
    (cross_verifier_id : string option) : (unit, string) result =
  match cross_verifier_id with
  | None -> Ok ()
  | Some id ->
    (match List.find_opt (fun (r : t) -> String.equal r.id id) runtimes with
     | None ->
      Error
        (Printf.sprintf
           "%s: [runtime].cross_verifier = %S not found among %d runtimes"
           config_path
           id
           (List.length runtimes))
     | Some runtime ->
       (match runtime.model.capabilities with
        | Some caps when caps.supports_response_format_json -> Ok ()
        | _ ->
          Error
            (Printf.sprintf
               "%s: [runtime].cross_verifier = %S uses model %S, which does \
                not declare supports-response-format-json"
               config_path
               id
               runtime.model.id)))
;;

(* [runtime].structured_judge is the explicit lane for provider-native schema
   requests. Unlike the librarian lane, this lane must declare structured output,
   not just JSON mode. [None] remains a migration fallback for existing configs;
   unsupported resolved runtimes are rejected by each caller's OAS schema
   validation instead of silently dropping the schema. *)
let validate_structured_judge_runtime ~(config_path : string) (runtimes : t list)
    (structured_judge_id : string option) : (unit, string) result =
  match structured_judge_id with
  | None -> Ok ()
  | Some id ->
    (match List.find_opt (fun (r : t) -> String.equal r.id id) runtimes with
     | None ->
       Error
         (Printf.sprintf
            "%s: [runtime].structured_judge = %S not found among %d runtimes"
            config_path
            id
            (List.length runtimes))
     | Some runtime ->
       (match runtime.model.capabilities with
        | Some caps when caps.supports_structured_output -> Ok ()
        | _ ->
          Error
            (Printf.sprintf
               "%s: [runtime].structured_judge = %S uses model %S, which does \
                not declare supports-structured-output"
               config_path
               id
               runtime.model.id)))
;;

(* [runtime].media_failover (RFC-0265) mirrors [runtime].librarian validation for
   each id in the ordered list: an unknown id is an operator typo rejected at
   load, not a silent drop (Unknown→Permissive anti-pattern). [[]] is the designed
   "derive capable runtimes from declared capabilities" case. *)
let validate_media_failover ~(config_path : string) (runtimes : t list)
    (media_failover : string list) : (unit, string) result =
  match
    List.find_opt
      (fun id ->
        not (List.exists (fun (r : t) -> String.equal r.id id) runtimes))
      media_failover
  with
  | None -> Ok ()
  | Some id ->
    Error
      (Printf.sprintf
         "%s: [runtime].media_failover entry %S not found among %d runtimes"
         config_path
         id
         (List.length runtimes))
;;

(* Pure decision for the capability gate, separated from the global OAS catalog
   lookup so it is unit-testable. [entries] is [(label, known_to_oas)] per runtime.

   An unknown model resolves to OAS [provider_default], whose guessed capabilities
   (notably [thinking_control_format = No_thinking_control]) silently drop
   thinking/sampling control a binding may require — that guess corrupted the
   memory-os librarian for minimax-m3 (2026-06-19, before it was catalogued).
   Reject such a binding at load instead of discovering corruption at runtime
   (Unknown->Permissive anti-pattern; mirrors [runtime].default validation,
   RFC-0206 §2.1 no-silent-fallback).

   An empty runtime list is allowed for focused unit tests/config probes, but any
   configured runtime whose model is absent from the catalog is rejected before it
   can inherit guessed provider_default capabilities. *)
let decide_capability_gate ~(config_path : string) (entries : (string * bool) list)
  : (unit, string) result
  =
  let unknown = List.filter (fun (_, known) -> not known) entries in
  match unknown with
  | [] -> Ok ()
  | _ ->
    Error
      (Printf.sprintf
         "%s: %d runtime model(s) absent from the OAS capability catalog; they \
          would use provider_default and silently drop thinking/sampling control. \
          Add them to models.toml (OAS catalog): %s"
         config_path
         (List.length unknown)
         (String.concat ", " (List.map fst unknown)))
;;

let capabilities_for_runtime (rt : t) =
  Llm_provider.Provider_config.capabilities_for_config_model rt.provider_config
;;

(* Every runtime binding's provider/model pair must be known to the OAS
   capability catalog. Use the materialized [Provider_config.t] so
   provider-qualified catalog rows are considered before bare model rows; this
   keeps overlapping ids such as native Kimi vs Ollama Cloud Kimi from requiring
   bare-id manifest workarounds. *)
let validate_runtime_model_capabilities ~(config_path : string) (runtimes : t list)
  : (unit, string) result
  =
  decide_capability_gate
    ~config_path
    (List.map
       (fun (r : t) ->
          ( Printf.sprintf "%s (model=%s)" r.id r.provider_config.model_id
          , Option.is_some (capabilities_for_runtime r) ))
       runtimes)
;;

let materialize_config ~(config_path : string) (cfg : config)
  : ( t list
      * t
      * (string * string) list
      * string option
      * string option
      * string option
      * string list
    , string )
    result
  =
  let runtimes = List.filter_map (of_binding cfg) cfg.bindings in
  let assignments = cfg.keeper_assignments in
  let* rt =
    match cfg.default_runtime_id with
    | None ->
      Error
        (Printf.sprintf
           "%s: [runtime].default is required (no default runtime configured; \
            silent fallback removed)"
           config_path)
    | Some did ->
      (match List.find_opt (fun (r : t) -> String.equal r.id did) runtimes with
       | None ->
         Error
           (Printf.sprintf
              "%s: [runtime].default = %S not found among %d runtimes"
              config_path
              did
              (List.length runtimes))
       | Some rt -> Ok rt)
  in
  let* () = validate_keeper_assignments ~config_path runtimes assignments in
  let* () =
    validate_librarian_runtime ~config_path runtimes cfg.librarian_runtime_id
  in
  let* () =
    validate_structured_judge_runtime ~config_path runtimes
      cfg.structured_judge_runtime_id
  in
  let* () =
    validate_cross_verifier_runtime ~config_path runtimes
      cfg.cross_verifier_runtime_id
  in
  let* () =
    validate_media_failover ~config_path runtimes cfg.media_failover
  in
  (* The OAS catalog membership gate is intentionally not called here:
     [load_list] stays a routing-validity parser for tests and config probes.
     Production startup applies the stricter gate via [init_default_strict]. *)
  Ok
    ( runtimes
    , rt
    , assignments
    , cfg.librarian_runtime_id
    , cfg.structured_judge_runtime_id
    , cfg.cross_verifier_runtime_id
    , cfg.media_failover )
;;

let load_list ~(config_path : string)
  : ( t list
       * t
       * (string * string) list
       * string option
       * string option
       * string option
       * string list
    , string )
    result
  =
  let* cfg =
    Runtime_toml.parse_file config_path
    |> Result.map_error (fun errs ->
      Printf.sprintf
        "runtime config parse failed (%s): %d error(s)"
        config_path
        (List.length errs))
  in
  materialize_config ~config_path cfg

(* ---- Lazy default runtime singleton ---- *)

(** The loaded runtime cache is read from arbitrary call sites, including worker
    domains spawned by the executor pool. Keep all derived runtime.toml values in
    one immutable record behind one [Atomic.t] so readers never observe a torn
    refresh or test restore. *)
type loaded_state =
  { default_runtime : t option
  ; runtimes : t list
  ; keeper_assignments : (string * string) list
  ; librarian_runtime_id : string option
  ; structured_judge_runtime_id : string option
  ; cross_verifier_runtime_id : string option
  ; media_failover : string list
  ; config_path : string option
  }

let empty_loaded_state =
  { default_runtime = None
  ; runtimes = []
  ; keeper_assignments = []
  ; librarian_runtime_id = None
  ; structured_judge_runtime_id = None
  ; cross_verifier_runtime_id = None
  ; media_failover = []
  ; config_path = None
  }

let loaded_state_ref : loaded_state Atomic.t = Atomic.make empty_loaded_state

let runtime_ids runtimes = List.map (fun (rt : t) -> rt.id) runtimes

let set_loaded
    ~config_path
    ( runtimes
    , rt
    , assignments
    , librarian_id
    , structured_judge_id
    , cross_verifier_id
    , media_failover ) =
  Atomic.set loaded_state_ref
    { default_runtime = Some rt
    ; runtimes
    ; keeper_assignments = assignments
    ; librarian_runtime_id = librarian_id
    ; structured_judge_runtime_id = structured_judge_id
    ; cross_verifier_runtime_id = cross_verifier_id
    ; media_failover
    ; config_path = Some config_path
    }

let init_default ~config_path =
  let* loaded = load_list ~config_path in
  set_loaded ~config_path loaded;
  Ok ()

(* Startup entry point: [load_list] (RFC-0206 routing validation) PLUS the OAS
   capability-catalog gate. Production callers (server boot, fusion run) use this
   so an operator runtime.toml whose model is absent from the catalog is rejected
   before boot — the gate that load_list intentionally no longer applies, kept out
   of load_list so unit tests stay catalog-independent. *)
let init_default_strict ~config_path =
  match load_list ~config_path with
  | Error _ as e -> e
  | Ok ((runtimes, _, _, _, _, _, _) as loaded) ->
    (match validate_runtime_model_capabilities ~config_path runtimes with
     | Error _ as e -> e
     | Ok () ->
       set_loaded ~config_path loaded;
       Ok ())

let runtime_state () = Atomic.get loaded_state_ref

module For_testing = struct
  type snapshot = loaded_state

  let snapshot () = runtime_state ()
  let restore snapshot = Atomic.set loaded_state_ref snapshot
end

let get_default_runtime () = (runtime_state ()).default_runtime
let get_runtimes () = (runtime_state ()).runtimes
let get_runtime_ids () = runtime_ids (runtime_state ()).runtimes

let default_runtime_id_or_fail () =
  match (runtime_state ()).default_runtime with
  | Some rt -> rt.id
  | None ->
    failwith
      "Runtime.get_default_runtime_id: default runtime not initialized; \
       Runtime.init_default must run at startup (no silent fallback — RFC-0206 §2.1)"
;;

let runtimes_and_media_failover () =
  let state = runtime_state () in
  state.runtimes, state.media_failover
;;

(* RFC persona⊥{model,runtime}: keeper→runtime assignment is sourced from
   [[runtime.assignments]] (runtime.toml SSOT), NOT from persona JSON or keeper
   TOML. [None] = no explicit assignment; the caller falls back to
   {!get_default_runtime_id}. The returned id is opaque (masc never parses it;
   only the OAS adapter resolves it to provider/model/spec). Reads
   [keeper_assignments_ref], never a module-level eager binding. *)
let runtime_id_for_keeper (keeper_name : string) : string option =
  List.assoc_opt keeper_name (runtime_state ()).keeper_assignments
;;

let keeper_assignments () = (runtime_state ()).keeper_assignments

(* [runtime].librarian routing for the memory-os librarian. [None] = the
   librarian inherits each keeper's runtime (legacy). Reads the Atomic ref set by
   [init_default]; the env override lives in keeper_librarian_runtime. *)
let librarian_runtime_id () = (runtime_state ()).librarian_runtime_id

(* [runtime].structured_judge is the explicit runtime.toml SSOT for
   provider-native schema requests. *)
let structured_judge_runtime_id () = (runtime_state ()).structured_judge_runtime_id

let runtime_id_for_structured_judge () =
  let state = runtime_state () in
  match state.structured_judge_runtime_id, state.librarian_runtime_id with
  | Some id, _ -> id
  | None, Some id -> id
  | None, None -> default_runtime_id_or_fail ()
;;

(* [runtime].cross_verifier routing for the anti-rationalization evaluator.
   [None] = the evaluator inherits [runtime].default. Reads the Atomic ref set by
   [init_default]. *)
let cross_verifier_runtime_id () = (runtime_state ()).cross_verifier_runtime_id

(* [runtime].media_failover ordered runtime ids for RFC-0265 modality-gated
   reroute. [[]] = derive capable runtimes from declared capabilities. Reads the
   Atomic ref set by [init_default]. *)
let media_failover () = (runtime_state ()).media_failover

(* RFC-0207: resolve a runtime by its binding-key id ["provider.model"].  The
   keeper turn driver dispatches to the *requested* runtime (a keeper's persona
   [model] selection or the default) instead of unconditionally the default; an
   unknown id returns [None] so the driver fails fast (no silent substitution —
   RFC-0206 §2.1).  Reads [runtimes_ref], never a module-level eager binding. *)
let get_runtime_by_id (id : string) : t option =
  List.find_opt (fun (rt : t) -> String.equal rt.id id) (runtime_state ()).runtimes
;;

let max_context_of_runtime (rt : t) : int =
  match capabilities_for_runtime rt with
  | Some caps ->
    (match caps.Llm_provider.Capabilities.max_context_tokens with
     | Some provider_cap when provider_cap > 0 ->
       min rt.model.max_context provider_cap
     | Some _ | None -> rt.model.max_context)
  | None -> rt.model.max_context
;;

let max_context_of_runtime_id (id : string) : int option =
  match get_runtime_by_id id with
  | Some rt -> Some (max_context_of_runtime rt)
  | None -> None
;;

(* The model's declared max output tokens (OAS capability catalog SSOT), or
   [None] when the runtime is unknown or the catalog row leaves it unset.
   Mirrors [max_context_of_runtime_id] but projects the OAS-typed capability
   rather than the runtime.toml [model] record, because max output is owned by
   the provider/model catalog, not the per-binding runtime config. Consumed by
   [Runtime_inference.resolve_max_tokens] to size reasoning turns from the
   model's own ceiling. *)
let max_output_tokens_of_runtime_id (id : string) : int option =
  match get_runtime_by_id id with
  | Some rt ->
    (match capabilities_for_runtime rt with
     | Some caps -> caps.Llm_provider.Capabilities.max_output_tokens
     | None -> None)
  | None -> None
;;

let thinking_support_of_runtime_id (id : string) : bool option =
  match get_runtime_by_id id with
  | Some rt -> Some rt.model.thinking_support
  | None -> None
;;

let default_preserve_thinking_for_model (_rt : t) : bool option =
  (* OAS owns provider/model capability truth and can preserve reasoning when
     the provider contract requires it. MASC must not turn "request-side
     preserve is supported" into a fleet-wide replay policy; long-running
     keepers otherwise accumulate hidden reasoning across unrelated turns. *)
  None
;;

let preserve_thinking_of_runtime_id (id : string) : bool option =
  match get_runtime_by_id id with
  | Some rt ->
    (match rt.model.preserve_thinking with
     | Some _ as explicit -> explicit
     | None -> default_preserve_thinking_for_model rt)
  | None -> None
;;

(* RFC-0233 §8 — per-million-token pricing declared on the [id] binding's
   runtime.toml table. Projects straight off the retained [rt.binding]
   (price_input/price_output are [Runtime_schema.binding] option fields),
   same shape as [max_context_of_runtime_id]. Returns (None, None) when the
   runtime is unknown OR the operator left the rates unset — the turn-record
   writer stores those Nones so the dashboard renders cost absence ("미상")
   rather than fabricating Claude $3/$15 defaults. Partial config (only one
   rate set) is preserved field-by-field; the cost view then cannot compute
   and also renders absence. *)
let pricing_of_runtime_id (id : string) : float option * float option =
  match get_runtime_by_id id with
  | Some rt -> (rt.binding.price_input, rt.binding.price_output)
  | None -> (None, None)
;;

(* fail-fast: uninitialized = startup-ordering bug, NOT a recoverable
   condition. 이전 [| None -> "tool_strict"] 하드코딩 fallback 은 90 사이트에
   조작된 id 를 흘리는 Unknown→Permissive 안티패턴이라 제거했다 (RFC-0206 §2.1).
   불변식: [init_default] 가 startup 에서 성공해야 한다(아니면 startup abort).
   NB(R2): 함수 호출 시점에만 raise 하므로 호출자는 이 값을 모듈 top-level
   [let] 로 eager 바인딩하면 안 된다(config-less 테스트 바이너리 load crash). *)
let get_default_runtime_id () =
  default_runtime_id_or_fail ()
;;

let config_path () : string option =
  Config_dir_resolver.log_warnings ~context:"Runtime" ();
  let resolution = Config_dir_resolver.resolve () in
  match resolution.config_root.source with
  | Env | Local_masc ->
      let path =
        Filename.concat resolution.config_root.path
          Config_dir_resolver.runtime_toml_filename
      in
      if Sys.file_exists path then Some path else None
  | Invalid_env | Missing -> None
;;

let pause_threshold () =
  let runtime_config_path =
    match (runtime_state ()).config_path with
    | Some path -> Some path
    | None -> config_path ()
  in
  match runtime_config_path with
  | None -> Runtime_schema.pause_threshold_default
  | Some config_path ->
    (match Runtime_toml.parse_file config_path with
     | Ok cfg -> cfg.pause_threshold
     | Error errs ->
       Log.Runtime.warn
         "runtime: failed to parse [pause] thresholds from %s (%d error(s)); \
          using defaults"
         config_path
         (List.length errs);
       Runtime_schema.pause_threshold_default)
;;

let runtime_config_path_result ?runtime_config_path () =
  match runtime_config_path with
  | Some path -> Ok path
  | None -> Option.to_result (config_path ()) ~none:"runtime config path not found"
;;

let load_file_result path =
  try Ok (Fs_compat.load_file path) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Printf.sprintf
         "failed to read runtime config %s: %s"
         path
         (Printexc.to_string exn))
;;

let load_config_text ?runtime_config_path () =
  let* path = runtime_config_path_result ?runtime_config_path () in
  let* content = load_file_result path in
  Ok (path, content)
;;

let contains_newline s =
  String.exists (function
    | '\n' | '\r' -> true
    | _ -> false)
    s
;;

let toml_escape_string s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (function
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf
;;

let assignment_line ~keeper_name ~runtime_id =
  Printf.sprintf
    "\"%s\" = \"%s\""
    (toml_escape_string keeper_name)
    (toml_escape_string runtime_id)
;;

let runtime_scalar_line ~key ~runtime_id =
  Printf.sprintf "%s = \"%s\"" key (toml_escape_string runtime_id)
;;

let runtime_string_array_line ~key ~values =
  let rendered =
    values
    |> List.map (fun value -> Printf.sprintf "\"%s\"" (toml_escape_string value))
    |> String.concat ", "
  in
  Printf.sprintf "%s = [%s]" key rendered
;;

let split_lines content =
  if String.equal content "" then [], false
  else (
    let len = String.length content in
    let trailing_newline = Char.equal content.[len - 1] '\n' in
    let parts = String.split_on_char '\n' content in
    let lines =
      if trailing_newline
      then (
        match List.rev parts with
        | "" :: rest -> List.rev rest
        | _ -> parts)
      else parts
    in
    lines, trailing_newline)
;;

let join_lines lines ~trailing_newline =
  match lines with
  | [] -> if trailing_newline then "\n" else ""
  | _ ->
    let body = String.concat "\n" lines in
    if trailing_newline then body ^ "\n" else body
;;

let strip_toml_comment line =
  match String.index_opt line '#' with
  | None -> line
  | Some index -> String.sub line 0 index
;;

let is_toml_table_header line =
  let s = line |> strip_toml_comment |> String.trim in
  let len = String.length s in
  len >= 2 && Char.equal s.[0] '[' && Char.equal s.[len - 1] ']'
;;

let is_runtime_assignments_header line =
  String.equal (line |> strip_toml_comment |> String.trim) "[runtime.assignments]"
;;

let is_runtime_header line =
  String.equal (line |> strip_toml_comment |> String.trim) "[runtime]"
;;

let rec split_at n xs =
  if n <= 0 then [], xs
  else
    match xs with
    | [] -> [], []
    | x :: rest ->
      let before, after = split_at (n - 1) rest in
      x :: before, after
;;

let find_index pred xs =
  let rec loop index = function
    | [] -> None
    | x :: rest -> if pred x then Some index else loop (index + 1) rest
  in
  loop 0 xs
;;

let parse_quoted_key raw =
  let len = String.length raw in
  if len < 2 || not (Char.equal raw.[0] '"') then None
  else
    let buf = Buffer.create len in
    let rec loop index =
      if index >= len then None
      else
        match raw.[index] with
        | '"' -> Some (Buffer.contents buf)
        | '\\' when index + 1 < len ->
          let escaped =
            match raw.[index + 1] with
            | '"' -> '"'
            | '\\' -> '\\'
            | 'n' -> '\n'
            | 'r' -> '\r'
            | 't' -> '\t'
            | c -> c
          in
          Buffer.add_char buf escaped;
          loop (index + 2)
        | c ->
          Buffer.add_char buf c;
          loop (index + 1)
    in
    loop 1
;;

let parse_literal_key raw =
  let len = String.length raw in
  if len < 2 || not (Char.equal raw.[0] '\'') then None
  else
    match String.index_from_opt raw 1 '\'' with
    | None -> None
    | Some end_index -> Some (String.sub raw 1 (end_index - 1))
;;

let assignment_key_of_line line =
  let trimmed = String.trim line in
  if String.equal trimmed "" || Char.equal trimmed.[0] '#'
  then None
  else
    match String.index_opt trimmed '=' with
    | None -> None
    | Some eq_index ->
      let key_part = String.sub trimmed 0 eq_index |> String.trim in
      if String.equal key_part ""
      then None
      else if Char.equal key_part.[0] '"'
      then parse_quoted_key key_part
      else if Char.equal key_part.[0] '\''
      then parse_literal_key key_part
      else Some key_part
;;

let replace_or_append_assignment section_lines ~keeper_name ~runtime_id =
  let line = assignment_line ~keeper_name ~runtime_id in
  let rec loop acc = function
    | [] -> List.rev_append acc [ line ]
    | existing :: rest ->
      (match assignment_key_of_line existing with
       | Some key when String.equal key keeper_name ->
         List.rev_append acc (line :: rest)
       | _ -> loop (existing :: acc) rest)
  in
    loop [] section_lines
;;

let remove_assignment section_lines ~keeper_name =
  List.filter
    (fun existing ->
      match assignment_key_of_line existing with
      | Some key when String.equal key keeper_name -> false
      | _ -> true)
    section_lines
;;

let replace_or_append_runtime_scalar section_lines ~key ~runtime_id =
  let line = runtime_scalar_line ~key ~runtime_id in
  let rec loop acc = function
    | [] -> List.rev_append acc [ line ]
    | existing :: rest ->
      (match assignment_key_of_line existing with
       | Some existing_key when String.equal existing_key key ->
         List.rev_append acc (line :: rest)
       | _ -> loop (existing :: acc) rest)
  in
  loop [] section_lines
;;

let replace_or_append_runtime_string_array section_lines ~key ~values =
  let line = runtime_string_array_line ~key ~values in
  let rec loop acc = function
    | [] -> List.rev_append acc [ line ]
    | existing :: rest ->
      (match assignment_key_of_line existing with
       | Some existing_key when String.equal existing_key key ->
         List.rev_append acc (line :: rest)
       | _ -> loop (existing :: acc) rest)
  in
  loop [] section_lines
;;

let remove_runtime_scalar section_lines ~key =
  List.filter
    (fun existing ->
      match assignment_key_of_line existing with
      | Some existing_key when String.equal existing_key key -> false
      | _ -> true)
    section_lines
;;

let append_runtime_section lines ~key ~runtime_id =
  let section = [ "[runtime]"; runtime_scalar_line ~key ~runtime_id ] in
  match List.rev lines with
  | [] -> section
  | last :: _ when String.equal (String.trim last) "" -> lines @ section
  | _ -> lines @ ("" :: section)
;;

let append_runtime_string_array_section lines ~key ~values =
  let section = [ "[runtime]"; runtime_string_array_line ~key ~values ] in
  match List.rev lines with
  | [] -> section
  | last :: _ when String.equal (String.trim last) "" -> lines @ section
  | _ -> lines @ ("" :: section)
;;

let append_runtime_assignments_section lines ~keeper_name ~runtime_id =
  let section =
    [ "[runtime.assignments]"; assignment_line ~keeper_name ~runtime_id ]
  in
  match List.rev lines with
  | [] -> section
  | last :: _ when String.equal (String.trim last) "" -> lines @ section
  | _ -> lines @ ("" :: section)
;;

let update_runtime_assignment_text content ~keeper_name ~runtime_id =
  let lines, _trailing_newline = split_lines content in
  let updated_lines =
    match find_index is_runtime_assignments_header lines with
    | None -> append_runtime_assignments_section lines ~keeper_name ~runtime_id
    | Some header_index ->
      let before, from_header = split_at header_index lines in
      (match from_header with
       | [] -> append_runtime_assignments_section lines ~keeper_name ~runtime_id
       | header :: after_header ->
         let section_lines, after_section =
           match find_index is_toml_table_header after_header with
           | None -> after_header, []
           | Some next_header_index -> split_at next_header_index after_header
         in
         before
         @ (header
            :: replace_or_append_assignment
                 section_lines
                 ~keeper_name
                 ~runtime_id)
         @ after_section)
  in
  join_lines updated_lines ~trailing_newline:true
;;

let update_runtime_scalar_text content ~key ~runtime_id =
  let lines, _trailing_newline = split_lines content in
  let updated_lines =
    match find_index is_runtime_header lines, runtime_id with
    | None, None -> lines
    | None, Some runtime_id -> append_runtime_section lines ~key ~runtime_id
    | Some header_index, _ ->
      let before, from_header = split_at header_index lines in
      (match from_header with
       | [] ->
         (match runtime_id with
          | None -> lines
          | Some runtime_id -> append_runtime_section lines ~key ~runtime_id)
       | header :: after_header ->
         let section_lines, after_section =
           match find_index is_toml_table_header after_header with
           | None -> after_header, []
           | Some next_header_index -> split_at next_header_index after_header
         in
         let next_section_lines =
           match runtime_id with
           | None -> remove_runtime_scalar section_lines ~key
           | Some runtime_id -> replace_or_append_runtime_scalar section_lines ~key ~runtime_id
         in
         before @ (header :: next_section_lines) @ after_section)
  in
  join_lines updated_lines ~trailing_newline:true
;;

let update_runtime_string_array_text content ~key ~values =
  let lines, _trailing_newline = split_lines content in
  let updated_lines =
    match find_index is_runtime_header lines with
    | None -> append_runtime_string_array_section lines ~key ~values
    | Some header_index ->
      let before, from_header = split_at header_index lines in
      (match from_header with
       | [] -> append_runtime_string_array_section lines ~key ~values
       | header :: after_header ->
         let section_lines, after_section =
           match find_index is_toml_table_header after_header with
           | None -> after_header, []
           | Some next_header_index -> split_at next_header_index after_header
         in
         before
         @ (header :: replace_or_append_runtime_string_array section_lines ~key ~values)
         @ after_section)
  in
  join_lines updated_lines ~trailing_newline:true
;;

let remove_runtime_assignment_text content ~keeper_name =
  let lines, _trailing_newline = split_lines content in
  let updated_lines =
    match find_index is_runtime_assignments_header lines with
    | None -> lines
    | Some header_index ->
      let before, from_header = split_at header_index lines in
      (match from_header with
       | [] -> lines
       | header :: after_header ->
         let section_lines, after_section =
           match find_index is_toml_table_header after_header with
           | None -> after_header, []
           | Some next_header_index -> split_at next_header_index after_header
         in
         before @ (header :: remove_assignment section_lines ~keeper_name) @ after_section)
  in
  join_lines updated_lines ~trailing_newline:true
;;

let runtime_parse_errors_to_string errs =
  errs
  |> List.map (fun (err : Runtime_toml.parse_error) ->
    Printf.sprintf "%s: %s" err.path err.message)
  |> String.concat "; "
;;

let validate_runtime_config_text ~config_path content =
  let* cfg =
    Runtime_toml.parse_string content
    |> Result.map_error (fun errs ->
      Printf.sprintf
        "runtime config parse failed (%s): %s"
        config_path
        (runtime_parse_errors_to_string errs))
  in
  let* (_
         : t list
           * t
           * (string * string) list
           * string option
           * string option
           * string option
           * string list) =
    materialize_config ~config_path cfg
  in
  Ok ()
;;

let save_config_text ?runtime_config_path content =
  let* path = runtime_config_path_result ?runtime_config_path () in
  let* () = validate_runtime_config_text ~config_path:path content in
  let* () = Fs_compat.save_file_atomic path content in
  let* () = init_default ~config_path:path in
  Ok ()
;;

let set_runtime_id_for_keeper ?runtime_config_path ~keeper_name ~runtime_id () =
  let keeper_name = String.trim keeper_name in
  let runtime_id = String.trim runtime_id in
  if String.equal keeper_name ""
  then Error "keeper_name must not be empty"
  else if String.equal runtime_id ""
  then Error "runtime_id must not be empty"
  else if contains_newline keeper_name
  then Error "keeper_name must not contain newlines"
  else if contains_newline runtime_id
  then Error "runtime_id must not contain newlines"
  else
    let* path = runtime_config_path_result ?runtime_config_path () in
    let* content = load_file_result path in
    let next = update_runtime_assignment_text content ~keeper_name ~runtime_id in
    let* () = validate_runtime_config_text ~config_path:path next in
    let* () = Fs_compat.save_file_atomic path next in
    let* () = init_default ~config_path:path in
    Ok ()
;;

let clear_runtime_id_for_keeper ?runtime_config_path ~keeper_name () =
  let keeper_name = String.trim keeper_name in
  if String.equal keeper_name ""
  then Error "keeper_name must not be empty"
  else if contains_newline keeper_name
  then Error "keeper_name must not contain newlines"
  else
    let* path = runtime_config_path_result ?runtime_config_path () in
    let* content = load_file_result path in
    let next = remove_runtime_assignment_text content ~keeper_name in
    let* () = validate_runtime_config_text ~config_path:path next in
    let* () = Fs_compat.save_file_atomic path next in
    let* () = init_default ~config_path:path in
    Ok ()
;;

let set_runtime_scalar ?runtime_config_path ~key ~runtime_id () =
  let key = String.trim key in
  let runtime_id = Option.map String.trim runtime_id in
  if String.equal key ""
  then Error "runtime key must not be empty"
  else if contains_newline key
  then Error "runtime key must not contain newlines"
  else
    match runtime_id with
    | Some runtime_id when String.equal runtime_id "" ->
      Error "runtime_id must not be empty"
    | Some runtime_id when contains_newline runtime_id ->
      Error "runtime_id must not contain newlines"
    | _ ->
      let* path = runtime_config_path_result ?runtime_config_path () in
      let* content = load_file_result path in
      let next = update_runtime_scalar_text content ~key ~runtime_id in
      let* () = validate_runtime_config_text ~config_path:path next in
      let* () = Fs_compat.save_file_atomic path next in
      let* () = init_default ~config_path:path in
      Ok ()
;;

let set_runtime_string_array ?runtime_config_path ~key ~runtime_ids () =
  let key = String.trim key in
  let runtime_ids = List.map String.trim runtime_ids in
  if String.equal key ""
  then Error "runtime key must not be empty"
  else if contains_newline key
  then Error "runtime key must not contain newlines"
  else if List.exists (String.equal "") runtime_ids
  then Error "runtime_ids must not contain empty entries"
  else if List.exists contains_newline runtime_ids
  then Error "runtime_ids must not contain newlines"
  else (
    let* path = runtime_config_path_result ?runtime_config_path () in
    let* content = load_file_result path in
    let next = update_runtime_string_array_text content ~key ~values:runtime_ids in
    let* () = validate_runtime_config_text ~config_path:path next in
    let* () = Fs_compat.save_file_atomic path next in
    let* () = init_default ~config_path:path in
    Ok ())
;;

let set_runtime_default ?runtime_config_path ~runtime_id () =
  set_runtime_scalar ?runtime_config_path ~key:"default" ~runtime_id:(Some runtime_id) ()
;;

let set_runtime_librarian ?runtime_config_path ~runtime_id () =
  set_runtime_scalar ?runtime_config_path ~key:"librarian" ~runtime_id ()
;;

let set_runtime_structured_judge ?runtime_config_path ~runtime_id () =
  set_runtime_scalar ?runtime_config_path ~key:"structured_judge" ~runtime_id ()
;;

let set_runtime_cross_verifier ?runtime_config_path ~runtime_id () =
  set_runtime_scalar ?runtime_config_path ~key:"cross_verifier" ~runtime_id ()
;;

let set_runtime_media_failover ?runtime_config_path ~runtime_ids () =
  set_runtime_string_array ?runtime_config_path ~key:"media_failover" ~runtime_ids ()
;;

(* RFC-0206 single-binding: the deleted [Runtime_runtime.resolve_*_max_context]
   scanned model labels across a runtime's candidates and folded the max. Under
   single-binding every keeper uses the default runtime, so the context budget
   is that runtime's [model.max_context]. Falls back to
   [Runtime_constants.fallback_context_window] when the default is not yet
   initialized (config-less test binaries). *)
let default_max_context () : int =
  match get_default_runtime () with
  | Some rt -> max_context_of_runtime rt
  | None -> Runtime_constants.fallback_context_window
;;

(* RFC-0206 single-binding: the deleted
   [Runtime_runtime.default_local_model_label_and_id] scanned configured/available
   labels and returned the model-id substring. Under single-binding the model
   name sent to the runtime endpoint is the default runtime's [model.api_name].
   Falls back to ["auto"] before {!init_default} runs. *)
let default_model_api_name () : string =
  match get_default_runtime () with
  | Some rt -> rt.model.api_name
  | None -> "auto"
;;
