module P = Masc.Keeper_board_attention_partition
module A = P.Candidate
module F = P.Failure
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

let ok label = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s: %s" label detail
;;

let expect_error label = function
  | Error _ -> ()
  | Ok _ -> Alcotest.failf "%s unexpectedly succeeded" label
;;

let signal post_id : Masc.Board_dispatch.board_signal =
  { kind = Masc.Board_dispatch.Board_post_created
  ; post_id
  ; author = "external-author"
  ; title = "Board update"
  ; content = "Persisted Board evidence"
  ; hearth = Some "hearth-1"
  ; updated_at = Some 42.0
  }
;;

let context name =
  `Assoc
    [ "instructions", `String ("continue " ^ name)
    ; "runtime", `Assoc [ "model", `String "configured-judge" ]
    ]
;;

let candidate ?(keeper_name = "sangsu") ?(context = context "primary") ~id ~recorded_at () :
  A.candidate
  =
  { candidate_id = id
  ; keeper_name
  ; signal = signal id
  ; judgment_request = `Assoc [ "keeper_context", context ]
  ; recorded_at
  ; status = A.Pending { last_failure = None }
  }
;;

let judgment ?(judged_at = 101.0) () : A.judgment =
  { verdict = { J.decision = J.Relevant; rationale = "react to this Board event" }
  ; runtime_id = "configured-structured-judge"
  ; judged_at
  }
;;

let roots ~base_path candidates =
  ignore
    (ok "ensure roots" (P.ensure_roots ~base_path ~keeper_name:"sangsu" candidates) : int);
  ok "load roots" (P.load ~base_path ~keeper_name:"sangsu")
;;

let claim ~base_path ~worker_epoch ~now =
  match ok "claim next" (P.claim_next ~now ~worker_epoch ~base_path ~keeper_name:"sangsu") with
  | Some partition -> partition
  | None -> Alcotest.fail "expected a Ready partition"
;;

let test_roots_are_singleton_deterministic_and_context_exact () =
  with_temp_base "board-attention-partition-roots" @@ fun base_path ->
  let first = candidate ~id:"candidate-first" ~recorded_at:1.0 () in
  let second = candidate ~id:"candidate-second" ~recorded_at:2.0 () in
  let isolated =
    candidate
      ~context:(context "isolated")
      ~id:"candidate-isolated"
      ~recorded_at:3.0
      ()
  in
  let created = roots ~base_path [ second; isolated; first ] in
  Alcotest.(check int) "one root per Pending candidate" 3 (List.length created);
  Alcotest.(check (list string))
    "oldest candidate order is durable"
    [ first.candidate_id; second.candidate_id; isolated.candidate_id ]
    (List.map (fun partition -> partition.P.candidate_id) created);
  List.iter
    (fun partition ->
       match partition.P.state with
       | P.Ready -> ()
       | _ -> Alcotest.fail "new partition was not Ready")
    created;
  Alcotest.(check int)
    "repeated ensure creates nothing"
    0
    (ok
       "repeat ensure"
       (P.ensure_roots
          ~base_path
          ~keeper_name:"sangsu"
          [ first; second; isolated ]));
  let repeated = ok "load repeated roots" (P.load ~base_path ~keeper_name:"sangsu") in
  Alcotest.(check bool) "root creation is idempotent" true (created = repeated);
  expect_error
    "same candidate identity with changed context"
    (P.ensure_roots
       ~base_path
       ~keeper_name:"sangsu"
       [ { first with judgment_request = `Assoc [ "keeper_context", context "changed" ] } ]);
  expect_error
    "same candidate identity with changed recorded_at"
    (P.ensure_roots
       ~base_path
       ~keeper_name:"sangsu"
       [ { first with recorded_at = 9.0 } ]);
  let primary_key = (List.hd created).P.context_key in
  let isolated_key = (List.hd (List.rev created)).P.context_key in
  Alcotest.(check bool)
    "different exact Keeper contexts do not collapse"
    false
    (A.Context_key.equal primary_key isolated_key)
;;

