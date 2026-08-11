(** Regression guard for the dashboard board REST bridge (task-1647).

    The dashboard board API client (dashboard/src/api/board.ts) posts to
    [/api/v1/tools/masc_board_*] endpoints. Each MCP board tool the dashboard
    calls needs a matching REST route registered by
    {!Server_routes_http_routes_activity.add_routes}; a missing route makes the
    corresponding dashboard button return 404.

    [masc_board_comment_vote] existed as an MCP tool and was called by the
    comment up/down buttons, but had no REST route — every comment vote
    returned 404. This test builds the real router and asserts that every
    board tool the dashboard depends on resolves to a POST route.

    All [/api/v1/tools/*] routes are registered by this one module, so
    enumerating its [add_routes] output is exhaustive for this route family.
    The expected set mirrors the [/api/v1/tools/*] literals in
    dashboard/src/api/board.ts; adding a dashboard board endpoint requires both
    a new route and an entry here, so drift fails the build. *)

open Alcotest

module Http = Masc.Http_server_eio

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when Sys.file_exists (Filename.concat root "dune-project") -> root
  | _ -> Sys.getcwd ()

let source_file rel =
  let path = Filename.concat (source_root ()) rel in
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)

let contains ~needle haystack =
  String.length needle = 0 || String_util.contains_substring haystack needle

let () = Mirage_crypto_rng_unix.use_default ()

let with_reaction_auth_base f =
  let base_path = Filename.temp_dir "board-reaction-auth-" "" in
  Auth.save_auth_config
    base_path
    { Masc_domain.default_auth_config with enabled = true; require_token = true };
  f base_path

let reaction_auth_request ?token () =
  let headers =
    match token with
    | None -> Httpun.Headers.of_list []
    | Some token ->
      Httpun.Headers.of_list [ "authorization", "Bearer " ^ token ]
  in
  Httpun.Request.create ~headers `GET "/api/v1/board/reactions"

let reaction_internal_auth_request token =
  Httpun.Request.create
    ~headers:(Httpun.Headers.of_list [ "x-masc-internal-token", token ])
    `GET
    "/api/v1/board/reactions"

let reaction_raw_auth_request header value =
  Httpun.Request.create
    ~headers:(Httpun.Headers.of_list [ header, value ])
    `GET
    "/api/v1/board/reactions"

(* /api/v1/tools/* endpoints called by dashboard/src/api/board.ts.
   Kept in sync with that file — see module doc. *)
let dashboard_board_tool_routes =
  [ "/api/v1/tools/masc_board_vote"
  ; "/api/v1/tools/masc_board_post"
  ; "/api/v1/tools/masc_board_comment"
  ; "/api/v1/tools/masc_board_comment_vote"
  ]

let dashboard_board_reaction_routes =
  [ `GET, "/api/v1/board/reactions/catalog"
  ; `GET, "/api/v1/board/reactions"
  ; `POST, "/api/v1/board/reactions"
  ]

(* [add_routes] only registers closures — no fiber is spawned — so the
   [Eio_main.run] just supplies the switch + clock the handlers capture. *)
let with_router f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let clock = Eio.Stdenv.clock env in
      let router =
        Server_routes_http_routes_activity.add_routes
          ~sw
          ~clock
          (Http.Router.create ())
      in
      f router))

(* Every dashboard-consumed board tool must resolve to a Plain POST route. *)
let test_dashboard_board_routes_registered () =
  with_router (fun router ->
    List.iter
      (fun path ->
        let request = Httpun.Request.create `POST path in
        match Http.Router.resolve router request with
        | `Matched route -> (
          match route.Http.Router.handler with
          | Http.Router.Plain _ -> ()
          | Http.Router.Ws _ ->
            fail (Printf.sprintf "%s must be a Plain POST route, not Ws" path))
        | `Method_not_allowed ->
          fail (Printf.sprintf "%s exists but rejects POST" path)
        | `Not_found ->
          fail
            (Printf.sprintf
               "%s is not registered — dashboard call would 404"
               path))
      dashboard_board_tool_routes)

(* The registered /api/v1/tools/* set must equal the dashboard-consumed set:
   no orphan server route, no dashboard endpoint left unregistered. *)
let test_no_tools_route_drift () =
  with_router (fun router ->
    let registered =
      Http.Router.routes router
      |> List.filter_map (fun (r : Http.Router.route) ->
             if String.starts_with ~prefix:"/api/v1/tools/" r.Http.Router.path
             then Some r.Http.Router.path
             else None)
      |> List.sort_uniq String.compare
    in
    let expected = List.sort_uniq String.compare dashboard_board_tool_routes in
    check
      (list string)
      "registered /api/v1/tools/* routes match dashboard-consumed set"
      expected
      registered)

let test_dashboard_board_reaction_routes_registered () =
  with_router (fun router ->
    List.iter
      (fun (meth, path) ->
         let request = Httpun.Request.create meth path in
         match Http.Router.resolve router request with
         | `Matched { Http.Router.handler = Plain _; _ } -> ()
         | `Matched { Http.Router.handler = Ws _; _ } ->
           fail (Printf.sprintf "%s must be a plain HTTP route" path)
         | `Method_not_allowed ->
           fail (Printf.sprintf "%s rejects its dashboard HTTP method" path)
         | `Not_found ->
           fail (Printf.sprintf "%s is not registered" path))
      dashboard_board_reaction_routes)

let test_board_reaction_catalog_uses_board_ssot () =
  match Server_board_reaction_http.catalog_json () with
  | `Assoc fields ->
    let actual =
      match List.assoc_opt "supported_reaction_emojis" fields with
      | Some (`List values) ->
        List.filter_map (function `String value -> Some value | _ -> None) values
      | Some _ | None -> fail "supported_reaction_emojis must be a JSON array"
    in
    check (list string) "catalog" Masc.Board.board_reaction_emojis actual
  | _ -> fail "reaction catalog must be a JSON object"

let test_board_reaction_optional_auth_is_anonymous_only_without_header () =
  with_reaction_auth_base (fun base_path ->
    match
      Server_auth.authorize_optional_token_bound_permission_request
        ~base_path
        ~permission:Masc_domain.CanReadState
        (reaction_auth_request ())
    with
    | Ok None -> ()
    | Ok (Some actor) ->
      failf "headerless request unexpectedly resolved actor %s" actor
    | Error error -> fail (Masc_domain.masc_error_to_string error))

let test_board_reaction_optional_auth_rejects_invalid_header () =
  with_reaction_auth_base (fun base_path ->
    match
      Server_auth.authorize_optional_token_bound_permission_request
        ~base_path
        ~permission:Masc_domain.CanReadState
        (reaction_auth_request ~token:"invalid-board-reaction-token" ())
    with
    | Error error ->
      check bool "invalid credential is unauthorized" true
        (Server_auth.http_status_of_auth_error error = `Unauthorized)
    | Ok None -> fail "invalid Authorization header fell back to anonymous"
    | Ok (Some actor) -> failf "invalid credential resolved actor %s" actor)

let test_board_reaction_optional_auth_rejects_invalid_internal_header () =
  with_reaction_auth_base (fun base_path ->
    match
      Server_auth.authorize_optional_token_bound_permission_request
        ~base_path
        ~permission:Masc_domain.CanReadState
        (reaction_internal_auth_request "invalid-internal-token")
    with
    | Error error ->
      check bool "invalid internal credential is unauthorized" true
        (Server_auth.http_status_of_auth_error error = `Unauthorized)
    | Ok None -> fail "invalid internal bearer fell back to anonymous"
    | Ok (Some actor) -> failf "invalid internal bearer resolved actor %s" actor)

let test_board_reaction_optional_auth_rejects_malformed_credentials () =
  with_reaction_auth_base (fun base_path ->
    List.iter
      (fun (label, request) ->
         check bool
           (label ^ " is detected as a credential")
           true
           (Server_auth.request_carries_auth_credential request);
         match
           Server_auth.authorize_optional_token_bound_permission_request
             ~base_path
             ~permission:Masc_domain.CanReadState
             request
         with
         | Error error ->
           check bool
             (label ^ " is unauthorized")
             true
             (Server_auth.http_status_of_auth_error error = `Unauthorized)
         | Ok None -> failf "%s fell back to anonymous" label
         | Ok (Some actor) -> failf "%s resolved actor %s" label actor)
      [ ( "malformed Authorization"
        , reaction_raw_auth_request "authorization" "Basic not-a-bearer" )
      ; ( "empty internal credential"
        , reaction_raw_auth_request "x-masc-internal-token" " " )
      ])

let test_dashboard_dev_token_can_vote_as_credential_owner () =
  with_reaction_auth_base (fun base_path ->
    match
      Server_routes_http_dashboard_dev_token.ensure_dashboard_dev_token base_path
    with
    | Error error ->
      fail
        (Server_routes_http_dashboard_dev_token.token_error_to_string error)
    | Ok token ->
      match
        Server_auth.authorize_token_bound_permission_request
          ~base_path
          ~permission:Masc_domain.CanVote
          (reaction_auth_request ~token:token.raw ())
      with
      | Ok actor -> check string "dashboard credential owner" "dashboard" actor
      | Error error -> fail (Masc_domain.masc_error_to_string error))

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> fail "failed to construct loopback request authority"

let mutation_request ?(origin = "https://attacker.example") meth path =
  Httpun.Request.create
    ~headers:(Httpun.Headers.of_list [ "origin", origin ])
    meth
    path

let test_activity_mutation_routes_use_shared_auth () =
  let source = source_file "lib/server/server_routes_http_routes_activity.ml" in
  check bool "activity routes do not shadow shared tool auth" false
    (contains
       ~needle:"let with_tool_auth ~tool_name:_ handler = with_public_read handler"
       source);
  check bool "activity routes delegate tool auth to Server_auth" true
    (contains ~needle:"let with_tool_auth = Server_auth.with_tool_auth" source);
  List.iter
    (fun (label, needle) -> check bool label true (contains ~needle source))
    [
      ( "keeper delegate remains tool-gated"
      , "with_tool_auth ~tool_name:\"masc_keeper_delegate\"" );
      ( "board sub-board create remains tool-gated"
      , "with_tool_auth ~tool_name:\"masc_board_sub_board_create\"" );
      ( "board sub-board delete remains tool-gated"
      , "with_tool_auth ~tool_name:\"masc_board_sub_board_delete\"" );
      ( "board sub-board update remains tool-gated"
      , "with_tool_auth ~tool_name:\"masc_board_sub_board_update\"" );
      ( "board vote remains tool-gated"
      , "with_tool_auth ~tool_name:\"masc_board_vote\"" );
      ( "board post remains tool-gated"
      , "with_tool_auth ~tool_name:\"masc_board_post\"" );
      ( "board comment remains tool-gated"
      , "with_tool_auth ~tool_name:\"masc_board_comment\"" );
      ( "board comment vote remains tool-gated"
      , "with_tool_auth ~tool_name:\"masc_board_comment_vote\"" );
      ( "prompt override remains tool-gated"
      , "with_tool_auth ~tool_name:\"masc_prompt_override\"" );
      ( "runtime parameter mutations remain tool-gated"
      , "with_tool_auth ~tool_name:\"masc_set_param\"" );
      ( "board reaction mutation keeps CanVote auth"
      , "with_token_permission_auth\n         ~permission:Masc_domain.CanVote" );
    ]

let test_activity_mutations_reject_missing_token () =
  with_reaction_auth_base (fun base_path ->
    let authority = loopback_request_authority () in
    let tool_routes =
      [ "masc_keeper_delegate", "/api/v1/board/context-inference"
      ; "masc_board_sub_board_create", "/api/v1/board/sub-boards"
      ; "masc_board_sub_board_delete", "/api/v1/board/sub-boards/id"
      ; "masc_board_sub_board_update", "/api/v1/board/sub-boards/id"
      ; "masc_board_vote", "/api/v1/tools/masc_board_vote"
      ; "masc_board_post", "/api/v1/tools/masc_board_post"
      ; "masc_board_comment", "/api/v1/tools/masc_board_comment"
      ; "masc_board_comment_vote", "/api/v1/tools/masc_board_comment_vote"
      ; "masc_prompt_override", "/api/v1/prompts"
      ; "masc_set_param", "/api/v1/runtime/params/set"
      ; "masc_set_param", "/api/v1/runtime/params/clear"
      ]
    in
    List.iter
      (fun (tool_name, path) ->
         match
           Server_auth.authorize_tool_request
             ~base_path
             ~tool_name
             ~request_authority:authority
             (mutation_request `POST path)
         with
         | Error _ -> ()
         | Ok () -> failf "%s accepted an unauthenticated mutation" path)
      tool_routes;
    match
      Server_auth.authorize_token_bound_permission_request
        ~base_path
        ~permission:Masc_domain.CanVote
        (mutation_request `POST "/api/v1/board/reactions")
    with
    | Error _ -> ()
    | Ok actor ->
      failf "board reaction mutation accepted unauthenticated actor %s" actor)

let test_activity_board_vote_accepts_authorized_token () =
  with_reaction_auth_base (fun base_path ->
    match
      Server_routes_http_dashboard_dev_token.ensure_dashboard_dev_token base_path
    with
    | Error error ->
      fail (Server_routes_http_dashboard_dev_token.token_error_to_string error)
    | Ok token ->
      let request =
        Httpun.Request.create
          ~headers:
            (Httpun.Headers.of_list
               [ "authorization", String.concat "" [ "Bearer "; token.raw ] ])
          `POST
          "/api/v1/tools/masc_board_vote"
      in
      match
        Server_auth.authorize_tool_request
          ~base_path
          ~tool_name:"masc_board_vote"
          ~request_authority:(loopback_request_authority ())
          request
      with
      | Ok () -> ()
      | Error error -> fail (Masc_domain.masc_error_to_string error))

let () =
  run
    "board_rest_routes"
    [ ( "dashboard bridge"
      , [ test_case
            "dashboard board tool routes registered"
            `Quick
            test_dashboard_board_routes_registered
        ; test_case
            "no /api/v1/tools/* route drift"
            `Quick
            test_no_tools_route_drift
        ; test_case
            "dashboard board reaction routes registered"
            `Quick
            test_dashboard_board_reaction_routes_registered
        ; test_case
            "reaction catalog uses Board SSOT"
            `Quick
            test_board_reaction_catalog_uses_board_ssot
        ; test_case
            "optional reaction auth is anonymous only without header"
            `Quick
            test_board_reaction_optional_auth_is_anonymous_only_without_header
        ; test_case
            "optional reaction auth rejects invalid header"
            `Quick
            test_board_reaction_optional_auth_rejects_invalid_header
        ; test_case
            "optional reaction auth rejects invalid internal header"
            `Quick
            test_board_reaction_optional_auth_rejects_invalid_internal_header
        ; test_case
            "optional reaction auth rejects malformed credentials"
            `Quick
            test_board_reaction_optional_auth_rejects_malformed_credentials
        ; test_case
            "dashboard dev-token can vote as credential owner"
            `Quick
            test_dashboard_dev_token_can_vote_as_credential_owner
        ; test_case
            "activity mutations use shared auth combinators"
            `Quick
            test_activity_mutation_routes_use_shared_auth
        ; test_case
            "activity mutations reject missing tokens"
            `Quick
            test_activity_mutations_reject_missing_token
        ; test_case
            "authorized dashboard token reaches board vote auth"
            `Quick
            test_activity_board_vote_accepts_authorized_token
        ] )
    ]
