(** Unit tests for Cascade_strategy and Cascade_client_capacity.

    Strategy ordering is pure — these tests use a synthetic record
    type plus an adapter rather than building real Provider_config.t
    values, isolating strategy behaviour from provider construction.

    Cascade_client_capacity carries process-global state via a
    Hashtbl; each test that mutates the registry calls [unregister_all]
    in setup. *)

open Alcotest
module S = Masc_mcp.Cascade_strategy
module H = Masc_mcp.Cascade_health_tracker
module C = Masc_mcp.Cascade_client_capacity
module T = Masc_mcp.Cascade_throttle

(* ── Test fixture ────────────────────────────────────────────── *)

type cand = {
  name : string;          (* health key *)
  url : string;           (* capacity key *)
  w : int;                (* config weight *)
}

let mk_cand ?(url = "http://test/" ^ "x") ?(w = 1) name =
  { name; url = url ^ name; w }

let adapter : cand S.adapter = {
  health_key = (fun c -> c.name);
  capacity_key = (fun c -> c.url);
  weight = (fun c -> c.w);
}

let names cands = List.map (fun c -> c.name) cands

let mk_capacity_info ~total ~active = {
  T.total;
  process_active = active;
  process_available = max 0 (total - active);
  process_queue_length = 0;
  source = Llm_provider.Provider_throttle.Fallback;
}

(* Capacity stub: caller supplies a closure mapping URL → capacity_info. *)
let stub_capacity table url =
  try Some (List.assoc url table) with Not_found -> None

let mk_ctx ?(health = H.create ())
           ?(capacity = fun _ -> None)
           ?(now = 0.0)
           ?(rand = fun _ -> 0)
           () : S.signal_ctx =
  { health; capacity; now; rand_int = rand }

(* ── S1 Failover ─────────────────────────────────────────────── *)

let test_failover_preserves_order () =
  let cands = [mk_cand "a"; mk_cand "b"; mk_cand "c"] in
  let ctx = mk_ctx () in
  let ordered = S.order_candidates S.failover ~adapter ~ctx ~cycle:0 cands in
  check (list string) "input order preserved"
    ["a"; "b"; "c"] (names ordered)

(* ── S2 Capacity_aware ───────────────────────────────────────── *)

let test_capacity_aware_filters_busy () =
  let cands = [mk_cand "a"; mk_cand "b"; mk_cand "c"] in
  let table = [
    (List.nth cands 0).url, mk_capacity_info ~total:1 ~active:1;
    (List.nth cands 1).url, mk_capacity_info ~total:2 ~active:0;
    (* "c" has no entry → unknown → kept (fail-open) *)
  ] in
  let ctx = mk_ctx ~capacity:(stub_capacity table) () in
  let strat = { S.kind = Capacity_aware; cycle = S.default_cycle_policy } in
  let ordered = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  check (list string) "busy 'a' filtered, 'b' and 'c' (unknown) kept"
    ["b"; "c"] (names ordered)

let test_capacity_aware_all_busy_yields_empty () =
  let cands = [mk_cand "a"; mk_cand "b"] in
  let table = [
    (List.nth cands 0).url, mk_capacity_info ~total:1 ~active:1;
    (List.nth cands 1).url, mk_capacity_info ~total:1 ~active:1;
  ] in
  let ctx = mk_ctx ~capacity:(stub_capacity table) () in
  let strat = { S.kind = Capacity_aware; cycle = S.default_cycle_policy } in
  let ordered = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  check (list string) "all busy → empty list" [] (names ordered)

let test_capacity_aware_unknown_passes () =
  let cands = [mk_cand "a"; mk_cand "b"] in
  let ctx = mk_ctx ~capacity:(fun _ -> None) () in
  let strat = { S.kind = Capacity_aware; cycle = S.default_cycle_policy } in
  let ordered = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  check (list string) "unknown capacity → all kept (fail-open)"
    ["a"; "b"] (names ordered)

(* ── S3 Weighted_random ──────────────────────────────────────── *)

let test_weighted_random_deterministic_with_rand0 () =
  (* With rand_int = (fun _ -> 0) the weighted picker always selects
     the first remaining candidate, producing a stable left-to-right
     ordering identical to the input. *)
  let cands = [
    mk_cand ~w:30 "a";
    mk_cand ~w:50 "b";
    mk_cand ~w:20 "c";
  ] in
  let ctx = mk_ctx ~rand:(fun _ -> 0) () in
  let strat = { S.kind = Weighted_random; cycle = S.default_cycle_policy } in
  let ordered = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  check (list string) "rand=0 picks left-to-right"
    ["a"; "b"; "c"] (names ordered)

