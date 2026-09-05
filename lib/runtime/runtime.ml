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
  ; execution : Runtime_execution.t
    (** Turn owner materialized at load time. HTTP bindings become
        [Agent_core]; official client runtimes remain distinct and can never
        be dispatched as a fake LLM provider config. *)
  ; quota_scope : Runtime_quota_window.scope
    (** Quota ownership key frozen at materialization, from the same
        credential-alias selection that resolved the dispatched API key
        (PR #28219 review). *)
  }

type dispatch_credential_error =
  | Required_env_credential_missing of
      { provider_id : string
      ; env_key : string
      }
  | Declared_credential_unavailable of
      { provider_id : string
      ; carrier : Agent_core.Error.credential_carrier
      }

let dispatch_credential_error_to_string = function
  | Required_env_credential_missing { provider_id; env_key } ->
    Printf.sprintf
      "provider %S requires non-empty credential env %S"
      provider_id
      env_key
  | Declared_credential_unavailable { provider_id; carrier } ->
    Printf.sprintf
      "provider %S declares an unavailable %s credential"
      provider_id
      (match carrier with
       | Agent_core.Error.InlineCredential -> "inline"
       | Agent_core.Error.FileCredential -> "file")
;;

let dispatch_credential_error_to_core_error = function
  | Required_env_credential_missing { env_key; _ } ->
    Agent_core.Error.Config (Agent_core.Error.MissingEnvVar { var_name = env_key })
  | Declared_credential_unavailable { provider_id; carrier } ->
    Agent_core.Error.Config
      (Agent_core.Error.CredentialUnavailable { provider_id; carrier })
;;

let validate_dispatch_credential
    ~(provider_config : Llm_provider.Provider_config.t)
    (runtime : t)
  =
  match runtime.execution with
  | Runtime_execution.Codex_app_server _
  | Runtime_execution.Claude_code _
  | Runtime_execution.Antigravity_cli _ ->
    Ok ()
  | Runtime_execution.Agent_core _ ->
    let credential =
      Runtime_adapter.effective_credential_reference
        ~provider_id:runtime.provider.id
        runtime.provider.credentials
    in
    if not (Llm_provider.Secret.is_empty provider_config.api_key)
    then Ok ()
    else
      match credential with
      | None -> Ok ()
      | Some (Env env_key) ->
        Error
          (Required_env_credential_missing
             { provider_id = runtime.provider.id; env_key })
      | Some (Inline _) ->
        Error
          (Declared_credential_unavailable
             { provider_id = runtime.provider.id
             ; carrier = Agent_core.Error.InlineCredential
             })
      | Some (File _) ->
        Error
          (Declared_credential_unavailable
             { provider_id = runtime.provider.id
             ; carrier = Agent_core.Error.FileCredential
             })
;;

type config_source_revision = Config_source_revision of string
type config_commit_order = Config_commit_order of int64

type config_observation =
  { path : string
  ; source_text : string
  ; source_revision : config_source_revision
  }

type config_durability =
  | Durable
  | Durability_unconfirmed of { detail : string }

type config_commit_receipt =
  { observation : config_observation
  ; durability : config_durability
  ; order : config_commit_order
  ; lock_warnings : config_lock_warning list
  }

and config_lock_warning =
  | Config_lock_release_unconfirmed of string

type keeper_assignment_state =
  | Assignment_missing
  | Assignment_present of string

type keeper_assignment_revision =
  | Runtime_config_missing
  | Runtime_config_present of
      { source_revision : config_source_revision
      ; assignment : keeper_assignment_state
      }

type keeper_assignment_cas_error =
  | Assignment_revision_conflict of keeper_assignment_revision
  | Assignment_io_error of string

type keeper_assignment_write =
  | Assignment_unchanged of keeper_assignment_revision
  | Assignment_committed of
      { receipt : config_commit_receipt
      ; revision : keeper_assignment_revision
      }

type keeper_assignment_transaction =
  | Missing_runtime_config of { keeper_name : string }
  | Present_runtime_config of
      { path : string
      ; source_text : string
      ; keeper_name : string
      ; revision : keeper_assignment_revision
      }

type 'a config_lock_receipt =
  { value : 'a
  ; warnings : config_lock_warning list
  }

let config_source_revision_to_string (Config_source_revision revision) = revision
let config_commit_order_to_string (Config_commit_order order) = Int64.to_string order
let compare_config_commit_order (Config_commit_order left) (Config_commit_order right) =
  Int64.compare left right
;;

let config_lock_warning_to_yojson = function
  | Config_lock_release_unconfirmed detail ->
    `Assoc
      [ "code", `String "runtime_config_lock_release_unconfirmed"
      ; "detail", `String detail
      ]
;;

let keeper_assignment_state_to_yojson = function
  | Assignment_missing -> `Assoc [ "state", `String "missing" ]
  | Assignment_present runtime_id ->
    `Assoc [ "state", `String "assigned"; "runtime_id", `String runtime_id ]
;;

let keeper_assignment_revision_to_yojson revision =
  match revision with
  | Runtime_config_missing -> `Assoc [ "state", `String "runtime_config_missing" ]
  | Runtime_config_present { source_revision; assignment } ->
    `Assoc
      [ "state", `String "runtime_config_present"
      ; "source_revision", `String (config_source_revision_to_string source_revision)
      ; "assignment", keeper_assignment_state_to_yojson assignment
      ]
;;

let keeper_assignment_revision_of_yojson = function
  | `Assoc [ ("state", `String "runtime_config_missing") ] ->
    Ok Runtime_config_missing
  | `Assoc fields ->
    let source_revision =
      match List.assoc_opt "source_revision" fields with
      | Some (`String value) when String_util.is_lowercase_sha256_hex value ->
        Ok (Config_source_revision value)
      | Some _ -> Error "runtime assignment source_revision must be lowercase SHA-256 hex"
      | None -> Error "runtime assignment source_revision is required"
    in
    let assignment =
      match List.assoc_opt "assignment" fields with
      | Some (`Assoc assignment_fields) ->
        (match List.assoc_opt "state" assignment_fields with
         | Some (`String "missing") when List.length assignment_fields = 1 ->
           Ok Assignment_missing
         | Some (`String "assigned") ->
           (match assignment_fields with
            | [ ("state", `String "assigned"); ("runtime_id", `String runtime_id) ]
            | [ ("runtime_id", `String runtime_id); ("state", `String "assigned") ]
              when String.trim runtime_id <> "" ->
              Ok (Assignment_present runtime_id)
            | _ -> Error "assigned runtime revision requires only runtime_id")
         | Some (`String state) ->
           Error (Printf.sprintf "unsupported runtime assignment state: %S" state)
         | Some _ -> Error "runtime assignment state must be a string"
         | None -> Error "runtime assignment state is required")
      | Some _ -> Error "runtime assignment revision must be an object"
      | None -> Error "runtime assignment revision is required"
    in
    let* source_revision = source_revision in
    let* assignment = assignment in
    if List.assoc_opt "state" fields <> Some (`String "runtime_config_present")
    then Error "runtime assignment revision state must be runtime_config_present"
    else if List.length fields <> 3
    then Error "runtime assignment revision has unexpected fields"
    else Ok (Runtime_config_present { source_revision; assignment })
  | _ -> Error "runtime assignment revision must be an object"
;;

let config_observation ~path source_text =
  let digest =
    Digestif.SHA256.(to_hex (digest_string ("runtime_config_source\x00" ^ source_text)))
  in
  { path; source_text; source_revision = Config_source_revision digest }
;;

(* id 파생의 단일 출처는 {!Runtime_schema.binding_key} — runtime 을 id 로
   인덱싱하는 모든 호출자와 동일한 ["provider.model"] 규칙을 공유한다. *)
let id_of_binding (b : binding) : string = binding_key b

(** binding 을 Runtime 으로 변환하되 실패 이유를 보존한다. provider/model
    resolve 또는 provider_config materialize 가 실패하면 [Error reason] —
    동작은 fail-closed 그대로(partial-boot 없음, 해당 binding 은 Runtime 목록에서
    제외)이되 왜 제외되는지 이유를 잃지 않는다. 이 이유는 assignment / default /
    task-route / lane 검증이 "not found" 대신 근본 원인을 표면화하는 데 쓰인다
    (Unknown→silent-drop 안티패턴 차단). *)
(* Quota scope is frozen here, at materialization, from the same
   credential-alias selection that resolves the dispatched API key. Deriving
   it later would re-run alias selection against a possibly changed process
   environment and charge the window to an account the dispatch never used
   (PR #28219 review). *)
let quota_scope_of_materialized
    ~(provider : provider)
    ~(execution : Runtime_execution.t) =
  let credential =
    match execution with
    | Runtime_execution.Agent_core _ ->
      Runtime_adapter.effective_credential_reference
        ~provider_id:provider.id
        provider.credentials
    | Runtime_execution.Antigravity_cli _ -> provider.credentials
    | Runtime_execution.Codex_app_server _
    | Runtime_execution.Claude_code _ ->
      (* Official clients own subscription login. A registry API-key default
         with the same provider label is a different account authority. *)
      None
  in
  Runtime_quota_window.scope_of_credential ~provider_id:provider.id credential
;;

(* Why a binding did not become a runtime, as a closed vocabulary rather than a
   string. The distinction the variant makes is the one the config loader has to
   act on: [Binding_disabled] and [Provider_disabled] are choices the operator
   wrote down, [Execution_unbuildable] is a capability limit of the adapter, and
   the two [*_not_declared] cases are dangling references — the binding names a
   [\[providers.x\]] or [\[models.y\]] row that does not exist. Collapsing all
   five into one string is what let a dangling reference be dropped as quietly as
   a deliberate disable (masc#28403): a [local_llama_server.qwen3-6-35b-uncensored]
   binding pointed at a model row an unquoted dot had split into
   [models.qwen3."6-35b-uncensored"], and nothing reported the runtime's absence.
   Deciding fatality by matching the reason string would be the same defect one
   layer up, so the vocabulary is closed and {!load_list} matches it. *)
type drop_reason =
  | Binding_disabled
  | Provider_disabled of string (* provider id *)
  | Provider_not_declared of string (* provider id the binding names *)
  | Model_not_declared of string (* model id the binding names *)
  | Execution_unbuildable of string (* adapter's own reason *)

let string_of_drop_reason = function
  | Binding_disabled -> "binding is disabled by runtime.toml"
  | Provider_disabled id -> Printf.sprintf "provider %S is disabled by runtime.toml" id
  | Provider_not_declared id -> Printf.sprintf "provider not found: %s" id
  | Model_not_declared id -> Printf.sprintf "model not found: %s" id
  | Execution_unbuildable reason -> reason
;;

let of_binding (cfg : config) (b : binding) : (t, drop_reason) result =
  if not b.enabled
  then Error Binding_disabled
  else match provider_of_id cfg b.provider_id, model_of_id cfg b.model_id with
  | Some provider, Some model ->
    if not provider.enabled
    then Error (Provider_disabled provider.id)
    else
      (match Runtime_adapter.binding_to_execution cfg b with
       | Ok execution ->
         Ok
           { id = id_of_binding b
           ; provider
           ; model
           ; binding = b
           ; execution
           ; quota_scope = quota_scope_of_materialized ~provider ~execution
           }
       | Error reason -> Error (Execution_unbuildable reason))
  | None, _ -> Error (Provider_not_declared b.provider_id)
  | Some _, None -> Error (Model_not_declared b.model_id)
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
   default / task-route / lane validation surface *why* a target binding is
   absent from the runtime list (e.g. "provider ... uses protocol messages-http,
   which the runtime adapter cannot build a provider_config for ...") instead of
   the misleading "not found among N runtimes", which points the operator at a
   typo that does not exist. Materialize failure stays fail-closed: the binding
   is still excluded from [runtimes] (RFC-0206 §2.1). *)
let partition_bindings (cfg : config) (bindings : binding list)
  : t list * (string * drop_reason) list
  =
  let runtimes, dropped =
    List.fold_left
      (fun (runtimes, dropped) (b : binding) ->
         match of_binding cfg b with
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
let unresolved_runtime_suffix ~(dropped_bindings : (string * drop_reason) list)
    ~(runtime_count : int) (id : string) : string =
  match List.assoc_opt id dropped_bindings with
  | Some reason ->
    Printf.sprintf
      ": binding is defined but could not be materialized as a runtime — %s"
      (string_of_drop_reason reason)
  | None -> Printf.sprintf " not found among %d runtimes" runtime_count
;;

(* A dangling reference is an operator typo, and unlike every other drop reason
   it is not survivable by ignoring the binding: the runtime the operator
   declared simply does not exist, and nothing downstream will say so unless the
   id happens to be referenced by an assignment, route, or lane. Reporting it
   here — at load, over the whole binding list — is what makes the absence
   visible without a reference to hang the message on (masc#28403). The other
   three reasons stay non-fatal: they keep the RFC-0206 §2.1 contract that a
   binding MASC cannot run is excluded rather than fatal. *)
let dangling_reference_reason = function
  | Provider_not_declared id ->
    Some (Printf.sprintf "names provider %S, which has no [providers.%s] row" id id)
  | Model_not_declared id ->
    Some (Printf.sprintf "names model %S, which has no [models.%s] row" id id)
  | Binding_disabled | Provider_disabled _ | Execution_unbuildable _ -> None
;;

let validate_no_dangling_bindings ~(config_path : string)
    ~(dropped_bindings : (string * drop_reason) list) : (unit, string) result =
  match
    List.filter_map
      (fun (id, reason) ->
        Option.map
          (fun why -> Printf.sprintf "  %s %s" id why)
          (dangling_reference_reason reason))
      dropped_bindings
  with
  | [] -> Ok ()
  | dangling ->
    Error
      (Printf.sprintf
         "%s: %d binding(s) reference a provider or model that is not declared, \
          so the runtime they define does not exist:\n%s"
         config_path
         (List.length dangling)
         (String.concat "\n" dangling))
;;

(** TOML 에서 Runtime 목록과 default Runtime 을 로드한다.

    fail-fast: [\[runtime\] default] 가 없거나 그 id 가 목록에 없으면 [Error].
    silent fallback 일절 없음 (runtime→Runtime 비전: TOML 에 default 없으면
    프로그램 실행 불가). *)
(* Route ids resolve with lane precedence ([resolve_assignment] prefers a lane
   over a same-named runtime), so route validation must judge the same target
   the consumer will actually get: lane first, runtime second. *)
let find_declared_lane (lanes : Runtime_lane.t list) (id : string) =
  List.find_opt (fun lane -> String.equal (Runtime_lane.id lane) id) lanes
;;

(* Each [runtime] reference is validated under its field's admission contract:
   - [Runtime_only] requires a declared runtime id for keeper assignments and
     media_failover entries. Assignment execution may still resolve a
     same-named lane first.
   - [Lane_then_runtime] admits a declared lane or runtime id for route ids.
   Unknown ids are rejected while loading the configuration. *)
type reference_domain =
  | Runtime_only
  | Lane_then_runtime

(* A list entry renders as "field entry \"id\"" and a scalar as "field = \"id\"".
   Keeping both is not cosmetic: [runtime].media_failover = "x" would tell the
   operator a list field equals one id. The variance is in rendering the site,
   never in deciding it. *)
type reference_shape =
  | Scalar
  | List_entry

type runtime_reference =
  { site : string (* the config path as the operator wrote it *)
  ; shape : reference_shape
  ; id : string
  ; domain : reference_domain
  }

let validate_runtime_references ~(config_path : string)
    ~(dropped_bindings : (string * drop_reason) list) (runtimes : t list)
    (lanes : Runtime_lane.t list) (references : runtime_reference list)
  : (unit, string) result
  =
  let resolves_as_runtime id =
    List.exists (fun (r : t) -> String.equal r.id id) runtimes
  in
  let resolves (reference : runtime_reference) =
    match reference.domain with
    | Runtime_only -> resolves_as_runtime reference.id
    | Lane_then_runtime ->
      (* [validate_lanes] already guaranteed every candidate id of a declared
         lane resolves, so naming the lane is enough. *)
      Option.is_some (find_declared_lane lanes reference.id)
      || resolves_as_runtime reference.id
  in
  match List.find_opt (fun reference -> not (resolves reference)) references with
  | None -> Ok ()
  | Some { site; shape; id; domain = _ } ->
    let named =
      match shape with
      | Scalar -> Printf.sprintf "%s = %S" site id
      | List_entry -> Printf.sprintf "%s entry %S" site id
    in
    Error
      (Printf.sprintf
         "%s: %s%s"
         config_path
         named
         (unresolved_runtime_suffix ~dropped_bindings
            ~runtime_count:(List.length runtimes) id))
;;

(* Reference constructors keep each site string next to the field it names, so a
   renamed config key cannot drift away from its diagnostic. *)
let assignment_references (assignments : (string * string) list) =
  List.map
    (fun (keeper_name, runtime_id) ->
      { site = Printf.sprintf "[runtime.assignments].%s" keeper_name
      ; shape = Scalar
      ; id = runtime_id
      ; domain = Runtime_only
      })
    assignments
;;

let media_failover_references (media_failover : string list) =
  List.map
    (fun id ->
      { site = "[runtime].media_failover"
      ; shape = List_entry
      ; id
      ; domain = Runtime_only
      })
    media_failover
;;

(* [runtime.lanes.<id>] candidate ids must resolve to configured runtimes.
   Empty candidate lists are rejected at parse time; here we reject unknown ids
   as operator typos (mirrors [runtime].default validation). *)
let validate_lanes ~(config_path : string)
    ~(dropped_bindings : (string * drop_reason) list) (runtimes : t list)
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

(* [runtime].default is required, so every lane can end somewhere. Without this
   a lane walk stops at its last declared candidate and the turn dies there —
   failover would exist only where an operator remembered to type a second
   candidate. Appended rather than substituted: declared order is the
   operator's, this only says where the walk terminates. *)
let with_terminal_default ~default_runtime_id candidates =
  if List.exists (String.equal default_runtime_id) candidates
  then candidates
  else candidates @ [ default_runtime_id ]
;;

let lanes_of_decls ~(config_path : string)
    ~(dropped_bindings : (string * drop_reason) list) ~(default_runtime_id : string)
    (runtimes : t list)
    (lane_decls : Runtime_schema.lane_decl list)
  : (Runtime_lane.t list, string) result
  =
  let* () = validate_lanes ~config_path ~dropped_bindings runtimes lane_decls in
  Ok
    (List.map
       (fun ({ Runtime_schema.id; candidate_ids } : Runtime_schema.lane_decl) ->
          Runtime_lane.make ~id (with_terminal_default ~default_runtime_id candidate_ids))
       lane_decls)
;;

(* Pure decision for the capability gate, separated from the global AGENT_CORE catalog
   lookup so it is unit-testable. [entries] is [(label, known_to_agent_core)] per runtime.

   An unknown model resolves to AGENT_CORE [provider_default], whose guessed capabilities
   (notably [thinking_control_format = No_thinking_control]) silently drop
   thinking/sampling control a binding may require. Reject such a binding at
   load instead of discovering corruption at runtime
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
         "%s: %d runtime model(s) absent from the AGENT_CORE capability catalog; they \
          would use provider_default and silently drop thinking/sampling control. \
          Add deployment rows to agent-core-models-overlay.toml or update the AGENT_CORE embedded catalog: %s"
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
    "%s: %d runtime model(s) absent from the AGENT_CORE capability catalog; they \
     would use provider_default and silently drop thinking/sampling control. \
     Add deployment rows to agent-core-models-overlay.toml or update the AGENT_CORE embedded catalog: %s"
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
      ; "terminal_reason", `String "missing_agent_core_catalog_models"
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
            "Add deployment rows to agent-core-models-overlay.toml (or upstream AGENT_CORE) or remove \
             those runtime.toml bindings; uncatalogued runtimes are disabled \
             for this process." )
      ]
;;

let capabilities_for_runtime (rt : t) =
  match rt.execution with
  | Runtime_execution.Agent_core provider_config ->
    Llm_provider.Provider_config.capabilities_for_config_model provider_config
  | Runtime_execution.Codex_app_server _
  | Runtime_execution.Claude_code _
  | Runtime_execution.Antigravity_cli _ -> None
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
   AGENT_CORE capability catalog declares a positive context window for this
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
   runtime.toml override or the AGENT_CORE capability catalog. A binding that leaves
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
          and no AGENT_CORE capability catalog max-context; set the override or add \
          the model to the capability catalog (no silent default — \
          RFC-0206 §2.1)"
         config_path
         r.id
         (match Runtime_execution.model_id r.execution with
          | Some model_id -> model_id
          | None -> "<official-client-selected>")
         r.model.id)
;;

type request_body_cap_error = Missing_or_non_positive_request_body_cap of
  { runtime_id : string
  }

let request_body_cap_error_to_string = function
  | Missing_or_non_positive_request_body_cap { runtime_id } ->
    Printf.sprintf
      "Keeper runtime %S has no positive serialized-request ceiling"
      runtime_id
;;

(* The capability is checked at configuration admission and again immediately
   before each concrete provider call. The latter is required because feature
   owners may transform a materialized provider config after runtime.toml has
   been accepted. *)
let validate_request_body_cap ~runtime_id
    (provider_config : Llm_provider.Provider_config.t) =
  match provider_config.max_request_body_bytes with
  | Some cap when cap > 0 -> Ok cap
  | None | Some _ ->
    Error (Missing_or_non_positive_request_body_cap { runtime_id })
;;

(* Whether a materialized runtime could carry a keeper turn if one were routed
   to it, independent of whether anything routes to it today.

   Boot validation deliberately checks only reachable ids — refusing to start
   over a runtime nobody is assigned to would be wrong — but that left the
   blocked state with no observer at all: a runtime declared in runtime.toml,
   materialized, listed by /api/v1/runtime/resolved, and impossible to assign,
   with nothing anywhere saying why. Seven live runtimes were in that state on
   2026-08-12 and finding them required a separate script that re-parsed the
   TOML (masc#28404). The readiness is the same predicate boot validation uses,
   named once so the operator-facing projection and the fail-closed gate cannot
   disagree. *)
type keeper_dispatch_readiness =
  | Dispatchable
  | Missing_request_body_cap of { table_path : string }

(* TEL-OK: pure predicate over an already-materialized runtime; the boot logger
   and the resolved projection own its observability. *)
let keeper_dispatch_readiness (runtime : t) : keeper_dispatch_readiness =
  (* Only Agent_core is judged, because only Agent_core builds the request whose
     size this bounds. An official-client turn hands its conversation to a
     spawned vendor client that owns its own context window and refuses an
     oversized one in a typed terminal. *)
  match runtime.execution with
  | Runtime_execution.Agent_core provider_config ->
    (match validate_request_body_cap ~runtime_id:runtime.id provider_config with
     | Ok _ -> Dispatchable
     | Error _ ->
       Missing_request_body_cap
         { table_path =
             Otoml.string_of_path
               [ runtime.binding.provider_id; runtime.binding.model_id ]
         })
  | Runtime_execution.Codex_app_server _
  | Runtime_execution.Claude_code _
  | Runtime_execution.Antigravity_cli _ -> Dispatchable
;;

(* TEL-OK: pure rendering of the variant above; callers decide where it lands. *)
let keeper_dispatch_blocker = function
  | Dispatchable -> None
  | Missing_request_body_cap { table_path } ->
    Some
      (Printf.sprintf
         "no positive max-request-body-bytes; declare [%s].max-request-body-bytes"
         table_path)
;;

(* Every materialized runtime a keeper could not be assigned to, in declaration
   order, paired with the reason. Empty is the healthy state.
   TEL-OK: pure filter; the boot path logs one line per entry it returns. *)
let keeper_dispatch_blocked (runtimes : t list) : (t * string) list =
  List.filter_map
    (fun runtime ->
      Option.map
        (fun reason -> runtime, reason)
        (keeper_dispatch_blocker (keeper_dispatch_readiness runtime)))
    runtimes
;;

(* [runtime.exact_output_lanes.verifier_exact] (RFC-0361 D7(a)) is the single
   selector for completion-authority judgement calls: admitted slots in frozen
   declaration order, fail over in that order. *)
let verifier_exact_lane_id = "verifier_exact"

let verifier_exact_slot_ids_of_lane_decls
      (decls : Runtime_schema.exact_output_lane_decl list)
  =
  match
    List.find_opt
      (fun (lane : Runtime_schema.exact_output_lane_decl) ->
         String.equal lane.id verifier_exact_lane_id)
      decls
  with
  | None -> []
  | Some lane -> lane.slot_ids
;;

(* [verifier_exact] is the one exact-output lane whose slot ids are read
   twice. The exact registry admits them against the AGENT_CORE catalog, and
   completion-authority judgement dispatches them through
   [resolve_assignment], which knows only configured runtimes and lanes. An id
   that satisfies the catalog but names no configured route is admitted at
   boot and then fails at every judgement: on 2026-09-02 a degraded first slot
   sent judgements to such an id 113 times, one failure each, and the trace
   was a Board post per attempt rather than a config that refused to load.

   The sibling lanes are deliberately not checked here. They dispatch through
   the registry alone, so a catalog-only target id is right for them, and
   [hitl_auto_judge] holds one today. *)
let verifier_exact_slot_references
      (decls : Runtime_schema.exact_output_lane_decl list)
  =
  List.map
    (fun id ->
       { site =
           Printf.sprintf
             "[runtime.exact_output_lanes.%s].slots"
             verifier_exact_lane_id
       ; shape = List_entry
       ; id
       ; domain = Lane_then_runtime
       })
    (verifier_exact_slot_ids_of_lane_decls decls)
;;

(* Keeper provider attempts originate at the configured default, an explicit
   keeper assignment, an explicit media-failover runtime, the verifier_exact
   exact-output lane's slots, or cross verifier. A lane is
   reachable only when its id shadows one of the configured routes; a merely
   declared lane is dormant until a routed root names it.
   Expand each lane-capable route with the same lane-over-runtime precedence as
   [resolve_assignment], keep media_failover runtime-only, then preserve first
   occurrence order. Every attempt is checked again after its final provider
   config transform in Keeper_turn_driver. No provider/model names live in
   this policy. *)
(* TEL-OK: pure reachability projection; callers own config-load diagnostics. *)
let keeper_dispatch_runtime_ids
    ~(default_runtime_id : string)
    ~(assignments : (string * string) list)
    ~(verifier_exact_slot_ids : string list)
    ~(media_failover : string list)
    ~(lanes : Runtime_lane.t list)
  =
  let expand id =
    match find_declared_lane lanes id with
    | Some lane -> Runtime_lane.ordered_candidates lane
    | None -> [ id ]
  in
  let routed_roots =
    default_runtime_id :: List.map snd assignments
    |> List.concat_map expand
  in
  let rec dedupe seen acc = function
    | [] -> List.rev acc
    | id :: rest when List.mem id seen -> dedupe seen acc rest
    | id :: rest -> dedupe (id :: seen) (id :: acc) rest
  in
  (* These special routes reach providers outside the ordinary keeper default
     and assignment dispatch, so startup must admit every configured lane
     candidate's request cap here as well. *)
  dedupe
    []
    []
    ( routed_roots
      @ media_failover
      @ List.concat_map expand verifier_exact_slot_ids )
;;

(* TEL-OK: pure fail-closed validation; the load boundary surfaces its error. *)
let validate_keeper_dispatch_request_caps
    ~(config_path : string)
    ~(verifier_exact_slot_ids : string list)
    ( runtimes
    , (default_runtime : t)
    , assignments
    , media_failover
    , lanes )
  =
  let ids =
    keeper_dispatch_runtime_ids
      ~default_runtime_id:default_runtime.id
      ~assignments
      ~verifier_exact_slot_ids
      ~media_failover
      ~lanes
  in
  let runtime_by_id id =
    List.find_opt (fun (runtime : t) -> String.equal runtime.id id) runtimes
  in
  (* Same predicate {!keeper_dispatch_readiness} reports to operators. Only
     reachable ids are judged here — a declared-but-unassigned runtime must not
     refuse boot — but the two must never disagree about what "blocked" means,
     which is why the decision has one definition and this is a projection of
     it. The official-client arms are Dispatchable there: requiring a declared
     max-prompt-bytes for them added a second authority over the same window,
     measured in wire bytes rather than tokens, and made its absence a boot
     refusal, so a deployment could not choose to let the provider decide. *)
  let missing_ceiling runtime =
    match keeper_dispatch_readiness runtime with
    | Dispatchable -> None
    | Missing_request_body_cap { table_path } -> Some (runtime, table_path)
  in
  match List.find_map (fun id -> Option.bind (runtime_by_id id) missing_ceiling) ids with
  | None -> Ok ()
  | Some (runtime, table_path) ->
    Error
      (Printf.sprintf
         "%s: Keeper-dispatch runtime %S has no positive \
          max-request-body-bytes; declare [%s].max-request-body-bytes before \
          dispatch so the exact serialized request has an explicit admission \
          ceiling"
         config_path
         runtime.id
         table_path)
;;

(* Every runtime binding's provider/model pair must be known to the AGENT_CORE
   capability catalog. Use the materialized [Provider_config.t] so
   provider-qualified catalog rows are considered before bare model rows; this
   keeps overlapping ids such as native Kimi vs Ollama Cloud Kimi from requiring
   bare-id manifest workarounds. *)
let missing_runtime_model_capabilities ~(config_path : string) (runtimes : t list)
  : missing_catalog_report option
  =
  let missing_models =
    List.filter_map
      (fun (r : t) ->
         match r.execution, capabilities_for_runtime r with
         | ( Runtime_execution.Codex_app_server _
           | Runtime_execution.Claude_code _
           | Runtime_execution.Antigravity_cli _ ), _ -> None
         | Runtime_execution.Agent_core _, Some _ -> None
         | Runtime_execution.Agent_core provider_config, None ->
           let provider_label =
             Llm_provider.Provider_config.capability_provider_label provider_config
           in
           let model_id = provider_config.model_id in
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
        "Configured %s=%S is absent from the AGENT_CORE capability catalog; degraded \
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
     agent-core-models-overlay.toml (or upstream AGENT_CORE) or remove those routing references; MASC will not erase \
     explicit runtime intent into [runtime].default fallback."
    config_path
    (String.concat "; " references)
    default_fallback_explanation
;;

let degrade_loaded_for_missing_catalog
    ( (runtimes, configured_default, assignments,
       media_failover, lanes) :
      t list
      * t
      * (string * string) list
      * string list
      * Runtime_lane.t list )
    (report : missing_catalog_report)
  : ( ( t list
        * t
        * (string * string) list
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
               kept_candidates
             :: kept
           , dropped_candidates
           , dropped_lanes ))
      lanes
      ([], [], [])
  in
  let dropped_routes =
    [ default_drop ]
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
         "%s: all configured runtime models are absent from the AGENT_CORE capability \
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
        , kept_media_failover
        , kept_lanes )
      , degradation )
;;

let materialize_config
    ?(validate_max_context = true)
    ~(config_path : string)
    (cfg : config)
  : ( (t list
       * t
       * (string * string) list
       * string list
       * Runtime_lane.t list)
      * Runtime_schema.exact_output_lane_decl list
    , string )
    result
  =
  let runtimes, dropped_bindings = partition_bindings cfg cfg.bindings in
  (* Ahead of default / assignment / route validation on purpose: a dangling
     binding makes a runtime the operator declared not exist, and the messages
     below can only describe an id something else referenced. *)
  let* () = validate_no_dangling_bindings ~config_path ~dropped_bindings in
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
  (* Assignments are checked before lanes are materialized, which keeps the order
     in which a typo'd assignment surfaces ahead of a typo'd lane candidate.
     [Runtime_only] never consults the lane list, so the empty list here is not a
     stand-in for lanes that do not exist yet — it states that no lane is
     admissible at this site, which is the assignment contract runtime.mli
     documents and Keeper_turn_driver's lane-aware dispatch relies on. *)
  let* () =
    validate_runtime_references ~config_path ~dropped_bindings runtimes []
      (assignment_references assignments)
  in
  (* Lanes are materialized before every route validation so any route id can
     name a lane (#25394); candidate resolution is enforced by [validate_lanes]
     inside [lanes_of_decls]. *)
  let* lanes =
    lanes_of_decls ~config_path ~dropped_bindings ~default_runtime_id:rt.id runtimes
      cfg.lane_decls
  in
  let* () =
    validate_runtime_references ~config_path ~dropped_bindings runtimes lanes
      (media_failover_references cfg.media_failover)
  in
  let* () =
    validate_runtime_references ~config_path ~dropped_bindings runtimes lanes
      (verifier_exact_slot_references cfg.exact_output_lane_decls)
  in
  let* () =
    if validate_max_context
    then validate_runtime_max_context ~config_path runtimes
    else Ok ()
  in
  (* The AGENT_CORE catalog membership gate is intentionally not called here:
     [load_list] stays a routing-validity parser for tests and config probes.
     Startup callers choose fail-closed [init_default_strict] or server-visible
     degraded boot [init_default_degraded_report]. *)
  let loaded =
    ( runtimes
    , rt
    , assignments
    , cfg.media_failover
    , lanes )
  in
  Ok (loaded, cfg.exact_output_lane_decls)
;;

let load_list_internal ~(config_path : string) ~validate_max_context
  : ( (t list
       * t
       * (string * string) list
       * string list
       * Runtime_lane.t list)
      * Runtime_schema.exact_output_lane_decl list
    , string )
    result
  =
  let* cfg =
    Runtime_toml.parse_file config_path
    |> Result.map_error (fun errs ->
      let detail =
        errs
        |> List.map (fun (e : Runtime_toml.parse_error) ->
          Printf.sprintf "  - %s: %s" e.path e.message)
        |> String.concat "\n"
      in
      Printf.sprintf
        "runtime config parse failed (%s): %d error(s):\n%s"
        config_path
        (List.length errs)
        detail)
  in
  materialize_config ~validate_max_context ~config_path cfg
;;

let load_list_internal_text ~(config_path : string) ~content ~validate_max_context =
  let* cfg =
    Runtime_toml.parse_string content
    |> Result.map_error (fun errs ->
      let detail =
        errs
        |> List.map (fun (e : Runtime_toml.parse_error) ->
          Printf.sprintf "  - %s: %s" e.path e.message)
        |> String.concat "\n"
      in
      Printf.sprintf
        "runtime config parse failed (%s): %d error(s):\n%s"
        config_path
        (List.length errs)
        detail)
  in
  materialize_config ~validate_max_context ~config_path cfg
;;

let load_list ~config_path =
  load_list_internal ~config_path ~validate_max_context:true
  |> Result.map fst
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
  ; media_failover : string list
  ; lanes : Runtime_lane.t list
  ; config_path : string option
  ; startup_degradation : startup_degradation option
  }

let empty_loaded_state =
  { default_runtime = None
  ; runtimes = []
  ; keeper_assignments = []
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
    , media_failover
    , lanes ) =
  Atomic.set loaded_state_ref
    { default_runtime = Some rt
    ; runtimes
    ; keeper_assignments = assignments
    ; media_failover
    ; lanes
    ; config_path = Some config_path
    ; startup_degradation
    }

let init_default ~config_path =
  let* loaded, _exact_output_lane_decls =
    load_list_internal ~config_path ~validate_max_context:true
  in
  set_loaded ~config_path loaded;
  Ok ()

let publish_exact_output_registry ?required_lane_ids ~lanes resolver_snapshot =
  match
    Runtime_exact_output_registry.publish
      ?required_lane_ids
      ~lanes
      resolver_snapshot
  with
  | Ok registry -> Ok registry
  | Error error ->
    Error (Runtime_exact_output_registry.publication_error_to_string error)
;;

(* Fail-closed startup entry point: [load_list] (RFC-0206 routing validation)
   PLUS the AGENT_CORE capability-catalog gate. Strict callers use this so an operator
   runtime.toml whose model is absent from the catalog is rejected before boot —
   the gate that load_list intentionally no longer applies, kept out of load_list
   so unit tests stay catalog-independent. *)
let init_default_strict_report ~config_path =
  match load_list_internal ~config_path ~validate_max_context:true with
  | Error msg -> Error (Runtime_config_error msg)
  | Ok (((runtimes, _, _, _, _) as loaded), exact_output_lane_decls) ->
    (match missing_runtime_model_capabilities ~config_path runtimes with
     | Some report -> Error (Missing_catalog_models report)
     | None ->
       (match
          validate_keeper_dispatch_request_caps
            ~config_path
            ~verifier_exact_slot_ids:
              (verifier_exact_slot_ids_of_lane_decls exact_output_lane_decls)
            loaded
        with
        | Error msg -> Error (Runtime_config_error msg)
        | Ok () ->
          set_loaded ~config_path loaded;
          Ok ()))

let init_default_strict ~config_path =
  init_default_strict_report ~config_path
  |> Result.map_error strict_init_error_to_string

let initialize_degraded_loaded ~config_path = function
  | Error msg -> Error (Runtime_config_error msg)
  | Ok (((runtimes, _, _, _, _) as loaded), exact_output_lane_decls) ->
    let verifier_exact_slot_ids =
      verifier_exact_slot_ids_of_lane_decls exact_output_lane_decls
    in
    (match missing_runtime_model_capabilities ~config_path runtimes with
     | None ->
       (match validate_runtime_max_context ~config_path runtimes with
        | Error msg -> Error (Runtime_config_error msg)
        | Ok () ->
          (match
             validate_keeper_dispatch_request_caps
               ~config_path
               ~verifier_exact_slot_ids
               loaded
           with
           | Error msg -> Error (Runtime_config_error msg)
           | Ok () ->
             set_loaded ~config_path loaded;
             Ok Initialized))
     | Some report ->
       (match degrade_loaded_for_missing_catalog loaded report with
        | Error msg -> Error (Runtime_config_error msg)
        | Ok
            (((active_runtimes, _, _, _, _) as degraded_loaded), degradation)
          ->
          (match validate_runtime_max_context ~config_path active_runtimes with
           | Error msg -> Error (Runtime_config_error msg)
           | Ok () ->
             (match
                validate_keeper_dispatch_request_caps
                  ~config_path
                  ~verifier_exact_slot_ids
                  degraded_loaded
              with
              | Error msg -> Error (Runtime_config_error msg)
              | Ok () ->
                set_loaded
                  ~startup_degradation:degradation
                  ~config_path
                  degraded_loaded;
                Ok (Initialized_degraded degradation)))))

let init_default_degraded_report ~config_path =
  load_list_internal ~config_path ~validate_max_context:false
  |> initialize_degraded_loaded ~config_path
;;

let init_default_degraded_observation (observation : config_observation) =
  load_list_internal_text
    ~config_path:observation.path
    ~content:observation.source_text
    ~validate_max_context:false
  |> initialize_degraded_loaded ~config_path:observation.path
;;

let runtime_state () = Atomic.get loaded_state_ref

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

(* Keeper-to-runtime assignment is sourced from [[runtime.assignments]] in
   runtime.toml, not from keeper TOML. [None] = no explicit assignment; the caller falls back to
   {!get_default_runtime_id}. The returned id is opaque (masc never parses it;
   only the AGENT_CORE adapter resolves it to provider/model/spec). Reads
   [keeper_assignments_ref], never a module-level eager binding. *)
let runtime_id_for_keeper (keeper_name : string) : string option =
  List.assoc_opt keeper_name (runtime_state ()).keeper_assignments
;;

let keeper_assignments () = (runtime_state ()).keeper_assignments

type dashboard_runtime_defaults_snapshot =
  { default_runtime : t option
  ; runtimes : t list
  ; media_failover : string list
  ; config_path : string option
  }

let dashboard_runtime_defaults_snapshot () =
  let state = runtime_state () in
  { default_runtime = state.default_runtime
  ; runtimes = state.runtimes
  ; media_failover = state.media_failover
  ; config_path = state.config_path
  }
;;

(* Admitted [verifier_exact] slot ids in frozen declaration order from the
   published exact-output registry — the single provider-selection SSOT for
   completion-authority judgement calls (RFC-0361 D7(a)). [Error] names why the
   lane cannot judge (registry not published, lane unconfigured, or no admitted
   slots); there is no fallback to another route. *)
let verifier_exact_lane_slot_ids () =
  match Runtime_exact_output_registry.current () with
  | Error error ->
    Error (Runtime_exact_output_registry.publication_error_to_string error)
  | Ok registry ->
    (match
       Runtime_exact_output_registry.resolve_lane
         registry
         ~lane_id:verifier_exact_lane_id
     with
     | Ok { selected_slots } ->
       Ok
         (List.map
            (fun (slot : Runtime_exact_output_registry.selected_slot) ->
               slot.slot_id)
            selected_slots)
     | Error error ->
       Error (Runtime_exact_output_registry.lane_resolution_error_to_string error))
;;

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
   keeper turn driver dispatches to the requested runtime assignment (or the
   default) instead of unconditionally the default; an
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

(* Resolve a keeper assignment to a lane. Declared lanes are preferred so a lane
   id can shadow a runtime id (lanes are explicit operator routing constructs).
   An assignment naming a bare runtime gets a lane of its own rather than a
   bare dispatch target: the lane id is what keys sticky preference and quota
   demotion, so without one those mechanisms are simply off for that keeper.
   [Missing] means the assignment does not name a known lane or runtime. *)
let resolve_assignment (assigned_id : string) =
  match get_lane_by_id assigned_id with
  | Some lane -> `Lane lane
  | None ->
    (match get_runtime_by_id assigned_id with
     | Some runtime ->
       let candidates =
         match get_default_runtime () with
         | Some default ->
           with_terminal_default ~default_runtime_id:default.id [ runtime.id ]
         | None -> [ runtime.id ]
       in
       `Lane (Runtime_lane.make ~id:runtime.id candidates)
     | None -> `Missing)
;;

let resolve_max_context_of_runtime_id (id : string)
  : (int * max_context_source) option
  =
  match get_runtime_by_id id with
  | Some rt -> resolve_max_context_of_runtime rt
  | None -> None
;;

let max_context_of_runtime_id (id : string) : int option =
  match get_runtime_by_id id with
  | Some rt -> Some (max_context_of_runtime rt)
  | None -> None
;;

(* The model's declared max output tokens (AGENT_CORE capability catalog SSOT), or
   [None] when the runtime is unknown or the catalog row leaves it unset.
   Mirrors [max_context_of_runtime_id] but projects the AGENT_CORE-typed capability
   rather than the runtime.toml [model] record, because max output is owned by
   the provider/model catalog, not the per-binding runtime config. This is an
   observable capability ceiling only. AGENT_CORE owns request validation and clamp
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
  | Some rt -> rt.model.top_p
  | None -> None
;;

(* The per-model [reasoning-effort] declared in runtime.toml
   ([models.<id>.reasoning-effort]), or [None] when the runtime is unknown
   or the model leaves it unset. Mirrors [temperature_of_runtime_id]. *)
let reasoning_effort_of_runtime_id (id : string)
  : Llm_provider.Reasoning_effort.t option
  =
  match get_runtime_by_id id with
  | Some rt -> rt.model.reasoning_effort
  | None -> None
;;

let turn_timeout_s_of_runtime_id (id : string) : float option =
  match get_runtime_by_id id with
  | Some rt -> rt.model.turn_timeout_s
  | None -> None
;;

let wall_clock_ceiling_s_of_runtime_id (id : string) : float option =
  match get_runtime_by_id id with
  | Some rt -> rt.model.wall_clock_ceiling_s
  | None -> None
;;

(* Reads the scope frozen at materialization ({!of_binding}); no
   environment access here, so a post-load env change cannot re-select the
   credential alias out from under the recorded window. *)
let quota_scope_of_runtime (rt : t) : Runtime_quota_window.scope =
  rt.quota_scope
;;

let quota_scope_of_runtime_id (id : string) : Runtime_quota_window.scope option =
  match get_runtime_by_id id with
  | Some rt -> Some (quota_scope_of_runtime rt)
  | None -> None
;;

let max_prompt_bytes_of_runtime_id (id : string) : int option =
  match get_runtime_by_id id with
  | Some rt -> rt.model.max_prompt_bytes
  | None -> None
;;

(* Two declarations bound a model input, and which one applies depends on the
   path: [Keeper_antigravity_runtime] projects against the model's
   [max-prompt-bytes], while the generic driver takes the binding's
   [max-request-body-bytes] through [validate_request_body_cap]. A caller that
   has to fit inside whatever this runtime will enforce has to satisfy both,
   so the smaller declared value is the answer. They count different things —
   prompt bytes against whole-request bytes — which is why this is the ceiling
   for something known to be a part of the input, not a budget for the input
   itself. *)
let declared_input_byte_ceiling_of_runtime_id (id : string) : int option =
  match get_runtime_by_id id with
  | None -> None
  | Some rt ->
    (match rt.model.max_prompt_bytes, rt.binding.max_request_body_bytes with
     | None, None -> None
     | Some only, None | None, Some only -> Some only
     | Some prompt_bytes, Some body_bytes -> Some (min prompt_bytes body_bytes))
;;

let default_preserve_thinking_for_model (_rt : t) : bool option =
  (* AGENT_CORE owns provider/model capability truth and can preserve reasoning when
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

(* The one spelling of "no runtime config path resolves". Two producers
   (this resolver and the assignment transaction below) and the dashboard
   route's 404 mapping share it; a consumer that needs to BRANCH on the
   condition asks [runtime_config_path_opt] instead of matching the
   sentence. *)
let runtime_config_path_missing_message = "runtime config path not found"

let runtime_config_path_opt ?runtime_config_path () =
  match runtime_config_path with
  | Some path -> Some path
  | None -> config_path ()
;;

let runtime_config_path_result ?runtime_config_path () =
  Option.to_result
    (runtime_config_path_opt ?runtime_config_path ())
    ~none:runtime_config_path_missing_message
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

let load_config_observation ?runtime_config_path () =
  let* path = runtime_config_path_result ?runtime_config_path () in
  let* content = load_file_result path in
  Ok (config_observation ~path content)
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

(* [\[egress.keepers.<name>\]] as text, so a keeper's allowlist can be written
   by the same call that puts the keeper in the policy lane. Two files edited
   by hand is how the two halves come apart, and an allowlist that does not
   match its keeper's mode fails silently in the direction that looks like
   permission.

   The table is replaced wholesale rather than merged: an allowlist is the
   complete statement of what a keeper may reach, so a write that kept
   unnamed entries would mean an operator could not remove one. *)
(* Quoted, like an assignment row's key: a keeper name carries dots
   (edgar.a.poe is live), and [egress.keepers.edgar.a.poe] would be a path
   into nested tables rather than one keeper. Unquoted, the loader reads
   "a" as an unknown key under keeper "edgar" and refuses the file. *)
let egress_keepers_header keeper_name =
  Printf.sprintf "[egress.keepers.\"%s\"]" (toml_escape_string keeper_name)
;;

let egress_allow_line allow =
  Printf.sprintf
    "allow = [%s]"
    (allow
     |> List.map (fun entry -> Printf.sprintf "\"%s\"" (toml_escape_string entry))
     |> String.concat ", ")
;;

(* Both spellings, because the file has two authors. This writer always
   quotes; an operator writing [egress.keepers.rondo] by hand does not, and
   a matcher that only knew its own spelling would append a second table for
   a keeper that already had one -- two tables for one keeper, with the
   loader taking whichever it saw first. *)
let is_egress_keeper_header ~keeper_name line =
  let trimmed = String.trim line in
  String.equal trimmed (egress_keepers_header keeper_name)
  || String.equal
       trimmed
       (Printf.sprintf "[egress.keepers.%s]" (toml_escape_string keeper_name))
;;

let update_egress_allow_text content ~keeper_name ~allow =
  let lines, _trailing_newline = split_lines content in
  let section = [ egress_keepers_header keeper_name; egress_allow_line allow ] in
  let updated_lines =
    match find_index (is_egress_keeper_header ~keeper_name) lines with
    | None ->
      (match List.rev lines with
       | [] -> section
       | last :: _ when String.equal (String.trim last) "" -> lines @ section
       | _ -> lines @ ("" :: section))
    | Some header_index ->
      let before, from_header = split_at header_index lines in
      (match from_header with
       | [] -> lines @ section
       | _ :: after_header ->
         let _replaced, after_section =
           match find_index is_toml_table_header after_header with
           | None -> after_header, []
           | Some next -> split_at next after_header
         in
         before @ section @ after_section)
  in
  join_lines updated_lines ~trailing_newline:true
;;

let remove_egress_allow_text content ~keeper_name =
  let lines, _trailing_newline = split_lines content in
  let updated_lines =
    match find_index (is_egress_keeper_header ~keeper_name) lines with
    | None -> lines
    | Some header_index ->
      let before, from_header = split_at header_index lines in
      (match from_header with
       | [] -> lines
       | _ :: after_header ->
         let _dropped, after_section =
           match find_index is_toml_table_header after_header with
           | None -> after_header, []
           | Some next -> split_at next after_header
         in
         before @ after_section)
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

let materialize_runtime_config_text ~config_path content =
  let* cfg =
    Runtime_toml.parse_string content
    |> Result.map_error (fun errs ->
      Printf.sprintf
        "runtime config parse failed (%s): %s"
        config_path
        (runtime_parse_errors_to_string errs))
  in
  materialize_config ~config_path cfg
;;

let runtime_config_commit_order = ref Int64.zero
let runtime_config_commit_order_mu = Stdlib.Mutex.create ()

let committed_receipt ~observation ~durability =
  let order =
    (* Process-global publication order spans every runtime.toml authority.
       The file lock is path-scoped, so distinct config paths can commit on
       different domains and must synchronize this shared sequence here. *)
    Stdlib.Mutex.protect runtime_config_commit_order_mu (fun () ->
      runtime_config_commit_order := Int64.succ !runtime_config_commit_order;
      !runtime_config_commit_order)
  in
  { observation
  ; durability
  ; order = Config_commit_order order
  ; lock_warnings = []
  }
;;

let with_runtime_config_write_lock_using observe path f =
  let lock_path = path ^ ".lock" in
  match observe ~lock_path f with
  | File_lock_eio.Lock_not_acquired error ->
    Error (File_lock_eio.durable_lock_error_to_string error)
  | File_lock_eio.Body_completed { value; release_error = None } ->
    Ok { value; warnings = [] }
  | File_lock_eio.Body_completed { value; release_error = Some error } ->
    Ok
      { value
      ; warnings =
          [ Config_lock_release_unconfirmed
              (File_lock_eio.durable_lock_error_to_string error)
          ]
      }
;;

let with_runtime_config_write_lock path f =
  with_runtime_config_write_lock_using
    File_lock_eio.with_durable_lock_observed path f
;;

let attach_lock_warnings warnings receipt =
  { receipt with lock_warnings = receipt.lock_warnings @ warnings }
;;

let runtime_config_atomic_failure
    ~replacement_visible
    ~observation
    (failure : Fs_compat.atomic_replace_failure)
  =
  if replacement_visible
  then
    let detail = Fs_compat.atomic_replace_failure_to_string failure in
    Ok
      (committed_receipt
         ~observation
         ~durability:(Durability_unconfirmed { detail }))
  else
    match failure.Fs_compat.exception_ with
    | Eio.Cancel.Cancelled _ ->
      Printexc.raise_with_backtrace failure.exception_ failure.backtrace
    | _ -> Error (Fs_compat.atomic_replace_failure_to_string failure)
;;

let runtime_config_write_outcome
    ~replace_file
    ~on_replacement_visible
    ~path
    content
    ()
  =
  match replace_file path content with
  | Ok () ->
    on_replacement_visible ();
    Runtime_exact_output_registry.Committed `Durable
  | Error (failure : Fs_compat.atomic_replace_failure) ->
    (match failure.stage with
     | Fs_compat.Before_rename ->
       Runtime_exact_output_registry.Not_committed failure
     | Fs_compat.After_rename ->
       on_replacement_visible ();
       Runtime_exact_output_registry.Committed (`Durability_unconfirmed failure))
;;

(* Pure save precondition shared by the writer and the preview endpoint: TOML
   parse, config materialization, and dispatch-cap validation, with no write and
   no [set_loaded]. Keeping this as the single source of the precondition means
   [can_save] previews cannot diverge from what [commit_runtime_config_text]
   actually enforces. *)
let parse_and_validate_config_text ~config_path content =
  let* () =
    match Skill_source_config.validate_text content with
    | Ok () -> Ok ()
    | Error diagnostics ->
      Error
        (String.concat
           "; "
           (List.map Skill_source_config.diagnostic_to_string diagnostics))
  in
  let* loaded, exact_output_lanes =
    materialize_runtime_config_text ~config_path content
  in
  (* TEL-OK: validation is pure; config commit owns visible failure reporting. *)
  let* () =
    validate_keeper_dispatch_request_caps
      ~config_path
      ~verifier_exact_slot_ids:
        (verifier_exact_slot_ids_of_lane_decls exact_output_lanes)
      loaded
  in
  Ok (loaded, exact_output_lanes)
;;

let commit_runtime_config_text
    ?(replace_file = Fs_compat.save_file_atomic_strict_staged)
    ~path
    content
  =
  let observation = config_observation ~path content in
  let* loaded, exact_output_lanes =
    parse_and_validate_config_text ~config_path:path content
  in
  match
    Runtime_exact_output_registry.prepare_replacement ~lanes:exact_output_lanes
  with
  | Error Runtime_exact_output_registry.Registry_not_published ->
    (match replace_file path content with
     | Ok () ->
       set_loaded ~config_path:path loaded;
       Ok (committed_receipt ~observation ~durability:Durable)
     | Error (failure : Fs_compat.atomic_replace_failure) ->
       (match failure.stage with
        | Fs_compat.Before_rename ->
          runtime_config_atomic_failure
            ~replacement_visible:false
            ~observation
            failure
        | Fs_compat.After_rename ->
          set_loaded ~config_path:path loaded;
          runtime_config_atomic_failure
            ~replacement_visible:true
            ~observation
            failure))
  | Error error ->
    Error
      ("exact-output registry replacement rejected: "
       ^ Runtime_exact_output_registry.publication_error_to_string error)
  | Ok prepared_replacement ->
    (match
       Runtime_exact_output_registry.transact_replacement
         prepared_replacement
         ~apply_write:
           (runtime_config_write_outcome
              ~replace_file
              ~on_replacement_visible:(fun () ->
                set_loaded ~config_path:path loaded)
              ~path
              content)
     with
     | Error error ->
       Error
         ("exact-output registry replacement reservation rejected: "
          ^ Runtime_exact_output_registry.publication_error_to_string error)
     | Ok (Runtime_exact_output_registry.Not_committed failure) ->
       runtime_config_atomic_failure
         ~replacement_visible:false
         ~observation
         failure
     | Ok (Runtime_exact_output_registry.Committed `Durable) ->
       Ok (committed_receipt ~observation ~durability:Durable)
     | Ok
         (Runtime_exact_output_registry.Committed
           (`Durability_unconfirmed failure)) ->
       runtime_config_atomic_failure
         ~replacement_visible:true
         ~observation
         failure)
;;

let save_config_text_with_replace_file
    ?runtime_config_path
    ~replace_file
    content
  =
  let* path = runtime_config_path_result ?runtime_config_path () in
  let* locked =
    with_runtime_config_write_lock path (fun () ->
      commit_runtime_config_text ~replace_file ~path content)
  in
  let* receipt = locked.value in
  Ok (attach_lock_warnings locked.warnings receipt)
;;

let save_config_text ?runtime_config_path content =
  save_config_text_with_replace_file
    ?runtime_config_path
    ~replace_file:Fs_compat.save_file_atomic_strict_staged
    content
;;

(* The read-modify-write form of [save_config_text]. A caller that loads the
   file itself and then hands the edited text to [save_config_text] loses any
   write that landed in between, because only the write is inside the lock.
   Here the load, the edit and the commit are all inside it. Different
   processes edit different tables of this one file -- the server writes
   keeper assignments and lanes, the TUI writes the reader's [\[tui\]] keys --
   so that gap is reachable rather than theoretical. *)
let edit_config_text ?runtime_config_path edit =
  let* path = runtime_config_path_result ?runtime_config_path () in
  let* locked =
    with_runtime_config_write_lock path (fun () ->
      let* content = load_file_result path in
      commit_runtime_config_text ~path (edit content))
  in
  let* receipt = locked.value in
  Ok (attach_lock_warnings locked.warnings receipt)
;;

let validate_config_text ?runtime_config_path content =
  let* path = runtime_config_path_result ?runtime_config_path () in
  let* _loaded, _exact_output_lanes =
    parse_and_validate_config_text ~config_path:path content
  in
  Ok ()
;;

module For_testing = struct
  type snapshot = loaded_state
  (* TEL-OK: this module only exposes pure state and validation test helpers. *)

  let snapshot () = runtime_state ()
  let restore snapshot = Atomic.set loaded_state_ref snapshot
  (* TEL-OK: test-only alias of the pure reachability projection above. *)
  let keeper_dispatch_runtime_ids = keeper_dispatch_runtime_ids
  let save_config_text_with_sync_parent
      ?runtime_config_path
      ~sync_parent
      content
    =
    save_config_text_with_replace_file
      ?runtime_config_path
      ~replace_file:
        (Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
           ~sync_parent)
      content
  ;;
end
;;

let assignment_state_of_config (config : Runtime_schema.config) keeper_name =
  match List.assoc_opt keeper_name config.keeper_assignments with
  | None -> Assignment_missing
  | Some runtime_id -> Assignment_present runtime_id
;;

let assignment_transaction_of_source ~path ~source_text ~keeper_name =
  let* config =
    Runtime_toml.parse_string source_text
    |> Result.map_error (fun errors ->
      Printf.sprintf
        "runtime config parse failed (%s): %s"
        path
        (runtime_parse_errors_to_string errors))
  in
  let observation = config_observation ~path source_text in
  Ok
    (Present_runtime_config
       { path
       ; source_text
       ; keeper_name
       ; revision =
           Runtime_config_present
             { source_revision = observation.source_revision
             ; assignment = assignment_state_of_config config keeper_name
             }
       })
;;

let with_keeper_assignment_transaction_using ~with_lock ?runtime_config_path
    ~keeper_name f =
  let keeper_name = String.trim keeper_name in
  if String.equal keeper_name ""
  then Error "keeper_name must not be empty"
  else if contains_newline keeper_name
  then Error "keeper_name must not contain newlines"
  else
    (* Ask the condition, not the sentence: the old arm matched the error
       string exactly, so rewording the message would have silently turned
       every benign missing-config read into a hard error. *)
    match runtime_config_path_opt ?runtime_config_path () with
    | None ->
      Ok { value = f (Missing_runtime_config { keeper_name }); warnings = [] }
    | Some path ->
      let* locked =
        with_lock path (fun () ->
          if not (Fs_compat.file_exists path)
          then Ok (f (Missing_runtime_config { keeper_name }))
          else
            let* source_text = load_file_result path in
            let* transaction =
              assignment_transaction_of_source ~path ~source_text ~keeper_name
            in
            Ok (f transaction))
      in
      let* value = locked.value in
      Ok { value; warnings = locked.warnings }
;;

let with_keeper_assignment_transaction ?runtime_config_path ~keeper_name f =
  with_keeper_assignment_transaction_using
    ~with_lock:with_runtime_config_write_lock
    ?runtime_config_path ~keeper_name f
;;

let keeper_assignment_revision = function
  | Missing_runtime_config _ -> Runtime_config_missing
  | Present_runtime_config transaction -> transaction.revision

let keeper_assignment_transaction_path = function
  | Missing_runtime_config _ -> None
  | Present_runtime_config transaction -> Some transaction.path

let normalized_assignment = function
  | None -> Ok Assignment_missing
  | Some runtime_id ->
    let runtime_id = String.trim runtime_id in
    if String.equal runtime_id ""
    then Error "runtime_id must not be empty"
    else if contains_newline runtime_id
    then Error "runtime_id must not contain newlines"
    else Ok (Assignment_present runtime_id)
;;

let commit_keeper_assignment_using ~commit_text transaction ~runtime_id =
  let* requested = normalized_assignment runtime_id in
  match transaction with
  | Missing_runtime_config _ ->
    (match requested with
     | Assignment_missing -> Ok (Assignment_unchanged Runtime_config_missing)
     | Assignment_present _ -> Error runtime_config_path_missing_message)
  | Present_runtime_config transaction ->
  let current_assignment =
    match transaction.revision with
    | Runtime_config_present { assignment; _ } -> assignment
    | Runtime_config_missing -> Assignment_missing
  in
  if requested = current_assignment
  then Ok (Assignment_unchanged transaction.revision)
  else
    let next =
      match requested with
      | Assignment_missing ->
        remove_runtime_assignment_text transaction.source_text
          ~keeper_name:transaction.keeper_name
      | Assignment_present runtime_id ->
        update_runtime_assignment_text transaction.source_text
          ~keeper_name:transaction.keeper_name ~runtime_id
    in
    let* receipt = commit_text ~path:transaction.path next in
    Ok
      (Assignment_committed
         { receipt
         ; revision =
             Runtime_config_present
               { source_revision = receipt.observation.source_revision
               ; assignment = requested
               }
         })
;;

let commit_keeper_assignment transaction ~runtime_id =
  commit_keeper_assignment_using
    ~commit_text:(fun ~path content -> commit_runtime_config_text ~path content)
    transaction ~runtime_id
;;

(* The keeper's egress allowlist, written inside the same transaction as its
   runtime assignment: one lock, one file, one set of source bytes. A second
   transaction would let another admitted writer land between a keeper being
   put in the policy lane and being told what it may reach, and the gap
   between those two is a keeper that reaches nothing while its config says
   otherwise.

   Unlike an assignment, there is no "unchanged" fast path keyed off the
   revision: the transaction's revision carries the assignment, not the
   allowlist, so the comparison is on the text this write would produce. *)
let commit_keeper_egress_allow_using ~commit_text transaction ~allow =
  match transaction with
  | Missing_runtime_config _ ->
    (match allow with
     | None -> Ok (Assignment_unchanged Runtime_config_missing)
     | Some _ -> Error runtime_config_path_missing_message)
  | Present_runtime_config transaction ->
    let next =
      match allow with
      | None ->
        remove_egress_allow_text transaction.source_text
          ~keeper_name:transaction.keeper_name
      | Some allow ->
        update_egress_allow_text transaction.source_text
          ~keeper_name:transaction.keeper_name ~allow
    in
    if String.equal next transaction.source_text
    then Ok (Assignment_unchanged transaction.revision)
    else
      let* receipt = commit_text ~path:transaction.path next in
      Ok
        (Assignment_committed
           { receipt
           ; revision =
               Runtime_config_present
                 { source_revision = receipt.observation.source_revision
                 ; assignment =
                     (match transaction.revision with
                      | Runtime_config_present { assignment; _ } -> assignment
                      | Runtime_config_missing -> Assignment_missing)
                 }
           })
;;

let commit_keeper_egress_allow transaction ~allow =
  commit_keeper_egress_allow_using
    ~commit_text:(fun ~path content -> commit_runtime_config_text ~path content)
    transaction ~allow
;;

let restore_keeper_assignment_transaction_using ~commit_text transaction =
  match transaction with
  | Missing_runtime_config _ -> Ok (Assignment_unchanged Runtime_config_missing)
  | Present_runtime_config transaction ->
  let* current = load_file_result transaction.path in
  if String.equal current transaction.source_text
  then Ok (Assignment_unchanged transaction.revision)
  else
    let* receipt =
      commit_text ~path:transaction.path transaction.source_text
    in
    Ok
      (Assignment_committed
         { receipt
         ; revision = transaction.revision
         })
;;

let restore_keeper_assignment_transaction transaction =
  restore_keeper_assignment_transaction_using
    ~commit_text:(fun ~path content -> commit_runtime_config_text ~path content)
    transaction
;;

let observe_keeper_assignment ?runtime_config_path ~keeper_name () =
  with_keeper_assignment_transaction ?runtime_config_path ~keeper_name
    keeper_assignment_revision
;;

let set_keeper_assignment_if_revision_using ~with_transaction ?runtime_config_path
    ~keeper_name ~runtime_id ~expected () =
  match
    with_transaction ?runtime_config_path ~keeper_name (fun transaction ->
      let observed = keeper_assignment_revision transaction in
      if expected <> observed
      then Error (Assignment_revision_conflict observed)
      else
        match commit_keeper_assignment transaction ~runtime_id with
        | Error detail -> Error (Assignment_io_error detail)
        | Ok write -> Ok write)
  with
  | Error detail -> Error (Assignment_io_error detail)
  | Ok { value = Error error; _ } -> Error error
  | Ok { value = Ok value; warnings } ->
    let value =
      match value with
      | Assignment_unchanged _ -> value
      | Assignment_committed committed ->
        Assignment_committed
          { committed with
            receipt = attach_lock_warnings warnings committed.receipt
          }
    in
    Ok { value; warnings }
;;

let set_keeper_assignment_if_revision ?runtime_config_path ~keeper_name ~runtime_id
    ~expected () =
  set_keeper_assignment_if_revision_using
    ~with_transaction:with_keeper_assignment_transaction
    ?runtime_config_path ~keeper_name ~runtime_id ~expected ()
;;

module Assignment_for_testing = struct
  let commit_with_replace_file ~replace_file transaction ~runtime_id =
    commit_keeper_assignment_using
      ~commit_text:(commit_runtime_config_text ~replace_file)
      transaction ~runtime_id
  ;;

  let restore_with_replace_file ~replace_file transaction =
    restore_keeper_assignment_transaction_using
      ~commit_text:(commit_runtime_config_text ~replace_file)
      transaction
  ;;

  let set_with_release_failure ~release_failure ~runtime_config_path ~keeper_name
      ~runtime_id ~expected () =
    let with_lock path f =
      let observe ~lock_path body =
        File_lock_eio.For_testing.with_durable_lock_observed_with_release_failure
          ~release_failure ~lock_path body
      in
      with_runtime_config_write_lock_using observe path f
    in
    let with_transaction ?runtime_config_path ~keeper_name f =
      with_keeper_assignment_transaction_using ~with_lock ?runtime_config_path
        ~keeper_name f
    in
    set_keeper_assignment_if_revision_using ~with_transaction
      ~runtime_config_path ~keeper_name ~runtime_id ~expected ()
  ;;
end

let set_runtime_id_for_keeper ?runtime_config_path ~keeper_name ~runtime_id () =
  match
    with_keeper_assignment_transaction ?runtime_config_path ~keeper_name
      (fun transaction ->
        commit_keeper_assignment transaction ~runtime_id:(Some runtime_id))
  with
  | Error _ as error -> error
  | Ok locked ->
    locked.value
    |> Result.map (fun value -> { value; warnings = locked.warnings })
;;

let clear_runtime_id_for_keeper ?runtime_config_path ~keeper_name () =
  match
    with_keeper_assignment_transaction ?runtime_config_path ~keeper_name
      (fun transaction -> commit_keeper_assignment transaction ~runtime_id:None)
  with
  | Error _ as error -> error
  | Ok locked ->
    locked.value
    |> Result.map (fun value -> { value; warnings = locked.warnings })
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
      let* locked =
        with_runtime_config_write_lock path (fun () ->
          let* content = load_file_result path in
          let next = update_runtime_scalar_text content ~key ~runtime_id in
          commit_runtime_config_text ~path next)
      in
      let* receipt = locked.value in
      Ok (attach_lock_warnings locked.warnings receipt)
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
    let* locked =
      with_runtime_config_write_lock path (fun () ->
        let* content = load_file_result path in
        let next = update_runtime_string_array_text content ~key ~values:runtime_ids in
        commit_runtime_config_text ~path next)
    in
    let* receipt = locked.value in
    Ok (attach_lock_warnings locked.warnings receipt))
;;

let set_runtime_default ?runtime_config_path ~runtime_id () =
  set_runtime_scalar ?runtime_config_path ~key:"default" ~runtime_id:(Some runtime_id) ()
;;

let set_runtime_media_failover ?runtime_config_path ~runtime_ids () =
  set_runtime_string_array ?runtime_config_path ~key:"media_failover" ~runtime_ids ()
;;

(* [\[runtime.lanes."<id>"\]] is written by table path, not by the [\[runtime\]]
   array writer above: the candidates live in their own table, one per lane.

   The header must match the file byte for byte ([Toml_line_editor.is_table]
   compares the whole line), so the id is quoted exactly when TOML requires it
   — a bare key is [A-Za-z0-9_-] and every runtime id carries a dot, so in
   practice this quotes. Writing the other form would append a second table
   for the same key and the post-write validation would reject the file. *)
let lane_table_path lane_id =
  let bare =
    String.for_all
      (function 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true | _ -> false)
      lane_id
  in
  if bare && not (String.equal lane_id "")
  then Printf.sprintf "runtime.lanes.%s" lane_id
  else
    (* [escape_string] escapes the contents; the quotes are the caller's. *)
    Printf.sprintf "runtime.lanes.\"%s\"" (Toml_line_editor.escape_string lane_id)
;;

let set_runtime_lane_candidates ?runtime_config_path ~lane_id ~runtime_ids () =
  let lane_id = String.trim lane_id in
  let runtime_ids = List.map String.trim runtime_ids in
  if String.equal lane_id ""
  then Error "lane id must not be empty"
  else if contains_newline lane_id
  then Error "lane id must not contain newlines"
  else if runtime_ids = []
  then
    (* An empty list is not "no failover", it is a lane that resolves to
       nothing. Removing a lane is a different edit than emptying it. *)
    Error "a lane needs at least one candidate"
  else if List.exists (String.equal "") runtime_ids
  then Error "runtime_ids must not contain empty entries"
  else if List.exists contains_newline runtime_ids
  then Error "runtime_ids must not contain newlines"
  else (
    let* path = runtime_config_path_result ?runtime_config_path () in
    let* locked =
      with_runtime_config_write_lock path (fun () ->
        let* content = load_file_result path in
        let next =
          Toml_line_editor.edit_table_multiline_array
            content
            ~path:(lane_table_path lane_id)
            ~key:"candidates"
            ~values:runtime_ids
        in
        commit_runtime_config_text ~path next)
    in
    let* receipt = locked.value in
    Ok (attach_lock_warnings locked.warnings receipt))
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
