module A = Masc.Keeper_board_attention_candidate
module Event_queue = Masc.Keeper_event_queue
module Event_queue_persistence = Masc.Keeper_event_queue_persistence
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

let post_id_exn value =
  match Masc.Board.Post_id.of_string value with
  | Ok value -> value
  | Error _ -> Alcotest.fail ("invalid Board post id fixture: " ^ value)
;;

let agent_id_exn value =
  match Masc.Board.Agent_id.of_string value with
  | Ok value -> value
  | Error _ -> Alcotest.fail ("invalid Board agent id fixture: " ^ value)
;;

let comment_id_exn value =
  match Masc.Board.Comment_id.of_string value with
  | Ok value -> value
  | Error _ -> Alcotest.fail ("invalid Board comment id fixture: " ^ value)
;;

let post_of_signal (signal : Masc.Board_dispatch.board_signal) : Masc.Board.post =
  { id = post_id_exn signal.post_id
  ; author = agent_id_exn signal.author
  ; title = signal.title
  ; body = signal.content
  ; content = signal.content
  ; post_kind = Masc.Board.Human_post
  ; meta_json = None
  ; visibility = Masc.Board.Public
  ; created_at = 1.0
  ; updated_at = Option.value signal.updated_at ~default:1.0
  ; expires_at = 3601.0
  ; votes_up = 0
  ; votes_down = 0
  ; reply_count = 0
  ; pinned = false
  ; hearth = signal.hearth
  ; thread_id = None
  ; origin = None
  }
;;

let comment_of_signal
      (signal : Masc.Board_dispatch.board_signal)
  : Masc.Board.comment
  =
  { id = comment_id_exn ("comment-" ^ signal.post_id)
  ; post_id = post_id_exn signal.post_id
  ; parent_id = None
  ; author = agent_id_exn "comment-author"
  ; content = "Canonical Board comment"
  ; created_at = 2.0
  ; expires_at = 3602.0
  ; votes_up = 0
  ; votes_down = 0
  }
;;

let keeper_context ?(active_goal_ids = []) () =
  `Assoc
    [ "lane_keeper_name", `String "sangsu"
    ; "agent_name", `String "sangsu-agent"
    ; "keeper_record_id", `Null
    ; "keeper_runtime_uid", `Null
    ; "persona", `Null
    ; "instructions", `String "continue"
    ; "active_goal_ids", `List (List.map (fun id -> `String id) active_goal_ids)
    ; "current_task_id", `Null
    ; "mention_keeper_ids", `List [ `String "sangsu" ]
    ]
;;

let candidate ?(context = keeper_context ()) signal :
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
        ; "post", Masc.Board.post_to_yojson (post_of_signal signal)
        ; ( "comments"
          , `List
              [ Masc.Board.comment_to_yojson (comment_of_signal signal) ] )
        ; "keeper_context", context
        ]
  ; recorded_at = 1.0
  ; status = A.Pending { last_delivery_failure = None }
  }
;;

let judgment decision : A.judgment =
  { verdict = { J.decision; rationale = "typed structured verdict" }
  ; slot_id = "board-attention-primary"
  ; call_id = "call-board-attention"
  ; plan_fingerprint = "plan-board-attention"
  ; request_body_sha256 = "request-board-attention"
  ; judged_at = 2.0
  }
;;

let invalid_judgment_fixtures () =
  let valid = judgment J.Not_relevant in
  [ ( "blank verdict rationale"
    , { valid with
        verdict = { valid.verdict with rationale = " \t" }
      } )
  ; "blank slot_id", { valid with slot_id = "\n" }
  ; "blank call_id", { valid with call_id = " " }
  ; "blank plan_fingerprint", { valid with plan_fingerprint = "\t" }
  ; "blank request_body_sha256", { valid with request_body_sha256 = "\r\n" }
  ; "NaN judged_at", { valid with judged_at = Float.nan }
  ; "+Infinity judged_at", { valid with judged_at = Float.infinity }
  ; "-Infinity judged_at", { valid with judged_at = Float.neg_infinity }
  ]
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
      ~context:(keeper_context ~active_goal_ids:[ "g-1"; "g-2" ] ())
      (signal "post-codec")
  in
  let encoded = A.candidate_to_json original in
  Alcotest.(check bool)
    "candidate roundtrip"
    true
    (ok "decode candidate" (A.candidate_of_json encoded) = original);
  let old_schema =
    match encoded with
    | `Assoc fields ->
      `Assoc (List.filter (fun (name, _) -> not (String.equal name "schema_version")) fields)
    | _ -> Alcotest.fail "candidate codec did not produce an object"
  in
  (match A.candidate_of_json old_schema with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "pre-quarantine candidate schema was accepted");
  let left = ok "left context" (A.Context_key.of_candidate original) in
  let reordered =
    candidate
      ~context:
        (match keeper_context ~active_goal_ids:[ "g-1"; "g-2" ] () with
         | `Assoc fields -> `Assoc (List.rev fields)
         | _ -> assert false)
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
      ~context:(keeper_context ~active_goal_ids:[ "g-2"; "g-1" ] ())
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

let rewrite_assoc_field key rewrite = function
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (field, value) ->
            if String.equal field key
            then field, rewrite value
            else field, value)
         fields)
  | _ -> Alcotest.fail ("expected object while rewriting field " ^ key)
;;

let add_legacy_extra = function
  | `Assoc fields -> `Assoc (("legacy_extra", `String "must-not-survive") :: fields)
  | _ -> Alcotest.fail "expected Board object fixture"
