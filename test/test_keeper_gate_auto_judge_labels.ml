(* The label an auto-judge resume failure travels under.

   [auto_judge_resume_failure_code_to_string] is the only exported way into
   two closed variants -- six resume codes, and the ten completion rejections
   one of them carries -- and no case named a single constructor of either.
   The mapping underneath is ten arms of copy-paste from
   [Keeper_approval_queue.Exact_attempt_*], which is where two arms end up
   sharing a label and an operator reads someone else's reason.

   Two things are pinned. Each label is spelled out, because the string is what
   leaves the process and a rename is a contract change rather than a
   refactor. And all fifteen are checked distinct, which is the half that
   survives someone updating an expectation to match a collision. *)

open Alcotest
module Gate = Masc.Keeper_gate

let rejections =
  [ Gate.Completion_not_found, "not_found"
  ; Gate.Completion_key_mismatch, "key_mismatch"
  ; Gate.Completion_invalid_identity, "invalid_identity"
  ; Gate.Completion_summary_not_pending, "summary_not_pending"
  ; Gate.Completion_unbound_state, "unbound_state"
  ; Gate.Completion_disposition_conflict, "disposition_conflict"
  ; Gate.Completion_identity_conflict, "identity_conflict"
  ; Gate.Completion_status_conflict, "status_conflict"
  ; Gate.Completion_provenance_mismatch, "provenance_mismatch"
  ; Gate.Completion_content_conflict, "content_conflict"
  ]

let plain_codes =
  [ Gate.Resume_worker_start_failed, "worker_start_failed"
  ; Gate.Resume_identity_unbound, "identity_unbound"
  ; ( Gate.Resume_completion_persistence_uncertain
    , "completion_persistence_uncertain" )
  ; Gate.Resume_judgment_resolution_failed, "judgment_resolution_failed"
  ; Gate.Resume_exact_state_not_completed, "exact_state_not_completed"
  ]

let label code = Gate.auto_judge_resume_failure_code_to_string code

let test_every_rejection_keeps_its_own_label () =
  List.iter
    (fun (rejection, suffix) ->
      check string
        ("completion_rejected:" ^ suffix)
        ("completion_rejected:" ^ suffix)
        (label (Gate.Resume_completion_rejected rejection)))
    rejections

let test_every_plain_code_keeps_its_own_label () =
  List.iter
    (fun (code, expected) -> check string expected expected (label code))
    plain_codes

(* The half that a wrong expectation cannot satisfy. Two arms mapped to one
   label pass every case above the moment someone edits the expectation to
   agree; they cannot both be here. *)
let test_no_two_codes_share_a_label () =
  let labels =
    List.map (fun (code, _) -> label code) plain_codes
    @ List.map
        (fun (rejection, _) -> label (Gate.Resume_completion_rejected rejection))
        rejections
  in
  let sorted = List.sort String.compare labels in
  let deduped = List.sort_uniq String.compare labels in
  check int "fifteen codes" 15 (List.length sorted);
  check (list string) "and fifteen distinct labels" sorted deduped

(* The prefix is the wire's own reading: a resume failure that a completion
   rejected is one code with a reason inside it, not fifteen flat names. A
   consumer splitting on the colon reads the reason; one that does not still
   reads a code it can compare. *)
let test_a_rejection_label_is_prefixed_by_its_code () =
  List.iter
    (fun (rejection, _) ->
      let text = label (Gate.Resume_completion_rejected rejection) in
      check bool
        (text ^ " starts with completion_rejected:")
        true
        (String.length text > String.length "completion_rejected:"
         && String.equal
              (String.sub text 0 (String.length "completion_rejected:"))
              "completion_rejected:"))
    rejections

let () =
  run "keeper_gate_auto_judge_labels"
    [ ( "labels"
      , [ test_case "every rejection keeps its own label" `Quick
            test_every_rejection_keeps_its_own_label
        ; test_case "every plain code keeps its own label" `Quick
            test_every_plain_code_keeps_its_own_label
        ; test_case "no two codes share a label" `Quick
            test_no_two_codes_share_a_label
        ; test_case "a rejection label is prefixed by its code" `Quick
            test_a_rejection_label_is_prefixed_by_its_code
        ] )
    ]
