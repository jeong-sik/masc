(* The one element a single-destination case expects. A mismatch fails with
   every element it got, not only how many, so the failure log shows what the
   run actually reported. *)
let only_one ~what ~to_json = function
  | [ item ] -> item
  | items ->
    Alcotest.failf "one destination, got %d %s: %s" (List.length items) what
      (Yojson.Safe.to_string (`List (List.map to_json items)))
;;

let with_gate_http_fixture f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
  @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" (Some "synthetic-jev-key") @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    { Runtime_schema.default_typesafeai with absorb_gate = true } @@ fun () ->
  f ~sw ~net ~clock
;;

let test_transport_diagnostics_preserve_cause_without_configured_credentials () =
  let module Client = Masc.Typesafeai_client in
  let endpoint =
    "http://fixture-user:fixture-password@example.test/evaluate?access=fixture-query#fixture-fragment"
  in
  let normalized = Uri.of_string endpoint |> Uri.to_string in
  let displayed = "http://example.test/evaluate" in
  let api_key = "plain-api-key-without-a-known-secret-prefix" in
  List.iter (fun cause ->
    let detail = Printf.sprintf "%s url=%s normalized=%s key=%s"
        cause endpoint normalized api_key in
    let failure = Client.For_testing.transport_failure ~endpoint ~api_key detail in
    let rendered = Client.refusal_to_string failure in
    Alcotest.(check string) "diagnostic cause and safe destination remain"
      (Printf.sprintf "typesafeai: transport failure: %s url=%s normalized=%s key=[REDACTED]"
         cause displayed displayed) rendered;
    let json = Client.refusal_to_yojson failure in
    let open Yojson.Safe.Util in
    Alcotest.(check string) "transport failure has its own type" "transport"
      (member "kind" json |> to_string);
    Alcotest.(check bool) "a transport failure has no HTTP response"
      true (member "body" json = `Null && member "status" json = `Null);
    ignore (Yojson.Safe.to_string ~std:true json : string))
    [ "DNS lookup failed"; "connect ECONNREFUSED"; "request timeout" ]
;;

let test_failure_bodies_omit_configured_credentials () =
  with_gate_http_fixture @@ fun ~sw ~net ~clock ->
  let module Client = Masc.Typesafeai_client in
  let open Yojson.Safe.Util in
  let socket = Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | _ -> Alcotest.fail "fixture has no TCP address" in
  let displayed = Printf.sprintf "http://127.0.0.1:%d/evaluate" port in
  let endpoint = Printf.sprintf
    "http://fixture-user:fixture-password@127.0.0.1:%d/evaluate?access=fixture-query#fixture-fragment" port in
  let api_key = "plain-api-key-without-a-known-secret-prefix" in
  let reply = ref (`Service_unavailable, "") in
  let handler _ request body =
    ignore (Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) : string);
    Alcotest.(check (option string)) "the actual request retains its configured authorization"
      (Some ("Bearer " ^ api_key)) (Cohttp.Header.get (Cohttp.Request.headers request) "authorization");
    Alcotest.(check (option string)) "the actual request retains its configured query"
      (Some "fixture-query") (Uri.get_query_param (Cohttp.Request.uri request) "access");
    let status, body = !reply in
    Cohttp_eio.Server.respond_string ~status ~body () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket (Cohttp_eio.Server.make ~callback:handler ())
      ~on_error:(fun exn -> Alcotest.fail (Printexc.to_string exn)));
  List.iter (fun (status, suffix) ->
    reply := status, "gateway echo " ^ api_key ^ " url=" ^ endpoint ^ suffix;
    let destination = { Client.endpoint; model = "gateway-echo-model"; api_key } in
    let failure =
      match Client.evaluate ~clock ~destinations:(destination, []) ~state:`Null ~questions:[] () with
      | Error failure ->
        (only_one ~what:"attempts" ~to_json:Client.attempt_to_yojson
           (Client.attempts failure)).refusal
      | Ok _ -> Alcotest.fail "the gateway response must remain a typed failure" in
    let expected = "gateway echo [REDACTED] url=" ^ displayed ^ suffix in
    (match failure with
     | Client.Http_response_failure { body; destination_uri; _ } ->
       Alcotest.(check string) "the typed observation already omits known credentials" expected body;
       Alcotest.(check string) "the typed destination is safe" displayed destination_uri
     | Client.Transport_failure detail -> Alcotest.fail detail);
    let json = Client.refusal_to_yojson failure in
    let body = member "body" json in
    let decoded = match body with
      | `String body -> body
      | _ -> Base64.decode_exn (member "content" body |> to_string) in
    Alcotest.(check string) "encoded evidence retains other bytes, including invalid UTF-8"
      expected decoded;
    let encoded = Yojson.Safe.to_string ~std:true json in
    Alcotest.(check bool) "the saved failure is valid UTF-8" true (String_util.is_valid_utf8 encoded))
    [ `Service_unavailable, " service unavailable"
    ; `OK, " invalid JSON"
    ; `OK, String.make 1 (Char.chr 255) ]
;;

let () =
  Alcotest.run
    "typesafeai_client_redaction"
    [ ( "judgment"
      , [ Alcotest.test_case "transport diagnostics retain cause without credentials" `Quick
            test_transport_diagnostics_preserve_cause_without_configured_credentials
        ; Alcotest.test_case "failure bodies omit configured credentials" `Quick
            test_failure_bodies_omit_configured_credentials
        ] )
    ]
;;
