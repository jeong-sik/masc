let rewrite ?early ?allow_named source =
  match Route_auth_rewrite.rewrite ?early ?allow_named ~file:"test.ml" source with
  | Ok result -> result
  | Error message -> Alcotest.failf "rewrite failed: %s" message
;;

let check_parses text =
  match Parse.implementation (Lexing.from_string text) with
  | (_ : Parsetree.structure) -> ()
  | exception exn ->
    Alcotest.failf "the output does not parse (%s):\n%s" (Printexc.to_string exn) text
;;

let sites (report : Route_auth_rewrite.report) =
  List.map
    (fun (site : Route_auth_rewrite.site) -> site.path, site.note)
    report.unhandled
;;

(* ---- registrations the tool converts ---- *)

let converted_cases =
  [ ( "inline partial with a constant permission remains convertible"
    , {|let routes routes =
  routes |> Http.Router.get "/api/x" (with_permission_auth ~permission:Masc_domain.CanAdmin handler)
|}
    , {|let routes routes =
  routes |> Server_route.get (Server_route.Permission Masc_domain.CanAdmin) "/api/x" handler
|} )
  ; ( "public read, and the Router qualification is kept apart from the kind"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (fun request reqd ->
       with_public_read (fun _state req reqd -> handle req reqd) request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.get Server_route.Public_read "/api/x" (fun _state req reqd -> handle req reqd)
|}
    )
  ; ( "read auth through qualified names"
    , {|let routes routes =
  routes
  |> Http_server_eio.Router.get "/api/x" (fun request reqd ->
       Server_auth.with_read_auth (fun _state req reqd -> handle req reqd) request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.get Server_route.Read_auth "/api/x" (fun _state req reqd -> handle req reqd)
|}
    )
  ; ( "permission"
    , {|let routes routes =
  routes
  |> Http.Router.post "/api/x" (fun request reqd ->
       with_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state req reqd -> handle state req reqd) request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.post (Server_route.Permission Masc_domain.CanAdmin) "/api/x" (fun state req reqd -> handle state req reqd)
|}
    )
  ; ( "token permission"
    , {|let routes routes =
  routes
  |> Http.Router.post "/api/x" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAddTask
         (fun state token req reqd -> handle state token req reqd) request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAddTask) "/api/x" (fun state token req reqd -> handle state token req reqd)
|}
    )
  ; ( "private token permission"
    , {|let routes routes =
  routes
  |> Http.Router.post "/api/x" (fun request reqd ->
       with_private_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state token req reqd -> handle state token req reqd) request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.post (Server_route.Private_token_permission Masc_domain.CanAdmin) "/api/x" (fun state token req reqd -> handle state token req reqd)
|}
    )
  ; ( "tool"
    , {|let routes routes =
  routes
  |> Http.Router.post "/api/x" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_board_post"
         (fun state req reqd -> handle state req reqd) request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.post (Server_route.Tool { tool_name = "masc_board_post" }) "/api/x" (fun state req reqd -> handle state req reqd)
|}
    )
  ; ( "tool actor"
    , {|let routes routes =
  routes
  |> Http.Router.post "/api/x" (fun request reqd ->
       with_tool_actor_auth ~tool_name:"masc_board_post"
         (fun state actor req reqd -> handle state actor req reqd) request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.post (Server_route.Tool_actor { tool_name = "masc_board_post" }) "/api/x" (fun state actor req reqd -> handle state actor req reqd)
|}
    )
  ; ( "prefix registration"
    , {|let routes routes =
  routes
  |> Http.Router.prefix_get "/api/files/" (fun request reqd ->
       with_read_auth (fun _state req reqd -> handle req reqd) request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.prefix_get Server_route.Read_auth "/api/files/" (fun _state req reqd -> handle req reqd)
|}
    )
  ; ( "add takes the handler as a label, and the label goes"
    , {|let routes routes =
  routes
  |> Http.Router.add ~path:"/graphql" ~methods:[`GET; `POST]
       ~handler:(fun request reqd ->
         with_read_auth (fun _state req reqd -> handle_graphql req reqd) request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.add Server_route.Read_auth ~path:"/graphql" ~methods:[`GET; `POST]
       (fun _state req reqd -> handle_graphql req reqd)
|}
    )
  ; ( "add with the handler on the line after its label"
    , {|let routes routes =
  routes
  |> Http.Router.add ~path:"/x" ~methods:[`GET] ~handler:
       (fun request reqd -> with_read_auth (fun _state req reqd -> h req reqd) request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.add Server_route.Read_auth ~path:"/x" ~methods:[`GET] (fun _state req reqd -> h req reqd)
|}
    )
  ; ( "the wrapper applied without the outer function"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (with_public_read (fun _state req reqd -> handle req reqd))
|}
    , {|let routes routes =
  routes
  |> Server_route.get Server_route.Public_read "/api/x" (fun _state req reqd -> handle req reqd)
|}
    )
  ; ( "a named function inside the wrapper"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (fun request reqd -> with_read_auth handle_x request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.get Server_route.Read_auth "/api/x" handle_x
|}
    )
  ; ( "the inner function binds the outer names itself"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (fun request reqd ->
       with_public_read (fun _state request reqd -> handle request reqd) request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.get Server_route.Public_read "/api/x" (fun _state request reqd -> handle request reqd)
|}
    )
  ; ( "the inner handler reads the outer request and ignores its own"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (fun request reqd ->
       with_public_read (fun state _req reqd -> handle ~request state reqd) request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.get Server_route.Public_read "/api/x" (fun state request reqd -> handle ~request state reqd)
|}
    )
  ; ( "the unused parameter is a wildcard"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (fun request reqd ->
       with_public_read (fun state _ reqd -> handle ~request state reqd) request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.get Server_route.Public_read "/api/x" (fun state request reqd -> handle ~request state reqd)
|}
    )
  ; ( "the outer request is in the second to last place of a longer parameter list"
    , {|let routes routes =
  routes
  |> Http.Router.post "/api/x" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state token _req reqd -> handle ~request state token reqd) request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/x" (fun state token request reqd -> handle ~request state token reqd)
|}
    )
  ; ( "the inner handler reads the outer reqd and ignores its own"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (fun request reqd ->
       with_public_read (fun _state req _ -> handle req reqd) request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.get Server_route.Public_read "/api/x" (fun _state req reqd -> handle req reqd)
|}
    )
  ; ( "the inner handler reads both outer names"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (fun request reqd ->
       with_public_read (fun state _ _ -> handle request state reqd) request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.get Server_route.Public_read "/api/x" (fun state request reqd -> handle request state reqd)
|}
    )
  ; ( "the inner handler reads the outer request and also uses its own"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (fun request reqd ->
       with_public_read (fun state req reqd -> handle req ~request state reqd) request reqd)
|}
    , {|let routes routes =
  routes
  |> Server_route.get Server_route.Public_read "/api/x" (fun state req reqd -> let request = req in handle req ~request state reqd)
|}
    )
  ; ( "a comment between the function and the wrapper moves above the registration"
    , {|let routes routes =
  routes
  |> Http.Router.post "/api/x" (fun request reqd ->
       (* admins only,
          for two reasons *)
       with_permission_auth ~permission:Masc_domain.CanAdmin
         (fun _state req reqd -> handle req reqd) request reqd)
|}
    , {|let routes routes =
  routes
  (* admins only,
     for two reasons *)
  |> Server_route.post (Server_route.Permission Masc_domain.CanAdmin) "/api/x" (fun _state req reqd -> handle req reqd)
|}
    )
  ; ( "two comments, one after the handler"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (fun request reqd ->
       (* first *)
       with_read_auth (fun _state req reqd -> handle req reqd) request reqd (* second *))
|}
    , {|let routes routes =
  routes
  (* first *)
  (* second *)
  |> Server_route.get Server_route.Read_auth "/api/x" (fun _state req reqd -> handle req reqd)
|}
    )
  ; ( "other names for the outer parameters"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (fun r d ->
       with_public_read (fun _state req reqd -> handle req reqd) r d)
|}
    , {|let routes routes =
  routes
  |> Server_route.get Server_route.Public_read "/api/x" (fun _state req reqd -> handle req reqd)
|}
    )
  ]