;;

let set_assoc_field key value = function
  | `Assoc fields ->
    if List.exists (fun (field, _) -> String.equal field key) fields
    then
      `Assoc
        (List.map
           (fun (field, current) ->
              if String.equal field key then field, value else field, current)
           fields)
    else `Assoc (fields @ [ key, value ])
  | _ -> Alcotest.fail ("expected object while setting field " ^ key)
;;

let rewrite_first_comment rewrite = function
  | `List (comment :: rest) -> `List (rewrite comment :: rest)
  | `List [] -> Alcotest.fail "expected one Board comment fixture"
  | _ -> Alcotest.fail "expected comments array"
;;

let expect_record_error ~base_path label candidate =
  match A.record ~base_path candidate with
  | A.Record_error _ -> ()
  | A.Recorded _ | A.Duplicate _ -> Alcotest.fail (label ^ " was recorded")
;;

let test_singleton_request_is_canonical_and_identity_bound () =
  let original = candidate (signal "post-canonical-request") in
  ignore
    (ok
       "canonical singleton request"
       (A.singleton_judgment_request original)
      : Yojson.Safe.t);
  let noisy_request =
    original.judgment_request
    |> rewrite_assoc_field "post" add_legacy_extra
    |> rewrite_assoc_field "comments" (function
      | `List comments -> `List (List.map add_legacy_extra comments)
      | _ -> Alcotest.fail "expected comments array")
  in
  (match
     A.singleton_judgment_request
       { original with judgment_request = noisy_request }
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "unknown nested Board fields were accepted");
  let mismatched_post =
    original.judgment_request
    |> rewrite_assoc_field "post" (rewrite_assoc_field "id" (fun _ ->
      `String "different-post"))
  in
  (match
     A.singleton_judgment_request
       { original with judgment_request = mismatched_post }
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "mismatched Board post identity was accepted");
  let mismatched_comment =
    original.judgment_request
    |> rewrite_assoc_field "comments" (function
      | `List (comment :: rest) ->
        `List
          (rewrite_assoc_field
             "post_id"
             (fun _ -> `String "different-post")
             comment
           :: rest)
      | `List [] -> Alcotest.fail "expected one Board comment fixture"
      | _ -> Alcotest.fail "expected comments array")
  in
  match
    A.singleton_judgment_request
      { original with judgment_request = mismatched_comment }
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "mismatched Board comment identity was accepted"
;;

let test_record_rejects_malformed_without_poisoning_ledger () =
  with_temp_base "board-attention-candidate-record-validation" @@ fun base_path ->
  let valid = candidate (signal "post-record-validation") in
  let malformed_request =
    valid.judgment_request
    |> rewrite_assoc_field "post" (rewrite_assoc_field "id" (fun _ ->
      `String "different-post"))
  in
  (match
     A.record
       ~base_path
       { valid with judgment_request = malformed_request }
   with
   | A.Record_error _ -> ()
   | A.Recorded _ | A.Duplicate _ ->
     Alcotest.fail "malformed in-memory candidate was recorded");
  Alcotest.(check int)
    "failed validation did not poison the ledger"
    0
    (ok
       "load ledger after rejected record"
       (A.load_candidates ~base_path ~keeper_name:valid.keeper_name)
     |> List.length);
  let noisy_request =
    valid.judgment_request
    |> rewrite_assoc_field "post" add_legacy_extra
    |> rewrite_assoc_field "comments" (function
      | `List comments -> `List (List.map add_legacy_extra comments)
      | _ -> Alcotest.fail "expected comments array")
  in
  (match A.record ~base_path { valid with judgment_request = noisy_request } with
   | A.Record_error _ -> ()
   | A.Recorded _ | A.Duplicate _ ->
     Alcotest.fail "unknown nested Board fields were canonicalized and recorded");
  Alcotest.(check int)
    "rejected old JSON left the ledger empty"
    0
    (ok
       "load ledger after rejected old JSON"
       (A.load_candidates ~base_path ~keeper_name:valid.keeper_name)
     |> List.length);
  let persisted = record ~base_path valid in
  Alcotest.(check bool)
    "valid current request is the only durable row"
    true
    (load_one ~base_path = persisted)
