module A = Masc.Keeper_board_attention_candidate
module J = Masc.Keeper_board_attention_judgment
module P = Masc.Keeper_board_attention_partition
module U = Yojson.Safe.Util

let worker_epoch = P.Worker_epoch.generate ()

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

let meta ?(instructions = "partition context") keeper_name =
  let json =
    `Assoc
      [ "name", `String keeper_name
      ; "agent_name", `String ("keeper-" ^ keeper_name)
      ; "trace_id", `String ("trace-" ^ keeper_name)
      ; "instructions", `String instructions
      ; "sandbox_profile", `String "local"
      ; "network_mode", `String "inherit"
      ; "mention_targets", `List [ `String keeper_name ]
      ]
  in
  match Masc.Keeper_meta_json_parse.meta_of_json json with
  | Ok meta -> { meta with active_goal_ids = [ "goal-partition" ] }
  | Error detail -> Alcotest.failf "keeper meta fixture invalid: %s" detail
;;

let candidate ?(instructions = "partition context") index =
  let keeper_name = "partition-keeper" in
  let post_id_raw = Printf.sprintf "post-%03d" index in
  let signal : Masc.Board_dispatch.board_signal =
    { kind = Masc.Board_dispatch.Board_post_created
    ; post_id = post_id_raw
    ; author = "external-author"
    ; title = "Board update"
    ; content = Printf.sprintf "candidate-%03d" index
    ; hearth = Some "partition-hearth"
    ; updated_at = Some (float_of_int index)
    }
  in
  let post : Masc.Board.post =
    { id = post_id post_id_raw
    ; author = agent_id "external-author"
    ; title = signal.title
    ; body = signal.content
    ; content = signal.content
    ; post_kind = Masc.Board.Human_post
    ; meta_json = None
    ; visibility = Masc.Board.Public
    ; created_at = float_of_int index
    ; updated_at = float_of_int index
    ; expires_at = 0.0
    ; votes_up = 0
    ; votes_down = 0
    ; reply_count = 1
    ; pinned = false
    ; hearth = signal.hearth
    ; thread_id = None
    ; origin = None
    }
  in
  let comments : Masc.Board.comment list =
    [ { id = comment_id (Printf.sprintf "comment-%03d" index)
      ; post_id = post_id post_id_raw
      ; parent_id = None
      ; author = agent_id "reviewer"
      ; content = "evidence"
      ; created_at = float_of_int index
      ; expires_at = 0.0
      ; votes_up = 0
      ; votes_down = 0
      }
    ]
  in
  match
    A.of_board_evidence
      ~meta:(meta ~instructions keeper_name)
      ~recorded_at:(float_of_int index)
      ~signal
      ~post
      ~comments
  with
  | Ok candidate -> candidate
  | Error detail -> Alcotest.failf "candidate fixture invalid: %s" detail
;;

let record_all ~base_path candidates =
  List.iter
    (fun candidate ->
       match A.record ~base_path candidate with
       | A.Recorded _ | A.Duplicate _ -> ()
       | A.Record_error detail -> Alcotest.fail detail)
    candidates
;;

let judgment index : A.judgment =
  { verdict =
      { J.decision =
          (if index mod 2 = 0 then J.Relevant else J.Not_relevant)
      ; rationale = Printf.sprintf "judgment-%03d" index
      }
  ; runtime_id = "partition-test-runtime"
  ; judged_at = 200.0 +. float_of_int index
  }
;;

let failure kind detail : A.retryable_failure =
  { kind; detail; failed_at = 300.0 }
;;

let ensure ~base_path candidates =
  match
    P.ensure_roots
      ~base_path
      ~keeper_name:"partition-keeper"
      candidates
  with
  | Ok partitions -> partitions
  | Error detail -> Alcotest.fail detail
;;

let claim ~base_path =
  match
    P.claim_next
      ~now:110.0
      ~worker_epoch
      ~base_path
      ~keeper_name:"partition-keeper"
  with
  | Ok (Some partition) -> partition
  | Ok None -> Alcotest.fail "expected a ready partition"
  | Error detail -> Alcotest.fail detail
;;

let ledger_lines path =
  Fs_compat.load_file path
  |> String.split_on_char '\n'
  |> List.filter (fun line -> not (String.equal line ""))
;;

let append_ledger path content =
  match Fs_compat.append_private_jsonl_durable_locked_result path content with
  | Fs_compat.Private_file_succeeded () -> ()
  | Fs_compat.Private_file_failed error ->
    Alcotest.fail (Fs_compat.private_jsonl_append_error_to_string error)
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { cleanup_failure; _ } ->
    Alcotest.fail
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
  | Fs_compat.Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    Alcotest.fail
      (Printf.sprintf
         "%s; cleanup: %s"
         (Fs_compat.private_jsonl_append_error_to_string error)
         (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
;;

let test_pending_candidates_form_singleton_roots () =
  with_temp_base "board-partition-root" @@ fun base_path ->
  let candidates = List.init 17 (fun index -> candidate (index + 1)) in
  record_all ~base_path candidates;
  let partitions = ensure ~base_path candidates in
  Alcotest.(check int) "one root per candidate" 17 (List.length partitions);
  Alcotest.(check (list string))
    "stable recorded order"
    (List.map (fun value -> value.A.candidate_id) candidates)
    (List.concat_map (fun partition -> partition.P.candidate_ids) partitions);
  Alcotest.(check bool)
    "every root is an irreducible singleton"
    true
    (List.for_all (fun partition -> List.length partition.P.candidate_ids = 1) partitions);
  let second = ensure ~base_path candidates in
  Alcotest.(check int) "idempotent ensure appends no roots" 0 (List.length second);
  (match P.load ~base_path ~keeper_name:"partition-keeper" with
   | Ok persisted -> Alcotest.(check int) "all roots remain indexed" 17 (List.length persisted)
   | Error detail -> Alcotest.fail detail)
;;

let test_singleton_roots_preserve_context_identity () =
  with_temp_base "board-partition-context" @@ fun base_path ->
  let left = List.init 3 (fun index -> candidate ~instructions:"left" (index + 1)) in
  let right =
    List.init 4 (fun index -> candidate ~instructions:"right" (index + 101))
  in
  let candidates = left @ right in
  record_all ~base_path candidates;
  let partitions = ensure ~base_path candidates in
  Alcotest.(check int) "all candidates remain independently executable" 7 (List.length partitions);
  Alcotest.(check int)
    "two exact context identities retained"
    2
    (partitions
     |> List.map (fun partition -> partition.P.context_key)
     |> List.sort_uniq String.compare
     |> List.length)
;;

let test_response_failure_defers_without_split () =
  with_temp_base "board-partition-response-defer" @@ fun base_path ->
  let candidates = List.init 17 (fun index -> candidate (index + 1)) in
  record_all ~base_path candidates;
  ignore (ensure ~base_path candidates : P.t list);
  let root = claim ~base_path in
  (match
    P.fail
      ~now:120.0
      ~worker_epoch
      ~base_path
      ~partition:root
      (failure A.Response_contract_unavailable "exact id set mismatch")
  with
  | Ok (P.Partition_deferred { state = P.Deferred _; candidate_ids; _ }) ->
    Alcotest.(check (list string))
      "same membership remains deferred"
      root.candidate_ids
      candidate_ids
  | Ok _ -> Alcotest.fail "response failure did not defer the same partition"
  | Error detail -> Alcotest.fail detail);
  let health = P.fleet_summary_json ~base_path in
  Alcotest.(check string)
    "deferred response failure degrades health"
    "degraded"
    U.(health |> member "status" |> to_string);
  Alcotest.(check bool)
    "deferred response failure requires operator action"
    true
    U.(health |> member "operator_action_required" |> to_bool)
;;

let test_settled_root_tolerates_stale_pending_snapshot () =
  with_temp_base "board-partition-stale-snapshot" @@ fun base_path ->
  let pending_snapshot = candidate 1 in
  record_all ~base_path [ pending_snapshot ];
  ignore (ensure ~base_path [ pending_snapshot ] : P.t list);
  let root = claim ~base_path in
  let completed =
    match
      P.complete
        ~now:120.0
        ~worker_epoch
        ~base_path
        ~partition:root
        ~items:
          [ { P.candidate_id = pending_snapshot.candidate_id
            ; judgment = judgment 1
            }
          ]
    with
    | Ok (P.Partition_completed partition) -> partition
    | Ok _ -> Alcotest.fail "expected completed partition"
    | Error detail -> Alcotest.fail detail
  in
  ignore
    (match
       P.settle_many
         ~now:130.0
         ~base_path
         ~keeper_name:"partition-keeper"
         ~partition_ids:[ completed.partition_id ]
     with
     | Ok partitions -> partitions
     | Error detail -> Alcotest.fail detail
      : P.t list);
  let appended = ensure ~base_path [ pending_snapshot ] in
  Alcotest.(check int) "settled root is not appended again" 0 (List.length appended);
  match P.load ~base_path ~keeper_name:"partition-keeper" with
  | Ok [ { state = P.Settled _; _ } ] -> ()
  | Ok _ -> Alcotest.fail "stale Pending snapshot recreated a settled root"
  | Error detail -> Alcotest.fail detail
;;

let test_claim_order_uses_candidate_recorded_identity () =
  with_temp_base "board-partition-recorded-order" @@ fun base_path ->
  let oldest = candidate 1 in
  let newest = candidate 2 in
  record_all ~base_path [ newest; oldest ];
  let roots = ensure ~base_path [ newest; oldest ] in
  Alcotest.(check (list (float 0.0)))
    "root creation time is candidate recorded time"
    [ oldest.recorded_at; newest.recorded_at ]
    (List.map (fun partition -> partition.P.created_at) roots);
  let first = claim ~base_path in
  Alcotest.(check (list string))
    "oldest candidate claims first"
    [ oldest.candidate_id ]
    first.candidate_ids
;;

let test_candidate_storage_failure_defers () =
  with_temp_base "board-partition-storage-defer" @@ fun base_path ->
  let pending = candidate 1 in
  record_all ~base_path [ pending ];
  ignore (ensure ~base_path [ pending ] : P.t list);
  let root = claim ~base_path in
  match
    P.fail
      ~now:120.0
      ~worker_epoch
      ~base_path
      ~partition:root
      (failure A.Durable_candidate_storage_unavailable "candidate ledger unavailable")
  with
  | Ok (P.Partition_deferred { state = P.Deferred _; _ }) ->
    (match P.load ~base_path ~keeper_name:"partition-keeper" with
     | Ok
         [ { state =
               P.Deferred
                 { failure = { kind = A.Durable_candidate_storage_unavailable; _ }; _ }
           ; _
           }
         ] ->
       ()
     | Ok _ -> Alcotest.fail "candidate storage failure did not round-trip"
     | Error detail -> Alcotest.fail detail)
  | Ok _ -> Alcotest.fail "candidate storage failure became terminal"
  | Error detail -> Alcotest.fail detail
;;

let test_completed_delivery_obligation_degrades_health () =
  with_temp_base "board-partition-completed-health" @@ fun base_path ->
  let pending = candidate 1 in
  record_all ~base_path [ pending ];
  ignore (ensure ~base_path [ pending ] : P.t list);
  let root = claim ~base_path in
  ignore
    (match
       P.complete
         ~now:120.0
         ~worker_epoch
         ~base_path
         ~partition:root
         ~items:[ { P.candidate_id = pending.candidate_id; judgment = judgment 1 } ]
     with
     | Ok transition -> transition
     | Error detail -> Alcotest.fail detail
      : P.transition);
  let health = P.fleet_summary_json ~base_path in
  Alcotest.(check string)
    "completed delivery obligation degrades health"
    "degraded"
    U.(health |> member "status" |> to_string);
  Alcotest.(check bool)
    "completed delivery obligation requires operator action"
    true
    U.(health |> member "operator_action_required" |> to_bool);
  Alcotest.(check bool)
    "completed delivery reason is explicit"
    true
    U.(health |> member "status_reasons" |> to_list |> List.mem (`String "completed_delivery_pending"))