;;

let check_converted (name, source, expected) =
  Alcotest.test_case name `Quick (fun () ->
    let rewritten, report = rewrite source in
    Alcotest.(check string) "text" expected rewritten;
    Alcotest.(check int) "converted" 1 report.converted;
    Alcotest.(check (list (pair string string))) "left alone" [] (sites report);
    Alcotest.(check int) "evaluated once" 0 (List.length report.early);
    check_parses rewritten;
    let again, second = rewrite rewritten in
    Alcotest.(check string) "a second run changes nothing" rewritten again;
    Alcotest.(check int) "a second run converts nothing" 0 second.converted)
;;

(* ---- registrations the tool leaves alone ---- *)

let left_alone_cases =
  [ ( "a named handler"
    , {|let routes routes =
  routes |> Http.Router.get "/api/x" handle_x
|}
    , "/api/x"
    , "named handler handle_x" )
  ; ( "a helper that wraps the handler"
    , {|let routes routes =
  routes |> Http.Router.get "/api/x" (authorized (fun _state req reqd -> h req reqd))
|}
    , "/api/x"
    , "handler is a call of authorized" )
  ; ( "a handler with no wrapper"
    , {|let routes routes =
  routes |> Http.Router.get "/api/x" (fun request reqd -> Http.Response.text ~request "ok" reqd)
|}
    , "/api/x"
    , "handler body is not a wrapper call" )
  ; ( "the inner handler binds the outer name deeper down and may also read the outer one"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (fun request reqd ->
       with_public_read (fun _state _req reqd' ->
         log request;
         let request = other () in
         handle request reqd') request reqd)
|}
    , "/api/x"
    , "the wrapped handler binds request itself and may read the outer one" )
  ; ( "the wrapper is applied to other values"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (fun request reqd ->
       with_public_read (fun _state req reqd -> handle req reqd) other reqd)
|}
    , "/api/x"
    , "the wrapper is not applied to the request and reqd of the handler" )
  ; ( "a computed permission would be evaluated at registration"
    , {|let routes routes =
  routes
  |> Http.Router.post "/api/x" (fun request reqd ->
       with_permission_auth ~permission:(permission_of_env ())
         (fun _state req reqd -> handle req reqd) request reqd)
|}
    , "/api/x"
    , "~permission of with_permission_auth is computed, so it would be evaluated at registration instead of on every request" )
  ; ( "a direct outer argument is not a constant permission"
    , {|let routes routes =
  routes |> Http.Router.get "/api/x" (fun request reqd ->
    with_permission_auth ~permission:request (fun state req reqd -> handle state req reqd) request reqd)
|}
    , "/api/x"
    , "~permission of with_permission_auth reads the request of the outer function" )
  ; ( "a computed partial argument and computed handler may reorder"
    , {|let routes routes =
  routes
  |> Http.Router.post "/api/x"
       (with_permission_auth ~permission:(permission_of_env ()) (read Browser_addon_view.read))
|}
    , "/api/x"
    , "a computed partial wrapper argument may be reordered with other registration effects" )
  ; ( "a doc comment inside the wrapper"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (fun request reqd ->
       (** documents nothing *)
       with_read_auth (fun _state req reqd -> h req reqd) request reqd)
|}
    , "/api/x"
    , "the wrapper holds a doc comment, or text the tool cannot read" )
  ; ( "a wrapped handler that is a call would run at registration"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (fun request reqd ->
       with_read_auth (make_handler config) request reqd)
|}
    , "/api/x"
    , "the wrapped handler is a call, which would run at registration" )
  ; ( "an attribute on the handler"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" ((fun request reqd ->
       with_read_auth (fun _state req reqd -> h req reqd) request reqd) [@inline])
|}
    , "/api/x"
    , "the handler has an attribute" )
  ; ( "an attribute on the wrapper function"
    , {|let routes = Router.get "/api/x" (fun request reqd ->
  (with_public_read [@instrument.wrapper]) (fun state req reqd -> h state req reqd) request reqd)
|}
    , "/api/x"
    , "handler body is not a wrapper call" )
  ; ( "an attribute on the forwarded request"
    , {|let routes = Router.get "/api/x" (fun request reqd ->
  with_public_read (fun state req reqd -> h state req reqd) (request [@instrument.request]) reqd)
|}
    , "/api/x"
    , "the wrapper is not applied to the request and reqd of the handler" )
  ; ( "an attribute on the forwarded reqd"
    , {|let routes = Router.get "/api/x" (fun request reqd ->
  with_public_read (fun state req reqd -> h state req reqd) request (reqd [@instrument.reqd]))
|}
    , "/api/x"
    , "the wrapper is not applied to the request and reqd of the handler" )
  ; ( "an attribute on the registration function"
    , {|let routes = (Router.get [@instrument.router]) "/api/x" (fun request reqd ->
  with_public_read (fun state req reqd -> h state req reqd) request reqd)
|}
    , "/api/x"
    , "registration function has an attribute" )
  ; ( "a comment inside the registration function"
    , {|let routes = Router.(* retain-route-comment *)get "/api/x" (fun request reqd ->
  with_public_read (fun state req reqd -> h state req reqd) request reqd)
|}
    , "/api/x"
    , "registration function contains a comment" )
  ; ( "an attribute on an outer parameter"
    , {|let routes routes =
  routes |> Http.Router.get "/api/x" (fun (request [@some_attribute]) reqd ->
    with_public_read (fun _state req reqd -> handle req reqd) request reqd)
|}
    , "/api/x"
    , "the outer handler parameter has an attribute" )
  ; ( "an attribute on an inner parameter that would be renamed"
    , {|let routes routes =
  routes |> Http.Router.get "/api/x" (fun request reqd ->
    with_public_read (fun state (_ [@some_attribute]) reqd -> handle state request reqd) request reqd)
|}
    , "/api/x"
    , "the wrapped handler parameter has an attribute" )
  ; ( "an annotated parameter"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (fun (request : Httpun.Request.t) reqd ->
       with_read_auth (fun _state req reqd -> h req reqd) request reqd)
|}
    , "/api/x"
    , "handler does not take exactly request and reqd" )
  ; ( "a label the tool does not know"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (fun request reqd ->
       with_read_auth ~extra:1 (fun _state req reqd -> h req reqd) request reqd)
|}
    , "/api/x"
    , "with_read_auth is called with labels the tool does not know" )
  ; ( "an optional argument"
    , {|let routes routes =
  routes
  |> Http.Router.get "/api/x" (fun request reqd ->
       with_read_auth ?extra:None (fun _state req reqd -> h req reqd) request reqd)
|}
    , "/api/x"
    , "the wrapper call has optional arguments or attributes" )
  ; ( "a wrapper with more arguments than a handler"
    , {|let routes routes =
  routes |> Http.Router.get "/api/x" (with_read_auth first second)
|}
    , "/api/x"
    , "the wrapper is partially applied with other arguments" )
  ; ( "no handler"
    , {|let routes routes =
  routes |> Http.Router.get "/api/x"
|}
    , "/api/x"
    , "no handler argument" )
  ; ( "a path that is not a literal"
    , {|let routes routes =
  routes |> Http.Router.get path handle_x
|}
    , "<non-literal>"
    , "named handler handle_x" )
  ]
;;

let check_left_alone (name, source, path, reason) =
  Alcotest.test_case name `Quick (fun () ->
    let rewritten, report = rewrite source in
    Alcotest.(check string) "the text is untouched" source rewritten;
    Alcotest.(check int) "converted" 0 report.converted;
    Alcotest.(check (list (pair string string))) "left alone" [ path, reason ] (sites report))
