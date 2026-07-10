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
      match List.assoc_opt "supported_emojis" fields with
      | Some (`List values) ->
        List.filter_map (function `String value -> Some value | _ -> None) values
      | Some _ | None -> fail "supported_emojis must be a JSON array"
    in
    check (list string) "catalog" Board.board_reaction_emojis actual
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

let test_dashboard_dev_token_can_vote_as_credential_owner () =
  with_reaction_auth_base (fun base_path ->
    match
      Server_routes_http_dashboard_dev_token.ensure_dashboard_dev_token base_path
    with
    | Error message -> fail message
    | Ok token ->
      match
        Server_auth.authorize_token_bound_permission_request
          ~base_path
          ~permission:Masc_domain.CanVote
          (reaction_auth_request ~token ())
      with
      | Ok actor -> check string "dashboard credential owner" "dashboard" actor
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
            "dashboard dev-token can vote as credential owner"
            `Quick
            test_dashboard_dev_token_can_vote_as_credential_owner
        ] )
    ]
