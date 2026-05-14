(** Unit tests for [Cascade_capacity_probe] adapter dispatch.

    Tests the provider-agnostic registry and 3-tier resolution chain
    without hitting the network — mock probes return canned results. *)

open Alcotest
module Cp = Masc_mcp.Cascade_capacity_probe
module Throttle = Masc_mcp.Cascade_throttle

(* ── Mock probe ─────────────────────────────────────────────── *)

let mock_cap ~total ~active =
  { Throttle.total
  ; process_active = active
  ; process_available = max 0 (total - active)
  ; process_queue_length = 0
  ; source = Llm_provider.Provider_throttle.Discovered
  }
;;

let make_mock ~recognizes ?(cached_result = None) () =
  (module struct
    let can_probe ~url = recognizes url
    let probe ~sw:_ ~net:_ ~url:_ ?timeout_s:_ () = cached_result
    let cached ~url ?now:_ () = if recognizes url then cached_result else None
    let refresh_many ~sw:_ ~net:_ ~urls:_ ?timeout_s:_ () = ()
  end : Cp.Probe)
;;

(* ── Registry lifecycle ──────────────────────────────────────── *)

let test_clear_registry () =
  Cp.For_testing.clear_registry ();
  check bool "empty after clear" false (Cp.can_probe ~url:"http://127.0.0.1:11434")
;;

let test_register_can_probe () =
  Cp.For_testing.clear_registry ();
  let probe =
    make_mock
      ~recognizes:(fun url -> String.ends_with ~suffix:":11434" url)
      ~cached_result:(Some (mock_cap ~total:1 ~active:0))
      ()
  in
  Cp.register probe;
  check bool "recognises ollama" true (Cp.can_probe ~url:"http://localhost:11434");
  check bool "ignores non-ollama" false (Cp.can_probe ~url:"http://openai.com")
;;

let test_with_registry_restores () =
  Cp.For_testing.clear_registry ();
  let baseline =
    make_mock
      ~recognizes:(fun url -> String.starts_with ~prefix:"http://baseline" url)
      ~cached_result:(Some (mock_cap ~total:1 ~active:0))
      ()
  in
  Cp.register baseline;
  let swapped =
    make_mock
      ~recognizes:(fun url -> String.starts_with ~prefix:"http://swapped" url)
      ~cached_result:(Some (mock_cap ~total:9 ~active:0))
      ()
  in
  Cp.For_testing.with_registry [ swapped ] (fun () ->
    check bool "swapped visible inside swap" true (Cp.can_probe ~url:"http://swapped/x");
    check bool "baseline hidden inside swap" false (Cp.can_probe ~url:"http://baseline/x"));
  check bool "baseline restored after swap" true (Cp.can_probe ~url:"http://baseline/x");
  check bool "swapped gone after swap" false (Cp.can_probe ~url:"http://swapped/x")
;;

let test_with_registry_restores_after_exception () =
  Cp.For_testing.clear_registry ();
  let baseline =
    make_mock
      ~recognizes:(fun u -> u = "http://baseline")
      ~cached_result:(Some (mock_cap ~total:1 ~active:0))
      ()
  in
  Cp.register baseline;
  let swapped =
    make_mock ~recognizes:(fun _ -> true) ~cached_result:None ()
  in
  (try
     Cp.For_testing.with_registry [ swapped ] (fun () -> failwith "boom")
   with
   | Failure _ -> ());
  check bool "registry restored even when f raises" true
    (Cp.can_probe ~url:"http://baseline")
;;

(* ── Resolution chain ────────────────────────────────────────── *)

let test_cached_returns_first_match () =
  Cp.For_testing.clear_registry ();
  let url = "http://localhost:11434" in
  let cap = mock_cap ~total:1 ~active:0 in
  let probe = make_mock ~recognizes:(fun u -> u = url) ~cached_result:(Some cap) () in
  Cp.register probe;
  match Cp.cached ~url () with
  | None -> fail "expected Some from registered probe"
  | Some info ->
    check int "total" 1 info.total;
    check int "available" 1 info.process_available
;;

let test_cached_returns_none_when_no_match () =
  Cp.For_testing.clear_registry ();
  let probe =
    make_mock
      ~recognizes:(fun _ -> false)
      ~cached_result:(Some (mock_cap ~total:1 ~active:0))
      ()
  in
  Cp.register probe;
  match Cp.cached ~url:"http://unknown:9999" () with
  | None -> ()
  | Some _ -> fail "expected None for unrecognised URL"
;;

let test_capacity_prefers_probe_cache_over_client () =
  Cp.For_testing.clear_registry ();
  let url = "http://probe-wins.example/x" in
  let probe_cap = mock_cap ~total:7 ~active:1 in
  let p = make_mock ~recognizes:(fun u -> u = url) ~cached_result:(Some probe_cap) () in
  Cp.register p;
  match Cp.capacity url with
  | None -> fail "expected probe cache to satisfy capacity"
  | Some info ->
    check int "probe cache wins over client capacity" 7 info.total;
    check int "available" 6 info.process_available
;;

let test_capacity_returns_none_for_unknown_url () =
  Cp.For_testing.clear_registry ();
  (* No probes registered + URL has no Throttle/Client_capacity entry. *)
  let url = "http://nothing-registered.example.invalid:65530/never" in
  match Cp.capacity url with
  | None -> ()
  | Some _ ->
    fail
      "expected None — no probe registered and URL is intentionally unknown to \
       Throttle/Client_capacity"
;;

(* ── Test suite ──────────────────────────────────────────────── *)

let () =
  run
    "cascade_capacity_probe"
    [ ( "registry"
      , [ test_case "clear empties registry" `Quick test_clear_registry
        ; test_case "register + can_probe" `Quick test_register_can_probe
        ; test_case "with_registry restores" `Quick test_with_registry_restores
        ; test_case
            "with_registry restores after exception"
            `Quick
            test_with_registry_restores_after_exception
        ] )
    ; ( "resolution"
      , [ test_case "cached returns first match" `Quick test_cached_returns_first_match
        ; test_case
            "cached returns None when no match"
            `Quick
            test_cached_returns_none_when_no_match
        ; test_case
            "capacity prefers probe cache over client"
            `Quick
            test_capacity_prefers_probe_cache_over_client
        ; test_case
            "capacity returns None for unknown url"
            `Quick
            test_capacity_returns_none_for_unknown_url
        ] )
    ]
;;
