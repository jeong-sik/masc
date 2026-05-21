(** Non-HTTP transport registry + dispatcher, extracted from
    [cascade_transport.ml] (godfile decomp).

    Builds on the [Cascade_transport_cli_overrides] type extraction
    (#17393) — the [non_http_transport_ctor] function-type signature
    references [cli_transport_overrides] which had to move first.

    Three pieces shipped together:

    - [type non_http_transport_ctor] — function type for a CLI
      transport constructor. Each ctor takes ownership of
      [Process_eio.get_proc_mgr] so the registry's value type stays a
      plain function (no row-polymorphic Eio mgr leaks into the
      Hashtbl).

    - [non_http_transport_registry] — the per-process Hashtbl that
      maps each [Llm_provider.Provider_config.provider_kind] to its
      registered ctor. Populated by the parent's top-level
      [let () = register_non_http_transport ~kind ... ~ctor:...]
      block at module load.

    - [register_non_http_transport ~kind ~ctor] — registration entry
      point invoked by the parent's [let () = ...] block.

    - [non_http_transport_of_provider ~sw ~provider_cfg
        ?runtime_mcp_policy ?cli_transport_overrides ()] —
      runtime dispatcher. Looks up [provider_cfg.kind] in the
      registry, invokes the registered ctor, forwards the result.
      Fail-fast policy: missing registration for a subprocess CLI
      kind returns [Error invalid_runtime_config]. Falling through to
      [Ok None] would route the request to the HTTP lane, which
      cannot serve a CLI provider. HTTP-shaped providers correctly
      return [Ok None]; they live behind a different transport
      selector upstream. *)

module Label_resolution = Cascade_transport_label_resolution
module Cli_overrides = Cascade_transport_cli_overrides

type non_http_transport_ctor =
  provider_cfg:Llm_provider.Provider_config.t
  -> runtime_mcp_policy:Llm_provider.Llm_transport.runtime_mcp_policy option
  -> cli_transport_overrides:Cli_overrides.cli_transport_overrides option
  -> (Llm_provider.Llm_transport.t, Agent_sdk.Error.sdk_error) result

let non_http_transport_registry
  : (Llm_provider.Provider_config.provider_kind, non_http_transport_ctor) Hashtbl.t
  =
  Hashtbl.create 8
;;

let register_non_http_transport ~kind ~ctor =
  Hashtbl.replace non_http_transport_registry kind ctor
;;

let non_http_transport_of_provider
      ~(sw : Eio.Switch.t)
      ~(provider_cfg : Llm_provider.Provider_config.t)
      ?runtime_mcp_policy
      ?cli_transport_overrides
      ()
  : (Llm_provider.Llm_transport.t option, Agent_sdk.Error.sdk_error) result
  =
  let _ = sw in
  match Hashtbl.find_opt non_http_transport_registry provider_cfg.kind with
  | Some ctor ->
    (match ctor ~provider_cfg ~runtime_mcp_policy ~cli_transport_overrides with
     | Ok transport -> Ok (Some transport)
     | Error _ as e -> e)
  | None ->
    (* Fail-fast for subprocess CLI kinds that have no registered ctor:
       falling through to [Ok None] would route the request to the HTTP
       lane, which cannot serve a CLI provider. HTTP-shaped providers
       correctly return [Ok None]; they live behind a different transport
       selector upstream. *)
    if Llm_provider.Provider_config.is_subprocess_cli provider_cfg.kind
    then
      Error
        (Label_resolution.invalid_runtime_config
           "non_http_transport_registry"
           (Printf.sprintf
              "no non-HTTP transport constructor registered for subprocess \
               CLI kind %s — registry initializer (cascade_transport.ml \
               top-level [let ()]) is out of sync with the \
               Llm_provider.Provider_config.provider_kind variant"
              (Llm_provider.Provider_config.string_of_provider_kind
                 provider_cfg.kind)))
    else Ok None
;;
