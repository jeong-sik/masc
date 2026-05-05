
open Server_utils
open Server_voice_config
open Server_routes_http
open Server_h2_gateway_helpers

(* Dispatch board, governance, voice, karma, and static asset routes.
   Returns [true] if the route was handled, [false] otherwise. *)
let dispatch ~h2_reqd ~httpun_request ~cors ~path
    (httpun_meth : [ `GET | `POST | `DELETE | `OPTIONS | `PUT | `HEAD
                    | `CONNECT | `TRACE | `Other of string ]) =
  match httpun_meth, path with
  | `GET, "/api/v1/voice/config" ->
      let status, json = voice_config_payload () in
      let status =
        match status with `OK -> `OK | `Error -> `Internal_server_error
      in
      h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~status
        ~extra_headers:cors;
      true

  | `GET, "/api/v1/board" ->
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
      let posts_json = List.map (fun (p : Board.post) ->
        let author = Board.Agent_id.to_string p.author in
        let post_id = Board.Post_id.to_string p.id in
        let current_vote = board_current_vote_for_post ~voter ~post_id in
        let reactions = board_reactions_for_post ~voter ~post_id in
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
      h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors;
      true

  | `GET, "/api/v1/board/curation" ->
      let json =
        match Board_dispatch.latest_curation_snapshot () with
        | None -> `Assoc [("snapshot", `Null)]
        | Some snap ->
            `Assoc [("snapshot", Board_curation.snapshot_to_yojson snap)]
      in
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

  | `GET, p
    when String.starts_with ~prefix:"/api/v1/board/" p
         && String.length p > 14 ->
      let post_id = String.sub p 14 (String.length p - 14) in
      let format = Option.value ~default:"nested" (query_param httpun_request "format") in
      let voter = board_voter_query httpun_request in
      let (status, body) =
        board_post_detail_json ~voter ~response_format:format ~post_id
      in
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

  | `GET, "/api/v1/board/karma/ledger" ->
      (* Karma ledger contract endpoint — attributed karma events.
         Query params:
           agent  — filter to a single recipient (case-sensitive)
           limit  — cap result count (default: 500) *)
      let agent = query_param httpun_request "agent" in
      let limit =
        int_query_param httpun_request "limit" ~default:500
        |> clamp ~min_v:1 ~max_v:5000
      in
      let events = Board_dispatch.get_karma_ledger ?agent ~limit () in
      let totals = Board_dispatch.get_all_karma () |> List.sort (fun (_, a) (_, b) -> compare b a) in
      let json =
        `Assoc [
          ("events",
           `List (List.map Board.karma_event_to_yojson events));
          ("count", `Int (List.length events));
          ("scoring_rule", `String "up=+1,down=0");
          ("totals",
           `List (List.map (fun (agent_name, k) ->
               `Assoc [("agent", `String agent_name); ("karma", `Int k)])
             totals));
        ]
      in
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

  | `GET, p
    when String.starts_with ~prefix:"/dashboard/assets/" p
         && String.length p > 18 ->
      let filename = String.sub p 18 (String.length p - 18) in
      if not (Web_dashboard.is_safe_asset_relative_path filename) then begin
        h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found;
        true
      end
      else
        let file_path = Filename.concat (dashboard_asset_root ()) ("assets/" ^ filename) in
        (match read_file file_path with
         | Ok body ->
             let ct = asset_content_type filename in
             let is_compressible =
               Filename.check_suffix filename ".js"
               || Filename.check_suffix filename ".css"
               || Filename.check_suffix filename ".svg"
             in
             let accepts_zstd =
               Http_server_eio.Compression.accepts_zstd httpun_request
             in
             let final_body, encoding_headers =
               if is_compressible && accepts_zstd then
                 let (compressed, did_compress) =
                   Http_server_eio.Compression.compress_zstd ~level:3 body
                 in
                 if did_compress then
                   (compressed, [("content-encoding", "zstd"); ("vary", "Accept-Encoding")])
                 else
                   (body, [])
               else
                 (body, [])
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
         | Error _ -> h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found);
      true

  | _ -> false
