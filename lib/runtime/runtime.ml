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

(** binding 을 Runtime 으로 변환하되 실패 이유를 보존한다. provider/model
    resolve 또는 provider_config materialize 가 실패하면 [Error reason] —
    동작은 fail-closed 그대로(partial-boot 없음, 해당 binding 은 Runtime 목록에서
    제외)이되 왜 제외되는지 이유를 잃지 않는다. 이 이유는 assignment / default /
    librarian / lane 검증이 "not found" 대신 근본 원인을 표면화하는 데 쓰인다
    (Unknown→silent-drop 안티패턴 차단). *)
let of_binding_result (cfg : config) (b : binding) : (t, string) result =
  match provider_of_id cfg b.provider_id, model_of_id cfg b.model_id with
  | Some provider, Some model ->
    (match Runtime_adapter.binding_to_provider_config cfg b with
     | Ok provider_config ->
       Ok { id = id_of_binding b; provider; model; binding = b; provider_config }
     | Error reason -> Error reason)
  | None, _ -> Error (Printf.sprintf "provider not found: %s" b.provider_id)
  | Some _, None -> Error (Printf.sprintf "model not found: %s" b.model_id)
;;

(** {!of_binding_result} 의 option 투영. materialize 실패 이유가 필요 없는
    호출자(단일 binding 성공 여부만 확인)를 위한 유지 API. *)
let of_binding (cfg : config) (b : binding) : t option =
  Result.to_option (of_binding_result cfg b)
;;

let is_local_provider (provider : provider) =
  match provider.transport, provider.credentials with
  | Cli _, _ -> true
  | Http endpoint, None ->
    Uri.of_string endpoint |> Uri.host |> Masc_network_defaults.is_loopback_host_opt
  | Http _, Some _ -> false
;;

let is_local_runtime (runtime : t) = is_local_provider runtime.provider

