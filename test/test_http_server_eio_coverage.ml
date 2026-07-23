(** Http Server Eio Module Coverage Tests

    Tests for http_server_eio types and functions:
    - config type
    - default_config constant
*)

open Alcotest
module Http_server_eio = Masc.Http_server_eio

(* ============================================================
   config Type Tests
   ============================================================ *)

let test_config_type () =
  let cfg : Http_server_eio.config =
    { port = 8080; host = "0.0.0.0"; max_connections = 256; listen_backlog = 64 }
  in
  check int "port" 8080 cfg.port;
  check string "host" "0.0.0.0" cfg.host;
  check int "max_connections" 256 cfg.max_connections
;;

let test_config_localhost () =
  let cfg : Http_server_eio.config =
    { port = 3000; host = "localhost"; max_connections = 64; listen_backlog = 32 }
  in
  check string "host" "localhost" cfg.host
;;

(* ============================================================
   default_config Tests
   ============================================================ *)

let test_default_config_port () =
  check int "default port" 8935 Http_server_eio.default_config.port
;;

let test_default_config_host () =
  check string "default host" "127.0.0.1" Http_server_eio.default_config.host
;;

let test_default_config_max_connections () =
  check int "default max_connections" 512 Http_server_eio.default_config.max_connections
;;

let test_default_config_valid () =
  let cfg = Http_server_eio.default_config in
  check bool "port > 0" true (cfg.port > 0);
  check bool "host not empty" true (String.length cfg.host > 0);
  check bool "max_connections > 0" true (cfg.max_connections > 0)
;;

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  run
    "Http Server Eio Coverage"
    [ ( "config"
      , [ test_case "type" `Quick test_config_type
        ; test_case "localhost" `Quick test_config_localhost
        ] )
    ; ( "default_config"
      , [ test_case "port" `Quick test_default_config_port
        ; test_case "host" `Quick test_default_config_host
        ; test_case "max_connections" `Quick test_default_config_max_connections
        ; test_case "valid" `Quick test_default_config_valid
        ] )
    ]
;;
