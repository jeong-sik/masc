module A = Masc.Keeper_board_attention_candidate
module J = Masc.Keeper_board_attention_judgment

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

let board_id parse label value =
  match parse value with
  | Ok id -> id
  | Error error ->
    Alcotest.failf "%s fixture id invalid: %s" label (Masc.Board.show_board_error error)
;;

let post_id value = board_id Masc.Board.Post_id.of_string "post" value
let comment_id value = board_id Masc.Board.Comment_id.of_string "comment" value
let agent_id value = board_id Masc.Board.Agent_id.of_string "agent" value

let meta keeper_name =
  let json =
    `Assoc
      [ "name", `String keeper_name
      ; "agent_name", `String ("keeper-" ^ keeper_name ^ "-agent")
      ; "trace_id", `String ("trace-" ^ keeper_name)
      ; "instructions", `String "Use the lane context and complete the task"
      ; "sandbox_profile", `String "local"
      ; "network_mode", `String "inherit"
      ; "mention_targets", `List [ `String keeper_name ]
      ]
  in
  match Masc.Keeper_meta_json_parse.meta_of_json json with
  | Ok meta -> { meta with active_goal_ids = [ "goal-board" ] }
  | Error detail -> Alcotest.failf "keeper meta fixture invalid: %s" detail
;;

let signal ?(post_id = "post-1") ?(content = "A new Board observation") () :
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

let post ?(id = "post-1") () : Masc.Board.post =
  { id = post_id id
  ; author = agent_id "external-author"
  ; title = "Board update"
  ; body = "Full persisted body"
  ; content = "A new Board observation"
  ; post_kind = Masc.Board.Human_post
  ; meta_json = Some (`Assoc [ "source", `String "test" ])
  ; visibility = Masc.Board.Public
  ; created_at = 40.0
  ; updated_at = 42.0
  ; expires_at = 0.0
  ; votes_up = 3
  ; votes_down = 1
  ; reply_count = 1
  ; pinned = false
  ; hearth = Some "hearth-1"
  ; thread_id = Some "thread-1"
  ; origin = None
  }
;;

let comments () : Masc.Board.comment list =
  [ { id = comment_id "comment-1"
    ; post_id = post_id "post-1"
    ; parent_id = None
    ; author = agent_id "reviewer"
    ; content = "Full persisted comment"
    ; created_at = 41.0
    ; expires_at = 0.0
    ; votes_up = 1
    ; votes_down = 0
    }
  ]
;;

let candidate ?(keeper_name = "sangsu") ?(signal = signal ()) () =
  match
    A.of_board_evidence
      ~meta:(meta keeper_name)
      ~recorded_at:100.0
      ~signal
      ~post:(post ~id:signal.post_id ())
      ~comments:(comments ())
  with
  | Ok candidate -> candidate
  | Error detail -> Alcotest.failf "candidate fixture invalid: %s" detail
;;

let judgment decision : A.judgment =
  { verdict = { J.decision = decision; rationale = "typed structured verdict" }
  ; runtime_id = "configured-structured-judge"
  ; judged_at = 101.0
  }
;;

let record_or_fail ~base_path candidate =
  match A.record ~base_path candidate with
  | A.Recorded persisted -> persisted
  | A.Duplicate _ -> Alcotest.fail "first candidate record was a duplicate"
  | A.Record_error detail -> Alcotest.failf "candidate record failed: %s" detail
;;

let only_loaded ~base_path ~keeper_name =
  match A.load_candidates ~base_path ~keeper_name with
  | Ok [ candidate ] -> candidate
  | Ok candidates ->
    Alcotest.failf "expected one latest candidate, got %d" (List.length candidates)
  | Error detail -> Alcotest.failf "candidate load failed: %s" detail
;;

let test_roundtrip_preserves_full_evidence_and_pending_state () =
  let candidate = candidate () in
  (match candidate.status with
   | A.Pending { last_failure = None } -> ()
   | A.Pending { last_failure = Some _ } | A.Judged _ | A.Consumed _ ->
     Alcotest.fail "new candidate was not clean Pending");
  let request_fields =
    match candidate.judgment_request with
    | `Assoc fields -> fields
    | _ -> Alcotest.fail "judgment request must be an object"
  in
  Alcotest.(check bool)
    "full post evidence"
    true
    (List.mem_assoc "post" request_fields);
  (match List.assoc_opt "comments" request_fields with
   | Some (`List [ `Assoc comment_fields ]) ->
     Alcotest.(check bool)
       "full comment content"
       true
       (List.mem_assoc "content" comment_fields)
   | _ -> Alcotest.fail "full comment list missing");
  Alcotest.(check bool)
    "Keeper Goal Task lane context"
    true
    (List.mem_assoc "keeper_context" request_fields);
  match A.candidate_of_json (A.candidate_to_json candidate) with
  | Ok decoded -> Alcotest.(check bool) "strict roundtrip" true (decoded = candidate)
  | Error detail -> Alcotest.failf "candidate decode failed: %s" detail
;;

let test_record_dedupes_exact_candidate_identity () =
  with_temp_base "keeper-board-attention-dedup" @@ fun base_path ->
  let first = candidate () in
  let duplicate = candidate () in
  ignore (record_or_fail ~base_path first : A.candidate);
  (match A.record ~base_path duplicate with
   | A.Duplicate existing ->
     Alcotest.(check string)
       "same exact signal id"
       first.candidate_id
       existing.candidate_id
   | A.Recorded _ -> Alcotest.fail "exact duplicate appended as a new candidate"
   | A.Record_error detail -> Alcotest.failf "duplicate check failed: %s" detail);
  ignore (only_loaded ~base_path ~keeper_name:first.keeper_name : A.candidate)
;;

let test_retryable_judge_failure_remains_pending () =
  with_temp_base "keeper-board-attention-retry" @@ fun base_path ->
  let pending = record_or_fail ~base_path (candidate ()) in
  let failure : A.retryable_failure =
    { kind = A.Provider_unavailable
    ; detail = "provider unavailable"
    ; failed_at = 102.0
    }
  in
  let current =
    match
      A.process_with_judge
        ~base_path
        ~judge:(fun _ -> Error failure)
        pending
    with
    | Ok candidate -> candidate
    | Error detail -> Alcotest.failf "retryable transition failed: %s" detail
  in
  match current.status with
  | A.Pending { last_failure = Some observed } ->
    Alcotest.(check string)
      "typed failure preserved"
      "provider_unavailable"
      (A.retryable_failure_kind_to_string observed.kind)
  | A.Pending { last_failure = None } | A.Judged _ | A.Consumed _ ->
    Alcotest.fail "retryable judge failure consumed the candidate"
;;

let test_not_relevant_transitions_directly_to_consumed () =
  with_temp_base "keeper-board-attention-not-relevant" @@ fun base_path ->
  let pending = record_or_fail ~base_path (candidate ()) in
  let current =
    match
      A.process_with_judge
        ~base_path
        ~judge:(fun _ -> Ok (judgment J.Not_relevant))
        pending
    with
    | Ok candidate -> candidate
    | Error detail -> Alcotest.failf "not-relevant transition failed: %s" detail
  in
  (match current.status with
   | A.Consumed { delivery = A.Not_relevant; _ } -> ()
   | A.Consumed _ | A.Pending _ | A.Judged _ ->
     Alcotest.fail "not-relevant verdict did not reach Consumed");
  let queue =
    Keeper_event_queue_persistence.load
      ~base_path
      ~keeper_name:current.keeper_name
  in
  Alcotest.(check int)
    "not relevant does not enqueue"
    0
    (Keeper_event_queue.length queue)
;;

let test_relevant_consumes_only_after_exact_durable_enqueue () =
  with_temp_base "keeper-board-attention-relevant" @@ fun base_path ->
  let pending = record_or_fail ~base_path (candidate ()) in
  let current =
    match
      A.process_with_judge
        ~base_path
        ~judge:(fun _ -> Ok (judgment J.Relevant))
        pending
    with
    | Ok candidate -> candidate
    | Error detail -> Alcotest.failf "relevant transition failed: %s" detail
  in
  (match current.status with
   | A.Consumed { delivery = A.Enqueued_to_keeper_lane; _ } -> ()
   | A.Consumed _ | A.Pending _ | A.Judged _ ->
     Alcotest.fail "relevant verdict consumed before durable delivery");
  let queue =
    Keeper_event_queue_persistence.load
      ~base_path
      ~keeper_name:current.keeper_name
    |> Keeper_event_queue.to_list
  in
  (match queue with
   | [ { payload = Keeper_event_queue.Board_attention attention; _ } ] ->
     Alcotest.(check string)
       "opaque candidate identity persisted"
       current.candidate_id
       attention.candidate_id
   | _ -> Alcotest.fail "relevant candidate did not persist one Board_attention event");
  let replayed =
    match
      A.process_with_judge
        ~base_path
        ~judge:(fun _ -> Alcotest.fail "Consumed candidate invoked judge")
        current
    with
    | Ok candidate -> candidate
    | Error detail -> Alcotest.failf "Consumed replay failed: %s" detail
  in
  Alcotest.(check bool) "Consumed replay is idempotent" true (replayed = current)
;;

let test_delivery_storage_error_retains_judged_state () =
  with_temp_base "keeper-board-attention-delivery-error" @@ fun base_path ->
  let pending = record_or_fail ~base_path (candidate ()) in
  let keepers_path =
    Filename.concat (Common.masc_dir_from_base_path ~base_path) "keepers"
  in
  let oc = open_out_bin keepers_path in
  output_string oc "event queue directory blocker";
  close_out oc;
  let current =
    match
      A.process_with_judge
        ~base_path
        ~judge:(fun _ -> Ok (judgment J.Relevant))
        pending
    with
    | Ok candidate -> candidate
    | Error detail -> Alcotest.failf "delivery failure transition failed: %s" detail
  in
  match current.status with
  | A.Judged
      { last_failure = Some { kind = A.Durable_delivery_unavailable; _ }; _ } ->
    ()
  | A.Judged _ | A.Pending _ | A.Consumed _ ->
    Alcotest.fail "durable delivery storage error did not retain Judged"
;;

let test_malformed_ledger_is_explicit_and_not_overwritten () =
  with_temp_base "keeper-board-attention-malformed" @@ fun base_path ->
  let keeper_name = "sangsu" in
  let dir =
    Filename.concat
      (Common.masc_dir_from_base_path ~base_path)
      "board_attention_candidates"
  in
  Fs_compat.mkdir_p dir;
  let path = Filename.concat dir (keeper_name ^ ".jsonl") in
  let malformed = "{not-json\n" in
  let oc = open_out_bin path in
  output_string oc malformed;
  close_out oc;
  (match A.load_candidates ~base_path ~keeper_name with
   | Error detail -> Alcotest.(check bool) "error detail" true (String.length detail > 0)
   | Ok _ -> Alcotest.fail "malformed ledger was silently skipped");
  (match A.record ~base_path (candidate ~keeper_name ()) with
   | A.Record_error _ -> ()
   | A.Recorded _ | A.Duplicate _ -> Alcotest.fail "malformed ledger was overwritten");
  let ic = open_in_bin path in
  let preserved = really_input_string ic (in_channel_length ic) in
  close_in ic;
  Alcotest.(check string) "malformed bytes preserved" malformed preserved
;;

let test_strict_judgment_contract_rejects_extra_fields () =
  let invalid =
    `Assoc
      [ "decision", `String "relevant"
      ; "rationale", `String "because"
      ; "score", `Int 100
      ]
  in
  match J.of_yojson invalid with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "structured judgment accepted an undeclared score"
