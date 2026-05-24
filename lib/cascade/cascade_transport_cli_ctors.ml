(** CLI transport constructors + registration, extracted from
    [cascade_transport.ml] (godfile decomp).

    Builds on prior cascade extractions:
    - [Cascade_transport_cli_overrides] (#17393): cli_transport_overrides
      type + default
    - [Cascade_transport_non_http_registry] (#17428): registry +
      register_non_http_transport
    - [Cascade_transport_cli_config]: provider config readers
    - [Cascade_transport_cli_argv_sanitize]: make_cli_argv_sanitizing_transport
    - [Cascade_transport_runtime_policy_provider]: cli_runtime_mcp_jsons

    Contents:

    - [make_per_call_switch_transport factory] — wraps each
      transport call in its own [Eio.Switch] so leftover pipe/process
      resources release deterministically at call-end, even for
      long-lived keepers.

    - [with_proc_mgr f] — pulls [Process_eio.get_proc_mgr ()] and
      threads it as a [~mgr] arg, surfacing the
      [invalid_runtime_config "proc_mgr" detail] error if the
      process manager isn't initialized.

    - 4 transport constructors: [cli_tool_d_transport_ctor],
      [cli_tool_b_transport_ctor], [json_stream_cli_transport_ctor]
      (used by Provider_k CLI), [cli_tool_a_transport_ctor]. Each reads
      [cli_transport_overrides] from the caller (falling back to
      defaults), builds the provider's transport-specific config,
      and returns a per-call switched transport wrapped in
      [Process_eio.get_proc_mgr]. The agent_code ctor additionally
      wraps in [make_cli_argv_sanitizing_transport] for UTF-8 argv
      hygiene.

    - Top-level [let () = ...] registration block that wires the 4
      ctors into [Cascade_transport_non_http_registry] at module
      load time, keyed by [Llm_provider.Provider_config.Cli_tool_d],
      [.Cli_tool_c], [.Cli_tool_b], [.Cli_tool_d]. The sibling's
      ordering invariant: this block fires *after* the registry's
      Hashtbl is created (sibling depends on
      [Cascade_transport_non_http_registry]), so by the time any
      caller invokes [non_http_transport_of_provider] at runtime,
      the registry is populated. *)

module Cli_overrides = Cascade_transport_cli_overrides
module Cli_config = Cascade_transport_cli_config
module Cli_argv_sanitize = Cascade_transport_cli_argv_sanitize
module Registry = Cascade_transport_non_http_registry
module Label_resolution = Cascade_transport_label_resolution

let make_per_call_switch_transport
      (factory : sw:Eio.Switch.t -> Llm_provider.Llm_transport.t)
  : Llm_provider.Llm_transport.t
  =
  let with_call_switch f = Eio.Switch.run (fun sw -> f (factory ~sw)) in
  { complete_sync =
      (fun req -> with_call_switch (fun transport -> transport.complete_sync req))
  ; complete_stream =
      (fun ?on_telemetry:_ ~on_event req ->
        with_call_switch (fun transport -> transport.complete_stream ~on_event req))
  }
;;

let with_proc_mgr (f : mgr:_ -> Llm_provider.Llm_transport.t) =
  match Process_eio.get_proc_mgr () with
  | Error detail -> Error (Label_resolution.invalid_runtime_config "proc_mgr" detail)
  | Ok mgr -> Ok (f ~mgr)
;;

let cli_tool_d_transport_ctor
      ~(provider_cfg : Llm_provider.Provider_config.t)
      ~runtime_mcp_policy:_
      ~cli_transport_overrides
  =
  let overrides =
    Option.value ~default:Cli_overrides.default_cli_transport_overrides cli_transport_overrides
  in
  let config =
    { Llm_provider.Transport_cli_tool_d.default_config with
      model = Cli_config.cli_model_override provider_cfg.model_id
    ; cwd = overrides.cwd
    ; mcp_config = overrides.claude_mcp_config
    ; allowed_tools = Option.value ~default:[] overrides.claude_allowed_tools
    ; permission_mode = overrides.claude_permission_mode
    ; max_turns = overrides.claude_max_turns
    }
  in
  with_proc_mgr (fun ~mgr ->
    make_per_call_switch_transport (fun ~sw ->
      Llm_provider.Transport_cli_tool_d.create ~sw ~mgr ~config))
;;

let cli_tool_b_transport_ctor
      ~(provider_cfg : Llm_provider.Provider_config.t)
      ~runtime_mcp_policy:_
      ~cli_transport_overrides
  =
  let overrides =
    Option.value ~default:Cli_overrides.default_cli_transport_overrides cli_transport_overrides
  in
  let config =
    { Llm_provider.Transport_cli_tool_c.default_config with
      model = Cli_config.cli_model_override provider_cfg.model_id
    ; cwd = overrides.cwd
    }
  in
  with_proc_mgr (fun ~mgr ->
    make_per_call_switch_transport (fun ~sw ->
      Llm_provider.Transport_cli_tool_c.create ~sw ~mgr ~config))
;;

let cli_tool_a_transport_ctor
      ~provider_cfg:_
      ~runtime_mcp_policy:_
      ~cli_transport_overrides
  =
  let cwd = Option.bind cli_transport_overrides (fun overrides -> overrides.Cli_overrides.cwd) in
  with_proc_mgr (fun ~mgr ->
    Cli_argv_sanitize.make_cli_argv_sanitizing_transport
      (make_per_call_switch_transport (fun ~sw ->
         Llm_provider.Transport_cli_tool_d.create
           ~sw
           ~mgr
           ~config:{ Llm_provider.Transport_cli_tool_d.default_config with cwd })))
;;

let () =
  Registry.register_non_http_transport
    ~kind:Llm_provider.Provider_config.Cli_tool_d
    ~ctor:cli_tool_d_transport_ctor;
  Registry.register_non_http_transport
    ~kind:Llm_provider.Provider_config.Cli_tool_c
    ~ctor:cli_tool_b_transport_ctor;
  Registry.register_non_http_transport
    ~kind:Llm_provider.Provider_config.Cli_tool_d
    ~ctor:cli_tool_a_transport_ctor
;;
