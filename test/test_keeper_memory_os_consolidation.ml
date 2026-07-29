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

(* Most cases assert only the surviving facts; stats-focused cases call
   [Consolidation.apply_plan] directly. *)
let apply_plan_facts ~now ~facts plan = fst (Consolidation.apply_plan ~now ~facts plan)

(* The single surviving fact of a one-group plan, for metadata assertions. *)
let only_fact = function
  | [ f ] -> f
  | other ->
    Alcotest.failf "expected exactly one surviving fact, got %d" (List.length other)
;;

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
          ; claim_kind = None
          }
        ]
    ; drop_indices = []
    }
  in
  match apply_plan_facts ~now ~facts plan with
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
          ; claim_kind = None
          }
        ]
    ; drop_indices = []
    }
  in
  Alcotest.(check (list string))
    "C survives, A+B merged"
    [ "A and B merged"; "claim C" ]
    (claims (apply_plan_facts ~now ~facts plan))
;;

(* A single-member group is a no-op: the LLM cannot silently reword one fact. *)
let test_apply_single_member_group_is_noop () =
  let facts = [ fact "original wording" ] in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0 ]
          ; consolidated_claim = "reworded"
          ; category = Types.Fact
          ; claim_kind = None
          }
        ]
    ; drop_indices = []
    }
  in
  Alcotest.(check (list string))
    "single-member group leaves the fact unchanged"
    [ "original wording" ]
    (claims (apply_plan_facts ~now ~facts plan))
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
          ; claim_kind = None
          }
        ]
    ; drop_indices = [ 9 ]
    }
  in
  Alcotest.(check (list string))
    "no merge from one valid index; bad drop ignored"
    [ "only fact" ]
    (claims (apply_plan_facts ~now ~facts plan))
;;

(* Explicitly dropped indices are forgotten; everything else survives. *)
let test_apply_drops_listed () =
  let facts = [ fact "keep me"; fact "obsolete"; fact "keep me too" ] in
  let plan = { Consolidation.groups = []; drop_indices = [ 1 ] } in
  Alcotest.(check (list string))
    "only the listed index is dropped"
    [ "keep me"; "keep me too" ]
    (claims (apply_plan_facts ~now ~facts plan))
;;

(* A fact contested by a group and a drop goes to the group (first claim wins);
   a fact in two groups goes to the first group only. *)
let test_apply_first_group_wins_contested () =
  let facts = [ fact "x"; fact "y"; fact "z" ] in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]; consolidated_claim = "xy"; category = Types.Fact; claim_kind = None }
        ; { Consolidation.member_indices = [ 1; 2 ]; consolidated_claim = "yz"; category = Types.Fact; claim_kind = None }
        ]
    ; drop_indices = [ 0 ]
    }
  in
  (* group1 consumes 0,1 -> "xy"; group2 sees only 2 left (1 consumed) -> <2 -> no-op,
     so 2 survives; drop of 0 is ignored (already consumed). *)
  Alcotest.(check (list string))
    "first group wins index 1; index 2 survives"
    [ "xy"; "z" ]
    (claims (apply_plan_facts ~now ~facts plan))
;;

let test_apply_accepts_model_category_change () =
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
          ; claim_kind = None
          }
        ]
    ; drop_indices = []
    }
  in
  Alcotest.(check (list string))
    "model-selected category is applied"
    [ "Retry loops can time out under load" ]
    (claims (apply_plan_facts ~now ~facts plan))
;;

let test_apply_accepts_model_category_selection () =
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
          ; claim_kind = None
          }
        ]
    ; drop_indices = []
    }
  in
  Alcotest.(check (list string))
    "model-selected category is applied"
    [ "Retry timeout failures imply a durable lesson" ]
    (claims (apply_plan_facts ~now ~facts plan))
;;