;;

(* ---- arguments that are evaluated once after the rewrite ---- *)

let early_source =
  {|let routes routes =
  routes
  |> Http.Router.post "/api/x" (fun request reqd ->
       with_tool_auth ~tool_name:(Msx_tool.name Msx_tool.Press)
         (fun state _req reqd -> handle state reqd) request reqd)
|}
;;

let test_early_refused_by_default () =
  let rewritten, report = rewrite early_source in
  Alcotest.(check string) "the text is untouched" early_source rewritten;
  Alcotest.(check (list (pair string string)))
    "left alone"
    [ ( "/api/x"
      , "~tool_name of with_tool_auth is computed, so it would be evaluated at registration instead of on every request"
      )
    ]
    (sites report)
;;

let test_early_allowed () =
  let rewritten, report = rewrite ~early:true early_source in
  Alcotest.(check string)
    "text"
    {|let routes routes =
  routes
  |> Server_route.post (Server_route.Tool { tool_name = (Msx_tool.name Msx_tool.Press) }) "/api/x" (fun state _req reqd -> handle state reqd)
|}
    rewritten;
  Alcotest.(check int) "converted" 1 report.converted;
  Alcotest.(check (list (pair string string))) "left alone" [] (sites report);
  Alcotest.(check (list (pair string string)))
    "the expression that is now evaluated once"
    [ "/api/x", "(Msx_tool.name Msx_tool.Press)" ]
    (List.map
       (fun (site : Route_auth_rewrite.site) -> site.path, site.note)
       report.early);
  check_parses rewritten
;;

(* A computed argument that reads the request cannot be moved to registration
   however the flag is set. *)
let test_early_never_for_request_reads () =
  let source =
    {|let routes routes =
  routes
  |> Http.Router.post "/api/x" (fun request reqd ->
       with_tool_auth ~tool_name:(Msx_tool.name_for request)
         (fun state _req reqd -> handle state reqd) request reqd)
|}
  in
  let rewritten, report = rewrite ~early:true source in
  Alcotest.(check string) "the text is untouched" source rewritten;
  Alcotest.(check (list (pair string string)))
    "left alone"
    [ "/api/x", "~tool_name of with_tool_auth reads the request of the outer function" ]
    (sites report);
  Alcotest.(check int) "evaluated once" 0 (List.length report.early)
