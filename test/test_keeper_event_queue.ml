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

let latest_log_seq () =
  match Log.Ring.recent ~limit:1 () with
  | (entry : Log.Ring.entry) :: _ -> entry.seq
  | [] -> -1

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec scan offset =
    offset + needle_len <= haystack_len
    && (String.equal (String.sub haystack offset needle_len) needle || scan (offset + 1))
  in
  String.equal needle "" || scan 0

let restored_log_messages_since before_seq =
  Log.Ring.recent ~limit:20 ~module_filter:"Keeper" ~since_seq:before_seq ()
  |> List.filter_map (fun (entry : Log.Ring.entry) ->
    if contains_substring ~needle:"event_queue_snapshot: restored " entry.message
    then Some entry.message
    else None)

let claim_single ~base_path ~keeper_name ~claimed_at ~ready =
  match
    Masc.Keeper_registry_event_queue.claim_when_result
      ~base_path
      keeper_name
      ~claimed_at
      ~ready
  with
  | Error error -> Alcotest.fail ("event queue claim failed: " ^ error)
  | Ok None -> Alcotest.fail "expected an event queue lease"
  | Ok (Some lease) ->
    (match Masc.Keeper_registry_event_queue.lease_stimuli lease with
     | [ stimulus ] -> lease, stimulus
     | [] | _ :: _ :: _ ->
       Alcotest.fail "single event queue lease changed cardinality")

