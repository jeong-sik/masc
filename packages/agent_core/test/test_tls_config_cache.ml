(** Regression guard for the process-wide TLS client-config cache.

    [Api_common.tls_client_config] must load the system trust store once
    and hand back the physically same [Tls.Config.client] on every
    subsequent call. Rebuilding it per connection re-runs the ca-certs
    trust-store load (macOS: one `security find-certificate` subprocess
    per keychain + a full PEM parse and X509 decode of the anchor set)
    on every LLM connection and every OTel flush — measured at ~73% of
    a consuming server's main event-loop thread across two 10s `sample`
    profiles (2026-07-17) under sustained LLM traffic.

    Hosts without a readable trust store make the loader error; errors
    must not be cached (transient failures retry on the next call), so
    on such hosts these cases print a skip note and pass vacuously. *)

open Llm_provider

let skip_note err =
  Printf.printf
    "skip: system trust store unavailable in this environment: %s\n"
    (Api_common.https_init_error_to_string err)
;;

let test_cached_physical_identity () =
  match Api_common.tls_client_config () with
  | Error err -> skip_note err
  | Ok first ->
    (match Api_common.tls_client_config () with
     | Error err ->
       Alcotest.failf
         "second call errored after first succeeded: %s"
         (Api_common.https_init_error_to_string err)
     | Ok second ->
       Alcotest.(check bool)
         "same physical Tls.Config.client on repeat calls"
         true
         (first == second))
;;

let test_make_https_result_reuses_cache () =
  match Api_common.tls_client_config () with
  | Error err -> skip_note err
  | Ok _ ->
    (match Api_common.make_https_result () with
     | Ok _wrap -> ()
     | Error err ->
       Alcotest.failf
         "make_https_result errored while a config is cached: %s"
         (Api_common.https_init_error_to_string err))
;;

let () =
  Alcotest.run
    "tls_config_cache"
    [ ( "cache"
      , [ Alcotest.test_case "physical identity" `Quick test_cached_physical_identity
        ; Alcotest.test_case
            "make_https_result reuses cache"
            `Quick
            test_make_https_result_reuses_cache
        ] )
    ]
;;
