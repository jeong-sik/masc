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
      ~now:100.0
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
  Alcotest.(check int) "idempotent ensure" 17 (List.length second)
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
  let candidates = [ candidate 1 ] in
  record_all ~base_path candidates;
  ignore (ensure ~base_path candidates : P.t list);
  let path = P.For_testing.path ~base_path ~keeper_name:"partition-keeper" in
  let channel = open_out_bin path in
  output_string channel "not-json\n";
  close_out channel;
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
  with_temp_base "board-partition-cross-keeper" @@ fun base_path ->
  let candidates = [ candidate 1 ] in
  record_all ~base_path candidates;
  let root = ensure ~base_path candidates |> List.hd in
  let path = P.For_testing.path ~base_path ~keeper_name:"partition-keeper" in
  let channel = open_out_bin path in
  output_string
    channel
    (Yojson.Safe.to_string (P.to_yojson { root with keeper_name = "other-keeper" })
     ^ "\n");
  close_out channel;
  (match P.load ~base_path ~keeper_name:"partition-keeper" with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "partition ledger crossed Keeper identity");
  let health = P.fleet_summary_json ~base_path in
  Alcotest.(check int)
    "cross-Keeper partition is a health read error"
    1
    U.(health |> member "read_error_count" |> to_int)
;;

let test_provider_failure_defers_until_process_start_recovery () =
  with_temp_base "board-partition-defer" @@ fun base_path ->
  let candidates = [ candidate 1; candidate 2 ] in
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
  (match P.claim_next ~now:121.0 ~worker_epoch ~base_path ~keeper_name:"partition-keeper" with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "deferred partition retried without a signal"
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
  let candidates = List.init 3 (fun index -> candidate (index + 1)) in
  record_all ~base_path candidates;
  ignore (ensure ~base_path candidates : P.t list);
  let root = claim ~base_path in
  let items =
    candidates
    |> List.mapi (fun index candidate ->
      { P.candidate_id = candidate.A.candidate_id; judgment = judgment index })
  in
  (match
     P.complete
       ~now:120.0
       ~worker_epoch
       ~base_path
       ~partition:root
       ~items:(List.tl items)
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
  (match
     P.settle_many
       ~now:131.0
       ~base_path
       ~keeper_name:"partition-keeper"
       ~partition_ids:[ completed.partition_id ]
   with
   | Ok [ { state = P.Settled _; _ } ] -> ()
   | Ok _ -> Alcotest.fail "settlement replay was not idempotent"
   | Error detail -> Alcotest.fail detail)
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
        ] )
    ]
;;
