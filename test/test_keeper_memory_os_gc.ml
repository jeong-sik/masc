(** Unit tests for Keeper_memory_os_gc — deterministic garbage collection. *)

open Keeper_memory_os_gc
open Keeper_memory_os_types
open Keeper_memory_os_policy

(* --- Helpers --- *)

let now = 1_700_000_000.0

let fresh_fact ?(valid_until = None) ~last_accessed claim confidence =
  { claim
  ; confidence
  ; created_at = now -. 1000.0
  ; last_accessed
  ; access_count = 1
  ; source = "test"
  ; category = "test"
  ; valid_until
  }

(* --- TTL expired --- *)

let test_ttl_expired () =
  (* Fact with expired TTL *)
  let f = fresh_fact ~valid_until:(Some (now -. 10.0)) ~last_accessed:now "old" 0.9 in
  Alcotest.(check bool "expired" true (ttl_expired ~now f));
  (* Fact with future TTL *)
  let f2 = fresh_fact ~valid_until:(Some (now +. 1000.0)) ~last_accessed:now "fresh" 0.9 in
  Alcotest.(check bool "not expired" false (ttl_expired ~now f2));
  (* Fact with no TTL (None) *)
  let f3 = fresh_fact ~last_accessed:now "no-ttl" 0.9 in
  Alcotest.(check bool "no ttl" false (ttl_expired ~now f3));
  (* Fact with TTL exactly at now (boundary: not expired) *)
  let f4 = fresh_fact ~valid_until:(Some now) ~last_accessed:now "boundary" 0.9 in
  Alcotest.(check bool "boundary" false (ttl_expired ~now f4))

(* --- should_keep --- *)

let test_should_keep () =
  let kv = (fresh_fact ~last_accessed:now "kv" 0.9, 0.85, KeepVerbatim) in
  Alcotest.(check bool "keep verbatim" true (should_keep kv));
  let sm = (fresh_fact ~last_accessed:now "sm" 0.6, 0.6, Summarize) in
  Alcotest.(check bool "keep summarize" true (should_keep sm));
  let ro = (fresh_fact ~last_accessed:now "ro" 0.2, 0.35, ReferenceOnly) in
  Alcotest.(check bool "drop reference" false (should_keep ro));
  let dc = (fresh_fact ~last_accessed:now "dc" 0.1, 0.1, Discard) in
  Alcotest.(check bool "drop discard" false (should_keep dc))

(* --- dedup_by_claim --- *)

let test_dedup_same_claim () =
  let f1 = (fresh_fact ~last_accessed:now "Same Claim" 0.9, 0.85, KeepVerbatim) in
  let f2 = (fresh_fact ~last_accessed:now "Same Claim" 0.5, 0.4, Summarize) in
  let f3 = (fresh_fact ~last_accessed:now "Same Claim" 0.7, 0.6, Summarize) in
  let result = dedup_by_claim [f1; f2; f3] in
  Alcotest.(check int "keeps one" 1 (List.length result));
  (* Should keep highest-scored *)
  let (best_f, best_score, _) = List.hd result in
  Alcotest.(check float "best score" ~epsilon:0.001 0.85 best_score)

let test_dedup_different_claims () =
  let f1 = (fresh_fact ~last_accessed:now "claim A" 0.9, 0.85, KeepVerbatim) in
  let f2 = (fresh_fact ~last_accessed:now "claim B" 0.5, 0.4, Summarize) in
  let f3 = (fresh_fact ~last_accessed:now "claim C" 0.7, 0.6, Summarize) in
  let result = dedup_by_claim [f1; f2; f3] in
  Alcotest.(check int "keeps all three" 3 (List.length result))

let test_dedup_case_insensitive () =
  let f1 = (fresh_fact ~last_accessed:now "UPPER Claim" 0.9, 0.85, KeepVerbatim) in
  let f2 = (fresh_fact ~last_accessed:now "upper claim" 0.5, 0.4, Summarize) in
  let result = dedup_by_claim [f1; f2] in
  Alcotest.(check int "deduplicates case-insensitive" 1 (List.length result))

let test_dedup_empty () =
  let result = dedup_by_claim [] in
  Alcotest.(check int "empty list" 0 (List.length result))

(* --- score_and_verdict --- *)

let test_score_and_verdict () =
  let f = fresh_fact ~last_accessed:now "high" 0.9 in
  let (_, score, verdict) = score_and_verdict ~now f in
  Alcotest.(check bool "high score → KeepVerbatim" true (score > 0.8));
  let _match_keep =
    match verdict with KeepVerbatim -> true | _ -> false
  in
  Alcotest.(check bool "verdict is KeepVerbatim" true _match_keep);
  (* Low-confidence old fact *)
  let f2 = fresh_fact ~last_accessed:(now -. 1_000_000.0) "low" 0.1 in
  let (_, score2, verdict2) = score_and_verdict ~now f2 in
  Alcotest.(check bool "low score → Discard range" true (score2 < 0.3));
  let _match_discard =
    match verdict2 with Discard -> true | _ -> false
  in
  Alcotest.(check bool "verdict is Discard" true _match_discard)

(* --- empty_report --- *)

let test_empty_report () =
  Alcotest.(check int "total" 0 empty_report.total_input);
  Alcotest.(check int "ttl" 0 empty_report.ttl_expired);
  Alcotest.(check int "verdict" 0 empty_report.verdict_discarded);
  Alcotest.(check int "dedup" 0 empty_report.dedup_removed);
  Alcotest.(check int "written" 0 empty_report.written)

(* --- Test suite --- *)

let () =
  Alcotest.run "Keeper_memory_os_gc" [
    Alcotest.test_case "ttl_expired" `Quick test_ttl_expired;
    Alcotest.test_case "should_keep" `Quick test_should_keep;
    Alcotest.test_case "dedup same claim" `Quick test_dedup_same_claim;
    Alcotest.test_case "dedup different claims" `Quick test_dedup_different_claims;
    Alcotest.test_case "dedup case insensitive" `Quick test_dedup_case_insensitive;
    Alcotest.test_case "dedup empty" `Quick test_dedup_empty;
    Alcotest.test_case "score_and_verdict" `Quick test_score_and_verdict;
    Alcotest.test_case "empty_report" `Quick test_empty_report;
  ]