(* RFC-0285 §3.1: category is orthogonal to [claim_kind], so the LLM can group a
   Self_observation with a durable claim of the SAME category. With no stated
   [claim_kind] the plan does not determine the merged row's tag, and the code
   must not pick one: inheriting by first_seen order would either immortalize the
   self-observation or expire the durable claim, and writing [None] would mean
   "producer emitted no tag" — a row the read boundary renders identically to a
   never-tagged one. Refuse instead; the judge can clear this by stating a tag. *)
let test_apply_rejects_undetermined_claim_kind () =
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
          ; claim_kind = None
          }
        ]
    ; drop_indices = []
    }
  in
  Alcotest.(check (list string))
    "undetermined-claim_kind group is skipped; both facts survive unchanged"
    [ "Bounded retries prevent loop starvation"
    ; "the agent is stuck in a retry loop this turn"
    ]
    (claims (apply_plan_facts ~now ~facts plan))
;;

(* The same mixed-kind group merges once the judge states which tag the row it is
   authoring should carry. This is what makes the refusal above satisfiable
   rather than a gate on metadata the judge cannot express. *)
let test_apply_merges_mixed_kind_when_judge_states_tag () =
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
          ; claim_kind = Some Types.Self_observation
          }
        ]
    ; drop_indices = []
    }
  in
  let merged = only_fact (apply_plan_facts ~now ~facts plan) in
  Alcotest.(check string) "the group merges" "retry loops need bounds" merged.Types.claim;
  Alcotest.(check bool)
    "the merged row carries the stated tag, not the earliest member's"
    true
    (merged.Types.claim_kind = Some Types.Self_observation)
;;

(* A stated tag no member carries is accepted, like a model-selected [category]
   (see [test_apply_accepts_model_category_change]). RFC-0285's anti-promotion
   rule is a Tier-2 promotion-call-site concern (§3.5), not a Tier-1 merge one,
   and nothing branches on [claim_kind], so narrowing the judge here would be a
   gate without a harm to prevent. This test pins that the narrowing is absent:
   if someone re-adds it, this fails. *)
let test_apply_accepts_claim_kind_no_member_carries () =
  let facts =
    [ fact ~first_seen:100.0 ~claim_kind:(Some Types.Self_observation) "the agent is idle"
    ; fact ~first_seen:200.0 ~claim_kind:(Some Types.Self_observation) "the agent remains idle"
    ]
  in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "idleness is a durable property of this keeper"
          ; category = Types.Lesson
          ; claim_kind = Some Types.Durable_knowledge
          }
        ]
    ; drop_indices = []
    }
  in
  let _survivors, stats = Consolidation.apply_plan ~now ~facts plan in
  Alcotest.(check int) "the group merges" 1 stats.Consolidation.merged_groups;
  Alcotest.(check int)
    "no kind rejection: a stated tag is not narrowed to the members'"
    0
    stats.Consolidation.rejected_kind_mismatch;
  let merged = only_fact (apply_plan_facts ~now ~facts plan) in
  Alcotest.(check bool)
    "the merged row carries the stated tag"
    true
    (merged.Types.claim_kind = Some Types.Durable_knowledge)
;;

let test_apply_merges_different_explicit_validity () =
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
          ; claim_kind = None
          }
        ]
    ; drop_indices = []
    }
  in
  let merged = only_fact (apply_plan_facts ~now ~facts plan) in
  Alcotest.(check string)
    "different explicit bounds still merge"
    "the agent is stuck looping"
    merged.Types.claim;
  Alcotest.(check (option (float 0.001)))
    "merged horizon is the earliest member's"
    (Some 1_700_000.0)
    merged.Types.valid_until;
  Alcotest.(check bool)
    "unanimous claim_kind survives the merge"
    true
    (merged.Types.claim_kind = Some Types.Self_observation)
;;

let test_apply_merges_absent_vs_explicit_validity () =
  let stored_horizon = now +. 2_000.0 in
  let facts =
    [ fact
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
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "task-1578 is blocked by missing mapping"
          ; category = Types.Blocker
          ; claim_kind = None
          }
        ]
    ; drop_indices = []
    }
  in
  let merged = only_fact (apply_plan_facts ~now ~facts plan) in
  Alcotest.(check (option (float 0.001)))
    "no-expiry is the identity: the explicit horizon wins"
    (Some stored_horizon)
    merged.Types.valid_until
