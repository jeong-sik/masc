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
module CH = Masc_mcp.Cascade_client_capacity_history
module ST = Masc_mcp.Cascade_strategy_trace
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

let test_failover_filters_cooldown () =
  let h = H.create () in
  H.record_failure h ~provider_key:"a" ();
  H.record_failure h ~provider_key:"a" ();
  H.record_failure h ~provider_key:"a" ();
  let cands = [mk_cand "a"; mk_cand "b"; mk_cand "c"] in
  let ctx = mk_ctx ~health:h () in
  let ordered = S.order_candidates S.failover ~adapter ~ctx ~cycle:0 cands in
  check (list string) "cooldown candidate removed, remaining order preserved"
    ["b"; "c"] (names ordered)

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

let test_weighted_random_all_cooldown_yields_empty () =
  (* Cool down all providers via health tracker. effective_weight
     becomes 0 for all, so weighted_random must return no candidates
     and let the caller surface a filtered-empty cascade state. *)
  let h = H.create () in
  let cool_down k =
    H.record_failure h ~provider_key:k ();
    H.record_failure h ~provider_key:k ();
    H.record_failure h ~provider_key:k ()
  in
  cool_down "a"; cool_down "b";
  let cands = [mk_cand ~w:50 "a"; mk_cand ~w:30 "b"] in
  let ctx = mk_ctx ~health:h ~rand:(fun _ -> 0) () in
  let strat = mk_t S.Weighted_random in
  let ordered = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  check (list string) "all-cooldown → empty"
    [] (names ordered)

(* ── S4 Circuit_breaker_cycling ──────────────────────────────── *)

let test_cb_cycling_excludes_cooldown_and_busy () =
  let h = H.create () in
  H.record_failure h ~provider_key:"a" ();
  H.record_failure h ~provider_key:"a" ();
  H.record_failure h ~provider_key:"a" ();
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

let test_cb_cycling_starvation_guard () =
  (* Cooldown filter passes both 'a' and 'b', but capacity reports 0 for
     both.  Guard must return the post-cooldown list instead of empty so
     a real call is attempted (otherwise cascade exhausts with no
     upstream error signal). *)
  let h = H.create () in
  let cands = [mk_cand "a"; mk_cand "b"] in
  let table = [
    (List.nth cands 0).url, mk_capacity_info ~total:1 ~active:1;
    (List.nth cands 1).url, mk_capacity_info ~total:1 ~active:1;
  ] in
  let ctx = mk_ctx ~health:h ~capacity:(stub_capacity table) () in
  let strat = mk_t S.Circuit_breaker_cycling
      ~cycle:{ max_cycles = 3; backoff_base_ms = 100; backoff_cap_ms = 1000 }
  in
  let ordered = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  check (list string) "all-busy cooled list → fall through non-empty"
    ["a"; "b"] (names ordered)

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

let test_snapshot_returns_all_entries () =
  C.unregister_all ();
  C.register ~url:"http://127.0.0.1:11434" ~max_concurrent:1;
  C.register ~url:"cli:claude_code" ~max_concurrent:2;
  let entries = C.snapshot () in
  check int "snapshot contains both entries" 2 (List.length entries);
  let lookup k = List.assoc_opt k entries in
  (match lookup "http://127.0.0.1:11434" with
   | Some info -> check int "ollama total" 1 info.total
   | None -> fail "ollama entry missing");
  (match lookup "cli:claude_code" with
   | Some info ->
     check int "cli total" 2 info.total;
     check int "cli initial active" 0 info.process_active;
     check int "cli initial available" 2 info.process_available
   | None -> fail "cli entry missing")

let test_snapshot_reflects_active_acquires () =
  C.unregister_all ();
  C.register ~url:"cli:codex_cli" ~max_concurrent:2;
  match C.try_acquire "cli:codex_cli" with
  | None -> fail "first acquire failed"
  | Some _release ->
    let entries = C.snapshot () in
    match List.assoc_opt "cli:codex_cli" entries with
    | None -> fail "snapshot missing entry"
    | Some info ->
      check int "active counted" 1 info.process_active;
      check int "available decremented" 1 info.process_available

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