;;

(* A comment inside a copied argument is copied with it, not moved as well. *)
let test_comment_inside_copied_argument () =
  let source =
    {|let routes routes =
  routes
  |> Http.Router.post "/api/x" (fun request reqd ->
       with_tool_auth ~tool_name:(Msx_tool.name (* press *) Msx_tool.Press)
         (fun state _req reqd -> handle state reqd) request reqd)
|}
  in
  let rewritten, _ = rewrite ~early:true source in
  Alcotest.(check string)
    "the comment stays inside the argument, once"
    {|let routes routes =
  routes
  |> Server_route.post (Server_route.Tool { tool_name = (Msx_tool.name (* press *) Msx_tool.Press) }) "/api/x" (fun state _req reqd -> handle state reqd)
|}
    rewritten
;;

(* ---- named handlers ---- *)

let named_cases =
  [ ( "a definition that only registrations use"
    , {|let get_x request reqd =
  with_read_auth (fun state _request reqd -> handle state request reqd) request reqd

let routes routes =
  routes
  |> Http.Router.get "/api/x" get_x
|}
    , {|let get_x = (fun state request reqd -> handle state request reqd)

let routes routes =
  routes
  |> Server_route.get Server_route.Read_auth "/api/x" get_x
|}
    , 1
    , 1 )
  ; ( "one definition behind two registrations"
    , {|let get_x request reqd =
  with_read_auth (fun state req reqd -> handle state req reqd) request reqd

let routes routes =
  routes
  |> Http.Router.get "/api/x" get_x
  |> Http.Router.post "/api/x" get_x
|}
    , {|let get_x = (fun state req reqd -> handle state req reqd)

let routes routes =
  routes
  |> Server_route.get Server_route.Read_auth "/api/x" get_x
  |> Server_route.post Server_route.Read_auth "/api/x" get_x
|}
    , 2
    , 1 )
  ; ( "add takes the name as a label"
    , {|let get_x request reqd =
  with_read_auth (fun state req reqd -> handle state req reqd) request reqd

let routes routes =
  routes
  |> Http.Router.add ~path:"/api/x" ~methods:[`GET] ~handler:get_x
|}
    , {|let get_x = (fun state req reqd -> handle state req reqd)

let routes routes =
  routes
  |> Server_route.add Server_route.Read_auth ~path:"/api/x" ~methods:[`GET] get_x
|}
    , 1
    , 1 )
  ; ( "a definition that is the wrapper applied without the function"
    , {|let get_x = with_read_auth (fun state req reqd -> handle state req reqd)

let routes routes =
  routes
  |> Http.Router.get "/api/x" get_x
|}
    , {|let get_x = (fun state req reqd -> handle state req reqd)

let routes routes =
  routes
  |> Server_route.get Server_route.Read_auth "/api/x" get_x
|}
    , 1
    , 1 )
  ; ( "a comment in the definition moves above it"
    , {|let get_x request reqd =
  (* why this is read only *)
  with_read_auth (fun state _request reqd -> handle state request reqd) request reqd

let routes routes =
  routes
  |> Http.Router.get "/api/x" get_x
|}
    , {|(* why this is read only *)
let get_x = (fun state request reqd -> handle state request reqd)

let routes routes =
  routes
  |> Server_route.get Server_route.Read_auth "/api/x" get_x
|}
    , 1
    , 1 )
  ; ( "a permission carries over to the registration"
    , {|let drop request reqd =
  with_permission_auth ~permission:Masc_domain.CanAdmin
    (fun state req reqd -> handle state req reqd) request reqd

let routes routes =
  routes
  |> Http.Router.post "/api/drop" drop
|}
    , {|let drop = (fun state req reqd -> handle state req reqd)

let routes routes =
  routes
  |> Server_route.post (Server_route.Permission Masc_domain.CanAdmin) "/api/drop" drop
|}
    , 1
    , 1 )
  ; ( "an unchanged local permission retains its binding"
    , {|let permission = Masc_domain.CanAdmin
let drop request reqd =
  with_permission_auth ~permission (fun state req reqd -> handle state req reqd) request reqd
let routes routes = routes |> Http.Router.post "/api/drop" drop
|}
    , {|let permission = Masc_domain.CanAdmin
let drop = (fun state req reqd -> handle state req reqd)
let routes routes = routes |> Server_route.post (Server_route.Permission permission) "/api/drop" drop
|}
    , 1
    , 1 )
  ; ( "an open after the last registration is harmless"
    , {|let get_x request reqd =
  with_read_auth (fun state req reqd -> handle state req reqd) request reqd
let routes routes = routes |> Http.Router.get "/api/x" get_x
open Later
|}
    , {|let get_x = (fun state req reqd -> handle state req reqd)
let routes routes = routes |> Server_route.get Server_route.Read_auth "/api/x" get_x
open Later
|}
    , 1
    , 1 )
  ; ( "a nested registration can use an enclosing handler"
    , {|let get_x request reqd =
  with_read_auth (fun state req reqd -> handle state req reqd) request reqd
module Routes = struct
  let routes routes = routes |> Http.Router.get "/api/x" get_x
end
|}
    , {|let get_x = (fun state req reqd -> handle state req reqd)
module Routes = struct
  let routes routes = routes |> Server_route.get Server_route.Read_auth "/api/x" get_x
end
|}
    , 1
    , 1 )
  ]
;;

