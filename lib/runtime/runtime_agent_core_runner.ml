(** Runtime_agent_core_runner — Eio context, runtime resolution, runtime MCP policy.

    Resolves MASC runtime intent into an Agent Core runtime.
    Provides runtime profile defaults, Eio context validation,
    provider resolution, and tool-support filtering.

    @since God file decomposition *)

(* Runtime profile defaults (moved from Runtime module) *)

(* Named model execution *)

let require_eio ?sw ?net () =
  let sw =
    match sw with
    | Some s -> Some s
    | None -> Eio_context.get_switch_opt ()
  in
  let net =
    match net with
    | Some n -> Some n
    | None -> Eio_context.get_net_opt ()
  in
  match sw, net with
  | Some sw, Some net -> Ok (sw, net)
  | None, _ -> Error "Eio switch not available (running outside server context)"
  | _, None -> Error "Eio net not available (running outside server context)"

(* SSOT for the [InvalidConfig.field] tag that marks the MASC-internal
   "Eio context unavailable" error. Both the producer
   ([eio_context_error_to_core_error]) and the structural classifier
   ([is_eio_context_error]) reference this single binding, so the two sides
   cannot drift apart. *)
let eio_context_field = "eio_context"

let eio_context_error_to_core_error detail =
  Agent_core.Error.Config
    (Agent_core.Error.InvalidConfig { field = eio_context_field; detail })

(* [true] iff [err] is the "Eio switch/net unavailable" config error this
   module produces (running outside a server context). Matched structurally
   on the typed [Config (InvalidConfig { field })] tag — NOT by substring-
   scanning [Agent_core.Error.to_string]: the rendered Eio wording is not a
   contract and a wording change must not silently drop the fatal-environment
   promotion in the heartbeat loop. The producer and this predicate live in
   one module so the [field] tag is the single source of truth. The [when]
   guard keeps the [Config _] arm reachable regardless of how many
   constructors the wrapped config-error type carries. *)
let is_eio_context_error (err : Agent_core.Error.t) : bool =
  match err with
  | Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; _ })
    when String.equal field eio_context_field -> true
  | Agent_core.Error.Config
      ( Agent_core.Error.MissingEnvVar _
      | Agent_core.Error.UnsupportedProvider _
      | Agent_core.Error.CredentialUnavailable _
      | Agent_core.Error.InvalidConfig _
      | Agent_core.Error.SensitiveValueInConfig _ ) -> false
  | Agent_core.Error.Provider _ -> false
  | Agent_core.Error.Api _ -> false
  | Agent_core.Error.Agent _ -> false
  | Agent_core.Error.Mcp _ -> false
  | Agent_core.Error.Serialization _ -> false
  | Agent_core.Error.Io _ -> false
  | Agent_core.Error.Orchestration _ | Agent_core.Error.Media _ -> false
  | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } -> false

let runtime_catalog_error_to_core_error detail =
  Agent_core.Error.Config
    (Agent_core.Error.InvalidConfig { field = "runtime_id"; detail })

(** Resolve runtime provider configs via [Runtime].
    Returns Provider_config.t list for the downstream AGENT_CORE runtime. *)
let resolve_runtime_providers ~runtime_id () =
  (* Audit F8: honor the *requested* runtime id (RFC-0207 catalog lookup).
     The previous RFC-0206 single-binding stub discarded [runtime_id] and
     always returned the default runtime, silently substituting an
     operator-selected runtime id — an
     Unknown→Permissive fallback. An empty id means the default runtime; a
     non-empty id that is not a configured runtime is an [Error] (no silent
     substitution — RFC-0206 §2.1). The former [?provider_filter] parameter
     was ignored here and is deleted;
     each resolved runtime carries exactly one provider_config. *)
  let runtime_id = String.trim runtime_id in
  let provider_config_of_runtime rt =
    match rt.Runtime_instance.execution with
    | Runtime_execution.Agent_core sealed ->
      (match Runtime_account_access.authorize_api sealed with
       | Error refusal -> Error (Runtime_account_access.refusal_to_string refusal)
       | Ok provider_config ->
         (match Runtime_instance.validate_dispatch_credential ~provider_config rt with
          | Ok () -> Ok provider_config
          | Error error ->
            Error (Runtime_instance.dispatch_credential_error_to_string error)))
    | Runtime_execution.Codex_app_server _
    | Runtime_execution.Claude_code _
    | Runtime_execution.Muse_serve _
    | Runtime_execution.Vibe_cli _
      ->
      Error
        (Printf.sprintf
           "runtime %S is owned by an official client, not Agent Core"
           rt.Runtime_instance.id)
    | Runtime_execution.Antigravity_cli _ ->
      Error
        (Printf.sprintf
           "runtime %S is owned by antigravity-cli, not the Agent Core"
           rt.Runtime_instance.id)
  in
  if String.equal runtime_id "" then
    match Runtime.get_default_runtime () with
    | None -> Error "no default runtime configured"
    | Some rt -> Result.map (fun provider_config -> [ provider_config ]) (provider_config_of_runtime rt)
  else
    match Runtime.get_runtime_by_id runtime_id with
    | Some rt -> Result.map (fun provider_config -> [ provider_config ]) (provider_config_of_runtime rt)
    | None ->
      Error
        (Printf.sprintf
           "requested runtime %S not found among configured runtimes \
            (no silent fallback to default — RFC-0206 §2.1)"
           runtime_id)

let resolve_runtime_providers_for_turn ~runtime_id () =
  (* The empty id documents "the default runtime", and the resolver honours that
     by going through [Runtime.get_default_runtime]. The seed lookup is keyed by
     id, so passing "" through would look up a runtime that does not exist and
     return an absent seed — the default runtime would resolve its binding and
     lose its own [thinking-support], which is the mismatch this function is for
     (review on #28530). Resolve the id first so both halves name the same
     runtime. *)
  let seed_runtime_id =
    if String.equal runtime_id ""
    then (
      match Runtime.get_default_runtime () with
      | Some rt -> rt.Runtime_instance.id
      | None -> runtime_id)
    else runtime_id
  in
  Result.map
    (List.map
       (Runtime_thinking_seed.apply (Runtime_inference.for_runtime ~name:seed_runtime_id)))
    (resolve_runtime_providers ~runtime_id ())
;;

module For_testing = struct
  let resolve_runtime_providers = resolve_runtime_providers
end