let test_priority_tier_starvation_guard () =
  (* All tier candidates report capacity=0.  Without the guard the
     cascade would exit empty and surface as "all candidates filtered
     after N cycle(s)"; with it, the tier list itself is returned so
     at least one real call is attempted. *)
  let cands = [mk_cand "a"; mk_cand "b"] in
  let table = [
    (List.nth cands 0).url, mk_capacity_info ~total:1 ~active:1;
    (List.nth cands 1).url, mk_capacity_info ~total:1 ~active:1;
  ] in
  let strat = mk_t S.Priority_tier ~tiers:[["a"; "b"]] in
  let ctx = mk_ctx ~capacity:(stub_capacity table) () in
  let ordered = S.order_candidates strat ~adapter ~ctx ~cycle:0 cands in
  check (list string) "all-busy tier → fall through with tier list"
    ["a"; "b"] (names ordered)

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

(* ── Client capacity history (Phase D follow-up) ─────────── *)

let test_history_record_snapshot_roundtrip () =
  CH.clear ();
  CH.record { ts = 1000.0; key = "cli:claude_code";
              kind = Acquired; active_after = 1 };
  CH.record { ts = 1001.0; key = "cli:claude_code";
              kind = Released; active_after = 0 };
  CH.record { ts = 1002.0; key = "http://127.0.0.1:11434";
              kind = Rejected_full; active_after = 1 };
  let events = CH.snapshot () in
  check int "3 events recorded" 3 (List.length events);
  (* Newest-first ordering: ts=1002 must come first. *)
  (match events with
   | e0 :: e1 :: e2 :: [] ->
     check (float 0.0) "newest ts=1002" 1002.0 e0.ts;
     check (float 0.0) "middle ts=1001" 1001.0 e1.ts;
     check (float 0.0) "oldest ts=1000" 1000.0 e2.ts;
     check bool "newest kind = Rejected_full"
       true (e0.kind = CH.Rejected_full);
     check bool "middle kind = Released"
       true (e1.kind = CH.Released);
     check bool "oldest kind = Acquired"
       true (e2.kind = CH.Acquired)
   | _ -> fail "expected exactly 3 events")

let test_history_ring_buffer_drops_oldest () =
  CH.clear ();
  let cap = CH.capacity () in
  (* Record cap+5 events; oldest 5 must be dropped. *)
  for i = 0 to cap + 4 do
    CH.record { ts = float_of_int i;
                key = "cli:x";
                kind = Acquired;
                active_after = i }
  done;
  check int "count clamped to capacity" cap (CH.size ());
  let events = CH.snapshot ~limit:(cap + 10) () in
  check int "snapshot count = capacity" cap (List.length events);
  (* Newest must be ts=cap+4.  Oldest retained must be ts=5
     (i.e. the first 5 inserts at ts=0..4 were overwritten). *)
  (match events with
   | [] -> fail "expected at least one event"
   | newest :: _ ->
     check (float 0.0) "newest ts = cap+4"
       (float_of_int (cap + 4)) newest.ts);
  let oldest = List.nth events (cap - 1) in
  check (float 0.0) "oldest retained ts = 5 (earlier 5 dropped)"
    5.0 oldest.ts

