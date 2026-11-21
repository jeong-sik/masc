(* The account gate decides against the route inventory. Each case here fails
   the guard it names: a gate that refuses nothing would pass a test that only
   checks the allowed path, so the refusal cases are the point. *)

(* [masc] is wrapped, so the router and [Route_access] are reached through it;
   the server modules are not wrapped and are used by their own names. *)
open Alcotest
open Masc

let get = `GET
let post = `POST

let exact ?(methods = [ get ]) path access =
  { Server_account_route.path
  ; kind = Http_server_eio.Router.Exact
  ; methods
  ; access
  }
;;

let prefix ?(methods = [ get ]) path access =
  { Server_account_route.path
  ; kind = Http_server_eio.Router.Prefix
  ; methods
  ; access
  }
;;

let inventory () =
  [ exact "/api/v1/dashboard/board" Route_access.Always_public
  ; exact
      "/api/v1/dashboard/nav-event"
      (Route_access.Public_read Route_access.Open_when_strict)
  ; prefix Server_account_route.keeper_prefix Route_access.Read_auth
  ]
;;

let is_refused_uninventoried = function
  | Server_account_gate.Refused (Server_account_gate.Uninventoried _) -> true
  | Server_account_gate.Allowed _
  | Server_account_gate.Refused Server_account_gate.Keeper_prefix_missing -> false
;;

let test_refuses_a_path_the_inventory_does_not_name () =
  check bool "unknown path is refused" true
    (is_refused_uninventoried
       (Server_account_gate.decide (inventory ())
          ~path:"/api/v1/dashboard/unregistered"
          ~method_:get));
  check string "the refusal names the path"
    "GET /api/v1/dashboard/unregistered is not a route the account inventory names"
    (match Server_account_gate.decide (inventory ())
           ~path:"/api/v1/dashboard/unregistered"
           ~method_:get
     with
     | Server_account_gate.Refused refusal -> Server_account_gate.refusal_text refusal
     | Server_account_gate.Allowed _ -> "allowed")
;;

let test_refuses_everything_when_the_inventory_is_empty () =
  check bool "an empty inventory allows nothing" true
    (is_refused_uninventoried
       (Server_account_gate.decide [] ~path:"/api/v1/dashboard/board" ~method_:get))
;;

let test_allows_a_named_path () =
  match Server_account_gate.decide (inventory ()) ~path:"/api/v1/dashboard/board" ~method_:get with
  | Server_account_gate.Allowed entry ->
    check string "the entry the inventory named" "/api/v1/dashboard/board" entry.path
  | Server_account_gate.Refused refusal ->
    check string "refused" "allowed" (Server_account_gate.refusal_text refusal)
;;

let test_refuses_a_method_the_route_does_not_list () =
  check bool "GET only route refuses POST" true
    (is_refused_uninventoried
       (Server_account_gate.decide (inventory ())
          ~path:"/api/v1/dashboard/board"
          ~method_:post))
;;

let test_a_prefix_covers_its_sub_routes () =
  check bool "a keeper sub-route is covered by its prefix" true
    (match
       Server_account_gate.decide (inventory ()) ~path:"/api/v1/keepers/k/metrics" ~method_:get
     with
     | Server_account_gate.Allowed entry -> String.equal entry.path Server_account_route.keeper_prefix
     | Server_account_gate.Refused _ -> false)
;;

let test_an_exact_route_does_not_cover_a_child_path () =
  check bool "exact route does not cover a child path" true
    (is_refused_uninventoried
       (Server_account_gate.decide (inventory ())
          ~path:"/api/v1/dashboard/board/extra"
          ~method_:get))
;;

let test_reconcile_refuses_an_empty_inventory () =
  check bool "empty inventory is an error" true
    (match Server_account_gate.reconcile [] with
     | Error _ -> true
     | Ok () -> false)
;;

let test_reconcile_refuses_a_missing_keeper_prefix () =
  check bool "missing keeper prefix is an error" true
    (match
       Server_account_gate.reconcile
         [ exact "/api/v1/dashboard/board" Route_access.Always_public ]
     with
     | Error message -> String.length message > 0
     | Ok () -> false)
;;

let test_reconcile_refuses_one_path_with_two_accesses () =
  check bool "one path with two accesses is an error" true
    (match
       Server_account_gate.reconcile
         [ exact "/api/v1/dashboard/board" Route_access.Always_public
         ; exact "/api/v1/dashboard/board" Route_access.Read_auth
         ; prefix Server_account_route.keeper_prefix Route_access.Read_auth
         ]
     with
     | Error _ -> true
     | Ok () -> false)
;;

let test_reconcile_accepts_the_inventory () =
  check bool "the inventory reconciles" true
    (match Server_account_gate.reconcile (inventory ()) with
     | Ok () -> true
     | Error message ->
       check string "reconcile" "" message;
       false)
;;

