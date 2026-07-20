module A = Masc.Keeper_board_attention_candidate
module J = Masc.Keeper_board_attention_judgment
module P = Masc.Keeper_board_attention_partition
module W = Masc.Keeper_board_attention_worker
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

let expect_error label = function
  | Error _ -> ()
  | Ok _ -> Alcotest.failf "%s unexpectedly succeeded" label
;;

let candidate ?(id = "candidate-worker") () : A.candidate =
  let keeper_name = "sangsu" in
  let signal : Masc.Board_dispatch.board_signal =
    { kind = Masc.Board_dispatch.Board_post_created
    ; post_id = id
    ; author = "external-author"
    ; title = "Board update"
    ; content = "Persisted Board evidence"
    ; hearth = Some "hearth-1"
    ; updated_at = Some 42.0
    }
  in
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
        [ ( "keeper_context"
          , `Assoc
              [ "instructions", `String "continue"
              ; "runtime", `Assoc [ "model", `String "configured-judge" ]
              ] )
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

let load_one_candidate ~base_path =
  match ok "load candidate" (A.load_candidates ~base_path ~keeper_name:"sangsu") with
  | [ candidate ] -> candidate
  | candidates -> Alcotest.failf "expected one candidate, got %d" (List.length candidates)
;;

let process_at ~now ~base_path ~judge =
  W.For_testing.process_next
    ~now
    ~worker_epoch:(P.Worker_epoch.generate ())
    ~base_path
    ~keeper_name:"sangsu"
    ~judge
;;

let process ~base_path ~judge =
  process_at ~now:(fun () -> 3.0) ~base_path ~judge
;;

let test_provider_result_waits_for_owner_settlement () =
  with_temp_base "board-attention-worker-boundary" @@ fun base_path ->
  let persisted = record ~base_path (candidate ()) in
  let calls = ref 0 in
  let observed_time = ref 3.0 in
  (match
     ok
       "worker step"
       (process_at ~base_path ~now:(fun () -> !observed_time) ~judge:(fun _ ->
          incr calls;
          observed_time := 9.0;
          Ok (judgment J.Not_relevant)))
   with
   | W.Judgment_completed { candidate_id; _ }
     when String.equal candidate_id persisted.candidate_id -> ()
   | W.Judgment_completed _
   | W.Idle
   | W.Judgment_deferred _
   | W.Candidate_already_consumed _
   | W.Partition_blocked _ ->
     Alcotest.fail "worker did not durably complete the exact judgment");
  Alcotest.(check int) "one Provider judgment" 1 !calls;
  (match (load_one_candidate ~base_path).status with
   | A.Pending { last_failure = None } -> ()
   | A.Pending { last_failure = Some _ } | A.Judged _ | A.Consumed _ ->
     Alcotest.fail "background worker mutated the candidate ledger");
  (match ok "load completed partition" (P.completed ~base_path ~keeper_name:"sangsu") with
   | [ { state = P.Completed { completed_at; _ }; _ } ] ->
     Alcotest.(check (float 0.0))
       "completion time is observed after Provider return"
       9.0
       completed_at
   | _ -> Alcotest.fail "worker result was not Completed");
  (match ok "owner settlement" (W.settle_one_completed ~base_path ~keeper_name:"sangsu") with
   | W.Partition_settled { candidate_id; _ }
     when String.equal candidate_id persisted.candidate_id -> ()
   | W.Partition_settled _ -> Alcotest.fail "a different candidate was settled"
   | W.No_completed_partition -> Alcotest.fail "completed judgment was not settled");
  (match (load_one_candidate ~base_path).status with
   | A.Consumed { delivery = A.Not_relevant; _ } -> ()
   | A.Pending _ | A.Judged _ | A.Consumed _ ->
     Alcotest.fail "owner settlement did not consume the exact judgment");
  match ok "load partitions" (P.load ~base_path ~keeper_name:"sangsu") with
  | [ { state = P.Settled _; _ } ] -> ()
  | _ -> Alcotest.fail "owner settlement did not settle the partition"
;;

let test_provider_failure_is_durable_without_hot_retry () =
  with_temp_base "board-attention-worker-deferred" @@ fun base_path ->
  let persisted = record ~base_path (candidate ()) in
  let calls = ref 0 in
  let failure : A.retryable_failure =
    { kind = A.Provider_unavailable; detail = "typed provider failure"; failed_at = 3.0 }
  in
  (match
     ok
       "defer worker step"
       (process ~base_path ~judge:(fun _ ->
          incr calls;
          Error failure))
   with
   | W.Judgment_deferred { candidate_id; failure = observed }
     when String.equal candidate_id persisted.candidate_id && observed = failure -> ()
   | _ -> Alcotest.fail "Provider failure was not durably deferred");
  (match ok "no ordinary retry" (process ~base_path ~judge:(fun _ ->
     incr calls;
     Ok (judgment J.Not_relevant))) with
   | W.Idle -> ()
   | _ -> Alcotest.fail "Deferred partition was claimed without a retry authority");
  Alcotest.(check int) "deferred work was not hot-looped" 1 !calls;
  (match (load_one_candidate ~base_path).status with
   | A.Pending { last_failure = None } -> ()
   | A.Pending { last_failure = Some _ } | A.Judged _ | A.Consumed _ ->
     Alcotest.fail "partition failure leaked into the candidate SSOT")
;;

