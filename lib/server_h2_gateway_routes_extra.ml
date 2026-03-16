[@@@warning "-32-33-69"]

open Types
open Server_utils
open Server_auth
open Server_tts_proxy
open Server_trpg_rest
open Server_dashboard_http
open Server_routes_http
open Server_h2_gateway_helpers

(* Dispatch TRPG, board, governance, voice, karma, and static asset routes.
   Returns [true] if the route was handled, [false] otherwise. *)
let dispatch ~h2_reqd ~httpun_request ~cors ~path
    (httpun_meth : [ `GET | `POST | `DELETE | `OPTIONS | `PUT | `HEAD
                    | `CONNECT | `TRACE | `Other of string ]) =
  let trpg_respond_result json_result =
    match json_result with
    | Ok json ->
        h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
    | Error (`Bad_request, msg) ->
        h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
          ~status:`Bad_request ~extra_headers:cors
    | Error (`Internal_server_error, msg) ->
        h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
          ~status:`Internal_server_error ~extra_headers:cors
  in
  match httpun_meth, path with
  | `POST, "/api/v1/trpg/events" ->
      let state = get_server_state () in
      let base_dir = state.Mcp_server.room_config.base_path in
      h2_read_body h2_reqd (fun body_str ->
        match trpg_append_event_json ~base_dir ~body_str with
        | Ok json ->
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~status:`Created
              ~extra_headers:cors
        | Error (`Bad_request, msg) ->
            h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
              ~status:`Bad_request ~extra_headers:cors
        | Error (`Internal_server_error, msg) ->
            h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
              ~status:`Internal_server_error ~extra_headers:cors);
      true

  | `GET, "/api/v1/trpg/state" ->
      let state = get_server_state () in
      let base_dir = state.Mcp_server.room_config.base_path in
      let room_id =
        trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
      let rule_module =
        Option.value ~default:"dnd5e-lite" (query_param httpun_request "rule_module")
      in
      trpg_respond_result (trpg_derive_state_json ~base_dir ~room_id ~rule_module);
      true

  | `GET, "/api/v1/trpg/lobby/catalog" ->
      let state = get_server_state () in
      let base_dir = state.Mcp_server.room_config.base_path in
      let room_id =
        trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
      let rule_module =
        Option.value ~default:"dnd5e-lite"
          (query_param httpun_request "rule_module")
      in
      trpg_respond_result
        (trpg_lobby_catalog_json ~base_dir ~config:state.Mcp_server.room_config
           ~room_id ~rule_module);
      true

  | `GET, "/api/v1/trpg/lobby/preflight" ->
      let state = get_server_state () in
      let base_dir = state.Mcp_server.room_config.base_path in
      let room_id =
        trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
      let rule_module =
        Option.value ~default:"dnd5e-lite"
          (query_param httpun_request "rule_module")
      in
      let dm_keeper = query_param httpun_request "dm" in
      let player_keepers =
        query_param httpun_request "players" |> Option.value ~default:""
        |> split_csv_nonempty
      in
      let models =
        query_param httpun_request "models" |> Option.value ~default:""
        |> split_csv_nonempty
      in
      trpg_respond_result
        (trpg_lobby_preflight_json ~base_dir ~config:state.Mcp_server.room_config
           ~room_id ~rule_module ~dm_keeper ~player_keepers ~models);
      true

  | `GET, "/api/v1/trpg/overview" ->
      let state = get_server_state () in
      let base_dir = state.Mcp_server.room_config.base_path in
      let room_id =
        trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
      let rule_module =
        Option.value ~default:"dnd5e-lite"
          (query_param httpun_request "rule_module")
      in
      trpg_respond_result (trpg_overview_json ~base_dir ~room_id ~rule_module);
      true

  | `GET, "/api/v1/trpg/control/state" ->
      let state = get_server_state () in
      let base_dir = state.Mcp_server.room_config.base_path in
      let room_id =
        trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
      let rule_module =
        Option.value ~default:"dnd5e-lite"
          (query_param httpun_request "rule_module")
      in
      trpg_respond_result (trpg_control_state_json ~base_dir ~room_id ~rule_module);
      true

  | `GET, "/api/v1/trpg/models" ->
      h2_respond_json h2_reqd
        (Yojson.Safe.to_string (trpg_available_models_json ()))
        ~extra_headers:cors;
      true

  | `POST, "/api/v1/trpg/dice/roll" ->
      let state = get_server_state () in
      let base_dir = state.Mcp_server.room_config.base_path in
      h2_read_body h2_reqd (fun body_str ->
        match trpg_dice_roll_json ~base_dir ~body_str with
        | Ok json ->
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~status:`Created
              ~extra_headers:cors
        | Error (`Bad_request, msg) ->
            h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
              ~status:`Bad_request ~extra_headers:cors
        | Error (`Internal_server_error, msg) ->
            h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
              ~status:`Internal_server_error ~extra_headers:cors);
      true

  | `POST, "/api/v1/trpg/turns/advance" ->
      let state = get_server_state () in
      let base_dir = state.Mcp_server.room_config.base_path in
      h2_read_body h2_reqd (fun body_str ->
        match trpg_turn_advance_json ~base_dir ~body_str with
        | Ok json ->
            h2_respond_json h2_reqd (Yojson.Safe.to_string json)
              ~extra_headers:cors
        | Error (`Bad_request, msg) ->
            h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
              ~status:`Bad_request ~extra_headers:cors
        | Error (`Internal_server_error, msg) ->
            h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
              ~status:`Internal_server_error ~extra_headers:cors);
      true

  | `POST, "/api/v1/trpg/rounds/run" ->
      let state = get_server_state () in
      h2_read_body h2_reqd (fun body_str ->
        let agent_name =
          Option.value ~default:"dashboard"
            (agent_from_request httpun_request)
        in
        match Eio_context.get_switch_opt (), Eio_context.get_clock_opt () with
        | Some sw, Some clock -> (
            match
              trpg_round_run_json ~state ~agent_name ~sw ~clock
                ~idempotency_key:
                  (get_header_any_case httpun_request.headers "idempotency-key")
                ~body_str
            with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                  ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors)
        | _ ->
            h2_respond_json h2_reqd
              (Yojson.Safe.to_string
                 (trpg_error_json "trpg runtime not initialized"))
              ~status:`Internal_server_error ~extra_headers:cors);
      true

  | `GET, "/api/v1/trpg/stream" ->
      let state = get_server_state () in
      let base_dir = state.Mcp_server.room_config.base_path in
      let room_id = Option.value ~default:"" (query_param httpun_request "room_id") in
      let after_seq = int_query_param httpun_request "after_seq" ~default:0 in
      let event_type_filter = query_param httpun_request "event_type" in
      (match trpg_stream_json ~base_dir ~room_id ~after_seq ~event_type_filter with
      | Ok json ->
          let normalized = trpg_normalize_events_json ~default_room_id:room_id json in
          h2_respond_json h2_reqd (Yojson.Safe.to_string normalized) ~extra_headers:cors
      | Error (`Bad_request, msg) ->
          h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
            ~status:`Bad_request ~extra_headers:cors
      | Error (`Internal_server_error, msg) ->
          h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
            ~status:`Internal_server_error ~extra_headers:cors);
      true

  | `GET, "/api/v1/trpg/timeline" ->
      let state = get_server_state () in
      let base_dir = state.Mcp_server.room_config.base_path in
      let room_id =
        trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
      let after_seq = int_query_param httpun_request "after_seq" ~default:0 in
      let event_type_filter = query_param httpun_request "event_type" in
      let actor_filter = query_param httpun_request "actor" in
      let phase_filter = query_param httpun_request "phase" in
      let limit =
        int_query_param httpun_request "limit" ~default:50
        |> clamp ~min_v:1 ~max_v:200
      in
      trpg_respond_result
        (trpg_timeline_json ~base_dir ~room_id ~after_seq ~event_type_filter
           ~actor_filter ~phase_filter ~limit);
      true

  | `GET, "/api/v1/trpg/stream/sse" ->
      let state = get_server_state () in
      let base_dir = state.Mcp_server.room_config.base_path in
      let room_id = Option.value ~default:"" (query_param httpun_request "room_id") in
      let event_type_filter = query_param httpun_request "event_type" in
      let room_id_trimmed = String.trim room_id in
      if room_id_trimmed = "" then
        h2_respond_json h2_reqd
          (Yojson.Safe.to_string (trpg_error_json "room_id is required"))
          ~status:`Bad_request ~extra_headers:cors
      else begin
        match trpg_parse_event_type_filter event_type_filter with
        | Error (`Bad_request, msg) ->
            h2_respond_json h2_reqd
              (Yojson.Safe.to_string (trpg_error_json msg))
              ~status:`Bad_request ~extra_headers:cors
        | Ok event_type_opt ->
            let h2_headers = (H2.Reqd.request h2_reqd).headers in
            let last_event_id =
              match H2.Headers.get h2_headers "last-event-id" with
              | Some id -> (try int_of_string id with Failure _ -> 0)
              | None -> 0
            in
            let headers = H2.Headers.of_list ([
              ("content-type", "text/event-stream");
              ("cache-control", "no-cache");
            ] @ cors) in
            let response = H2.Response.create ~headers `OK in
            let writer = H2.Reqd.respond_with_streaming
              ~flush_headers_immediately:true h2_reqd response in
            let closed = ref false in
            let last_seq = ref last_event_id in
            let send data =
              if !closed || H2.Body.Writer.is_closed writer then begin
                closed := true; false
              end else begin
                H2.Body.Writer.write_string writer data;
                H2.Body.Writer.flush writer ignore;
                true
              end
            in
            let init_comment =
              Printf.sprintf ": TRPG SSE stream for room %s (after_seq=%d)\nretry: 3000\n\n"
                room_id_trimmed !last_seq in
            ignore (send init_comment);
            (match
               (if !last_seq > 0 then
                  Trpg_engine_store_sqlite.read_events_after
                    ~base_dir ~room_id:room_id_trimmed ~after_seq:!last_seq
                else
                  Trpg_engine_store_sqlite.read_events
                    ~base_dir ~room_id:room_id_trimmed)
             with
             | Ok events ->
                 let events = match event_type_opt with
                   | None -> events
                   | Some et ->
                       List.filter (fun (ev : Trpg_engine_event.t) ->
                         ev.event_type = et) events
                 in
                 List.iter (fun ev ->
                   if not !closed then begin
                     ignore (send (trpg_event_to_sse ev));
                     last_seq := max !last_seq ev.Trpg_engine_event.seq
                   end) events
             | Error _ -> ());
            (match Eio_context.get_switch_opt (), Eio_context.get_clock_opt () with
             | Some sw, Some clock ->
                 Eio.Fiber.fork ~sw (fun () ->
                   let is_cancelled = function
                     | Eio.Cancel.Cancelled _ -> true | _ -> false in
                   let keepalive_counter = ref 0 in
                   let polls_per_keepalive =
                     max 1 (int_of_float (trpg_sse_keepalive_s /. trpg_sse_poll_interval_s)) in
                   let rec loop () =
                     if not !closed then begin
                       (try Eio.Time.sleep clock trpg_sse_poll_interval_s
                        with exn -> if is_cancelled exn then raise exn);
                       if not !closed then begin
                         (match
                            Trpg_engine_store_sqlite.read_events_after
                              ~base_dir ~room_id:room_id_trimmed ~after_seq:!last_seq
                          with
                          | Ok events ->
                              let events = match event_type_opt with
                                | None -> events
                                | Some et ->
                                    List.filter (fun (ev : Trpg_engine_event.t) ->
                                      ev.event_type = et) events
                              in
                              List.iter (fun ev ->
                                if not !closed then begin
                                  if not (send (trpg_event_to_sse ev)) then
                                    closed := true
                                  else
                                    last_seq := max !last_seq
                                      ev.Trpg_engine_event.seq
                                end) events
                          | Error _ -> ());
                         incr keepalive_counter;
                         if !keepalive_counter >= polls_per_keepalive then begin
                           keepalive_counter := 0;
                           if not !closed then ignore (send ": keepalive\n\n")
                         end
                       end;
                       loop ()
                     end else
                       H2.Body.Writer.close writer
                   in
                   try loop () with exn ->
                     if is_cancelled exn then raise exn
                     else
                       Printf.eprintf "[TRPG-SSE/H2] poll error for room %s: %s\n%!"
                         room_id_trimmed (Printexc.to_string exn))
             | _ ->
                 ignore (send "event: error\ndata: {\"error\":\"server not ready\"}\n\n");
                 H2.Body.Writer.close writer)
      end;
      true

  | `POST, "/api/v1/trpg/actors/spawn" ->
      let state = get_server_state () in
      let base_dir = state.Mcp_server.room_config.base_path in
      h2_read_body h2_reqd (fun body_str ->
        match
          trpg_actor_spawn_json ~base_dir
            ~idempotency_key:
              (get_header_any_case httpun_request.headers "idempotency-key")
            ~body_str
        with
        | Ok json ->
            h2_respond_json h2_reqd (Yojson.Safe.to_string json)
              ~status:`Created ~extra_headers:cors
        | Error (`Bad_request, msg) ->
            h2_respond_json h2_reqd
              (Yojson.Safe.to_string (trpg_error_json msg))
              ~status:`Bad_request ~extra_headers:cors
        | Error (`Internal_server_error, msg) ->
            h2_respond_json h2_reqd
              (Yojson.Safe.to_string (trpg_error_json msg))
              ~status:`Internal_server_error ~extra_headers:cors);
      true

  | `POST, "/api/v1/trpg/actors/claim" ->
      let state = get_server_state () in
      let base_dir = state.Mcp_server.room_config.base_path in
      h2_read_body h2_reqd (fun body_str ->
        match trpg_actor_claim_json ~base_dir ~body_str with
        | Ok json ->
            h2_respond_json h2_reqd (Yojson.Safe.to_string json)
              ~status:`Created ~extra_headers:cors
        | Error (`Bad_request, msg) ->
            h2_respond_json h2_reqd
              (Yojson.Safe.to_string (trpg_error_json msg))
              ~status:`Bad_request ~extra_headers:cors
        | Error (`Internal_server_error, msg) ->
            h2_respond_json h2_reqd
              (Yojson.Safe.to_string (trpg_error_json msg))
              ~status:`Internal_server_error ~extra_headers:cors);
      true

  | `POST, "/api/v1/trpg/actors/release" ->
      let state = get_server_state () in
      let base_dir = state.Mcp_server.room_config.base_path in
      h2_read_body h2_reqd (fun body_str ->
        match trpg_actor_release_json ~base_dir ~body_str with
        | Ok json ->
            h2_respond_json h2_reqd (Yojson.Safe.to_string json)
              ~extra_headers:cors
        | Error (`Bad_request, msg) ->
            h2_respond_json h2_reqd
              (Yojson.Safe.to_string (trpg_error_json msg))
              ~status:`Bad_request ~extra_headers:cors
        | Error (`Internal_server_error, msg) ->
            h2_respond_json h2_reqd
              (Yojson.Safe.to_string (trpg_error_json msg))
              ~status:`Internal_server_error ~extra_headers:cors);
      true

  | `POST, "/api/v1/trpg/tts" ->
      h2_read_body h2_reqd (fun body_str ->
        match trpg_tts_proxy ~body_str with
        | Ok audio_bytes ->
            h2_respond_bytes ~content_type:"audio/mpeg"
              ~extra_headers:cors h2_reqd audio_bytes
        | Error (`Bad_request, msg) ->
            h2_respond_json h2_reqd
              (Yojson.Safe.to_string (trpg_error_json msg))
              ~status:`Bad_request ~extra_headers:cors
        | Error (`Internal_server_error, msg) ->
            h2_respond_json h2_reqd
              (Yojson.Safe.to_string (trpg_error_json msg))
              ~status:`Internal_server_error ~extra_headers:cors
        | Error (_, msg) ->
            h2_respond_json h2_reqd
              (Yojson.Safe.to_string (trpg_error_json msg))
              ~status:`Internal_server_error ~extra_headers:cors);
      true

  | `GET, "/api/v1/voice/config" ->
      let status, json = voice_config_payload () in
      let status =
        match status with `OK -> `OK | `Error -> `Internal_server_error
      in
      h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~status
        ~extra_headers:cors;
      true

  | `GET, "/api/v1/governance/cases" ->
      let state = get_server_state () in
      let base_path = state.Mcp_server.room_config.base_path in
      let json = governance_cases_json httpun_request ~base_path in
      h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors;
      true

  | `GET, p
    when String.length p > 23
         && String.sub p 0 23 = "/api/v1/governance/cases/" ->
      let state = get_server_state () in
      let case_id = String.sub p 23 (String.length p - 23) in
      let base_path = state.Mcp_server.room_config.base_path in
      let (status, json) = governance_case_detail_json ~base_path ~case_id in
      h2_respond_json h2_reqd (Yojson.Safe.to_string json)
        ~status ~extra_headers:cors;
      true

  | `GET, "/api/v1/board" ->
      let hearth = query_param httpun_request "hearth" in
      let sort_by = board_sort_order_of_request httpun_request in
      let exclude_system = bool_query_param httpun_request "exclude_system" ~default:false in
      let limit = int_query_param httpun_request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
      let offset = int_query_param httpun_request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
      let fetch_limit = board_fetch_limit ~exclude_system ~limit ~offset in
      let posts = Board_dispatch.list_posts ?hearth ~sort_by ~limit:fetch_limit () in
      let posts = filter_board_posts ~exclude_system posts in
      let karma_map = Board_dispatch.get_all_karma () in
      let get_karma author =
        Option.value ~default:0 (List.assoc_opt author karma_map)
      in
      let paged = posts |> drop offset |> take limit in
      let posts_json = List.map (fun (p : Board.post) ->
        let author = Board.Agent_id.to_string p.author in
        board_post_dashboard_json ~author_karma:(get_karma author) p
      ) paged in
      let json = `Assoc [
        ("posts", `List posts_json);
        ("count", `Int (List.length posts_json));
        ("limit", `Int limit);
        ("offset", `Int offset);
        ("sort_by", `String (board_sort_label sort_by));
      ] in
      h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors;
      true

  | `GET, "/api/v1/board/hearths" ->
      let hearths = Board_dispatch.list_hearths () in
      let json = `Assoc [
        ("hearths", `List (List.map (fun (name, count) ->
          `Assoc [("name", `String name); ("count", `Int count)]
        ) hearths));
      ] in
      h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors;
      true

  | `GET, "/api/v1/board/flairs" ->
      let flairs = List.map Board.flair_to_yojson Board.available_flairs in
      let json = `Assoc [("flairs", `List flairs)] in
      h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors;
      true

  | `GET, p when String.length p > 14 && String.sub p 0 14 = "/api/v1/board/" ->
      let post_id = String.sub p 14 (String.length p - 14) in
      let format = Option.value ~default:"nested" (query_param httpun_request "format") in
      let (status, body) = board_post_detail_json ~response_format:format ~post_id in
      h2_respond_json h2_reqd body ~status ~extra_headers:cors;
      true

  | `GET, "/api/v1/karma" ->
      let karma_list = Board_dispatch.get_all_karma () in
      let sorted = List.sort (fun (_, a) (_, b) -> compare b a) karma_list in
      let json = `Assoc [
        ("karma", `List (List.map (fun (agent, k) ->
          `Assoc [("agent", `String agent); ("karma", `Int k)]
        ) sorted));
      ] in
      h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors;
      true

  | `GET, "/static/css/middleware.css" ->
      (match read_file (playground_asset_path "static/css/middleware.css") with
       | Ok body ->
           let headers = H2.Headers.of_list [
             ("content-type", "text/css; charset=utf-8");
             ("content-length", string_of_int (String.length body));
           ] in
           let response = H2.Response.create ~headers `OK in
           let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
           H2.Body.Writer.write_string writer body;
           H2.Body.Writer.close writer
       | Error _ -> h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found);
      true

  | `GET, "/static/js/middleware.js" ->
      (match read_file (playground_asset_path "static/js/middleware.js") with
       | Ok body ->
           let headers = H2.Headers.of_list [
             ("content-type", "application/javascript; charset=utf-8");
             ("content-length", string_of_int (String.length body));
           ] in
           let response = H2.Response.create ~headers `OK in
           let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
           H2.Body.Writer.write_string writer body;
           H2.Body.Writer.close writer
       | Error _ -> h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found);
      true

  | `GET, p when String.length p > 18
               && String.sub p 0 18 = "/dashboard/assets/" ->
      let filename = String.sub p 18 (String.length p - 18) in
      if not (Web_dashboard.is_safe_asset_relative_path filename) then
        h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found
      else
        let file_path = Filename.concat (dashboard_asset_root ()) ("assets/" ^ filename) in
        (match read_file file_path with
         | Ok body ->
             let ct = asset_content_type filename in
             let headers = H2.Headers.of_list [
               ("content-type", ct);
               ("content-length", string_of_int (String.length body));
               ("cache-control", "public, max-age=31536000, immutable");
             ] in
             let response = H2.Response.create ~headers `OK in
             let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
             H2.Body.Writer.write_string writer body;
             H2.Body.Writer.close writer
         | Error _ -> h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found);
      true

  | _ -> false
