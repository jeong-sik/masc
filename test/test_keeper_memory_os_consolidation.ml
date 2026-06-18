(** Tests for Keeper_memory_os_consolidation — the pure consolidation core (no LLM). *)

module Types = Masc.Keeper_memory_os_types
module Consolidation = Masc.Keeper_memory_os_consolidation

let now = 1_000_000.0

let fact ?(category = Types.Fact) ?(first_seen = now) ?(observed_by = []) claim =
  { Types.claim
  ; category
  ; source = { Types.trace_id = "t"; turn = 1; tool_call_id = None }
  ; observed_by
  ; first_seen
  ; valid_until = None
  ; last_verified_at = Some first_seen
  ; schema_version = Types.schema_version
  }
;;

let claims facts = List.map (fun f -> f.Types.claim) facts |> List.sort String.compare

(* A two-member group collapses into one consolidated claim; provenance is the
   earliest member's, first_seen is the min, observed_by is the union, and the
   merged fact is re-verified at [now]. *)
let test_apply_merges_group () =
  let facts =
    [ fact ~first_seen:200.0 ~observed_by:[ "alpha" ] "deploy uses blue-green"
    ; fact ~first_seen:100.0 ~observed_by:[ "beta" ] "deployment is blue-green based"
    ]
  in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "deploys via blue-green"
          ; category = Types.Fact
          }
        ]
    ; drop_indices = []
    }
  in
  match Consolidation.apply_plan ~now ~facts plan with
  | [ merged ] ->
    Alcotest.(check string) "consolidated claim" "deploys via blue-green" merged.Types.claim;
    Alcotest.(check (float 1e-9)) "earliest first_seen preserved" 100.0 merged.Types.first_seen;
    Alcotest.(check (list string))
      "observed_by union"
      [ "alpha"; "beta" ]
      merged.Types.observed_by;
    Alcotest.(check (option (float 1e-9)))
      "re-verified at now"
      (Some now)
      merged.Types.last_verified_at
  | other -> Alcotest.failf "expected 1 merged fact, got %d" (List.length other)
;;

(* A fact named in no group and no drop list survives unchanged (conservative). *)
let test_apply_keeps_unreferenced () =
  let facts = [ fact "claim A"; fact "claim B"; fact "claim C" ] in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "A and B merged"
          ; category = Types.Fact
          }
        ]
    ; drop_indices = []
    }
  in
  Alcotest.(check (list string))
    "C survives, A+B merged"
    [ "A and B merged"; "claim C" ]
    (claims (Consolidation.apply_plan ~now ~facts plan))
;;

(* A single-member group is a no-op: the LLM cannot silently reword one fact. *)
let test_apply_single_member_group_is_noop () =
  let facts = [ fact "original wording" ] in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0 ]
          ; consolidated_claim = "reworded"
          ; category = Types.Fact
          }
        ]
    ; drop_indices = []
    }
  in
  Alcotest.(check (list string))
    "single-member group leaves the fact unchanged"
    [ "original wording" ]
    (claims (Consolidation.apply_plan ~now ~facts plan))
;;

(* Out-of-range and duplicate indices are skipped; a group that drops below two
   valid members after filtering is a no-op. *)
let test_apply_skips_bad_indices () =
  let facts = [ fact "only fact" ] in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 0; 5; -1 ]
          ; consolidated_claim = "should not form"
          ; category = Types.Fact
          }
        ]
    ; drop_indices = [ 9 ]
    }
  in
  Alcotest.(check (list string))
    "no merge from one valid index; bad drop ignored"
    [ "only fact" ]
    (claims (Consolidation.apply_plan ~now ~facts plan))
;;

(* Explicitly dropped indices are forgotten; everything else survives. *)
let test_apply_drops_listed () =
  let facts = [ fact "keep me"; fact "obsolete"; fact "keep me too" ] in
  let plan = { Consolidation.groups = []; drop_indices = [ 1 ] } in
  Alcotest.(check (list string))
    "only the listed index is dropped"
    [ "keep me"; "keep me too" ]
    (claims (Consolidation.apply_plan ~now ~facts plan))
;;

(* A fact contested by a group and a drop goes to the group (first claim wins);
   a fact in two groups goes to the first group only. *)
