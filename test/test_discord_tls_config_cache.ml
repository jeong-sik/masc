(** Regression guard for the process-wide Discord TLS config cache.

    [client_tls_config] runs on every gateway (re)connect; it must load
    the system trust store once (macOS: one `security find-certificate`
    subprocess per keychain plus a full PEM parse) and reuse the config
    on later calls instead of reloading per reconnect (2026-07-17 masc
    CPU-full diagnosis; the LLM connection-path twin of this cache is
    tested in oas test_tls_config_cache).

    Hosts without a readable trust store make the loader raise [Failure];
    there is nothing to cache in that environment, so the case prints a
    skip note and passes vacuously (failures are deliberately not
    cached — the next reconnect retries the load). *)

module Conn = Discord_wss_connection

let test_physical_identity () =
  match Conn.For_testing.client_tls_config () with
  | exception Failure msg ->
    Printf.printf "skip: system trust store unavailable: %s\n" msg
  | first ->
    let second = Conn.For_testing.client_tls_config () in
    Alcotest.(check bool)
      "same physical Tls.Config.client on repeat calls"
      true
      (first == second)
;;

let () =
  Alcotest.run
    "discord_tls_config_cache"
    [ ( "cache"
      , [ Alcotest.test_case "physical identity" `Quick test_physical_identity ] )
    ]
;;
