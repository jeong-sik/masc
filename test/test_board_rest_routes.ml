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

(* /api/v1/tools/* endpoints called by dashboard/src/api/board.ts.
   Kept in sync with that file — see module doc. *)
let dashboard_board_tool_routes =
  [ "/api/v1/tools/masc_board_vote"
  ; "/api/v1/tools/masc_board_post"
  ; "/api/v1/tools/masc_board_comment"
  ; "/api/v1/tools/masc_board_comment_vote"
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
        ] )
    ]
