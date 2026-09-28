(** Stack 5 tests for RFC-0471: the /collab HTTP trigger layer's pure core —
    request decode and base-URL validation. The live-server paths (start,
    resume, stop) run through [Server_collab_host], covered in
    test_collab_host. *)

open Alcotest

module Routes = Server_routes_http_routes_collab

let test_decode_host_request () =
  let decode = Routes.decode_host_request in
  (match decode {|{"keeper":" imp ","base_url":"https://m:9/"}|} with
   | Error detail -> fail detail
   | Ok req ->
     check string "keeper trimmed" "imp" req.Routes.keeper;
     check (option string) "base kept" (Some "https://m:9/") req.Routes.base_url);
  (match decode {|{"keeper":"imp"}|} with
   | Error detail -> fail detail
   | Ok req -> check (option string) "base absent" None req.Routes.base_url);
  (match decode {|{"keeper":"imp","base_url":null}|} with
   | Error detail -> fail detail
   | Ok req -> check (option string) "base null" None req.Routes.base_url);
  (match decode {|{"keeper":"imp","base_url":"   "}|} with
   | Error detail -> fail detail
   | Ok req -> check (option string) "base blank" None req.Routes.base_url);
  (match decode {|{"keeper":"imp","resume_only":true}|} with
   | Error detail -> fail detail
   | Ok req -> check bool "resume only" true req.Routes.resume_only);
  (match decode {|{"keeper":"imp"}|} with
   | Error detail -> fail detail
   | Ok req -> check bool "resume default" false req.Routes.resume_only);
  check bool "non-bool resume refused" true
    (Result.is_error (decode {|{"keeper":"imp","resume_only":"yes"}|}));
  check bool "keeper missing refused" true
    (Result.is_error (decode {|{"base_url":"https://m:9"}|}));
  check bool "blank keeper refused" true
    (Result.is_error (decode {|{"keeper":"  "}|}));
  check bool "non-object refused" true (Result.is_error (decode {|[]|}));
  check bool "bad json refused" true (Result.is_error (decode {|{|}))
;;

let test_validate_base_url () =
  let ok raw expected =
    check (result string string) ("accept " ^ raw) (Ok expected)
      (Routes.validate_base_url raw)
  in
  let refused raw =
    check bool ("refuse " ^ raw) true
      (Result.is_error (Routes.validate_base_url raw))
  in
  ok "https://relay.test:8443" "https://relay.test:8443";
  ok "http://10.9.8.7:1777" "http://10.9.8.7:1777";
  ok "https://relay.test/" "https://relay.test";
  ok "  https://relay.test  " "https://relay.test";
  ok "HTTP://relay.test" "http://relay.test";
  ok "http://[::1]:1777" "http://[::1]:1777";
  refused "ftp://relay.test";
  refused "relay.test";
  refused "https://relay.test/r/abc";
  refused "https://relay.test?x=1";
  refused "https://relay.test#frag";
  refused "https://user@relay.test";
  refused "https://relay.test:99999";
  refused "https://relay.test:";
  refused "https://relay.test:abc";
  refused "https://[::1]:abc";
  refused "https://rel ay.test";
  refused "";
  refused "http://"
;;

let () =
  run
    "collab-http"
    [ ( "routes",
        [ test_case "host request decodes" `Quick test_decode_host_request
        ; test_case "base url validates" `Quick test_validate_base_url
        ] )
    ]
;;