let test_claim_ownership_completion_and_settlement () =
  with_temp_base "board-attention-partition-claim" @@ fun base_path ->
  let early = candidate ~id:"candidate-early" ~recorded_at:1.0 () in
  let late = candidate ~id:"candidate-late" ~recorded_at:2.0 () in
  ignore (roots ~base_path [ late; early ] : P.t list);
  let owner = P.Worker_epoch.generate () in
  let stranger = P.Worker_epoch.generate () in
  let claimed = claim ~base_path ~worker_epoch:owner ~now:10.0 in
  Alcotest.(check string) "oldest Ready root claimed" early.candidate_id claimed.candidate_id;
  let item : P.completed_item =
    { candidate_id = claimed.candidate_id; judgment = judgment () }
  in
  expect_error
    "foreign worker completion"
    (P.complete ~now:11.0 ~worker_epoch:stranger ~base_path ~partition:claimed ~item);
  expect_error
    "wrong singleton identity"
    (P.complete
       ~now:11.0
       ~worker_epoch:owner
       ~base_path
       ~partition:claimed
       ~item:{ item with candidate_id = late.candidate_id });
  let completed =
    match
      ok
        "complete"
        (P.complete ~now:11.0 ~worker_epoch:owner ~base_path ~partition:claimed ~item)
    with
    | P.Partition_completed partition -> partition
    | P.Partition_deferred _ | P.Partition_blocked _ ->
      Alcotest.fail "completion returned a different terminal state"
  in
  (match completed.state with
   | P.Completed { item = persisted; _ } ->
     Alcotest.(check string)
       "exact completion identity persisted"
       claimed.candidate_id
       persisted.candidate_id
   | _ -> Alcotest.fail "partition was not Completed");
  let settled = ok "settle" (P.settle ~now:12.0 ~base_path ~partition:completed) in
  let settled_again = ok "settle idempotently" (P.settle ~now:99.0 ~base_path ~partition:settled) in
  Alcotest.(check bool) "settlement is idempotent" true (settled = settled_again);
  let next = claim ~base_path ~worker_epoch:owner ~now:13.0 in
  Alcotest.(check string) "next singleton remains independent" late.candidate_id next.candidate_id
;;

let test_lane_abort_and_process_start_recovery_are_explicit () =
  with_temp_base "board-attention-partition-recovery" @@ fun base_path ->
  let first = candidate ~id:"candidate-first" ~recorded_at:1.0 () in
  let second = candidate ~id:"candidate-second" ~recorded_at:2.0 () in
  ignore (roots ~base_path [ first; second ] : P.t list);
  let owner = P.Worker_epoch.generate () in
  let stranger = P.Worker_epoch.generate () in
  let first_claim = claim ~base_path ~worker_epoch:owner ~now:10.0 in
  expect_error
    "foreign worker abort recovery"
    (P.recover_claim_after_lane_abort ~worker_epoch:stranger ~base_path ~partition:first_claim);
  (match
     ok
       "owner abort recovery"
       (P.recover_claim_after_lane_abort ~worker_epoch:owner ~base_path ~partition:first_claim)
   with
   | P.Claim_released released ->
     (match released.state with
      | P.Ready -> ()
      | _ -> Alcotest.fail "released claim was not Ready")
   | P.Claim_already_transitioned _ -> Alcotest.fail "live owner claim was not released");
  let first_claim = claim ~base_path ~worker_epoch:owner ~now:11.0 in
  let failure : F.retryable =
    { requirement =
        F.Provider_retry_after
          { retry_class = Keeper_runtime_failure_route.Server_error
          ; delay_seconds = 5.0
          }
    ; detail = "typed Provider failure"
    ; failed_at = 12.0
    }
  in
  ignore
    (ok
       "defer"
       (P.defer ~now:12.0 ~worker_epoch:owner ~base_path ~partition:first_claim failure)
     : P.completion);
  let second_claim = claim ~base_path ~worker_epoch:owner ~now:13.0 in
  Alcotest.(check string)
    "Deferred root is not hot-loop claimed"
    second.candidate_id
    second_claim.candidate_id;
  Alcotest.(check int)
    "process start recovers only prior Running"
    1
    (ok "process-start recovery" (P.recover_for_process_start ~base_path ~keeper_name:"sangsu"));
  Alcotest.(check (option (float 0.0)))
    "Provider deadline remains durable"
    (Some 17.0)
    (ok
       "next Provider retry deadline"
       (P.next_provider_retry_deadline ~base_path ~keeper_name:"sangsu"));
  Alcotest.(check int)
    "deadline cannot release early"
    0
    (ok
       "early Provider retry release"
       (P.release_due_provider_retries
          ~now:16.0
          ~base_path
          ~keeper_name:"sangsu"));
  Alcotest.(check int)
    "exact Provider deadline releases deferred root"
    1
    (ok
       "due Provider retry release"
       (P.release_due_provider_retries
          ~now:17.0
          ~base_path
          ~keeper_name:"sangsu"));
  let recovered = claim ~base_path ~worker_epoch:owner ~now:18.0 in
  Alcotest.(check string)
    "recovery restores durable oldest order"
    first.candidate_id
    recovered.candidate_id
