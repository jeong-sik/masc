module A = Masc.Keeper_board_attention_candidate
module J = Masc.Keeper_board_attention_judgment
module Retry = Llm_provider.Retry

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

(* Small, fast-moving policy shared by the retry-gate tests: retry_base=10s
   doubling to a retry_max=40s cap, budget of 3 attempts, and a generous
   pending-age ceiling so only the dedicated expiry test crosses it. *)
let test_policy : A.retry_policy =
  { retry_base_sec = 10.0
  ; retry_max_sec = 40.0
  ; max_attempts = 3
  ; max_pending_age_sec = 1000.0
  }
;;

(* Same shape as [test_policy] but with headroom on [max_attempts] so the
   backoff-growth test can observe three successive doublings without hitting
   the budget wall. *)
let backoff_policy : A.retry_policy = { test_policy with max_attempts = 10 }

let block_keepers_path base_path =
  let keepers_path = Filename.concat (Common.masc_dir_from_base_path ~base_path) "keepers" in
  let oc = open_out_bin keepers_path in
  output_string oc "event queue directory blocker";
  close_out oc
;;

let unblock_keepers_path base_path =
  let keepers_path = Filename.concat (Common.masc_dir_from_base_path ~base_path) "keepers" in
  Sys.remove keepers_path
;;