;;

let test_apply_merges_rows_with_different_validity () =
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
          ; claim_kind = None
          }
        ]
    ; drop_indices = []
    }
  in
  let merged = only_fact (apply_plan_facts ~now ~facts plan) in
  Alcotest.(check (option (float 0.001)))
    "merged horizon is the earliest of two expiries"
    (Some 1_100.0)
    merged.Types.valid_until;
  Alcotest.(check bool)
    "untagged members produce an untagged merge"
    true
    (merged.Types.claim_kind = None)
;;

(* The meet is order-independent and takes the true minimum, not the first
   member's. Written with the minimum LAST so that replacing Float.min with
   "keep the accumulator" fails here — every other two-Some fixture happens to
   put its minimum at index 0. *)
let test_apply_merge_meet_takes_the_minimum_not_the_first () =
  let facts =
    [ fact ~valid_until:(now +. 9_000.0) "the deploy is blocked"
    ; fact ~valid_until:(now +. 100.0) "the deploy remains blocked"
    ]
  in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "the deploy is blocked"
          ; category = Types.Blocker
          ; claim_kind = None
          }
        ]
    ; drop_indices = []
    }
  in
  let merged = only_fact (apply_plan_facts ~now ~facts plan) in
  Alcotest.(check (option (float 0.001)))
    "the later member's earlier horizon wins"
    (Some (now +. 100.0))
    merged.Types.valid_until;
  Alcotest.(check bool)
    "and the merged row is current"
    true
    (Types.fact_is_current ~now merged)
;;

(* Regression for the live defect: sangsu carried 20 self_observation rows all
   restating one idle loop, each with a distinct write-time [valid_until]. The
   removed exact-equality gate made this group unmergeable by construction, so
   [apply_plan] returned the input untouched on every tick for weeks. *)
let test_apply_merges_distinct_write_instants () =
  let facts =
    List.init 20 (fun i ->
      let offset = float_of_int i in
      fact
        ~first_seen:(now +. offset)
        ~valid_until:(now +. 86_400.0 +. offset)
        ~category:Types.Ephemeral
        ~claim_kind:(Some Types.Self_observation)
        (Printf.sprintf "keeper is idle-looping with no new signals (episode %d)" i))
  in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = List.init 20 Fun.id
          ; consolidated_claim = "keeper has been idle-looping with no new signals"
          ; category = Types.Ephemeral
          ; claim_kind = None
          }
        ]
    ; drop_indices = []
    }
  in
  let survivors, stats = Consolidation.apply_plan ~now ~facts plan in
  Alcotest.(check int) "twenty near-duplicates collapse to one" 1 (List.length survivors);
  Alcotest.(check int) "one merged group" 1 stats.Consolidation.merged_groups;
  Alcotest.(check int) "nothing rejected" 0 stats.Consolidation.rejected_too_few_members;
  Alcotest.(check (option (float 0.001)))
    "merged horizon is the earliest write instant's"
    (Some (now +. 86_400.0))
    (only_fact survivors).Types.valid_until
;;

let test_apply_preserves_shared_claim_id () =
  let facts =
    [ fact ~claim_id:"pr-123-open" "PR #123 is open"
    ; fact ~claim_id:"pr-123-open" "pull request 123 remains open"
    ]
  in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "PR #123 remains open"
          ; category = Types.Fact
          ; claim_kind = None
          }
        ]
    ; drop_indices = []
    }
  in
  match apply_plan_facts ~now ~facts plan with
  | [ merged ] ->
    Alcotest.(check (option string))
      "shared claim_id preserved exactly"
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
          ; claim_kind = None
          }
        ]
    ; drop_indices = []
    }
  in
  match apply_plan_facts ~now ~facts plan with
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
    [ "0: [fact] (kind=untagged) line one line two"
    ; "1: [fact] (kind=untagged) carriage return"
    ]
    (String.split_on_char '\n' rendered)
