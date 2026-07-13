
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
module Keeper_api_types = Server_dashboard_http_keeper_api_types

let activity_result_json ~ok ~message =
  `Assoc [ ("ok", `Bool ok); ("message", `String message) ]
;;

let respond_board_reaction_result request reqd = function
  | Ok json -> respond_json_value_with_cors request reqd json
  | Error error ->
    respond_json_value_with_cors
      ~status:(Server_board_reaction_http.error_status error :> Httpun.Status.t)
      request
      reqd
      (Server_board_reaction_http.error_json error)
;;

let include_moderation_projection ~base_path request =
  match auth_token_from_request request with
  | None -> false
  | Some _ -> (
      match
        authorize_token_bound_permission_request
          ~base_path
          ~permission:Masc_domain.CanReadState
          request
      with
      | Ok _ -> true
      | Error _ -> false)

let with_optional_board_reaction_actor ~base_path request reqd f =
  match
    authorize_optional_token_bound_permission_request
      ~base_path
      ~permission:Masc_domain.CanReadState
      request
  with
  | Ok actor -> f (Option.map board_actor_author_for_write actor)
  | Error err -> respond_auth_error request reqd err

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

let board_tool_agent_name_from_request request =
  let hdr name =
    Option.bind
      (Httpun.Headers.get request.Httpun.Request.headers name)
      (fun value ->
        let trimmed = String.trim value in
        if String.equal trimmed "" then None else Some trimmed)
  in
  match hdr "x-gate-agent" with
  | Some value -> value
  | None -> (
      match hdr "x-masc-agent" with
      | Some value -> value
      | None ->
          (* NDT-OK: same-origin dashboard tool calls may omit agent headers;
             the sibling board REST bridges already use this dashboard actor fallback. *)
          "dashboard")

let board_tool_owner_from_request request =
  board_tool_agent_name_from_request request |> board_actor_author_for_write

let sub_board_owner_matches ~owner (sb : Board.sub_board) =
  String.equal (Board.Agent_id.to_string sb.Board.owner) owner

let sub_board_owner_error ~owner ~sub_board_id (sb : Board.sub_board) =
  `Assoc
    [ ( "error"
      , `String
          (Printf.sprintf
             "agent %s cannot mutate sub-board %s owned by %s"
             owner
             sub_board_id
             (Board.Agent_id.to_string sb.Board.owner)) )
    ]

let board_curation_json () =
  match Board_dispatch.latest_curation_snapshot () with
  | None -> `Assoc [ ("snapshot", `Null) ]
  | Some snap -> `Assoc [ ("snapshot", Board_curation.snapshot_to_yojson snap) ]

let board_sub_boards_json () =
  let sub_boards = Board_dispatch.list_sub_boards () in
  `Assoc
    [
      ( "sub_boards",
        `List (List.map Board.sub_board_to_yojson sub_boards) );
    ]

let board_karma_ledger_json req =
  let agent = query_param req "agent" in
  let limit = int_query_param req "limit" ~default:500 |> clamp ~min_v:1 ~max_v:5000 in
  let events = Board_dispatch.get_karma_ledger ?agent ~limit () in
  let totals =
    Board_dispatch.get_all_karma ()
    |> List.sort (fun (_, a) (_, b) -> compare b a)
  in
  `Assoc
    [
      ("events", `List (List.map Board.karma_event_to_yojson events));
      ("count", `Int (List.length events));
      ("scoring_rule", `String "up=+1,down=0");
      ( "totals",
        `List
          (List.map
             (fun (agent_name, k) ->
               `Assoc [ ("agent", `String agent_name); ("karma", `Int k) ])
             totals) );
    ]

type board_context_inference_target_source =
  | Explicit_target
  | Post_author

let board_context_inference_target_source_to_string = function
  | Explicit_target -> "explicit_target"
  | Post_author -> "post_author"

type board_context_inference_request =
  { post_id : string
  ; target_keeper : string option
  }

let json_assoc_member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let trimmed_json_string_member ~field json =
  match json_assoc_member field json with
  | None | Some `Null -> Ok None
  | Some (`String value) ->
      let value = String.trim value in
      Ok (if value = "" then None else Some value)
  | Some _ -> Error (Printf.sprintf "%s must be a string" field)

let required_trimmed_json_string_member ~field json =
  match trimmed_json_string_member ~field json with
  | Ok (Some value) -> Ok value
  | Ok None -> Error (Printf.sprintf "%s is required" field)
  | Error _ as err -> err

