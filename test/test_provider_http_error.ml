(** Drift-guard for [Provider_http_error.to_message] — pins the rendering
    for the simple variants and the 200-byte HTTP body truncation that the
    four former copies shared. Uses only the field-only variants
    ([AcceptRejected], [HttpError]) so the test carries no dependency on
    the nested [network_error_kind] / [timeout_phase] / [provider_*_kind]
    types. *)

let msg = Alcotest.(check string)

let test_simple_variants () =
  msg "AcceptRejected -> reason verbatim" "no transport injected"
    (Provider_http_error.to_message
       (Llm_provider.Http_client.AcceptRejected
          { reason = "no transport injected" }));
  msg "HttpError short body -> HTTP code: body" "HTTP 503: upstream down"
    (Provider_http_error.to_message
       (Llm_provider.Http_client.HttpError
          { code = 503; body = "upstream down" }))

let test_http_body_truncation () =
  let body = String.make 250 'x' in
  let expected = "HTTP 500: " ^ String.make 200 'x' ^ "..." in
  msg "HTTP body > 200 bytes truncated with ellipsis" expected
    (Provider_http_error.to_message
       (Llm_provider.Http_client.HttpError { code = 500; body }))

let () =
  Alcotest.run "provider_http_error"
    [ ( "to_message"
      , [ Alcotest.test_case "simple variants" `Quick test_simple_variants
        ; Alcotest.test_case "200-byte body truncation" `Quick
            test_http_body_truncation
        ] )
    ]
