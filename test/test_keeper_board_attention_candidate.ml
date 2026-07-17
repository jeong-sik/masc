module A = Masc.Keeper_board_attention_candidate
module J = Masc.Keeper_board_attention_judgment
module Event_queue = Keeper_event_queue
module Event_queue_persistence = Keeper_event_queue_persistence
module Registry = Masc.Keeper_registry

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

let test_worker_record_wakes_then_owner_lane_drains () =
  with_temp_base "keeper-board-attention-owner-lane" @@ fun base_path ->
  let pending = candidate () in
  let entry =
    Registry.register
      ~base_path
      pending.keeper_name
      (meta pending.keeper_name)
  in
  Fun.protect
    ~finally:(fun () ->
      Registry.unregister ~base_path pending.keeper_name)
    (fun () ->
       let accepted =
         Domain.spawn (fun () -> A.record_and_wake ~base_path pending)
         |> Domain.join
       in
       (match accepted with
        | Ok
            { A.candidate = persisted
            ; persistence = A.Candidate_recorded
            ; wake = A.Wake_requested Registry.Signaled
            } ->
          (match persisted.status with
           | A.Pending { last_failure = None } -> ()
           | A.Pending { last_failure = Some _ } | A.Judged _ | A.Consumed _ ->
             Alcotest.fail "worker-side record invoked or mutated the judgment")
        | Ok _ -> Alcotest.fail "worker-side record returned the wrong typed acceptance"
        | Error detail -> Alcotest.failf "worker-side record failed: %s" detail);
       Alcotest.(check bool)
         "worker producer signaled the registered owner lane"
         true
         (Atomic.get entry.fiber_wakeup);
       Atomic.set entry.fiber_wakeup false;
       let report =
         match
           A.For_testing.drain_pending_with_judge
             ~base_path
             ~keeper_name:pending.keeper_name
             ~judge:(fun _ -> Ok (judgment J.Relevant))
         with
         | Ok report -> report
         | Error detail -> Alcotest.failf "owner-lane drain failed: %s" detail
       in
       Alcotest.(check int) "one candidate attempted" 1 report.attempted;
       Alcotest.(check int) "one candidate consumed" 1 report.consumed;
       Alcotest.(check int) "no candidate remains" 0 report.remaining;
       Alcotest.(check bool)
         "durable delivery signaled the owner lane"
         true
         (Atomic.get entry.fiber_wakeup);
       match
         Event_queue_persistence.load
           ~base_path
           ~keeper_name:pending.keeper_name
         |> Event_queue.to_list
       with
       | [ { payload = Event_queue.Board_attention attention; _ } ] ->
         Alcotest.(check string)
           "owner drain delivered the exact candidate"
           pending.candidate_id
           attention.candidate_id
       | _ -> Alcotest.fail "owner drain did not commit one Board_attention event")
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
  (* Record several retryable failures against the same candidate id. Each is a
     committed update; before compaction the ledger grew by one row per update
     (and each update re-parsed the whole ledger, so writes were O(n^2)). *)
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
    "ledger holds one row per distinct candidate_id"
    1
    (count_ledger_lines base_path);
  match A.load_candidates ~base_path ~keeper_name with
  | Ok [ latest ] ->
    (match latest.status with
     | A.Pending { last_failure = Some observed } ->
       Alcotest.(check string)
         "latest failure wins after compaction"
         "provider unavailable 5"
         observed.detail
     | A.Pending { last_failure = None } | A.Judged _ | A.Consumed _ ->
       Alcotest.fail "compaction dropped the latest pending failure")
  | Ok candidates ->
    Alcotest.failf "expected one compacted candidate, got %d" (List.length candidates)
  | Error detail -> Alcotest.failf "load after compaction failed: %s" detail
;;

