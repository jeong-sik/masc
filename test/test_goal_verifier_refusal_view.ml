(* RFC-0489 §2.2 and §2.6 — the Goal-side view of an execution refusal.

   Layer 3 writes two evidence shapes that name a run rather than a reviewer
   receipt: a run that dispatched and ended without a verdict, and an original
   left [Dispatch_pending] with no live owner. This view must read both without
   mistaking either for [Reviewer_refused], and must keep every other object on
   today's path so a record this module cannot read is never rejected by shape.

   The shapes here are constructed literally, not through [evidence_json], so a
   change to the writer alone cannot make these cases agree with a reader that
   drifted from it. [evidence_json] is then checked to reproduce them. *)

open Alcotest
module V = Masc.Goal_verifier_refusal
module P = Masc.Lane_addon_request_progress

let run = `Assoc [ "run_id", `String "run-7"; "started_at", `Float 1.25 ]

let dispatched () =
  match P.append P.captured P.Dispatch_intended with
  | Ok progress -> progress
  | Error detail -> fail detail

let rejected evidence =
  match P.append (dispatched ()) (P.Refused { stage = P.Execution; evidence }) with
  | Ok progress -> progress
  | Error detail -> fail detail

let execution_refusal evidence =
  match V.view (P.phase (rejected evidence)) with
  | V.Rejected { stage = V.Execution; refusal } -> refusal
  | V.Rejected { stage = V.Before_dispatch; _ } ->
    fail "an execution refusal read back as a before-dispatch refusal"
  | _ -> fail "a rejected progress did not read as Rejected"

let run_ended_evidence =
  `Assoc
    [ "cause", `String "review_cancelled"
    ; "run", run
    ; "tools", `List []
    ; "observations", `List [ `Assoc [ "fact", `String "reply_received" ] ]
    ]

let test_run_ended_reads_as_run_ended () =
  match execution_refusal run_ended_evidence with
  | V.Run_ended { cause; run; tools; observations } ->
    check bool "cancelled cause" true (cause = V.Cancelled);
    check string "run id" "run-7" run.run_id;
    check (float 0.0) "run start" 1.25 run.started_at;
    check int "no tool observation" 0 (List.length tools);
    check int "one runtime observation" 1 (List.length observations)
  | V.Reviewer_refused _ | V.Owner_exited _ | V.Authority_moved _ ->
    fail "a run-ended record must not read as another refusal"

let test_owner_exited_reads_as_owner_exited () =
  match execution_refusal (`Assoc [ "run", run ]) with
  | V.Owner_exited { run } ->
    check string "run id" "run-7" run.run_id;
    check (float 0.0) "run start" 1.25 run.started_at
  | V.Reviewer_refused _ | V.Run_ended _ | V.Authority_moved _ ->
    fail "an owner-less dispatch must not read as another refusal"

(* A reviewer refusal carries a schema tag, and every refusal the worker wrote
   before layer 3 carries one. It must keep its exact bytes so the existing
   receipt authentication reads what it read before. *)
let test_reviewer_refusal_keeps_its_bytes () =
  let evidence =
    `Assoc
      [ "schema", `String "goal_verifier_refusal/v1"
      ; "run", run
      ; "receipt", `Assoc [ "verdict", `Null ]
      ] in
  match execution_refusal evidence with
  | V.Reviewer_refused { evidence = read } ->
    check bool "evidence preserved verbatim" true (Yojson.Safe.equal read evidence)
  | V.Run_ended _ | V.Owner_exited _ | V.Authority_moved _ ->
    fail "a tagged reviewer refusal must stay a reviewer refusal"

(* Total decode: an object that resembles neither writer shape keeps today's
   meaning instead of being rejected. A record this module cannot read must not
   be the reason a Goal stops. *)
let test_unreadable_shape_stays_a_reviewer_refusal () =
  let evidence =
    `Assoc [ "cause", `String "review_raised"; "run", run; "note", `String "x" ] in
  match execution_refusal evidence with
  | V.Reviewer_refused { evidence = read } ->
    check bool "evidence preserved verbatim" true (Yojson.Safe.equal read evidence)
  | V.Run_ended _ | V.Owner_exited _ | V.Authority_moved _ ->
    fail "an unreadable object must not be decoded by resemblance"

(* A run record the store cannot even carry — a non-finite number is refused by
   Yojson itself, so it can never arrive here — falls back through the same
   path as any other unreadable shape: the run must name a finite start time,
   and a run without one is not a run this module may decode. *)
let test_run_without_a_start_time_falls_back () =
  let evidence =
    `Assoc
      [ "cause", `String "review_cancelled"
      ; "run", `Assoc [ "run_id", `String "run-7" ]
      ; "tools", `List []
      ; "observations", `List []
      ] in
  match execution_refusal evidence with
  | V.Reviewer_refused _ -> ()
  | V.Run_ended _ | V.Owner_exited _ | V.Authority_moved _ ->
    fail "a run without a start time must not read as a named run"

(* The writer and this reader must agree on one shape. *)
let test_writer_reproduces_the_read_shape () =
  let written =
    V.evidence_json
      (V.Run_ended
         { cause = V.Cancelled
         ; run = { V.run_id = "run-7"; started_at = 1.25 }
         ; tools = []
         ; observations = [ `Assoc [ "fact", `String "reply_received" ] ]
         }) in
  check bool "writer emits the pinned shape" true (Yojson.Safe.equal written run_ended_evidence);
  let written_owner =
    V.evidence_json (V.Owner_exited { run = { V.run_id = "run-7"; started_at = 1.25 } }) in
  check bool "owner-exited writer shape" true (Yojson.Safe.equal written_owner (`Assoc [ "run", run ]));
  (match execution_refusal written with
   | V.Run_ended { cause; run = read; _ } ->
     check bool "cause round trip" true (cause = V.Cancelled);
     check string "run round trip" "run-7" read.run_id
   | _ -> fail "the writer's bytes must read back as the value it wrote")

let test_run_end_labels_round_trip () =
  List.iter
    (fun cause ->
      match V.run_end_of_label (V.run_end_label cause) with
      | Ok read -> check bool "label round trip" true (read = cause)
      | Error detail -> fail detail)
    [ V.Cancelled; V.Raised; V.Retention_failed ];
  match V.run_end_of_label "review_interrupted" with
  | Ok _ -> fail "an unknown run end must not decode"
  | Error _ -> ()

let () =
  Alcotest.run "goal_verifier_refusal_view"
    [ ( "execution refusal evidence"
      , [ Alcotest.test_case "run ended" `Quick test_run_ended_reads_as_run_ended
        ; Alcotest.test_case "owner exited" `Quick test_owner_exited_reads_as_owner_exited
        ; Alcotest.test_case "tagged reviewer refusal" `Quick
            test_reviewer_refusal_keeps_its_bytes
        ; Alcotest.test_case "unreadable shape" `Quick
            test_unreadable_shape_stays_a_reviewer_refusal
        ; Alcotest.test_case "run without a start time" `Quick
            test_run_without_a_start_time_falls_back
        ; Alcotest.test_case "writer shape" `Quick test_writer_reproduces_the_read_shape
        ; Alcotest.test_case "run end labels" `Quick test_run_end_labels_round_trip
        ] )
    ]
