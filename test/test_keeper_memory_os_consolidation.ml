(** Tests for Keeper_memory_os_consolidation — the pure consolidation core (no LLM). *)

module Types = Masc.Keeper_memory_os_types
module Consolidation = Masc.Keeper_memory_os_consolidation

let now = 1_000_000.0

let fact
      ?(category = Types.Fact)
      ?(first_seen = now)
      ?valid_until
      ?last_verified_at
      ?(observed_by = [])
      ?claim_id
      ?(claim_kind = None)
      claim
  =
  let last_verified_at =
    match last_verified_at with
    | Some value -> Some value
    | None -> Some first_seen
  in
  { Types.claim
  ; category
  ; external_ref = None
  ; claim_kind
  ; source = { Types.trace_id = "t"; turn = 1; tool_call_id = None }
  ; observed_by
  ; first_seen
  ; valid_until
  ; last_verified_at
  ; schema_version = Types.schema_version
  ; claim_id
  }
;;

let claims facts = List.map (fun f -> f.Types.claim) facts |> List.sort String.compare

(* A two-member group collapses into one consolidated claim; provenance is the
   earliest member's, first_seen is the min, observed_by is the union, and
   verification age is preserved from the newest member verification. *)
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
      "newest verification preserved"
      (Some 200.0)
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

let test_apply_rejects_category_downgrade () =
  let facts =
    [ fact ~category:Types.Lesson "Timeout failures need bounded retries"
    ; fact ~category:Types.Fact "The retry loop timed out under load"
    ]
  in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "Retry loops can time out under load"
          ; category = Types.Fact
          }
        ]
    ; drop_indices = []
    }
  in
  Alcotest.(check (list string))
    "downgraded group is skipped"
    [ "The retry loop timed out under load"; "Timeout failures need bounded retries" ]
    (claims (Consolidation.apply_plan ~now ~facts plan))
;;

let test_apply_rejects_category_upgrade () =
  let facts =
    [ fact ~category:Types.Fact "The retry loop timed out under load"
    ; fact ~category:Types.Fact "Retry loops can time out under load"
    ]
  in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "Retry timeout failures imply a durable lesson"
          ; category = Types.Lesson
          }
        ]
    ; drop_indices = []
    }
  in
  Alcotest.(check (list string))
    "upgraded group is skipped"
    [ "Retry loops can time out under load"; "The retry loop timed out under load" ]
    (claims (Consolidation.apply_plan ~now ~facts plan))
;;

(* RFC-0285 §3.1: [group_preserves_category] is orthogonal to [claim_kind], so the
   LLM can group a Self_observation with a durable claim of the SAME category. The
   merge must be refused (both kept) — otherwise [earliest.claim_kind] would, by
   first_seen order, either immortalize the self-observation or expire the durable
   claim. Earliest here is the durable claim; merging would carry [Durable_knowledge]
   and re-immortalize the self-observation echo this RFC exists to stop. *)
let test_apply_rejects_mixed_claim_kind () =
  let facts =
    [ fact
        ~first_seen:100.0
        ~category:Types.Lesson
        ~claim_kind:(Some Types.Durable_knowledge)
        "Bounded retries prevent loop starvation"
    ; fact
        ~first_seen:200.0
        ~category:Types.Lesson
        ~claim_kind:(Some Types.Self_observation)
        "the agent is stuck in a retry loop this turn"
    ]
  in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "retry loops need bounds"
          ; category = Types.Lesson
          }
        ]
    ; drop_indices = []
    }
  in
  Alcotest.(check (list string))
    "mixed-claim_kind group is skipped; both facts survive unchanged"
    [ "Bounded retries prevent loop starvation"
    ; "the agent is stuck in a retry loop this turn"
    ]
    (claims (Consolidation.apply_plan ~now ~facts plan))
;;

