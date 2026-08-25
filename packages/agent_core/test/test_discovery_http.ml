open Alcotest
open Llm_provider

let with_mock_server ~port handler f =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let socket =
      Eio.Net.listen
        env#net
        ~sw
        ~backlog:128
        ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    let server = Cohttp_eio.Server.make ~callback:handler () in
    Eio.Fiber.fork ~sw (fun () ->
      Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
    let endpoint = Printf.sprintf "http://127.0.0.1:%d" port in
    f ~sw ~net:env#net ~endpoint;
    Eio.Switch.fail sw Exit
  with
  | Unix.Unix_error (Unix.EPERM, "bind", _) -> Alcotest.skip ()
  | Exit -> ()
;;

let test_get_json_success_and_parse_error () =
  let handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/json" -> Cohttp_eio.Server.respond_string ~status:`OK ~body:{|{"ok":true}|} ()
    | "/bad-json" -> Cohttp_eio.Server.respond_string ~status:`OK ~body:"not-json" ()
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  with_mock_server ~port:18345 handler (fun ~sw ~net ~endpoint ->
    (match Discovery_http.get_json ~sw ~net (endpoint ^ "/json") with
     | Ok json ->
       let open Yojson.Safe.Util in
       check bool "ok" true (json |> member "ok" |> to_bool)
     | Error err -> fail err);
    match Discovery_http.get_json ~sw ~net (endpoint ^ "/bad-json") with
    | Error err -> check bool "parse error" true (String.length err > 0)
    | Ok _ -> fail "expected parse error")
;;

let test_get_json_http_error_and_liveness () =
  let handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/healthy" -> Cohttp_eio.Server.respond_string ~status:`No_content ~body:"" ()
    | _ -> Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body:"boom" ()
  in
  with_mock_server ~port:18346 handler (fun ~sw ~net ~endpoint ->
    (match Discovery_http.get_json ~sw ~net (endpoint ^ "/broken") with
     | Error "HTTP 500" -> ()
     | Error err -> fail ("unexpected error: " ^ err)
     | Ok _ -> fail "expected HTTP 500");
    (match Discovery_http.probe_liveness ~sw ~net (endpoint ^ "/healthy") with
     | Ok () -> ()
     | Error detail -> fail ("healthy probe failed: " ^ detail));
    match Discovery_http.probe_liveness ~sw ~net (endpoint ^ "/broken") with
    | Error "HTTP 500" -> ()
    | Error detail -> fail ("unexpected liveness error: " ^ detail)
    | Ok () -> fail "broken endpoint passed liveness probe")
;;

let () =
  run
    "discovery-http"
    [ ( "http helpers"
      , [ test_case
            "json success and parse error"
            `Quick
            test_get_json_success_and_parse_error
        ; test_case
            "http error and liveness probe"
            `Quick
            test_get_json_http_error_and_liveness
        ] )
    ]
;;