;;

let () =
  Alcotest.run
    "keeper_board_attention_candidate"
    [ ( "durable judgment"
      , [ Alcotest.test_case
            "roundtrip preserves full evidence and Pending"
            `Quick
            test_roundtrip_preserves_full_evidence_and_pending_state
        ; Alcotest.test_case
            "record dedupes exact candidate identity"
            `Quick
            test_record_dedupes_exact_candidate_identity
        ; Alcotest.test_case
            "retryable judge failure remains Pending"
            `Quick
            test_retryable_judge_failure_remains_pending
        ; Alcotest.test_case
            "not relevant transitions directly to Consumed"
            `Quick
            test_not_relevant_transitions_directly_to_consumed
        ; Alcotest.test_case
            "relevant consumes only after exact durable enqueue"
            `Quick
            test_relevant_consumes_only_after_exact_durable_enqueue
        ; Alcotest.test_case
            "delivery storage error retains Judged"
            `Quick
            test_delivery_storage_error_retains_judged_state
        ; Alcotest.test_case
            "malformed ledger is explicit and preserved"
            `Quick
            test_malformed_ledger_is_explicit_and_not_overwritten
        ; Alcotest.test_case
            "strict judgment rejects undeclared score"
            `Quick
            test_strict_judgment_contract_rejects_extra_fields
        ] )
    ]
;;