(* Split configured bindings into successfully materialized runtimes and the
   ones that were defined but could not be materialized, each paired with the
   reason it was dropped. The drop set ([id -> reason]) lets assignment /
   default / librarian / lane validation surface *why* a target binding is
   absent from the runtime list (e.g. "provider ... uses protocol messages-http,
   which the runtime adapter cannot build a provider_config for ...") instead of
   the misleading "not found among N runtimes", which points the operator at a
   typo that does not exist. Materialize failure stays fail-closed: the binding
   is still excluded from [runtimes] (RFC-0206 §2.1). *)
let partition_bindings (cfg : config) (bindings : binding list)
  : t list * (string * string) list
  =
  let runtimes, dropped =
    List.fold_left
      (fun (runtimes, dropped) (b : binding) ->
         match of_binding_result cfg b with
         | Ok rt -> rt :: runtimes, dropped
         | Error reason -> runtimes, (id_of_binding b, reason) :: dropped)
      ([], [])
      bindings
  in
  List.rev runtimes, List.rev dropped
;;

(* Explain why a validation target [id] is absent from the materialized
   [runtimes]. An [id] present in [dropped_bindings] was defined but failed to
   materialize — surface that reason (the actionable cause). An [id] absent from
   both is a genuine operator typo and keeps the original "not found among N
   runtimes" wording. The result is the suffix that follows the quoted id in
   each caller's message, so the existing prefix ("[runtime.assignments].<k> =
   <id>") is preserved and the typo case stays byte-for-byte unchanged. *)
let unresolved_runtime_suffix ~(dropped_bindings : (string * string) list)
    ~(runtime_count : int) (id : string) : string =
  match List.assoc_opt id dropped_bindings with
  | Some reason ->
    Printf.sprintf
      ": binding is defined but could not be materialized as a runtime — %s"
      reason
  | None -> Printf.sprintf " not found among %d runtimes" runtime_count
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
let validate_keeper_assignments ~(config_path : string)
    ~(dropped_bindings : (string * string) list) (runtimes : t list)
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
         "%s: [runtime.assignments].%s = %S%s"
         config_path
         keeper_name
         runtime_id
         (unresolved_runtime_suffix ~dropped_bindings
            ~runtime_count:(List.length runtimes) runtime_id))
;;

(* [runtime].librarian must resolve to a configured runtime when set, mirroring
   [runtime].default / [runtime.assignments] validation: an unknown id is an
   operator typo rejected at load, not a silent fallback (Unknown→Permissive
   anti-pattern). [None] is the designed "inherit the keeper's runtime" case. *)
let validate_librarian_runtime ~(config_path : string)
    ~(dropped_bindings : (string * string) list) (runtimes : t list)
    (librarian_id : string option) : (unit, string) result =
  match librarian_id with
  | None -> Ok ()
  | Some id ->
    if List.exists (fun (r : t) -> String.equal r.id id) runtimes
    then Ok ()
    else
      Error
        (Printf.sprintf
           "%s: [runtime].librarian = %S%s"
           config_path
           id
           (unresolved_runtime_suffix ~dropped_bindings
              ~runtime_count:(List.length runtimes) id))
;;

(* [runtime].cross_verifier mirrors [runtime].librarian validation: an unknown
   id is an operator typo rejected at load, not a silent fallback
   (Unknown→Permissive anti-pattern). [None] is the designed "inherit
   [runtime].default" case. *)
let validate_cross_verifier_runtime ~(config_path : string)
    ~(dropped_bindings : (string * string) list) (runtimes : t list)
    (cross_verifier_id : string option) : (unit, string) result =
  match cross_verifier_id with
  | None -> Ok ()
  | Some id ->
    (match List.find_opt (fun (r : t) -> String.equal r.id id) runtimes with
     | None ->
      Error
        (Printf.sprintf
           "%s: [runtime].cross_verifier = %S%s"
           config_path
           id
           (unresolved_runtime_suffix ~dropped_bindings
              ~runtime_count:(List.length runtimes) id))
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
let validate_structured_judge_runtime ~(config_path : string)
    ~(dropped_bindings : (string * string) list) (runtimes : t list)
    (structured_judge_id : string option) : (unit, string) result =
  match structured_judge_id with
  | None -> Ok ()
  | Some id ->
    (match List.find_opt (fun (r : t) -> String.equal r.id id) runtimes with
     | None ->
       Error
         (Printf.sprintf
            "%s: [runtime].structured_judge = %S%s"
            config_path
            id
            (unresolved_runtime_suffix ~dropped_bindings
               ~runtime_count:(List.length runtimes) id))
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

(* [runtime].hitl_summary is a dedicated lane for approval context summaries.
   It deliberately validates only existence: the worker can use either native
   structured output or plain JSON mode depending on the resolved provider config. *)
let validate_hitl_summary_runtime ~(config_path : string)
    ~(dropped_bindings : (string * string) list) (runtimes : t list)
    (hitl_summary_id : string option) : (unit, string) result =
  match hitl_summary_id with
  | None -> Ok ()
  | Some id ->
    if List.exists (fun (r : t) -> String.equal r.id id) runtimes
    then Ok ()
    else
      Error
        (Printf.sprintf
           "%s: [runtime].hitl_summary = %S%s"
           config_path
           id
           (unresolved_runtime_suffix ~dropped_bindings
              ~runtime_count:(List.length runtimes) id))
;;

(* [runtime].media_failover (RFC-0265) mirrors [runtime].librarian validation for
   each id in the ordered list: an unknown id is an operator typo rejected at
   load, not a silent drop (Unknown→Permissive anti-pattern). [[]] is the designed
   "derive capable runtimes from declared capabilities" case. *)
let validate_media_failover ~(config_path : string)
    ~(dropped_bindings : (string * string) list) (runtimes : t list)
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
         "%s: [runtime].media_failover entry %S%s"
         config_path
         id
         (unresolved_runtime_suffix ~dropped_bindings
            ~runtime_count:(List.length runtimes) id))
;;

(* [runtime.lanes.<id>] candidate ids must resolve to configured runtimes.
   Empty candidate lists are rejected at parse time; here we reject unknown ids
   as operator typos (mirrors [runtime].default validation). *)
let validate_lanes ~(config_path : string)
    ~(dropped_bindings : (string * string) list) (runtimes : t list)
    (lane_decls : Runtime_schema.lane_decl list)
  : (unit, string) result
  =
  let runtime_exists id =
    List.exists (fun (r : t) -> String.equal r.id id) runtimes
  in
  let rec first_unknown = function
    | [] -> None
    | { Runtime_schema.id = lane_id; candidate_ids; _ } :: rest ->
      (match List.find_opt (fun id -> not (runtime_exists id)) candidate_ids with
       | Some id -> Some (lane_id, id)
       | None -> first_unknown rest)
  in
  match first_unknown lane_decls with
  | None -> Ok ()
  | Some (lane_id, id) ->
    Error
      (Printf.sprintf
         "%s: [runtime.lanes.%s] candidate %S%s"
         config_path
         lane_id
         id
         (unresolved_runtime_suffix ~dropped_bindings
            ~runtime_count:(List.length runtimes) id))
;;

let lanes_of_decls ~(config_path : string)
    ~(dropped_bindings : (string * string) list) (runtimes : t list)
    (lane_decls : Runtime_schema.lane_decl list)
  : (Runtime_lane.t list, string) result
  =
  let* () = validate_lanes ~config_path ~dropped_bindings runtimes lane_decls in
  Ok
    (List.map
       (fun ({ Runtime_schema.id; strategy; candidate_ids } : Runtime_schema.lane_decl) ->
          match strategy with
          | Runtime_schema.Ordered ->
            Runtime_lane.make ~id ~strategy:Runtime_lane.Ordered candidate_ids)
       lane_decls)
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
          Add deployment rows to oas-models-overlay.toml or update the OAS embedded catalog: %s"
         config_path
         (List.length unknown)
         (String.concat ", " (List.map fst unknown)))
;;

type missing_catalog_model =
  { runtime_id : string
  ; provider_id : string
  ; provider_label : string
  ; model_id : string
  }

type missing_catalog_report =
  { config_path : string
  ; missing_models : missing_catalog_model list
  }

type dropped_runtime_assignment =
  { keeper_name : string
  ; runtime_id : string
  }

type dropped_runtime_route =
  { route_name : string
  ; runtime_id : string
  }

type dropped_runtime_lane =
  { lane_id : string
  ; runtime_ids : string list
  }

type startup_degradation =
  { report : missing_catalog_report
  ; configured_default_runtime_id : string
  ; effective_default_runtime_id : string
  ; disabled_runtime_ids : string list
  ; dropped_assignments : dropped_runtime_assignment list
  ; dropped_routes : dropped_runtime_route list
  ; dropped_media_failover : string list
  ; dropped_lane_candidates : dropped_runtime_lane list
  ; dropped_lanes : dropped_runtime_lane list
  }

type init_default_outcome =
  | Initialized
  | Initialized_degraded of startup_degradation

type strict_init_error =
  | Runtime_config_error of string
  | Missing_catalog_models of missing_catalog_report

let missing_catalog_model_label (missing : missing_catalog_model) =
  Printf.sprintf
    "%s (provider_label=%s, model=%s)"
    missing.runtime_id
    missing.provider_label
    missing.model_id
;;

let missing_catalog_report_to_string (report : missing_catalog_report) =
  Printf.sprintf
    "%s: %d runtime model(s) absent from the OAS capability catalog; they \
     would use provider_default and silently drop thinking/sampling control. \
     Add deployment rows to oas-models-overlay.toml or update the OAS embedded catalog: %s"
    report.config_path
    (List.length report.missing_models)
    (String.concat ", " (List.map missing_catalog_model_label report.missing_models))
;;

let strict_init_error_to_string = function
  | Runtime_config_error msg -> msg
  | Missing_catalog_models report -> missing_catalog_report_to_string report
;;

let startup_degradation_to_string (degradation : startup_degradation) =
  Printf.sprintf
    "runtime catalog degraded boot: disabled %d uncatalogued runtime(s); \
     configured default %S -> effective default %S; operator must add catalog \
     rows for: %s"
    (List.length degradation.disabled_runtime_ids)
    degradation.configured_default_runtime_id
    degradation.effective_default_runtime_id
    (String.concat ", "
       (List.map missing_catalog_model_label degradation.report.missing_models))
;;

let dropped_assignment_to_yojson (entry : dropped_runtime_assignment) =
  `Assoc
    [ "keeper_name", `String entry.keeper_name
    ; "runtime_id", `String entry.runtime_id
    ]
;;

let dropped_route_to_yojson (entry : dropped_runtime_route) =
  `Assoc [ "route_name", `String entry.route_name; "runtime_id", `String entry.runtime_id ]
;;

let dropped_lane_to_yojson (entry : dropped_runtime_lane) =
  `Assoc
    [ "lane_id", `String entry.lane_id
    ; "runtime_ids", `List (List.map (fun id -> `String id) entry.runtime_ids)
    ]
