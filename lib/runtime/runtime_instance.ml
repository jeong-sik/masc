(** A materialized provider/model binding, its frozen dispatch identity,
    credential admission and capability-derived limits. Configuration loading,
    mutable catalog state and durable commits remain owned by Runtime. *)

open Runtime_schema
open Runtime_config_error

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
  ; credential_admission : Runtime_credential_selection.admission option
  ; candidate_backpressure : Runtime_candidate_backpressure.candidate
    (** Candidate-only backpressure tied to the frozen dispatch binding. *)
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
  | Undeclared_credential of { provider_id : string }
  | Missing_credential_selection of { provider_id : string }

let undeclared_credential_detail ~provider_id =
  Printf.sprintf
    "provider %S requires an API key and declares no credential: add \
     [providers.%s.credentials] with the environment variable that holds it"
    provider_id
    provider_id
;;

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
       | Agent_core.Error.FileCredential -> "file"
       | Agent_core.Error.UndeclaredCredential -> "undeclared")
  | Undeclared_credential { provider_id } ->
    undeclared_credential_detail ~provider_id
  | Missing_credential_selection {provider_id} ->
    Printf.sprintf "runtime provider %S has no materialized credential selection" provider_id
;;

let dispatch_credential_error_to_core_error = function
  | Required_env_credential_missing { env_key; _ } ->
    Agent_core.Error.Config (Agent_core.Error.MissingEnvVar { var_name = env_key })
  | Declared_credential_unavailable { provider_id; carrier } ->
    Agent_core.Error.Config
      (Agent_core.Error.CredentialUnavailable { provider_id; carrier })
  | Undeclared_credential { provider_id } ->
    Agent_core.Error.Config
      (Agent_core.Error.CredentialUnavailable
         { provider_id; carrier = Agent_core.Error.UndeclaredCredential })
  | Missing_credential_selection {provider_id} ->
    Agent_core.Error.Config (Agent_core.Error.InvalidConfig
      {field="credential_selection";
       detail=dispatch_credential_error_to_string (Missing_credential_selection {provider_id})})
;;

let validate_dispatch_credential
    ~(provider_config : Llm_provider.Provider_config.t)
    (runtime : t)
  =
  match runtime.execution with
  | Runtime_execution.Codex_app_server _
  | Runtime_execution.Claude_code _
  | Runtime_execution.Antigravity_cli _
  | Runtime_execution.Muse_serve _
  | Runtime_execution.Vibe_cli _ ->
    Ok ()
  | Runtime_execution.Agent_core _ ->
    (match runtime.credential_admission with
     | None -> Error (Missing_credential_selection {provider_id=runtime.provider.id})
     | Some admission ->
       if not (Llm_provider.Secret.is_empty provider_config.api_key) then Ok ()
       else
         let provider_id = Runtime_credential_selection.provider_id admission in
         match Runtime_credential_selection.requirement admission with
         | Not_required -> Ok ()
         | Unknown_provider -> Ok ()
         | Required_undeclared -> Error (Undeclared_credential {provider_id})
         | Required_env env_key -> Error (Required_env_credential_missing {provider_id;env_key})
         | Required_inline -> Error (Declared_credential_unavailable
             {provider_id;carrier=Agent_core.Error.InlineCredential})
         | Required_file -> Error (Declared_credential_unavailable
             {provider_id;carrier=Agent_core.Error.FileCredential}))
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
    ~(execution : Runtime_execution.t)
    ~credential_admission =
  match execution with
  | Runtime_execution.Claude_code client ->
    Ok (Runtime_quota_window.scope_of_claude_code_home
      (Some (Runtime_account_access.home client.account_home)))
  | Runtime_execution.Codex_app_server client ->
    Ok (Runtime_quota_window.scope_of_codex_home
      (Some (Runtime_account_access.home client.account_home)))
  | Runtime_execution.Muse_serve client ->
    Ok
      (Runtime_quota_window.scope_of_muse_home
         (Runtime_account_access.muse_home_path client.account_home))
  | Runtime_execution.Agent_core _ ->
    (match credential_admission with
     | Some admission -> Ok (Runtime_credential_selection.quota_scope admission)
     | None -> Error "HTTP materialization has no credential selection")
  | Runtime_execution.Antigravity_cli _ ->
    Ok (Runtime_quota_window.scope_of_credential ~provider_id:provider.id provider.credentials)
  | Runtime_execution.Vibe_cli _ ->
    (* Vibe owns its login and the adapter refuses declared credentials, so
       the provider row names the window. *)
    Ok (Runtime_quota_window.scope_of_credential ~provider_id:provider.id None)
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
   layer up, so the vocabulary is closed and {!Runtime.load_list} matches it. *)
