(** CLI-transport override record + default, extracted from
    [cascade_transport.ml] (godfile decomp).

    [cli_transport_overrides] is the public record of per-keeper
    overrides honoured by the cascade transport layer when binding a
    subprocess CLI provider (Claude Code / Provider_f CLI / Codex CLI /
    Provider_c CLI). Each field is honoured by exactly one provider kind;
    missing fields fall back to the transport's [default_config].

    [default_cli_transport_overrides] is the no-overrides record used
    as the [Option.value ~default] target by the CLI transport ctors
    when no [?cli_transport_overrides] is supplied.

    This sibling owns the canonical definition; the parent re-exports
    via a transparent type alias so existing callers
    ([Cascade_runner.cli_transport_overrides] alias and the keeper
    layer's record-typed forwarders) keep working unchanged.

    Extracted as an enabling step for follow-up extraction of the
    [non_http_transport_registry] dispatcher — which references this
    type via its [non_http_transport_ctor] function-type signature. *)

type cli_transport_overrides =
  { cwd : string option
  ; claude_mcp_config : string option
  ; claude_allowed_tools : string list option
  ; claude_permission_mode : string option
  ; claude_max_turns : int option
  ; gemini_yolo : bool option
  ; cli_subprocess_idle_sec : float option
    (* When [Some s], the CLI subprocess is aborted via SIGINT if no
     stdout line arrives within [s] seconds. Currently honoured only
     by [Json_stream_cli_transport_local], which calls
     [Cli_common_subprocess.run_stream_lines] directly. The other CLI
     transports (cli_tool_d, cli_tool_b, cli_tool_a) route through
     agent_sdk [Transport_*_cli.create] whose configs do not yet
     expose [stdout_idle_timeout_s]; an OAS upstream change is needed
     to honour this field there. *)
  }

let default_cli_transport_overrides =
  { cwd = None
  ; claude_mcp_config = None
  ; claude_allowed_tools = None
  ; claude_permission_mode = None
  ; claude_max_turns = None
  ; gemini_yolo = None
  ; cli_subprocess_idle_sec = None
  }
;;