let test_history_snapshot_kind_filter () =
  CH.clear ();
  CH.record { ts = 1.0; key = "cli:claude_code";
              kind = Acquired; active_after = 1 };
  CH.record { ts = 2.0; key = "http://127.0.0.1:11434";
              kind = Acquired; active_after = 1 };
  CH.record { ts = 3.0; key = "http://other.example/api";
              kind = Rejected_full; active_after = 0 };
  CH.record { ts = 4.0; key = "cli:gemini_cli";
              kind = Released; active_after = 0 };
  (* cli filter → 2 events, both cli:* keys *)
  let cli_events = CH.snapshot ~kind:"cli" () in
  check int "cli filter → 2 events" 2 (List.length cli_events);
  List.iter
    (fun e ->
       check string "cli filter matches classify_key"
         "cli" (CH.classify_key e.CH.key))
    cli_events;
  (* ollama filter → 1 event for :11434 *)
  let ollama_events = CH.snapshot ~kind:"ollama" () in
  check int "ollama filter → 1 event" 1 (List.length ollama_events);
  (* other filter → 1 event for http://other *)
  let other_events = CH.snapshot ~kind:"other" () in
  check int "other filter → 1 event" 1 (List.length other_events);
  (* Unknown kind → empty list *)
  let unknown = CH.snapshot ~kind:"no_such_kind" () in
  check int "unknown kind → empty" 0 (List.length unknown)

let test_history_try_acquire_records_events () =
  CH.clear ();
  C.unregister_all ();
  C.register ~url:"cli:claude_code" ~max_concurrent:1;
  (* First acquire → Acquired recorded *)
  (match C.try_acquire "cli:claude_code" with
   | None -> fail "first acquire should succeed"
   | Some release ->
     (* Second acquire → Rejected_full recorded *)
     check bool "second acquire hits cap"
       true (C.try_acquire "cli:claude_code" = None);
     release ();
     let events = CH.snapshot () in
     (* Expected newest-first: Released, Rejected_full, Acquired. *)
     check int "3 events recorded" 3 (List.length events);
     (match events with
      | r :: f :: a :: [] ->
        check bool "newest = Released" true (r.kind = CH.Released);
        check int "released active_after = 0" 0 r.active_after;
        check bool "middle = Rejected_full"
          true (f.kind = CH.Rejected_full);
        check int "rejected active_after = 1" 1 f.active_after;
        check bool "oldest = Acquired" true (a.kind = CH.Acquired);
        check int "acquired active_after = 1" 1 a.active_after;
        check string "all keys = cli:claude_code"
          "cli:claude_code" a.key
      | _ -> fail "expected 3 events"))

(* ── Prometheus counter coverage (LT-6) ──────────────────

   The counter increment runs outside the ring-buffer mutex and uses the
   same (kind, key_type) labels as the JSON projection.  We exercise the
   full surface in-memory by scraping Masc_mcp.Prometheus.to_prometheus_text
   after a record() call.  The counter value check is >= rather than = so
   the test is robust to other cases in the suite touching the same metric. *)

let counter_value_from_text text kind key_type =
  (* Scan lines of the form:
       masc_cascade_capacity_events_total{kind="acquired",key_type="cli"} 3.0
     and return the numeric value for the matching label pair.  Returns
     [None] when the line is missing. *)
  let target_kind = Printf.sprintf {|kind="%s"|} kind in
  let target_key  = Printf.sprintf {|key_type="%s"|} key_type in
  let lines = String.split_on_char '\n' text in
  let matching =
    List.filter (fun line ->
      String.length line > 0
      && String.length line >= String.length "masc_cascade_capacity_events_total"
      && String.sub line 0 (String.length "masc_cascade_capacity_events_total")
         = "masc_cascade_capacity_events_total"
      && (let has s =
            let nlen = String.length s in
            let llen = String.length line in
            let rec f i =
              if i + nlen > llen then false
              else if String.sub line i nlen = s then true
              else f (i + 1)
            in f 0
          in has target_kind && has target_key))
      lines
  in
  match matching with
  | [] -> None
  | line :: _ ->
    (* Last whitespace-separated token is the value. *)
    let parts = String.split_on_char ' ' line in
    (match List.rev parts with
     | v :: _ -> float_of_string_opt (String.trim v)
     | [] -> None)

let test_history_prometheus_counter_increments () =
  CH.clear ();
  let before =
    counter_value_from_text
      (Masc_mcp.Prometheus.to_prometheus_text ()) "acquired" "cli"
    |> Option.value ~default:0.0
  in
  CH.record { ts = 1.0; key = "cli:claude_code";
              kind = Acquired; active_after = 1 };
  CH.record { ts = 2.0; key = "cli:gemini_cli";
              kind = Acquired; active_after = 1 };
  CH.record { ts = 3.0; key = "http://127.0.0.1:11434";
              kind = Rejected_full; active_after = 1 };
  let text = Masc_mcp.Prometheus.to_prometheus_text () in
  let cli_acquired =
    counter_value_from_text text "acquired" "cli"
    |> Option.value ~default:0.0
  in
  let ollama_rejected =
    counter_value_from_text text "rejected_full" "ollama"
    |> Option.value ~default:0.0
  in
  check bool "cli/acquired counter advanced by >= 2"
    true (cli_acquired >= before +. 2.0);
  check bool "ollama/rejected_full counter advanced by >= 1"
    true (ollama_rejected >= 1.0)

(* ── Strategy decision trace (LT-5) ─────────────────── *)

let mk_trace_event ?(ts = 0.0) ?(cascade_name = "big_three")
    ?(strategy = "failover") ?(cycle = 0) ?(candidates_in = 3)
    ?(candidates_out = 3) ?(backoff_ms = 0) ?(kind = ST.Ordered)
    ?trace_id () =
  { ST.ts; cascade_name; strategy; cycle; candidates_in; candidates_out;
    backoff_ms; kind; trace_id }

let test_trace_record_snapshot_roundtrip () =
  ST.clear ();
  ST.record (mk_trace_event ~ts:1000.0 ~cycle:0 ~kind:ST.Ordered ());
  ST.record (mk_trace_event ~ts:1001.0 ~cycle:1
               ~candidates_out:0 ~backoff_ms:500 ~kind:ST.Filtered_empty ());
  ST.record (mk_trace_event ~ts:1002.0 ~cycle:2
               ~candidates_out:0 ~kind:ST.Exhausted ());
  let events = ST.snapshot () in
  check int "3 events recorded" 3 (List.length events);
  (match events with
   | e0 :: e1 :: e2 :: [] ->
     check (float 0.0) "newest ts" 1002.0 e0.ts;
     check (float 0.0) "middle ts" 1001.0 e1.ts;
     check (float 0.0) "oldest ts" 1000.0 e2.ts;
     check bool "newest kind Exhausted" true (e0.kind = ST.Exhausted);
     check bool "middle kind Filtered_empty" true (e1.kind = ST.Filtered_empty);
     check bool "oldest kind Ordered" true (e2.kind = ST.Ordered)
   | _ -> fail "expected 3 events")

let test_trace_cascade_filter () =
  ST.clear ();
  ST.record (mk_trace_event ~cascade_name:"big_three" ~ts:1.0 ());
  ST.record (mk_trace_event ~cascade_name:"nick0cave" ~ts:2.0 ());
  ST.record (mk_trace_event ~cascade_name:"big_three" ~ts:3.0 ());
  let unified = ST.snapshot ~cascade:"big_three" () in
  check int "big_three → 2 events" 2 (List.length unified);
  List.iter
    (fun e -> check string "cascade filter" "big_three" e.ST.cascade_name)
    unified;
  let missing = ST.snapshot ~cascade:"does_not_exist" () in
  check int "missing cascade → empty" 0 (List.length missing)

let test_trace_ring_drops_oldest () =
  ST.clear ();
  let cap = ST.capacity () in
  for i = 0 to cap + 4 do
    ST.record (mk_trace_event ~ts:(float_of_int i) ~cycle:i ())
  done;
  check int "count clamped to capacity" cap (ST.size ());
  let events = ST.snapshot ~limit:(cap + 10) () in
  check int "snapshot count = capacity" cap (List.length events);
  (match events with
   | newest :: _ ->
     check (float 0.0) "newest ts = cap+4" (float_of_int (cap + 4)) newest.ts
   | [] -> fail "expected events");
  let oldest = List.nth events (cap - 1) in
  check (float 0.0) "oldest retained ts = 5" 5.0 oldest.ts

let test_trace_limit_clamp () =
  ST.clear ();
  for i = 0 to 9 do
    ST.record (mk_trace_event ~ts:(float_of_int i) ())
  done;
  let five = ST.snapshot ~limit:5 () in
  check int "limit 5" 5 (List.length five);
  let zero = ST.snapshot ~limit:0 () in
  check int "limit 0 → empty" 0 (List.length zero);
  let huge = ST.snapshot ~limit:9999 () in
  check int "limit>count clamps to count" 10 (List.length huge)

let test_trace_kind_labels () =
  check string "ordered" "ordered" (ST.kind_to_string ST.Ordered);
  check string "filtered_empty" "filtered_empty"
    (ST.kind_to_string ST.Filtered_empty);
  check string "exhausted" "exhausted" (ST.kind_to_string ST.Exhausted)

(* ── Prometheus counter coverage (LT-7) ────────────────── *)

let find_strategy_counter_value text ~cascade ~strategy ~kind =
  let target_cascade = Printf.sprintf {|cascade="%s"|} cascade in
  let target_strategy = Printf.sprintf {|strategy="%s"|} strategy in
  let target_kind = Printf.sprintf {|kind="%s"|} kind in
  let prefix = "masc_cascade_strategy_decisions_total" in
  let plen = String.length prefix in
  let has haystack needle =
    let nlen = String.length needle in
    let hlen = String.length haystack in
    let rec loop i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else loop (i + 1)
    in loop 0
  in
  let lines = String.split_on_char '\n' text in
  let matching =
    List.filter (fun line ->
      String.length line >= plen
      && String.sub line 0 plen = prefix
      && has line target_cascade
      && has line target_strategy
      && has line target_kind)
      lines
  in
  match matching with
  | [] -> None
  | line :: _ ->
    (match List.rev (String.split_on_char ' ' line) with
     | v :: _ -> float_of_string_opt (String.trim v)
     | [] -> None)

let test_trace_prometheus_counter_increments () =
  ST.clear ();
  let before =
    find_strategy_counter_value
      (Masc_mcp.Prometheus.to_prometheus_text ())
      ~cascade:"big_three" ~strategy:"failover" ~kind:"ordered"
    |> Option.value ~default:0.0
  in
  ST.record (mk_trace_event ~cascade_name:"big_three"
               ~strategy:"failover" ~kind:ST.Ordered ());
  ST.record (mk_trace_event ~cascade_name:"big_three"
               ~strategy:"failover" ~kind:ST.Ordered ());
  ST.record (mk_trace_event ~cascade_name:"nick0cave"
               ~strategy:"circuit_breaker_cycling"
               ~kind:ST.Filtered_empty ~backoff_ms:500 ());
  let text = Masc_mcp.Prometheus.to_prometheus_text () in
  let ordered =
    find_strategy_counter_value text
      ~cascade:"big_three" ~strategy:"failover" ~kind:"ordered"
    |> Option.value ~default:0.0
  in
  let filtered =
    find_strategy_counter_value text
      ~cascade:"nick0cave" ~strategy:"circuit_breaker_cycling"
      ~kind:"filtered_empty"
    |> Option.value ~default:0.0
  in
  check bool "big_three/failover/ordered advanced by >= 2"
    true (ordered >= before +. 2.0);
  check bool "nick0cave/circuit_breaker_cycling/filtered_empty >= 1"
    true (filtered >= 1.0)

let () =
  run "cascade_strategy" [
    "failover", [
      test_case "preserves order" `Quick test_failover_preserves_order;
      test_case "filters cooldown" `Quick test_failover_filters_cooldown;
    ];
    "capacity_aware", [
      test_case "filters busy candidates" `Quick test_capacity_aware_filters_busy;
      test_case "all busy yields empty" `Quick test_capacity_aware_all_busy_yields_empty;
      test_case "unknown capacity passes" `Quick test_capacity_aware_unknown_passes;
    ];
    "weighted_random", [
      test_case "deterministic with rand=0" `Quick
        test_weighted_random_deterministic_with_rand0;
      test_case "all cooldown yields empty" `Quick
        test_weighted_random_all_cooldown_yields_empty;
    ];
    "circuit_breaker_cycling", [
      test_case "excludes cooldown and busy" `Quick
        test_cb_cycling_excludes_cooldown_and_busy;
      test_case "all-busy cooled list falls through (starvation guard)" `Quick
        test_cb_cycling_starvation_guard;
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
      test_case "snapshot returns all registered entries" `Quick
        test_snapshot_returns_all_entries;
      test_case "snapshot reflects active acquires" `Quick
        test_snapshot_reflects_active_acquires;
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
      test_case "all-busy tier falls through (starvation guard)" `Quick
        test_priority_tier_starvation_guard;
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
    "client_capacity_history", [
      test_case "record + snapshot roundtrip newest-first" `Quick
        test_history_record_snapshot_roundtrip;
      test_case "ring buffer drops oldest when full" `Quick
        test_history_ring_buffer_drops_oldest;
      test_case "snapshot kind filter" `Quick
        test_history_snapshot_kind_filter;
      test_case "try_acquire records events on registered URL" `Quick
        test_history_try_acquire_records_events;
      test_case "record bumps Prometheus counter with label" `Quick
        test_history_prometheus_counter_increments;
    ];
    "strategy_trace", [
      test_case "record + snapshot newest-first" `Quick
        test_trace_record_snapshot_roundtrip;
      test_case "cascade filter scopes events" `Quick
        test_trace_cascade_filter;
      test_case "ring buffer drops oldest" `Quick
        test_trace_ring_drops_oldest;
      test_case "limit clamp" `Quick
        test_trace_limit_clamp;
      test_case "kind_to_string serialisation" `Quick
        test_trace_kind_labels;
      test_case "record bumps Prometheus counter with labels" `Quick
        test_trace_prometheus_counter_increments;
    ];
  ]