let test_weighted_random_starvation_guard () =
  (* Cool down all providers via health tracker.  effective_weight
     becomes 0 for all; the order_weighted_entries-style guard must
     keep at least the original list (with weight 1). *)
  let h = H.create () in
  let cool_down k =
    H.record_failure h ~provider_key:k;
    H.record_failure h ~provider_key:k;
    H.record_failure h ~provider_key:k
  in
  cool_down "a"; cool_down "b";
  let cands = [mk_cand ~w:50 "a"; mk_cand ~w:30 "b"] in
  let ctx = mk_ctx ~health:h ~rand:(fun _ -> 0) () in
  let strat = { S.kind = Weighted_random; cycle = S.default_cycle_policy } in
  let ordered = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  check int "all-cooldown → fallback picks at least 1"
    2 (List.length ordered)

(* ── S4 Circuit_breaker_cycling ──────────────────────────────── *)

let test_cb_cycling_excludes_cooldown_and_busy () =
  let h = H.create () in
  H.record_failure h ~provider_key:"a";
  H.record_failure h ~provider_key:"a";
  H.record_failure h ~provider_key:"a";
  let cands = [mk_cand "a"; mk_cand "b"; mk_cand "c"] in
  let table = [
    (List.nth cands 1).url, mk_capacity_info ~total:1 ~active:1;
    (* "c" unknown → kept *)
  ] in
  let ctx = mk_ctx ~health:h ~capacity:(stub_capacity table) () in
  let strat = {
    S.kind = Circuit_breaker_cycling;
    cycle = { max_cycles = 3; backoff_base_ms = 100; backoff_cap_ms = 1000 };
  } in
  let ordered = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  check (list string) "cooldown 'a' + busy 'b' filtered, 'c' (unknown) kept"
    ["c"] (names ordered)

(* ── Cycle policy + backoff ───────────────────────────────────── *)

let test_default_cycle_policy_backward_compat () =
  let p = S.default_cycle_policy in
  check int "max_cycles=1 (no retry)" 1 p.max_cycles;
  check int "backoff_base_ms=500" 500 p.backoff_base_ms;
  check int "backoff_cap_ms=10000" 10_000 p.backoff_cap_ms

let test_backoff_zero_at_cycle_zero () =
  check int "cycle 0 → 0ms (no sleep before first attempt)"
    0 (S.backoff_ms S.default_cycle_policy ~cycle:0)

let test_backoff_exponential_capped () =
  let p = { S.max_cycles = 5; backoff_base_ms = 100; backoff_cap_ms = 500 } in
  check int "cycle 1 → base"          100 (S.backoff_ms p ~cycle:1);
  check int "cycle 2 → base*2"        200 (S.backoff_ms p ~cycle:2);
  check int "cycle 3 → base*4"        400 (S.backoff_ms p ~cycle:3);
  check int "cycle 4 → cap (would be 800)"
                                       500 (S.backoff_ms p ~cycle:4);
  check int "cycle 30 → cap (would overflow)"
                                       500 (S.backoff_ms p ~cycle:30)

(* ── parse_kind ───────────────────────────────────────────────── *)

let test_parse_kind_known () =
  let check_ok s expected =
    match S.parse_kind s with
    | Ok k ->
      check string ("parse " ^ s) (S.kind_to_string expected) (S.kind_to_string k)
    | Error msg -> fail (Printf.sprintf "expected Ok, got Error %s" msg)
  in
  check_ok "failover" S.Failover;
  check_ok "capacity_aware" S.Capacity_aware;
  check_ok "weighted_random" S.Weighted_random;
  check_ok "circuit_breaker_cycling" S.Circuit_breaker_cycling

let test_parse_kind_unknown () =
  match S.parse_kind "round_robin_xx" with
  | Ok _ -> fail "expected Error for unknown kind"
  | Error msg ->
    check bool "error mentions the rejected name"
      true (String.length msg > 0
            && (let needle = "round_robin_xx" in
                let nlen = String.length needle in
                let hlen = String.length msg in
                let rec loop i =
                  if i + nlen > hlen then false
                  else if String.sub msg i nlen = needle then true
                  else loop (i + 1)
                in loop 0))

(* ── Cascade_client_capacity ─────────────────────────────────── *)

let test_client_capacity_register_query () =
  C.unregister_all ();
  C.register ~url:"http://localhost:11434" ~max_concurrent:1;
  match C.capacity "http://localhost:11434" with
  | None -> fail "expected Some after register"
  | Some info ->
    check int "total = 1" 1 info.total;
    check int "active = 0 initially" 0 info.process_active;
    check int "available = 1 initially" 1 info.process_available