;;

let replace_field key value = function
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (existing, current) -> if String.equal existing key then existing, value else existing, current)
         fields)
  | _ -> Alcotest.fail "partition row was not an object"
;;

let test_strict_codec_and_ledger_identity_validation () =
  with_temp_base "board-attention-partition-codec" @@ fun base_path ->
  let created =
    match roots ~base_path [ candidate ~id:"candidate-codec" ~recorded_at:1.0 () ] with
    | [ partition ] -> partition
    | _ -> Alcotest.fail "expected one partition"
  in
  let encoded = P.to_yojson created in
  Alcotest.(check bool)
    "strict codec roundtrip"
    true
    (ok "decode" (P.of_yojson encoded) = created);
  expect_error
    "unknown schema version"
    (P.of_yojson (replace_field "schema_version" (`Int 3) encoded));
  let malformed = replace_field "partition_id" (`String "forged-root") encoded in
  let ledger_path = P.For_testing.path ~base_path ~keeper_name:"sangsu" in
  ok
    "inject malformed durable row"
    (Fs_compat.save_file_atomic ledger_path (Yojson.Safe.to_string malformed ^ "\n"));
  expect_error "forged deterministic root identity" (P.load ~base_path ~keeper_name:"sangsu");
  with_temp_base "board-attention-partition-second-root" @@ fun second_base ->
  let second =
    match
      roots
        ~base_path:second_base
        [ candidate
            ~context:(context "other")
            ~id:"candidate-codec"
            ~recorded_at:1.0
            ()
        ]
    with
    | [ partition ] -> partition
    | _ -> Alcotest.fail "expected one second partition"
  in
  ok
    "inject duplicate live membership"
    (Fs_compat.save_file_atomic
       ledger_path
       (Yojson.Safe.to_string encoded ^ "\n" ^ Yojson.Safe.to_string (P.to_yojson second) ^ "\n"));
  expect_error "duplicate live candidate membership" (P.load ~base_path ~keeper_name:"sangsu")
;;

let test_invalid_observation_values_never_rewrite () =
  with_temp_base "board-attention-partition-invalid" @@ fun base_path ->
  expect_error
    "non-finite candidate time"
    (P.ensure_roots
       ~base_path
       ~keeper_name:"sangsu"
       [ candidate ~id:"candidate-invalid" ~recorded_at:Float.nan () ]);
  Alcotest.(check int)
    "invalid candidate did not create a root"
    0
    (List.length (ok "load empty ledger" (P.load ~base_path ~keeper_name:"sangsu")));
  let valid = candidate ~id:"candidate-valid" ~recorded_at:1.0 () in
  ignore (roots ~base_path [ valid ] : P.t list);
  let owner = P.Worker_epoch.generate () in
  let claimed = claim ~base_path ~worker_epoch:owner ~now:2.0 in
  let invalid_item : P.completed_item =
    { candidate_id = valid.candidate_id; judgment = judgment ~judged_at:Float.infinity () }
  in
  expect_error
    "non-finite judgment time"
    (P.complete ~now:3.0 ~worker_epoch:owner ~base_path ~partition:claimed ~item:invalid_item);
  let loaded = ok "load Running after rejected completion" (P.load ~base_path ~keeper_name:"sangsu") in
  match loaded with
  | [ { P.state = P.Running running; _ } ] ->
    Alcotest.(check bool) "claim owner remains intact" true (P.Worker_epoch.equal owner running.worker_epoch)
  | _ -> Alcotest.fail "rejected completion mutated the durable claim"
;;

let () =
  Alcotest.run
    "keeper_board_attention_partition"
    [ ( "durable singleton FSM"
      , [ Alcotest.test_case
            "roots are deterministic singleton context partitions"
            `Quick
            test_roots_are_singleton_deterministic_and_context_exact
        ; Alcotest.test_case
            "claim ownership completion and settlement"
            `Quick
            test_claim_ownership_completion_and_settlement
        ; Alcotest.test_case
            "lane abort and process-start recovery"
            `Quick
            test_lane_abort_and_process_start_recovery_are_explicit
        ; Alcotest.test_case
            "strict codec and ledger identity"
            `Quick
            test_strict_codec_and_ledger_identity_validation
        ; Alcotest.test_case
            "invalid observations never rewrite"
            `Quick
            test_invalid_observation_values_never_rewrite
        ] )
    ]
;;