let materialize_binding ~construction (cfg : config) (b : binding) : (t, drop_reason) result =
  if not b.enabled
  then Error Binding_disabled
  else match provider_of_id cfg b.provider_id, model_of_id cfg b.model_id with
  | Some provider, Some model ->
    if not provider.enabled
    then Error (Provider_disabled provider.id)
    else
      (match Runtime_adapter.materialize_execution ~construction cfg b with
       | Ok selected ->
         let execution = selected.Runtime_adapter.execution in
         let credential_admission = selected.credential_admission in
         Result.map (fun quota_scope ->
           { id = id_of_binding b
           ; provider
           ; model
           ; binding = b
           ; execution
           ; credential_admission
           ; candidate_backpressure = (
               let binding = match execution with
                 | Runtime_execution.Agent_core sealed ->
                     (match Runtime_account_access.api_binding_identity sealed with
                      | Ok binding -> Runtime_candidate_backpressure.Resolved_http_binding binding
                      | Error reason -> Runtime_candidate_backpressure.Http_binding_unavailable reason)
                 | Runtime_execution.Codex_app_server _
                 | Runtime_execution.Claude_code _
                 | Runtime_execution.Antigravity_cli _
                 | Runtime_execution.Muse_serve _
                 | Runtime_execution.Vibe_cli _ -> Runtime_candidate_backpressure.Official_client_binding
               in
               Runtime_candidate_backpressure.create_candidate ~binding)
           ; quota_scope
           })
           (quota_scope_of_materialized ~provider ~execution ~credential_admission)
         |> Result.map_error (fun reason -> Execution_unbuildable reason)
       | Error reason -> Error (Execution_unbuildable reason))
  | None, _ -> Error (Provider_not_declared b.provider_id)
  | Some _, None -> Error (Model_not_declared b.model_id)
;;

let of_binding cfg binding =
  materialize_binding ~construction:(Runtime_adapter.create_construction ()) cfg binding
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
  let construction = Runtime_adapter.create_construction () in
  let runtimes, dropped =
    List.fold_left
      (fun (runtimes, dropped) (b : binding) ->
         match materialize_binding ~construction cfg b with
         | Ok rt -> rt :: runtimes, dropped
         | Error reason -> runtimes, (id_of_binding b, reason) :: dropped)
      ([], [])
      bindings
  in
  List.rev runtimes, List.rev dropped
;;

let capabilities_for_runtime (rt : t) =
  match rt.execution with
  | Runtime_execution.Agent_core sealed ->
    Llm_provider.Provider_config.capabilities_for_config_model
      (Runtime_account_access.api_declaration sealed)
  | Runtime_execution.Codex_app_server _
  | Runtime_execution.Claude_code _
  | Runtime_execution.Antigravity_cli _
  | Runtime_execution.Muse_serve _
  | Runtime_execution.Vibe_cli _ -> None
;;

type max_context_source =
  | Override
  | Capability
  | Override_clamped_by_capability
  | Provider_override
  | Binding_override
  | Provider_override_clamped_by_capability
  | Binding_override_clamped_by_capability

let max_context_source_to_string = function
  | Provider_override -> "provider_override"
  | Binding_override -> "binding_override"
  | Provider_override_clamped_by_capability -> "provider_override_clamped_by_capability"
  | Binding_override_clamped_by_capability -> "binding_override_clamped_by_capability"
  | Override -> "override"
  | Capability -> "capability"
  | Override_clamped_by_capability -> "override_clamped_by_capability"
;;

(* Effective input context window and the source that produced it.
   Binding declarations override provider defaults, then model defaults.
   [None] means neither a scoped declaration nor the AGENT_CORE capability
   catalog declares a positive context window for this
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
  let declared = match rt.binding.max_context, rt.provider.max_context, rt.model.max_context with
    | Some tokens, _, _ -> Some (tokens, Binding_override, Binding_override_clamped_by_capability)
    | None, Some tokens, _ -> Some (tokens, Provider_override, Provider_override_clamped_by_capability)
    | None, None, Some tokens -> Some (tokens, Override, Override_clamped_by_capability)
    | None, None, None -> None in
  match declared, capability_cap with
  | Some (tokens, _, clamped), Some cap when tokens > cap -> Some (cap, clamped)
  | Some (tokens, source, _), _ -> Some (tokens, source)
  | None, Some cap -> Some (cap, Capability)
  | None, None -> None
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

(* Reads the scope frozen at materialization ({!of_binding}); no
   environment access here, so a post-load env change cannot re-select the
   credential alias out from under the recorded window. *)
let quota_scope_of_runtime (rt : t) : Runtime_quota_window.scope =
  rt.quota_scope
;;

(* Each quota scope the runtimes draw on, once, in first-appearance order:
   rows that share a credential share one scope. *)
let distinct_quota_scopes (runtimes : t list) : Runtime_quota_window.scope list =
  List.fold_left
    (fun scopes (rt : t) ->
       if List.exists (Runtime_quota_window.scope_equal rt.quota_scope) scopes
       then scopes
       else scopes @ [ rt.quota_scope ])
    []
    runtimes
;;

(* The model's declared max output tokens (AGENT_CORE capability catalog SSOT).
   [None] for an official-client runtime, for a model with no catalog row, and
   for a row that leaves it unset.
   Mirrors [max_context_of_runtime] but projects the AGENT_CORE-typed capability
   rather than the runtime.toml [model] record, because max output is owned by
   the provider/model catalog, not the per-binding runtime config. This is an
   observable capability ceiling only. AGENT_CORE owns request validation and clamp
   policy; MASC never turns this value into a request default. *)
let max_output_tokens_of_runtime (rt : t) : int option =
  match capabilities_for_runtime rt with
  | Some caps -> caps.Llm_provider.Capabilities.max_output_tokens
  | None -> None
;;
