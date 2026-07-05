let temp_dir prefix =
  Filename.temp_dir prefix ""

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path

let snapshot_path ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
    "event-queue.json"

let json_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let int_field name json =
  match json_field name json with
  | Some (`Int value) -> value
  | _ -> Alcotest.failf "expected int field %S" name

let bool_field name json =
  match json_field name json with
  | Some (`Bool value) -> value
  | _ -> Alcotest.failf "expected bool field %S" name

let float_field name json =
  match json_field name json with
  | Some (`Float value) -> value
  | Some (`Int value) -> float_of_int value
  | _ -> Alcotest.failf "expected float field %S" name

let list_field name json =
  match json_field name json with
  | Some (`List values) -> values
  | _ -> Alcotest.failf "expected list field %S" name

let string_field name json =
  match json_field name json with
  | Some (`String value) -> value
  | _ -> Alcotest.failf "expected string field %S" name

let keeper_summary name json =
  match
    list_field "keepers" json
    |> List.find_opt (fun item -> String.equal (string_field "keeper_name" item) name)
  with
  | Some item -> item
  | None -> Alcotest.failf "expected keeper summary for %S" name

let write_file path contents =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc contents)

let () =
  let open Keeper_event_queue in
  let board_payload () =
    Board_signal
      { kind = Post_created
      ; author = "a"
      ; title = "t"
      ; content = "c"
      ; hearth = None
      ; updated_at = None
      }
  in

  (* --- typed payload kind labels (RFC-0020): the stimulus kind is a
         closed variant, not classified from a JSON-prefixed string --- *)
  assert (is_board_signal (board_payload ()));
  assert (not (is_board_signal Bootstrap));
  assert (String.equal (payload_kind_label (board_payload ())) "board_signal");
  assert (String.equal (payload_kind_label Bootstrap) "bootstrap");
  assert (String.equal (payload_kind_label No_progress_recovery) "no_progress_recovery");

  let reaction_payload () =
    Board_signal
      { kind =
          Reaction_changed
            { target_type = Reaction_comment
            ; target_id = "c1"
            ; user_id = "reactor"
            ; emoji = "👏"
            ; reacted = true
            }
      ; author = "reactor"
      ; title = "parent"
      ; content = "body"
      ; hearth = Some "research"
      ; updated_at = Some 5.0
      }
  in
  (match
     stimulus_of_yojson
       (stimulus_to_yojson
          { post_id = "p-reaction"
          ; urgency = Normal
          ; arrived_at = 5.0
          ; payload = reaction_payload ()
          })
   with
   | Ok s ->
     (match s.payload with
      | Board_signal
          { kind =
              Reaction_changed
                { target_type = Reaction_comment
                ; target_id
                ; user_id
                ; emoji
                ; reacted
                }
          ; author
          ; hearth = Some hearth
          ; updated_at = Some updated_at
          ; _
          } ->
        assert (String.equal s.post_id "p-reaction");
        assert (String.equal target_id "c1");
        assert (String.equal user_id "reactor");
        assert (String.equal emoji "👏");
        assert reacted;
        assert (String.equal author "reactor");
        assert (String.equal hearth "research");
        assert (Float.equal updated_at 5.0)
      | _ -> Alcotest.fail "reaction board stimulus round-trip changed payload shape")
   | Error msg -> Alcotest.fail ("reaction board stimulus round-trip failed: " ^ msg));

  (* RFC-0266: Fusion_completed is a non-board stimulus with its own label. *)
  let fusion_payload () =
    Fusion_completed
      { run_id = "fus-1"; ok = true; resolved_answer = "ok"; board_post_id = "post-1" }
  in
  assert (not (is_board_signal (fusion_payload ())));
  assert (String.equal (payload_kind_label (fusion_payload ())) "fusion_completed");
  assert (
    String.equal
      (fusion_completion_post_id
         { run_id = "fus-1"; ok = true; resolved_answer = "ok"; board_post_id = "post-1" })
      "post-1");
  assert (
    String.equal
      (fusion_completion_post_id
         { run_id = "fus-2"; ok = false; resolved_answer = "sink_failed"; board_post_id = "" })
      "fusion-run:fus-2");

  (* RFC-0290: Bg_completed is a non-board stimulus with its own label; its
     post_id falls back to "bg-run:<run_id>" when no board post correlates. *)
  let bg_payload () =
    Bg_completed
      { bg_run_id = "bg-1"
      ; bg_kind = Subprocess
      ; bg_outcome = Bg_ok "done"
      ; bg_board_post_id = "post-2"
      }
  in
  assert (not (is_board_signal (bg_payload ())));
  assert (String.equal (payload_kind_label (bg_payload ())) "bg_completed");
  assert (
    String.equal
      (bg_job_completion_post_id
         { bg_run_id = "bg-1"
         ; bg_kind = Subprocess
         ; bg_outcome = Bg_ok "done"
         ; bg_board_post_id = "post-2"
         })
      "post-2");
  assert (
    String.equal
      (bg_job_completion_post_id
         { bg_run_id = "bg-2"
         ; bg_kind = Subprocess
         ; bg_outcome = Bg_failed "exit 1"
         ; bg_board_post_id = ""
         })
      "bg-run:bg-2");

  (* Scheduled wake is a non-board stimulus with a stable schedule-derived
     post id and a codec round-trip for restart replay. *)
  let scheduled_wake =
    { schedule_id = "sched-1"
    ; due_at = 200.0
    ; payload_digest = "digest-1"
    ; title = Some "Scheduled lane wake"
    ; message = "Run the scheduled maintenance lane now."
    }
  in
  let schedule_payload () = Schedule_due scheduled_wake in
  assert (not (is_board_signal (schedule_payload ())));
  assert (String.equal (payload_kind_label (schedule_payload ())) "schedule_due");
  assert (String.equal (schedule_due_post_id scheduled_wake) "schedule-due:sched-1");
  (match
     stimulus_of_yojson
       (stimulus_to_yojson
          { post_id = schedule_due_post_id scheduled_wake
          ; urgency = Immediate
          ; arrived_at = 5.0
          ; payload = Schedule_due scheduled_wake
          })
   with
   | Ok s ->
     (match s.payload with
      | Schedule_due wake ->
        assert (String.equal wake.schedule_id "sched-1");
        assert (Float.equal wake.due_at 200.0);
        assert (String.equal wake.payload_digest "digest-1");
        assert (wake.title = Some "Scheduled lane wake");
        assert (String.equal wake.message "Run the scheduled maintenance lane now.")
      | _ -> Alcotest.fail "Schedule_due codec round-trip changed payload shape")
   | Error msg -> Alcotest.fail ("Schedule_due stimulus round-trip failed: " ^ msg));

  (* RFC-0290: Bg_completed survives the stimulus codec round-trip, preserving
     the outcome variant ([Bg_failed]) and empty board post id. *)
  (match
     stimulus_of_yojson
       (stimulus_to_yojson
          { post_id = "bgp1"
          ; urgency = Low
          ; arrived_at = 3.0
          ; payload =
              Bg_completed
                { bg_run_id = "bg-3"
                ; bg_kind = Subprocess
                ; bg_outcome = Bg_failed "boom"
                ; bg_board_post_id = ""
                }
          })
   with
   | Ok s ->
     (match s.payload with
      | Bg_completed
          { bg_run_id; bg_kind = Subprocess; bg_outcome = Bg_failed msg; bg_board_post_id }
        ->
        assert (String.equal bg_run_id "bg-3");
        assert (String.equal msg "boom");
        assert (String.equal bg_board_post_id "")
      | _ -> Alcotest.fail "Bg_completed codec round-trip changed payload shape")
   | Error msg -> Alcotest.fail ("Bg_completed stimulus round-trip failed: " ^ msg));

  (* Hitl_resolved survives the codec round-trip: the wake is persisted for
     replay when the target keeper is not registered yet, so approval_id and
     decision must round-trip intact. *)
  (match
     stimulus_of_yojson
       (stimulus_to_yojson
          { post_id =
              hitl_resolution_post_id
                { approval_id = "appr-9"; decision = Hitl_approved }
          ; urgency = Immediate
          ; arrived_at = 4.0
          ; payload = Hitl_resolved { approval_id = "appr-9"; decision = Hitl_approved }
          })
   with
   | Ok s ->
     (match s.payload with
      | Hitl_resolved { approval_id; decision } ->
        assert (String.equal approval_id "appr-9");
        assert (decision = Hitl_approved);
        assert (String.equal s.post_id "hitl-approval:appr-9")
      | _ -> Alcotest.fail "Hitl_resolved codec round-trip changed payload shape")
   | Error msg -> Alcotest.fail ("Hitl_resolved stimulus round-trip failed: " ^ msg));

  (* --- queue operations preserved --- *)
  let board_stim =
    { post_id = "p1"; urgency = Normal; arrived_at = 0.0; payload = board_payload () }
  in
  let bootstrap_stim =
    { post_id = "bootstrap"; urgency = Normal; arrived_at = 0.0; payload = Bootstrap }
  in
  let duplicate_bootstrap_stim =
    { bootstrap_stim with arrived_at = 42.0 }
  in
  let ghost_stim =
    { post_id = "ghost"; urgency = Low; arrived_at = 0.0; payload = No_progress_recovery }
  in
  let q = empty in
  assert (is_empty q);
  let q = enqueue q board_stim in
  let q = enqueue q bootstrap_stim in
  assert (length q = 2);
  assert (stimulus_identity_equal bootstrap_stim duplicate_bootstrap_stim);
  assert (List.length (uniq_stimuli [ bootstrap_stim; duplicate_bootstrap_stim ]) = 1);
  let stim, q =
    match dequeue q with
    | Some s -> s
    | None -> Alcotest.fail "dequeue should return item"
  in
  assert (String.equal stim.post_id "p1");
  assert (length q = 1);

  (* --- drain_board_window: coalesces board signals within window --- *)
  let now = Unix.gettimeofday () in
  let recent_board_1 =
    { post_id = "rb1"; urgency = Normal; arrived_at = now; payload = board_payload () }
  in
  let recent_board_2 =
    { post_id = "rb2"; urgency = Immediate; arrived_at = now; payload = board_payload () }
  in
  let old_board =
    { post_id = "ob1"; urgency = Normal; arrived_at = 0.0; payload = board_payload () }
  in
  let bootstrap_in_queue =
    { post_id = "bs1"; urgency = Normal; arrived_at = now; payload = Bootstrap }
  in
  let q_drain = empty in
  let q_drain = enqueue q_drain recent_board_1 in
  let q_drain = enqueue q_drain old_board in
  let q_drain = enqueue q_drain bootstrap_in_queue in
  let q_drain = enqueue q_drain recent_board_2 in
  let board_in_window, rest_queue = drain_board_window ~window_sec:5.0 q_drain in
  assert (List.length board_in_window = 2);
  (match board_in_window with
   | first :: _ -> assert (String.equal first.post_id "rb2") (* urgency-sorted: Immediate first *)
   | [] -> Alcotest.fail "expected at least one board signal in window");
  assert (length rest_queue = 2);

  (* --- drain_board_window: empty queue --- *)
  let empty_board, empty_rest = drain_board_window empty in
  assert (List.length empty_board = 0);
  assert (is_empty empty_rest);

  (* --- durable snapshot codec: preserves FIFO order and typed payloads --- *)
  let queue_for_snapshot =
    let q = enqueue empty board_stim in
    let q = enqueue q bootstrap_stim in
    let q =
      enqueue
        q
         { post_id = "np1"
         ; urgency = Immediate
         ; arrived_at = 1.5
         ; payload = No_progress_recovery
         }
    in
    enqueue
      q
         { post_id = "fp1"
         ; urgency = Low
         ; arrived_at = 2.5
         ; payload =
             Fusion_completed
               { run_id = "fus-3"
               ; ok = false
               ; resolved_answer = "denied"
               ; board_post_id = ""
               }
         }
  in
  let queue_for_snapshot =
    enqueue
      queue_for_snapshot
      { post_id = "sp1"
      ; urgency = Normal
      ; arrived_at = 3.5
      ; payload = Schedule_due scheduled_wake
      }
  in
  let restored =
    match queue_of_yojson (queue_to_yojson queue_for_snapshot) with
    | Ok queue -> queue
    | Error msg -> Alcotest.fail ("queue snapshot round-trip failed: " ^ msg)
  in
  assert (length restored = 5);
  let first, restored =
    match dequeue restored with
    | Some item -> item
    | None -> Alcotest.fail "snapshot restore should preserve first item"
  in
  assert (String.equal first.post_id "p1");
  let second, restored =
    match dequeue restored with
    | Some item -> item
    | None -> Alcotest.fail "snapshot restore should preserve second item"
  in
  assert (String.equal second.post_id "bootstrap");
  let third, restored =
    match dequeue restored with
    | Some item -> item
    | None -> Alcotest.fail "snapshot restore should preserve third item"
  in
  assert (String.equal third.post_id "np1");
  assert (
    match third.payload with
    | No_progress_recovery -> true
    | _ -> false);
  let fourth, restored =
    match dequeue restored with
    | Some item -> item
    | None -> Alcotest.fail "snapshot restore should preserve fourth item"
  in
  assert (String.equal fourth.post_id "fp1");
  assert (
    match fourth.payload with
    | Fusion_completed { run_id; ok; resolved_answer; board_post_id } ->
      String.equal run_id "fus-3"
      && (not ok)
      && String.equal resolved_answer "denied"
      && String.equal board_post_id ""
    | _ -> false);
  let fifth, restored =
    match dequeue restored with
    | Some item -> item
    | None -> Alcotest.fail "snapshot restore should preserve fifth item"
  in
  assert (String.equal fifth.post_id "sp1");
  assert (
    match fifth.payload with
    | Schedule_due wake ->
      String.equal wake.schedule_id scheduled_wake.schedule_id
      && String.equal wake.message scheduled_wake.message
    | _ -> false);
  assert (is_empty restored);
  (match queue_of_yojson (`Assoc [ "schema", `String "wrong"; "items", `List [] ]) with
   | Ok _ -> Alcotest.fail "wrong queue snapshot schema should be rejected"
   | Error _ -> ());

  (* --- durable snapshot store: persist/load and empty dequeue state --- *)
  let base_path = temp_dir "keeper-event-queue-persistence" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-test" in
      let q = enqueue empty board_stim |> fun q -> enqueue q bootstrap_stim in
      Keeper_event_queue_persistence.persist ~base_path ~keeper_name q;
      assert (Sys.file_exists (snapshot_path ~base_path ~keeper_name));
      let restored = Keeper_event_queue_persistence.load ~base_path ~keeper_name in
      assert (length restored = 2);
      let first, rest =
        match dequeue restored with
        | Some item -> item
        | None -> Alcotest.fail "persisted queue should restore first stimulus"
      in
      assert (String.equal first.post_id "p1");
      Keeper_event_queue_persistence.persist ~base_path ~keeper_name rest;
      let second, rest =
        match dequeue (Keeper_event_queue_persistence.load ~base_path ~keeper_name) with
        | Some item -> item
        | None -> Alcotest.fail "persisted queue should restore second stimulus"
      in
      assert (String.equal second.post_id "bootstrap");
      Keeper_event_queue_persistence.persist ~base_path ~keeper_name rest;
      assert (is_empty (Keeper_event_queue_persistence.load ~base_path ~keeper_name)));

  (* --- durable snapshot load collapses legacy duplicates that differ only by
         arrival time. --- *)
  let base_path = temp_dir "keeper-event-queue-load-dedup" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-load-dedup-test" in
      let duplicated =
        empty
        |> fun q -> enqueue q bootstrap_stim
        |> fun q -> enqueue q duplicate_bootstrap_stim
      in
      Keeper_event_queue_persistence.persist ~base_path ~keeper_name duplicated;
      let restored = Keeper_event_queue_persistence.load ~base_path ~keeper_name in
      assert (length restored = 1);
      let only, rest = Option.get (dequeue restored) in
      assert (String.equal only.post_id "bootstrap");
      assert (is_empty rest));

  (* --- durable in-flight store: ack removes only consumed stimuli --- *)
  let base_path = temp_dir "keeper-event-queue-inflight-partial-ack" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-inflight-partial-ack-test" in
      Keeper_event_queue_persistence.record_inflight
        ~base_path
        ~keeper_name
        [ board_stim; bootstrap_stim ];
      Keeper_event_queue_persistence.ack_inflight
        ~base_path
        ~keeper_name
        [ board_stim ];
      let restored = Keeper_event_queue_persistence.load ~base_path ~keeper_name in
      assert (length restored = 1);
      let remaining, rest =
        match dequeue restored with
        | Some item -> item
        | None -> Alcotest.fail "partial ack should leave unrelated in-flight stimulus"
      in
      assert (String.equal remaining.post_id "bootstrap");
      assert (is_empty rest));

  (* --- A-fix (RFC: keeper-orphan-stimulus-persistence): a consumed stimulus
         is drained from pending and inflight snapshots on the genuine-ack path.
         [ack_inflight] clears the inflight file only (it is shared with
         [requeue_front], which must leave the requeued stimulus in pending -
         covered by the requeue-front test below). Here the stimulus lives in
         the pending snapshot (event-queue.json), mirroring a bootstrap enqueued
         by supervisor launch; after ack, [load] must be empty. Without the
         A-fix this returns length 1 and accumulates across restarts. --- *)
  let base_path = temp_dir "keeper-event-queue-ack-drains-pending" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-ack-drains-pending-test" in
      Keeper_event_queue_persistence.persist
        ~base_path ~keeper_name (enqueue empty bootstrap_stim);
      assert (length (Keeper_event_queue_persistence.load ~base_path ~keeper_name) = 1);
      (* Genuine-ack path: ack_consumed drains inflight AND pending snapshot. *)
      Masc.Keeper_registry_event_queue.ack_consumed
        ~base_path keeper_name [ bootstrap_stim ];
      (* Before the A-fix this returned length 1 (pending snapshot untouched);
         after the fix the pending snapshot is drained. *)
      assert (is_empty (Keeper_event_queue_persistence.load ~base_path ~keeper_name)));

  (* --- Genuine consumed-ack handles the realistic mixed state: pending can
         contain duplicates while inflight still carries the consumed lease.
         A partial ack removes all matching consumed copies from both snapshots,
         ignores absent stimuli, and leaves unrelated pending/inflight work
         replayable exactly once after [load]'s merge. --- *)
  let base_path = temp_dir "keeper-event-queue-ack-mixed-partial" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-ack-mixed-partial-test" in
      let pending =
        empty
        |> fun q -> enqueue q board_stim
        |> fun q -> enqueue q bootstrap_stim
        |> fun q -> enqueue q board_stim
      in
      Keeper_event_queue_persistence.persist ~base_path ~keeper_name pending;
      Keeper_event_queue_persistence.record_inflight
        ~base_path
        ~keeper_name
        [ board_stim; bootstrap_stim ];
      Masc.Keeper_registry_event_queue.ack_consumed
        ~base_path
        keeper_name
        [ board_stim; ghost_stim ];
      let restored = Keeper_event_queue_persistence.load ~base_path ~keeper_name in
      assert (length restored = 1);
      let remaining, rest =
        match dequeue restored with
        | Some item -> item
        | None -> Alcotest.fail "partial consumed ack should leave unrelated stimulus"
      in
      assert (String.equal remaining.post_id "bootstrap");
      assert (is_empty rest));

  (* --- durable fleet summary: health can see pending, in-flight, and oldest age. --- *)
  let base_path = temp_dir "keeper-event-queue-fleet-summary" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      let pending_keeper = "keeper-event-queue-pending-summary-test" in
      let inflight_keeper = "keeper-event-queue-inflight-summary-test" in
      let old_pending = { board_stim with post_id = "old-pending"; arrived_at = 10.0 } in
      let newer_pending =
        { bootstrap_stim with post_id = "newer-pending"; arrived_at = 25.0 }
      in
      let inflight =
        { ghost_stim with post_id = "old-inflight"; arrived_at = 5.0 }
      in
      Keeper_event_queue_persistence.persist
        ~base_path
        ~keeper_name:pending_keeper
        (empty |> fun q -> enqueue q old_pending |> fun q -> enqueue q newer_pending);
      Keeper_event_queue_persistence.record_inflight
        ~base_path
        ~keeper_name:inflight_keeper
        [ inflight ];
      let json =
        Keeper_event_queue_persistence.fleet_summary_json ~now:30.0 ~base_path
      in
      Alcotest.(check string) "summary status" "ok" (string_field "status" json);
      Alcotest.(check int) "keeper_count" 2 (int_field "keeper_count" json);
      Alcotest.(check int) "pending_count" 2 (int_field "pending_count" json);
      Alcotest.(check int) "inflight_count" 1 (int_field "inflight_count" json);
      Alcotest.(check int) "total_count" 3 (int_field "total_count" json);
      Alcotest.(check (float 0.001))
        "oldest_age_seconds"
        25.0
        (float_field "oldest_age_seconds" json);
      Alcotest.(check int)
        "pending_by_keeper count"
        1
        (List.length (list_field "pending_by_keeper" json));
      Alcotest.(check int)
        "inflight_by_keeper count"
        1
        (List.length (list_field "inflight_by_keeper" json));
      let pending_summary = keeper_summary pending_keeper json in
      let inflight_summary = keeper_summary inflight_keeper json in
      Alcotest.(check int)
        "pending keeper pending"
        2
        (int_field "pending_count" pending_summary);
      Alcotest.(check int)
        "inflight keeper inflight"
        1
        (int_field "inflight_count" inflight_summary);
      Alcotest.(check (float 0.001))
        "inflight keeper oldest age"
        25.0
        (float_field "oldest_age_seconds" inflight_summary));

  (* --- durable fleet summary: corrupt queue snapshots must not look green. --- *)
  let base_path = temp_dir "keeper-event-queue-fleet-summary-corrupt" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-corrupt-summary-test" in
      Keeper_event_queue_persistence.persist
        ~base_path
        ~keeper_name
        (empty |> fun q -> enqueue q board_stim);
      write_file (snapshot_path ~base_path ~keeper_name) "{not-json";
      let json =
        Keeper_event_queue_persistence.fleet_summary_json ~now:30.0 ~base_path
      in
      Alcotest.(check string)
        "corrupt summary status"
        "degraded"
        (string_field "status" json);
      Alcotest.(check bool)
        "corrupt summary requires operator action"
        true
        (bool_field "operator_action_required" json);
      Alcotest.(check int)
        "corrupt summary read error count"
        1
        (int_field "read_error_count" json);
      let summary = keeper_summary keeper_name json in
      Alcotest.(check int)
        "corrupt keeper pending count fails closed"
        0
        (int_field "pending_count" summary);
      Alcotest.(check int)
        "corrupt keeper read errors"
        1
        (List.length (list_field "read_errors" summary)));

  let meta_for_keeper keeper_name trace_id =
    match
      Masc.Keeper_meta_json_parse.meta_of_json
        (`Assoc
          [ "name", `String keeper_name
          ; "agent_name", `String keeper_name
          ; "trace_id", `String trace_id
          ; "last_model_used", `String "llama:auto"
          ; "tool_access", `List []
          ])
    with
    | Ok meta -> meta
    | Error msg -> Alcotest.fail ("meta parse failed: " ^ msg)
  in

  (* --- registry integration: CAS-successful enqueue persists and register reloads --- *)
  let base_path = temp_dir "keeper-event-queue-registry" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.clear ();
      rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-registry-test" in
      let meta = meta_for_keeper keeper_name "trace-event-queue-registry-test" in
      Masc.Keeper_registry.clear ();
      ignore (Masc.Keeper_registry.register ~base_path keeper_name meta);
      Masc.Keeper_registry_event_queue.enqueue ~base_path keeper_name board_stim;
      Masc.Keeper_registry_event_queue.enqueue ~base_path keeper_name board_stim;
      assert (length (Masc.Keeper_registry_event_queue.snapshot ~base_path keeper_name) = 1);
      assert (Sys.file_exists (snapshot_path ~base_path ~keeper_name));
      Masc.Keeper_registry.clear ();
      ignore (Masc.Keeper_registry.register ~base_path keeper_name meta);
      let restored = Masc.Keeper_registry_event_queue.snapshot ~base_path keeper_name in
      assert (length restored = 1);
      let replayed =
        match Masc.Keeper_registry_event_queue.dequeue ~base_path keeper_name with
        | Some stim -> stim
        | None -> Alcotest.fail "registry reload should replay pending stimulus"
      in
      assert (String.equal replayed.post_id "p1");
      Masc.Keeper_registry_event_queue.ack_consumed ~base_path keeper_name [ replayed ];
      assert (is_empty (Keeper_event_queue_persistence.load ~base_path ~keeper_name)));

  (* --- registry unavailable window: enqueue persists before register --- *)
  let base_path = temp_dir "keeper-event-queue-unregistered" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.clear ();
      rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-unregistered-test" in
      let meta = meta_for_keeper keeper_name "trace-event-queue-unregistered-test" in
      Masc.Keeper_registry.clear ();
      Masc.Keeper_registry_event_queue.enqueue ~base_path keeper_name board_stim;
      Masc.Keeper_registry_event_queue.enqueue ~base_path keeper_name board_stim;
      Masc.Keeper_registry_event_queue.enqueue ~base_path keeper_name bootstrap_stim;
      Masc.Keeper_registry_event_queue.enqueue
        ~base_path
        keeper_name
        duplicate_bootstrap_stim;
      assert (Sys.file_exists (snapshot_path ~base_path ~keeper_name));
      let pending = Masc.Keeper_registry_event_queue.snapshot ~base_path keeper_name in
      assert (length pending = 2);
      ignore (Masc.Keeper_registry.register ~base_path keeper_name meta);
      let restored = Masc.Keeper_registry_event_queue.snapshot ~base_path keeper_name in
      assert (length restored = 2);
      let first =
        match Masc.Keeper_registry_event_queue.dequeue ~base_path keeper_name with
        | Some stim -> stim
        | None ->
          Alcotest.fail "late registry registration should replay first pre-registered stimulus"
      in
      assert (String.equal first.post_id "p1");
      let second =
        match Masc.Keeper_registry_event_queue.dequeue ~base_path keeper_name with
        | Some stim -> stim
        | None ->
          Alcotest.fail "late registry registration should replay second pre-registered stimulus"
      in
      assert (String.equal second.post_id "bootstrap");
      Masc.Keeper_registry_event_queue.ack_consumed
        ~base_path
        keeper_name
        [ first; second ];
      assert (is_empty (Keeper_event_queue_persistence.load ~base_path ~keeper_name)));

  (* --- crash recovery: consumed stimuli can be put back for replay --- *)
  let base_path = temp_dir "keeper-event-queue-requeue-front" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.clear ();
      rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-requeue-front-test" in
      let meta = meta_for_keeper keeper_name "trace-event-queue-requeue-front-test" in
      Masc.Keeper_registry.clear ();
      ignore (Masc.Keeper_registry.register ~base_path keeper_name meta);
      Masc.Keeper_registry_event_queue.enqueue ~base_path keeper_name board_stim;
      Masc.Keeper_registry_event_queue.enqueue ~base_path keeper_name bootstrap_stim;
      let consumed =
        match Masc.Keeper_registry_event_queue.dequeue ~base_path keeper_name with
        | Some stim -> stim
        | None -> Alcotest.fail "dequeue should consume the first queued stimulus"
      in
      assert (String.equal consumed.post_id "p1");
      let restart_replay = Keeper_event_queue_persistence.load ~base_path ~keeper_name in
      assert (length restart_replay = 2);
      let replay_head =
        match dequeue restart_replay with
        | Some (stim, _) -> stim
        | None -> Alcotest.fail "restart replay should keep consumed stimulus before ack"
      in
      assert (String.equal replay_head.post_id "p1");
      Masc.Keeper_registry_event_queue.requeue_front
        ~base_path
        keeper_name
        [ consumed ];
      assert (length (Keeper_event_queue_persistence.load ~base_path ~keeper_name) = 2);
      Masc.Keeper_registry_event_queue.requeue_front
        ~base_path
        keeper_name
        [ consumed ];
      assert (length (Keeper_event_queue_persistence.load ~base_path ~keeper_name) = 2);
      let replayed =
        match Masc.Keeper_registry_event_queue.dequeue ~base_path keeper_name with
        | Some stim -> stim
        | None -> Alcotest.fail "requeued stimulus should replay first"
      in
      assert (String.equal replayed.post_id "p1");
      let second =
        match Masc.Keeper_registry_event_queue.dequeue ~base_path keeper_name with
        | Some stim -> stim
        | None -> Alcotest.fail "original second stimulus should remain queued"
      in
      assert (String.equal second.post_id "bootstrap"));

  print_endline "test_keeper_event_queue: all passed"