;;

(* The judge must see every field the apply gate compares (claim_kind and
   valid_until) — hiding them made every gate rejection a blind coin flip. *)
let test_render_numbered_facts_shows_gate_fields () =
  let rendered =
    Consolidation.render_numbered_facts
      [ fact ~claim_kind:(Some Types.External_state) ~valid_until:1_800_000.0 "PR open"
      ; fact "untagged claim"
      ]
  in
  let lines = String.split_on_char '\n' rendered in
  (match lines with
   | [ first; second ] ->
     Alcotest.(check bool)
       "tagged line carries kind and until"
       true
       (let has needle hay =
          let nlen = String.length needle in
          let hlen = String.length hay in
          let rec scan i = i + nlen <= hlen && (String.sub hay i nlen = needle || scan (i + 1)) in
          scan 0
        in
        has "kind=external_state" first && has "until=" first);
     Alcotest.(check string)
       "untagged line names the absence"
       "1: [fact] (kind=untagged) untagged claim"
       second
   | other -> Alcotest.failf "expected 2 lines, got %d" (List.length other))
;;

(* Structural rejection is typed and counted: 'the judge proposed no merges'
   and 'every merge was rejected' must not collapse into one silent outcome. *)
let test_apply_stats_count_rejections () =
  let facts =
    [ fact ~claim_kind:(Some Types.Durable_knowledge) "durable rule"
    ; fact ~claim_kind:(Some Types.Self_observation) "transient state"
    ; fact "dup A"
    ; fact "dup A reworded"
    ]
  in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "mixed kinds"
          ; category = Types.Fact
          ; claim_kind = None
          }
        ; { Consolidation.member_indices = [ 2; 3 ]
          ; consolidated_claim = "dup A"
          ; category = Types.Fact
          ; claim_kind = None
          }
        ; { Consolidation.member_indices = [ 2 ]
          ; consolidated_claim = "already consumed"
          ; category = Types.Fact
          ; claim_kind = None
          }
        ]
    ; drop_indices = []
    }
  in
  let _survivors, stats = Consolidation.apply_plan ~now ~facts plan in
  Alcotest.(check int) "one merged group" 1 stats.Consolidation.merged_groups;
  Alcotest.(check int)
    "one kind-mismatch rejection"
    1
    stats.Consolidation.rejected_kind_mismatch;
  Alcotest.(check int)
    "consumed/short group counted as too few members"
    1
    stats.Consolidation.rejected_too_few_members;
  Alcotest.(check int) "no drops" 0 stats.Consolidation.dropped
;;