let test_apply_first_group_wins_contested () =
  let facts = [ fact "x"; fact "y"; fact "z" ] in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]; consolidated_claim = "xy"; category = Types.Fact }
        ; { Consolidation.member_indices = [ 1; 2 ]; consolidated_claim = "yz"; category = Types.Fact }
        ]
    ; drop_indices = [ 0 ]
    }
  in
  (* group1 consumes 0,1 -> "xy"; group2 sees only 2 left (1 consumed) -> <2 -> no-op,
     so 2 survives; drop of 0 is ignored (already consumed). *)
  Alcotest.(check (list string))
    "first group wins index 1; index 2 survives"
    [ "xy"; "z" ]
    (claims (Consolidation.apply_plan ~now ~facts plan))
;;

let test_parse_plan_json () =
  let raw =
    {|{"groups":[{"member_indices":[0,2],"consolidated_claim":"merged","category":"lesson"}],"drop_indices":[3]}|}
  in
  match Consolidation.plan_of_string raw with
  | None -> Alcotest.fail "expected the plan to parse"
  | Some plan ->
    Alcotest.(check int) "one group" 1 (List.length plan.Consolidation.groups);
    let g = List.hd plan.Consolidation.groups in
    Alcotest.(check (list int)) "member indices" [ 0; 2 ] g.Consolidation.member_indices;
    Alcotest.(check string) "consolidated claim" "merged" g.Consolidation.consolidated_claim;
    Alcotest.(check bool) "category parsed to Lesson" true (g.Consolidation.category = Types.Lesson);
    Alcotest.(check (list int)) "drop indices" [ 3 ] plan.Consolidation.drop_indices
;;

let test_parse_rejects_fractional_indices () =
  let raw =
    {|{"groups":[{"member_indices":[0,1.5],"consolidated_claim":"merged","category":"fact"}],"drop_indices":[2.1,3]}|}
  in
  match Consolidation.plan_of_string raw with
  | None -> Alcotest.fail "expected the plan to parse"
  | Some plan ->
    let g = List.hd plan.Consolidation.groups in
    Alcotest.(check (list int)) "fractional member ignored" [ 0 ] g.Consolidation.member_indices;
    Alcotest.(check (list int)) "fractional drop ignored" [ 3 ] plan.Consolidation.drop_indices
;;

(* A garbled group is dropped individually; the rest of the plan stands. *)
let test_parse_degrades_garbled_group () =
  let raw =
    {|{"groups":[{"member_indices":[0,1],"consolidated_claim":"ok","category":"fact"},{"consolidated_claim":""}],"drop_indices":[]}|}
  in
  match Consolidation.plan_of_string raw with
  | None -> Alcotest.fail "expected the plan to parse"
  | Some plan -> Alcotest.(check int) "only the valid group survives" 1 (List.length plan.Consolidation.groups)
;;

let test_parse_non_json_is_none () =
  Alcotest.(check bool) "non-JSON yields None" true (Consolidation.plan_of_string "not json {{{" = None)
;;

let () =
  Alcotest.run
    "keeper_memory_os_consolidation"
    [ ( "apply"
      , [ Alcotest.test_case "merges a group" `Quick test_apply_merges_group
        ; Alcotest.test_case "keeps unreferenced facts" `Quick test_apply_keeps_unreferenced
        ; Alcotest.test_case "single-member group is no-op" `Quick test_apply_single_member_group_is_noop
        ; Alcotest.test_case "skips bad indices" `Quick test_apply_skips_bad_indices
        ; Alcotest.test_case "drops listed indices" `Quick test_apply_drops_listed
        ; Alcotest.test_case "first group wins contested fact" `Quick test_apply_first_group_wins_contested
        ] )
    ; ( "parse"
      , [ Alcotest.test_case "parses a plan" `Quick test_parse_plan_json
        ; Alcotest.test_case "rejects fractional indices" `Quick test_parse_rejects_fractional_indices
        ; Alcotest.test_case "degrades a garbled group" `Quick test_parse_degrades_garbled_group
        ; Alcotest.test_case "non-JSON is None" `Quick test_parse_non_json_is_none
        ] )
    ]
;;
