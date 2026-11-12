
include Server_routes_http_common
include Server_routes_http_pages
include Server_routes_http_runtime
include Server_routes_http_keeper_stream

module Http = Http_server_eio

let make_routes_with_transport ~port:_ ~host:_ ~sw ~transport_sw ~clock =
  (* Register connectors before routes are wired up *)
  Channel_gate_connector.register (module Channel_gate_discord_state);
  Channel_gate_connector.register (module Channel_gate_imessage_state);
  Channel_gate_connector.register (module Channel_gate_slack_state);
  Channel_gate_connector.register (module Channel_gate_telegram_state);
  Http.Router.create ()
  |> Server_routes_http_routes_frontend.add_routes ~clock
  |> Server_oauth_http.add_routes
  |> Server_keeper_oauth_http.add_routes ~clock
  |> Server_routes_http_routes_dashboard.add_routes ~sw ~clock
  |> Server_routes_http_routes_provider_runs.add_routes ~sw
  |> Server_routes_http_routes_verification.add_routes
  |> Server_routes_http_routes_attribution.add_routes
  |> Server_routes_http_routes_activity.add_routes ~sw ~clock
  |> Server_routes_http_routes_presets.add_routes
  |> Server_routes_http_routes_lane_addons.add_routes ~sw ~clock
  |> Server_routes_http_routes_msx.add_routes
  |> Server_routes_http_routes_dos.add_routes
  |> Server_routes_http_routes_play_page.add_routes
  |> Server_routes_http_routes_play_room.add_routes
  |> Server_routes_http_routes_play_guide.add_routes
  |> Server_routes_http_routes_play_pad.add_routes
  |> Server_routes_http_routes_play.add_routes
  |> Server_routes_http_routes_artifacts.add_routes
  |> Server_routes_http_routes_published_artifacts.add_routes
  |> Server_routes_http_routes_artifact_drafts.add_routes
  |> Server_routes_http_routes_artifact_app_data.add_routes
  |> Server_routes_http_routes_artifact_draft_live.add_routes
  |> Server_routes_http_routes_voice.add_routes
  |> Server_routes_http_routes_play_screen.add_routes
  |> Server_routes_http_routes_channel_gate.add_routes ~sw ~clock
  |> Server_routes_http_routes_fleet_stream.add_routes ~sw ~clock
  |> Server_routes_http_routes_log_stream.add_routes ~sw ~clock
  |> Server_tool_metrics_series_stream.add_routes ~sw ~clock
  |> Server_routes_http_routes_repositories.add_routes
  |> Server_routes_http_routes_workspace.add_routes
  |> Server_ide_http.add_routes
  |> Server_ide_lsp_proxy.add_routes ~transport_sw ~clock

let make_routes ~port ~host ~sw ~clock =
  make_routes_with_transport ~port ~host ~sw ~transport_sw:sw ~clock
;;