let test_client_capacity_acquire_release () =
  C.unregister_all ();
  C.register ~url:"http://x:11434" ~max_concurrent:1;
  match C.try_acquire "http://x:11434" with
  | None -> fail "first acquire should succeed"
  | Some release ->
    (match C.capacity "http://x:11434" with
     | Some info -> check int "active = 1 after acquire" 1 info.process_active
     | None -> fail "capacity disappeared");
    (* Second acquire must fail. *)
    (match C.try_acquire "http://x:11434" with
     | Some _ -> fail "second acquire on 1-slot must fail"
     | None -> ());
    release ();
    (match C.capacity "http://x:11434" with
     | Some info ->
       check int "active = 0 after release" 0 info.process_active
     | None -> fail "capacity disappeared after release")

let test_client_capacity_release_idempotent () =
  C.unregister_all ();
  C.register ~url:"http://y:11434" ~max_concurrent:1;
  match C.try_acquire "http://y:11434" with
  | None -> fail "acquire failed"
  | Some release ->
    release ();
    release ();  (* second release must be a no-op, not underflow *)
    match C.capacity "http://y:11434" with
    | Some info ->
      check int "active = 0 not -1" 0 info.process_active
    | None -> fail "capacity disappeared"

let test_client_capacity_unregistered_url () =
  C.unregister_all ();
  check (option int) "capacity = None for unregistered URL"
    None (Option.map (fun (i : T.capacity_info) -> i.total)
            (C.capacity "http://nope:9999"));
  check bool "try_acquire = None for unregistered URL"
    true (C.try_acquire "http://nope:9999" = None)

let test_client_capacity_clamp_max () =
  C.unregister_all ();
  C.register ~url:"http://z:11434" ~max_concurrent:0;  (* clamped up to 1 *)
  match C.capacity "http://z:11434" with
  | None -> fail "register did not register"
  | Some info ->
    check int "max_concurrent <=0 clamped to 1" 1 info.total

let test_ollama_auto_register () =
  C.unregister_all ();
  C.auto_register_for_candidates ~base_urls:[
    "http://127.0.0.1:11434";
    "http://glm.example.com/api";    (* not ollama: 11434 not in URL *)
    "http://other:11434/api";        (* ollama-like *)
  ];
  let urls = C.registered_urls () in
  check bool "127.0.0.1:11434 registered"
    true (List.mem "http://127.0.0.1:11434" urls);
  check bool "other:11434 registered"
    true (List.mem "http://other:11434/api" urls);
  check bool "glm.example.com NOT registered"
    false (List.mem "http://glm.example.com/api" urls)

let test_ollama_register_with_override () =
  C.unregister_all ();
  C.auto_register_ollama_with_override
    ~base_urls:["http://127.0.0.1:11434"]
    ~max_concurrent:4;
  match C.capacity "http://127.0.0.1:11434" with
  | None -> fail "expected registration"
  | Some info ->
    check int "override max=4" 4 info.total

let () =
  run "cascade_strategy" [
    "failover", [
      test_case "preserves order" `Quick test_failover_preserves_order;
    ];
    "capacity_aware", [
      test_case "filters busy candidates" `Quick test_capacity_aware_filters_busy;
      test_case "all busy yields empty" `Quick test_capacity_aware_all_busy_yields_empty;
      test_case "unknown capacity passes" `Quick test_capacity_aware_unknown_passes;
    ];
    "weighted_random", [
      test_case "deterministic with rand=0" `Quick
        test_weighted_random_deterministic_with_rand0;
      test_case "starvation guard kicks in" `Quick
        test_weighted_random_starvation_guard;
    ];
    "circuit_breaker_cycling", [
      test_case "excludes cooldown and busy" `Quick
        test_cb_cycling_excludes_cooldown_and_busy;
    ];
    "cycle_policy", [
      test_case "default policy backward-compat" `Quick
        test_default_cycle_policy_backward_compat;
      test_case "backoff zero at cycle 0" `Quick
        test_backoff_zero_at_cycle_zero;
      test_case "backoff exponential, capped" `Quick
        test_backoff_exponential_capped;
    ];
    "parse_kind", [
      test_case "known kinds parse" `Quick test_parse_kind_known;
      test_case "unknown kind returns Error with name" `Quick
        test_parse_kind_unknown;
    ];
    "client_capacity", [
      test_case "register + query" `Quick test_client_capacity_register_query;
      test_case "acquire + release lifecycle" `Quick
        test_client_capacity_acquire_release;
      test_case "release is idempotent" `Quick
        test_client_capacity_release_idempotent;
      test_case "unregistered URL returns None" `Quick
        test_client_capacity_unregistered_url;
      test_case "max_concurrent <= 0 clamped to 1" `Quick
        test_client_capacity_clamp_max;
      test_case "auto-register matches :11434 hosts" `Quick
        test_ollama_auto_register;
      test_case "auto_register override sets max" `Quick
        test_ollama_register_with_override;
    ];
  ]