let check_named (name, source, expected, converted, definitions) =
  Alcotest.test_case name `Quick (fun () ->
    let rewritten, report = rewrite ~allow_named:true source in
    Alcotest.(check string) "text" expected rewritten;
    Alcotest.(check int) "registrations converted" converted report.converted;
    Alcotest.(check int) "definitions converted" definitions report.definitions;
    Alcotest.(check int) "every converted name is reported" definitions (List.length report.named);
    Alcotest.(check (list (pair string string))) "left alone" [] (sites report);
    check_parses rewritten;
    let again, second = rewrite rewritten in
    Alcotest.(check string) "a second run changes nothing" rewritten again;
    Alcotest.(check int) "a second run converts nothing" 0 (second.converted + second.definitions))
;;

(* A name that is used anywhere but as a registration's handler keeps its
   wrapper, and so do the registrations that use it. *)
let named_left_alone_cases =
  [ ( "the name is also called directly"
    , {|let get_x request reqd =
  with_read_auth (fun state _request reqd -> handle state request reqd) request reqd

let again request reqd = get_x request reqd

let routes routes =
  routes
  |> Http.Router.get "/api/x" get_x
|}
    , "/api/x"
    , "named handler get_x" )
  ; ( "the name is also a websocket handler"
    , {|let get_x request reqd =
  with_read_auth (fun state _request reqd -> handle state request reqd) request reqd

let routes routes =
  routes
  |> Http.Router.get "/api/x" get_x
  |> Http.Router.ws_get "/ws" get_x
|}
    , "/api/x"
    , "named handler get_x" )
  ; ( "a recursive definition"
    , {|let rec get_x request reqd =
  with_read_auth (fun state _request reqd -> handle state request reqd) request reqd

let routes routes =
  routes
  |> Http.Router.get "/api/x" get_x
|}
    , "/api/x"
    , "named handler get_x" )
  ; ( "a definition with a computed argument and no early evaluation"
    , {|let press request reqd =
  with_tool_auth ~tool_name:(Msx_tool.name Msx_tool.Press)
    (fun state _request reqd -> handle state request reqd) request reqd

let routes routes =
  routes
  |> Http.Router.post "/api/x" press
|}
    , "/api/x"
    , "named handler press" )
  ; ( "a definition whose body is not a wrapper call"
    , {|let get_x request reqd = Http.Response.text ~request "ok" reqd

let routes routes =
  routes
  |> Http.Router.get "/api/x" get_x
|}
    , "/api/x"
    , "named handler get_x" )
  ; ( "an attributed parameter on a named handler"
    , {|let get_x (request [@some_attribute]) reqd =
  with_public_read (fun state req reqd -> handle state req reqd) request reqd
let routes routes = routes |> Http.Router.get "/api/x" get_x
|}
    , "/api/x"
    , "named handler get_x" )
  ; ( "a named handler uses an outer parameter as permission"
    , {|let get_x request reqd =
  with_permission_auth ~permission:request (fun state req reqd -> handle state req reqd) request reqd
let routes routes = routes |> Http.Router.get "/api/x" get_x
|}
    , "/api/x"
    , "named handler get_x" )
  ; ( "a permission is rebound before registration"
    , {|let permission = Masc_domain.CanAdmin
let get_x request reqd =
  with_permission_auth ~permission (fun state req reqd -> handle state req reqd) request reqd
let permission = Masc_domain.CanAddTask
let routes routes = routes |> Http.Router.get "/api/x" get_x
|}
    , "/api/x"
    , "named handler or wrapper argument may resolve differently at registration" )
  ; ( "a registration parameter shadows the permission"
    , {|let permission = Masc_domain.CanAdmin
let get_x request reqd =
  with_permission_auth ~permission (fun state req reqd -> handle state req reqd) request reqd
let routes permission routes = routes |> Http.Router.get "/api/x" get_x
|}
    , "/api/x"
    , "named handler or wrapper argument may resolve differently at registration" )
  ; ( "a module shadows the qualified permission"
    , {|let get_x request reqd =
  with_permission_auth ~permission:Masc_domain.CanAdmin
    (fun state req reqd -> handle state req reqd) request reqd
module Masc_domain = Other_domain
let routes routes = routes |> Http.Router.get "/api/x" get_x
|}
    , "/api/x"
    , "named handler or wrapper argument may resolve differently at registration" )
  ; ( "an opened scope can change a named handler"
    , {|let get_x request reqd =
  with_public_read (fun state req reqd -> handle state req reqd) request reqd
open Other_handlers
let routes routes = routes |> Http.Router.get "/api/x" get_x
|}
    , "/api/x"
    , "named handler or wrapper argument may resolve differently at registration" )
  ; ( "a local open can shadow a permission"
    , {|let permission = Masc_domain.CanAdmin
let get_x request reqd =
  with_permission_auth ~permission (fun state req reqd -> handle state req reqd) request reqd
let routes routes = let open Other in routes |> Http.Router.get "/api/x" get_x
|}
    , "/api/x"
    , "named handler or wrapper argument may resolve differently at registration" )
  ; ( "a local open can shadow the handler"
    , {|let get_x request reqd =
  with_public_read (fun state req reqd -> handle state req reqd) request reqd
let routes routes = let open Other in routes |> Http.Router.get "/api/x" get_x
|}
    , "/api/x"
    , "named handler or wrapper argument may resolve differently at registration" )
  ; ( "a first-class module parameter shadows the permission module"
    , {|let get_x request reqd =
  with_permission_auth ~permission:Masc_domain.CanAdmin
    (fun state req reqd -> handle state req reqd) request reqd
let routes (module Masc_domain : S) routes = routes |> Http.Router.get "/api/x" get_x
|}
    , "/api/x"
    , "named handler or wrapper argument may resolve differently at registration" )
  ; ( "the registration is outside the definition module"
    , {|open Other_handlers
module M = struct
  let get_x request reqd =
    with_public_read (fun state req reqd -> handle state req reqd) request reqd
end
let routes routes = routes |> Http.Router.get "/api/x" get_x
|}
    , "/api/x"
    , "named handler registration is outside its definition scope" )
  ; ( "a registration before the local definition"
    , {|let routes routes = routes |> Http.Router.get "/api/x" get_x
let get_x request reqd =
  with_public_read (fun state req reqd -> handle state req reqd) request reqd
|}
    , "/api/x"
    , "named handler is registered before its definition" )
  ]
;;

let test_named_registration_function_attribute () =
  let source = {|let handle request reqd =
  with_public_read (fun state req reqd -> h state req reqd) request reqd
let routes = Router.get "/a" handle
let more = (Router.get [@instrument.router]) "/b" handle
|} in
  let rewritten, report = rewrite ~allow_named:true source in
  Alcotest.(check string) "preserve definition and all registrations" source rewritten;
  Alcotest.(check int) "definitions" 0 report.definitions;
  Alcotest.(check int) "registrations" 0 report.converted;
  Alcotest.(check (list (pair string string))) "both left alone"
    [ "/a", "registration function has an attribute"
    ; "/b", "registration function has an attribute" ] (sites report)
;;

let test_named_registration_function_comment () =
  let source = {|let handle request reqd =
  with_public_read (fun state req reqd -> h state req reqd) request reqd
let routes = Router.get "/a" handle
let more = Router.(* retain-route-comment *)get "/b" handle
|} in
  let rewritten, report = rewrite ~allow_named:true source in
  Alcotest.(check string) "preserve definition and all registrations" source rewritten;
  Alcotest.(check int) "definitions" 0 report.definitions;
  Alcotest.(check int) "registrations" 0 report.converted;
  Alcotest.(check (list (pair string string))) "both left alone"
    [ "/a", "registration function contains a comment"
    ; "/b", "registration function contains a comment" ] (sites report)
;;

let test_shadowed_named_definitions () =
  let source =
    {|let h request reqd =
  with_permission_auth ~permission:Masc_domain.CanAdmin
    (fun state req reqd -> handle state req reqd) request reqd
let admin routes = routes |> Http.Router.get "/admin" h
let h request reqd =
  with_public_read (fun state req reqd -> handle state req reqd) request reqd
let public routes = routes |> Http.Router.get "/public" h
|}
  in
  let rewritten, report = rewrite source in
  Alcotest.(check string) "both definitions and registrations remain unchanged" source rewritten;
  Alcotest.(check int) "no ambiguous registration was converted" 0 report.converted;
  Alcotest.(check int) "no ambiguous definition lost its wrapper" 0 report.definitions;
  Alcotest.(check (list (pair string string))) "both ambiguous routes are reported"
    [ "/admin", "named handler has multiple bindings"
    ; "/public", "named handler has multiple bindings" ]
    (sites report)
;;

let test_shadowed_named_module_definitions () =
  let source =
    {|module Admin = struct
  let h request reqd = with_permission_auth ~permission:Masc_domain.CanAdmin
    (fun state req reqd -> handle state req reqd) request reqd
  let routes routes = routes |> Http.Router.get "/admin" h
end
module Public = struct
  let h request reqd = with_public_read (fun state req reqd -> handle state req reqd) request reqd
  let routes routes = routes |> Http.Router.get "/public" h
end
|}
  in
  let rewritten, report = rewrite source in
  Alcotest.(check string) "same spelling in separate modules remains unchanged" source rewritten;
  Alcotest.(check int) "no ambiguous definition was rewritten" 0 report.definitions;
  Alcotest.(check (list (pair string string))) "both module routes are reported"
    [ "/admin", "named handler has multiple bindings"
    ; "/public", "named handler has multiple bindings" ]
    (sites report)
;;

let test_named_early_shadowed_module () =
  let source =
    {|let press request reqd =
  with_tool_auth ~tool_name:(Msx_tool.name Msx_tool.Press)
    (fun state req reqd -> handle state req reqd) request reqd
module Msx_tool = Other_tool
let routes routes = routes |> Http.Router.post "/api/press" press
|}
  in
  let rewritten, report = Route_auth_rewrite.rewrite ~early:true ~file:"test.ml" source |> Result.get_ok in
  Alcotest.(check string) "early evaluation does not permit a different binding" source rewritten;
  Alcotest.(check int) "the handler wrapper is retained" 0 report.definitions;
  Alcotest.(check (list (pair string string))) "the unsafe registration is reported"
    [ "/api/press", "named handler or wrapper argument may resolve differently at registration" ]
    (sites report)
;;

let test_named_early () =
  let source =
    {|let press request reqd =
  with_tool_auth ~tool_name:(Msx_tool.name Msx_tool.Press)
    (fun state _request reqd -> handle state request reqd) request reqd

let routes routes =
  routes
  |> Http.Router.post "/api/x" press
|}
  in
  let rewritten, report = rewrite ~early:true ~allow_named:true source in
  Alcotest.(check string)
    "text"
    {|let press = (fun state request reqd -> handle state request reqd)

let routes routes =
  routes
  |> Server_route.post (Server_route.Tool { tool_name = (Msx_tool.name Msx_tool.Press) }) "/api/x" press
|}
    rewritten;
  Alcotest.(check int) "registrations" 1 report.converted;
  Alcotest.(check int) "definitions" 1 report.definitions;
  Alcotest.(check (list (pair string string)))
    "the expression is listed under the name of the handler"
    [ "press", "(Msx_tool.name Msx_tool.Press)" ]
    (List.map (fun (site : Route_auth_rewrite.site) -> site.path, site.note) report.early);
  check_parses rewritten
;;

let test_external_named_use_is_left_alone () =
  let file_a =
    {|let h request reqd = with_read_auth (fun state req reqd -> handle state req reqd) request reqd
let routes routes = routes |> Http.Router.get "/x" h
|} in
  let file_b = {|let outside request reqd = A.h request reqd
|} in
  let rewritten_a, report_a = Route_auth_rewrite.rewrite ~file:"a.ml" file_a |> Result.get_ok in
  let rewritten_b, report_b = Route_auth_rewrite.rewrite ~file:"b.ml" file_b |> Result.get_ok in
  Alcotest.(check string) "exported wrapper remains" file_a rewritten_a;
  Alcotest.(check string) "external call remains" file_b rewritten_b;
  Alcotest.(check int) "no named definition converted" 0 report_a.definitions;
  Alcotest.(check int) "no change to external file" 0 report_b.converted;
  Alcotest.(check (list (pair string string))) "the route requires external review"
    [ "/x", "named handler may be used outside this file; external-use review is required" ]
    (sites report_a)
;;

let test_local_opens_cannot_change_named_permission () =
  List.iter (fun route ->
    let source =
      "module Other = struct let permission = Masc_domain.CanRead end\n"
      ^ "let permission = Masc_domain.CanAdmin\n"
      ^ "let h request reqd = with_permission_auth ~permission "
      ^ "(fun state req reqd -> handle state req reqd) request reqd\n"
      ^ "let routes routes = " ^ route ^ "\n" in
    let rewritten, report = rewrite ~allow_named:true source in
    Alcotest.(check string) "local open retains definition and route" source rewritten;
    Alcotest.(check int) "no definition converted" 0 report.definitions;
    Alcotest.(check int) "no route converted" 0 report.converted;
    Alcotest.(check (list (pair string string))) "local open is reported"
      [ "/admin", "named handler or wrapper argument may resolve differently at registration" ]
      (sites report))
    [ "let open Other in routes |> Http.Router.get \"/admin\" h"
    ; "let open! Other in routes |> Http.Router.get \"/admin\" h"
    ; "Other.(routes |> Http.Router.get \"/admin\" h)" ]
;;

let test_unrelated_local_open_keeps_named_conversion () =
  let source =
    {|let permission = Masc_domain.CanAdmin
let h request reqd = with_permission_auth ~permission
  (fun state req reqd -> handle state req reqd) request reqd
let other = Other.(42)
let routes routes = routes |> Http.Router.get "/admin" h
|} in
  let expected =
    {|let permission = Masc_domain.CanAdmin
let h = (fun state req reqd -> handle state req reqd)
let other = Other.(42)
let routes routes = routes |> Server_route.get (Server_route.Permission permission) "/admin" h
|} in
  let rewritten, report = rewrite ~allow_named:true source in
  Alcotest.(check string) "unrelated local open preserves conversion" expected rewritten;
  Alcotest.(check int) "definition converted" 1 report.definitions;
  Alcotest.(check int) "route converted" 1 report.converted;
  Alcotest.(check int) "no route left alone" 0 (List.length report.unhandled);
  check_parses rewritten
;;

let test_qualified_named_use_in_same_file_is_left_alone () =
  List.iter (fun use ->
    let source =
      "module M = struct\n"
      ^ "  let h request reqd = with_permission_auth ~permission:Masc_domain.CanAdmin "
      ^ "(fun state req reqd -> handle state req reqd) request reqd\n"
      ^ "  let routes routes = routes |> Http.Router.get \"/admin\" h\n"
      ^ "end\n"
      ^ "let direct request reqd = " ^ use ^ " request reqd\n" in
    let rewritten, report = rewrite ~allow_named:true source in
    Alcotest.(check string) "qualified use keeps the definition and route" source rewritten;
    Alcotest.(check int) "no definition is converted" 0 report.definitions;
    Alcotest.(check int) "no route is converted" 0 report.converted;
    Alcotest.(check (list (pair string string))) "the route is reported"
      [ "/admin", "named handler h" ] (sites report))
    [ "M.h"; "Other.N.h" ]
;;

let test_computed_named_partial_is_never_moved () =
  List.iter (fun registrations ->
    let source =
      "let permission_calls = ref 0\n"
      ^ "let permission () = incr permission_calls; Masc_domain.CanAdmin\n"
      ^ "let h = with_permission_auth ~permission:(permission ()) handler\n"
      ^ "let routes routes = routes\n"
      ^ registrations in
    List.iter (fun (early,allow_named) ->
      let rewritten, report = rewrite ~early ~allow_named source in
      Alcotest.(check string) "definition and registrations remain" source rewritten;
      Alcotest.(check int) "no registration converted" 0 report.converted;
      Alcotest.(check int) "no definition converted" 0 report.definitions;
      Alcotest.(check int) "no expression evaluated early" 0 (List.length report.early);
      Alcotest.(check bool) "every registration reports moved evaluation" true
        (List.for_all (fun (site : Route_auth_rewrite.site) ->
          String.equal site.note "named partial wrapper argument would move from the definition to each registration") report.unhandled);
      Alcotest.(check int) "every registration reported"
        (if String.contains registrations '2' then 2 else 1) (List.length report.unhandled))
      [false,false; false,true; true,false; true,true])
    [ " |> Http.Router.get \"/1\" h\n"
    ; " |> Http.Router.get \"/1\" h\n |> Http.Router.post \"/2\" h\n" ]
;;

let test_partial_evaluation_order () =
  let sources =
    [ {|let r = Router.get (path ()) (with_permission_auth ~permission:(permission ()) handler)
|}
    ; {|let r = Router.get "/x" (with_permission_auth ~permission:(permission ()) (make_handler ()))
|}
    ; {|let r = Router.add ~path:"/x" ~methods:(methods ()) ~handler:(with_permission_auth ~permission:(permission ()) handler)
|}
    ; {|let r = Router.get "/x" (with_permission_auth ~permission:(permission ()) handler) (routes ())
|}
    ; {|let r = Router.get "/x" (with_permission_auth ~permission:(permission ()) (fun (state [@expand]) req reqd -> handle state req reqd))
|}
    ; {|let r = Router.get "/x" (with_permission_auth ~permission:(permission ()) (fun state req reqd -> [%expand]))
|} ] in
  List.iter (fun source ->
    List.iter (fun early ->
      let output, report = rewrite ~early source in
      Alcotest.(check string) "effectful argument preserves original source" source output;
      Alcotest.(check int) "no conversion" 0 report.converted;
      Alcotest.(check int) "reported" 1 (List.length report.unhandled);
      Alcotest.(check bool) "reports ordering" true
        (List.for_all (fun (site : Route_auth_rewrite.site) ->
          String.equal site.note "a computed partial wrapper argument may be reordered with other registration effects")
          report.unhandled)) [false; true]) sources;
  let safe = {|let r = Router.add ~path:"/x" ~methods:[`GET] ~handler:(with_permission_auth ~permission:(permission ()) (fun state req reqd -> handle state req reqd))
