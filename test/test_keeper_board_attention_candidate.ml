module A = Masc.Keeper_board_attention_candidate
module J = Masc.Keeper_board_attention_judgment
module Wake = Masc.Keeper_board_attention_worker_wake

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_base name f =
  let base_path = Filename.temp_dir name "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> f base_path)
;;

let ok label = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s: %s" label detail
;;

let signal ?(content = "Persisted Board evidence") post_id :
  Masc.Board_dispatch.board_signal
  =
  { kind = Masc.Board_dispatch.Board_post_created
  ; post_id
  ; author = "external-author"
  ; title = "Board update"
  ; content
  ; hearth = Some "hearth-1"
  ; updated_at = Some 42.0
  }
;;

let candidate ?(context = `Assoc [ "instructions", `String "continue" ]) signal :
  A.candidate
  =
  let keeper_name = "sangsu" in
  let candidate_id =
    `Assoc
      [ "keeper_name", `String keeper_name
      ; "signal", A.signal_to_yojson signal
      ]
    |> Yojson.Safe.to_string
    |> Digestif.SHA256.digest_string
    |> Digestif.SHA256.to_hex
  in
  { candidate_id
  ; keeper_name
  ; signal
  ; judgment_request =
      `Assoc
        [ "candidate_id", `String candidate_id
        ; "signal", A.signal_to_yojson signal
        ; "keeper_context", context
        ]
  ; recorded_at = 1.0
  ; status = A.Pending { last_failure = None }
  }
;;

let judgment decision : A.judgment =
  { verdict = { J.decision; rationale = "typed structured verdict" }
  ; runtime_id = "configured-structured-judge"
  ; judged_at = 2.0
  }
;;

let record ~base_path candidate =
  match A.record ~base_path candidate with
  | A.Recorded candidate -> candidate
  | A.Duplicate _ -> Alcotest.fail "first record was a duplicate"
  | A.Record_error detail -> Alcotest.failf "candidate record failed: %s" detail
;;

let load_one ~base_path =
  match ok "load candidate" (A.load_candidates ~base_path ~keeper_name:"sangsu") with
  | [ candidate ] -> candidate
  | candidates -> Alcotest.failf "expected one candidate, got %d" (List.length candidates)
;;

let test_codec_and_context_identity_are_strict () =
  let original =
    candidate
      ~context:
        (`Assoc
           [ "instructions", `String "continue"
           ; "goals", `List [ `String "g-1"; `String "g-2" ]
           ])
      (signal "post-codec")
  in
  Alcotest.(check bool)
    "candidate roundtrip"
    true
    (ok "decode candidate" (A.candidate_of_json (A.candidate_to_json original)) = original);
  let left = ok "left context" (A.Context_key.of_candidate original) in
  let reordered =
    candidate
      ~context:
        (`Assoc
           [ "goals", `List [ `String "g-1"; `String "g-2" ]
           ; "instructions", `String "continue"
           ])
      (signal "post-reordered")
    |> A.Context_key.of_candidate
    |> ok "reordered context"
  in
  Alcotest.(check bool)
    "object field order is not context identity"
    true
    (A.Context_key.equal left reordered);
  let changed_list =
    candidate
      ~context:
        (`Assoc
           [ "instructions", `String "continue"
           ; "goals", `List [ `String "g-2"; `String "g-1" ]
           ])
      (signal "post-list-order")
    |> A.Context_key.of_candidate
    |> ok "changed list context"
  in
  Alcotest.(check bool)
    "list order remains context identity"
    false
    (A.Context_key.equal left changed_list);
  (match
     A.Context_key.of_candidate
       { original with
         judgment_request =
           `Assoc
             [ "keeper_context", `Assoc []
             ; "keeper_context", `Assoc []
             ]
       }
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "duplicate keeper_context authority was accepted")
;;

let test_record_dedupes_exact_identity_and_rejects_conflict () =
  with_temp_base "board-attention-candidate-record" @@ fun base_path ->
  let original = candidate (signal "post-record") in
  let persisted = record ~base_path original in
  (match A.record ~base_path original with
   | A.Duplicate duplicate ->
     Alcotest.(check bool) "exact duplicate" true (duplicate = persisted)
   | A.Recorded _ | A.Record_error _ -> Alcotest.fail "exact duplicate was not deduped");
  let conflicting =
    { original with signal = signal ~content:"different evidence" "post-record" }
  in
  (match A.record ~base_path conflicting with
   | A.Record_error _ -> ()
   | A.Recorded _ | A.Duplicate _ -> Alcotest.fail "identity conflict was accepted");
  Alcotest.(check bool) "conflict preserved original" true (load_one ~base_path = original)
;;