let test_existing_judgment_never_calls_provider () =
  with_temp_base "board-attention-worker-existing-judgment" @@ fun base_path ->
  let persisted = record ~base_path (candidate ()) in
  ignore
    (ok
       "record prior judgment"
       (A.record_judgment ~base_path persisted (judgment J.Relevant))
     : A.candidate);
  match
    ok
      "worker step"
      (process ~base_path ~judge:(fun _ -> Alcotest.fail "Provider was called"))
  with
  | W.Judgment_completed { candidate_id; _ }
    when String.equal candidate_id persisted.candidate_id -> ()
  | _ -> Alcotest.fail "prior judgment was not projected into a completed partition"
;;

let test_step_exception_releases_exact_claim () =
  with_temp_base "board-attention-worker-claim-recovery" @@ fun base_path ->
  ignore (record ~base_path (candidate ()) : A.candidate);
  expect_error
    "raised judge step"
    (process ~base_path ~judge:(fun _ -> raise (Failure "injected judge crash")));
  match ok "load recovered partition" (P.load ~base_path ~keeper_name:"sangsu") with
  | [ { state = P.Ready; _ } ] -> ()
  | _ -> Alcotest.fail "raised worker step stranded a Running claim"
;;

let test_step_cancellation_releases_exact_claim () =
  Eio_main.run @@ fun _env ->
  with_temp_base "board-attention-worker-cancel-recovery" @@ fun base_path ->
  ignore (record ~base_path (candidate ()) : A.candidate);
  let judge_entered, publish_judge_entered = Eio.Promise.create () in
  let never, _resolve_never = Eio.Promise.create () in
  Eio.Fiber.first
    (fun () ->
       ignore
         (process ~base_path ~judge:(fun _ ->
            Eio.Promise.resolve publish_judge_entered ();
            Eio.Promise.await never)
          : (W.step, string) result))
    (fun () -> Eio.Promise.await judge_entered);
  match ok "load cancellation-recovered partition" (P.load ~base_path ~keeper_name:"sangsu") with
  | [ { state = P.Ready; _ } ] -> ()
  | _ -> Alcotest.fail "cancelled worker step stranded a Running claim"
;;

let test_conflicting_owner_judgment_preserves_completed_partition () =
  with_temp_base "board-attention-worker-conflict" @@ fun base_path ->
  let persisted = record ~base_path (candidate ()) in
  ignore
    (ok
       "worker completion"
       (process ~base_path ~judge:(fun _ -> Ok (judgment J.Relevant)))
     : W.step);
  ignore
    (ok
       "conflicting candidate judgment"
       (A.record_judgment ~base_path persisted (judgment J.Not_relevant))
     : A.candidate);
  expect_error
    "owner judgment conflict"
    (W.settle_one_completed ~base_path ~keeper_name:"sangsu");
  match ok "load preserved completion" (P.completed ~base_path ~keeper_name:"sangsu") with
  | [ _ ] -> ()
  | _ -> Alcotest.fail "conflicting owner settlement discarded the completed result"
;;

let test_cross_domain_wake_is_coalesced_and_rearmed () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_temp_base "board-attention-worker-wake" @@ fun base_path ->
  (match ok "unregistered request" (Wake.request ~base_path ~keeper_name:"sangsu") with
   | Wake.Not_registered -> ()
   | Wake.Signaled | Wake.Coalesced -> Alcotest.fail "unregistered wake was accepted");
  let registration =
    ok "register worker wake" (Wake.register ~sw ~base_path ~keeper_name:"sangsu")
  in
  let first =
    Domain.spawn (fun () -> Wake.request ~base_path ~keeper_name:"sangsu")
    |> Domain.join
    |> ok "cross-domain wake"
  in
  (match first with
   | Wake.Signaled -> ()
   | Wake.Coalesced | Wake.Not_registered -> Alcotest.fail "first wake was not signaled");
  (match ok "coalesced wake" (Wake.request ~base_path ~keeper_name:"sangsu") with
   | Wake.Coalesced -> ()
   | Wake.Signaled | Wake.Not_registered -> Alcotest.fail "pending wake did not coalesce");
  (match Wake.await registration with
   | Wake.Wake -> ()
   | Wake.Registration_closed -> Alcotest.fail "live registration closed");
  match ok "rearmed wake" (Wake.request ~base_path ~keeper_name:"sangsu") with
  | Wake.Signaled -> ()
  | Wake.Coalesced | Wake.Not_registered -> Alcotest.fail "consumed wake did not rearm"
;;

let () =
  Alcotest.run
    "keeper_board_attention_worker"
    [ ( "judgment plane"
      , [ Alcotest.test_case
            "Provider result waits for owner settlement"
            `Quick
            test_provider_result_waits_for_owner_settlement
        ; Alcotest.test_case
            "Provider failure is durable without hot retry"
            `Quick
            test_provider_failure_is_durable_without_hot_retry
        ; Alcotest.test_case
            "existing judgment skips Provider"
            `Quick
            test_existing_judgment_never_calls_provider
        ; Alcotest.test_case
            "step exception releases exact claim"
            `Quick
            test_step_exception_releases_exact_claim
        ; Alcotest.test_case
            "step cancellation releases exact claim"
            `Quick
            test_step_cancellation_releases_exact_claim
        ; Alcotest.test_case
            "conflicting owner judgment preserves completion"
            `Quick
            test_conflicting_owner_judgment_preserves_completed_partition
        ; Alcotest.test_case
            "cross-domain wake coalesces and rearms"
            `Quick
            test_cross_domain_wake_is_coalesced_and_rearmed
        ] )
    ]
;;