|} in
  let output, report = rewrite safe in
  Alcotest.(check int) "value-only registration keeps computed partial support" 1 report.converted;
  Alcotest.(check int) "no manual decisions" 0 (List.length report.unhandled);
  check_parses output
;;

(* ---- a whole file ---- *)

let mixed_source =
  {|let routes routes =
  routes
  (* the public ones *)
  |> Http.Router.get "/a" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         (* kept *)
         handle_a req reqd) request reqd)
  |> Http.Router.get "/skipped" handle_skipped
  |> Http.Router.ws_get "/ws" handle_ws
  |> Http.Router.get "/b" (fun request reqd ->
       with_read_auth (fun _state req reqd -> handle_b req reqd) request reqd)
|}
;;

let mixed_expected =
  {|let routes routes =
  routes
  (* the public ones *)
  |> Server_route.get Server_route.Public_read "/a" (fun _state req reqd ->
         (* kept *)
         handle_a req reqd)
  |> Http.Router.get "/skipped" handle_skipped
  |> Http.Router.ws_get "/ws" handle_ws
  |> Server_route.get Server_route.Read_auth "/b" (fun _state req reqd -> handle_b req reqd)
|}
;;

let test_mixed_file () =
  let rewritten, report = rewrite mixed_source in
  Alcotest.(check string) "converted ones change, every other byte stays" mixed_expected rewritten;
  Alcotest.(check int) "converted" 2 report.converted;
  Alcotest.(check (list (triple int string string)))
    "the skipped one is listed with its line"
    [ 8, "/skipped", "named handler handle_skipped" ]
    (List.map
       (fun (site : Route_auth_rewrite.site) -> site.line, site.path, site.note)
       report.unhandled);
  check_parses rewritten
