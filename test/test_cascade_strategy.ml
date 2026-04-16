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
module Cascade_state = Masc_mcp.Cascade_state

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
           ?(keeper_name = "")
           ?(cascade_name = "")
           () : S.signal_ctx =
  { health; capacity; now; rand_int = rand;
    keeper_name; cascade_name }

let mk_t ?(cycle = S.default_cycle_policy)
         ?(tiers = [])
         ?(sticky_ttl_ms = 0)
         kind : S.t =
  { kind; cycle; tiers; sticky_ttl_ms }

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
  let strat = mk_t S.Capacity_aware in
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
  let strat = mk_t S.Capacity_aware in
  let ordered = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  check (list string) "all busy → empty list" [] (names ordered)

let test_capacity_aware_unknown_passes () =
  let cands = [mk_cand "a"; mk_cand "b"] in
  let ctx = mk_ctx ~capacity:(fun _ -> None) () in
  let strat = mk_t S.Capacity_aware in
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
  let strat = mk_t S.Weighted_random in
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
  let strat = mk_t S.Weighted_random in
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
  let strat = mk_t S.Circuit_breaker_cycling
      ~cycle:{ max_cycles = 3; backoff_base_ms = 100; backoff_cap_ms = 1000 }
  in
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

(* ── Phase C3: CLI sentinel auto-registration ──────────────── *)

let test_cli_auto_register_filters_sentinels () =
  C.unregister_all ();
  C.auto_register_cli_for_candidates ~capacity_keys:[
    "cli:claude_code";
    "cli:gemini_cli";
    "http://127.0.0.1:8085";  (* HTTP, not CLI *)
    "";                       (* unknown / empty *)
  ];
  let urls = C.registered_urls () in
  check bool "cli:claude_code registered"
    true (List.mem "cli:claude_code" urls);
  check bool "cli:gemini_cli registered"
    true (List.mem "cli:gemini_cli" urls);
  check bool "http URL NOT registered as CLI"
    false (List.mem "http://127.0.0.1:8085" urls);
  check bool "empty key NOT registered"
    false (List.mem "" urls)

let test_cli_register_with_override () =
  C.unregister_all ();
  C.auto_register_cli_with_override
    ~capacity_keys:["cli:codex_cli"]
    ~max_concurrent:3;
  match C.capacity "cli:codex_cli" with
  | None -> fail "expected CLI registration"
  | Some info ->
    check int "CLI override max=3" 3 info.total

let test_cli_acquire_blocks_at_cap () =
  C.unregister_all ();
  C.auto_register_cli_with_override
    ~capacity_keys:["cli:claude_code"]
    ~max_concurrent:1;
  match C.try_acquire "cli:claude_code" with
  | None -> fail "first acquire should succeed"
  | Some release ->
    check bool "second acquire returns None at cap"
      true (C.try_acquire "cli:claude_code" = None);
    release ();
    check bool "after release: capacity available again"
      true (C.try_acquire "cli:claude_code" <> None)

let test_cli_idempotent_registration () =
  C.unregister_all ();
  C.auto_register_cli_with_override
    ~capacity_keys:["cli:gemini_cli"] ~max_concurrent:5;
  C.auto_register_cli_for_candidates
    ~capacity_keys:["cli:gemini_cli"];  (* should be no-op *)
  match C.capacity "cli:gemini_cli" with
  | None -> fail "expected registration"
  | Some info ->
    check int "first override preserved (idempotent)" 5 info.total

(* ── Phase B: Priority_tier (S5) ───────────────────────────── *)

let test_priority_tier_picks_first_tier () =
  let cands = [mk_cand "a"; mk_cand "b"; mk_cand "c"] in
  let strat = mk_t S.Priority_tier
      ~tiers:[["a"]; ["b"; "c"]]
  in
  let ctx = mk_ctx () in
  let ordered = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  check (list string) "cycle 0 → tier 0 (a only)" ["a"] (names ordered)

let test_priority_tier_advances_with_cycle () =
  let cands = [mk_cand "a"; mk_cand "b"; mk_cand "c"] in
  let strat = mk_t S.Priority_tier
      ~tiers:[["a"]; ["b"; "c"]]
  in
  let ctx = mk_ctx () in
  let cycle1 = S.order_candidates strat ~adapter ~ctx ~cycle:1 cands in
  check (list string) "cycle 1 → tier 1 (b, c)" ["b"; "c"] (names cycle1)

