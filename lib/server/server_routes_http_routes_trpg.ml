[@@@warning "-32-33-69"]

open Types
open Server_utils
open Server_auth
open Server_tts_proxy
open Server_trpg_rest
open Server_dashboard_http
open Server_routes_http_common
open Server_routes_http_pages
open Server_routes_http_runtime
open Server_routes_http_keeper_stream

module Http = Http_server_eio
module Mcp_eio = Mcp_server_eio
module Common = Server_routes_http_common
module Pages = Server_routes_http_pages
module Runtime = Server_routes_http_runtime
module Keeper_stream = Server_routes_http_keeper_stream

let add_routes router =
  router
  |> Http.Router.get "/api/v1/trpg/events" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = Option.value ~default:"" (query_param req "room_id") in
         let after_seq = int_query_param req "after_seq" ~default:0 in
         let event_type_filter = query_param req "event_type" in
         match trpg_read_events_json ~base_dir ~room_id ~after_seq ~event_type_filter with
         | Ok json ->
             let normalized = trpg_normalize_events_json ~default_room_id:room_id json in
             respond_json_with_cors request reqd (Yojson.Safe.to_string normalized)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/events" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_append_event_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors ~status:`Created request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
         )
       ) request reqd)
  |> Http.Router.get "/api/v1/room/current" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let config = state.Mcp_server.room_config in
         let room_id = Option.value ~default:"default" (Room.read_current_room config) in
         let json = `Assoc [("ok", `Bool true); ("room_id", `String room_id)] in
         respond_json_with_cors request reqd (Yojson.Safe.to_string json)
       ) request reqd)
  |> Http.Router.post "/api/v1/room/current" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let config = state.Mcp_server.room_config in
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
              (match trpg_parse_required_string "room_id" json with
               | Error (`Bad_request, msg) ->
                   respond_json_with_cors ~status:`Bad_request request reqd
                     (Yojson.Safe.to_string (trpg_error_json msg))
               | Ok room_id ->
                   let room_id = String.trim room_id in
                   if room_id = "" then
                     respond_json_with_cors ~status:`Bad_request request reqd
                       (Yojson.Safe.to_string
                          (trpg_error_json "room_id cannot be empty"))
                   else (
                     Room.write_current_room config room_id;
                     Room.ensure_room_entry config room_id;
                     let response = `Assoc [("ok", `Bool true); ("room_id", `String room_id)] in
                     respond_json_with_cors request reqd (Yojson.Safe.to_string response)))
           with
           | Yojson.Json_error msg ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string
                    (trpg_error_json (Printf.sprintf "invalid json: %s" msg))))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/state" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         match trpg_derive_state_json ~base_dir ~room_id ~rule_module with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/lobby/catalog" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         match
           trpg_lobby_catalog_json ~base_dir ~config:state.Mcp_server.room_config ~room_id
             ~rule_module
         with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/lobby/preflight" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         let dm_keeper = query_param req "dm" in
         let player_keepers =
           query_param req "players" |> Option.value ~default:"" |> split_csv_nonempty
         in
         let models =
           query_param req "models" |> Option.value ~default:"" |> split_csv_nonempty
         in
         match
           trpg_lobby_preflight_json ~base_dir ~config:state.Mcp_server.room_config ~room_id
             ~rule_module ~dm_keeper ~player_keepers ~models
         with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/overview" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         match trpg_overview_json ~base_dir ~room_id ~rule_module with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/control/state" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let rule_module =
           Option.value ~default:"dnd5e-lite" (query_param req "rule_module")
         in
         match trpg_control_state_json ~base_dir ~room_id ~rule_module with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/models" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         respond_json_with_cors request reqd
           (Yojson.Safe.to_string (trpg_available_models_json ()))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/dice/roll" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_dice_roll_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors ~status:`Created request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
         )
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/turns/advance" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_turn_advance_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors request reqd (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
         )
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/rounds/run" (fun request reqd ->
       with_public_read (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           let agent_name =
             Option.value ~default:"dashboard" (agent_from_request req)
           in
           match Eio_context.get_switch_opt (), Eio_context.get_clock_opt () with
           | Some sw, Some clock -> (
               match
                 trpg_round_run_json
                   ~state
                   ~agent_name
                   ~sw
                   ~clock
                   ~idempotency_key:
                     (get_header_any_case req.Httpun.Request.headers "idempotency-key")
                   ~body_str
               with
               | Ok json ->
                   respond_json_with_cors request reqd (Yojson.Safe.to_string json)
               | Error (`Bad_request, msg) ->
                   respond_json_with_cors ~status:`Bad_request request reqd
                     (Yojson.Safe.to_string (trpg_error_json msg))
               | Error (`Internal_server_error, msg) ->
                   respond_json_with_cors ~status:`Internal_server_error request reqd
                     (Yojson.Safe.to_string (trpg_error_json msg)))
           | _ ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string
                    (trpg_error_json "trpg runtime not initialized"))
         )
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/stream" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = Option.value ~default:"" (query_param req "room_id") in
         let after_seq = int_query_param req "after_seq" ~default:0 in
         let event_type_filter = query_param req "event_type" in
         match trpg_stream_json ~base_dir ~room_id ~after_seq ~event_type_filter with
         | Ok json ->
             let normalized = trpg_normalize_events_json ~default_room_id:room_id json in
             respond_json_with_cors request reqd (Yojson.Safe.to_string normalized)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/timeline" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = trpg_resolve_room_id ~config:state.Mcp_server.room_config req in
         let after_seq = int_query_param req "after_seq" ~default:0 in
         let event_type_filter = query_param req "event_type" in
         let actor_filter = query_param req "actor" in
         let phase_filter = query_param req "phase" in
         let limit = int_query_param req "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
         match
           trpg_timeline_json ~base_dir ~room_id ~after_seq ~event_type_filter
             ~actor_filter ~phase_filter ~limit
         with
         | Ok json ->
             respond_json_with_cors request reqd (Yojson.Safe.to_string json)
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
       ) request reqd)
  |> Http.Router.get "/api/v1/trpg/stream/sse" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         let room_id = Option.value ~default:"" (query_param req "room_id") in
         let event_type_filter = query_param req "event_type" in
         handle_trpg_sse ~base_dir ~room_id ~event_type_filter request reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/actors/spawn" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match
             trpg_actor_spawn_json ~base_dir
               ~idempotency_key:
                 (get_header_any_case req.Httpun.Request.headers "idempotency-key")
               ~body_str
           with
           | Ok json ->
               respond_json_with_cors ~status:`Created request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg)))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/actors/claim" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_actor_claim_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors ~status:`Created request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg)))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/actors/release" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_dir = state.Mcp_server.room_config.base_path in
         Http.Request.read_body_async reqd (fun body_str ->
           match trpg_actor_release_json ~base_dir ~body_str with
           | Ok json ->
               respond_json_with_cors ~status:`Created request reqd
                 (Yojson.Safe.to_string json)
           | Error (`Bad_request, msg) ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg))
           | Error (`Internal_server_error, msg) ->
               respond_json_with_cors ~status:`Internal_server_error request reqd
                 (Yojson.Safe.to_string (trpg_error_json msg)))
       ) request reqd)
  |> Http.Router.post "/api/v1/trpg/tts" (fun request reqd ->
       Http.Request.read_body_async reqd (fun body_str ->
         match trpg_tts_proxy ~body_str with
         | Ok audio_bytes ->
             let origin = get_origin request in
             Http.Response.bytes ~content_type:"audio/mpeg"
               ~headers:(cors_headers origin) audio_bytes reqd
         | Error (`Bad_request, msg) ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (`Internal_server_error, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))
         | Error (_, msg) ->
             respond_json_with_cors ~status:`Internal_server_error request reqd
               (Yojson.Safe.to_string (trpg_error_json msg))))
  |> Http.Router.get "/api/v1/voice/config" (fun request reqd ->
       let status, json = voice_config_payload () in
       let status =
         match status with `OK -> `OK | `Error -> `Internal_server_error
       in
       respond_json_with_cors ~status request reqd (Yojson.Safe.to_string json))
