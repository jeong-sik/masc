let rewrite ?early source =
  match Route_auth_rewrite.rewrite ?early ~file:"test.ml" source with
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
  [ ( "public read, and the Router qualification is kept apart from the kind"
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
  ; ( "a wrapper applied directly keeps a computed argument and a computed handler"
    , {|let routes routes =
  routes
  |> Http.Router.post "/api/x"
       (with_permission_auth ~permission:(permission_of_env ()) (read Browser_addon_view.read))
|}
    , {|let routes routes =
  routes
  |> Server_route.post (Server_route.Permission (permission_of_env ())) "/api/x"
       (read Browser_addon_view.read)
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