let test_priority_tier_clamps_overflow () =
  let cands = [mk_cand "a"; mk_cand "b"] in
  let strat = mk_t S.Priority_tier ~tiers:[["a"]; ["b"]] in
  let ctx = mk_ctx () in
  let cycle99 = S.order_candidates strat ~adapter ~ctx ~cycle:99 cands in
  check (list string) "cycle ≥ tiers count → last tier" ["b"] (names cycle99)

let test_priority_tier_capacity_filter () =
  let cands = [mk_cand "a"; mk_cand "b"] in
  let table = [
    (List.nth cands 0).url, mk_capacity_info ~total:1 ~active:1;
  ] in
  let strat = mk_t S.Priority_tier ~tiers:[["a"; "b"]] in
  let ctx = mk_ctx ~capacity:(stub_capacity table) () in
  let ordered = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  check (list string) "tier 0 with 'a' busy → only 'b'" ["b"] (names ordered)

(* ── Phase B: Sticky (S6) ──────────────────────────────────── *)

let test_sticky_records_and_pins () =
  Cascade_state.clear_all ();
  let cands = [mk_cand "a"; mk_cand "b"; mk_cand "c"] in
  let strat = mk_t S.Sticky ~sticky_ttl_ms:60_000 in
  let ctx = mk_ctx ~now:1000.0 ~keeper_name:"k1" ~cascade_name:"cas" () in
  (* First call: no entry → returns full list *)
  let first = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  check (list string) "no sticky → full list" ["a"; "b"; "c"] (names first);
  (* Record success on 'b' *)
  S.record_choice strat ~ctx ~provider_key:"b";
  (* Second call: pinned to 'b' *)
  let second = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  check (list string) "after record → pinned to 'b'" ["b"] (names second)

let test_sticky_expires_after_ttl () =
  Cascade_state.clear_all ();
  let cands = [mk_cand "a"; mk_cand "b"] in
  let strat = mk_t S.Sticky ~sticky_ttl_ms:60_000 in
  let ctx_now = mk_ctx ~now:0.0 ~keeper_name:"k" ~cascade_name:"cas" () in
  S.record_choice strat ~ctx:ctx_now ~provider_key:"a";
  (* 60s + 1ms past expiry *)
  let ctx_later = mk_ctx ~now:60.001 ~keeper_name:"k" ~cascade_name:"cas" () in
  let ordered = S.order_candidates strat ~adapter ~ctx:ctx_later ~cycle:0 cands in
  check (list string) "expired → fall back to full list"
    ["a"; "b"] (names ordered)