;;

let test_no_registration () =
  let source = "let answer = 42\nlet () = print_int answer\n" in
  let rewritten, report = rewrite source in
  Alcotest.(check string) "text" source rewritten;
  Alcotest.(check int) "converted" 0 report.converted;
  Alcotest.(check int) "left alone" 0 (List.length report.unhandled)
;;

let test_parse_error () =
  match Route_auth_rewrite.rewrite ~file:"bad.ml" "let =" with
  | Ok _ -> Alcotest.fail "a file that does not parse was rewritten"
  | Error message ->
    Alcotest.(check bool)
      "the error names the file"
      true
      (String.length message >= 6 && String.equal (String.sub message 0 6) "bad.ml")
;;

(* A registration inside the handler of another one cannot be converted in two
   steps on the same text; the tool refuses the file instead of converting one. *)
let test_nested_registration () =
  let source =
    {|let routes routes =
  routes
  |> Http.Router.get "/outer" (fun request reqd ->
       with_public_read (fun _state req rd ->
         let _ =
           Http.Router.get "/inner" (fun r d ->
             with_public_read (fun _s rq rd2 -> ()) r d)
         in
         ()) request reqd)
|}
  in
  match Route_auth_rewrite.rewrite ~file:"nested.ml" source with
  | Ok _ -> Alcotest.fail "overlapping edits were applied"
  | Error message ->
    Alcotest.(check string) "the error names the file and the cause" "nested.ml: two edits overlap" message
