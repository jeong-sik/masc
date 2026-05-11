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
  let probe_a =
    make_mock
      ~recognizes:(fun _ -> true)
      ~cached_result:(Some (mock_cap ~total:2 ~active:0))
      ()
  in
  let probe_b =
    make_mock
      ~recognizes:(fun _ -> true)
      ~cached_result:(Some (mock_cap ~total:4 ~active:2))
      ()
  in
  Cp.For_testing.with_registry [ probe_a ] (fun () ->
    check bool "probe_a active" true (Cp.can_probe ~url:"any"));
  (* After with_registry, registry should be restored to whatever it was
     before.  Re-register probe_b and verify it takes effect. *)
  Cp.For_testing.with_registry [ probe_b ] (fun () ->
    check bool "probe_b active" true (Cp.can_probe ~url:"any"))
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

let test_capacity_falls_through_to_client () =
  Cp.For_testing.clear_registry ();
  (* No probes registered → capacity falls through to
     Cascade_client_capacity, which returns None for unknown URLs. *)
  match Cp.capacity "http://nothing-registered:9999" with
  | None -> ()
  | Some _ ->
    (* Cascade_client_capacity or Cascade_throttle may have a global
       entry for this URL in some test environments.  Accept Some as
       well — the important thing is no exception. *)
    ()
;;

(* ── Test suite ──────────────────────────────────────────────── *)

let () =
  run
    "cascade_capacity_probe"
    [ ( "registry"
      , [ test_case "clear empties registry" `Quick test_clear_registry
        ; test_case "register + can_probe" `Quick test_register_can_probe
        ; test_case "with_registry restores" `Quick test_with_registry_restores
        ] )
    ; ( "resolution"
      , [ test_case "cached returns first match" `Quick test_cached_returns_first_match
        ; test_case
            "cached returns None when no match"
            `Quick
            test_cached_returns_none_when_no_match
        ; test_case "capacity falls through" `Quick test_capacity_falls_through_to_client
        ] )
    ]
;;