let test_sticky_pinned_provider_missing_falls_back () =
  Cascade_state.clear_all ();
  let cands = [mk_cand "a"; mk_cand "b"] in
  let strat = mk_t S.Sticky ~sticky_ttl_ms:60_000 in
  let ctx = mk_ctx ~now:0.0 ~keeper_name:"k" ~cascade_name:"cas" () in
  (* Pin 'c' which doesn't exist in the candidate list *)
  S.record_choice strat ~ctx ~provider_key:"c";
  let ordered = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  check (list string) "missing pin → fall back to full list"
    ["a"; "b"] (names ordered)

let test_sticky_per_keeper_isolation () =
  Cascade_state.clear_all ();
  let cands = [mk_cand "a"; mk_cand "b"] in
  let strat = mk_t S.Sticky ~sticky_ttl_ms:60_000 in
  let k1 = mk_ctx ~now:0.0 ~keeper_name:"k1" ~cascade_name:"cas" () in
  let k2 = mk_ctx ~now:0.0 ~keeper_name:"k2" ~cascade_name:"cas" () in
  S.record_choice strat ~ctx:k1 ~provider_key:"a";
  S.record_choice strat ~ctx:k2 ~provider_key:"b";
  let ordered_k1 = S.order_candidates strat ~adapter ~ctx:k1 ~cycle:0 cands in
  let ordered_k2 = S.order_candidates strat ~adapter ~ctx:k2 ~cycle:0 cands in
  check (list string) "k1 → 'a'" ["a"] (names ordered_k1);
  check (list string) "k2 → 'b'" ["b"] (names ordered_k2)

(* ── Phase B: Round_robin (S7) ─────────────────────────────── *)

let test_round_robin_rotates_each_call () =
  Cascade_state.clear_all ();
  let cands = [mk_cand "a"; mk_cand "b"; mk_cand "c"] in
  let strat = mk_t S.Round_robin in
  let ctx = mk_ctx ~cascade_name:"rr-test" () in
  let r0 = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  let r1 = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  let r2 = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  let r3 = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  check (list string) "call 0: cursor 0 → abc" ["a"; "b"; "c"] (names r0);
  check (list string) "call 1: cursor 1 → bca" ["b"; "c"; "a"] (names r1);
  check (list string) "call 2: cursor 2 → cab" ["c"; "a"; "b"] (names r2);
  check (list string) "call 3: cursor 3 mod 3 = 0 → abc" ["a"; "b"; "c"] (names r3)

let test_round_robin_singleton_no_op () =
  Cascade_state.clear_all ();
  let cands = [mk_cand "only"] in
  let strat = mk_t S.Round_robin in
  let ctx = mk_ctx ~cascade_name:"singleton" () in
  let r = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  check (list string) "singleton → unchanged" ["only"] (names r);
  (* Cursor not advanced for singleton *)
  check int "cursor stays at 0" 0
    (Cascade_state.peek_round_robin ~cascade:"singleton")

let test_round_robin_per_cascade_cursor () =
  Cascade_state.clear_all ();
  let cands = [mk_cand "a"; mk_cand "b"] in
  let strat = mk_t S.Round_robin in
  let ctx_x = mk_ctx ~cascade_name:"cas-x" () in
  let ctx_y = mk_ctx ~cascade_name:"cas-y" () in
  let _ = S.order_candidates strat ~adapter ~ctx:ctx_x ~cycle:0 cands in
  let _ = S.order_candidates strat ~adapter ~ctx:ctx_x ~cycle:0 cands in
  let r_y = S.order_candidates strat ~adapter ~ctx:ctx_y ~cycle:0 cands in
  check (list string) "cas-y has its own cursor (still 0)"
    ["a"; "b"] (names r_y)

(* ── Phase B: cascade_state primitives ─────────────────────── *)

let test_cascade_state_sticky_zero_ttl_no_record () =
  Cascade_state.clear_all ();
  Cascade_state.record_sticky_choice ~keeper:"k" ~cascade:"c"
    ~provider:"p" ~ttl_ms:0 ~now:0.0;
  match Cascade_state.lookup_sticky ~keeper:"k" ~cascade:"c" ~now:0.0 with
  | None -> ()
  | Some _ -> fail "ttl_ms=0 should not record"

let test_cascade_state_round_robin_negative_bound () =
  Cascade_state.clear_all ();
  let v = Cascade_state.rotate_round_robin ~cascade:"x" ~bound:0 in
  check int "bound<=0 → returns 0" 0 v;
  let v2 = Cascade_state.rotate_round_robin ~cascade:"x" ~bound:(-3) in
  check int "negative bound → returns 0" 0 v2

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
      test_case "cli sentinel auto-register filters non-CLI" `Quick
        test_cli_auto_register_filters_sentinels;
      test_case "cli auto_register override sets max" `Quick
        test_cli_register_with_override;
      test_case "cli acquire blocks at cap, releases freely" `Quick
        test_cli_acquire_blocks_at_cap;
      test_case "cli registration is idempotent" `Quick
        test_cli_idempotent_registration;
    ];
    "priority_tier", [
      test_case "cycle 0 picks first tier" `Quick
        test_priority_tier_picks_first_tier;
      test_case "cycle advances with tier index" `Quick
        test_priority_tier_advances_with_cycle;
      test_case "cycle overflow clamps to last tier" `Quick
        test_priority_tier_clamps_overflow;
      test_case "tier respects capacity filter" `Quick
        test_priority_tier_capacity_filter;
    ];
    "sticky", [
      test_case "record_choice → pinned on next call" `Quick
        test_sticky_records_and_pins;
      test_case "expires after ttl" `Quick
        test_sticky_expires_after_ttl;
      test_case "missing pinned provider falls back" `Quick
        test_sticky_pinned_provider_missing_falls_back;
      test_case "per-keeper isolation" `Quick
        test_sticky_per_keeper_isolation;
    ];
    "round_robin", [
      test_case "rotates each call" `Quick
        test_round_robin_rotates_each_call;
      test_case "singleton list is no-op" `Quick
        test_round_robin_singleton_no_op;
      test_case "per-cascade cursor isolation" `Quick
        test_round_robin_per_cascade_cursor;
    ];
    "cascade_state", [
      test_case "sticky ttl_ms=0 does not record" `Quick
        test_cascade_state_sticky_zero_ttl_no_record;
      test_case "round_robin bound<=0 returns 0" `Quick
        test_cascade_state_round_robin_negative_bound;
    ];
  ]