;;

let () =
  Alcotest.run
    "route_auth_rewrite"
    [ "converted", List.map check_converted converted_cases
    ; "left alone", List.map check_left_alone left_alone_cases
    ; "named handlers", List.map check_named named_cases
    ; ( "named handlers left alone"
      , List.map check_left_alone named_left_alone_cases
        @ [ Alcotest.test_case "attributed registration keeps its named definition" `Quick test_named_registration_function_attribute
          ; Alcotest.test_case "commented registration keeps its named definition" `Quick test_named_registration_function_comment
          ; Alcotest.test_case "a computed argument converts the definition when allowed" `Quick test_named_early
          ; Alcotest.test_case "shadowed named definitions stay unchanged" `Quick test_shadowed_named_definitions
          ; Alcotest.test_case "same named definitions in modules stay unchanged" `Quick test_shadowed_named_module_definitions
          ; Alcotest.test_case "early argument cannot change modules" `Quick test_named_early_shadowed_module ] )
    ; ( "external and partial evaluation safety"
      , [ Alcotest.test_case "external reference is not changed by default" `Quick test_external_named_use_is_left_alone
        ; Alcotest.test_case "local opens cannot change named permission" `Quick test_local_opens_cannot_change_named_permission
        ; Alcotest.test_case "unrelated local open preserves named conversion" `Quick test_unrelated_local_open_keeps_named_conversion
        ; Alcotest.test_case "qualified same-file use keeps a named wrapper" `Quick test_qualified_named_use_in_same_file_is_left_alone
        ; Alcotest.test_case "computed partial is never moved" `Quick test_computed_named_partial_is_never_moved
        ; Alcotest.test_case "partial registration effect order" `Quick test_partial_evaluation_order ] )
    ; ( "evaluation at registration"
      , [ Alcotest.test_case "refused unless allowed" `Quick test_early_refused_by_default
        ; Alcotest.test_case "converted and listed when allowed" `Quick test_early_allowed
        ; Alcotest.test_case "never when the argument reads the request" `Quick test_early_never_for_request_reads
        ; Alcotest.test_case "a comment inside the copied argument" `Quick test_comment_inside_copied_argument
        ] )
    ; ( "file"
      , [ Alcotest.test_case "converted and skipped registrations in one file" `Quick test_mixed_file
        ; Alcotest.test_case "a file without registrations" `Quick test_no_registration
        ; Alcotest.test_case "a file that does not parse" `Quick test_parse_error
        ; Alcotest.test_case "a registration inside a handler" `Quick test_nested_registration
        ] )
    ]
;;
