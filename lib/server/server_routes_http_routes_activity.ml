
open Server_utils
open Server_auth
open Server_routes_http_common
open Server_routes_http_runtime

module Http = Http_server_eio
module Mcp_eio = Mcp_server_eio
module Server_activity_http = Server_activity_http
module Common = Server_routes_http_common
module Pages = Server_routes_http_pages
module Runtime = Server_routes_http_runtime
module Keeper_stream = Server_routes_http_keeper_stream

let activity_http_deps ~sw ~clock : Server_activity_http.deps =
  {
    query_param;
    int_query_param;
    get_origin;
    cors_headers;
    get_switch = (fun () -> Some sw);
    get_clock = (fun () -> Some clock);
    get_session_id_any = Server_mcp_transport_http.get_session_id_any;
  }

let activity_events_http_json ~sw ~clock ~state request =
  Server_activity_http.events_http_json
    ~deps:(activity_http_deps ~sw ~clock) ~state request

let activity_graph_http_json ~sw ~clock ~state request =
  Server_activity_http.graph_http_json
    ~deps:(activity_http_deps ~sw ~clock) ~state request

let json_upsert_string_field name value = function
  | `Assoc fields ->
      let fields = List.filter (fun (k, _) -> k <> name) fields in
      Ok (`Assoc ((name, `String value) :: fields))
  | _non_object ->
      Error (Printf.sprintf "json_upsert_string_field: expected JSON object, got non-object for field %S" name)

let json_ensure_meta_source source = function
  | `Assoc fields ->
      let meta_json =
        match List.assoc_opt "meta" fields with
        | Some (`Assoc meta_fields as existing_meta) -> (
            match List.assoc_opt "source" meta_fields with
            | Some (`String current) when String.trim current <> "" -> existing_meta
            | _ -> `Assoc (("source", `String source) :: List.filter (fun (k, _) -> k <> "source") meta_fields))
        | _ -> `Assoc [ ("source", `String source) ]
      in
      let fields = ("meta", meta_json) :: List.filter (fun (k, _) -> k <> "meta") fields in
      Ok (`Assoc fields)
  | _non_object ->
      Error "json_ensure_meta_source: expected JSON object"

let json_ensure_meta_string_field name value = function
  | `Assoc fields ->
      let value = String.trim value in
      if value = "" then Ok (`Assoc fields)
      else
        let meta_json =
          match List.assoc_opt "meta" fields with
          | Some (`Assoc meta_fields as existing_meta) -> (
              match List.assoc_opt name meta_fields with
              | Some (`String current) when String.trim current <> "" -> existing_meta
              | _ ->
                  `Assoc
                    ((name, `String value)
                    :: List.filter (fun (k, _) -> k <> name) meta_fields))
          | _ -> `Assoc [ (name, `String value) ]
        in
        let fields =
          ("meta", meta_json) :: List.filter (fun (k, _) -> k <> "meta") fields
        in
        Ok (`Assoc fields)
  | _non_object ->
      Error "json_ensure_meta_string_field: expected JSON object"

let governance_surface_for_param_key param_key =
  Governance_registry.surfaces
  |> List.find_opt (fun (surface : Governance_registry.surface) ->
       List.mem param_key surface.param_keys)

let governance_param_risk param_key =
  governance_surface_for_param_key param_key
  |> Option.map (fun (surface : Governance_registry.surface) -> surface.risk)

let respond_high_risk_param_blocked request reqd ~param_key ~risk =
  respond_json_with_cors ~status:`Forbidden request reqd
    (Yojson.Safe.to_string
       (`Assoc
          [
            ("ok", `Bool false);
            ( "error",
              `String
                (Printf.sprintf
                   "runtime param %s is %s risk and no longer supports direct dashboard mutation"
                   param_key risk) );
          ]))

let add_routes ~sw ~clock router =
  router
  |> Http.Router.get "/api/v1/activity/events" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = activity_events_http_json ~sw ~clock ~state req in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/activity/graph" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = activity_graph_http_json ~sw ~clock ~state req in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/activity/swimlane" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json =
           Server_activity_http.swimlane_http_json
             ~deps:(activity_http_deps ~sw ~clock) ~state req
         in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/governance/params" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let params = Runtime_params.registry () in
         let meta_to_json = function
           | None -> `Null
           | Some (m : Runtime_params.param_meta) ->
               `Assoc ([
                 ("description", `String m.description);
                 ("value_type", `String m.value_type);
               ]
               @ (match m.min_value with Some v -> [("min_value", v)] | None -> [])
               @ (match m.max_value with Some v -> [("max_value", v)] | None -> []))
         in
         let items =
           List.map
             (fun (key, current, default, has_override, meta) ->
               `Assoc
                 [
                   ("key", `String key);
                   ("current", current);
                   ("default", default);
                   ("has_override", `Bool has_override);
                   ("meta", meta_to_json meta);
                 ])
             params
         in
         let surfaces = Governance_registry.surfaces_json () in
         let json =
           `Assoc
             [
               ("parameters", `List items);
               ("surfaces", surfaces);
             ]
         in
         Http.Response.json (Yojson.Safe.pretty_to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/governance/params/audit" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let limit = int_query_param req "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
         let entries = Runtime_params.recent_audit ~base_path limit in
         let json = `Assoc [
           ("entries", `List entries);
           ("count", `Int (List.length entries));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/audit" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let limit  = int_query_param req "limit"  ~default:100 |> clamp ~min_v:1 ~max_v:500 in
         let actor_filter    = query_param req "actor" in
         let kind_filter     = query_param req "kind" in
         let severity_filter = query_param req "severity" in
         let since_filter =
           query_param req "since"
           |> Fun.flip Option.bind (fun s -> float_of_string_opt (String.trim s))
         in
         let until_filter =
           query_param req "until"
           |> Fun.flip Option.bind (fun s -> float_of_string_opt (String.trim s))
         in
         let fetch_limit = match actor_filter, kind_filter, severity_filter with
           | None, None, None -> limit
           | _ -> min 5000 (limit * 20)
         in
         let all_entries = Audit_log.read_entries ~n:fetch_limit config in
         let json =
           Audit_log.audit_events_response_json ?actor:actor_filter
             ?kind:kind_filter ?severity:severity_filter ?since:since_filter
             ?until:until_filter ~limit all_entries
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let hearth = query_param req "hearth" in
         let sort_by = board_sort_order_of_request req in
         let exclude_system = bool_query_param req "exclude_system" ~default:false in
         let exclude_automation =
           bool_query_param req "exclude_automation" ~default:false
         in
         let author_filter =
           query_param req "author"
           |> Option.map String.trim
           |> Fun.flip Option.bind (fun s ->
                if s = "" then None else Some (board_actor_author_for_write s))
         in
         let limit = int_query_param req "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
         let offset = int_query_param req "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
         let base_fetch = board_fetch_limit ~exclude_system ~exclude_automation ~limit ~offset in
         let voter = board_voter_query req in
         let posts =
           Board_dispatch.list_posts ?hearth ~sort_by ~exclude_system
             ~exclude_automation ?author_filter ~limit:base_fetch ()
         in
         let karma_map = Board_dispatch.get_all_karma () in
         let get_karma author =
           List.assoc_opt author karma_map |> Option.value ~default:0
         in
         let paged = posts |> drop offset |> take limit in
         let reaction_rows =
           board_reactions_batch
             ~targets:
               (List.map
                  (fun (p : Board.post) ->
                     (Board.Reaction_post, Board.Post_id.to_string p.id))
                  paged)
             ~voter
         in
         let reactions_for = board_reactions_lookup reaction_rows in
         let posts_json =
           List.map
             (fun (p : Board.post) ->
               let author = Board.Agent_id.to_string p.author in
               let post_id = Board.Post_id.to_string p.id in
               let current_vote = board_current_vote_for_post ~voter ~post_id in
               let reactions = reactions_for (Board.Reaction_post, post_id) in
               board_post_dashboard_json ?current_vote
                 ~reactions
                 ~author_karma:(get_karma author) p)
             paged
         in
         let json = `Assoc [
           ("posts", `List posts_json);
           ("count", `Int (List.length posts_json));
           ("limit", `Int limit);
           ("offset", `Int offset);
           ("sort_by", `String (board_sort_label sort_by));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board/hearths" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let hearths = Board_dispatch.list_hearths () in
         let json = `Assoc [
           ("hearths", `List (List.map (fun (name, count) ->
             `Assoc [("name", `String name); ("count", `Int count)]
           ) hearths));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board/flairs" (fun _request reqd ->
       let flairs = List.map Board.flair_to_yojson Board.available_flairs in
       let json = `Assoc [("flairs", `List flairs)] in
       Http.Response.json (Yojson.Safe.to_string json) reqd)

  |> Http.Router.get "/api/v1/board/sub-boards" (fun _request reqd ->
       let sub_boards = Board_dispatch.list_sub_boards () in
       let json = `Assoc [
         ("sub_boards", `List (List.map Board.sub_board_to_yojson sub_boards));
       ] in
       Http.Response.json (Yojson.Safe.to_string json) reqd)

  |> Http.Router.post "/api/v1/board/sub-boards" (fun request reqd ->
       with_tool_auth ~tool_name:"board_sub_board_create"
         (fun _state _req reqd ->
         Http.Request.read_body_async reqd (fun body ->
           try
             let args = Yojson.Safe.from_string body in
             let slug =
               Safe_ops.json_string_opt "slug" args |> Option.value ~default:""
             in
             let name =
               Safe_ops.json_string_opt "name" args |> Option.value ~default:""
             in
             let description =
               Safe_ops.json_string_opt "description" args |> Option.value ~default:""
             in
             let members = Safe_ops.json_string_list "members" args in
             let agent_name =
               (let hdr k = Option.bind
                 (Httpun.Headers.get request.Httpun.Request.headers k)
                 (fun s -> if s = "" then None else Some s) in
               match hdr "x-gate-agent" with Some _ as v -> v | None -> hdr "x-masc-agent")
               |> Option.value ~default:"dashboard"
             in
             let access =
               match Safe_ops.json_string_opt "access" args with
               | Some s -> Board.sub_board_access_of_string_opt s
               | None -> None
             in
             (match Board_dispatch.create_sub_board ~slug ~name ~description
                      ~owner:agent_name ~members ?access () with
              | Ok sb ->
                  Http.Response.json
                    (Yojson.Safe.to_string (Board.sub_board_to_yojson sb)) reqd
              | Error e ->
                  Http.Response.json ~status:`Bad_request
                    (Yojson.Safe.to_string
                       (`Assoc [("error", `String (Tool_board.board_error_to_string e))]))
                    reqd)
           with Yojson.Json_error msg ->
             Http.Response.json ~status:`Bad_request
               (Yojson.Safe.to_string
                  (`Assoc [("error", `String ("invalid JSON: " ^ msg))]))
               reqd))
         request reqd)

  |> Http.Router.prefix_get "/api/v1/board/sub-boards/" (fun request reqd ->
       let path = Http.Request.path request in
       (match extract_path_param ~prefix:"/api/v1/board/sub-boards/" path with
        | None ->
            Http.Response.json ~status:`Bad_request
              (Yojson.Safe.to_string
                 (`Assoc [("error", `String "sub_board_id is required")]))
              reqd
        | Some sub_board_id ->
            (match Board_dispatch.get_sub_board ~sub_board_id with
             | Ok sb ->
                 Http.Response.json
                   (Yojson.Safe.to_string (Board.sub_board_to_yojson sb)) reqd
             | Error e ->
                 Http.Response.json ~status:`Not_found
                   (Yojson.Safe.to_string
                      (`Assoc [("error", `String (Tool_board.board_error_to_string e))]))
                   reqd)))

  |> Http.Router.prefix_get "/api/v1/board/" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let path = Http.Request.path request in
         (match extract_path_param ~prefix:"/api/v1/board/" path with
          | None ->
              Http.Response.json
                (Yojson.Safe.to_string (`Assoc [("error", `String "post_id is required")]))
                ~status:`Bad_request reqd
          | Some post_id ->
              let format =
                query_param req "format" |> Option.value ~default:"nested"
              in
              let voter = board_voter_query req in
              let (status, body) =
                board_post_detail_json ~voter ~response_format:format ~post_id
              in
              respond_json_with_cors ~status request reqd body)
       ) request reqd)

  (* Board write APIs — used by dashboard + Bevy Viewer.
     Uses with_tool_auth to allow same-origin or allowlisted local dev browser
     requests without a bearer token. *)
  |> Http.Router.post "/api/v1/tools/masc_board_vote" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_board_vote"
         (fun _state _req reqd ->
         let agent_name = (let hdr k = Option.bind (Httpun.Headers.get request.Httpun.Request.headers k) (fun s -> if s = "" then None else Some s) in match hdr "x-gate-agent" with Some _ as v -> v | None -> hdr "x-masc-agent") |> Option.value ~default:"dashboard" in
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let ( let* ) r f =
               match r with
               | Ok v -> f v
               | Error msg ->
                   respond_json_with_cors ~status:`Bad_request request reqd
                     (Yojson.Safe.to_string (`Assoc [
                       ("ok", `Bool false);
                       ("message", `String msg)
                     ]))
             in
             let* args =
               try Ok (Yojson.Safe.from_string body_str)
               with Yojson.Json_error msg -> Error ("Invalid JSON: " ^ msg)
             in
             let voter = board_actor_author_for_write agent_name in
             let* args = json_upsert_string_field "voter" voter args in
             let result = Tool_board.handle_tool "masc_board_vote" args in
             let ok = result.success in
             let msg = Tool_result.message result in
             let status = if ok then `OK else `Bad_request in
             respond_json_with_cors ~status request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool ok); ("message", `String msg)
               ]))
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool false);
                 ("message", `String (Printexc.to_string exn))
               ]))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/tools/masc_board_post" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_board_post"
         (fun _state _req reqd ->
         let agent_name = (let hdr k = Option.bind (Httpun.Headers.get request.Httpun.Request.headers k) (fun s -> if s = "" then None else Some s) in match hdr "x-gate-agent" with Some _ as v -> v | None -> hdr "x-masc-agent") |> Option.value ~default:"dashboard" in
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let ( let* ) r f =
               match r with
               | Ok v -> f v
               | Error msg ->
                   respond_json_with_cors ~status:`Bad_request request reqd
                     (Yojson.Safe.to_string (`Assoc [
                       ("ok", `Bool false);
                       ("message", `String msg)
                     ]))
             in
             let* args =
               try Ok (Yojson.Safe.from_string body_str)
               with Yojson.Json_error msg -> Error ("Invalid JSON: " ^ msg)
             in
             let author = board_actor_author_for_write agent_name in
             let* args = json_upsert_string_field "author" author args in
             let* args =
               if String.equal author (String.trim agent_name) then Ok args
               else json_ensure_meta_string_field "author_raw_agent_name" agent_name args
             in
             let* args = json_ensure_meta_source "dashboard_board_post" args in
             let result = Tool_board.handle_tool "masc_board_post" args in
             let ok = result.success in
             let msg = Tool_result.message result in
             let status = if ok then `Created else `Bad_request in
             respond_json_with_cors ~status request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool ok); ("message", `String msg)
               ]))
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool false);
                 ("message", `String (Printexc.to_string exn))
               ]))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/tools/masc_board_comment" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_board_comment"
         (fun _state _req reqd ->
         let agent_name = (let hdr k = Option.bind (Httpun.Headers.get request.Httpun.Request.headers k) (fun s -> if s = "" then None else Some s) in match hdr "x-gate-agent" with Some _ as v -> v | None -> hdr "x-masc-agent") |> Option.value ~default:"dashboard" in
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let ( let* ) r f =
               match r with
               | Ok v -> f v
               | Error msg ->
                   respond_json_with_cors ~status:`Bad_request request reqd
                     (Yojson.Safe.to_string (`Assoc [
                       ("ok", `Bool false);
                       ("message", `String msg)
                     ]))
             in
             let* args =
               try Ok (Yojson.Safe.from_string body_str)
               with Yojson.Json_error msg -> Error ("Invalid JSON: " ^ msg)
             in
             let author = board_actor_author_for_write agent_name in
             let* args = json_upsert_string_field "author" author args in
             let result = Tool_board.handle_tool "masc_board_comment" args in
             let ok = result.success in
             let msg = Tool_result.message result in
             let status = if ok then `Created else `Bad_request in
             respond_json_with_cors ~status request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool ok); ("message", `String msg)
               ]))
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool false);
                 ("message", `String (Printexc.to_string exn))
               ]))
         )
       ) request reqd)
  |> Http.Router.get "/api/v1/karma" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let karma_list = Board_dispatch.get_all_karma () in
         let sorted = List.sort (fun (_, a) (_, b) -> compare b a) karma_list in
         let json = `Assoc [
           ("karma", `List (List.map (fun (agent, k) ->
             `Assoc [("agent", `String agent); ("karma", `Int k)]
           ) sorted));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board/karma/ledger" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let agent = query_param req "agent" in
         let limit =
           int_query_param req "limit" ~default:500
           |> clamp ~min_v:1 ~max_v:5000
         in
         let events = Board_dispatch.get_karma_ledger ?agent ~limit () in
         let totals =
           Board_dispatch.get_all_karma ()
           |> List.sort (fun (_, a) (_, b) -> compare b a)
         in
         let json =
           `Assoc [
             ("events", `List (List.map Board.karma_event_to_yojson events));
             ("count", `Int (List.length events));
             ("scoring_rule", `String "up=+1,down=0");
             ("totals", `List (List.map (fun (agent_name, k) ->
               `Assoc [("agent", `String agent_name); ("karma", `Int k)])
               totals));
           ]
         in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* Mention Inbox API *)
  |> Http.Router.prefix_get "/api/v1/mentions/" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let path = Http.Request.path request in
         (match extract_path_param ~prefix:"/api/v1/mentions/" path with
          | None ->
              Http.Response.json
                (Yojson.Safe.to_string (`Assoc [("error", `String "agent_name is required")]))
                ~status:`Bad_request reqd
          | Some agent_name ->
              let limit = standard_limit request in
              let mentions =
                Mention_inbox.read_mentions state.Mcp_server.room_config
                  ~target_agent:agent_name ~limit
              in
              let unread =
                Mention_inbox.unread_count state.Mcp_server.room_config
                  ~target_agent:agent_name
              in
              let json = `Assoc [
                ("agent", `String agent_name);
                ("unread_count", `Int unread);
                ("mentions", `List (List.map Mention_inbox.mention_record_to_json mentions));
              ] in
              Http.Response.json (Yojson.Safe.to_string json) reqd)
       ) request reqd)

  (* Agent Reputation API *)
  |> Http.Router.prefix_get "/api/v1/reputation/" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let path = Http.Request.path request in
         (match extract_path_param ~prefix:"/api/v1/reputation/" path with
          | None ->
              Http.Response.json
                (Yojson.Safe.to_string (`Assoc [("error", `String "agent_name is required")]))
                ~status:`Bad_request reqd
          | Some agent_name ->
              let rep =
                Agent_reputation.compute_reputation
                  state.Mcp_server.room_config ~agent_name
              in
              Http.Response.json
                (Yojson.Safe.to_string (Agent_reputation.reputation_to_json rep))
                reqd)
       ) request reqd)

  (* Activity Feed API *)
  |> Http.Router.get "/api/v1/activity" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let agent_name = query_param req "agent" in
         let limit = int_query_param req "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
         let items =
           Activity_feed.recent_activity state.Mcp_server.room_config
             ?agent_name ~limit ()
         in
         let json = `Assoc [
           ("items", `List (List.map Activity_feed.activity_item_to_json items));
           ("count", `Int (List.length items));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* Prompt Registry API *)
  |> Http.Router.get "/api/v1/prompts" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let json = Prompt_registry.prompts_json () in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.post "/api/v1/prompts" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_prompt_override"
         (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let key = Yojson.Safe.Util.(member "key" args |> to_string_option)
               |> Option.value ~default:"" in
             let action = Yojson.Safe.Util.(member "action" args |> to_string_option)
               |> Option.value ~default:"set" in
             if key = "" then
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (`Assoc [
                   ("ok", `Bool false); ("error", `String "key is required")
                 ]))
             else begin
               let result = match action with
                 | "clear" ->
                   Prompt_registry.clear_prompt_override key;
                   (try Prompt_registry.persist_overrides
                          state.Mcp_server.room_config.base_path
                    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                      Log.Pages.warn "prompt override persist (clear) failed: %s"
                        (Printexc.to_string exn));
                   Ok "override cleared"
                 | "set" | _ ->
                   let value = Yojson.Safe.Util.(member "value" args |> to_string_option)
                     |> Option.value ~default:"" in
                   match Prompt_registry.set_override key value with
                   | Ok () ->
                     (try Prompt_registry.persist_overrides
                            state.Mcp_server.room_config.base_path
                      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                        Log.Pages.warn "prompt override persist (set) failed: %s"
                          (Printexc.to_string exn));
                     Ok "override set"
                   | Error msg -> Error msg
               in
               match result with
               | Ok msg ->
                 respond_json_with_cors request reqd
                   (Yojson.Safe.to_string (`Assoc [
                     ("ok", `Bool true);
                     ("message", `String msg);
                     ("key", `String key);
                     ("source", `String (Prompt_registry.prompt_source key));
                     ("effective", `String (Prompt_registry.get_prompt key));
                   ]))
               | Error msg ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (`Assoc [
                     ("ok", `Bool false); ("error", `String msg)
                   ]))
             end
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool false);
                 ("error", `String (Printexc.to_string exn))
               ]))
         )
       ) request reqd)

  (* Governance Runtime Params: set / clear *)
  |> Http.Router.post "/api/v1/governance/params/set" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_set_param"
         (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let base_path = state.Mcp_server.room_config.base_path in
             let actor =
               sanitized_dashboard_actor_for_request ~base_path request
               |> Option.value ~default:"dashboard"
             in
             let param_key = Yojson.Safe.Util.(member "param_key" args
               |> to_string_option) |> Option.value ~default:"" |> String.trim in
             let value_json = match Yojson.Safe.Util.member "value" args with
               | `Null -> None | v -> Some v in
             if param_key = "" then
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (`Assoc [
                   ("ok", `Bool false); ("error", `String "param_key is required")
                 ]))
             else match value_json with
             | None ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (`Assoc [
                   ("ok", `Bool false); ("error", `String "value is required")
                 ]))
             | Some value ->
               (match governance_param_risk param_key with
                | Some "high" ->
                    respond_high_risk_param_blocked request reqd
                      ~param_key ~risk:"high"
                | _ ->
                    let old_value =
                      match Runtime_params.registry ()
                        |> List.find_opt (fun (k, _, _, _, _) -> k = param_key) with
                      | Some (_, current, _, _, _) -> current
                      | None -> `Null
                    in
                    (match Runtime_params.set_by_key param_key value with
                     | Error msg ->
                         respond_json_with_cors ~status:`Bad_request request reqd
                           (Yojson.Safe.to_string
                              (`Assoc
                                 [
                                   ("ok", `Bool false);
                                   ("error", `String msg);
                                 ]))
                     | Ok () ->
                         Runtime_params.persist ~base_path;
                         Runtime_params.record_audit ~base_path
                           ~key:param_key ~old_value ~new_value:value ~actor ();
                         Sse.broadcast
                           (`Assoc
                              [
                                ("type", `String "governance_param_changed");
                                ("param_key", `String param_key);
                                ("old_value", old_value);
                                ("new_value", value);
                                ("actor", `String actor);
                              ]);
                         respond_json_with_cors request reqd
                           (Yojson.Safe.to_string
                              (`Assoc
                                 [
                                   ("ok", `Bool true);
                                   ( "message",
                                     `String
                                       (Printf.sprintf "Set %s = %s" param_key
                                          (Yojson.Safe.to_string value)) );
                                 ]))))
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool false);
                 ("error", `String (Printexc.to_string exn))
               ]))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/governance/params/clear" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_set_param"
         (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let param_key = Yojson.Safe.Util.(member "param_key" args
               |> to_string_option) |> Option.value ~default:"" in
             let base_path = state.Mcp_server.room_config.base_path in
             let actor =
               sanitized_dashboard_actor_for_request ~base_path request
               |> Option.value ~default:"dashboard"
             in
             if param_key = "" then
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (`Assoc [
                   ("ok", `Bool false); ("error", `String "param_key is required")
                 ]))
             else begin
               match governance_param_risk param_key with
               | Some "high" ->
                   respond_high_risk_param_blocked request reqd
                     ~param_key ~risk:"high"
               | _ ->
                   let old_value =
                     match Runtime_params.registry ()
                       |> List.find_opt (fun (k, _, _, _, _) -> k = param_key) with
                     | Some (_, current, _, _, _) -> current
                     | None -> `Null
                   in
                   match Runtime_params.clear_by_key param_key with
                   | Error msg ->
                       respond_json_with_cors ~status:`Bad_request request reqd
                         (Yojson.Safe.to_string
                            (`Assoc
                               [
                                 ("ok", `Bool false);
                                 ("error", `String msg);
                               ]))
                   | Ok () ->
                       let new_value =
                         match Runtime_params.registry ()
                           |> List.find_opt (fun (k, _, _, _, _) -> k = param_key) with
                         | Some (_, _, default, _, _) -> default
                         | None -> `Null
                       in
                       Runtime_params.persist ~base_path;
                       Runtime_params.record_audit ~base_path
                         ~key:param_key ~old_value ~new_value ~actor ();
                       Sse.broadcast
                         (`Assoc
                            [
                              ("type", `String "governance_param_changed");
                              ("param_key", `String param_key);
                              ("old_value", old_value);
                              ("new_value", new_value);
                              ("actor", `String actor);
                            ]);
                       respond_json_with_cors request reqd
                         (Yojson.Safe.to_string
                            (`Assoc
                               [
                                 ("ok", `Bool true);
                                 ( "message",
                                   `String
                                     (Printf.sprintf "Cleared %s to default" param_key) );
                               ]))
             end
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool false);
                 ("error", `String (Printexc.to_string exn))
               ]))
         )
       ) request reqd)