;;

let test_removed_split_state_is_rejected () =
  with_temp_base "board-partition-removed-split" @@ fun base_path ->
  let candidates = [ candidate 1; candidate 2 ] in
  record_all ~base_path candidates;
  let root = ensure ~base_path candidates |> List.hd in
  let removed_state =
    `Assoc
      [ "kind", `String "split"
      ; "failure", A.retryable_failure_to_yojson (failure A.Provider_unavailable "x")
      ; "left_partition_id", `String "left"
      ; "right_partition_id", `String "right"
      ; "split_at", `Float 120.0
      ]
  in
  let removed_row =
    match P.to_yojson root with
    | `Assoc fields -> `Assoc (("state", removed_state) :: List.remove_assoc "state" fields)
    | _ -> Alcotest.fail "partition fixture did not encode as an object"
  in
  match P.of_yojson removed_row with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "removed Split state was accepted by the durable schema"
;;

let test_malformed_partition_ledger_is_health_read_error () =
  with_temp_base "board-partition-health-read-error" @@ fun base_path ->
  let path = P.For_testing.path ~base_path ~keeper_name:"partition-keeper" in
  append_ledger path "not-json\n";
  let health = P.fleet_summary_json ~base_path in
  Alcotest.(check string)
    "malformed ledger degrades health"
    "degraded"
    U.(health |> member "status" |> to_string);
  Alcotest.(check int)
    "read error count"
    1
    U.(health |> member "read_error_count" |> to_int);
  Alcotest.(check bool)
    "read error requires operator action"
    true
    U.(health |> member "operator_action_required" |> to_bool)
;;

let test_partition_ledger_rejects_cross_keeper_identity () =
  with_temp_base "board-partition-cross-keeper-source" @@ fun source_base ->
  let candidates = [ candidate 1 ] in
  let other_root =
    match
      P.ensure_roots
        ~base_path:source_base
        ~keeper_name:"other-keeper"
        candidates
    with
    | Ok [ root ] -> root
    | Ok _ -> Alcotest.fail "cross-Keeper source root was not created exactly once"
    | Error detail -> Alcotest.fail detail
  in
  with_temp_base "board-partition-cross-keeper-target" @@ fun target_base ->
  let target_path =
    P.For_testing.path ~base_path:target_base ~keeper_name:"partition-keeper"
  in
  append_ledger target_path (Yojson.Safe.to_string (P.to_yojson other_root) ^ "\n");
  (match P.load ~base_path:target_base ~keeper_name:"partition-keeper" with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "partition ledger crossed Keeper identity");
  let health = P.fleet_summary_json ~base_path:target_base in
  Alcotest.(check int)
    "cross-Keeper partition is a health read error"
    1
    U.(health |> member "read_error_count" |> to_int)
;;

let test_partition_ledger_rejects_illegal_transition () =
  with_temp_base "board-partition-illegal-transition" @@ fun base_path ->
  let candidates = [ candidate 1 ] in
  record_all ~base_path candidates;
  let root = ensure ~base_path candidates |> List.hd in
  let path = P.For_testing.path ~base_path ~keeper_name:"partition-keeper" in
  let illegal = { root with state = P.Settled { settled_at = 101.0 } } in
  append_ledger path (Yojson.Safe.to_string (P.to_yojson illegal) ^ "\n");
  match P.load ~base_path ~keeper_name:"partition-keeper" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "Ready -> Settled ledger regression was accepted"
;;

let test_cold_replay_rejects_invalid_completed_payload () =
  with_temp_base "board-partition-invalid-completed-source" @@ fun source_base ->
  let candidates = [ candidate 1 ] in
  record_all ~base_path:source_base candidates;
  let root = ensure ~base_path:source_base candidates |> List.hd in
  let item =
    { P.candidate_id = List.hd root.P.candidate_ids; judgment = judgment 0 }
  in
  let invalid =
    { root with
      state = P.Completed { items = [ item; item ]; completed_at = 120.0 }
    }
  in
  with_temp_base "board-partition-invalid-completed-target" @@ fun target_base ->
  let target_path =
    P.For_testing.path ~base_path:target_base ~keeper_name:"partition-keeper"
  in
  append_ledger target_path (Yojson.Safe.to_string (P.to_yojson invalid) ^ "\n");
  match P.load ~base_path:target_base ~keeper_name:"partition-keeper" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "cold replay accepted duplicate Completed candidates"
;;

let test_cold_replay_rejects_failure_state_inversion () =
  with_temp_base "board-partition-failure-state-source" @@ fun source_base ->
  let candidates = [ candidate 1 ] in
  record_all ~base_path:source_base candidates;
  let root = ensure ~base_path:source_base candidates |> List.hd in
  let assert_rejected name invalid =
    with_temp_base name @@ fun target_base ->
    let target_path =
      P.For_testing.path ~base_path:target_base ~keeper_name:"partition-keeper"
    in
    append_ledger target_path (Yojson.Safe.to_string (P.to_yojson invalid) ^ "\n");
    match P.load ~base_path:target_base ~keeper_name:"partition-keeper" with
    | Error _ -> ()
    | Ok _ -> Alcotest.failf "cold replay accepted inverted failure state: %s" name
  in
  assert_rejected
    "board-partition-terminal-deferred"
    { root with
      state =
        P.Deferred
          { failure = failure A.Durable_delivery_unavailable "durability lost"
          ; deferred_at = 120.0
          }
    };
  assert_rejected
    "board-partition-retryable-blocked"
    { root with
      state =
        P.Blocked
          { failure = failure A.Provider_unavailable "provider unavailable"
          ; blocked_at = 120.0
          }
    }
;;

let test_provider_failure_defers_until_process_start_recovery () =
  with_temp_base "board-partition-defer" @@ fun base_path ->
  let candidates = [ candidate 1 ] in
  record_all ~base_path candidates;
  ignore (ensure ~base_path candidates : P.t list);
  let root = claim ~base_path in
  (match
     P.fail
       ~now:120.0
       ~worker_epoch
       ~base_path
       ~partition:root
       (failure A.Provider_unavailable "provider admission unavailable")
   with
   | Ok (P.Partition_deferred { state = P.Deferred _; _ }) -> ()
   | Ok _ -> Alcotest.fail "provider failure did not defer"
   | Error detail -> Alcotest.fail detail);
  let next = candidate 2 in
  record_all ~base_path [ next ];
  ignore (ensure ~base_path [ next ] : P.t list);
  let unrelated =
    match P.claim_next ~now:121.0 ~worker_epoch ~base_path ~keeper_name:"partition-keeper" with
    | Ok (Some unrelated) ->
      Alcotest.(check bool)
        "unrelated ready work continues"
        false
        (String.equal unrelated.P.partition_id root.partition_id);
      unrelated
    | Ok None -> Alcotest.fail "unrelated ready partition was blocked by deferred work"
    | Error detail -> Alcotest.fail detail
  in
  (match
     P.recover_claim_after_lane_abort ~worker_epoch ~base_path ~partition:unrelated
   with
   | Ok (P.Claim_released _) -> ()
   | Ok _ -> Alcotest.fail "unrelated fixture claim was not released"
   | Error detail -> Alcotest.fail detail);
  (match P.recover_for_process_start ~base_path ~keeper_name:"partition-keeper" with
   | Ok 1 -> ()
   | Ok count -> Alcotest.failf "expected one recovered partition, got %d" count
   | Error detail -> Alcotest.fail detail);
  ignore (claim ~base_path : P.t)
;;

let test_untyped_worker_epoch_is_rejected () =
  with_temp_base "board-partition-untyped-worker-epoch" @@ fun base_path ->
  let candidates = [ candidate 1 ] in
  record_all ~base_path candidates;
  ignore (ensure ~base_path candidates : P.t list);
  let claimed = claim ~base_path in
  let untyped_state =
    match P.to_yojson claimed with
    | `Assoc fields ->
      (match List.assoc_opt "state" fields with
       | Some (`Assoc state_fields) ->
         `Assoc
           (("worker_epoch", `String "legacy-worker-epoch")
            :: List.remove_assoc "worker_epoch" state_fields)
       | Some _ | None -> Alcotest.fail "running state fixture is malformed")
    | _ -> Alcotest.fail "partition fixture did not encode as an object"
  in
  let untyped_row =
    match P.to_yojson claimed with
    | `Assoc fields -> `Assoc (("state", untyped_state) :: List.remove_assoc "state" fields)
    | _ -> Alcotest.fail "partition fixture did not encode as an object"
  in
  match P.of_yojson untyped_row with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "untyped legacy worker epoch was accepted"
;;

let test_running_claim_recovers_at_process_start () =
  with_temp_base "board-partition-recover" @@ fun base_path ->
  let candidates = [ candidate 1; candidate 2 ] in
  record_all ~base_path candidates;
  ignore (ensure ~base_path candidates : P.t list);
  ignore (claim ~base_path : P.t);
  (match P.recover_for_process_start ~base_path ~keeper_name:"partition-keeper" with
   | Ok 1 -> ()
   | Ok count -> Alcotest.failf "expected one running recovery, got %d" count
   | Error detail -> Alcotest.fail detail);
  ignore (claim ~base_path : P.t)
;;

let test_completion_requires_exact_identity_then_settles () =
  with_temp_base "board-partition-complete" @@ fun base_path ->
  let candidates = [ candidate 1 ] in
  record_all ~base_path candidates;
  ignore (ensure ~base_path candidates : P.t list);
  let path = P.For_testing.path ~base_path ~keeper_name:"partition-keeper" in
  let ready_bytes = Fs_compat.load_file path in
  let root = claim ~base_path in
  let items =
    root.P.candidate_ids
    |> List.mapi (fun index candidate_id ->
      { P.candidate_id; judgment = judgment index })
  in
  let running_bytes = Fs_compat.load_file path in
  Alcotest.(check bool)
    "claim appends without rewriting ready prefix"
    true
    (String.starts_with running_bytes ~prefix:ready_bytes);
  Alcotest.(check int) "ready and running rows" 2 (List.length (ledger_lines path));
  (match
     P.complete
       ~now:120.0
       ~worker_epoch
       ~base_path
       ~partition:root
       ~items:[]
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "partial completion was accepted");
  (match P.load ~base_path ~keeper_name:"partition-keeper" with
   | Ok [ { state = P.Running _; _ } ] -> ()
   | Ok _ -> Alcotest.fail "failed completion changed running state"
   | Error detail -> Alcotest.fail detail);
  let completed =
    match
      P.complete
        ~now:121.0
        ~worker_epoch
        ~base_path
        ~partition:root
        ~items
    with
    | Ok (P.Partition_completed partition) -> partition
    | Ok _ -> Alcotest.fail "expected completed partition"
    | Error detail -> Alcotest.fail detail
  in
  let completed_bytes = Fs_compat.load_file path in
  Alcotest.(check bool)
    "completion appends without rewriting running prefix"
    true
    (String.starts_with completed_bytes ~prefix:running_bytes);
  (match
     P.settle_many
       ~now:130.0
       ~base_path
       ~keeper_name:"partition-keeper"
       ~partition_ids:[ completed.partition_id ]
   with
   | Ok [ { state = P.Settled _; _ } ] -> ()
   | Ok _ -> Alcotest.fail "completed partition did not settle"
   | Error detail -> Alcotest.fail detail);
  let settled_bytes = Fs_compat.load_file path in
  Alcotest.(check bool)
    "settlement appends without rewriting completed prefix"
    true
    (String.starts_with settled_bytes ~prefix:completed_bytes);
  (match
     P.settle_many
       ~now:131.0
       ~base_path
       ~keeper_name:"partition-keeper"
       ~partition_ids:[ completed.partition_id ]
   with
   | Ok [ { state = P.Settled _; _ } ] -> ()
   | Ok _ -> Alcotest.fail "settlement replay was not idempotent"
   | Error detail -> Alcotest.fail detail);
  Alcotest.(check string)
    "settlement replay writes no duplicate row"
    settled_bytes
    (Fs_compat.load_file path);
  Alcotest.(check int)
    "runtime transitions append one latest row each"
    4
    (List.length (ledger_lines path));
  (match P.recover_for_process_start ~base_path ~keeper_name:"partition-keeper" with
   | Ok 0 -> ()
   | Ok recovered -> Alcotest.failf "settled compaction recovered %d rows" recovered
   | Error detail -> Alcotest.fail detail);
  Alcotest.(check int)
    "process start compacts to one latest row"
    1
    (List.length (ledger_lines path));
  let compacted_bytes = Fs_compat.load_file path in
  (match P.load ~base_path ~keeper_name:"partition-keeper" with
   | Ok [ { state = P.Settled _; _ } ] -> ()
   | Ok _ -> Alcotest.fail "compaction did not preserve settled receipt"
   | Error detail -> Alcotest.fail detail);
  with_temp_base "board-partition-cold-compacted" @@ fun cold_base ->
  let cold_path =
    P.For_testing.path ~base_path:cold_base ~keeper_name:"partition-keeper"
  in
  append_ledger cold_path compacted_bytes;
  match P.load ~base_path:cold_base ~keeper_name:"partition-keeper" with
  | Ok [ { state = P.Settled _; _ } ] -> ()
  | Ok _ -> Alcotest.fail "cold replay did not preserve compacted Settled receipt"
  | Error detail -> Alcotest.fail detail
;;

let () =
  Alcotest.run
    "keeper_board_attention_partition"
    [ ( "partition FSM"
      , [ Alcotest.test_case
            "pending candidates form singleton roots"
            `Quick
            test_pending_candidates_form_singleton_roots
        ; Alcotest.test_case
            "singleton roots preserve context identity"
            `Quick
            test_singleton_roots_preserve_context_identity
        ; Alcotest.test_case
            "response failure defers without split"
            `Quick
            test_response_failure_defers_without_split
        ; Alcotest.test_case
            "settled root tolerates stale Pending snapshot"
            `Quick
            test_settled_root_tolerates_stale_pending_snapshot
        ; Alcotest.test_case
            "claim order uses candidate recorded identity"
            `Quick
            test_claim_order_uses_candidate_recorded_identity
        ; Alcotest.test_case
            "candidate storage failure defers"
            `Quick
            test_candidate_storage_failure_defers
        ; Alcotest.test_case
            "completed delivery obligation degrades health"
            `Quick
            test_completed_delivery_obligation_degrades_health
        ; Alcotest.test_case
            "removed split state is rejected"
            `Quick
            test_removed_split_state_is_rejected
        ; Alcotest.test_case
            "provider failure waits for process-start recovery"
            `Quick
            test_provider_failure_defers_until_process_start_recovery
        ; Alcotest.test_case
            "untyped worker epoch is rejected"
            `Quick
            test_untyped_worker_epoch_is_rejected
        ; Alcotest.test_case
            "running claim recovers at process start"
            `Quick
            test_running_claim_recovers_at_process_start
        ; Alcotest.test_case
            "completion requires exact identity then settles"
            `Quick
            test_completion_requires_exact_identity_then_settles
        ; Alcotest.test_case
            "malformed ledger is an operator-visible read error"
            `Quick
            test_malformed_partition_ledger_is_health_read_error
        ; Alcotest.test_case
            "partition ledger rejects cross-Keeper identity"
            `Quick
            test_partition_ledger_rejects_cross_keeper_identity
        ; Alcotest.test_case
            "partition ledger rejects illegal transitions"
            `Quick
            test_partition_ledger_rejects_illegal_transition
        ; Alcotest.test_case
            "cold replay rejects invalid completed payload"
            `Quick
            test_cold_replay_rejects_invalid_completed_payload
        ; Alcotest.test_case
            "cold replay rejects failure state inversion"
            `Quick
            test_cold_replay_rejects_failure_state_inversion
        ] )
    ]
;;