(* RFC-0285 §3.3/§4 re-mint at the consolidation boundary: a homogeneous
   Self_observation group DOES merge, the consolidated fact stays [Self_observation],
   and its horizon is the member-min — a reworded re-mint never extends the horizon
   past the earliest member's anchor. *)
let test_apply_self_observation_group_inherits_min_horizon () =
  let facts =
    [ fact
        ~first_seen:100.0
        ~valid_until:1_700_000.0
        ~category:Types.Lesson
        ~claim_kind:(Some Types.Self_observation)
        "the agent is looping"
    ; fact
        ~first_seen:200.0
        ~valid_until:2_000_000.0
        ~category:Types.Lesson
        ~claim_kind:(Some Types.Self_observation)
        "the agent remains in a loop"
    ]
  in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "the agent is stuck looping"
          ; category = Types.Lesson
          }
        ]
    ; drop_indices = []
    }
  in
  match Consolidation.apply_plan ~now ~facts plan with
  | [ merged ] ->
    Alcotest.(check bool)
      "consolidated fact stays a self-observation"
      true
      (merged.Types.claim_kind = Some Types.Self_observation);
    Alcotest.(check (option (float 1e-9)))
      "horizon is the member-min anchor, not extended"
      (Some 1_700_000.0)
      merged.Types.valid_until
  | other -> Alcotest.failf "expected 1 merged fact, got %d" (List.length other)
;;

let test_apply_external_state_group_inherits_effective_horizon () =
  let first_seen = now -. 1000.0 in
  let stored_horizon = now +. 2_000.0 in
  let facts =
    [ fact
        ~first_seen
        ~category:Types.Blocker
        ~claim_kind:(Some Types.External_state)
        "task-1578 is blocked by missing mapping"
    ; fact
        ~first_seen:(now -. 500.0)
        ~valid_until:stored_horizon
        ~category:Types.Blocker
        ~claim_kind:(Some Types.External_state)
        "task-1578 still has missing mapping"
    ]
  in
  let expected =
    let compatibility_horizon =
      Types.external_state_valid_until_from_first_seen ~first_seen
    in
    Some (Float.min compatibility_horizon stored_horizon)
  in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "task-1578 is blocked by missing mapping"
          ; category = Types.Blocker
          }
        ]
    ; drop_indices = []
    }
  in
  match Consolidation.apply_plan ~now ~facts plan with
  | [ merged ] ->
    Alcotest.(check bool)
      "consolidated fact stays External_state"
      true
      (merged.Types.claim_kind = Some Types.External_state);
    Alcotest.(check (option (float 1e-9)))
      "External_state consolidated horizon uses member-min effective horizon"
      expected
      merged.Types.valid_until
  | other -> Alcotest.failf "expected 1 merged fact, got %d" (List.length other)
;;

let test_apply_preserves_ephemeral_expiry_and_verification_age () =
  let facts =
    [ fact
        ~category:Types.Ephemeral
        ~valid_until:1_100.0
        ~last_verified_at:900.0
        "checkpoint saved"
    ; fact
        ~category:Types.Ephemeral
        ~valid_until:1_200.0
        ~last_verified_at:950.0
        "continuation checkpoint saved"
    ]
  in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "checkpoint saved"
          ; category = Types.Ephemeral
          }
        ]
    ; drop_indices = []
    }
  in
  match Consolidation.apply_plan ~now ~facts plan with
  | [ merged ] ->
    Alcotest.(check (option (float 1e-9)))
      "earliest ephemeral expiry preserved"
      (Some 1_100.0)
      merged.Types.valid_until;
    Alcotest.(check (option (float 1e-9)))
      "newest verification preserved"
      (Some 950.0)
      merged.Types.last_verified_at
  | other -> Alcotest.failf "expected 1 merged fact, got %d" (List.length other)
;;

let test_apply_preserves_shared_claim_id () =
  let facts =
    [ fact ~claim_id:"PR #123 Open" "PR #123 is open"
    ; fact ~claim_id:"pr-123-open" "pull request 123 remains open"
    ]
  in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "PR #123 remains open"
          ; category = Types.Fact
          }
        ]
    ; drop_indices = []
    }
  in
  match Consolidation.apply_plan ~now ~facts plan with
  | [ merged ] ->
    Alcotest.(check (option string))
      "shared claim_id preserved canonically"
      (Some "pr-123-open")
      merged.Types.claim_id;
    Alcotest.(check string)
      "consolidated row keeps id identity"
      "id:pr-123-open"
      (Types.claim_identity merged)
  | other -> Alcotest.failf "expected 1 merged fact, got %d" (List.length other)
;;

let test_apply_drops_conflicting_claim_ids () =
  let facts =
    [ fact ~claim_id:"pr-123-open" "PR #123 is open"
    ; fact ~claim_id:"pr-123-merged" "PR #123 was merged"
    ]
  in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "PR #123 changed status"
          ; category = Types.Fact
          }
        ]
    ; drop_indices = []
    }
  in
  match Consolidation.apply_plan ~now ~facts plan with
  | [ merged ] ->
    Alcotest.(check (option string))
      "conflicting claim_ids are not invented into a new id"
      None
      merged.Types.claim_id
  | other -> Alcotest.failf "expected 1 merged fact, got %d" (List.length other)