(* --- read-side stat memo (#25003) -------------------------------------
   The memo key is (dev, ino, mtime, size). Production writes always go
   through atomic temp+rename (new inode), so the only way to observe a
   cache HIT deterministically is to mutate the file while preserving all
   four key fields: an in-place same-length byte flip plus [Unix.utimes]
   restore. A stale (pre-flip) result then proves the parse was skipped;
   bumping mtime afterwards proves invalidation. *)

let loaded_ids ~base_path ~keeper_name =
  match A.load_candidates ~base_path ~keeper_name with
  | Ok candidates -> List.map (fun (c : A.candidate) -> c.candidate_id) candidates
  | Error detail -> Alcotest.failf "candidate load failed: %s" detail
;;

(* µs-aligned so the utimes(float µs) -> stat(float ns) round trip is exact
   and the memo key compares equal across the in-place mutation. *)
let fixed_mtime = 1700000000.5
let bumped_mtime = 1700000001.5

let index_of_substring haystack needle =
  let hay_len = String.length haystack
  and needle_len = String.length needle in
  let rec loop i =
    if i + needle_len > hay_len
    then None
    else if String.equal (String.sub haystack i needle_len) needle
    then Some i
    else loop (i + 1)
  in
  loop 0
;;

let rec find_file_named ~name path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then
      Array.fold_left
        (fun found entry ->
           match found with
           | Some _ -> found
           | None -> find_file_named ~name (Filename.concat path entry))
        None
        (Sys.readdir path)
    else if String.equal (Filename.basename path) name
    then Some path
    else None
  else None
;;

let ledger_path_or_fail ~base_path ~keeper_name =
  match find_file_named ~name:(keeper_name ^ ".jsonl") base_path with
  | Some path -> path
  | None -> Alcotest.failf "ledger file for %s not found under %s" keeper_name base_path
;;

let flip_candidate_id_in_place path =
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  let content = really_input_string ic len in
  close_in ic;
  let marker = {|"candidate_id":"|} in
  let start =
    match index_of_substring content marker with
    | Some index -> index + String.length marker
    | None -> Alcotest.fail "candidate_id marker not found in ledger"
  in
  let original = content.[start] in
  let flipped = if Char.equal original 'f' then '0' else 'f' in
  let mutated =
    String.mapi (fun i c -> if i = start then flipped else c) content
  in
  Alcotest.(check int) "in-place mutation keeps length" len (String.length mutated);
  let fd = Unix.openfile path [ Unix.O_WRONLY ] 0o600 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      let written = Unix.write_substring fd mutated 0 len in
      Alcotest.(check int) "in-place write is complete" len written)
;;

let test_load_memo_skips_reparse_when_stat_key_unchanged () =
  with_temp_base "attention-read-memo-hit" (fun base_path ->
    let keeper_name = "sangsu" in
    let recorded = record_or_fail ~base_path (candidate ()) in
    let path = ledger_path_or_fail ~base_path ~keeper_name in
    Unix.utimes path fixed_mtime fixed_mtime;
    (match loaded_ids ~base_path ~keeper_name with
     | [ id ] ->
       Alcotest.(check string) "first load parses the ledger" recorded.candidate_id id
     | ids -> Alcotest.failf "expected one candidate, got %d" (List.length ids));
    flip_candidate_id_in_place path;
    Unix.utimes path fixed_mtime fixed_mtime;
    (match loaded_ids ~base_path ~keeper_name with
     | [ id ] ->
       Alcotest.(check string)
         "unchanged stat key serves the memoized parse"
         recorded.candidate_id
         id
     | ids -> Alcotest.failf "expected one candidate, got %d" (List.length ids));
    Unix.utimes path bumped_mtime bumped_mtime;
    (* Invalidation proof: a re-read parses the mutated bytes, and the flipped
       candidate_id no longer matches the content-identity digest, so the
       loader must surface the integrity error. A stale cache hit would keep
       returning [Ok] with the original id instead. *)
    match A.load_candidates ~base_path ~keeper_name with
    | Ok _ -> Alcotest.fail "mtime bump did not invalidate the memo (stale Ok served)"
    | Error detail ->
      (match index_of_substring detail "does not match" with
       | Some _ -> ()
       | None -> Alcotest.failf "unexpected load error after invalidation: %s" detail))
;;

let test_load_memo_invalidated_by_atomic_rewrite () =
  with_temp_base "attention-read-memo-rewrite" (fun base_path ->
    let keeper_name = "sangsu" in
    let first = record_or_fail ~base_path (candidate ()) in
    (match loaded_ids ~base_path ~keeper_name with
     | [ id ] -> Alcotest.(check string) "first load" first.candidate_id id
     | ids -> Alcotest.failf "expected one candidate, got %d" (List.length ids));
    let second =
      record_or_fail ~base_path (candidate ~signal:(signal ~post_id:"post-2" ()) ())
    in
    let ids = loaded_ids ~base_path ~keeper_name in
    Alcotest.(check int) "rename-rewrite is observed" 2 (List.length ids);
    if not (List.exists (String.equal second.candidate_id) ids)
    then Alcotest.fail "second candidate missing after atomic rewrite")
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
            "worker record wakes and owner lane drains"
            `Quick
            test_worker_record_wakes_then_owner_lane_drains
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
        ; Alcotest.test_case
            "update ledger compacts to distinct candidate count"
            `Quick
            test_update_ledger_compacts_to_distinct
        ] )
    ; ( "read memo"
      , [ Alcotest.test_case
            "unchanged stat key skips reparse"
            `Quick
            test_load_memo_skips_reparse_when_stat_key_unchanged
        ; Alcotest.test_case
            "atomic rewrite invalidates memo"
            `Quick
            test_load_memo_invalidated_by_atomic_rewrite
        ] )
    ]
;;