let test_record_requests_worker_without_invoking_judgment () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_temp_base "board-attention-candidate-wake" @@ fun base_path ->
  let registration =
    ok "register worker" (Wake.register ~sw ~base_path ~keeper_name:"sangsu")
  in
  let original = candidate (signal "post-wake") in
  let accepted =
    Domain.spawn (fun () -> A.record_and_wake ~base_path original)
    |> Domain.join
    |> ok "record and wake"
  in
  (match accepted with
   | { A.persistence = A.Candidate_recorded
     ; wake = A.Judgment_worker_requested Wake.Signaled
     ; candidate = persisted
     } ->
     (match persisted.status with
      | A.Pending { last_failure = None } -> ()
      | A.Pending { last_failure = Some _ } | A.Judged _ | A.Consumed _ ->
        Alcotest.fail "producer performed judgment work")
   | _ -> Alcotest.fail "candidate returned the wrong worker-wake acceptance");
  match Wake.await registration with
  | Wake.Wake -> ()
  | Wake.Registration_closed -> Alcotest.fail "worker registration closed"
;;

let test_not_relevant_delivery_is_idempotent () =
  with_temp_base "board-attention-candidate-not-relevant" @@ fun base_path ->
  let persisted = record ~base_path (candidate (signal "post-not-relevant")) in
  let verdict = judgment J.Not_relevant in
  ignore
    (ok "record judgment" (A.record_judgment ~base_path persisted verdict)
      : A.candidate);
  (match
     A.record_judgment
       ~base_path
       persisted
       (judgment J.Relevant)
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "conflicting durable judgment was accepted");
  let consumed =
    ok
      "apply judgment"
      (A.apply_judgment_and_deliver
         ~base_path
         ~keeper_name:persisted.keeper_name
         ~candidate_id:persisted.candidate_id
         ~judgment:verdict)
  in
  (match consumed.status with
   | A.Consumed { delivery = A.Not_relevant; _ } -> ()
   | A.Pending _ | A.Judged _ | A.Consumed _ ->
     Alcotest.fail "not-relevant judgment did not reach Consumed");
  let replayed =
    ok
      "replay judgment"
      (A.apply_judgment_and_deliver
         ~base_path
         ~keeper_name:persisted.keeper_name
         ~candidate_id:persisted.candidate_id
         ~judgment:verdict)
  in
  Alcotest.(check bool) "terminal replay is idempotent" true (replayed = consumed);
  match
    A.apply_judgment_and_deliver
      ~base_path
      ~keeper_name:persisted.keeper_name
      ~candidate_id:persisted.candidate_id
      ~judgment:(judgment J.Relevant)
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "conflicting terminal judgment was accepted"
;;

let test_relevant_delivery_uses_exact_candidate_identity () =
  with_temp_base "board-attention-candidate-relevant" @@ fun base_path ->
  let persisted = record ~base_path (candidate (signal "post-relevant")) in
  let consumed =
    ok
      "apply relevant judgment"
      (A.apply_judgment_and_deliver
         ~base_path
         ~keeper_name:persisted.keeper_name
         ~candidate_id:persisted.candidate_id
         ~judgment:(judgment J.Relevant))
  in
  (match consumed.status with
   | A.Consumed { delivery = A.Enqueued_to_keeper_lane; _ } -> ()
   | A.Pending _ | A.Judged _ | A.Consumed _ ->
     Alcotest.fail "relevant judgment consumed without durable enqueue");
  match
    Keeper_event_queue_persistence.load
      ~base_path
      ~keeper_name:persisted.keeper_name
    |> Keeper_event_queue.to_list
  with
  | [ { payload = Keeper_event_queue.Board_attention attention; _ } ] ->
    Alcotest.(check string)
      "exact candidate delivery identity"
      persisted.candidate_id
      attention.candidate_id
  | _ -> Alcotest.fail "relevant judgment did not enqueue one Board_attention event"
;;

let () =
  Alcotest.run
    "keeper_board_attention_candidate"
    [ ( "durable candidate"
      , [ Alcotest.test_case
            "codec and context identity are strict"
            `Quick
            test_codec_and_context_identity_are_strict
        ; Alcotest.test_case
            "record dedupes exact identity"
            `Quick
            test_record_dedupes_exact_identity_and_rejects_conflict
        ; Alcotest.test_case
            "record requests worker without judgment"
            `Quick
            test_record_requests_worker_without_invoking_judgment
        ; Alcotest.test_case
            "not relevant delivery is idempotent"
            `Quick
            test_not_relevant_delivery_is_idempotent
        ; Alcotest.test_case
            "relevant delivery uses exact identity"
            `Quick
            test_relevant_delivery_uses_exact_candidate_identity
        ] )
    ]
;;