;;

let test_judgment_write_invariant_rejects_blank_provenance () =
  with_temp_base "board-attention-candidate-judgment-invariant" @@ fun base_path ->
  let persisted =
    record ~base_path (candidate (signal "post-judgment-invariant"))
  in
  let valid = judgment J.Not_relevant in
  let invalid_judgments = invalid_judgment_fixtures () in
  List.iter
    (fun (label, invalid) ->
       match A.record_judgment ~base_path persisted invalid with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail (label ^ " judgment was recorded"))
    invalid_judgments;
  let terminal = candidate (signal "post-consumed-invariant") in
  let invalid_terminal =
    { terminal with
      status =
        A.Consumed
          { judgment =
              { valid with
                verdict = { valid.verdict with rationale = " " }
              }
          ; delivery = A.Not_relevant
          ; consumed_at = 3.0
          }
    }
  in
  expect_record_error
    ~base_path
    "Consumed candidate with blank verdict"
    invalid_terminal;
  match (load_one ~base_path).status with
  | A.Pending { last_delivery_failure = None } -> ()
  | A.Pending { last_delivery_failure = Some _ }
  | A.Judged _
  | A.Consumed _
  | A.Quarantine _ ->
    Alcotest.fail "rejected judgment changed the durable Pending candidate"
;;

let test_direct_judgment_decoder_enforces_invariant () =
  List.iter
    (fun (label, invalid) ->
       match A.judgment_of_yojson (A.judgment_to_yojson invalid) with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail (label ^ " was accepted by judgment decoder"))
    (invalid_judgment_fixtures ())
;;

let test_non_finite_lifecycle_times_are_rejected () =
  with_temp_base "board-attention-candidate-finite-times" @@ fun base_path ->
  let valid = candidate (signal "post-finite-times") in
  expect_record_error
    ~base_path
    "NaN recorded_at"
    { valid with recorded_at = Float.nan };
  let infinite_failure : A.delivery_failure =
    { kind = A.Durable_delivery_unavailable
    ; detail = "injected non-finite failure time"
    ; failed_at = Float.infinity
    }
  in
  expect_record_error
    ~base_path
    "infinite delivery failed_at"
    { valid with
      status = A.Pending { last_delivery_failure = Some infinite_failure }
    };
  expect_record_error
    ~base_path
    "negative-infinite consumed_at"
    { valid with
      status =
        A.Consumed
          { judgment = judgment J.Not_relevant
          ; delivery = A.Not_relevant
          ; consumed_at = Float.neg_infinity
          }
    };
  Alcotest.(check int)
    "non-finite records did not poison the ledger"
    0
    (ok
       "load after rejected non-finite records"
       (A.load_candidates ~base_path ~keeper_name:valid.keeper_name)
     |> List.length);
  ignore (record ~base_path valid : A.candidate);
  let ledger_path =
    Filename.concat
      (Filename.concat
         (Common.masc_dir_from_base_path ~base_path)
         "board_attention_candidates")
      "sangsu.jsonl"
  in
  let non_finite_row =
    A.candidate_to_json { valid with recorded_at = Float.infinity }
    |> Yojson.Safe.to_string
  in
  Out_channel.with_open_bin ledger_path (fun channel ->
    output_string channel (non_finite_row ^ "\n"));
  match A.load_candidates ~base_path ~keeper_name:valid.keeper_name with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "load accepted a non-finite durable candidate"
;;