;;

let missing_catalog_model_to_yojson (entry : missing_catalog_model) =
  `Assoc
    [ "runtime_id", `String entry.runtime_id
    ; "provider_id", `String entry.provider_id
    ; "provider_label", `String entry.provider_label
    ; "model_id", `String entry.model_id
    ]
;;

let startup_degradation_to_yojson = function
  | None ->
    `Assoc
      [ "schema", `String "masc.runtime_startup_degradation.v1"
      ; "status", `String "ok"
      ; "degraded", `Bool false
      ; "operator_action_required", `Bool false
      ; "terminal_reason", `String "none"
      ; "missing_catalog_model_count", `Int 0
      ; "disabled_runtime_ids", `List []
      ]
  | Some degradation ->
    `Assoc
      [ "schema", `String "masc.runtime_startup_degradation.v1"
      ; "status", `String "degraded"
      ; "degraded", `Bool true
      ; "operator_action_required", `Bool true
      ; "terminal_reason", `String "missing_oas_catalog_models"
      ; "message", `String (startup_degradation_to_string degradation)
      ; "config_path", `String degradation.report.config_path
      ; "configured_default_runtime_id"
        , `String degradation.configured_default_runtime_id
      ; "effective_default_runtime_id", `String degradation.effective_default_runtime_id
      ; "missing_catalog_model_count", `Int (List.length degradation.report.missing_models)
      ; ( "missing_catalog_models"
        , `List (List.map missing_catalog_model_to_yojson degradation.report.missing_models)
        )
      ; ( "disabled_runtime_ids"
        , `List (List.map (fun id -> `String id) degradation.disabled_runtime_ids)
        )
      ; ( "dropped_assignments"
        , `List (List.map dropped_assignment_to_yojson degradation.dropped_assignments)
        )
      ; "dropped_routes", `List (List.map dropped_route_to_yojson degradation.dropped_routes)
      ; ( "dropped_media_failover"
        , `List (List.map (fun id -> `String id) degradation.dropped_media_failover)
        )
      ; ( "dropped_lane_candidates"
        , `List (List.map dropped_lane_to_yojson degradation.dropped_lane_candidates)
        )
      ; "dropped_lanes", `List (List.map dropped_lane_to_yojson degradation.dropped_lanes)
      ; ( "next_action"
        , `String
            "Add deployment rows to oas-models-overlay.toml (or upstream OAS) or remove \
             those runtime.toml bindings; uncatalogued runtimes are disabled \
             for this process." )
      ]
;;

let capabilities_for_runtime (rt : t) =
  Llm_provider.Provider_config.capabilities_for_config_model rt.provider_config
;;

type max_context_source =
  | Override
  | Capability
  | Override_clamped_by_capability

let max_context_source_to_string = function
  | Override -> "override"
  | Capability -> "capability"
  | Override_clamped_by_capability -> "override_clamped_by_capability"
;;

(* Effective input context window and the source that produced it.
   [None] means neither the runtime.toml [model.max-context] override nor the
   OAS capability catalog declares a positive context window for this
   binding — [validate_runtime_max_context] rejects such a runtime at load
   (fail-closed; Unknown->Permissive anti-pattern, not a silent default). *)
let resolve_max_context_of_runtime (rt : t) : (int * max_context_source) option =
  let capability_cap =
    match capabilities_for_runtime rt with
    | Some caps ->
      (match caps.Llm_provider.Capabilities.max_context_tokens with
       | Some c when c > 0 -> Some c
       | Some _ | None -> None)
    | None -> None
  in
  match rt.model.max_context, capability_cap with
  | Some o, Some c when o > c -> Some (c, Override_clamped_by_capability)
  | Some o, (Some _ | None) -> Some (o, Override)
  | None, Some c -> Some (c, Capability)
  | None, None -> None
;;

(* Every materialized runtime must resolve a positive context window from the
   runtime.toml override or the OAS capability catalog. A binding that leaves
   both unset is a config error rejected here, not a runtime defaulted to a
   fallback window (RFC-0206 §2.1 no silent fallback). *)
let validate_runtime_max_context ~(config_path : string) (runtimes : t list)
  : (unit, string) result
  =
  match
    List.find_opt
      (fun (r : t) -> Option.is_none (resolve_max_context_of_runtime r))
      runtimes
  with
  | None -> Ok ()
  | Some r ->
    Error
      (Printf.sprintf
         "%s: runtime %S (model=%s) has no [models.%s].max-context override \
          and no OAS capability catalog max-context; set the override or add \
          the model to the capability catalog (no silent default — \
          RFC-0206 §2.1)"
         config_path
         r.id
         r.provider_config.model_id
         r.model.id)
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

let missing_runtime_model_capabilities ~(config_path : string) (runtimes : t list)
  : missing_catalog_report option
  =
  let missing_models =
    List.filter_map
      (fun (r : t) ->
         match capabilities_for_runtime r with
         | Some _ -> None
         | None ->
           let provider_label =
             Llm_provider.Provider_config.capability_provider_label r.provider_config
           in
           let model_id = r.provider_config.model_id in
           Some
             { runtime_id = r.id
             ; provider_id = r.provider.id
             ; provider_label
             ; model_id
             })
      runtimes
  in
  match missing_models with
  | [] -> None
  | first :: rest -> Some { config_path; missing_models = first :: rest }
;;

let runtime_missing_from_report (report : missing_catalog_report) runtime_id =
  List.exists
    (fun (missing : missing_catalog_model) -> String.equal missing.runtime_id runtime_id)
    report.missing_models
;;

let runtime_default_route_name = "[runtime].default"

let dropped_assignment_label (entry : dropped_runtime_assignment) =
  Printf.sprintf "[runtime.assignments].%s=%S" entry.keeper_name entry.runtime_id
;;

let dropped_route_label (entry : dropped_runtime_route) =
  Printf.sprintf "%s=%S" entry.route_name entry.runtime_id
;;

let dropped_lane_label (prefix : string) (entry : dropped_runtime_lane) =
  Printf.sprintf
    "%s.%s=[%s]"
    prefix
    entry.lane_id
    (String.concat ", " (List.map (Printf.sprintf "%S") entry.runtime_ids))
;;

let missing_reference_error
    ~(config_path : string)
    ~(configured_default_runtime_id : string)
    ~(default_drop : dropped_runtime_route option)
    ~(dropped_assignments : dropped_runtime_assignment list)
    ~(dropped_routes : dropped_runtime_route list)
    ~(dropped_media_failover : string list)
    ~(dropped_lane_candidates : dropped_runtime_lane list)
    ~(dropped_lanes : dropped_runtime_lane list)
  =
  let references =
    List.concat
      [ List.map dropped_assignment_label dropped_assignments
      ; List.map dropped_route_label dropped_routes
      ; (match dropped_media_failover with
         | [] -> []
         | runtime_ids ->
           [ Printf.sprintf
               "[runtime].media_failover=[%s]"
               (String.concat ", " (List.map (Printf.sprintf "%S") runtime_ids))
           ])
      ; List.map
          (dropped_lane_label "[runtime.lanes].candidates")
          dropped_lane_candidates
      ; List.map (dropped_lane_label "[runtime.lanes].dropped") dropped_lanes
      ]
  in
  let default_fallback_explanation =
    match default_drop with
    | Some _ ->
      Printf.sprintf
        "Configured %s=%S is absent from the OAS capability catalog; degraded \
         boot will not select a different default runtime."
        runtime_default_route_name
        configured_default_runtime_id
    | None ->
      Printf.sprintf
        "Configured %s=%S remains catalog-known, but degraded boot would erase \
         the missing references above into that default fallback."
        runtime_default_route_name
        configured_default_runtime_id
  in
  Printf.sprintf
    "%s: cannot use degraded runtime boot because catalog-missing runtime ids \
     are referenced by routing config: %s. %s Add catalog rows to \
     oas-models-overlay.toml (or upstream OAS) or remove those routing references; MASC will not erase \
     explicit runtime intent into [runtime].default fallback."
    config_path
    (String.concat "; " references)
    default_fallback_explanation
;;

let degrade_loaded_for_missing_catalog
    ( (runtimes, configured_default, assignments, librarian_id, structured_judge_id,
       hitl_summary_id, cross_verifier_id, media_failover, lanes) :
      t list
      * t
      * (string * string) list
      * string option
      * string option
      * string option
      * string option
      * string list
      * Runtime_lane.t list )
    (report : missing_catalog_report)
  : ( ( t list
        * t
        * (string * string) list
        * string option
        * string option
        * string option
        * string option
        * string list
        * Runtime_lane.t list )
      * startup_degradation
    , string )
    result
  =
  let is_missing = runtime_missing_from_report report in
  let active_runtimes = List.filter (fun (rt : t) -> not (is_missing rt.id)) runtimes in
  let disabled_runtime_ids =
    report.missing_models
    |> List.map (fun (missing : missing_catalog_model) -> missing.runtime_id)
    |> List.sort_uniq String.compare
  in
  let kept_assignments, dropped_assignments =
    List.fold_right
      (fun (keeper_name, runtime_id) (kept, dropped) ->
         if is_missing runtime_id
         then kept, { keeper_name; runtime_id } :: dropped
         else (keeper_name, runtime_id) :: kept, dropped)
      assignments
      ([], [])
  in
  let default_drop =
    if is_missing configured_default.id
    then Some { route_name = runtime_default_route_name; runtime_id = configured_default.id }
    else None
  in
  let drop_route route_name = function
    | None -> None, None
    | Some runtime_id when is_missing runtime_id -> None, Some { route_name; runtime_id }
    | Some _ as value -> value, None
  in
  let librarian_id, librarian_drop = drop_route "[runtime].librarian" librarian_id in
  let structured_judge_id, structured_judge_drop =
    drop_route "[runtime].structured_judge" structured_judge_id
  in
  let hitl_summary_id, hitl_summary_drop =
    drop_route "[runtime].hitl_summary" hitl_summary_id
  in
  let cross_verifier_id, cross_verifier_drop =
    drop_route "[runtime].cross_verifier" cross_verifier_id
  in
  let dropped_routes =
    [ default_drop
    ; librarian_drop
    ; structured_judge_drop
    ; hitl_summary_drop
    ; cross_verifier_drop
    ]
    |> List.filter_map Fun.id
  in
  let kept_media_failover, dropped_media_failover =
    List.fold_right
      (fun runtime_id (kept, dropped) ->
         if is_missing runtime_id
         then kept, runtime_id :: dropped
         else runtime_id :: kept, dropped)
      media_failover
      ([], [])
  in
  let kept_lanes, dropped_lane_candidates, dropped_lanes =
    List.fold_right
      (fun (lane : Runtime_lane.t) (kept, dropped_candidates, dropped_lanes) ->
         let kept_candidates, dropped_candidates_for_lane =
           List.fold_right
             (fun runtime_id (kept_ids, dropped_ids) ->
                if is_missing runtime_id
                then kept_ids, runtime_id :: dropped_ids
                else runtime_id :: kept_ids, dropped_ids)
             (Runtime_lane.ordered_candidates lane)
             ([], [])
         in
         let dropped_candidates =
           match dropped_candidates_for_lane with
           | [] -> dropped_candidates
           | runtime_ids ->
             { lane_id = Runtime_lane.id lane; runtime_ids } :: dropped_candidates
         in
         match kept_candidates with
         | [] ->
           ( kept
           , dropped_candidates
           , { lane_id = Runtime_lane.id lane
             ; runtime_ids = Runtime_lane.ordered_candidates lane
             }
             :: dropped_lanes )
         | _ ->
           ( Runtime_lane.make
               ~id:(Runtime_lane.id lane)
               ~strategy:(Runtime_lane.strategy lane)
               kept_candidates
             :: kept
           , dropped_candidates
           , dropped_lanes ))
      lanes
      ([], [], [])
  in
  let has_routing_references =
    (not (List.is_empty dropped_assignments))
    || (not (List.is_empty dropped_routes))
    || (not (List.is_empty dropped_media_failover))
    || (not (List.is_empty dropped_lane_candidates))
    || not (List.is_empty dropped_lanes)
  in
  match active_runtimes with
  | [] ->
    Error
      (Printf.sprintf
         "%s: all configured runtime models are absent from the OAS capability \
          catalog; cannot degrade without dispatching through provider_default"
         report.config_path)
  | _ when has_routing_references ->
    Error
      (missing_reference_error
         ~config_path:report.config_path
         ~configured_default_runtime_id:configured_default.id
         ~default_drop
         ~dropped_assignments
         ~dropped_routes
         ~dropped_media_failover
         ~dropped_lane_candidates
         ~dropped_lanes)
  | _ ->
    let degradation =
      { report
      ; configured_default_runtime_id = configured_default.id
      ; effective_default_runtime_id = configured_default.id
      ; disabled_runtime_ids
      ; dropped_assignments
      ; dropped_routes
      ; dropped_media_failover
      ; dropped_lane_candidates
      ; dropped_lanes
      }
    in
    Ok
      ( ( active_runtimes
        , configured_default
        , kept_assignments
        , librarian_id
        , structured_judge_id
        , hitl_summary_id
        , cross_verifier_id
        , kept_media_failover
        , kept_lanes )
      , degradation )
;;

let materialize_config
    ?(validate_max_context = true)
    ~(config_path : string)
    (cfg : config)
  : ( t list
      * t
      * (string * string) list
      * string option
      * string option
      * string option
      * string option
      * string list
      * Runtime_lane.t list
    , string )
    result
  =
  let runtimes, dropped_bindings = partition_bindings cfg cfg.bindings in
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
              "%s: [runtime].default = %S%s"
              config_path
              did
              (unresolved_runtime_suffix ~dropped_bindings
                 ~runtime_count:(List.length runtimes) did))
       | Some rt -> Ok rt)
  in
  let* () =
    validate_keeper_assignments ~config_path ~dropped_bindings runtimes assignments
  in
  let* () =
    validate_librarian_runtime ~config_path ~dropped_bindings runtimes
      cfg.librarian_runtime_id
  in
  let* () =
    validate_structured_judge_runtime ~config_path ~dropped_bindings runtimes
      cfg.structured_judge_runtime_id
  in
  let* () =
    validate_hitl_summary_runtime ~config_path ~dropped_bindings runtimes
      cfg.hitl_summary_runtime_id
  in
  let* () =
    validate_cross_verifier_runtime ~config_path ~dropped_bindings runtimes
      cfg.cross_verifier_runtime_id
  in
  let* () =
    validate_media_failover ~config_path ~dropped_bindings runtimes
      cfg.media_failover
  in
  let* () =
    if validate_max_context
    then validate_runtime_max_context ~config_path runtimes
    else Ok ()
  in
  let* lanes =
    lanes_of_decls ~config_path ~dropped_bindings runtimes cfg.lane_decls
  in
  (* The OAS catalog membership gate is intentionally not called here:
     [load_list] stays a routing-validity parser for tests and config probes.
     Startup callers choose fail-closed [init_default_strict] or server-visible
     degraded boot [init_default_degraded_report]. *)
  Ok
    ( runtimes
    , rt
    , assignments
    , cfg.librarian_runtime_id
    , cfg.structured_judge_runtime_id
    , cfg.hitl_summary_runtime_id
    , cfg.cross_verifier_runtime_id
    , cfg.media_failover
    , lanes )
;;

let load_list_internal ~(config_path : string) ~validate_max_context
  : ( t list
       * t
       * (string * string) list
       * string option
       * string option
       * string option
       * string option
       * string list
       * Runtime_lane.t list
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
  materialize_config ~validate_max_context ~config_path cfg
;;

let load_list ~config_path =
  load_list_internal ~config_path ~validate_max_context:true
;;

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
  ; hitl_summary_runtime_id : string option
  ; cross_verifier_runtime_id : string option
  ; media_failover : string list
  ; lanes : Runtime_lane.t list
  ; config_path : string option
  ; startup_degradation : startup_degradation option
  }

let empty_loaded_state =
  { default_runtime = None
  ; runtimes = []
  ; keeper_assignments = []
  ; librarian_runtime_id = None
  ; structured_judge_runtime_id = None
  ; hitl_summary_runtime_id = None
  ; cross_verifier_runtime_id = None
  ; media_failover = []
  ; lanes = []
  ; config_path = None
  ; startup_degradation = None
  }

let loaded_state_ref : loaded_state Atomic.t = Atomic.make empty_loaded_state

let runtime_ids runtimes = List.map (fun (rt : t) -> rt.id) runtimes

let set_loaded
    ?startup_degradation
    ~config_path
    ( runtimes
    , rt
    , assignments
    , librarian_id
    , structured_judge_id
    , hitl_summary_id
    , cross_verifier_id
    , media_failover
    , lanes ) =
  Atomic.set loaded_state_ref
    { default_runtime = Some rt
    ; runtimes
    ; keeper_assignments = assignments
    ; librarian_runtime_id = librarian_id
    ; structured_judge_runtime_id = structured_judge_id
    ; hitl_summary_runtime_id = hitl_summary_id
    ; cross_verifier_runtime_id = cross_verifier_id
    ; media_failover
    ; lanes
    ; config_path = Some config_path
    ; startup_degradation
    }

let init_default ~config_path =
  let* loaded = load_list ~config_path in
  set_loaded ~config_path loaded;
  Ok ()

(* Fail-closed startup entry point: [load_list] (RFC-0206 routing validation)
   PLUS the OAS capability-catalog gate. Strict callers use this so an operator
   runtime.toml whose model is absent from the catalog is rejected before boot —
   the gate that load_list intentionally no longer applies, kept out of load_list
   so unit tests stay catalog-independent. *)
let init_default_strict_report ~config_path =
  match load_list ~config_path with
  | Error msg -> Error (Runtime_config_error msg)
  | Ok ((runtimes, _, _, _, _, _, _, _, _) as loaded) ->
    (match missing_runtime_model_capabilities ~config_path runtimes with
     | Some report -> Error (Missing_catalog_models report)
     | None ->
       set_loaded ~config_path loaded;
       Ok ())

let init_default_strict ~config_path =
  init_default_strict_report ~config_path
  |> Result.map_error strict_init_error_to_string

let init_default_degraded_report ~config_path =
  match load_list_internal ~config_path ~validate_max_context:false with
  | Error msg -> Error (Runtime_config_error msg)
  | Ok ((runtimes, _, _, _, _, _, _, _, _) as loaded) ->
    (match missing_runtime_model_capabilities ~config_path runtimes with
     | None ->
       (match validate_runtime_max_context ~config_path runtimes with
        | Error msg -> Error (Runtime_config_error msg)
        | Ok () ->
          set_loaded ~config_path loaded;
          Ok Initialized)
     | Some report ->
       (match degrade_loaded_for_missing_catalog loaded report with
        | Error msg -> Error (Runtime_config_error msg)
        | Ok (((active_runtimes, _, _, _, _, _, _, _, _) as degraded_loaded), degradation) ->
          (match validate_runtime_max_context ~config_path active_runtimes with
           | Error msg -> Error (Runtime_config_error msg)
           | Ok () ->
             set_loaded ~startup_degradation:degradation ~config_path degraded_loaded;
             Ok (Initialized_degraded degradation))))

let runtime_state () = Atomic.get loaded_state_ref

module For_testing = struct
  type snapshot = loaded_state

  let snapshot () = runtime_state ()
  let restore snapshot = Atomic.set loaded_state_ref snapshot
end

let get_default_runtime () = (runtime_state ()).default_runtime
let get_runtimes () = (runtime_state ()).runtimes
let get_runtime_ids () = runtime_ids (runtime_state ()).runtimes
let startup_degradation () = (runtime_state ()).startup_degradation
let startup_degraded () = Option.is_some (startup_degradation ())

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

(* [runtime].hitl_summary is the dedicated HITL approval-summary lane,
   consumed by [Keeper_approval_queue.provider_config_for_summary]. [None]
   falls through to the structured-judge routing chain. *)
let hitl_summary_runtime_id () = (runtime_state ()).hitl_summary_runtime_id

let runtime_id_for_structured_judge () =
  let state = runtime_state () in
  match state.structured_judge_runtime_id, state.librarian_runtime_id with
  | Some id, _ -> id
  | None, Some id -> id
  | None, None -> default_runtime_id_or_fail ()
;;

let runtime_id_for_hitl_summary () =
  match (runtime_state ()).hitl_summary_runtime_id with
  | Some id -> id
  | None -> runtime_id_for_structured_judge ()
;;

(* [runtime].cross_verifier routing for the anti-rationalization evaluator.
   [None] = the evaluator inherits [runtime].default. Reads the Atomic ref set by
   [init_default]. *)
let cross_verifier_runtime_id () = (runtime_state ()).cross_verifier_runtime_id

(* [runtime].media_failover ordered runtime ids for RFC-0265 modality-gated
   reroute. [[]] = derive capable runtimes from declared capabilities. Reads the
   Atomic ref set by [init_default]. *)
let media_failover () = (runtime_state ()).media_failover

(* [runtime.lanes.<id>] ordered failover candidate lists. Reads the Atomic ref
   set by [init_default]. *)
let lanes () = (runtime_state ()).lanes

let get_lane_by_id (id : string) : Runtime_lane.t option =
  List.find_opt (fun (lane : Runtime_lane.t) -> String.equal lane.id id)
    (runtime_state ()).lanes
;;

(* RFC-0207: resolve a runtime by its binding-key id ["provider.model"].  The
   keeper turn driver dispatches to the *requested* runtime (a keeper's persona
   [model] selection or the default) instead of unconditionally the default; an
   unknown id returns [None] so the driver fails fast (no silent substitution —
   RFC-0206 §2.1).  Reads [runtimes_ref], never a module-level eager binding. *)
let get_runtime_by_id (id : string) : t option =
  List.find_opt (fun (rt : t) -> String.equal rt.id id) (runtime_state ()).runtimes
;;

let is_local_runtime_id (id : string) : bool option =
  get_runtime_by_id id |> Option.map is_local_runtime
;;

let max_context_of_runtime (rt : t) : int =
  match resolve_max_context_of_runtime rt with
  | Some (n, _source) -> n
  | None ->
    failwith
      (Printf.sprintf
         "Runtime.max_context_of_runtime: %s has no resolvable max-context; \
          materialize_config should have rejected this at load (no silent \
          fallback — RFC-0206 §2.1)"
         rt.id)
;;

(* Resolve a keeper assignment to either a lane or a single runtime. Lanes are
   preferred so a lane id can shadow a runtime id (lanes are explicit operator
   routing constructs). [Missing] means the assignment does not name a known
   lane or runtime. *)
let resolve_assignment (assigned_id : string) =
  match get_lane_by_id assigned_id with
  | Some lane -> `Lane lane
  | None ->
    (match get_runtime_by_id assigned_id with
     | Some runtime -> `Single_runtime runtime
     | None -> `Missing)
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
   the provider/model catalog, not the per-binding runtime config. This is an
   observable capability ceiling only. OAS owns request validation and clamp
   policy; MASC never turns this value into a request default. *)
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

(* The per-model [temperature] override declared in runtime.toml
   ([models.<id>.temperature]), or [None] when the runtime is unknown or the
   model leaves it unset. Projects the runtime.toml [model] record (per-binding
   config SSOT), mirroring [thinking_support_of_runtime_id]. Consumed by
   [Runtime_inference.resolve_temperature]: a keeper turn uses this value when
   set and its caller fallback otherwise. *)
let temperature_of_runtime_id (id : string) : float option =
  match get_runtime_by_id id with
  | Some rt -> rt.model.temperature
  | None -> None
;;

let top_p_of_runtime_id (id : string) : float option =
  match get_runtime_by_id id with
  | Some rt -> rt.provider_config.top_p
  | None -> None
;;

let top_k_of_runtime_id (id : string) : int option =
  match get_runtime_by_id id with
  | Some rt -> rt.provider_config.top_k
  | None -> None
;;

let min_p_of_runtime_id (id : string) : float option =
  match get_runtime_by_id id with
  | Some rt -> rt.provider_config.min_p
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

(* Comment-preserving TOML line editing lives in [Toml_line_editor] (RFC-0306
   §3.2). These aliases keep the runtime.toml routing/assignment editor's call
   sites unchanged while removing the duplicated implementations. *)
let toml_escape_string = Toml_line_editor.escape_string

let assignment_line ~keeper_name ~runtime_id =
  Printf.sprintf
    "\"%s\" = \"%s\""
    (toml_escape_string keeper_name)
    (toml_escape_string runtime_id)
;;

let runtime_scalar_line ~key ~runtime_id =
  Toml_line_editor.scalar_line ~key ~value:runtime_id
;;

let runtime_string_array_line = Toml_line_editor.string_array_line

let split_lines = Toml_line_editor.split_lines
let join_lines = Toml_line_editor.join_lines
let strip_toml_comment = Toml_line_editor.strip_comment
let is_toml_table_header = Toml_line_editor.is_table_header

let is_runtime_assignments_header line =
  String.equal (line |> strip_toml_comment |> String.trim) "[runtime.assignments]"
;;

let is_runtime_header line =
  String.equal (line |> strip_toml_comment |> String.trim) "[runtime]"
;;

let split_at = Toml_line_editor.split_at
let find_index = Toml_line_editor.find_index
let assignment_key_of_line = Toml_line_editor.key_of_line

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
           * string option
           * string list
           * Runtime_lane.t list) =
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

let set_runtime_hitl_summary ?runtime_config_path ~runtime_id () =
  set_runtime_scalar ?runtime_config_path ~key:"hitl_summary" ~runtime_id ()
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