(* The ordinary contested-duplicate plan: the first group consumes a fact a
   later group also references, leaving that later group below two free members.
   It is expected behavior, so it stays at info — the cry-wolf case the
   adversarial review of PR #25522 flagged. *)
let test_first_group_wins_lands_in_too_few_bucket () =
  let facts = [ fact "x"; fact "y"; fact "z" ] in
  let plan =
    { Consolidation.groups =
        [ { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "xy"
          ; category = Types.Fact
          ; claim_kind = None
          }
        ; { Consolidation.member_indices = [ 1; 2 ]
          ; consolidated_claim = "yz"
          ; category = Types.Fact
          ; claim_kind = None
          }
        ]
    ; drop_indices = []
    }
  in
  let _survivors, stats = Consolidation.apply_plan ~now ~facts plan in
  Alcotest.(check int)
    "later overlapping group lands in the too-few bucket"
    1
    stats.Consolidation.rejected_too_few_members;
  Alcotest.(check int)
    "an ordinary contested plan raises no kind-gate rejection"
    0
    stats.Consolidation.rejected_kind_mismatch
;;

(* The wire path for the judge-stated tag. Without this, a key or token rename
   silently reverts the feature to "never stated" and every other test passes. *)
let test_parse_plan_claim_kind_wire () =
  let parse raw =
    match Consolidation.plan_of_string raw with
    | Some { Consolidation.groups = [ g ]; _ } -> g.Consolidation.claim_kind
    | _ -> Alcotest.failf "expected exactly one group from %s" raw
  in
  let group extra =
    Printf.sprintf
      {|{"groups":[{"member_indices":[0,1],"consolidated_claim":"c","category":"fact"%s}],"drop_indices":[]}|}
      extra
  in
  Alcotest.(check bool)
    "a stated token round-trips to its variant"
    true
    (parse (group {|,"claim_kind":"self_observation"|}) = Some Types.Self_observation);
  Alcotest.(check bool)
    "an absent field is not stated"
    true
    (parse (group "") = None);
  Alcotest.(check bool)
    "an explicit null is not stated"
    true
    (parse (group {|,"claim_kind":null|}) = None);
  Alcotest.(check bool)
    "a misspelled token degrades to not stated rather than dropping the group"
    true
    (parse (group {|,"claim_kind":"durable"|}) = None);
  Alcotest.(check bool)
    "the display word 'untagged' is not a wire token"
    true
    (parse (group {|,"claim_kind":"untagged"|}) = None);
  Alcotest.(check bool)
    "diagnostic is withheld from provider surfaces"
    true
    (parse (group {|,"claim_kind":"diagnostic"|}) = None)
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
	        ; Alcotest.test_case "accepts model category change" `Quick test_apply_accepts_model_category_change
	        ; Alcotest.test_case "accepts model category selection" `Quick test_apply_accepts_model_category_selection
        ; Alcotest.test_case
            "rejects undetermined claim_kind"
            `Quick
            test_apply_rejects_undetermined_claim_kind
        ; Alcotest.test_case
            "merges mixed kinds when the judge states the tag"
            `Quick
            test_apply_merges_mixed_kind_when_judge_states_tag
        ; Alcotest.test_case
            "accepts a claim_kind no member carries"
            `Quick
            test_apply_accepts_claim_kind_no_member_carries
        ; Alcotest.test_case
            "different explicit validity merges at the earliest horizon"
            `Quick
            test_apply_merges_different_explicit_validity
        ; Alcotest.test_case
            "absent validity is the merge identity"
            `Quick
            test_apply_merges_absent_vs_explicit_validity
        ; Alcotest.test_case
            "different validity values merge at the earliest"
            `Quick
            test_apply_merges_rows_with_different_validity
        ; Alcotest.test_case
            "distinct write instants still merge"
            `Quick
            test_apply_merges_distinct_write_instants
        ; Alcotest.test_case
            "the meet takes the minimum, not the first member"
            `Quick
            test_apply_merge_meet_takes_the_minimum_not_the_first
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
        ; Alcotest.test_case
            "parses the judge-stated claim_kind"
            `Quick
            test_parse_plan_claim_kind_wire
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
        ; Alcotest.test_case
            "shows kind and until to the judge"
            `Quick
            test_render_numbered_facts_shows_gate_fields
        ; Alcotest.test_case
            "apply stats count rejections"
            `Quick
            test_apply_stats_count_rejections
        ; Alcotest.test_case
            "first-group-wins lands in the too-few bucket"
            `Quick
            test_first_group_wins_lands_in_too_few_bucket
        ] )
    ; ( "explicit_validity"
      , [ Alcotest.test_case "old unbounded fact remains eligible" `Quick
            (fun () ->
               let old =
                 { (fact ~first_seen:(now -. 1_000_000.0) "old") with
                   Types.last_verified_at = None
                 }
               in
               Alcotest.(check bool) "current" true (Types.fact_is_current ~now old))
        ; Alcotest.test_case "explicitly expired fact is ineligible" `Quick
            (fun () ->
               let expired = fact ~valid_until:(now -. 1.0) "expired" in
               Alcotest.(check bool)
                 "expired"
                 false
                 (Types.fact_is_current ~now expired))
        ] )
	    ]
;;