let test_non_finite_complete_request_evidence_is_rejected () =
  with_temp_base "board-attention-candidate-request-finite" @@ fun base_path ->
  let base = candidate (signal "post-request-finite") in
  let at_signal value =
    let signal =
      { (signal "post-request-finite") with updated_at = Some value }
    in
    let candidate = candidate signal in
    { candidate with
      judgment_request =
        candidate.judgment_request
        |> rewrite_assoc_field
             "post"
             (rewrite_assoc_field "updated_at" (fun _ -> `Float 42.0))
    }
  in
  let at_post value =
    { base with
      judgment_request =
        base.judgment_request
        |> rewrite_assoc_field
             "post"
             (rewrite_assoc_field "created_at" (fun _ -> `Float value))
    }
  in
  let at_comment value =
    { base with
      judgment_request =
        base.judgment_request
        |> rewrite_assoc_field
             "comments"
             (rewrite_first_comment
                (rewrite_assoc_field "created_at" (fun _ -> `Float value)))
    }
  in
  let at_nested_evidence value =
    let nested =
      `Assoc
        [ ( "evidence"
          , `List [ `Assoc [ "confidence", `Float value ] ] )
        ]
    in
    { base with
      judgment_request =
        base.judgment_request
        |> rewrite_assoc_field "post" (set_assoc_field "meta" nested)
    }
  in
  let locations =
    [ "signal.updated_at", at_signal
    ; "post.created_at", at_post
    ; "comment.created_at", at_comment
    ; "nested post evidence", at_nested_evidence
    ]
  in
  let non_finite_values =
    [ "NaN", Float.nan
    ; "+Infinity", Float.infinity
    ; "-Infinity", Float.neg_infinity
    ]
  in
  List.iter
    (fun (location, make_candidate) ->
       List.iter
         (fun (number, value) ->
            expect_record_error
              ~base_path
              (number ^ " at " ^ location)
              (make_candidate value))
         non_finite_values)
    locations;
  Alcotest.(check int)
    "non-finite request fixtures left no durable row"
    0
    (ok
       "load after rejected request fixtures"
       (A.load_candidates ~base_path ~keeper_name:base.keeper_name)
     |> List.length)
;;

let test_finite_numeric_boundary_is_persisted () =
  with_temp_base "board-attention-candidate-finite-boundary" @@ fun base_path ->
  let signal =
    { (signal "post-finite-boundary") with
      updated_at = Some Float.max_float
    }
  in
  let original = candidate signal in
  let nested_boundary =
    `Assoc
      [ ( "evidence"
        , `List
            [ `Assoc
                [ "positive", `Float Float.max_float
                ; "negative", `Float (-. Float.max_float)
                ]
            ] )
      ]
  in
  let judgment_request =
    original.judgment_request
    |> rewrite_assoc_field
         "post"
         (fun post ->
            post
            |> rewrite_assoc_field
                 "created_at"
                 (fun _ -> `Float (-. Float.max_float))
            |> set_assoc_field "meta" nested_boundary)
    |> rewrite_assoc_field
         "comments"
         (rewrite_first_comment
            (rewrite_assoc_field
               "created_at"
               (fun _ -> `Float Float.max_float)))
  in
  let original = { original with judgment_request } in
  let persisted = record ~base_path original in
  Alcotest.(check bool)
    "largest finite magnitudes round-trip"
    true
    (load_one ~base_path = persisted)
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
      | A.Pending { last_delivery_failure = None } -> ()
      | A.Pending { last_delivery_failure = Some _ }
      | A.Judged _
      | A.Consumed _
      | A.Quarantine _ ->
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
   | A.Pending _ | A.Judged _ | A.Consumed _ | A.Quarantine _ ->
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
   | A.Pending _ | A.Judged _ | A.Consumed _ | A.Quarantine _ ->
     Alcotest.fail "relevant judgment consumed without durable enqueue");
  match
    Event_queue_persistence.load
      ~base_path
      ~keeper_name:persisted.keeper_name
    |> Event_queue.to_list
  with
  | [ { payload = Event_queue.Board_attention attention; _ } ] ->
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
            "singleton request is canonical and identity bound"
            `Quick
            test_singleton_request_is_canonical_and_identity_bound
        ; Alcotest.test_case
            "record rejects malformed input without poisoning ledger"
            `Quick
            test_record_rejects_malformed_without_poisoning_ledger
        ; Alcotest.test_case
            "judgment write invariant rejects blank provenance"
            `Quick
            test_judgment_write_invariant_rejects_blank_provenance
        ; Alcotest.test_case
            "direct judgment decoder enforces invariant"
            `Quick
            test_direct_judgment_decoder_enforces_invariant
        ; Alcotest.test_case
            "non-finite lifecycle times are rejected"
            `Quick
            test_non_finite_lifecycle_times_are_rejected
        ; Alcotest.test_case
            "non-finite complete request evidence is rejected"
            `Quick
            test_non_finite_complete_request_evidence_is_rejected
        ; Alcotest.test_case
            "finite numeric boundary is persisted"
            `Quick
            test_finite_numeric_boundary_is_persisted
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