let test_roundtrip_preserves_full_evidence_and_pending_state () =
  let candidate = candidate () in
  (match candidate.status with
   | A.Pending { last_failure = None } -> ()
   | A.Pending { last_failure = Some _ } | A.Judged _ | A.Deferred _
   | A.Consumed _ | A.Terminal_failed _ ->
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

let test_legacy_pending_row_loads_unchanged () =
  with_temp_base "keeper-board-attention-legacy-pending" @@ fun base_path ->
  let fixture = candidate () in
  let keeper_name = fixture.keeper_name in
  let dir =
    Filename.concat (Common.masc_dir_from_base_path ~base_path) "board_attention_candidates"
  in
  Fs_compat.mkdir_p dir;
  let path = Filename.concat dir (keeper_name ^ ".jsonl") in
  (* Hand-typed row in the pre-redesign wire shape: only
     pending/judged/consumed existed, with none of the new fields this phase
     adds. A pre-existing ledger written by an older binary must still parse. *)
  let legacy_json =
    `Assoc
      [ "candidate_id", `String fixture.candidate_id
      ; "keeper_name", `String fixture.keeper_name
      ; "signal", A.signal_to_yojson fixture.signal
      ; "judgment_request", fixture.judgment_request
      ; "recorded_at", `Float fixture.recorded_at
      ; "status", `Assoc [ "kind", `String "pending"; "last_failure", `Null ]
      ]
  in
  let oc = open_out_bin path in
  output_string oc (Yojson.Safe.to_string legacy_json ^ "\n");
  close_out oc;
  match A.load_candidates ~base_path ~keeper_name with
  | Ok [ loaded ] ->
    Alcotest.(check string) "legacy candidate_id preserved" fixture.candidate_id loaded.candidate_id;
    (match loaded.status with
     | A.Pending { last_failure = None } -> ()
     | A.Pending { last_failure = Some _ } | A.Judged _ | A.Deferred _
     | A.Consumed _ | A.Terminal_failed _ ->
       Alcotest.fail "legacy pending row did not load as clean Pending")
  | Ok candidates ->
    Alcotest.failf "expected exactly one legacy candidate, got %d" (List.length candidates)
  | Error detail -> Alcotest.failf "legacy row failed to load: %s" detail
;;

let test_deferred_judge_strict_roundtrip () =
  let candidate =
    { (candidate ()) with
      status =
        A.Deferred
          { resume = A.Resume_judge
          ; failure = { kind = A.Provider_unavailable; detail = "provider unavailable"; failed_at = 102.0 }
          ; retry = { not_before = 200.0; attempts = 2 }
          }
    }
  in
  match A.candidate_of_json (A.candidate_to_json candidate) with
  | Ok decoded -> Alcotest.(check bool) "deferred/judge strict roundtrip" true (decoded = candidate)
  | Error detail -> Alcotest.failf "deferred/judge decode failed: %s" detail
;;

let test_deferred_delivery_strict_roundtrip () =
  let carried_judgment = judgment J.Relevant in
  let candidate =
    { (candidate ()) with
      status =
        A.Deferred
          { resume = A.Resume_delivery carried_judgment
          ; failure =
              { kind = A.Durable_delivery_unavailable
              ; detail = "storage unavailable"
              ; failed_at = 103.0
              }
          ; retry = { not_before = 250.0; attempts = 1 }
          }
    }
  in
  match A.candidate_of_json (A.candidate_to_json candidate) with
  | Ok decoded -> Alcotest.(check bool) "deferred/delivery strict roundtrip" true (decoded = candidate)
  | Error detail -> Alcotest.failf "deferred/delivery decode failed: %s" detail
;;

let test_terminal_states_strict_roundtrip () =
  let base = candidate () in
  let variants : (string * A.terminal_reason) list =
    [ "judge_rejected", A.Judge_rejected { class_ = A.Invalid_request; detail = "bad request shape" }
    ; ( "retry_budget_exhausted"
      , A.Retry_budget_exhausted
          { last = { kind = A.Provider_unavailable; detail = "still failing"; failed_at = 104.0 }
          ; attempts = 8
          } )
    ; "expired_backlog", A.Expired_backlog { age_s = 400000.0; max_age_s = 259200.0 }
    ]
  in
  List.iter
    (fun (label, reason) ->
       let candidate = { base with status = A.Terminal_failed { reason; failed_at = 105.0 } } in
       match A.candidate_of_json (A.candidate_to_json candidate) with
       | Ok decoded -> Alcotest.(check bool) (label ^ " strict roundtrip") true (decoded = candidate)
       | Error detail -> Alcotest.failf "%s decode failed: %s" label detail)
    variants
;;

let wrap_status base_candidate status_json =
  `Assoc
    [ "candidate_id", `String base_candidate.A.candidate_id
    ; "keeper_name", `String base_candidate.A.keeper_name
    ; "signal", A.signal_to_yojson base_candidate.A.signal
    ; "judgment_request", base_candidate.A.judgment_request
    ; "recorded_at", `Float base_candidate.A.recorded_at
    ; "status", status_json
    ]
;;

let test_deferred_exact_fields_rejects_extras () =
  let base = candidate () in
  let status_with_extra =
    `Assoc
      [ "kind", `String "deferred"
      ; "resume", `Assoc [ "kind", `String "judge" ]
      ; ( "failure"
        , `Assoc
            [ "kind", `String "provider_unavailable"
            ; "detail", `String "x"
            ; "failed_at", `Float 1.0
            ] )
      ; "not_before", `Float 2.0
      ; "attempts", `Int 1
      ; "unexpected", `Bool true
      ]
  in
  match A.candidate_of_json (wrap_status base status_with_extra) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "deferred status accepted an undeclared field"
;;

let test_terminal_failed_exact_fields_rejects_extras () =
  let base = candidate () in
  let status_with_extra =
    `Assoc
      [ "kind", `String "terminal_failed"
      ; ( "reason"
        , `Assoc
            [ "kind", `String "expired_backlog"
            ; "age_s", `Float 400000.0
            ; "max_age_s", `Float 259200.0
            ] )
      ; "failed_at", `Float 105.0
      ; "unexpected", `String "surplus"
      ]
  in
  match A.candidate_of_json (wrap_status base status_with_extra) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "terminal_failed status accepted an undeclared field"
;;

let test_judge_retryable_with_provider_hint_honors_retry_after () =
  with_temp_base "keeper-board-attention-retry-after" @@ fun base_path ->
  let pending = record_or_fail ~base_path (candidate ()) in
  let now () = 1000.0 in
  let outcome =
    A.Judge_retryable
      { failure = { kind = A.Provider_unavailable; detail = "rate limited"; failed_at = 1000.0 }
      ; retry_after = Some 42.0
      }
  in
  match A.process_with_judge ~base_path ~now ~policy:test_policy ~judge:(fun _ -> Error outcome) pending with
  | Ok { status = A.Deferred { resume = A.Resume_judge; retry = { not_before; attempts = 1 }; _ }; _ } ->
    Alcotest.(check (float 0.0001)) "retry-after hint honored exactly" 1042.0 not_before
  | Ok _ -> Alcotest.fail "retry-after hint was not honored"
  | Error detail -> Alcotest.failf "retryable transition failed: %s" detail
;;

let test_judge_retryable_backs_off_with_capped_exponential_growth () =
  with_temp_base "keeper-board-attention-backoff" @@ fun base_path ->
  let pending = record_or_fail ~base_path (candidate ()) in
  let now_ref = ref 1000.0 in
  let now () = !now_ref in
  let retryable () =
    A.Judge_retryable
      { failure = { kind = A.Provider_unavailable; detail = "backoff probe"; failed_at = !now_ref }
      ; retry_after = None
      }
  in
  (* retry_base=10s doubling to retry_max=40s: attempts 0,1,2 -> 10,20,40. *)
  let expected_caps = [ 10.0; 20.0; 40.0 ] in
  ignore
    (List.fold_left
       (fun current expected_cap ->
          let judge_calls = ref 0 in
          match
            A.process_with_judge
              ~base_path
              ~now
              ~policy:backoff_policy
              ~judge:(fun _ ->
                 incr judge_calls;
                 Error (retryable ()))
              current
          with
          | Ok ({ status = A.Deferred { retry = { not_before; _ }; _ }; _ } as updated) ->
            Alcotest.(check int) "judge invoked exactly once per due attempt" 1 !judge_calls;
            let delta = not_before -. !now_ref in
            Alcotest.(check bool)
              (Printf.sprintf "delta >= base cap %.1f" expected_cap)
              true
              (delta >= expected_cap -. 0.0001);
            Alcotest.(check bool)
              (Printf.sprintf "delta <= cap %.1f plus jitter headroom" expected_cap)
              true
              (delta <= (expected_cap *. 1.10001));
            now_ref := not_before +. 0.001;
            updated
          | Ok _ -> Alcotest.fail "expected Deferred{Resume_judge} mid-backoff"
          | Error detail -> Alcotest.failf "backoff transition failed: %s" detail)
       pending
       expected_caps
     : A.candidate)
;;

let test_deferred_before_not_before_skips_judge () =
  with_temp_base "keeper-board-attention-not-due" @@ fun base_path ->
  let pending = record_or_fail ~base_path (candidate ()) in
  let candidate_before =
    { pending with
      status =
        A.Deferred
          { resume = A.Resume_judge
          ; failure = { kind = A.Provider_unavailable; detail = "prior failure"; failed_at = 900.0 }
          ; retry = { not_before = 2000.0; attempts = 1 }
          }
    }
  in
  (* Stay well under [test_policy.max_pending_age_sec] (1000s past
     recorded_at=100.0) so the expiry check does not preempt the not_before
     gate this test exercises. *)
  let now () = 500.0 in
  match
    A.process_with_judge
      ~base_path
      ~now
      ~policy:test_policy
      ~judge:(fun _ -> Alcotest.fail "judge invoked before the retry gate was due")
      candidate_before
  with
  | Ok unchanged ->
    Alcotest.(check bool) "not-due Deferred row is unchanged" true (unchanged = candidate_before)
  | Error detail -> Alcotest.failf "not-due Deferred transition failed: %s" detail
;;

let test_due_deferred_reinvokes_judge () =
  with_temp_base "keeper-board-attention-due" @@ fun base_path ->
  let pending = record_or_fail ~base_path (candidate ()) in
  let candidate_before =
    { pending with
      status =
        A.Deferred
          { resume = A.Resume_judge
          ; failure = { kind = A.Provider_unavailable; detail = "prior failure"; failed_at = 900.0 }
          ; retry = { not_before = 1000.0; attempts = 1 }
          }
    }
  in
  let judge_calls = ref 0 in
  let now () = 1000.0 in
  match
    A.process_with_judge
      ~base_path
      ~now
      ~policy:test_policy
      ~judge:(fun _ ->
         incr judge_calls;
         Ok (judgment J.Not_relevant))
      candidate_before
  with
  | Ok { status = A.Consumed { delivery = A.Not_relevant; _ }; _ } ->
    Alcotest.(check int) "judge invoked exactly once for the due retry" 1 !judge_calls
  | Ok _ -> Alcotest.fail "due Deferred did not re-judge"
  | Error detail -> Alcotest.failf "due Deferred transition failed: %s" detail
;;

let test_permanent_judge_error_terminalizes_and_absorbs () =
  with_temp_base "keeper-board-attention-permanent" @@ fun base_path ->
  let pending = record_or_fail ~base_path (candidate ()) in
  let now () = 1000.0 in
  let permanent = A.Judge_permanent { class_ = A.Invalid_request; detail = "malformed request shape" } in
  let terminalized =
    match A.process_with_judge ~base_path ~now ~policy:test_policy ~judge:(fun _ -> Error permanent) pending with
    | Ok candidate -> candidate
    | Error detail -> Alcotest.failf "permanent transition failed: %s" detail
  in
  (match terminalized.status with
   | A.Terminal_failed { reason = A.Judge_rejected { class_ = A.Invalid_request; _ }; _ } -> ()
   | A.Terminal_failed _ | A.Pending _ | A.Judged _ | A.Deferred _ | A.Consumed _ ->
     Alcotest.fail "permanent judge error did not terminalize with Judge_rejected");
  let replayed =
    match
      A.process_with_judge
        ~base_path
        ~now
        ~policy:test_policy
        ~judge:(fun _ -> Alcotest.fail "Terminal_failed candidate invoked judge")
        terminalized
    with
    | Ok candidate -> candidate
    | Error detail -> Alcotest.failf "Terminal_failed replay failed: %s" detail
  in
  Alcotest.(check bool) "Terminal_failed replay is idempotent" true (replayed = terminalized)
;;

let test_retry_budget_exhaustion_terminalizes () =
  with_temp_base "keeper-board-attention-budget" @@ fun base_path ->
  let pending = record_or_fail ~base_path (candidate ()) in
  let now_ref = ref 1000.0 in
  let now () = !now_ref in
  let retryable () =
    A.Judge_retryable
      { failure = { kind = A.Provider_unavailable; detail = "still failing"; failed_at = !now_ref }
      ; retry_after = None
      }
  in
  let step current =
    match
      A.process_with_judge ~base_path ~now ~policy:test_policy ~judge:(fun _ -> Error (retryable ())) current
    with
    | Ok updated -> updated
    | Error detail -> Alcotest.failf "budget-exhaustion transition failed: %s" detail
  in
  let after_first = step pending in
  (match after_first.status with
   | A.Deferred { retry = { attempts = 1; not_before }; _ } -> now_ref := not_before +. 0.001
   | A.Deferred _ | A.Pending _ | A.Judged _ | A.Consumed _ | A.Terminal_failed _ ->
     Alcotest.fail "first retryable failure did not defer with attempts=1");
  let after_second = step after_first in
  (match after_second.status with
   | A.Deferred { retry = { attempts = 2; not_before }; _ } -> now_ref := not_before +. 0.001
   | A.Deferred _ | A.Pending _ | A.Judged _ | A.Consumed _ | A.Terminal_failed _ ->
     Alcotest.fail "second retryable failure did not defer with attempts=2");
  let after_third = step after_second in
  match after_third.status with
  | A.Terminal_failed { reason = A.Retry_budget_exhausted { attempts = 3; _ }; _ } -> ()
  | A.Terminal_failed _ | A.Pending _ | A.Judged _ | A.Deferred _ | A.Consumed _ ->
    Alcotest.fail "third retryable failure did not exhaust the retry budget"
;;

let test_not_relevant_transitions_directly_to_consumed () =
  with_temp_base "keeper-board-attention-not-relevant" @@ fun base_path ->
  let pending = record_or_fail ~base_path (candidate ()) in
  let now () = 1000.0 in
  let current =
    match
      A.process_with_judge
        ~base_path
        ~now
        ~policy:test_policy
        ~judge:(fun _ -> Ok (judgment J.Not_relevant))
        pending
    with
    | Ok candidate -> candidate
    | Error detail -> Alcotest.failf "not-relevant transition failed: %s" detail
  in
  (match current.status with
   | A.Consumed { delivery = A.Not_relevant; _ } -> ()
   | A.Consumed _ | A.Pending _ | A.Judged _ | A.Deferred _ | A.Terminal_failed _ ->
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
  let now () = 1000.0 in
  let current =
    match
      A.process_with_judge
        ~base_path
        ~now
        ~policy:test_policy
        ~judge:(fun _ -> Ok (judgment J.Relevant))
        pending
    with
    | Ok candidate -> candidate
    | Error detail -> Alcotest.failf "relevant transition failed: %s" detail
  in
  (match current.status with
   | A.Consumed { delivery = A.Enqueued_to_keeper_lane; _ } -> ()
   | A.Consumed _ | A.Pending _ | A.Judged _ | A.Deferred _ | A.Terminal_failed _ ->
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
        ~now
        ~policy:test_policy
        ~judge:(fun _ -> Alcotest.fail "Consumed candidate invoked judge")
        current
    with
    | Ok candidate -> candidate
    | Error detail -> Alcotest.failf "Consumed replay failed: %s" detail
  in
  Alcotest.(check bool) "Consumed replay is idempotent" true (replayed = current)
;;

let test_delivery_failure_defers_and_retries_without_rejudge () =
  with_temp_base "keeper-board-attention-delivery-defer" @@ fun base_path ->
  let pending = record_or_fail ~base_path (candidate ()) in
  block_keepers_path base_path;
  let now_ref = ref 1000.0 in
  let now () = !now_ref in
  let judge_calls = ref 0 in
  let judge _ =
    incr judge_calls;
    Ok (judgment J.Relevant)
  in
  let after_first =
    match A.process_with_judge ~base_path ~now ~policy:test_policy ~judge pending with
    | Ok candidate -> candidate
    | Error detail -> Alcotest.failf "delivery-failure transition failed: %s" detail
  in
  Alcotest.(check int) "judge invoked exactly once before delivery failed" 1 !judge_calls;
  let preserved_runtime_id =
    match after_first.status with
    | A.Deferred
        { resume = A.Resume_delivery delivered_judgment
        ; retry = { attempts = 1; not_before }
        ; _
        } ->
      now_ref := not_before +. 0.001;
      delivered_judgment.runtime_id
    | A.Deferred _ | A.Pending _ | A.Judged _ | A.Consumed _ | A.Terminal_failed _ ->
      Alcotest.fail "delivery failure did not defer with the judgment preserved"
  in
  unblock_keepers_path base_path;
  let after_second =
    match
      A.process_with_judge
        ~base_path
        ~now
        ~policy:test_policy
        ~judge:(fun _ -> Alcotest.fail "delivery retry re-invoked judge")
        after_first
    with
    | Ok candidate -> candidate
    | Error detail -> Alcotest.failf "delivery retry transition failed: %s" detail
  in
  match after_second.status with
  | A.Consumed { judgment = delivered; delivery = A.Enqueued_to_keeper_lane; _ } ->
    Alcotest.(check string) "same judgment delivered" preserved_runtime_id delivered.runtime_id
  | A.Consumed _ | A.Pending _ | A.Judged _ | A.Deferred _ | A.Terminal_failed _ ->
    Alcotest.fail "delivery retry did not consume once unblocked"
;;

let test_expired_backlog_terminalizes_without_judging () =
  with_temp_base "keeper-board-attention-expired" @@ fun base_path ->
  let pending = record_or_fail ~base_path (candidate ()) in
  let now () = pending.recorded_at +. test_policy.max_pending_age_sec +. 1.0 in
  match
    A.process_with_judge
      ~base_path
      ~now
      ~policy:test_policy
      ~judge:(fun _ -> Alcotest.fail "judge invoked for expired backlog")
      pending
  with
  | Ok { status = A.Terminal_failed { reason = A.Expired_backlog { max_age_s; _ }; _ }; _ } ->
    Alcotest.(check (float 0.0001)) "expiry policy recorded" test_policy.max_pending_age_sec max_age_s
  | Ok _ -> Alcotest.fail "stale backlog did not terminalize with Expired_backlog"
  | Error detail -> Alcotest.failf "expiry transition failed: %s" detail
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

let count_ledger_lines base_path =
  let dir =
    Filename.concat
      (Filename.concat base_path ".masc")
      "board_attention_candidates"
  in
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun name -> Filename.check_suffix name ".jsonl")
  |> List.fold_left
       (fun total name ->
         let channel = open_in (Filename.concat dir name) in
         Fun.protect
           ~finally:(fun () -> close_in channel)
           (fun () ->
             let rec loop count =
               match input_line channel with
               | (_ : string) -> loop (count + 1)
               | exception End_of_file -> count
             in
             total + loop 0))
       0
;;

let test_update_ledger_compacts_to_distinct () =
  with_temp_base "keeper-board-attention-compaction" @@ fun base_path ->
  let pending = record_or_fail ~base_path (candidate ()) in
  let keeper_name = pending.keeper_name in
  (* Drive several retryable judge failures against the same candidate id via
     process_with_judge (each commits a Deferred update through update_ledger).
     Before compaction the ledger grew by one row per update (and each update
     re-parsed the whole ledger, so writes were O(n^2)); this proves it still
     holds exactly one row per distinct candidate_id. *)
  let transitions = 6 in
  let now_ref = ref 1000.0 in
  let now () = !now_ref in
  (* max_pending_age_sec widened well past what 6 capped-exponential
     transitions accumulate (test_policy's default would expire the
     candidate partway through the drive). *)
  let policy : A.retry_policy =
    { test_policy with max_attempts = transitions + 2; max_pending_age_sec = 100_000.0 }
  in
  let retryable index =
    A.Judge_retryable
      { failure =
          { kind = A.Provider_unavailable
          ; detail = Printf.sprintf "provider unavailable %d" index
          ; failed_at = !now_ref
          }
      ; retry_after = None
      }
  in
  ignore
    (List.fold_left
       (fun current index ->
          match
            A.process_with_judge
              ~base_path
              ~now
              ~policy
              ~judge:(fun _ -> Error (retryable index))
              current
          with
          | Ok ({ status = A.Deferred { retry = { not_before; _ }; _ }; _ } as updated) ->
            now_ref := not_before +. 0.001;
            updated
          | Ok _ -> Alcotest.fail "expected Deferred mid-compaction drive"
          | Error detail -> Alcotest.failf "failure %d not recorded: %s" index detail)
       pending
       (List.init transitions Fun.id)
     : A.candidate);
  Alcotest.(check int)
    "ledger holds one row per distinct candidate_id"
    1
    (count_ledger_lines base_path);
  match A.load_candidates ~base_path ~keeper_name with
  | Ok [ latest ] ->
    (match latest.status with
     | A.Deferred { failure = observed; retry = { attempts; _ }; _ } ->
       Alcotest.(check string)
         "latest failure wins after compaction"
         (Printf.sprintf "provider unavailable %d" (transitions - 1))
         observed.detail;
       Alcotest.(check int) "attempts accumulate across compacted updates" transitions attempts
     | A.Pending _ | A.Judged _ | A.Consumed _ | A.Terminal_failed _ ->
       Alcotest.fail "compaction dropped the latest deferred state")
  | Ok candidates ->
    Alcotest.failf "expected one compacted candidate, got %d" (List.length candidates)
  | Error detail -> Alcotest.failf "load after compaction failed: %s" detail
;;

let test_classify_judge_sdk_error_matches_provider_domain () =
  let check_retryable label error =
    match A.classify_judge_sdk_error error with
    | A.Judge_retryable _ -> ()
    | A.Judge_permanent _ -> Alcotest.failf "%s classified as permanent" label
  in
  let check_permanent label expected_class error =
    match A.classify_judge_sdk_error error with
    | A.Judge_permanent { class_; _ } ->
      Alcotest.(check bool) (label ^ " permanent class") true (class_ = expected_class)
    | A.Judge_retryable _ -> Alcotest.failf "%s classified as retryable" label
  in
  (* Provider errors with an explicit retry-after or no hint: retryable. *)
  check_retryable
    "rate_limited"
    (Agent_sdk.Error.Api (Retry.RateLimited { retry_after = Some 5.0; message = "rate limited" }));
  check_retryable "overloaded" (Agent_sdk.Error.Api (Retry.Overloaded { message = "overloaded" }));
  check_retryable
    "server_error"
    (Agent_sdk.Error.Api (Retry.ServerError { status = 500; message = "server error" }));
  check_retryable
    "network_error"
    (Agent_sdk.Error.Api
       (NetworkError { message = "refused"; kind = Llm_provider.Http_client.Connection_refused }));
  check_retryable
    "provider_timeout"
    (Agent_sdk.Error.Api (Timeout { message = "deadline"; phase = Some Llm_provider.Http_client.Wall_clock }));
  check_retryable
    "streaming_timeout"
    (Agent_sdk.Error.Api
       (Timeout { message = "no first token"; phase = Some Llm_provider.Http_client.First_token }));
  (* Provider rejections that repeat identically without operator
     intervention: permanent, with the exact class carried through. *)
  check_permanent
    "auth_error"
    A.Auth
    (Agent_sdk.Error.Api (Retry.AuthError { message = "bad credential" }));
  check_permanent
    "authorization_error"
    A.Authorization
    (Agent_sdk.Error.Api (Retry.AuthorizationError { message = "forbidden" }));
  check_permanent
    "payment_required"
    A.Payment_required
    (Agent_sdk.Error.Api (Retry.PaymentRequired { message = "quota exhausted" }));
  check_permanent
    "invalid_request"
    A.Invalid_request
    (Agent_sdk.Error.Api
       (Retry.InvalidRequest { message = "bad shape"; reason = Retry.Unknown_invalid_request }));
  check_permanent "not_found" A.Not_found (Agent_sdk.Error.Api (Retry.NotFound { message = "missing model" }));
  check_permanent
    "context_overflow"
    A.Context_overflow
    (Agent_sdk.Error.Api (ContextOverflow { message = "too large"; limit = Some 131072 }));
  (* Non-provider SDK domains: environment/operator-fixable, retryable via the
     same attempt budget rather than a permanent judge rejection. *)
  check_retryable "internal" (Agent_sdk.Error.Internal "unclassified fault");
  check_retryable
    "missing_env_var"
    (Agent_sdk.Error.Config (Agent_sdk.Error.MissingEnvVar { var_name = "OAS_KEY" }));
  check_retryable
    "mcp_init_failed"
    (Agent_sdk.Error.Mcp (Agent_sdk.Error.InitializeFailed { detail = "mcp down" }));
  check_retryable
    "serialization"
    (Agent_sdk.Error.Serialization (Agent_sdk.Error.JsonParseError { detail = "bad json" }));
  check_retryable
    "unrecognized_stop_reason"
    (Agent_sdk.Error.Agent (Agent_sdk.Error.UnrecognizedStopReason { reason = "weird stop" }))
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
            "legacy pending row loads unchanged"
            `Quick
            test_legacy_pending_row_loads_unchanged
        ; Alcotest.test_case
            "deferred/judge strict roundtrip"
            `Quick
            test_deferred_judge_strict_roundtrip
        ; Alcotest.test_case
            "deferred/delivery strict roundtrip"
            `Quick
            test_deferred_delivery_strict_roundtrip
        ; Alcotest.test_case
            "terminal states strict roundtrip"
            `Quick
            test_terminal_states_strict_roundtrip
        ; Alcotest.test_case
            "deferred status rejects undeclared fields"
            `Quick
            test_deferred_exact_fields_rejects_extras
        ; Alcotest.test_case
            "terminal_failed status rejects undeclared fields"
            `Quick
            test_terminal_failed_exact_fields_rejects_extras
        ; Alcotest.test_case
            "provider retry-after hint sets the exact not_before"
            `Quick
            test_judge_retryable_with_provider_hint_honors_retry_after
        ; Alcotest.test_case
            "no-hint retryable failure backs off with a capped exponential"
            `Quick
            test_judge_retryable_backs_off_with_capped_exponential_growth
        ; Alcotest.test_case
            "Deferred row not yet due skips the judge call"
            `Quick
            test_deferred_before_not_before_skips_judge
        ; Alcotest.test_case
            "due Deferred row re-invokes the judge"
            `Quick
            test_due_deferred_reinvokes_judge
        ; Alcotest.test_case
            "permanent judge error terminalizes and absorbs replay"
            `Quick
            test_permanent_judge_error_terminalizes_and_absorbs
        ; Alcotest.test_case
            "retry budget exhaustion terminalizes"
            `Quick
            test_retry_budget_exhaustion_terminalizes
        ; Alcotest.test_case
            "not relevant transitions directly to Consumed"
            `Quick
            test_not_relevant_transitions_directly_to_consumed
        ; Alcotest.test_case
            "relevant consumes only after exact durable enqueue"
            `Quick
            test_relevant_consumes_only_after_exact_durable_enqueue
        ; Alcotest.test_case
            "delivery failure defers and retries without re-judging"
            `Quick
            test_delivery_failure_defers_and_retries_without_rejudge
        ; Alcotest.test_case
            "expired backlog terminalizes without judging"
            `Quick
            test_expired_backlog_terminalizes_without_judging
        ; Alcotest.test_case
            "malformed ledger is explicit and preserved"
            `Quick
            test_malformed_ledger_is_explicit_and_not_overwritten
        ; Alcotest.test_case
            "strict judgment rejects undeclared score"
            `Quick
            test_strict_judgment_contract_rejects_extra_fields
        ; Alcotest.test_case
            "update ledger compacts to distinct candidate count"
            `Quick
            test_update_ledger_compacts_to_distinct
        ; Alcotest.test_case
            "judge SDK error classifier is exhaustive over Error_domain"
            `Quick
            test_classify_judge_sdk_error_matches_provider_domain
        ] )
    ]
;;
