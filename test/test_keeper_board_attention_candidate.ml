module A = Masc.Keeper_board_attention_candidate
module J = Masc.Keeper_board_attention_judgment
module Event_queue = Keeper_event_queue
module Event_queue_persistence = Keeper_event_queue_persistence

let cohort_size = 17

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

let meta ?(instructions = "Use the lane context and complete the task") keeper_name =
  let json =
    `Assoc
      [ "name", `String keeper_name
      ; "agent_name", `String ("keeper-" ^ keeper_name ^ "-agent")
      ; "trace_id", `String ("trace-" ^ keeper_name)
      ; "instructions", `String instructions
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

let candidate
      ?(keeper_name = "sangsu")
      ?(instructions = "Use the lane context and complete the task")
      ?(signal = signal ())
      ()
  =
  match
    A.of_board_evidence
      ~meta:(meta ~instructions keeper_name)
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

let load_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

let candidate_ledger_path ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path)
       "board_attention_candidates")
    (Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name ^ ".jsonl")
;;

let ledger_path_or_fail ~base_path ~keeper_name =
  let path = candidate_ledger_path ~base_path ~keeper_name in
  if Sys.file_exists path
  then path
  else Alcotest.failf "ledger file for %s not found under %s" keeper_name base_path
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

let test_candidate_codec_rejects_inner_identity_drift () =
  let encoded = A.candidate_to_json (candidate ()) in
  let invalid =
    match encoded with
    | `Assoc fields ->
      let judgment_request =
        match List.assoc_opt "judgment_request" fields with
        | Some (`Assoc request_fields) ->
          `Assoc
            (("candidate_id", `String "different-candidate")
             :: List.remove_assoc "candidate_id" request_fields)
        | Some _ | None -> Alcotest.fail "judgment_request fixture is absent"
      in
      `Assoc
        (("judgment_request", judgment_request)
         :: List.remove_assoc "judgment_request" fields)
    | _ -> Alcotest.fail "candidate fixture is not an object"
  in
  match A.candidate_of_json invalid with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "candidate codec accepted inner candidate identity drift"
;;

let test_record_rejects_inner_identity_drift () =
  with_temp_base "keeper-board-attention-record-identity" @@ fun base_path ->
  let candidate = candidate () in
  ignore (record_or_fail ~base_path candidate : A.candidate);
  let judgment_request =
    match candidate.judgment_request with
    | `Assoc fields ->
      `Assoc
        (("candidate_id", `String "different-candidate")
         :: List.remove_assoc "candidate_id" fields)
    | _ -> Alcotest.fail "judgment_request fixture is not an object"
  in
  match A.record ~base_path { candidate with judgment_request } with
  | A.Record_error _ -> ()
  | A.Recorded _ | A.Duplicate _ ->
    Alcotest.fail
      "record accepted an invalid duplicate that violates the codec identity invariant"
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

let test_consumed_candidate_rejects_retryable_failure () =
  with_temp_base "keeper-board-attention-consumed-failure" @@ fun base_path ->
  let pending = record_or_fail ~base_path (candidate ()) in
  let consumed =
    match
      A.process_with_judge
        ~base_path
        ~judge:(fun _ -> Ok (judgment J.Not_relevant))
        pending
    with
    | Ok candidate -> candidate
    | Error detail -> Alcotest.failf "candidate consumption failed: %s" detail
  in
  let path = ledger_path_or_fail ~base_path ~keeper_name:consumed.keeper_name in
  let before = load_file path in
  let failure : A.retryable_failure =
    { kind = A.Provider_unavailable
    ; detail = "late failure"
    ; failed_at = 110.0
    }
  in
  (match A.record_retryable_failure ~base_path consumed failure with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "Consumed candidate silently ignored retryable failure");
  Alcotest.(check string)
    "rejected late failure writes no durable row"
    before
    (load_file path)
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
  let discovery = A.discover_keeper_names ~base_path in
  Alcotest.(check int)
    "malformed ledger is reported"
    1
    (List.length discovery.read_errors);
  Alcotest.(check (list string))
    "malformed ledger does not invent an identity"
    []
    discovery.keeper_names;
  (match A.record ~base_path (candidate ~keeper_name ()) with
   | A.Record_error _ -> ()
   | A.Recorded _ | A.Duplicate _ -> Alcotest.fail "malformed ledger was overwritten");
  let ic = open_in_bin path in
  let preserved = really_input_string ic (in_channel_length ic) in
  close_in ic;
  Alcotest.(check string) "malformed bytes preserved" malformed preserved
;;

let test_candidate_ledger_rejects_cross_keeper_identity () =
  with_temp_base "keeper-board-attention-cross-keeper" @@ fun base_path ->
  let expected_keeper = "sangsu" in
  let observed = candidate ~keeper_name:"other-keeper" () in
  let dir =
    Filename.concat
      (Common.masc_dir_from_base_path ~base_path)
      "board_attention_candidates"
  in
  Fs_compat.mkdir_p dir;
  let path = Filename.concat dir (expected_keeper ^ ".jsonl") in
  let channel = open_out_bin path in
  output_string channel (Yojson.Safe.to_string (A.candidate_to_json observed) ^ "\n");
  close_out channel;
  (match A.load_candidates ~base_path ~keeper_name:expected_keeper with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "candidate ledger crossed Keeper identity");
  let discovery = A.discover_keeper_names ~base_path in
  Alcotest.(check int)
    "cross-Keeper ledger is reported"
    1
    (List.length discovery.read_errors);
  Alcotest.(check (list string))
    "cross-Keeper ledger is not started"
    []
    discovery.keeper_names
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

let with_ledger_operations operation =
  let mutex = Stdlib.Mutex.create () in
  let observed = ref [] in
  A.For_testing.set_ledger_operation_observer (fun event ->
    Stdlib.Mutex.protect mutex (fun () -> observed := event :: !observed));
  Fun.protect
    ~finally:A.For_testing.reset_ledger_operation_observer
    (fun () ->
       let result = operation () in
       result, Stdlib.Mutex.protect mutex (fun () -> List.rev !observed))
;;

let append_ledger path rows =
  match Fs_compat.append_private_jsonl_durable_locked_result path rows with
  | Ok () -> ()
  | Error error ->
    Alcotest.fail (Fs_compat.private_jsonl_append_error_to_string error)
;;

let test_runtime_appends_then_process_start_compacts () =
  with_temp_base "keeper-board-attention-compaction" @@ fun base_path ->
  let pending = record_or_fail ~base_path (candidate ()) in
  let keeper_name = pending.keeper_name in
  let transitions = 6 in
  ignore
    (List.fold_left
       (fun current index ->
         let failure : A.retryable_failure =
           { kind = A.Provider_unavailable
           ; detail = Printf.sprintf "provider unavailable %d" index
           ; failed_at = 102.0 +. float_of_int index
           }
         in
         match A.record_retryable_failure ~base_path current failure with
         | Ok candidate -> candidate
         | Error detail -> Alcotest.failf "failure %d not recorded: %s" index detail)
       pending
       (List.init transitions Fun.id)
     : A.candidate);
  Alcotest.(check int)
    "runtime writes one append row per changed state"
    (transitions + 1)
    (count_ledger_lines base_path);
  let compaction, operations =
    with_ledger_operations (fun () ->
      A.compact_for_process_start ~base_path ~keeper_name)
  in
  (match compaction with
   | Ok { rewritten = true; removed_rows } ->
     Alcotest.(check int) "superseded rows removed" transitions removed_rows
   | Ok { rewritten = false; _ } ->
     Alcotest.fail "non-canonical process-start ledger was not rewritten"
   | Error detail -> Alcotest.failf "process-start compaction failed: %s" detail);
  (match operations with
   | [ A.Rewrite { rows = 1; bytes } ] ->
     Alcotest.(check bool) "compaction rewrite is non-empty" true (bytes > 0)
   | _ -> Alcotest.fail "process-start compaction was not exactly one rewrite");
  Alcotest.(check int)
    "process-start compaction keeps one latest row"
    1
    (count_ledger_lines base_path);
  let path = ledger_path_or_fail ~base_path ~keeper_name in
  let compacted_bytes = load_file path in
  let replay, replay_operations =
    with_ledger_operations (fun () ->
      A.compact_for_process_start ~base_path ~keeper_name)
  in
  (match replay with
   | Ok { rewritten = false; removed_rows = 0 } -> ()
   | Ok report ->
     Alcotest.failf
       "idempotent compaction reported rewritten=%b removed=%d"
       report.rewritten
       report.removed_rows
   | Error detail -> Alcotest.failf "compaction replay failed: %s" detail);
  Alcotest.(check int)
    "idempotent compaction performs no ledger operation"
    0
    (List.length replay_operations);
  Alcotest.(check string)
    "idempotent compaction writes no bytes"
    compacted_bytes
    (load_file path);
  (match A.load_candidates ~base_path ~keeper_name with
   | Ok [ latest ] ->
     (match latest.status with
      | A.Pending { last_failure = Some observed } ->
        Alcotest.(check string)
          "latest failure survives compaction"
          "provider unavailable 5"
          observed.detail
      | A.Pending { last_failure = None } | A.Judged _ | A.Consumed _ ->
        Alcotest.fail "process-start compaction dropped the latest pending failure")
   | Ok candidates ->
     Alcotest.failf "expected one compacted candidate, got %d" (List.length candidates)
   | Error detail -> Alcotest.failf "load after compaction failed: %s" detail);
  with_temp_base "keeper-board-attention-compaction-cold" @@ fun cold_base ->
  append_ledger
    (candidate_ledger_path ~base_path:cold_base ~keeper_name)
    compacted_bytes;
  match A.load_candidates ~base_path:cold_base ~keeper_name with
  | Ok [ { status = A.Pending { last_failure = Some _ }; _ } ] -> ()
  | Ok _ -> Alcotest.fail "cold replay lost the compacted latest candidate"
  | Error detail -> Alcotest.failf "cold compacted replay failed: %s" detail
;;

let loaded_ids ~base_path ~keeper_name =
  match A.load_candidates ~base_path ~keeper_name with
  | Ok candidates -> List.map (fun (c : A.candidate) -> c.candidate_id) candidates
  | Error detail -> Alcotest.failf "candidate load failed: %s" detail
;;

let test_runtime_append_preserves_prefix_and_updates_delta_view () =
  with_temp_base "attention-candidate-append-delta" (fun base_path ->
    let keeper_name = "sangsu" in
    let first = record_or_fail ~base_path (candidate ()) in
    let path = ledger_path_or_fail ~base_path ~keeper_name in
    let prefix = load_file path in
    let first_stats = Unix.stat path in
    (match loaded_ids ~base_path ~keeper_name with
     | [ id ] -> Alcotest.(check string) "first load" first.candidate_id id
     | ids -> Alcotest.failf "expected one candidate, got %d" (List.length ids));
    let second, operations =
      with_ledger_operations (fun () ->
        record_or_fail
          ~base_path
          (candidate ~signal:(signal ~post_id:"post-2" ()) ()))
    in
    let appended = load_file path in
    let suffix =
      Yojson.Safe.to_string (A.candidate_to_json second) ^ "\n"
    in
    let second_stats = Unix.stat path in
    Alcotest.(check int) "append preserves device" first_stats.st_dev second_stats.st_dev;
    Alcotest.(check int) "append preserves inode" first_stats.st_ino second_stats.st_ino;
    Alcotest.(check bool)
      "second record appends without rewriting the first row"
      true
      (String.starts_with appended ~prefix);
    Alcotest.(check string)
      "append writes exactly the serialized candidate suffix"
      (prefix ^ suffix)
      appended;
    (match operations with
     | [ A.Append { rows = 1; bytes } ] ->
       Alcotest.(check int) "append observer reports exact byte count" (String.length suffix) bytes
     | _ -> Alcotest.fail "one candidate record was not exactly one append operation");
    let ids = loaded_ids ~base_path ~keeper_name in
    Alcotest.(check int) "delta view observes appended candidate" 2 (List.length ids);
    if not (List.exists (String.equal second.candidate_id) ids)
    then Alcotest.fail "second candidate missing after cursor append")
;;

let test_cold_replay_rejects_illegal_status_transition () =
  with_temp_base "attention-candidate-illegal-transition" @@ fun base_path ->
  let keeper_name = "sangsu" in
  let pending = candidate ~keeper_name () in
  let verdict = judgment J.Relevant in
  let consumed =
    { pending with
      status =
        A.Consumed
          { judgment = verdict
          ; delivery = A.Enqueued_to_keeper_lane
          ; consumed_at = 120.0
          }
    }
  in
  let path = candidate_ledger_path ~base_path ~keeper_name in
  append_ledger
    path
    (Yojson.Safe.to_string (A.candidate_to_json pending)
     ^ "\n"
     ^ Yojson.Safe.to_string (A.candidate_to_json consumed)
     ^ "\n");
  match A.load_candidates ~base_path ~keeper_name with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "cold replay accepted Pending -> Consumed"
;;

let test_compacted_consumed_snapshot_replays_cold () =
  with_temp_base "attention-candidate-consumed-source" @@ fun source_base ->
  let keeper_name = "sangsu" in
  let pending = record_or_fail ~base_path:source_base (candidate ~keeper_name ()) in
  (match
     A.process_with_judge
       ~base_path:source_base
       ~judge:(fun _ -> Ok (judgment J.Not_relevant))
       pending
   with
   | Ok { status = A.Consumed _; _ } -> ()
   | Ok _ -> Alcotest.fail "source candidate was not Consumed"
   | Error detail -> Alcotest.failf "source consumption failed: %s" detail);
  (match A.compact_for_process_start ~base_path:source_base ~keeper_name with
   | Ok _ -> ()
   | Error detail -> Alcotest.failf "Consumed compaction failed: %s" detail);
  let bytes =
    ledger_path_or_fail ~base_path:source_base ~keeper_name |> load_file
  in
  with_temp_base "attention-candidate-consumed-cold" @@ fun cold_base ->
  append_ledger
    (candidate_ledger_path ~base_path:cold_base ~keeper_name)
    bytes;
  match A.load_candidates ~base_path:cold_base ~keeper_name with
  | Ok [ { status = A.Consumed { delivery = A.Not_relevant; _ }; _ } ] -> ()
  | Ok _ -> Alcotest.fail "cold replay lost compacted Consumed receipt"
  | Error detail -> Alcotest.failf "cold Consumed replay failed: %s" detail
;;

let test_cold_replay_rejects_failure_state_inversion () =
  with_temp_base "attention-candidate-failure-inversion" @@ fun base_path ->
  let keeper_name = "sangsu" in
  let pending = candidate ~keeper_name () in
  let invalid =
    { pending with
      status =
        A.Judged
          { judgment = judgment J.Not_relevant
          ; last_failure =
              Some
                { kind = A.Provider_unavailable
                ; detail = "provider failure cannot be delivery evidence"
                ; failed_at = 120.0
                }
          }
    }
  in
  let path = candidate_ledger_path ~base_path ~keeper_name in
  append_ledger path (Yojson.Safe.to_string (A.candidate_to_json invalid) ^ "\n");
  match A.load_candidates ~base_path ~keeper_name with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "cold replay accepted Provider failure on Judged"
;;

let test_cold_replay_rejects_candidate_storage_failure_status () =
  let assert_rejected name status =
    with_temp_base name @@ fun base_path ->
    let keeper_name = "sangsu" in
    let original = candidate ~keeper_name () in
    let invalid = { original with status } in
    let path = candidate_ledger_path ~base_path ~keeper_name in
    append_ledger path (Yojson.Safe.to_string (A.candidate_to_json invalid) ^ "\n");
    match A.load_candidates ~base_path ~keeper_name with
    | Error _ -> ()
    | Ok _ ->
      Alcotest.fail "cold replay accepted candidate-storage failure as candidate state"
  in
  let failure : A.retryable_failure =
    { kind = A.Durable_candidate_storage_unavailable
    ; detail = "candidate storage unavailable"
    ; failed_at = 120.0
    }
  in
  assert_rejected
    "attention-candidate-storage-failure-pending"
    (A.Pending { last_failure = Some failure });
  assert_rejected
    "attention-candidate-storage-failure-judged"
    (A.Judged
       { judgment = judgment J.Not_relevant
       ; last_failure = Some failure
       })
;;

let test_cold_replay_rejects_pending_to_failed_judged () =
  with_temp_base "attention-candidate-failed-judgment-transition" @@ fun base_path ->
  let keeper_name = "sangsu" in
  let pending = candidate ~keeper_name () in
  let invalid =
    { pending with
      status =
        A.Judged
          { judgment = judgment J.Relevant
          ; last_failure =
              Some
                { kind = A.Durable_delivery_unavailable
                ; detail = "delivery was not attempted from Pending"
                ; failed_at = 120.0
                }
          }
    }
  in
  append_ledger
    (candidate_ledger_path ~base_path ~keeper_name)
    (Yojson.Safe.to_string (A.candidate_to_json pending)
     ^ "\n"
     ^ Yojson.Safe.to_string (A.candidate_to_json invalid)
     ^ "\n");
  match A.load_candidates ~base_path ~keeper_name with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "cold replay accepted Pending -> Judged-with-failure"
;;

let test_same_length_rewrite_invalidates_cached_cursor_explicitly () =
  with_temp_base "attention-candidate-cursor-rewrite" @@ fun base_path ->
  let keeper_name = "sangsu" in
  ignore (record_or_fail ~base_path (candidate ~keeper_name ()) : A.candidate);
  ignore (loaded_ids ~base_path ~keeper_name : string list);
  let path = ledger_path_or_fail ~base_path ~keeper_name in
  let bytes = load_file path in
  (match
     Fs_compat.rewrite_private_file_durable_locked_result path (fun _ ->
       Some bytes, ())
   with
   | Ok () -> ()
   | Error detail -> Alcotest.fail detail);
  (match A.load_candidates ~base_path ~keeper_name with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "same-length inode replacement served a stale cache");
  match A.load_candidates ~base_path ~keeper_name with
  | Ok [ _ ] -> ()
  | Ok _ -> Alcotest.fail "cache invalidation did not recover on the next exact read"
  | Error detail -> Alcotest.failf "cache did not recover after invalidation: %s" detail
;;

let test_concurrent_distinct_records_are_both_preserved () =
  with_temp_base "attention-candidate-concurrent-record" @@ fun base_path ->
  let keeper_name = "sangsu" in
  let first = candidate ~keeper_name ~signal:(signal ~post_id:"post-a" ()) () in
  let second = candidate ~keeper_name ~signal:(signal ~post_id:"post-b" ()) () in
  let first_domain = Domain.spawn (fun () -> A.record ~base_path first) in
  let second_domain = Domain.spawn (fun () -> A.record ~base_path second) in
  let results = [ Domain.join first_domain; Domain.join second_domain ] in
  List.iter
    (function
      | A.Recorded _ -> ()
      | A.Duplicate _ -> Alcotest.fail "distinct concurrent record became a duplicate"
      | A.Record_error detail -> Alcotest.failf "concurrent record failed: %s" detail)
    results;
  let observed = loaded_ids ~base_path ~keeper_name |> List.sort String.compare in
  let expected = [ first.candidate_id; second.candidate_id ] |> List.sort String.compare in
  Alcotest.(check (list string))
    "same-process mutation mutex preserves both records"
    expected
    observed
;;

let test_conflicting_judgment_is_explicit_and_writes_nothing () =
  with_temp_base "attention-candidate-judgment-conflict" @@ fun base_path ->
  let keeper_name = "sangsu" in
  let pending = record_or_fail ~base_path (candidate ~keeper_name ()) in
  let first = judgment J.Relevant in
  let judged =
    match A.record_judgment ~base_path pending first with
    | Ok judged -> judged
    | Error detail -> Alcotest.failf "first judgment failed: %s" detail
  in
  let path = ledger_path_or_fail ~base_path ~keeper_name in
  let before = load_file path in
  (match A.record_judgment ~base_path judged (judgment J.Not_relevant) with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "conflicting judgment was silently accepted");
  Alcotest.(check string)
    "conflicting judgment appends no row"
    before
    (load_file path)
;;

let all_not_relevant candidates =
  Ok
    (List.fold_left
       (fun map (candidate : A.candidate) ->
          A.Candidate_map.add candidate.candidate_id (judgment J.Not_relevant) map)
       A.Candidate_map.empty
       candidates)
;;

let all_relevant candidates =
  Ok
    (List.fold_left
       (fun map (candidate : A.candidate) ->
          A.Candidate_map.add candidate.candidate_id (judgment J.Relevant) map)
       A.Candidate_map.empty
       candidates)
;;

let test_old_pending_is_judged_without_wall_clock_expiry () =
  with_temp_base "board-attention-no-wall-clock-expiry" @@ fun base_path ->
  let keeper_name = "sangsu" in
  let old = { (candidate ~keeper_name ()) with recorded_at = -1_000_000.0 } in
  let _ = record_or_fail ~base_path old in
  let report =
    match
      A.For_testing.drain_pending_with_judge_batch
        ~base_path
        ~keeper_name
        ~judge_batch:all_not_relevant
    with
    | Ok report -> report
    | Error detail -> Alcotest.failf "old pending drain failed: %s" detail
  in
  Alcotest.(check int) "old row reaches judge" 1 report.attempted;
  Alcotest.(check int) "old row consumed by verdict" 1 report.consumed;
  Alcotest.(check int) "nothing remains" 0 report.remaining;
  match (only_loaded ~base_path ~keeper_name).status with
  | A.Consumed { delivery = A.Not_relevant; _ } -> ()
  | A.Consumed _ | A.Pending _ | A.Judged _ ->
    Alcotest.fail "old pending candidate was silently discarded"
;;

let test_removed_expired_status_is_rejected () =
  let legacy_json =
    match A.candidate_to_json (candidate ()) with
    | `Assoc fields ->
      `Assoc
        (("status", `Assoc [ "kind", `String "expired"; "expired_at", `Float 123.5 ])
         :: List.remove_assoc "status" fields)
    | _ -> Alcotest.fail "candidate fixture did not encode as an object"
  in
  match A.candidate_of_json legacy_json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "removed Expired status was accepted by the durable schema"
;;

let test_batch_verdict_missing_candidate_fails_whole_batch_with_evidence () =
  with_temp_base "board-attention-partial" @@ fun base_path ->
  let keeper_name = "sangsu" in
  let first = record_or_fail ~base_path (candidate ~keeper_name ()) in
  let second =
    record_or_fail
      ~base_path
      (candidate ~keeper_name ~signal:(signal ~post_id:"post-2" ()) ())
  in
  let report =
    match
      A.For_testing.drain_pending_with_judge_batch
        ~base_path
        ~keeper_name
        ~judge_batch:(fun _ ->
          Ok
            (A.Candidate_map.add
               first.candidate_id
               (judgment J.Not_relevant)
               A.Candidate_map.empty))
    with
    | Ok report -> report
    | Error detail -> Alcotest.failf "partial drain failed: %s" detail
  in
  Alcotest.(check int) "both attempted" 2 report.attempted;
  Alcotest.(check int) "partial response consumes nothing" 0 report.consumed;
  Alcotest.(check int) "whole batch remains" 2 report.remaining;
  match A.load_candidates ~base_path ~keeper_name with
  | Ok candidates ->
    List.iter
      (fun (target : A.candidate) ->
         match
           List.find_opt
             (fun (c : A.candidate) -> String.equal c.candidate_id target.candidate_id)
             candidates
         with
         | Some
             { status =
                 A.Pending
                   { last_failure =
                       Some { kind = A.Response_contract_unavailable; _ }
                   }
             ; _
             } ->
           ()
         | Some _ -> Alcotest.fail "partial response lacked contract-failure evidence"
         | None -> Alcotest.fail "partial-response candidate vanished")
      [ first; second ]
  | Error detail -> Alcotest.failf "candidate load failed: %s" detail
;;

let test_batch_failure_aborts_round_and_records_evidence () =
  with_temp_base "board-attention-abort" @@ fun base_path ->
  let keeper_name = "sangsu" in
  let recorded =
    List.map
      (fun index ->
         let post_id = Printf.sprintf "post-%d" index in
         record_or_fail
           ~base_path
           (candidate ~keeper_name ~signal:(signal ~post_id ()) ()))
      (List.init cohort_size (fun index -> index + 1))
  in
  let failure : A.retryable_failure =
    { kind = A.Provider_unavailable; detail = "429 too many concurrent"; failed_at = 100.0 }
  in
  let report =
    match
      A.For_testing.drain_pending_with_judge_batch
        ~base_path
        ~keeper_name
        ~judge_batch:(fun _ -> Error failure)
    with
    | Ok report -> report
    | Error detail -> Alcotest.failf "abort drain failed: %s" detail
  in
  Alcotest.(check int)
    "the whole exact-context cohort was attempted"
    cohort_size
    report.attempted;
  Alcotest.(check int) "nothing consumed" 0 report.consumed;
  Alcotest.(check int)
    "failed cohort remains"
    cohort_size
    report.remaining;
  match A.load_candidates ~base_path ~keeper_name with
  | Error detail -> Alcotest.failf "candidate load failed: %s" detail
  | Ok candidates ->
    let by_id (target : A.candidate) =
      List.find_opt
        (fun (c : A.candidate) -> String.equal c.candidate_id target.candidate_id)
        candidates
    in
    List.iter
      (fun (target : A.candidate) ->
         match by_id target with
         | Some { status = A.Pending { last_failure = Some observed }; _ } ->
           Alcotest.(check string)
             "attempted candidate keeps the failure evidence"
             "429 too many concurrent"
             observed.detail
         | Some _ -> Alcotest.fail "attempted candidate lost the failure evidence"
         | None -> Alcotest.fail "attempted candidate vanished")
      recorded
;;

let test_batch_failure_evidence_write_error_propagates () =
  with_temp_base "board-attention-failure-write" @@ fun base_path ->
  let keeper_name = "sangsu" in
  ignore (record_or_fail ~base_path (candidate ~keeper_name ()) : A.candidate);
  let path = ledger_path_or_fail ~base_path ~keeper_name in
  let failure : A.retryable_failure =
    { kind = A.Provider_unavailable; detail = "provider unavailable"; failed_at = 100.0 }
  in
  match
    A.For_testing.drain_pending_with_judge_batch
      ~base_path
      ~keeper_name
      ~judge_batch:(fun _ ->
        Sys.remove path;
        Unix.mkdir path 0o700;
        Error failure)
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "failure-evidence storage error was silently accepted"
;;

let test_successful_drain_uses_one_unbounded_exact_context_cohort () =
  with_temp_base "board-attention-unbounded-cohort" @@ fun base_path ->
  let keeper_name = "sangsu" in
  List.iter
    (fun index ->
       let post_id = Printf.sprintf "post-%d" index in
       ignore
         (record_or_fail
            ~base_path
            (candidate ~keeper_name ~signal:(signal ~post_id ()) ())))
    (List.init cohort_size (fun index -> index + 1));
  let calls = ref 0 in
  let report =
    match
      A.For_testing.drain_pending_with_judge_batch
        ~base_path
        ~keeper_name
        ~judge_batch:(fun candidates ->
          incr calls;
          all_not_relevant candidates)
    with
    | Ok report -> report
    | Error detail -> Alcotest.failf "one-quantum drain failed: %s" detail
  in
  Alcotest.(check int) "one provider call" 1 !calls;
  Alcotest.(check int) "whole cohort attempted" cohort_size report.attempted;
  Alcotest.(check int) "whole cohort consumed" cohort_size report.consumed;
  Alcotest.(check int) "nothing remains" 0 report.remaining
;;

let test_successful_batch_appends_two_atomic_state_sets () =
  with_temp_base "board-attention-atomic-batch" @@ fun base_path ->
  let keeper_name = "sangsu" in
  List.iter
    (fun index ->
       let post_id = Printf.sprintf "post-%d" index in
       ignore
         (record_or_fail
            ~base_path
            (candidate ~keeper_name ~signal:(signal ~post_id ()) ())))
    (List.init cohort_size (fun index -> index + 1));
  let path = ledger_path_or_fail ~base_path ~keeper_name in
  let pending_prefix = load_file path in
  let report, operations =
    with_ledger_operations (fun () ->
      match
        A.For_testing.drain_pending_with_judge_batch
          ~base_path
          ~keeper_name
          ~judge_batch:all_relevant
      with
      | Ok report -> report
      | Error detail -> Alcotest.failf "atomic batch drain failed: %s" detail)
  in
  Alcotest.(check int) "whole batch consumed" cohort_size report.consumed;
  let final_bytes = load_file path in
  Alcotest.(check bool)
    "batch state commits preserve the Pending prefix"
    true
    (String.starts_with final_bytes ~prefix:pending_prefix);
  Alcotest.(check int)
    "Pending, Judged, and Consumed each contribute one row per candidate"
    (cohort_size * 3)
    (count_ledger_lines base_path);
  (match operations with
   | [ A.Append judged; A.Append consumed ] ->
     Alcotest.(check int) "Judged append row count" cohort_size judged.rows;
     Alcotest.(check int) "Consumed append row count" cohort_size consumed.rows;
     Alcotest.(check bool) "Judged append is non-empty" true (judged.bytes > 0);
     Alcotest.(check bool) "Consumed append is non-empty" true (consumed.bytes > 0)
   | _ ->
     Alcotest.failf
       "batch drain performed %d ledger operations instead of two appends"
       (List.length operations));
  let queued =
    Keeper_event_queue_persistence.load ~base_path ~keeper_name
    |> Keeper_event_queue.length
  in
  Alcotest.(check int)
    "every relevant verdict has one durable event"
    cohort_size
    queued
;;

let test_batch_delivery_failure_preserves_all_judgments () =
  with_temp_base "board-attention-batch-delivery-error" @@ fun base_path ->
  let keeper_name = "sangsu" in
  List.iter
    (fun index ->
       let post_id = Printf.sprintf "post-%d" index in
       ignore
         (record_or_fail
            ~base_path
            (candidate ~keeper_name ~signal:(signal ~post_id ()) ())))
    [ 1; 2 ];
  let keepers_path =
    Filename.concat (Common.masc_dir_from_base_path ~base_path) "keepers"
  in
  let oc = open_out_bin keepers_path in
  output_string oc "event queue directory blocker";
  close_out oc;
  let report =
    match
      A.For_testing.drain_pending_with_judge_batch
        ~base_path
        ~keeper_name
        ~judge_batch:all_relevant
    with
    | Ok report -> report
    | Error detail -> Alcotest.failf "batch delivery failure drain failed: %s" detail
  in
  Alcotest.(check int) "delivery failure consumes none" 0 report.consumed;
  Alcotest.(check int) "both judgments remain" 2 report.remaining;
  match A.load_candidates ~base_path ~keeper_name with
  | Error detail -> Alcotest.failf "candidate load failed: %s" detail
  | Ok candidates ->
    List.iter
      (fun (candidate : A.candidate) ->
         match candidate.status with
         | A.Judged
             { last_failure = Some { kind = A.Durable_delivery_unavailable; _ }
             ; _
             } ->
           ()
         | A.Pending _ | A.Judged _ | A.Consumed _ ->
           Alcotest.fail "batch delivery failure lost a durable judgment")
      candidates
;;

let test_batch_never_mixes_persisted_keeper_contexts () =
  with_temp_base "board-attention-context-cohort" @@ fun base_path ->
  let keeper_name = "sangsu" in
  let first =
    record_or_fail
      ~base_path
      (candidate
         ~keeper_name
         ~instructions:"context-a"
         ~signal:(signal ~post_id:"post-a1" ())
         ())
  in
  let second =
    record_or_fail
      ~base_path
      (candidate
         ~keeper_name
         ~instructions:"context-b"
         ~signal:(signal ~post_id:"post-b" ())
         ())
  in
  let third =
    record_or_fail
      ~base_path
      (candidate
         ~keeper_name
         ~instructions:"context-a"
         ~signal:(signal ~post_id:"post-a2" ())
         ())
  in
  let observed_ids = ref [] in
  let report =
    match
      A.For_testing.drain_pending_with_judge_batch
        ~base_path
        ~keeper_name
        ~judge_batch:(fun candidates ->
          observed_ids := List.map (fun (c : A.candidate) -> c.candidate_id) candidates;
          all_not_relevant candidates)
    with
    | Ok report -> report
    | Error detail -> Alcotest.failf "context-cohort drain failed: %s" detail
  in
  Alcotest.(check int) "same-context cohort attempted" 2 report.attempted;
  Alcotest.(check int) "same-context cohort consumed" 2 report.consumed;
  Alcotest.(check int) "different context deferred" 1 report.remaining;
  List.iter
    (fun (expected : A.candidate) ->
       if not (List.exists (String.equal expected.candidate_id) !observed_ids)
       then Alcotest.failf "same-context candidate %s was omitted" expected.candidate_id)
    [ first; third ];
  if List.exists (String.equal second.candidate_id) !observed_ids
  then Alcotest.fail "different Keeper contexts were mixed in one provider call"
;;

let test_batch_verdict_codec_roundtrip () =
  let items : J.batch_item list =
    [ { candidate_id = "c-1"; verdict = { decision = J.Relevant; rationale = "first" } }
    ; { candidate_id = "c-2"; verdict = { decision = J.Not_relevant; rationale = "second" } }
    ]
  in
  match J.batch_of_yojson (J.batch_to_yojson items) with
  | Ok [ first; second ] ->
    Alcotest.(check string) "first id" "c-1" first.candidate_id;
    Alcotest.(check string) "second id" "c-2" second.candidate_id;
    (match first.verdict.decision with
     | J.Relevant -> ()
     | J.Not_relevant -> Alcotest.fail "first decision flipped")
  | Ok _ -> Alcotest.fail "batch codec changed the item count"
  | Error detail -> Alcotest.failf "batch codec failed: %s" detail
;;

let test_batch_verdict_codec_rejects_contract_violations () =
  let expect_error label json =
    match J.batch_of_yojson json with
    | Error _ -> ()
    | Ok _ -> Alcotest.failf "%s was accepted" label
  in
  expect_error
    "missing verdicts field"
    (`Assoc [ "items", `List [] ]);
  expect_error
    "unknown decision"
    (`Assoc
       [ ( "verdicts"
         , `List
             [ `Assoc
                 [ "candidate_id", `String "c-1"
                 ; "decision", `String "maybe"
                 ; "rationale", `String "r"
                 ]
             ] )
       ]);
  expect_error
    "empty rationale"
    (`Assoc
       [ ( "verdicts"
         , `List
             [ `Assoc
                 [ "candidate_id", `String "c-1"
                 ; "decision", `String "relevant"
                 ; "rationale", `String "  "
                 ]
             ] )
       ])
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
            "candidate codec rejects inner identity drift"
            `Quick
            test_candidate_codec_rejects_inner_identity_drift
        ; Alcotest.test_case
            "record rejects inner identity drift"
            `Quick
            test_record_rejects_inner_identity_drift
        ; Alcotest.test_case
            "retryable judge failure remains Pending"
            `Quick
            test_retryable_judge_failure_remains_pending
        ; Alcotest.test_case
            "not relevant transitions directly to Consumed"
            `Quick
            test_not_relevant_transitions_directly_to_consumed
        ; Alcotest.test_case
            "Consumed rejects retryable failure"
            `Quick
            test_consumed_candidate_rejects_retryable_failure
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
            "candidate ledger rejects cross-Keeper identity"
            `Quick
            test_candidate_ledger_rejects_cross_keeper_identity
        ; Alcotest.test_case
            "strict judgment rejects undeclared score"
            `Quick
            test_strict_judgment_contract_rejects_extra_fields
        ; Alcotest.test_case
            "runtime appends then process start compacts"
            `Quick
            test_runtime_appends_then_process_start_compacts
        ] )
    ; ( "cursor view"
      , [ Alcotest.test_case
            "runtime append preserves prefix and updates delta view"
            `Quick
            test_runtime_append_preserves_prefix_and_updates_delta_view
        ; Alcotest.test_case
            "cold replay rejects illegal status transition"
            `Quick
            test_cold_replay_rejects_illegal_status_transition
        ; Alcotest.test_case
            "compacted Consumed snapshot replays cold"
            `Quick
            test_compacted_consumed_snapshot_replays_cold
        ; Alcotest.test_case
            "cold replay rejects failure state inversion"
            `Quick
            test_cold_replay_rejects_failure_state_inversion
        ; Alcotest.test_case
            "cold replay rejects candidate-storage failure status"
            `Quick
            test_cold_replay_rejects_candidate_storage_failure_status
        ; Alcotest.test_case
            "cold replay rejects Pending to failed Judged"
            `Quick
            test_cold_replay_rejects_pending_to_failed_judged
        ; Alcotest.test_case
            "same-length rewrite invalidates cached cursor explicitly"
            `Quick
            test_same_length_rewrite_invalidates_cached_cursor_explicitly
        ; Alcotest.test_case
            "concurrent distinct records are both preserved"
            `Quick
            test_concurrent_distinct_records_are_both_preserved
        ; Alcotest.test_case
            "conflicting judgment is explicit and writes nothing"
            `Quick
            test_conflicting_judgment_is_explicit_and_writes_nothing
        ] )
    ; ( "batch drain"
      , [ Alcotest.test_case
            "old pending is never expired by wall clock"
            `Quick
            test_old_pending_is_judged_without_wall_clock_expiry
        ; Alcotest.test_case
            "removed expired status is rejected"
            `Quick
            test_removed_expired_status_is_rejected
        ; Alcotest.test_case
            "missing verdict fails the whole batch with evidence"
            `Quick
            test_batch_verdict_missing_candidate_fails_whole_batch_with_evidence
        ; Alcotest.test_case
            "batch failure aborts round with evidence"
            `Quick
            test_batch_failure_aborts_round_and_records_evidence
        ; Alcotest.test_case
            "batch failure evidence write error propagates"
            `Quick
            test_batch_failure_evidence_write_error_propagates
        ; Alcotest.test_case
            "successful drain uses one unbounded exact-context cohort"
            `Quick
            test_successful_drain_uses_one_unbounded_exact_context_cohort
        ; Alcotest.test_case
            "successful batch appends two atomic state sets"
            `Quick
            test_successful_batch_appends_two_atomic_state_sets
        ; Alcotest.test_case
            "batch delivery failure preserves all judgments"
            `Quick
            test_batch_delivery_failure_preserves_all_judgments
        ; Alcotest.test_case
            "batch never mixes persisted Keeper contexts"
            `Quick
            test_batch_never_mixes_persisted_keeper_contexts
        ; Alcotest.test_case
            "batch verdict codec roundtrip"
            `Quick
            test_batch_verdict_codec_roundtrip
        ; Alcotest.test_case
            "batch verdict codec rejects violations"
            `Quick
            test_batch_verdict_codec_rejects_contract_violations
        ] )
    ]
;;