;;

let test_render_numbered_facts_keeps_one_fact_per_line () =
  let rendered =
    Consolidation.render_numbered_facts
      [ fact "line one\nline two"; fact "carriage\rreturn" ]
  in
  Alcotest.(check (list string))
    "one numbered fact per line"
    [ "0: [fact] line one line two"; "1: [fact] carriage return" ]
    (String.split_on_char '\n' rendered)
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

let test_parse_rejects_wrapped_json () =
  let json =
    {|{"groups":[{"member_indices":[0,1],"consolidated_claim":"merged","category":"fact"}],"drop_indices":[]}|}
  in
  [ "fenced", Printf.sprintf "```json\n%s\n```" json
  ; "prefixed", Printf.sprintf "Here is the plan:\n%s" json
  ; "suffixed", Printf.sprintf "%s\nDone." json
  ; "multiple objects", Printf.sprintf "%s\n%s" json json
  ; "thinking leak", Printf.sprintf "<think>merge these</think>\n%s" json
  ]
  |> List.iter (fun (label, raw) ->
    match Consolidation.plan_of_string raw with
    | None -> ()
    | Some _ -> Alcotest.failf "%s wrapped plan should be rejected" label)
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
  Alcotest.(check bool) "non-JSON yields None" true (Consolidation.plan_of_string "not json {{{" = None);
  Alcotest.(check bool)
    "JSON string yields None"
    true
    (Consolidation.plan_of_string {|"not an object"|} = None);
  Alcotest.(check bool) "JSON array yields None" true (Consolidation.plan_of_string "[]" = None)
;;

let test_parse_result_reports_rejection_reason () =
  Alcotest.(check bool)
    "non-JSON result"
    true
    (match Consolidation.plan_result_of_string "not json {{{" with
     | Error Consolidation.Non_json -> true
     | Ok _
     | Error Consolidation.Non_object_json -> false);
  Alcotest.(check bool)
    "non-object result"
    true
    (match Consolidation.plan_result_of_string {|"not an object"|} with
     | Error Consolidation.Non_object_json -> true
     | Ok _
     | Error Consolidation.Non_json -> false)
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
	        ; Alcotest.test_case "rejects category downgrade" `Quick test_apply_rejects_category_downgrade
        ; Alcotest.test_case "rejects category upgrade" `Quick test_apply_rejects_category_upgrade
        ; Alcotest.test_case "rejects mixed claim_kind" `Quick test_apply_rejects_mixed_claim_kind
        ; Alcotest.test_case
            "self-observation group inherits min horizon"
            `Quick
            test_apply_self_observation_group_inherits_min_horizon
        ; Alcotest.test_case
            "external-state group inherits effective horizon"
            `Quick
            test_apply_external_state_group_inherits_effective_horizon
        ; Alcotest.test_case
            "preserves ephemeral expiry and verification age"
            `Quick
            test_apply_preserves_ephemeral_expiry_and_verification_age
        ; Alcotest.test_case
            "preserves a shared claim_id"
            `Quick
            test_apply_preserves_shared_claim_id
        ; Alcotest.test_case
            "drops conflicting claim_ids"
            `Quick
            test_apply_drops_conflicting_claim_ids
	        ] )
	    ; ( "parse"
	      , [ Alcotest.test_case "parses a plan" `Quick test_parse_plan_json
	        ; Alcotest.test_case "rejects fractional indices" `Quick test_parse_rejects_fractional_indices
        ; Alcotest.test_case "rejects wrapped JSON" `Quick test_parse_rejects_wrapped_json
        ; Alcotest.test_case "degrades a garbled group" `Quick test_parse_degrades_garbled_group
        ; Alcotest.test_case "non-JSON is None" `Quick test_parse_non_json_is_none
        ; Alcotest.test_case
            "result reports rejection reason"
            `Quick
            test_parse_result_reports_rejection_reason
        ] )
    ; ( "render"
      , [ Alcotest.test_case
            "keeps one fact per prompt line"
            `Quick
            test_render_numbered_facts_keeps_one_fact_per_line
        ] )
	    ]
;;
