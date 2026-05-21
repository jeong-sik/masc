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

    - 4 transport constructors: [claude_code_transport_ctor],
      [gemini_cli_transport_ctor], [json_stream_cli_transport_ctor]
      (used by Kimi CLI), [codex_cli_transport_ctor]. Each reads
      [cli_transport_overrides] from the caller (falling back to
      defaults), builds the provider's transport-specific config,
      and returns a per-call switched transport wrapped in
      [Process_eio.get_proc_mgr]. The codex ctor additionally
      wraps in [make_cli_argv_sanitizing_transport] for UTF-8 argv
      hygiene.

    - Top-level [let () = ...] registration block that wires the 4
      ctors into [Cascade_transport_non_http_registry] at module
      load time, keyed by [Llm_provider.Provider_config.Claude_code],
      [.Gemini_cli], [.Kimi_cli], [.Codex_cli]. The sibling's
      ordering invariant: this block fires *after* the registry's
      Hashtbl is created (sibling depends on
      [Cascade_transport_non_http_registry]), so by the time any
      caller invokes [non_http_transport_of_provider] at runtime,
      the registry is populated. *)

module Cli_overrides = Cascade_transport_cli_overrides
module Cli_config = Cascade_transport_cli_config
module Cli_argv_sanitize = Cascade_transport_cli_argv_sanitize
module Runtime_policy_provider = Cascade_transport_runtime_policy_provider
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

let claude_code_transport_ctor
      ~(provider_cfg : Llm_provider.Provider_config.t)
      ~runtime_mcp_policy:_
      ~cli_transport_overrides
  =
  let overrides =
    Option.value ~default:Cli_overrides.default_cli_transport_overrides cli_transport_overrides
  in
  let config =
    { Llm_provider.Transport_claude_code.default_config with
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
      Llm_provider.Transport_claude_code.create ~sw ~mgr ~config))
;;

let gemini_cli_transport_ctor
      ~(provider_cfg : Llm_provider.Provider_config.t)
      ~runtime_mcp_policy:_
      ~cli_transport_overrides
  =
  let overrides =
    Option.value ~default:Cli_overrides.default_cli_transport_overrides cli_transport_overrides
  in
  let config =
    { Llm_provider.Transport_gemini_cli.default_config with
      model = Cli_config.cli_model_override provider_cfg.model_id
    ; cwd = overrides.cwd
    ; yolo = Option.value ~default:true overrides.gemini_yolo
    }
  in
  with_proc_mgr (fun ~mgr ->
    make_per_call_switch_transport (fun ~sw ->
      Llm_provider.Transport_gemini_cli.create ~sw ~mgr ~config))
;;

let json_stream_cli_transport_ctor
      ~(provider_cfg : Llm_provider.Provider_config.t)
      ~runtime_mcp_policy
      ~cli_transport_overrides
  =
  let cwd = Option.bind cli_transport_overrides (fun overrides -> overrides.Cli_overrides.cwd) in
  let stdout_idle_timeout_s =
    Option.bind cli_transport_overrides (fun overrides ->
      overrides.Cli_overrides.cli_subprocess_idle_sec)
  in
  let mcp_config_json = Runtime_policy_provider.cli_runtime_mcp_jsons ~base:[] runtime_mcp_policy in
  let model = Cli_config.cli_model_for_provider_config provider_cfg in
  let config_json = Cli_config.cli_runtime_config_json_for_provider provider_cfg in
  let extra_env = Cli_config.cli_direct_binding_extra_env provider_cfg in
  let cli_path =
    Cli_config.cli_command_for_provider_config provider_cfg
    |> Option.value ~default:Json_stream_cli_transport_local.default_config.cli_path
  in
  let process_name = Cli_config.cli_process_name_for_provider_config provider_cfg in
  let config =
    { Json_stream_cli_transport_local.default_config with
      cli_path
    ; process_name
    ; model
    ; cwd
    ; config_json
    ; mcp_config_json
    ; extra_env
    ; stdout_idle_timeout_s
    }
  in
  with_proc_mgr (fun ~mgr ->
    make_per_call_switch_transport (fun ~sw ->
      Json_stream_cli_transport_local.create ~sw ~mgr ~config))
;;

let codex_cli_transport_ctor
      ~provider_cfg:_
      ~runtime_mcp_policy:_
      ~cli_transport_overrides
  =
  let cwd = Option.bind cli_transport_overrides (fun overrides -> overrides.Cli_overrides.cwd) in
  with_proc_mgr (fun ~mgr ->
    Cli_argv_sanitize.make_cli_argv_sanitizing_transport
      (make_per_call_switch_transport (fun ~sw ->
         Llm_provider.Transport_codex_cli.create
           ~sw
           ~mgr
           ~config:{ Llm_provider.Transport_codex_cli.default_config with cwd })))
;;

let () =
  Registry.register_non_http_transport
    ~kind:Llm_provider.Provider_config.Claude_code
    ~ctor:claude_code_transport_ctor;
  Registry.register_non_http_transport
    ~kind:Llm_provider.Provider_config.Gemini_cli
    ~ctor:gemini_cli_transport_ctor;
  Registry.register_non_http_transport
    ~kind:Llm_provider.Provider_config.Kimi_cli
    ~ctor:json_stream_cli_transport_ctor;
  Registry.register_non_http_transport
    ~kind:Llm_provider.Provider_config.Codex_cli
    ~ctor:codex_cli_transport_ctor
;;
