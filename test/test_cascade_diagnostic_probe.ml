(** Unit tests for [Cascade_diagnostic_probe] adapter dispatch.

    Tests the provider-agnostic registry, [find_owner] resolution, and
    the top-level [*_json] fall-through-to-`Null contract without
    hitting the network — mock probes return canned JSON. *)

open Alcotest
module Dp = Masc_mcp.Cascade_diagnostic_probe

(* ── Mock probe ─────────────────────────────────────────────── *)

let make_mock ~recognizes ?(loaded_json = `Null) ?(probe_json = `Null) () =
  (module struct
    let can_probe ~url = recognizes url

    let loaded_models_json ~sw:_ ~net:_ ~url ?timeout_sec:_ () =
      if recognizes url then loaded_json else `Null
    ;;

    let runtime_probe_json
      ~sw:_
      ~net:_
      ~url
      ~probe_runs:_
      ~max_tokens:_
      ?think_enabled:_
      ()
      =
      if recognizes url then probe_json else `Null
    ;;
  end : Dp.Diagnostic_probe)
;;

(* Top-level dispatch tests need [sw] and [net] arguments — mocks
   short-circuit on can_probe so the network is never touched. *)
let with_dummy_env f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw -> f sw (Eio.Stdenv.net env)
;;

(* ── Registry lifecycle ──────────────────────────────────────── *)

let test_clear_registry () =
  Dp.For_testing.clear_registry ();
  check bool "find_owner empty after clear" true (Option.is_none (Dp.find_owner ~url:"x"))
;;

let test_register_find_owner () =
  Dp.For_testing.clear_registry ();
  let probe =
    make_mock ~recognizes:(fun url -> String.ends_with ~suffix:":11434" url) ()
  in
  Dp.register probe;
  check bool "recognises endpoint" true (Option.is_some (Dp.find_owner ~url:"http://localhost:11434"));
  check
    bool
    "ignores unknown endpoint"
    true
    (Option.is_none (Dp.find_owner ~url:"http://openai.com"))
;;

let test_with_registry_restores () =
  Dp.For_testing.clear_registry ();
  let baseline =
    make_mock ~recognizes:(fun url -> String.starts_with ~prefix:"http://baseline" url) ()
  in
  Dp.register baseline;
  let swapped =
    make_mock ~recognizes:(fun url -> String.starts_with ~prefix:"http://swapped" url) ()
  in
  Dp.For_testing.with_registry [ swapped ] (fun () ->
    check
      bool
      "swapped visible inside swap"
      true
      (Option.is_some (Dp.find_owner ~url:"http://swapped/x"));
    check
      bool
      "baseline hidden inside swap"
      true
      (Option.is_none (Dp.find_owner ~url:"http://baseline/x")));
  check
    bool
    "baseline restored after swap"
    true
    (Option.is_some (Dp.find_owner ~url:"http://baseline/x"));
  check
    bool
    "swapped gone after swap"
    true
    (Option.is_none (Dp.find_owner ~url:"http://swapped/x"))
;;

let test_with_registry_restores_after_exception () =
  Dp.For_testing.clear_registry ();
  let baseline = make_mock ~recognizes:(fun u -> u = "http://baseline") () in
  Dp.register baseline;
  let swapped = make_mock ~recognizes:(fun _ -> true) () in
  (try Dp.For_testing.with_registry [ swapped ] (fun () -> failwith "boom") with
   | Failure _ -> ());
  check
    bool
    "registry restored even when f raises"
    true
    (Option.is_some (Dp.find_owner ~url:"http://baseline"))
;;

(* ── Top-level routed dispatch ───────────────────────────────── *)

let test_loaded_models_json_routed () =
  Dp.For_testing.clear_registry ();
  let probe =
    make_mock
      ~recognizes:(fun u -> u = "http://r")
      ~loaded_json:(`Assoc [ "models", `List [ `String "m1" ] ])
      ()
  in
  Dp.register probe;
  with_dummy_env
  @@ fun sw net ->
  let json = Dp.loaded_models_json ~sw ~net ~url:"http://r" () in
  check
    bool
    "routed loaded_models_json returns probe result"
    true
    (json
     = `Assoc [ "models", `List [ `String "m1" ] ])
;;

let test_loaded_models_json_null_when_unknown () =
  Dp.For_testing.clear_registry ();
  let probe =
    make_mock ~recognizes:(fun u -> u = "http://r") ~loaded_json:(`String "x") ()
  in
  Dp.register probe;
  with_dummy_env
  @@ fun sw net ->
  let json = Dp.loaded_models_json ~sw ~net ~url:"http://unknown" () in
  check bool "null for unknown url" true (json = `Null)
;;

let test_runtime_probe_json_routed () =
  Dp.For_testing.clear_registry ();
  let probe =
    make_mock
      ~recognizes:(fun u -> u = "http://r")
      ~probe_json:(`Assoc [ "decode_ms", `Int 42 ])
      ()
  in
  Dp.register probe;
  with_dummy_env
  @@ fun sw net ->
  let json =
    Dp.runtime_probe_json ~sw ~net ~url:"http://r" ~probe_runs:1 ~max_tokens:8 ()
  in
  check
    bool
    "routed runtime_probe_json returns probe result"
    true
    (json = `Assoc [ "decode_ms", `Int 42 ])
;;

let test_runtime_probe_json_null_when_unknown () =
  Dp.For_testing.clear_registry ();
  let probe =
    make_mock
      ~recognizes:(fun u -> u = "http://r")
      ~probe_json:(`Assoc [ "decode_ms", `Int 42 ])
      ()
  in
  Dp.register probe;
  with_dummy_env
  @@ fun sw net ->
  let json =
    Dp.runtime_probe_json ~sw ~net ~url:"http://unknown" ~probe_runs:1 ~max_tokens:8 ()
  in
  check bool "null for unknown url" true (json = `Null)
;;

(* ── Driver ──────────────────────────────────────────────────── *)

let () =
  run
    "cascade_diagnostic_probe"
    [ ( "registry"
      , [ test_case "clear empties registry" `Quick test_clear_registry
        ; test_case "register + find_owner" `Quick test_register_find_owner
        ; test_case "with_registry restores" `Quick test_with_registry_restores
        ; test_case
            "with_registry restores after exception"
            `Quick
            test_with_registry_restores_after_exception
        ] )
    ; ( "dispatch"
      , [ test_case
            "loaded_models_json routed"
            `Quick
            test_loaded_models_json_routed
        ; test_case
            "loaded_models_json `Null when unknown"
            `Quick
            test_loaded_models_json_null_when_unknown
        ; test_case
            "runtime_probe_json routed"
            `Quick
            test_runtime_probe_json_routed
        ; test_case
            "runtime_probe_json `Null when unknown"
            `Quick
            test_runtime_probe_json_null_when_unknown
        ] )
    ]
;;