let parse_board_context_inference_request = function
  | `Assoc _ as json -> (
      match required_trimmed_json_string_member ~field:"post_id" json with
      | Error msg -> Error msg
      | Ok post_id -> (
          match trimmed_json_string_member ~field:"target_keeper" json with
          | Error msg -> Error msg
          | Ok target_keeper -> Ok { post_id; target_keeper }))
  | _ -> Error "request body must be a JSON object"

let board_context_string_option_json = function
  | Some value -> `String value
  | None -> `Null

let board_context_field key value =
  `Assoc [ ("k", `String key); ("v", value) ]

let board_context_comment_json (comment : Board.comment) =
  `Assoc
    [
      ("id", `String (Board.Comment_id.to_string comment.id));
      ("post_id", `String (Board.Post_id.to_string comment.post_id));
      ( "parent_id",
        board_context_string_option_json
          (Option.map Board.Comment_id.to_string comment.parent_id) );
      ("author", `String (Board.Agent_id.to_string comment.author));
      ("content", `String comment.content);
      ("created_at", `Float comment.created_at);
    ]

let board_context_inference_surface_context (post : Board.post) comments =
  let post_id = Board.Post_id.to_string post.id in
  let author = Board.Agent_id.to_string post.author in
  `Assoc
    [
      ("label", `String "Board post context inference");
      ("route", `String (Printf.sprintf "#board?post=%s" post_id));
      ("scene", `String "board_post_context");
      ( "fields",
        `List
          [
            board_context_field "board_post_id" (`String post_id);
            board_context_field "author" (`String author);
            board_context_field "title" (`String post.title);
            board_context_field "body" (`String post.body);
            board_context_field "content" (`String post.content);
            board_context_field "post_kind" (`String (Board.post_kind_to_string post.post_kind));
            board_context_field "visibility" (`String (Board.visibility_to_string post.visibility));
            board_context_field "hearth" (board_context_string_option_json post.hearth);
            board_context_field "thread_id" (board_context_string_option_json post.thread_id);
            board_context_field "reply_count" (`Int post.reply_count);
            board_context_field "comment_count" (`Int (List.length comments));
            board_context_field "comments" (`List (List.map board_context_comment_json comments));
          ] );
    ]

let board_context_inference_message (post : Board.post) =
  Printf.sprintf
    "Infer the context of board post %s. Use the supplied board surface \
     context and MASC tools as needed. Identify related work, missing context, \
     and whether a follow-up action or board comment is warranted. Do not \
     invent facts that are not present in board context, memory, or tools."
    (Board.Post_id.to_string post.id)

let resolve_board_context_inference_target ~config (post : Board.post) target_keeper =
  let resolve source requested =
    match Keeper_meta_store.read_meta_resolved config requested with
    | Ok (Some (resolved_name, _meta)) -> Ok (resolved_name, source)
    | Ok None ->
        Error
          (`Bad_request
             (Printf.sprintf
                "target_keeper %S is not a registered keeper"
                requested))
    | Error msg ->
        Error
          (`Internal_server_error
             (Printf.sprintf
                "failed to read keeper metadata for %S: %s"
                requested
                msg))
  in
  match target_keeper with
  | Some requested -> resolve Explicit_target requested
  | None ->
      let author = Board.Agent_id.to_string post.author in
      (match Keeper_meta_store.read_meta_resolved config author with
       | Ok (Some (resolved_name, _meta)) -> Ok (resolved_name, Post_author)
       | Ok None ->
           Error
             (`Bad_request
                (Printf.sprintf
                   "target_keeper is required because board post author %S is not a registered keeper"
                   author))
       | Error msg ->
           Error
             (`Internal_server_error
                (Printf.sprintf
                   "failed to read keeper metadata for board author %S: %s"
                   author
                   msg)))

let non_empty_json_string_member field json =
  match json_assoc_member field json with
  | Some (`String value) ->
      let value = String.trim value in
      if value = "" then None else Some value
  | _ -> None

let board_context_inference_submission_json ~post_id ~target_source tool_data =
  match
    ( non_empty_json_string_member "request_id" tool_data,
      non_empty_json_string_member "keeper_name" tool_data,
      non_empty_json_string_member "status" tool_data )
  with
  | Some request_id, Some keeper_name, Some status ->
      let fields =
        [
          ("ok", `Bool true);
          ("request_id", `String request_id);
          ("keeper_name", `String keeper_name);
          ("post_id", `String post_id);
          ("status", `String status);
          ( "target_source",
            `String (board_context_inference_target_source_to_string target_source) );
        ]
      in
      let fields =
        match non_empty_json_string_member "message" tool_data with
        | Some message -> fields @ [ ("message", `String message) ]
        | None -> fields
      in
      Ok (`Assoc fields)
  | _ -> Error "masc_keeper_msg returned a malformed queue submission"

let dispatch_board_context_inference ~state ~sw ~clock ~request ~target_keeper
    ~target_source ~(post : Board.post) ~comments =
  let config = Mcp_server.workspace_config state in
  let agent_name = board_tool_agent_name_from_request request in
  let keeper_ctx : _ Keeper_tool_surface.context =
    {
      config;
      agent_name;
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      net = state.Mcp_server.net;
    }
  in
  let post_id = Board.Post_id.to_string post.id in
  let args =
    `Assoc
      [
        ("name", `String target_keeper);
        ("message", `String (board_context_inference_message post));
        ("direct_reply", `Bool true);
        ( "surface_context",
          board_context_inference_surface_context post comments );
      ]
  in
  match Keeper_tool_surface.dispatch keeper_ctx ~name:"masc_keeper_msg" ~args with
  | None -> Error (`Internal_server_error "masc_keeper_msg tool is unavailable")
  | Some result ->
      if Tool_result.is_success result
      then
        (match
           board_context_inference_submission_json ~post_id ~target_source
             (Tool_result.data result)
         with
         | Ok json -> Ok json
         | Error msg -> Error (`Internal_server_error msg))
      else Error (`Bad_request (Tool_result.message result))

let respond_board_context_inference_error request reqd ~status ~message =
  respond_json_value_with_cors ~status request reqd
    (`Assoc [ ("ok", `Bool false); ("error", `String message) ])

let handle_board_context_inference_request ~state ~sw ~clock ~request reqd body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error msg ->
      respond_board_context_inference_error request reqd ~status:`Bad_request
        ~message:("Invalid JSON: " ^ msg)
  | parsed -> (
      match parse_board_context_inference_request parsed with
      | Error message ->
          respond_board_context_inference_error request reqd ~status:`Bad_request
            ~message
      | Ok { post_id; target_keeper } -> (
          match Board_dispatch.get_post_and_comments ~post_id () with
          | Error err ->
              respond_board_context_inference_error request reqd
                ~status:`Bad_request
                ~message:(Board_tool.board_error_to_string err)
          | Ok (post, comments) -> (
              let config = Mcp_server.workspace_config state in
              match
                resolve_board_context_inference_target ~config post target_keeper
              with
              | Error (`Bad_request message) ->
                  respond_board_context_inference_error request reqd
                    ~status:`Bad_request
                    ~message
              | Error (`Internal_server_error message) ->
                  respond_board_context_inference_error request reqd
                    ~status:`Internal_server_error
                    ~message
              | Ok (target_keeper, target_source) -> (
                  match
                    dispatch_board_context_inference ~state ~sw ~clock ~request
                      ~target_keeper ~target_source ~post ~comments
                  with
                  | Ok json ->
                      respond_json_value_with_cors ~status:`Accepted request reqd
                        json
                  | Error (`Bad_request message) ->
                      respond_board_context_inference_error request reqd
                        ~status:`Bad_request ~message
                  | Error (`Internal_server_error message) ->
                      respond_board_context_inference_error request reqd
                        ~status:`Internal_server_error ~message))))

let respond_board_json reqd json =
  Http.Response.json_value json reqd

let add_routes ~sw ~clock router =
  router
  |> Http.Router.get "/api/v1/activity/events" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = activity_events_http_json ~sw ~clock ~state req in
         Http.Response.json_value json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/activity/graph" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = activity_graph_http_json ~sw ~clock ~state req in
         Http.Response.json_value json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/activity/swimlane" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json =
           Server_activity_http.swimlane_http_json
             ~deps:(activity_http_deps ~sw ~clock) ~state req
         in
         Http.Response.json_value json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/runtime/params" (fun request reqd ->
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
         let surfaces = Runtime_settings.surfaces_json () in
         let json =
           `Assoc
             [
               ("parameters", `List items);
               ("surfaces", surfaces);
             ]
         in
         Http.Response.json_value json reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/runtime/params/audit" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         let limit = int_query_param req "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
         let entries = Runtime_params.recent_audit ~base_path limit in
         let json = `Assoc [
           ("entries", `List entries);
           ("count", `Int (List.length entries));
         ] in
         Http.Response.json_value json reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/audit" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let config = (Mcp_server.workspace_config state) in
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
         Http.Response.json_value ~compress:true ~request:req
           json reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let config = Mcp_server.workspace_config state in
         with_optional_board_reaction_actor
           ~base_path:config.base_path
           req
           reqd
           (fun reaction_actor ->
         let hearth = query_param req "hearth" in
         let sort_by = board_sort_order_of_request req in
         let exclude_system = bool_query_param req "exclude_system" ~default:false in
         let exclude_automation =
           bool_query_param req "exclude_automation" ~default:false
         in
         let author_query =
           query_param req "author"
           |> Option.map String.trim
           |> Fun.flip Option.bind (fun s -> if s = "" then None else Some s)
         in
         let author_filter =
           Option.map board_actor_author_for_write author_query
         in
         let limit = int_query_param req "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
         let offset = int_query_param req "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
         let base_fetch = board_fetch_limit ~exclude_system ~exclude_automation ~limit ~offset in
         let voter = board_voter_query req in
         let blind_votes = bool_query_param req "blind_votes" ~default:false in
         let include_moderation =
           include_moderation_projection
             ~base_path:config.base_path
             req
         in
         let cache_key =
           let cache_part = function
             | Some value -> value
             | None -> ""
           in
           Printf.sprintf "board:list:%s:%s:%s:%b:%b:%s:%d:%d:%s:%s:%b:%b"
             config.base_path
             (cache_part hearth)
             (board_sort_label sort_by)
             exclude_system exclude_automation
             (cache_part author_query)
             limit offset (cache_part voter) (cache_part reaction_actor)
             blind_votes include_moderation
         in
         let json =
           Dashboard_cache.get_or_compute cache_key
             ~ttl:Server_dashboard_http_core_cache.realtime_cache_ttl_s
             (fun () ->
                Domain_pool_ref.submit_io_or_inline (fun () ->
                  let posts =
                    Board_dispatch.list_posts ?hearth ~sort_by ~exclude_system
                      ~exclude_automation ?author_filter ~limit:base_fetch ()
                  in
                  let karma_map = Board_dispatch.get_all_karma () in
                  let get_karma author =
                    match List.assoc_opt author karma_map with
                    | Some karma -> karma
                    | None -> 0
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
                  let contributor_quality_for =
                    board_contributor_quality_lookup ~config ()
                  in
                  let posts_json =
                    List.map
                      (fun (p : Board.post) ->
                         let author = Board.Agent_id.to_string p.author in
                         let post_id = Board.Post_id.to_string p.id in
                         let current_vote = board_current_vote_for_post ~voter ~post_id in
                         let reactions = reactions_for (Board.Reaction_post, post_id) in
                         let contributor_quality = contributor_quality_for author in
                         board_post_dashboard_json ~include_moderation ~blind_votes
                           ?contributor_quality ~reactions
                           ?current_vote
                           ~author_karma:(get_karma author) p)
                      paged
                  in
                  `Assoc [
                    ("posts", `List posts_json);
                    ("count", `Int (List.length posts_json));
                    ("limit", `Int limit);
                    ("offset", `Int offset);
                    ("sort_by", `String (board_sort_label sort_by));
                  ]))
         in
         Http.Response.json_value json reqd)
       ) request reqd)

  |> Http.Router.get "/api/v1/board/reactions/catalog" (fun request reqd ->
       with_public_read
         (fun _state _request reqd ->
            Http.Response.json_value
              (Server_board_reaction_http.catalog_json ())
              reqd)
         request
         reqd)

  |> Http.Router.get "/api/v1/board/reactions" (fun request reqd ->
       with_token_permission_auth
         ~permission:Masc_domain.CanReadState
         (fun _state actor req reqd ->
            let actor = board_actor_author_for_write actor in
            let result =
              Result.bind
                (Server_board_reaction_http.target_of_strings
                   ~target_type:(query_param req "target_type")
                   ~target_id:(query_param req "target_id"))
                (Server_board_reaction_http.list_json ~actor)
            in
            respond_board_reaction_result request reqd result)
         request
         reqd)

  |> Http.Router.post "/api/v1/board/reactions" (fun request reqd ->
       with_token_permission_auth
         ~permission:Masc_domain.CanVote
         (fun _state actor _req reqd ->
            let actor = board_actor_author_for_write actor in
            Http.Request.read_body_async reqd (fun body ->
              let parsed =
                match Yojson.Safe.from_string body with
                | json -> Server_board_reaction_http.toggle_request_of_json json
                | exception Yojson.Json_error message ->
                  Error (Server_board_reaction_http.malformed_json message)
              in
              let result =
                Result.bind
                  parsed
                  (Server_board_reaction_http.toggle_json ~actor)
              in
              respond_board_reaction_result request reqd result))
         request
         reqd)

  |> Http.Router.get "/api/v1/board/hearths" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let config = Mcp_server.workspace_config state in
         let cache_key =
           Printf.sprintf "board:hearths:%s"
             (Keeper_api_types.cache_key_string_segment config.base_path)
         in
         let json =
           Dashboard_cache.get_or_compute
             cache_key
             ~ttl:Server_dashboard_http_core_cache.standard_cache_ttl_s
             (fun () ->
                Domain_pool_ref.submit_io_or_inline (fun () ->
                  let hearths = Board_dispatch.list_hearths () in
                  `Assoc [
                    ("hearths", `List (List.map (fun (name, count) ->
                      `Assoc [("name", `String name); ("count", `Int count)]
                    ) hearths));
                  ]))
         in
         Http.Response.json_value json reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board/curation" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         respond_board_json reqd (board_curation_json ())
       ) request reqd)

  |> Http.Router.get "/api/v1/board/flairs" (fun _request reqd ->
       let flairs = List.map Board.flair_to_yojson Board.available_flairs in
       let json = `Assoc [("flairs", `List flairs)] in
       Http.Response.json_value json reqd)

  |> Http.Router.get "/api/v1/board/sub-boards" (fun _request reqd ->
       respond_board_json reqd (board_sub_boards_json ()))

  |> Http.Router.post "/api/v1/board/context-inference" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_keeper_msg"
         (fun state _req reqd ->
         Http.Request.read_body_async reqd
           (handle_board_context_inference_request ~state ~sw ~clock ~request
              reqd))
         request reqd)

  |> Http.Router.post "/api/v1/board/sub-boards" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_board_sub_board_create"
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
             let owner = board_tool_owner_from_request request in
             let access =
               match Safe_ops.json_string_opt "access" args with
               | Some s -> Board.sub_board_access_of_string_opt s
               | None -> None
             in
             (match Board_dispatch.create_sub_board ~slug ~name ~description
                      ~owner ~members ?access () with
              | Ok sb ->
                  Http.Response.json_value (Board.sub_board_to_yojson sb) reqd
              | Error e ->
                  Http.Response.json_value ~status:`Bad_request
                    (`Assoc [("error", `String (Board_tool.board_error_to_string e))])
                    reqd)
           with Yojson.Json_error msg ->
             Http.Response.json_value ~status:`Bad_request
               (`Assoc [("error", `String ("invalid JSON: " ^ msg))])
               reqd))
         request reqd)

  |> Http.Router.prefix_get "/api/v1/board/sub-boards/" (fun request reqd ->
       let path = Http.Request.path request in
       (match extract_path_param ~prefix:"/api/v1/board/sub-boards/" path with
        | None ->
            Http.Response.json_value ~status:`Bad_request
              (`Assoc [("error", `String "sub_board_id is required")])
              reqd
        | Some sub_board_id ->
            (match Board_dispatch.get_sub_board ~sub_board_id with
             | Ok sb ->
                 Http.Response.json_value (Board.sub_board_to_yojson sb) reqd
             | Error e ->
                 Http.Response.json_value ~status:`Not_found
                   (`Assoc [("error", `String (Board_tool.board_error_to_string e))])
                   reqd)))

  |> Http.Router.prefix_delete "/api/v1/board/sub-boards/" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_board_sub_board_delete"
         (fun _state _req reqd ->
         let path = Http.Request.path request in
         (match extract_path_param ~prefix:"/api/v1/board/sub-boards/" path with
          | None ->
              Http.Response.json_value ~status:`Bad_request
                (`Assoc [("error", `String "sub_board_id is required")])
                reqd
         | Some sub_board_id ->
              let owner = board_tool_owner_from_request request in
              (match Board_dispatch.get_sub_board ~sub_board_id with
               | Error e ->
                   Http.Response.json_value ~status:`Not_found
                     (`Assoc [("error", `String (Board_tool.board_error_to_string e))])
                     reqd
               | Ok sb when not (sub_board_owner_matches ~owner sb) ->
                   Http.Response.json_value ~status:`Forbidden
                     (sub_board_owner_error ~owner ~sub_board_id sb)
                     reqd
               | Ok _ ->
              (match Board_dispatch.delete_sub_board ~sub_board_id with
               | Ok () ->
                   Http.Response.json_value (`Assoc [("deleted", `Bool true)]) reqd
               | Error e ->
                   Http.Response.json_value ~status:`Not_found
                     (`Assoc [("error", `String (Board_tool.board_error_to_string e))])
                     reqd)))
         )
         request reqd)

  |> Http.Router.prefix_put "/api/v1/board/sub-boards/" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_board_sub_board_update"
         (fun _state _req reqd ->
         Http.Request.read_body_async reqd (fun body ->
           try
             let args = Yojson.Safe.from_string body in
             let name = Safe_ops.json_string_opt "name" args in
             let description = Safe_ops.json_string_opt "description" args in
             let members = Safe_ops.json_string_list "members" args in
             let members_arg = if members = [] then None else Some members in
             let access =
               match Safe_ops.json_string_opt "access" args with
               | Some s -> Board.sub_board_access_of_string_opt s
               | None -> None
             in
             let path = Http.Request.path request in
             (match extract_path_param ~prefix:"/api/v1/board/sub-boards/" path with
              | None ->
                  Http.Response.json_value ~status:`Bad_request
                    (`Assoc [("error", `String "sub_board_id is required")])
                    reqd
              | Some sub_board_id ->
                  let owner = board_tool_owner_from_request request in
                  (match Board_dispatch.get_sub_board ~sub_board_id with
                   | Error e ->
                       Http.Response.json_value ~status:`Not_found
                         (`Assoc [("error", `String (Board_tool.board_error_to_string e))])
                         reqd
                   | Ok sb when not (sub_board_owner_matches ~owner sb) ->
                       Http.Response.json_value ~status:`Forbidden
                         (sub_board_owner_error ~owner ~sub_board_id sb)
                         reqd
                   | Ok _ ->
                  (match Board_dispatch.update_sub_board ~sub_board_id ?name ?description ?members:members_arg ?access () with
                   | Ok sb ->
                       Http.Response.json_value (Board.sub_board_to_yojson sb) reqd
                   | Error e ->
                       Http.Response.json_value ~status:`Bad_request
                         (`Assoc [("error", `String (Board_tool.board_error_to_string e))])
                         reqd)))
           with Yojson.Json_error msg ->
             Http.Response.json_value ~status:`Bad_request
               (`Assoc [("error", `String ("invalid JSON: " ^ msg))])
               reqd))
         request reqd)

  |> Http.Router.prefix_get "/api/v1/board/" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let path = Http.Request.path request in
         (match extract_path_param ~prefix:"/api/v1/board/" path with
          | None ->
              Http.Response.json_value
                (`Assoc [("error", `String "post_id is required")])
                ~status:`Bad_request reqd
          | Some "curation" ->
              respond_board_json reqd (board_curation_json ())
          | Some "sub-boards" ->
              respond_board_json reqd (board_sub_boards_json ())
          | Some "karma/ledger" ->
              respond_board_json reqd (board_karma_ledger_json req)
          | Some post_id ->
              let config = Mcp_server.workspace_config state in
              with_optional_board_reaction_actor
                ~base_path:config.base_path
                req
                reqd
                (fun reaction_actor ->
                   match
                     Server_board_post_response_format.of_query
                       (query_param req "format")
                   with
                   | Error error ->
                     respond_json_value_with_cors
                       ~status:`Bad_request
                       request
                       reqd
                       (Server_board_post_response_format.error_json error)
                   | Ok response_format ->
                     let voter = board_voter_query req in
                     let blind_votes =
                       bool_query_param req "blind_votes" ~default:false
                     in
                     let include_moderation =
                       include_moderation_projection ~base_path:config.base_path req
                     in
                     let status, body =
                       board_post_detail_json
                         ~include_moderation
                         ~blind_votes
                         ~voter
                         ~reaction_actor
                         ~config:(Some config)
                         ~response_format
                         ~post_id
                     in
                     respond_json_with_cors ~status request reqd body))
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
                   respond_json_value_with_cors ~status:`Bad_request request reqd
                     (activity_result_json ~ok:false ~message:msg)
             in
             let* args =
               try Ok (Yojson.Safe.from_string body_str)
               with Yojson.Json_error msg -> Error ("Invalid JSON: " ^ msg)
             in
             let voter = board_actor_author_for_write agent_name in
             let* args = json_upsert_string_field "voter" voter args in
             let result = Board_tool.handle_tool "masc_board_vote" args in
             let ok = Tool_result.is_success result in
             let msg = Tool_result.message result in
             let status = if ok then `OK else `Bad_request in
             respond_json_value_with_cors ~status request reqd
               (activity_result_json ~ok ~message:msg)
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             respond_json_value_with_cors ~status:`Bad_request request reqd
               (activity_result_json ~ok:false ~message:(Printexc.to_string exn))
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
                   respond_json_value_with_cors ~status:`Bad_request request reqd
                     (activity_result_json ~ok:false ~message:msg)
             in
             let* args =
               try Ok (Yojson.Safe.from_string body_str)
               with Yojson.Json_error msg -> Error ("Invalid JSON: " ^ msg)
             in
             let author = board_actor_author_for_write agent_name in
             let* args = json_upsert_string_field "author" author args in
             let* args =
               if String.equal author (String.trim agent_name) then Ok args
               else
                 json_ensure_meta_string_field
                   Board_tool.author_raw_agent_name_meta_key
                   agent_name
                   args
             in
             let* args = json_ensure_meta_source "dashboard_board_post" args in
             let result = Board_tool.handle_tool "masc_board_post" args in
             let ok = Tool_result.is_success result in
             let msg = Tool_result.message result in
             let status = if ok then `Created else `Bad_request in
             respond_json_value_with_cors ~status request reqd
               (activity_result_json ~ok ~message:msg)
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             respond_json_value_with_cors ~status:`Bad_request request reqd
               (activity_result_json ~ok:false ~message:(Printexc.to_string exn))
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
                   respond_json_value_with_cors ~status:`Bad_request request reqd
                     (activity_result_json ~ok:false ~message:msg)
             in
             let* args =
               try Ok (Yojson.Safe.from_string body_str)
               with Yojson.Json_error msg -> Error ("Invalid JSON: " ^ msg)
             in
             let author = board_actor_author_for_write agent_name in
             let* args = json_upsert_string_field "author" author args in
             let result = Board_tool.handle_tool "masc_board_comment" args in
             let ok = Tool_result.is_success result in
             let msg = Tool_result.message result in
             let status = if ok then `Created else `Bad_request in
             respond_json_value_with_cors ~status request reqd
               (activity_result_json ~ok ~message:msg)
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             respond_json_value_with_cors ~status:`Bad_request request reqd
               (activity_result_json ~ok:false ~message:(Printexc.to_string exn))
         )
       ) request reqd)

  (* Comment vote — mirrors masc_board_vote. Server re-derives [voter] from the
     agent header so the client cannot forge the voting identity. *)
  |> Http.Router.post "/api/v1/tools/masc_board_comment_vote" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_board_comment_vote"
         (fun _state _req reqd ->
         let agent_name = board_tool_agent_name_from_request request in
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let ( let* ) r f =
               match r with
               | Ok v -> f v
               | Error msg ->
                   respond_json_value_with_cors ~status:`Bad_request request reqd
                     (activity_result_json ~ok:false ~message:msg)
             in
             let* args =
               try Ok (Yojson.Safe.from_string body_str)
               with Yojson.Json_error msg -> Error ("Invalid JSON: " ^ msg)
             in
             let voter = board_actor_author_for_write agent_name in
             let* args = json_upsert_string_field "voter" voter args in
             let result = Board_tool.handle_tool "masc_board_comment_vote" args in
             let ok = Tool_result.is_success result in
             let msg = Tool_result.message result in
             let status = if ok then `OK else `Bad_request in
             respond_json_value_with_cors ~status request reqd
               (activity_result_json ~ok ~message:msg)
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             respond_json_value_with_cors ~status:`Bad_request request reqd
               (activity_result_json ~ok:false ~message:(Printexc.to_string exn))
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
         Http.Response.json_value json reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board/karma/ledger" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         respond_board_json reqd (board_karma_ledger_json req)
       ) request reqd)

  (* Mention Inbox API *)
  |> Http.Router.prefix_get "/api/v1/mentions/" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let path = Http.Request.path request in
         (match extract_path_param ~prefix:"/api/v1/mentions/" path with
          | None ->
              Http.Response.json_value
                (`Assoc [("error", `String "agent_name is required")])
                ~status:`Bad_request reqd
          | Some agent_name ->
              let limit = standard_limit request in
              let mentions =
                Mention_inbox.read_mentions (Mcp_server.workspace_config state)
                  ~target_agent:agent_name ~limit
              in
              let unread =
                Mention_inbox.unread_count (Mcp_server.workspace_config state)
                  ~target_agent:agent_name
              in
              let json = `Assoc [
                ("agent", `String agent_name);
                ("unread_count", `Int unread);
                ("mentions", `List (List.map Mention_inbox.mention_record_to_json mentions));
              ] in
              Http.Response.json_value json reqd)
       ) request reqd)

  (* Agent Reputation API *)
  |> Http.Router.prefix_get "/api/v1/reputation/" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let path = Http.Request.path request in
         (match extract_path_param ~prefix:"/api/v1/reputation/" path with
          | None ->
              Http.Response.json_value
                (`Assoc [("error", `String "agent_name is required")])
                ~status:`Bad_request reqd
          | Some agent_name ->
              let rep =
                Reputation.compute_reputation
                  (Mcp_server.workspace_config state) ~agent_name
              in
              Http.Response.json_value
                (Reputation.reputation_to_json rep) reqd)
       ) request reqd)

  (* Activity Feed API *)
  |> Http.Router.get "/api/v1/activity" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let agent_name = query_param req "agent" in
         let limit = int_query_param req "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
         let items =
           Activity_feed.recent_activity (Mcp_server.workspace_config state)
             ?agent_name ~limit ()
         in
         let json = `Assoc [
           ("items", `List (List.map Activity_feed.activity_item_to_json items));
           ("count", `Int (List.length items));
         ] in
         Http.Response.json_value json reqd
       ) request reqd)

  (* Prompt Registry API *)
  |> Http.Router.get "/api/v1/prompts" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let json = Prompt_registry.prompts_json () in
         Http.Response.json_value json reqd
       ) request reqd)

  |> Http.Router.post "/api/v1/prompts" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_prompt_override"
         (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let key = Json_util.get_string args "key"
               |> Option.value ~default:"" in
             let action = Json_util.get_string args "action" in
             if key = "" then
               respond_json_value_with_cors ~status:`Bad_request request reqd
                 (`Assoc
                    [ ("ok", `Bool false); ("error", `String "key is required") ])
             else match action with
             | None ->
               respond_json_value_with_cors ~status:`Bad_request request reqd
                 (`Assoc
                    [
                      ("ok", `Bool false);
                      ("error", `String "action is required");
                    ])
             | Some action ->
               let result = match action with
                 | "clear" ->
                   (match
                      Prompt_registry.clear_prompt_override_persisted
                        ~base_path:
                          (Mcp_server.workspace_config state).base_path
                        key
                    with
                    | Ok () -> Ok "override cleared"
                    | Error message ->
                        Error (`Persistence message))
                 | "set" ->
                   let value = Json_util.get_string args "value"
                     |> Option.value ~default:"" in
                   (match
                      Prompt_registry.set_override_persisted
                        ~base_path:
                          (Mcp_server.workspace_config state).base_path
                        key value
                    with
                    | Ok () -> Ok "override set"
                    | Error (Prompt_registry.Validation_error message) ->
                        Error (`Validation message)
                    | Error (Prompt_registry.Persistence_error message) ->
                        Error (`Persistence message))
                 | unsupported ->
                     Error
                       (`Validation
                         (Printf.sprintf "unsupported action: %s" unsupported))
               in
               match result with
               | Ok msg ->
                 respond_json_value_with_cors request reqd
                   (`Assoc
                      [
                        ("ok", `Bool true);
                        ("message", `String msg);
                        ("key", `String key);
                        ("source", `String (Prompt_registry.prompt_source key));
                        ("effective", `String (Prompt_registry.get_prompt key));
                      ])
               | Error (`Validation msg) ->
                 respond_json_value_with_cors ~status:`Bad_request request reqd
                   (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])
               | Error (`Persistence msg) ->
                 Log.Pages.error "prompt override persist failed: %s" msg;
                 respond_json_value_with_cors ~status:`Internal_server_error
                   request reqd
                   (`Assoc
                      [
                        ("ok", `Bool false);
                        ("error", `String "prompt override persistence failed");
                      ])
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             respond_json_value_with_cors ~status:`Bad_request request reqd
               (`Assoc
                  [
                    ("ok", `Bool false);
                    ("error", `String (Printexc.to_string exn));
                  ])
         )
       ) request reqd)

  (* Runtime Params: set / clear *)
  |> Http.Router.post "/api/v1/runtime/params/set" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_set_param"
         (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let base_path = (Mcp_server.workspace_config state).base_path in
             let actor =
               sanitized_dashboard_actor_for_request ~base_path request
               |> Option.value ~default:"dashboard"
             in
             let param_key = Json_util.get_string args "param_key"
               |> Option.value ~default:"" |> String.trim in
             let value_json = Json_util.assoc_member_opt "value" args in
            if param_key = "" then
               respond_json_value_with_cors ~status:`Bad_request request reqd
                 (`Assoc
                    [ ("ok", `Bool false); ("error", `String "param_key is required") ])
             else match value_json with
             | None ->
               respond_json_value_with_cors ~status:`Bad_request request reqd
                 (`Assoc
                    [ ("ok", `Bool false); ("error", `String "value is required") ])
             | Some value ->
               let old_value =
                 match Runtime_params.registry ()
                   |> List.find_opt (fun (k, _, _, _, _) -> k = param_key) with
                 | Some (_, current, _, _, _) -> current
                 | None -> `Null
               in
               (match Runtime_params.set_by_key param_key value ~actor with
                | Error msg ->
                  respond_json_value_with_cors ~status:`Bad_request request reqd
                    (`Assoc [ "ok", `Bool false; "error", `String msg ])
                | Ok () ->
                  Sse.broadcast
                    (`Assoc
                       [ "type", `String "runtime_param_changed"
                       ; "param_key", `String param_key
                       ; "old_value", old_value
                       ; "new_value", value
                       ; "actor", `String actor
                       ]);
                  respond_json_value_with_cors request reqd
                    (`Assoc
                       [ "ok", `Bool true
                       ; ( "message"
                         , `String
                             (Printf.sprintf
                                "Set %s = %s"
                                param_key
                                (Yojson.Safe.to_string value)) )
                       ]))
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             respond_json_value_with_cors ~status:`Bad_request request reqd
               (`Assoc
                  [
                    ("ok", `Bool false);
                    ("error", `String (Printexc.to_string exn));
                  ])
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/runtime/params/clear" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_set_param"
         (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let param_key = Json_util.get_string args "param_key"
               |> Option.value ~default:"" in
             let base_path = (Mcp_server.workspace_config state).base_path in
             let actor =
               sanitized_dashboard_actor_for_request ~base_path request
               |> Option.value ~default:"dashboard"
             in
            if param_key = "" then
               respond_json_value_with_cors ~status:`Bad_request request reqd
                 (`Assoc
                    [ ("ok", `Bool false); ("error", `String "param_key is required") ])
             else
               let old_value =
                 match Runtime_params.registry ()
                   |> List.find_opt (fun (k, _, _, _, _) -> k = param_key) with
                 | Some (_, current, _, _, _) -> current
                 | None -> `Null
               in
               (match Runtime_params.clear_by_key param_key ~actor with
                | Error msg ->
                  respond_json_value_with_cors ~status:`Bad_request request reqd
                    (`Assoc [ "ok", `Bool false; "error", `String msg ])
                | Ok () ->
                  let new_value =
                    match Runtime_params.registry ()
                      |> List.find_opt (fun (k, _, _, _, _) -> k = param_key) with
                    | Some (_, _, default, _, _) -> default
                    | None -> `Null
                  in
                  Sse.broadcast
                    (`Assoc
                       [ "type", `String "runtime_param_changed"
                       ; "param_key", `String param_key
                       ; "old_value", old_value
                       ; "new_value", new_value
                       ; "actor", `String actor
                       ]);
                  respond_json_value_with_cors request reqd
                    (`Assoc
                       [ "ok", `Bool true
                       ; ( "message"
                         , `String (Printf.sprintf "Cleared %s to default" param_key) )
                       ]))
           with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
             respond_json_value_with_cors ~status:`Bad_request request reqd
               (`Assoc
                  [
                    ("ok", `Bool false);
                    ("error", `String (Printexc.to_string exn));
                  ])
         )
       ) request reqd)