let settle_and_project
    ~base_path
    ~keeper_name
    ~settled_at
    ~lease
    ~settlement
  =
  let receipt =
    match
      Masc.Keeper_registry_event_queue.settle_result
        ~base_path
        keeper_name
        ~settled_at
        ~lease
        ~settlement
    with
    | Error error -> Alcotest.fail ("event queue settlement failed: " ^ error)
    | Ok (Masc.Keeper_registry_event_queue.Settled receipt)
    | Ok (Masc.Keeper_registry_event_queue.Already_settled receipt) -> receipt
  in
  match
    Masc.Keeper_registry_event_queue.mark_transition_projected_result
      ~base_path
      keeper_name
      ~transition_id:receipt.transition_id
  with
  | Ok () -> receipt
  | Error error -> Alcotest.fail ("event queue projection failed: " ^ error)

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

  let board_attention_payload ?(content = "c") candidate_id =
    Board_attention
      { candidate_id
      ; signal =
          { kind = Post_created
          ; author = "a"
          ; title = "t"
          ; content
          ; hearth = None
          ; updated_at = None
          }
      }
  in
  assert (is_board_signal (board_attention_payload "candidate-1"));
  assert (
    String.equal
      (payload_kind_label (board_attention_payload "candidate-1"))
      "board_attention");
  (match
     stimulus_of_yojson
       (stimulus_to_yojson
          { post_id = "post-attention"
          ; urgency = Normal
          ; arrived_at = 4.0
          ; payload = board_attention_payload "candidate-1"
          })
   with
   | Ok
       { payload =
           Board_attention
             { candidate_id = "candidate-1"; signal = { content = "c"; _ } }
       ; _
       } ->
     ()
   | Ok _ -> Alcotest.fail "Board_attention round-trip changed opaque identity"
   | Error detail -> Alcotest.fail ("Board_attention round-trip failed: " ^ detail));

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
      { run_id = "fus-1"
      ; ok = true
      ; resolved_answer = "ok"
      ; board_post_id = "post-1"
      ; channel = Keeper_continuation_channel.unrouted "test fixture"
      }
  in
  assert (not (is_board_signal (fusion_payload ())));
  assert (String.equal (payload_kind_label (fusion_payload ())) "fusion_completed");
  assert (
    String.equal
      (fusion_completion_post_id
         { run_id = "fus-1"
         ; ok = true
         ; resolved_answer = "ok"
         ; board_post_id = "post-1"
         ; channel = Keeper_continuation_channel.unrouted "test fixture"
         })
      "post-1");
  (* Reply-route parity: the fusion wake serializes its originating channel,
     and — like the sibling Connector_attention/Hitl_resolved rows — a legacy
     Fusion_completed row persisted before the channel field existed replays as
     [Unrouted] rather than failing the snapshot parse (a parse failure recovers
     to an empty queue, dropping every co-resident stimulus). *)
  (let routed : Keeper_event_queue.fusion_completion =
     { run_id = "fus-routed"
     ; ok = true
     ; resolved_answer = "answer"
     ; board_post_id = "post-9"
     ; channel =
         Keeper_continuation_channel.Discord
           { guild_id = None
           ; channel_id = "chan-42"
           ; parent_channel_id = None
           ; thread_id = Some "th-1"
           ; user_id = "u-7"
           }
     }
   in
   let stim : Keeper_event_queue.stimulus =
     { post_id = "post-9"
     ; urgency = Normal
     ; arrived_at = 42.0
     ; payload = Fusion_completed routed
     }
   in
   (match stimulus_of_yojson (stimulus_to_yojson stim) with
    | Ok { payload = Fusion_completed fc; _ } ->
      assert (
        match fc.channel with
        | Keeper_continuation_channel.Discord
            { channel_id = "chan-42"; thread_id = Some "th-1"; user_id = "u-7"; _ } ->
          true
        | _ -> false)
    | Ok _ -> assert false
    | Error e -> failwith e);
   let missing_channel_json =
     match stimulus_to_yojson stim with
     | `Assoc fields ->
       `Assoc
         (List.map
            (fun (k, v) ->
               if String.equal k "payload"
               then
                 ( k
                 , match v with
                   | `Assoc payload_fields ->
                     `Assoc
                       (List.filter
                          (fun (pk, _) -> not (String.equal pk "channel"))
                          payload_fields)
                   | other -> other )
               else (k, v))
            fields)
     | other -> other
   in
   match stimulus_of_yojson missing_channel_json with
   | Ok { payload = Fusion_completed fc; _ } ->
     assert (
       match fc.channel with
       | Keeper_continuation_channel.Unrouted { reason } ->
         String.equal reason "legacy: channel not captured"
       | _ -> false)
   | Ok _ -> failwith "legacy fusion row must decode as Fusion_completed"
   | Error e ->
     failwith
       (Printf.sprintf
          "legacy fusion row without a channel key must replay Unrouted, not \
           fail closed: %s"
          e));
  assert (
    String.equal
      (fusion_completion_post_id
         { run_id = "fus-2"
         ; ok = false
         ; resolved_answer = "sink_failed"
         ; board_post_id = ""
         ; channel = Keeper_continuation_channel.unrouted "test fixture"
         })
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

  (* Scheduled wake is a non-board stimulus whose enclosing occurrence id and
     payload both survive restart replay. *)
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
  (match
     stimulus_of_yojson
       (stimulus_to_yojson
          { post_id = "schedule-occurrence:codec"
          ; urgency = Immediate
          ; arrived_at = 5.0
          ; payload = Schedule_due scheduled_wake
          })
   with
   | Ok s ->
     assert (String.equal s.post_id "schedule-occurrence:codec");
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
                { approval_id = "appr-9"
                ; decision = Hitl_approved
                ; channel = Keeper_continuation_channel.unrouted "test"
                }
          ; urgency = Immediate
          ; arrived_at = 4.0
          ; payload =
              Hitl_resolved
                { approval_id = "appr-9"
                ; decision = Hitl_approved
                ; channel = Keeper_continuation_channel.unrouted "test"
                }
          })
   with
   | Ok s ->
     (match s.payload with
      | Hitl_resolved { approval_id; decision = Hitl_approved; _ } ->
        assert (String.equal approval_id "appr-9");
        assert (String.equal s.post_id "hitl-approval:appr-9")
      | _ -> Alcotest.fail "Hitl_resolved codec round-trip changed payload shape")
  | Error msg -> Alcotest.fail ("Hitl_resolved stimulus round-trip failed: " ^ msg));

  let hitl_stimulus decision =
    let resolution =
      { approval_id = "appr-first-commit"
      ; decision
      ; channel = Keeper_continuation_channel.unrouted "identity-test"
      }
    in
    { post_id = hitl_resolution_post_id resolution
    ; urgency = Immediate
    ; arrived_at = 4.0
    ; payload = Hitl_resolved resolution
    }
  in
  assert (
    not
      (stimulus_identity_equal
      (hitl_stimulus Hitl_approved)
      (hitl_stimulus (Hitl_rejected "operator declined"))));

  (* --- RFC-0315 P3 W0: Goal_assigned --- *)
  let assignment =
    { ga_goal_id = "goal-9"
    ; ga_goal_title = "Harden wake continuity"
    ; ga_assigned_by = "keeper_up"
    }
  in
  assert (
    String.equal (goal_assignment_post_id assignment) "goal-assigned:goal-9");
  assert (
    String.equal (payload_kind_label (Goal_assigned assignment)) "goal_assigned");
  (match
     stimulus_of_yojson
       (stimulus_to_yojson
          { post_id = goal_assignment_post_id assignment
          ; urgency = Normal
          ; arrived_at = 7.0
          ; payload = Goal_assigned assignment
          })
   with
   | Ok s ->
     (match s.payload with
      | Goal_assigned ga ->
        assert (String.equal ga.ga_goal_id "goal-9");
        assert (String.equal ga.ga_goal_title "Harden wake continuity");
        assert (String.equal ga.ga_assigned_by "keeper_up")
      | _ -> Alcotest.fail "Goal_assigned codec round-trip changed payload shape")
   | Error msg ->
     Alcotest.fail ("Goal_assigned stimulus round-trip failed: " ^ msg));
  (* Identity strips display-only fields: re-assigning the same goal via a
     different actor or after a title edit still dedups. *)
  let assignment_stim =
    { post_id = goal_assignment_post_id assignment
    ; urgency = Normal
    ; arrived_at = 7.0
    ; payload = Goal_assigned assignment
    }
  in
  let assignment_retitled =
    { assignment_stim with
      arrived_at = 8.0
    ; payload =
        Goal_assigned
          { assignment with
            ga_goal_title = "Harden wake continuity (v2)"
          ; ga_assigned_by = "toml_reconcile"
          }
    }
  in
  assert (stimulus_identity_equal assignment_stim assignment_retitled);
  (* Producer diff is edge-only: additions wake, removals and unchanged ids
     never do. *)
  assert (
    Masc.Keeper_goal_assignment_wake.added_goal_ids
      ~old_ids:[ "goal-1"; "goal-2" ]
      ~new_ids:[ "goal-2"; "goal-9" ]
    = [ "goal-9" ]);
  assert (
    Masc.Keeper_goal_assignment_wake.added_goal_ids
      ~old_ids:[ "goal-1" ]
      ~new_ids:[]
    = []);

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
    { post_id = "ghost"; urgency = Low; arrived_at = 0.0; payload = Bootstrap }
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
         ; payload = Bootstrap
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
               ; channel = Keeper_continuation_channel.unrouted "test fixture"
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
    | Bootstrap -> true
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

  (* --- health snapshot reads stay quiet; live hydration still announces replay. --- *)
  let base_path = temp_dir "keeper-event-queue-restore-log-gate" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      Log.set_level Log.Info;
      let keeper_name = "keeper-event-queue-restore-log-gate-test" in
      let q = enqueue empty board_stim |> fun q -> enqueue q bootstrap_stim in
      Keeper_event_queue_persistence.persist ~base_path ~keeper_name q;
      let before_health_reads = latest_log_seq () in
      ignore (Keeper_event_queue_persistence.load_snapshot_pair ~base_path ~keeper_name);
      ignore
        (Keeper_event_queue_persistence.load_snapshot_pair_with_errors
           ~base_path
           ~keeper_name);
      Alcotest.(check (list string))
        "health snapshot reads do not emit restore log"
        []
        (restored_log_messages_since before_health_reads);
      let before_live_load = latest_log_seq () in
      ignore (Keeper_event_queue_persistence.load ~base_path ~keeper_name);
      Alcotest.(check bool)
        "live load emits restore log"
        true
        (List.exists
           (contains_substring
              ~needle:"keeper=keeper-event-queue-restore-log-gate-test")
           (restored_log_messages_since before_live_load)));

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
      (match
         Keeper_event_queue_persistence.ack_consumed
           ~base_path
           ~keeper_name
           [ bootstrap_stim ]
       with
       | Ok () -> ()
       | Error error -> Alcotest.fail ("pending acknowledgement failed: " ^ error));
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
      (match
         Keeper_event_queue_persistence.ack_consumed
           ~base_path
           ~keeper_name
           [ board_stim; ghost_stim ]
       with
       | Ok () -> ()
       | Error error -> Alcotest.fail ("mixed acknowledgement failed: " ^ error));
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
      let noise_keeper_dir =
        Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) "snapshotless"
      in
      Unix.mkdir noise_keeper_dir 0o755;
      let dot_noise_keeper_dir =
        Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) ".worktrees"
      in
      Unix.mkdir dot_noise_keeper_dir 0o755;
      let json =
        Keeper_event_queue_persistence.fleet_summary_json ~now:30.0 ~base_path
      in
      Alcotest.(check string) "summary status" "ok" (string_field "status" json);
      Alcotest.(check int)
        "keeper_count excludes snapshotless runtime dirs"
        2
        (int_field "keeper_count" json);
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
      (match
         Masc.Keeper_registry_event_queue.claim_when_result
           ~base_path
           keeper_name
           ~claimed_at:1.0
           ~ready:(fun _ -> false)
       with
       | Ok None -> ()
       | Ok (Some _) -> Alcotest.fail "unready stimulus must remain queued"
       | Error error -> Alcotest.fail ("readiness claim failed: " ^ error));
      assert (
        length (Masc.Keeper_registry_event_queue.snapshot ~base_path keeper_name) = 1);
      let replay_lease, replayed =
        claim_single
          ~base_path
          ~keeper_name
          ~claimed_at:2.0
          ~ready:(fun _ -> true)
      in
      assert (String.equal replayed.post_id "p1");
      ignore
        (settle_and_project
           ~base_path
           ~keeper_name
           ~settled_at:3.0
           ~lease:replay_lease
           ~settlement:Masc.Keeper_registry_event_queue.Ack);
      assert (is_empty (Keeper_event_queue_persistence.load ~base_path ~keeper_name)));

  (* --- registry identity barrier: [base] and [base/.masc] must address one
     live atomic and the same durable owner. Two registrations followed by one
     enqueue through each alias used to leave two live entries whose snapshots
     overwrote each other on the shared canonical file. --- *)
  let base_path = temp_dir "keeper-event-queue-registry-base-alias" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.clear ();
      rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-registry-base-alias-test" in
      let base_path_masc = Filename.concat base_path Common.masc_dirname in
      let meta = meta_for_keeper keeper_name "trace-event-queue-base-alias-test" in
      let queue_post_ids queue =
        Keeper_event_queue.to_list queue
        |> List.map (fun (stimulus : Keeper_event_queue.stimulus) -> stimulus.post_id)
      in
      Masc.Keeper_registry.clear ();
      ignore (Masc.Keeper_registry.register ~base_path keeper_name meta);
      ignore
        (Masc.Keeper_registry.register
           ~base_path:base_path_masc
           keeper_name
           meta);
      let base_entry =
        match Masc.Keeper_registry.get ~base_path keeper_name with
        | Some entry -> entry
        | None -> Alcotest.fail "base-path registry entry missing"
      in
      let masc_entry =
        match Masc.Keeper_registry.get ~base_path:base_path_masc keeper_name with
        | Some entry -> entry
        | None -> Alcotest.fail "base-path/.masc registry entry missing"
      in
      Alcotest.(check bool)
        "BasePath aliases resolve one live registry entry"
        true
        (base_entry == masc_entry);
      Alcotest.(check string)
        "registry stores canonical BasePath"
        base_path
        base_entry.base_path;
      Alcotest.(check int)
        "registry contains one canonical owner"
        1
        (List.length (Masc.Keeper_registry.all ()));
      Alcotest.(check int)
        "BasePath/.masc filter sees canonical owner"
        1
        (List.length (Masc.Keeper_registry.all ~base_path:base_path_masc ()));

      Masc.Keeper_registry_event_queue.enqueue ~base_path keeper_name board_stim;
      Masc.Keeper_registry_event_queue.enqueue
        ~base_path:base_path_masc
        keeper_name
        bootstrap_stim;
      let expected_post_ids = [ "p1"; "bootstrap" ] in
      Alcotest.(check (list string))
        "both aliases publish to one live atomic"
        expected_post_ids
        (Masc.Keeper_registry_event_queue.snapshot ~base_path keeper_name
         |> queue_post_ids);
      Alcotest.(check (list string))
        "both alias stimuli share one durable snapshot"
        expected_post_ids
        (Keeper_event_queue_persistence.load
           ~base_path:base_path_masc
           ~keeper_name
         |> queue_post_ids);

      Masc.Keeper_registry.clear ();
      ignore
        (Masc.Keeper_registry.register
           ~base_path:base_path_masc
           keeper_name
           meta);
      Alcotest.(check (list string))
        "restart through alias restores both stimuli"
        expected_post_ids
        (Masc.Keeper_registry_event_queue.snapshot
           ~base_path
           keeper_name
         |> queue_post_ids));

  (* --- registry lane fairness: an unready HITL continuation stays queued
     without blocking later work. Among ready entries, exact arrival order wins
     across payload families and urgency labels. --- *)
  let base_path = temp_dir "keeper-event-queue-ready-fifo" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.clear ();
      rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-ready-fifo-test" in
      let meta = meta_for_keeper keeper_name "trace-event-queue-ready-fifo-test" in
      Masc.Keeper_registry.clear ();
      ignore (Masc.Keeper_registry.register ~base_path keeper_name meta);
      let now = Unix.gettimeofday () in
      let blocked_hitl =
        { post_id = "blocked-hitl"
        ; urgency = Immediate
        ; arrived_at = now
        ; payload =
            Hitl_resolved
              { approval_id = "approval-still-pending"
              ; decision = Hitl_approved
              ; channel = Keeper_continuation_channel.unrouted "test"
              }
        }
      in
      let ready_board =
        { post_id = "ready-board"
        ; urgency = Low
        ; arrived_at = now +. 1.0
        ; payload = board_payload ()
        }
      in
      let ready_schedule =
        { post_id = "ready-schedule"
        ; urgency = Immediate
        ; arrived_at = now +. 2.0
        ; payload = schedule_payload ()
        }
      in
      List.iter
        (Masc.Keeper_registry_event_queue.enqueue ~base_path keeper_name)
        [ blocked_hitl; ready_board; ready_schedule ];
      let ready = function
        | { payload = Hitl_resolved _; _ } -> false
        | _ -> true
      in
      let first_lease, first =
        claim_single ~base_path ~keeper_name ~claimed_at:now ~ready
      in
      assert (String.equal first.post_id "ready-board");
      ignore
        (settle_and_project
           ~base_path
           ~keeper_name
           ~settled_at:(now +. 3.0)
           ~lease:first_lease
           ~settlement:Masc.Keeper_registry_event_queue.Ack);
      let second_lease, second =
        claim_single ~base_path ~keeper_name ~claimed_at:(now +. 4.0) ~ready
      in
      assert (String.equal second.post_id "ready-schedule");
      ignore
        (settle_and_project
           ~base_path
           ~keeper_name
           ~settled_at:(now +. 5.0)
           ~lease:second_lease
           ~settlement:Masc.Keeper_registry_event_queue.Ack);
      Alcotest.(check (list string))
        "unready continuation remains in place"
        [ "blocked-hitl" ]
        (Masc.Keeper_registry_event_queue.snapshot ~base_path keeper_name
         |> queue_post_ids));

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
      let claim_and_ack expected_post_id =
        let claimed_at = Time_compat.now () in
        let lease =
          match
            Masc.Keeper_registry_event_queue.claim_when_result
              ~base_path
              keeper_name
              ~claimed_at
              ~ready:(fun _ -> true)
          with
          | Ok (Some lease) -> lease
          | Ok None ->
            Alcotest.failf
              "late registry registration did not replay %s"
              expected_post_id
          | Error error ->
            Alcotest.failf
              "late registry registration failed to claim %s: %s"
              expected_post_id
              error
        in
        let stimulus =
          match Masc.Keeper_registry_event_queue.lease_stimuli lease with
          | [ stimulus ] -> stimulus
          | [] | _ :: _ :: _ ->
            Alcotest.failf
              "late registry registration claim for %s changed cardinality"
              expected_post_id
        in
        Alcotest.(check string)
          "late registry registration replay order"
          expected_post_id
          stimulus.post_id;
        let receipt =
          match
            Masc.Keeper_registry_event_queue.settle_result
              ~base_path
              keeper_name
              ~settled_at:(Time_compat.now ())
              ~lease
              ~settlement:Masc.Keeper_registry_event_queue.Ack
          with
          | Ok (Masc.Keeper_registry_event_queue.Settled receipt) -> receipt
          | Ok (Masc.Keeper_registry_event_queue.Already_settled _) ->
            Alcotest.failf
              "late registry registration repeated settlement for %s"
              expected_post_id
          | Error error ->
            Alcotest.failf
              "late registry registration failed to settle %s: %s"
              expected_post_id
              error
        in
        match
          Masc.Keeper_registry_event_queue.mark_transition_projected_result
            ~base_path
            keeper_name
            ~transition_id:receipt.transition_id
        with
        | Ok () -> ()
        | Error error ->
          Alcotest.failf
            "late registry registration failed to project %s settlement: %s"
            expected_post_id
            error
      in
      claim_and_ack "p1";
      claim_and_ack "bootstrap";
      assert (is_empty (Keeper_event_queue_persistence.load ~base_path ~keeper_name)));

  (* A pending durable stimulus is the structural cooperative-yield signal for
     an already-running autonomous OAS loop. The classifier reads the same
     registry queue this test dequeues below; no age, count, or payload text
     heuristic participates. *)
  Eio_main.run (fun _env ->
    let base_path = temp_dir "keeper-event-queue-autonomous-yield" in
    Fun.protect
      ~finally:(fun () ->
        Masc.Keeper_registry.clear ();
        Masc.Keeper_chat_queue.For_testing.reset ();
        rm_rf base_path)
      (fun () ->
        let keeper_name = "keeper-event-queue-yield-test" in
        let meta = meta_for_keeper keeper_name "trace-event-queue-yield-test" in
        Masc.Keeper_registry.clear ();
        Masc.Keeper_chat_queue.For_testing.reset ();
        ignore
          (Masc.Keeper_chat_queue.configure_persistence ~base_path
            : Masc.Keeper_chat_queue.configure_report);
        ignore (Masc.Keeper_registry.register ~base_path keeper_name meta);
        (match
           Masc.Keeper_unified_turn_execution.autonomous_yield_request
             ~base_path
             ~keeper_name
         with
         | Ok None -> ()
         | Error error ->
           Alcotest.failf "empty queue snapshot failed: %s" error
         | Ok (Some _) ->
           Alcotest.fail "empty work queues must not request an autonomous yield");
        Masc.Keeper_registry_event_queue.enqueue
          ~base_path
          keeper_name
          bootstrap_stim;
        match
          Masc.Keeper_unified_turn_execution.autonomous_yield_request
            ~base_path
            ~keeper_name
        with
        | Ok
            (Some
               { Masc.Keeper_agent_run.reason =
                   Masc.Keeper_agent_run.Durable_stimulus_waiting
               }) ->
          ()
        | Error error ->
          Alcotest.failf "durable queue snapshot failed: %s" error
        | Ok None | Ok (Some _) ->
          Alcotest.fail "pending durable stimulus must request a typed yield"));

  (* --- critical delivery: durable enqueue succeeds before registration and
     is replayed when that keeper lane appears. --- *)
  let base_path = temp_dir "keeper-event-queue-durable-unregistered" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.clear ();
      rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-durable-unregistered-test" in
      let meta = meta_for_keeper keeper_name "trace-durable-unregistered-test" in
      Masc.Keeper_registry.clear ();
      (match
         Masc.Keeper_registry_event_queue.enqueue_durable_result
           ~base_path
           keeper_name
           board_stim
       with
       | Ok () -> ()
       | Error msg -> Alcotest.fail ("durable enqueue failed: " ^ msg));
      assert (Sys.file_exists (snapshot_path ~base_path ~keeper_name));
      ignore (Masc.Keeper_registry.register ~base_path keeper_name meta);
      let _lease, stimulus =
        claim_single
          ~base_path
          ~keeper_name
          ~claimed_at:1.0
          ~ready:(fun _ -> true)
      in
      assert (String.equal stimulus.post_id board_stim.post_id));

  (* --- critical delivery: one approval id cannot commit contradictory
     decisions across an acknowledgement retry. --- *)
  let base_path = temp_dir "keeper-event-queue-durable-decision-conflict" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-durable-decision-conflict-test" in
      let approved = hitl_stimulus Hitl_approved in
      let rejected = hitl_stimulus (Hitl_rejected "operator declined") in
      (match
         Masc.Keeper_registry_event_queue.enqueue_durable_result
           ~base_path
           keeper_name
           approved
       with
       | Ok () -> ()
       | Error msg -> Alcotest.fail ("initial durable decision failed: " ^ msg));
      (match
         Masc.Keeper_registry_event_queue.enqueue_durable_result
           ~base_path
           keeper_name
           rejected
       with
       | Error msg -> assert (String.length msg > 0)
       | Ok () -> Alcotest.fail "conflicting approval decision was accepted");
      match
        Keeper_event_queue_persistence.load ~base_path ~keeper_name
        |> Keeper_event_queue.to_list
      with
      | [ { payload = Hitl_resolved { decision = Hitl_approved; _ }; _ } ] -> ()
      | _ -> Alcotest.fail "first committed approval decision was not preserved");

  (* --- judged Board delivery: only the opaque candidate id participates in
     admission identity. Exact replay is idempotent; the same id carrying a
     different typed signal is an explicit conflict. --- *)
  let base_path = temp_dir "keeper-event-queue-board-attention-identity" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-board-attention-identity-test" in
      let first : Keeper_event_queue.stimulus =
        { post_id = "post-shared"
        ; urgency = Normal
        ; arrived_at = 10.0
        ; payload = board_attention_payload "candidate-exact"
        }
      in
      let replay = { first with arrived_at = 11.0 } in
      let conflict =
        { first with
          payload = board_attention_payload ~content:"different" "candidate-exact"
        }
      in
      (match
         Masc.Keeper_registry_event_queue.enqueue_if_missing_durable_result
           ~base_path
           ~event_id:"candidate-exact"
           keeper_name
           first
       with
       | Masc.Keeper_registry_event_queue.Enqueued -> ()
       | _ -> Alcotest.fail "first exact Board-attention event was not enqueued");
      (match
         Masc.Keeper_registry_event_queue.enqueue_if_missing_durable_result
           ~base_path
           ~event_id:"candidate-exact"
           keeper_name
           replay
       with
       | Masc.Keeper_registry_event_queue.Already_present -> ()
       | _ -> Alcotest.fail "exact Board-attention replay was not idempotent");
      (match
         Masc.Keeper_registry_event_queue.enqueue_if_missing_durable_result
           ~base_path
           ~event_id:"candidate-exact"
           keeper_name
           conflict
       with
       | Masc.Keeper_registry_event_queue.Identity_conflict _ -> ()
       | _ -> Alcotest.fail "same candidate id with different payload did not conflict");
      match
        Keeper_event_queue_persistence.load ~base_path ~keeper_name
        |> Keeper_event_queue.to_list
      with
      | [ { payload = Board_attention { signal = { content = "c"; _ }; _ }; _ } ] ->
        ()
      | _ -> Alcotest.fail "identity conflict changed the first durable payload");

  (* --- critical delivery: a registered but non-running keeper still owns a
     durable lane; only the wake hint is phase-gated. --- *)
  let base_path = temp_dir "keeper-event-queue-durable-offline" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.clear ();
      rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-durable-offline-test" in
      let meta = meta_for_keeper keeper_name "trace-durable-offline-test" in
      Masc.Keeper_registry.clear ();
      ignore (Masc.Keeper_registry.register_offline ~base_path keeper_name meta);
      (match
         Masc.Keeper_registry_event_queue.enqueue_durable_result
           ~base_path
           keeper_name
           board_stim
       with
       | Ok () -> ()
       | Error msg -> Alcotest.fail ("offline durable enqueue failed: " ^ msg));
      assert (
        length (Masc.Keeper_registry_event_queue.snapshot ~base_path keeper_name) = 1);
      assert (Sys.file_exists (snapshot_path ~base_path ~keeper_name)));

  (* --- critical delivery: an unwritable path is an explicit error, never an
     acknowledged in-memory-only stimulus. --- *)
  let base_path = temp_dir "keeper-event-queue-durable-write-error" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      write_file (Filename.concat base_path ".masc") "directory blocker";
      match
        Masc.Keeper_registry_event_queue.enqueue_durable_result
          ~base_path
          "keeper-event-queue-durable-write-error-test"
          board_stim
      with
      | Error msg -> assert (String.length msg > 0)
      | Ok () -> Alcotest.fail "durable enqueue silently accepted an invalid path");

  (* --- critical delivery: a corrupt existing snapshot is preserved for
     operator repair instead of being silently replaced with a fresh queue. --- *)
  let base_path = temp_dir "keeper-event-queue-durable-corrupt-snapshot" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-durable-corrupt-snapshot-test" in
      let path = snapshot_path ~base_path ~keeper_name in
      Fs_compat.mkdir_p (Filename.dirname path);
      write_file path "{not-json";
      match
        Masc.Keeper_registry_event_queue.enqueue_durable_result
          ~base_path
          keeper_name
          board_stim
      with
      | Error msg -> assert (String.length msg > 0)
      | Ok () -> Alcotest.fail "durable enqueue overwrote a corrupt snapshot");

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
      let consumed_lease, consumed =
        claim_single
          ~base_path
          ~keeper_name
          ~claimed_at:1.0
          ~ready:(fun _ -> true)
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
      let requeue_receipt =
        match
          Masc.Keeper_registry_event_queue.settle_result
            ~base_path
            keeper_name
            ~settled_at:2.0
            ~lease:consumed_lease
            ~settlement:
              (Masc.Keeper_registry_event_queue.Requeue
                 Masc.Keeper_registry_event_queue.Cycle_crashed)
        with
        | Ok (Masc.Keeper_registry_event_queue.Settled receipt) -> receipt
        | Ok (Masc.Keeper_registry_event_queue.Already_settled _) ->
          Alcotest.fail "first requeue unexpectedly reused a prior receipt"
        | Error error -> Alcotest.fail ("typed requeue failed: " ^ error)
      in
      assert (length (Keeper_event_queue_persistence.load ~base_path ~keeper_name) = 2);
      (match
         Masc.Keeper_registry_event_queue.settle_result
           ~base_path
           keeper_name
           ~settled_at:3.0
           ~lease:consumed_lease
           ~settlement:
             (Masc.Keeper_registry_event_queue.Requeue
                Masc.Keeper_registry_event_queue.Cycle_crashed)
       with
       | Ok (Masc.Keeper_registry_event_queue.Already_settled receipt)
         when String.equal receipt.transition_id requeue_receipt.transition_id -> ()
       | Ok (Masc.Keeper_registry_event_queue.Already_settled _)
       | Ok (Masc.Keeper_registry_event_queue.Settled _) ->
         Alcotest.fail "repeated requeue changed the durable receipt"
       | Error error -> Alcotest.fail ("idempotent requeue failed: " ^ error));
      assert (length (Keeper_event_queue_persistence.load ~base_path ~keeper_name) = 2);
      (match
         Masc.Keeper_registry_event_queue.mark_transition_projected_result
           ~base_path
           keeper_name
           ~transition_id:requeue_receipt.transition_id
       with
       | Ok () -> ()
       | Error error -> Alcotest.fail ("requeue projection failed: " ^ error));
      let replayed_lease, replayed =
        claim_single
          ~base_path
          ~keeper_name
          ~claimed_at:4.0
          ~ready:(fun _ -> true)
      in
      assert (String.equal replayed.post_id "p1");
      ignore
        (settle_and_project
           ~base_path
           ~keeper_name
           ~settled_at:5.0
           ~lease:replayed_lease
           ~settlement:Masc.Keeper_registry_event_queue.Ack);
      let _second_lease, second =
        claim_single
          ~base_path
          ~keeper_name
          ~claimed_at:6.0
          ~ready:(fun _ -> true)
      in
      assert (String.equal second.post_id "bootstrap"));

  (* RFC-0320 backward compat: pre-W2 persisted stimuli have no [channel] in
     their payload and must replay as [Unrouted], not fail — a restart
     replaying a legacy wake queue must not break. Simulate by serializing a W2
     stimulus then stripping the [channel] field before parsing back. *)
  (let strip_channel json =
     match json with
     | `Assoc top ->
       `Assoc
         (List.map
            (fun (k, v) ->
              if String.equal k "payload" then
                ( k
                , match v with
                  | `Assoc p ->
                    `Assoc
                      (List.filter (fun (pk, _) -> not (String.equal pk "channel")) p)
                  | other -> other )
              else (k, v))
            top)
     | other -> other
   in
   let hitl_stim =
     { post_id = "p-legacy"
     ; urgency = Immediate
     ; arrived_at = 1.0
     ; payload =
         Hitl_resolved
           { approval_id = "a"
           ; decision = Hitl_approved
           ; channel = Keeper_continuation_channel.unrouted "seed"
           }
     }
   in
   match stimulus_of_yojson (strip_channel (stimulus_to_yojson hitl_stim)) with
   | Ok s ->
     (match s.payload with
      | Hitl_resolved r ->
        assert (not (Keeper_continuation_channel.is_routable r.channel))
      | _ -> assert false)
   | Error _ -> assert false);

  print_endline "test_keeper_event_queue: all passed"
