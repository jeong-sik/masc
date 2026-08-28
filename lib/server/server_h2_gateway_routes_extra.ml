
open Server_utils
open Server_voice_config
open Server_routes_http
open Server_h2_gateway_helpers

(* Dispatch board, Gate, voice, karma, and static asset routes.
   Returns [true] if the route was handled, [false] otherwise. *)
(* [with_public_read] is the parent gateway's own H2 public-read gate, handed
   in rather than rebuilt here. The five routes that take it are wrapped in
   Server_auth.with_public_read on HTTP/1 and are not in the public-read
   allowlist, so under MASC_HTTP_AUTH_STRICT=1 HTTP/1 answers 401 while this
   dispatcher used to run the handler (#28161). *)
let dispatch ~h2_reqd ~httpun_request ~cors ~path ~config ~with_public_read
    (httpun_meth : [ `GET | `POST | `DELETE | `OPTIONS | `PUT | `HEAD
                    | `CONNECT | `TRACE | `Other of string ]) =
  let h2_respond_auth_error error =
    let status = Server_auth.http_status_of_auth_error error in
    h2_respond_json
      h2_reqd
      (Server_auth.auth_error_json error)
      ~status:(status :> H2.Status.t)
      ~extra_headers:(Server_auth.auth_error_headers ~status ~cors)
  in
  let with_optional_board_reaction_actor f =
    match config with
    | None ->
      if Server_auth.request_carries_auth_credential httpun_request
      then (
         h2_respond_json
           h2_reqd
           (Server_auth.not_initialized_response path)
           ~status:`Internal_server_error
           ~extra_headers:cors;
         true)
      else f None
    | Some (config : Workspace.config) ->
      (match
         Server_auth.authorize_optional_token_bound_permission_request
           ~base_path:config.base_path
           ~permission:Masc_domain.CanReadState
           httpun_request
       with
       | Ok actor -> f (Option.map board_actor_author_for_write actor)
       | Error error ->
         h2_respond_auth_error error;
         true)
  in
  match httpun_meth, path with
  | `GET, "/api/v1/voice/config" ->
      with_public_read (fun () ->
        let status, json = voice_config_payload () in
        let status =
          match status with `OK -> `OK | `Error -> `Internal_server_error
        in
        h2_respond_json_value h2_reqd json ~status ~extra_headers:cors);
      true

  | `GET, "/api/v1/board" ->
      with_optional_board_reaction_actor (fun reaction_actor ->
      let hearth = query_param httpun_request "hearth" in
      let sort_by = board_sort_order_of_request httpun_request in
      let exclude_system = bool_query_param httpun_request "exclude_system" ~default:false in
      let exclude_automation =
        bool_query_param httpun_request "exclude_automation" ~default:false
      in
      let author_filter =
        query_param httpun_request "author"
        |> Option.map String.trim
        |> Fun.flip Option.bind (fun s ->
             if s = "" then None else Some (board_actor_author_for_write s))
      in
      let limit = int_query_param httpun_request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
      let offset = int_query_param httpun_request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
      let base_fetch = board_fetch_limit ~exclude_system ~exclude_automation ~limit ~offset in
      let voter = board_voter_query httpun_request in
      let posts =
        Board_dispatch.list_posts ?hearth ~sort_by ~exclude_system
          ~exclude_automation ?author_filter ~limit:base_fetch ()
      in
      let karma_map = Board_dispatch.get_all_karma () in
      let get_karma author =
        Option.value ~default:0 (List.assoc_opt author karma_map)
      in
      let paged = posts |> drop offset |> take limit in
      let reaction_rows =
        board_reactions_batch
          ~targets:
            (List.map
               (fun (p : Board.post) ->
                  (Board.Reaction_post, Board.Post_id.to_string p.id))
               paged)
          ~voter:reaction_actor
      in
      let reactions_for = board_reactions_lookup reaction_rows in
      let posts_json = List.map (fun (p : Board.post) ->
        let author = Board.Agent_id.to_string p.author in
        let post_id = Board.Post_id.to_string p.id in
        let current_vote = board_current_vote_for_post ~voter ~post_id in
        let reactions = reactions_for (Board.Reaction_post, post_id) in
        board_post_dashboard_json ?current_vote ~reactions
          ~author_karma:(get_karma author) p
      ) paged in
      let json = `Assoc [
        ("posts", `List posts_json);
        ("count", `Int (List.length posts_json));
        ("limit", `Int limit);
        ("offset", `Int offset);
        ("sort_by", `String (board_sort_label sort_by));
      ] in
      h2_respond_json_value h2_reqd json ~extra_headers:cors;
      true)

  | `GET, "/api/v1/board/curation" ->
      with_public_read (fun () ->
        let json =
          match Board_dispatch.latest_curation_snapshot () with
          | None -> `Assoc [("snapshot", `Null)]
          | Some snap ->
              `Assoc [("snapshot", Board_curation.snapshot_to_yojson snap)]
        in
        h2_respond_json_value h2_reqd json ~extra_headers:cors);
      true

  | `GET, "/api/v1/board/hearths" ->
      with_public_read (fun () ->
        let exclude_system =
          bool_query_param httpun_request "exclude_system" ~default:false
        in
        let exclude_automation =
          bool_query_param httpun_request "exclude_automation" ~default:false
        in
        let hearths =
          Board_dispatch.list_hearths ~exclude_system ~exclude_automation ()
        in
        let json = `Assoc [
          ("hearths", `List (List.map (fun (name, count) ->
            `Assoc [("name", `String name); ("count", `Int count)]
          ) hearths));
        ] in
        h2_respond_json_value h2_reqd json ~extra_headers:cors);
      true

  | `GET, "/api/v1/board/flairs" ->
      let flairs = List.map Board.flair_to_yojson Board.available_flairs in
      let json = `Assoc [("flairs", `List flairs)] in
      h2_respond_json_value h2_reqd json ~extra_headers:cors;
      true

  | `GET, "/api/v1/board/sub-boards" ->
      let sub_boards = Board_dispatch.list_sub_boards () in
      let json =
        `Assoc
          [
            ( "sub_boards",
              `List (List.map Board.sub_board_to_yojson sub_boards) );
          ]
      in
      h2_respond_json_value h2_reqd json ~extra_headers:cors;
      true

  | `GET, "/api/v1/board/karma/ledger" ->
      with_public_read (fun () ->
        (* Karma ledger contract endpoint — attributed karma events.
           Query params:
             agent  — filter to a single recipient (case-sensitive)
             limit  — cap result count (default: 500) *)
        let agent = query_param httpun_request "agent" in
        let limit =
          int_query_param httpun_request "limit" ~default:500
          |> clamp ~min_v:1 ~max_v:5000
        in
        (* TEL-OK: read-only projection mirroring the HTTP/1 arm
           [board_karma_ledger_json], which emits none either. This route
           exists to make the two protocols answer identically, so telemetry
           on one arm only would reintroduce the asymmetry it closes. *)
        let events = Board_dispatch.get_karma_ledger ?agent ~limit () in
        let totals =
          (* TEL-OK: same read, same H1 counterpart, same reason. *)
          Board_dispatch.get_all_karma ()
          |> List.sort (fun (_, a) (_, b) -> compare b a)
        in
        let json =
          `Assoc
            [
              ("events", `List (List.map Board.karma_event_to_yojson events));
              ("count", `Int (List.length events));
              ("scoring_rule", `String "up=+1,down=0");
              ( "totals",
                `List
                  (List.map
                     (fun (agent_name, k) ->
                       `Assoc
                         [ ("agent", `String agent_name); ("karma", `Int k) ])
                     totals) );
            ]
        in
        h2_respond_json_value h2_reqd json ~extra_headers:cors);
      true

  | `GET, p
    when String.starts_with ~prefix:"/api/v1/board/" p
         && String.length p > 14 ->
      with_optional_board_reaction_actor (fun reaction_actor ->
      let post_id = String.sub p 14 (String.length p - 14) in
      match
        Server_board_post_response_format.of_query
          (query_param httpun_request "format")
      with
      | Error error ->
        h2_respond_json_value
          h2_reqd
          (Server_board_post_response_format.error_json error)
          ~status:`Bad_request
          ~extra_headers:cors;
        true
      | Ok response_format ->
        let voter = board_voter_query httpun_request in
        let status, body =
          board_post_detail_json ~voter
            ~reaction_actor ~config ~response_format ~post_id
        in
        h2_respond_json h2_reqd body ~status ~extra_headers:cors;
        true)

  | `GET, "/api/v1/karma" ->
      with_public_read (fun () ->
        let karma_list = Board_dispatch.get_all_karma () in
        let sorted = List.sort (fun (_, a) (_, b) -> compare b a) karma_list in
        let json = `Assoc [
          ("karma", `List (List.map (fun (agent, k) ->
            `Assoc [("agent", `String agent); ("karma", `Int k)]
          ) sorted));
        ] in
        h2_respond_json_value h2_reqd json ~extra_headers:cors);
      true

  | `GET, "/static/css/middleware.css" ->
      (match Option.map read_file (playground_asset_path "static/css/middleware.css") with
       | Some (Ok body) ->
           let headers = H2.Headers.of_list [
             ("content-type", "text/css; charset=utf-8");
             ("content-length", string_of_int (String.length body));
           ] in
           let response = H2.Response.create ~headers `OK in
           let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
           H2.Body.Writer.write_string writer body;
           H2.Body.Writer.close writer
       | None | Some (Error _) -> h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found);
      true

  | `GET, "/static/js/middleware.js" ->
      (match Option.map read_file (playground_asset_path "static/js/middleware.js") with
       | Some (Ok body) ->
           let headers = H2.Headers.of_list [
             ("content-type", "application/javascript; charset=utf-8");
             ("content-length", string_of_int (String.length body));
           ] in
           let response = H2.Response.create ~headers `OK in
           let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
           H2.Body.Writer.write_string writer body;
           H2.Body.Writer.close writer
       | None | Some (Error _) -> h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found);
      true

  | `GET, p
    when String.starts_with ~prefix:"/dashboard/assets/" p
         && String.length p > 18 ->
      let filename = String.sub p 18 (String.length p - 18) in
      if not (Web_dashboard.is_safe_asset_relative_path filename) then begin
        h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found;
        true
      end
      else begin
        (match Web_dashboard.load_dashboard_asset ("assets/" ^ filename) with
         | Ok body ->
             let ct = asset_content_type filename in
             let is_compressible =
               Filename.check_suffix filename ".js"
               || Filename.check_suffix filename ".css"
               || Filename.check_suffix filename ".svg"
             in
             let final_body, encoding_headers =
               Http_response_payload.compress_body
                 ~compress:is_compressible
                 ~accept_encoding:
                   (Httpun.Headers.get
                      httpun_request.Httpun.Request.headers
                      "accept-encoding")
                 body
             in
             let base_headers = [
               ("content-type", ct);
               ("content-length", string_of_int (String.length final_body));
               ("cache-control", "public, max-age=31536000, immutable");
             ] in
             let headers = H2.Headers.of_list (base_headers @ encoding_headers) in
             let response = H2.Response.create ~headers `OK in
             let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
             H2.Body.Writer.write_string writer final_body;
             H2.Body.Writer.close writer
         | Error error ->
           (match Web_dashboard.asset_error_http_status error with
            | `Not_found ->
              h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found
            | `Service_unavailable ->
              h2_respond_text
                h2_reqd
                "Dashboard assets unavailable; inspect /health dashboard_surface.recovery"
                ~status:`Service_unavailable));
        true
      end

  | _ -> false
