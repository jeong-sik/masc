(** RFC-0259 P7 — typed decay for [External_state] claims.

    [External_state] claims describe volatile external reality (task status,
    blockers, PR state). Before P7 they fell into the never-expire arm of
    [fact_valid_until] (same as [Durable_knowledge]) AND [reobserve_fact]
    advanced their [last_verified_at] on mere LLM re-assertion, so a claim about
    a now-cancelled task was re-injected into recall indefinitely (observed:
    keeper garnet, 110/260 facts stale about a cancelled task, last_verified =
    now). P7 gives [External_state] a finite birth-set horizon keyed on the
    producer-emitted [claim_kind] tag (not on claim prose), and stops
    re-observation from extending it. *)

open Alcotest

module Types = Masc.Keeper_memory_os_types
module Policy = Masc.Keeper_memory_os_policy

let now = 1_000_000.0

let fact ~claim_kind ~category ?(valid_until = None)
    ?(last_verified_at = Some (now -. 60.0)) () : Types.fact =
  { Types.claim = "task-1578 is blocked by a circular mapping dependency"
  ; Types.category
  ; Types.external_ref = None
  ; Types.claim_kind
  ; Types.source = { Types.trace_id = "trace-x"; Types.turn = 1; Types.tool_call_id = None }
  ; Types.observed_by = []
  ; Types.first_seen = now -. 60.0
  ; Types.valid_until
  ; Types.last_verified_at
  ; Types.schema_version = Types.schema_version
  ; Types.claim_id = None
  }
;;

(* 1. External_state gets a finite horizon for EVERY category (never None) —
   this is the loop-breaker: a stale external claim can no longer be immortal. *)
let test_external_state_valid_until_is_finite () =
  List.iter
    (fun category ->
      match
        Types.fact_valid_until ~now ~external_ref:None
          ~claim_kind:(Some Types.External_state) category
      with
      | Some vu ->
        check (float 0.001) "External_state horizon = now + ttl"
          (now +. Types.external_state_ttl_seconds) vu
      | None -> fail "External_state must have a finite valid_until regardless of category")
    [ Types.Fact; Types.Constraint; Types.Blocker; Types.Goal; Types.Lesson ]
;;

(* 2. The other claim_kinds are unchanged: Durable_knowledge/None stay immortal
   under non-Ephemeral categories; Self_observation keeps its own TTL. *)
let test_other_claim_kinds_unchanged () =
  check (option (float 0.001)) "Durable_knowledge under Fact still never-expires" None
    (Types.fact_valid_until ~now ~external_ref:None
       ~claim_kind:(Some Types.Durable_knowledge) Types.Fact);
  check (option (float 0.001)) "None claim_kind under Fact still never-expires" None
    (Types.fact_valid_until ~now ~external_ref:None ~claim_kind:None Types.Fact);
  match
    Types.fact_valid_until ~now ~external_ref:None
      ~claim_kind:(Some Types.Self_observation) Types.Fact
  with
  | Some vu ->
    check (float 0.001) "Self_observation TTL unchanged"
      (now +. Types.self_observation_ttl_seconds) vu
  | None -> fail "Self_observation must keep its finite TTL"
;;

(* 3. An External_state fact past its horizon is no longer current, so recall
   ([fact_is_current] gate) drops it and the perseveration loop ends. *)
let test_external_state_expires_past_horizon () =
  let valid_until = Some (now +. Types.external_state_ttl_seconds) in
  let f = fact ~claim_kind:(Some Types.External_state) ~category:Types.Blocker ~valid_until () in
  check bool "current before horizon" true (Types.fact_is_current ~now f);
  check bool "expired after horizon" false
    (Types.fact_is_current ~now:(now +. Types.external_state_ttl_seconds +. 1.0) f)
;;

(* 4. Legacy External_state rows written before P7 have [valid_until = None].
   They must still decay from their original [first_seen] anchor, otherwise the
   exact stale garnet rows that motivated P7 remain immortal. *)
let test_legacy_external_state_without_valid_until_expires_from_first_seen () =
  let first_seen = now -. Types.external_state_ttl_seconds -. 1.0 in
  let legacy =
    { (fact ~claim_kind:(Some Types.External_state) ~category:Types.Blocker ())
      with
      Types.first_seen
    ; valid_until = None
    }
  in
  check (option (float 0.001)) "legacy effective horizon"
    (Some (first_seen +. Types.external_state_ttl_seconds))
    (Types.fact_effective_valid_until legacy);
  check bool "legacy row is expired by effective horizon" false
    (Types.fact_is_current ~now legacy)
;;

(* 5. Re-observing an External_state claim must NOT advance last_verified_at
   (mirrors Self_observation): repetition cannot keep a stale claim "fresh" or
   extend its lifetime. It should materialize the compatibility-derived horizon
   for legacy rows so the next write no longer stores an immortal row.
   Durable_knowledge still advances (contrast). *)
let test_reobserve_external_state_does_not_bump () =
  let stale_lv = Some (now -. 1000.0) in
  let existing =
    fact ~claim_kind:(Some Types.External_state) ~category:Types.Blocker
      ~last_verified_at:stale_lv ()
  in
  let incoming = fact ~claim_kind:(Some Types.External_state) ~category:Types.Blocker () in
  let merged = Policy.reobserve_fact ~now ~existing ~incoming in
  check (option (float 0.001))
    "External_state last_verified_at unchanged by re-observation" stale_lv
    merged.Types.last_verified_at;
  check (option (float 0.001))
    "External_state legacy horizon materialized on re-observation"
    (Types.fact_effective_valid_until existing)
    merged.Types.valid_until;
  let dk =
    fact ~claim_kind:(Some Types.Durable_knowledge) ~category:Types.Lesson
      ~last_verified_at:stale_lv ()
  in
  let dk_merged = Policy.reobserve_fact ~now ~existing:dk ~incoming:dk in
  check (option (float 0.001))
    "Durable_knowledge last_verified_at advances to now" (Some now)
    dk_merged.Types.last_verified_at
;;

let () =
  run "keeper_memory_os_external_state_decay"
    [ ( "P7 typed decay"
      , [ test_case "External_state valid_until is finite for every category" `Quick
            test_external_state_valid_until_is_finite
        ; test_case "Durable/None/Self retention unchanged" `Quick
            test_other_claim_kinds_unchanged
        ; test_case "External_state expires past its horizon" `Quick
            test_external_state_expires_past_horizon
        ; test_case "legacy External_state valid_until=None expires from first_seen" `Quick
            test_legacy_external_state_without_valid_until_expires_from_first_seen
        ; test_case "re-observing External_state does not bump last_verified_at" `Quick
            test_reobserve_external_state_does_not_bump
        ] )
    ]
;;