let method_names methods =
  List.map (fun method_ -> Httpun.Method.to_string method_) methods
;;

let test_methods_at_names_what_the_path_answers () =
  let entries =
    [ exact ~methods:[ get ] "/x" Route_access.Always_public
    ; exact ~methods:[ post ] "/x" Route_access.Always_public
    ; prefix ~methods:[ get ] "/k/" Route_access.Read_auth
    ]
  in
  check (list string) "both methods at one path, in registration order" [ "GET"; "POST" ]
    (method_names (Server_account_route.methods_at entries ~path:"/x"));
  check (list string) "a prefix answers its methods for a sub-path" [ "GET" ]
    (method_names (Server_account_route.methods_at entries ~path:"/k/one"));
  check (list string) "a path nothing answers has no method" []
    (method_names (Server_account_route.methods_at entries ~path:"/nowhere"))
;;

(* The inventory is the router's own table, so a registration that the router
   accepted cannot be missing from it: this is the property the boot check
   leans on, not a copy of a list written by hand. *)
let test_of_router_sees_every_registration () =
  let plain : Http_server_eio.request_handler = fun _request _reqd -> () in
  let state : Server_route.state_handler = fun _state _request _reqd -> () in
  let router =
    Http_server_eio.Router.create ()
    |> Server_route.get Server_route.Always_public "/a" plain
    |> Server_route.get Server_route.Read_auth "/b" state
  in
  let entries = Server_account_route.of_router router in
  check int "the inventory holds every registration" 2 (List.length entries);
  check (list string) "in registration order" [ "/a"; "/b" ]
    (List.map (fun (entry : Server_account_route.entry) -> entry.path) entries);
  check bool "a registered path is covered" true
    (Server_account_route.covers entries ~path:"/a" ~method_:get)
;;

(* The gate is only useful if it is closed on the paths that look almost like a
   route: a different case, a trailing slash, an encoded segment, an empty path,
   or a prefix without its slash. Each is read as "not this route". *)
let test_refuses_paths_beside_a_route () =
  let entries = inventory () in
  let refused path =
    is_refused_uninventoried (Server_account_gate.decide entries ~path ~method_:get)
  in
  check bool "a different case is a different path" true (refused "/API/v1/dashboard/board");
  check bool "a trailing slash is a different path" true
    (refused "/api/v1/dashboard/board/");
  check bool "a percent-encoded segment is not decoded" true
    (refused "/api/v1/dashboard/%62oard");
  check bool "the empty path is not a route" true (refused "");
  check bool "a prefix is not itself a route" true (refused "/api/v1/keepers");
  check bool "a sub-route of the prefix is named" false
    (refused "/api/v1/keepers/alice/metrics")
;;

let test_reconcile_refuses_a_prefix_without_a_slash () =
  let entries =
    [ exact "/api/v1/dashboard/board" Route_access.Always_public
    ; prefix Server_account_route.keeper_prefix Route_access.Read_auth
    ; prefix "/api/v1/board" Route_access.Always_public
    ]
  in
  check bool "a prefix that reaches beside itself is refused" true
    (match Server_account_gate.reconcile entries with
     | Error _ -> true
     | Ok () -> false)
;;

let () =
  Alcotest.run
    "server_account_gate"
    [ ( "inventory"
      , [ test_case "refuses a path the inventory does not name" `Quick
            test_refuses_a_path_the_inventory_does_not_name
        ; test_case "refuses everything when the inventory is empty" `Quick
            test_refuses_everything_when_the_inventory_is_empty
        ; test_case "allows a named path" `Quick test_allows_a_named_path
        ; test_case "refuses a method the route does not list" `Quick
            test_refuses_a_method_the_route_does_not_list
        ; test_case "refuses the paths beside a route" `Quick
            test_refuses_paths_beside_a_route
        ; test_case "a prefix covers its sub-routes" `Quick test_a_prefix_covers_its_sub_routes
        ; test_case "an exact route does not cover a child path" `Quick
            test_an_exact_route_does_not_cover_a_child_path
        ] )
    ; ( "reconcile"
      , [ test_case "refuses an empty inventory" `Quick
            test_reconcile_refuses_an_empty_inventory
        ; test_case "refuses a missing keeper prefix" `Quick
            test_reconcile_refuses_a_missing_keeper_prefix
        ; test_case "refuses one path with two accesses" `Quick
            test_reconcile_refuses_one_path_with_two_accesses
        ; test_case "refuses a prefix without its slash" `Quick
            test_reconcile_refuses_a_prefix_without_a_slash
        ; test_case "accepts the inventory" `Quick test_reconcile_accepts_the_inventory
        ] )
    ; ( "table"
      , [ test_case "names what a path answers" `Quick
            test_methods_at_names_what_the_path_answers
        ; test_case "sees every registration" `Quick test_of_router_sees_every_registration
        ] )
    ]
;;
