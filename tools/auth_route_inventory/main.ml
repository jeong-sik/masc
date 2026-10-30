(* Prints the routes of the HTTP/1 [Router] that dispatch can reach as JSON: kind,
   path, methods, whether the handler upgrades to WebSocket, and the access the
   registration recorded ([Route_access]). A registration that a later one
   replaced is not listed; [registrations] counts every row that was registered.
   The auth baseline probe reads it so that the list of probed paths comes from
   the router, not from a copy. *)

module Http = Masc.Http_server_eio

let kind_to_string = function
  | Http.Router.Exact -> "exact"
  | Http.Router.Prefix -> "prefix"
;;

let target_to_string = function
  | Http.Router.Plain _ -> "plain"
  | Http.Router.Ws _ -> "ws"
;;

let route_to_json (route : Http.Router.route) =
  `Assoc
    [ "kind", `String (kind_to_string route.kind)
    ; "path", `String route.path
    ; "methods", `List (List.map (fun m -> `String (Httpun.Method.to_string m)) route.methods)
    ; "target", `String (target_to_string route.handler)
    ; "access", Masc.Route_access.to_json route.access
    ]
;;

let () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let router =
        Server_routes_http.make_routes
          ~port:0
          ~host:"127.0.0.1"
          ~sw
          ~clock:(Eio.Stdenv.clock env)
      in
      let routes = Http.Router.effective_routes router in
      print_endline
        (Yojson.Safe.pretty_to_string
           (`Assoc
             [ "route_count", `Int (List.length routes)
             ; "registrations", `Int (Http.Router.route_count router)
             ; "routes", `List (List.map route_to_json routes)
             ]))))
;;
