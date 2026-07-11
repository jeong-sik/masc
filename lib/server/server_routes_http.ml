
include Server_routes_http_common
include Server_routes_http_pages
include Server_routes_http_runtime
include Server_routes_http_keeper_stream

module Http = Http_server_eio

let make_routes ~port ~host:_ ~sw ~clock =
  (* Register connectors before routes are wired up *)
  Channel_gate_connector.register (module Channel_gate_discord_state);
  Channel_gate_connector.register (module Channel_gate_imessage_state);
  Channel_gate_connector.register (module Channel_gate_slack_state);
  Channel_gate_connector.register (module Channel_gate_telegram_state);
  (* Tier K1: bind the multimodal workspace getter so the dashboard
     reads the live keeper-side workspace instead of [Workspace.empty].
     Idempotent — calling [bind_workspace_getter] twice just replaces
     the callback. *)
  Server_routes_http_routes_multimodal.bind_workspace_getter
    Multimodal.Workspace_holder.get;
  Http.Router.create ()
  |> Server_routes_http_routes_frontend.add_routes ~port ~sw ~clock
  |> Server_routes_http_routes_workspace.add_routes
  |> Server_routes_http_routes_dashboard.add_routes ~sw ~clock
  |> Server_routes_http_routes_provider_runs.add_routes ~sw
  |> Server_routes_http_routes_verification.add_routes
  |> Server_routes_http_routes_attribution.add_routes
  |> Server_routes_http_routes_activity.add_routes ~sw ~clock
  |> Server_routes_http_routes_artifacts.add_routes
  |> Server_routes_http_routes_voice.add_routes
  |> Server_routes_http_routes_multimodal.add_routes
  |> Server_routes_http_routes_autonomous.add_routes
  |> Server_routes_http_routes_resilience.add_routes
  |> Server_routes_http_routes_channel_gate.add_routes ~sw ~clock
  |> Server_routes_http_routes_sidecar.add_routes ~sw ~clock
  |> Server_routes_http_routes_repositories.add_routes
  |> Server_routes_http_routes_workspace.add_routes
  |> Server_ide_http.add_routes
  |> Server_ide_lsp_proxy.add_routes ~sw ~clock
  |> Server_routes_http_routes_keeper_repos.add_routes
