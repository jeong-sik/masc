(* Recognition apply semantics (masc#26122 acceptance criteria):
   - Reinforce updates the existing row in place (no new row; last_verified_at
     and reinforcement_count move) — re-observation is NOT an append;
   - Forget removes a row and Merge collapses rows — the store can shrink
     (no monotonic-growth invariant);
   - Add appends; Revise rewrites in place preserving first_seen;
   - out-of-range and doubly-targeted indices are typed rejections leaving
     the store unchanged;
   - merge gates (claim_kind / valid_until representability) reject without
     collapsing metadata.
   All checks drive the pure [Keeper_librarian_recognition.apply]; no IO. *)

open Alcotest
module Recognition = Masc.Keeper_librarian_recognition
module Consolidation = Masc.Keeper_memory_os_consolidation
module Ledger = Masc.Keeper_librarian_recognition_ledger
module Types = Masc.Keeper_memory_os_types

let now = 2_000_000.0

let fact ?(claim = "c") ?(category = Types.Fact) ?claim_kind ?claim_id
      ?(first_seen = 1_000_000.0) ?valid_until ?(reinforcement_count = 0) ()
  : Types.fact
  =
  { Types.claim
  ; category
  ; claim_kind
  ; source = { Types.trace_id = "t"; turn = 1; tool_call_id = None }
  ; observed_by = []
  ; first_seen
  ; valid_until
  ; last_verified_at = None
  ; schema_version = Types.schema_version
  ; claim_id
  ; reinforcement_count
  }
;;

let claims facts = List.map (fun (f : Types.fact) -> f.Types.claim) facts

let apply operations facts = Recognition.apply ~now ~operations facts

let merge ?claim_id ?(source_turn = 9) group =
  Recognition.Merge { group; claim_id; source_turn }
;;

let test_reinforce_updates_in_place () =
  let store = [ fact ~claim:"a" (); fact ~claim:"b" ~reinforcement_count:2 () ] in
  let result = apply [ Recognition.Reinforce { index = 1; source_turn = 9 } ] store in
  check int "row count unchanged" 2 (List.length result.Recognition.facts);
  check (list string) "claims unchanged" [ "a"; "b" ] (claims result.Recognition.facts);
  let reinforced = List.nth result.Recognition.facts 1 in
  check int "reinforcement_count incremented" 3 reinforced.Types.reinforcement_count;
  check (option (float 0.0)) "last_verified_at set to now" (Some now)
    reinforced.Types.last_verified_at;
  check (float 0.0) "first_seen preserved" 1_000_000.0 reinforced.Types.first_seen;
  check int "reinforce produces no episode claims" 0
    (List.length result.Recognition.recognized_facts);
  check (list string) "applied" [ "applied" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_forget_shrinks_store () =
  let store = [ fact ~claim:"keep" (); fact ~claim:"drop" () ] in
  let result = apply [ Recognition.Forget { index = 1; reason = "superseded" } ] store in
  check (list string) "store shrank to the survivor" [ "keep" ]
    (claims result.Recognition.facts)
;;

let test_merge_collapses_rows () =
  let store =
    [ fact ~claim:"first wording" ~first_seen:1_000.0 ~reinforcement_count:1 ()
    ; fact ~claim:"untouched" ()
    ; fact ~claim:"second wording" ~first_seen:2_000.0 ~reinforcement_count:2 ()
    ]
  in
  let result =
    apply
      [ merge
          { Consolidation.member_indices = [ 0; 2 ]
          ; consolidated_claim = "one merged claim"
          ; category = Types.Lesson
          }
      ]
      store
  in
  (* 3 -> 2: merged row takes the earliest member's slot. *)
  check (list string) "merged row anchors at earliest member"
    [ "one merged claim"; "untouched" ]
    (claims result.Recognition.facts);
  let merged = List.hd result.Recognition.facts in
  check (float 0.0) "first_seen is min of members" 1_000.0 merged.Types.first_seen;
  check int "reinforcement history converges (1+2)" 3 merged.Types.reinforcement_count;
  check (list string) "merged row is the episode claim" [ "one merged claim" ]
    (claims result.Recognition.recognized_facts)
;;

let test_revise_rewrites_in_place () =
  let store =
    [ fact ~claim:"old conclusion" ~claim_id:"old-slug" ~reinforcement_count:3 () ]
  in
  let result =
    apply
      [ Recognition.Revise
          { index = 0
          ; claim = "new conclusion"
          ; category = None
          ; claim_id = Some "new-slug"
          ; claim_kind_update = Recognition.Keep_claim_kind
          ; valid_until_update = Recognition.Set_valid_for_days 7
          ; source_turn = 9
          }
      ]
      store
  in
  check int "row count unchanged" 1 (List.length result.Recognition.facts);
  let revised = List.hd result.Recognition.facts in
  check string "claim rewritten" "new conclusion" revised.Types.claim;
  check (option string) "claim_id replaced" (Some "new-slug") revised.Types.claim_id;
  check (float 0.0) "first_seen preserved" 1_000_000.0 revised.Types.first_seen;
  check bool "valid_until derived from valid_for_days" true
    (revised.Types.valid_until = Some (Types.valid_until_of_days ~now 7));
  check int "revision resets reinforcement count" 0 revised.Types.reinforcement_count;
  check (list string) "revised row is the episode claim" [ "new conclusion" ]
    (claims result.Recognition.recognized_facts)
;;

let test_revise_null_semantics_clear_expiry () =
  let store = [ fact ~valid_until:9_000_000.0 () ] in
  let result =
    apply
      [ Recognition.Revise
          { index = 0
          ; claim = "durable revision"
          ; category = None
          ; claim_id = None
          ; claim_kind_update = Recognition.Keep_claim_kind
          ; valid_until_update = Recognition.Clear_valid_until
          ; source_turn = 9
          }
      ]
      store
  in
  let revised = List.hd result.Recognition.facts in
  check (option (float 0.0)) "explicit null clears expiry" None revised.Types.valid_until
;;

let test_revise_null_claim_id_clears_stale_slug () =
  (* The slug identifies the conclusion and revise means the conclusion
     changed: a null claim_id is "no stable slug for the corrected
     conclusion", never "inherit the superseded conclusion's identity". *)
  let store = [ fact ~claim:"old conclusion" ~claim_id:"old-slug" () ] in
  let result =
    apply
      [ Recognition.Revise
          { index = 0
          ; claim = "corrected conclusion"
          ; category = None
          ; claim_id = None
          ; claim_kind_update = Recognition.Keep_claim_kind
          ; valid_until_update = Recognition.Keep_valid_until
          ; source_turn = 9
          }
      ]
      store
  in
  let revised = List.hd result.Recognition.facts in
  check (option string) "stale slug does not survive the revision" None
    revised.Types.claim_id
;;

let test_revise_claim_kind_tri_state () =
  let base = fact ~claim_kind:Types.External_state () in
  let revise claim_kind_update =
    apply
      [ Recognition.Revise
          { index = 0
          ; claim = "corrected"
          ; category = None
          ; claim_id = None
          ; claim_kind_update
          ; valid_until_update = Recognition.Keep_valid_until
          ; source_turn = 17
          }
      ]
      [ base ]
    |> fun result -> List.hd result.Recognition.facts
  in
  check (option string) "absent preserves kind"
    (Some "external_state")
    (Option.map Types.claim_kind_to_string
       (revise Recognition.Keep_claim_kind).Types.claim_kind);
  check (option string) "null clears kind" None
    (Option.map Types.claim_kind_to_string
       (revise Recognition.Clear_claim_kind).Types.claim_kind);
  check (option string) "value replaces kind"
    (Some "durable_knowledge")
    (Option.map Types.claim_kind_to_string
       (revise (Recognition.Set_claim_kind Types.Durable_knowledge)).Types.claim_kind)
;;

let test_merge_uses_authored_claim_id_and_current_turn () =
  let result =
    apply
      [ merge
          ~claim_id:"merged-conclusion"
          ~source_turn:42
          { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "merged"
          ; category = Types.Lesson
          }
      ]
      [ fact ~claim_id:"historical-a" (); fact ~claim_id:"historical-b" () ]
  in
  let merged = List.hd result.Recognition.facts in
  check (option string) "merge stores the authored conclusion id"
    (Some "merged-conclusion")
    merged.Types.claim_id;
  check (list int) "episode provenance uses the current operation turn"
    [ 42 ]
    result.Recognition.applied_source_turns
;;

let test_rewrite_failure_never_commits_publication () =
  let prepared = ref false
  and rewritten = ref false
  and committed = ref false in
  match
    Ledger.publish
      ~prepare:(fun () ->
        prepared := true;
        Ok ())
      ~rewrite:(fun () ->
        rewritten := true;
        Error "injected rewrite failure")
      ~commit:(fun () ->
        committed := true;
        Ok ())
  with
  | Error (Ledger.Rewrite_failed "injected rewrite failure") ->
    check bool "prepare is durable first" true !prepared;
    check bool "rewrite was attempted" true !rewritten;
    check bool "failed rewrite has no committed marker" false !committed
  | Error _ -> fail "unexpected publication failure"
  | Ok () -> fail "injected rewrite failure unexpectedly committed"
;;

let test_publication_rows_distinguish_prepared_from_committed () =
  let before = [ fact ~claim:"before" () ] in
  let operation = Recognition.Add (fact ~claim:"after" ()) in
  let applied = apply [ operation ] before in
  let publication_id =
    Ledger.publication_id
      ~keeper_id:"keeper-a"
      ~trace_id:"trace-current"
      ~generation:7
      ~store_before:before
      ~operations:[ operation ]
      ~dispositions:applied.Recognition.dispositions
      ~store_after:applied.Recognition.facts
  in
  let state = function
    | `Assoc fields ->
      (match List.assoc_opt "publication_state" fields with
       | Some (`String value) -> value
       | _ -> fail "publication_state missing")
    | _ -> fail "publication row must be an object"
  in
  let prepared =
    Ledger.prepared_to_json
      ~publication_id
      ~keeper_id:"keeper-a"
      ~trace_id:"trace-current"
      ~generation:7
      ~store_before:before
      ~operations:[ operation ]
      ~dispositions:applied.Recognition.dispositions
      ~store_after:applied.Recognition.facts
      ~now
      ()
  in
  let committed =
    Ledger.committed_to_json
      ~publication_id
      ~keeper_id:"keeper-a"
      ~trace_id:"trace-current"
      ~generation:7
      ~now
      ()
  in
  check string "pre-rewrite evidence is not published" "prepared" (state prepared);
  check string "post-rewrite marker is explicit" "committed" (state committed)
;;

let test_recalled_reinforcement_is_rejected_by_provenance () =
  let store = [ fact ~claim:"recalled" ~reinforcement_count:3 () ] in
  let result =
    Recognition.apply
      ~recalled_reinforcement_indices:[ 0 ]
      ~now
      ~operations:[ Recognition.Reinforce { index = 0; source_turn = 9 } ]
      store
  in
  check int "recalled echo does not refresh count" 3
    (List.hd result.Recognition.facts).Types.reinforcement_count;
  check (list string) "recalled echo has typed disposition"
    [ "rejected_recalled_echo" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_add_appends () =
  let store = [ fact ~claim:"existing" () ] in
  let result = apply [ Recognition.Add (fact ~claim:"brand new" ()) ] store in
  check (list string) "added at the end" [ "existing"; "brand new" ]
    (claims result.Recognition.facts)
;;

let test_out_of_range_rejects_without_change () =
  let store = [ fact ~claim:"only" () ] in
  let result =
    apply
      [ Recognition.Forget { index = 5; reason = "r" }
      ; Recognition.Reinforce { index = -1; source_turn = 0 }
      ]
      store
  in
  check (list string) "store unchanged" [ "only" ] (claims result.Recognition.facts);
  check (list string) "both rejected"
    [ "rejected_index_out_of_bounds"; "rejected_index_out_of_bounds" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_overlapping_targets_reject_the_entire_operation_set () =
  let store = [ fact ~claim:"contested" () ] in
  let result =
    apply
      [ Recognition.Reinforce { index = 0; source_turn = 1 }
      ; Recognition.Forget { index = 0; reason = "r" }
      ]
      store
  in
  check (list string) "store is unchanged" [ "contested" ]
    (claims result.Recognition.facts);
  check (list string) "all operations are rejected as one malformed set"
    [ "rejected_target_overlap"; "rejected_target_overlap" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_merge_kind_mismatch_rejected () =
  let store =
    [ fact ~claim:"a" ~claim_kind:Types.Durable_knowledge ()
    ; fact ~claim:"b" ~claim_kind:Types.Self_observation ()
    ]
  in
  let result =
    apply
      [ merge
          { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "m"
          ; category = Types.Fact
          }
      ]
      store
  in
  check (list string) "kind mismatch preserves both members" [ "a"; "b" ]
    (claims result.Recognition.facts);
  check (list string) "typed rejection" [ "rejected_kind_mismatch" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_merge_valid_until_mismatch_rejected () =
  let store =
    [ fact ~claim:"a" ~valid_until:3_000_000.0 (); fact ~claim:"b" () ]
  in
  let result =
    apply
      [ merge
          { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "m"
          ; category = Types.Fact
          }
      ]
      store
  in
  check (list string) "valid_until mismatch preserves both members" [ "a"; "b" ]
    (claims result.Recognition.facts);
  check (list string) "typed rejection" [ "rejected_valid_until_mismatch" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_merge_with_consumed_member_rejects_entirely () =
  let store = [ fact ~claim:"a" (); fact ~claim:"b" () ] in
  let result =
    apply
      [ Recognition.Forget { index = 0; reason = "r" }
      ; merge
          { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "m"
          ; category = Types.Fact
          }
      ]
      store
  in
  check (list string) "overlap leaves every row untouched" [ "a"; "b" ]
    (claims result.Recognition.facts);
  check (list string) "dispositions"
    [ "rejected_target_overlap"; "rejected_target_overlap" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_merge_never_shrinks_to_free_subset () =
  (* A merge sharing one member with another operation is a malformed batch,
     not a left-to-right conflict resolution policy. *)
  let store =
    [ fact ~claim:"a" (); fact ~claim:"b" (); fact ~claim:"c" () ]
  in
  let result =
    apply
      [ Recognition.Reinforce { index = 1; source_turn = 2 }
      ; merge
          { Consolidation.member_indices = [ 0; 1; 2 ]
          ; consolidated_claim = "m"
          ; category = Types.Fact
          }
      ]
      store
  in
  check (list string) "no partial merge; all rows survive" [ "a"; "b"; "c" ]
    (claims result.Recognition.facts);
  check (list string) "batch overlap is typed"
    [ "rejected_target_overlap"; "rejected_target_overlap" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_merge_out_of_range_member_rejects_entirely () =
  let store = [ fact ~claim:"a" (); fact ~claim:"b" () ] in
  let result =
    apply
      [ merge
          { Consolidation.member_indices = [ 0; 1; 9 ]
          ; consolidated_claim = "m"
          ; category = Types.Fact
          }
      ]
      store
  in
  check (list string) "out-of-range member rejects the whole merge"
    [ "a"; "b" ]
    (claims result.Recognition.facts);
  check (list string) "typed rejection" [ "rejected_index_out_of_bounds" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_mixed_pass_shrinks_store () =
  (* One realistic pass over five rows: reinforce one, merge two, forget one,
     add one -> net 5 - 2 + 1 = 4 rows, proving write-side refinement. *)
  let store =
    [ fact ~claim:"stable lesson" ()
    ; fact ~claim:"dup wording 1" ()
    ; fact ~claim:"stale queue state" ()
    ; fact ~claim:"dup wording 2" ()
    ; fact ~claim:"still true constraint" ()
    ]
  in
  let result =
    apply
      [ Recognition.Reinforce { index = 0; source_turn = 3 }
      ; merge
          { Consolidation.member_indices = [ 1; 3 ]
          ; consolidated_claim = "the deduplicated lesson"
          ; category = Types.Lesson
          }
      ; Recognition.Forget { index = 2; reason = "queue state is ephemeral" }
      ; Recognition.Add (fact ~claim:"new external fact" ())
      ]
      store
  in
  check (list string) "refined store"
    [ "stable lesson"
    ; "the deduplicated lesson"
    ; "still true constraint"
    ; "new external fact"
    ]
    (claims result.Recognition.facts);
  check (list string) "all applied"
    [ "applied"; "applied"; "applied"; "applied" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_empty_operations_identity () =
  let store = [ fact ~claim:"a" (); fact ~claim:"b" () ] in
  let result = apply [] store in
  check (list string) "no ops, identical store" [ "a"; "b" ]
    (claims result.Recognition.facts);
  check int "no dispositions" 0 (List.length result.Recognition.dispositions)
;;

let () =
  run "keeper_librarian_recognition"
    [
      ( "apply",
        [
          test_case "reinforce updates in place, adds no row" `Quick
            test_reinforce_updates_in_place;
          test_case "forget shrinks the store" `Quick test_forget_shrinks_store;
          test_case "merge collapses rows" `Quick test_merge_collapses_rows;
          test_case "revise rewrites in place" `Quick test_revise_rewrites_in_place;
          test_case "revise null clears expiry" `Quick
            test_revise_null_semantics_clear_expiry;
          test_case "revise null claim_id clears the stale slug" `Quick
            test_revise_null_claim_id_clears_stale_slug;
          test_case "revise claim_kind is tri-state" `Quick
            test_revise_claim_kind_tri_state;
          test_case "merge keeps authored claim_id and current provenance" `Quick
            test_merge_uses_authored_claim_id_and_current_turn;
          test_case "rewrite failure never commits publication" `Quick
            test_rewrite_failure_never_commits_publication;
          test_case "publication rows distinguish prepared and committed" `Quick
            test_publication_rows_distinguish_prepared_from_committed;
          test_case "recalled reinforcement is rejected by provenance" `Quick
            test_recalled_reinforcement_is_rejected_by_provenance;
          test_case "add appends" `Quick test_add_appends;
          test_case "out-of-range rejects without change" `Quick
            test_out_of_range_rejects_without_change;
          test_case "overlapping targets reject the full operation set" `Quick
            test_overlapping_targets_reject_the_entire_operation_set;
          test_case "merge kind mismatch rejected" `Quick test_merge_kind_mismatch_rejected;
          test_case "merge valid_until mismatch rejected" `Quick
            test_merge_valid_until_mismatch_rejected;
          test_case "merge with consumed member rejects entirely" `Quick
            test_merge_with_consumed_member_rejects_entirely;
          test_case "merge never shrinks to free subset" `Quick
            test_merge_never_shrinks_to_free_subset;
          test_case "merge with out-of-range member rejects entirely" `Quick
            test_merge_out_of_range_member_rejects_entirely;
          test_case "mixed pass refines and shrinks" `Quick test_mixed_pass_shrinks_store;
          test_case "empty operations are identity" `Quick test_empty_operations_identity;
        ] );
    ]
