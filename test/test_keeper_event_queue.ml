module Event_queue_persistence_source = Keeper_event_queue_persistence
module Keeper_event_queue_persistence = struct
  include Event_queue_persistence_source

  let load ~base_path ~keeper_name =
    match load_result ~base_path ~keeper_name with
    | Ok queue -> queue
    | Error detail -> Alcotest.fail detail
  ;;
end

let registry_snapshot ~base_path keeper_name =
  match Masc.Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
  | Ok queue -> queue
  | Error detail -> Alcotest.fail detail

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
    "event-queue-v14.json"

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

let read_file path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))

let rewrite_payload_fields ~kind ~label rewrite_fields json =
  let rewritten = ref 0 in
  let rec rewrite = function
    | `Assoc fields ->
      let fields =
        match List.assoc_opt "kind" fields with
        | Some (`String observed_kind) when String.equal observed_kind kind ->
          let next = rewrite_fields fields in
          if next <> fields then incr rewritten;
          next
        | _ -> fields
      in
      `Assoc (List.map (fun (name, value) -> name, rewrite value) fields)
    | `List values -> `List (List.map rewrite values)
    | other -> other
  in
  let rewritten_json = rewrite json in
  Alcotest.(check int)
    (Printf.sprintf "rewrote exactly one %s payload for %s" kind label)
    1
    !rewritten;
  rewritten_json

let remove_payload_field ~kind ~field =
  rewrite_payload_fields
    ~kind
    ~label:("missing " ^ field)
    (fun fields ->
       if List.mem_assoc field fields then List.remove_assoc field fields else fields)

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec scan offset =
    offset + needle_len <= haystack_len
    && (String.equal (String.sub haystack offset needle_len) needle || scan (offset + 1))
  in
  String.equal needle "" || scan 0

let event_queue_test_meta keeper_name trace_id =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String keeper_name
        ; "agent_name", `String ("keeper-" ^ keeper_name ^ "-agent")
        ; "trace_id", `String trace_id
        ])
  with
  | Ok meta -> meta
  | Error detail -> Alcotest.fail detail

let with_strict_executor f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let pool =
    Domain_pool.create
      ~sw
      ~domain_count:1
      (Eio.Stdenv.domain_mgr env)
  in
  Executor_pool_ref.For_testing.with_pool
    (Domain_pool.executor_pool pool)
    f

let project_transition_canonically ~base_path ~keeper_name ~transition_id:_ =
  with_strict_executor
  @@ fun () ->
  match
    Masc.Keeper_event_queue_recovery.project_owner_result
      ~base_path
      ~keeper_name
  with
  | Ok Masc.Keeper_event_queue_recovery.Transition_converged -> Ok ()
  | Ok _ -> Error "canonical transition projection did not converge"
  | Error _ -> Error "canonical transition projection failed"

let load_queue_state ~base_path ~keeper_name =
  match
    Keeper_event_queue_persistence.load_state_result ~base_path ~keeper_name
  with
  | Ok state -> state
  | Error detail -> Alcotest.fail detail

let stage_transfer ~base_path ~from_keeper ~to_keeper ~source ~owner_nonce ~operation_id =
  (match
     Masc.Keeper_registry_event_queue.enqueue_stimulus_durable_result
       ~base_path
       from_keeper
       source
   with
   | Masc.Keeper_registry_event_queue.Stimulus_enqueued -> ()
   | _ -> Alcotest.fail "failed to seed transfer recovery source");
  let selection =
    load_queue_state ~base_path ~keeper_name:from_keeper
    |> Keeper_event_queue_state.select_when
         ~ready:(Keeper_event_queue.stimulus_identity_equal source)
    |> function
    | Some selection -> selection
    | None -> Alcotest.fail "transfer recovery source was not selectable"
  in
  let transfer : Keeper_event_queue_persistence.accepted_transfer =
    { source = selection.source
    ; source_incarnation = selection.admitted_revision
    ; owner_nonce
    ; operator_operation_id = operation_id
    ; from_keeper
    ; to_keeper
    }
  in
  (match
     Masc.Keeper_registry_event_queue.transfer_pending_accepted_result
       ~base_path
       from_keeper
       ~current_owner_nonce:owner_nonce
       ~applied_at:101.0
       ~transfer
   with
   | Ok (Masc.Keeper_registry_event_queue.Transition_applied _) -> ()
   | Ok (Masc.Keeper_registry_event_queue.Transition_already_applied _) ->
     Alcotest.fail "first transfer recovery transition was already applied"
   | Ok
       (Masc.Keeper_registry_event_queue.Transition_committed_followup_failed
          { detail; _ }) ->
     Alcotest.fail detail
   | Error detail -> Alcotest.fail detail)

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
      ; terminal = Fusion_succeeded "ok"
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
         ; terminal = Fusion_succeeded "ok"
         ; board_post_id = "post-1"
         ; channel = Keeper_continuation_channel.unrouted "test fixture"
         })
      "fusion-run:fus-1");
  (* Reply-route parity: every continuation-bearing wake serializes its exact
     originating channel. A missing route is malformed durable state, not an
     implicit [Unrouted] destination. *)
  (let routed : Keeper_event_queue.fusion_completion =
     { run_id = "fus-routed"
     ; terminal = Fusion_succeeded "answer"
     ; board_post_id = "post-9"
     ; channel =
         (Keeper_continuation_channel.discord
            ~guild_id:None
            ~channel_id:"chan-42"
            ~parent_channel_id:None
            ~thread_id:(Some "th-1")
            ~user_id:"u-7"
          |> Result.get_ok)
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
   let without_payload_channel stimulus =
     match stimulus_to_yojson stimulus with
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
   List.iter
     (fun (label, stimulus) ->
        match stimulus_of_yojson (without_payload_channel stimulus) with
        | Error _ -> ()
        | Ok _ -> failwith (label ^ " without channel must fail explicitly"))
     [ "fusion completion", stim
     ; ( "connector attention"
       , { stim with
           post_id = "connector-route"
         ; payload =
             Connector_attention
               { event_id = "connector-route"; channel = routed.channel }
         } )
     ; ( "HITL resolution"
       , { stim with
           post_id = "hitl:approval-route"
         ; payload =
             Hitl_resolved
               { approval_id = "approval-route"
               ; decision = Hitl_approved
               ; channel = routed.channel
               }
         } )
     ]);
  assert (
    String.equal
      (fusion_completion_post_id
         { run_id = "fus-2"
         ; terminal = Fusion_failed "sink_failed"
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
  let reconciliation =
    { gr_goal_id = "goal-9"; gr_triggering_task_id = "task-4" }
  in
  let reconciliation_stim =
    { post_id = goal_reconciliation_ready_post_id reconciliation
    ; urgency = Immediate
    ; arrived_at = 9.0
    ; payload = Goal_reconciliation_ready reconciliation
    }
  in
  assert (
    String.equal
      reconciliation_stim.post_id
      "goal-reconciliation-ready:goal-9");
  assert (
    String.equal
      (payload_kind_label reconciliation_stim.payload)
      "goal_reconciliation_ready");
  (match stimulus_of_yojson (stimulus_to_yojson reconciliation_stim) with
   | Ok { payload = Goal_reconciliation_ready decoded; _ } ->
     assert (String.equal decoded.gr_goal_id "goal-9");
     assert (String.equal decoded.gr_triggering_task_id "task-4")
   | Ok _ -> Alcotest.fail "Goal_reconciliation_ready codec changed payload"
   | Error msg ->
     Alcotest.fail
       ("Goal_reconciliation_ready stimulus round-trip failed: " ^ msg));
  let prompt_event =
    match
      Masc.Keeper_world_observation.pending_board_event_of_stimulus
        ~meta:(event_queue_test_meta "goal-reconciler" "trace-goal-reconciler")
        reconciliation_stim
    with
    | Ok (Some event) -> event
    | Ok None -> Alcotest.fail "goal reconciliation wake produced no prompt event"
    | Error _ -> Alcotest.fail "goal reconciliation wake prompt projection failed"
  in
  assert (
    match prompt_event.event_kind with
    | Masc.Keeper_world_observation.Goal_reconciliation_ready -> true
    | _ -> false);
  assert (
    contains_substring
      ~needle:"Re-read Goal and Task SSOT"
      prompt_event.preview);
  (* The Board-activity partition decides which prompt section renders this
     event and whether it reaches [Keeper_contract_classifier]'s
     [board_activity_count]. Classifying a reconciliation wake as scheduled
     work compiles cleanly but drops it from the Board Activity prompt section
     and from [board_activity_count]; when the event is isolated, it also
     removes [Board_event_pending] and suppresses the intended reactive turn,
     so pin both sides here. *)
  assert (Masc.Keeper_world_observation.is_board_activity_event prompt_event);
  assert (
    not
      (Masc.Keeper_world_observation.is_board_activity_event
         { prompt_event with
           event_kind = Masc.Keeper_world_observation.Schedule_due scheduled_wake
         }));

  (* A completion-authority rejection is a system LLM result delivered to the
     producer Keeper. It is neither a Keeper identity nor a generic Board
     signal, so its typed task/verification/reason fields must survive the
     queue codec and prompt projection unchanged. *)
  let rejection : completion_authority_rejection =
    { car_task_id = "task-rejected"
    ; car_verification_id = "vrf-rejected"
    ; car_reason = "Evidence did not demonstrate the required invariant."
    ; car_authority = Masc_domain.System_llm_agent { agent_run_id = "judge-rejected" }
    }
  in
  let rejection_stimulus : stimulus =
    { post_id = completion_authority_rejection_post_id rejection
    ; urgency = Immediate
    ; arrived_at = 10.0
    ; payload = Completion_authority_rejected rejection
    }
  in
  assert (
    String.equal
      (payload_kind_label rejection_stimulus.payload)
      "completion_authority_rejected");
  assert (
    String.equal
      rejection_stimulus.post_id
      "completion-authority-rejected:task-rejected:vrf-rejected");
  (match stimulus_of_yojson (stimulus_to_yojson rejection_stimulus) with
   | Ok
       { payload =
           Completion_authority_rejected
             { car_task_id; car_verification_id; car_reason; car_authority }
       ; _
       } ->
     assert (String.equal car_task_id "task-rejected");
     assert (String.equal car_verification_id "vrf-rejected");
     assert (String.equal car_reason rejection.car_reason);
     assert (car_authority = rejection.car_authority)
   | Ok _ -> Alcotest.fail "completion rejection codec changed payload shape"
   | Error msg ->
     Alcotest.fail ("completion rejection codec failed: " ^ msg));
  let operator_rejection_stimulus =
    { rejection_stimulus with
      payload =
        Completion_authority_rejected
          { rejection with
            car_authority =
              Masc_domain.Human_operator { operator_id = "operator-rejected" }
          }
    }
  in
  (match stimulus_of_yojson (stimulus_to_yojson operator_rejection_stimulus) with
   | Ok
       { payload =
           Completion_authority_rejected
             { car_authority = Masc_domain.Human_operator { operator_id }; _ }
       ; _
       } ->
     assert (String.equal operator_id "operator-rejected")
   | Ok _ -> Alcotest.fail "operator rejection codec changed authority provenance"
   | Error msg ->
     Alcotest.fail ("operator rejection codec failed: " ^ msg));
  let rejection_event =
    match
      Masc.Keeper_world_observation.pending_board_event_of_stimulus
        ~meta:(event_queue_test_meta "producer" "trace-producer")
        rejection_stimulus
    with
    | Ok (Some event) -> event
    | Ok None -> Alcotest.fail "completion rejection produced no prompt event"
    | Error _ -> Alcotest.fail "completion rejection prompt projection failed"
  in
  assert (
    match rejection_event.event_kind with
    | Masc.Keeper_world_observation.Completion_authority_rejected decoded ->
      decoded = rejection
    | _ -> false);
  assert (String.equal rejection_event.post_id rejection_stimulus.post_id);
  assert (contains_substring ~needle:rejection.car_reason rejection_event.preview);
  assert (
    not (Masc.Keeper_world_observation.is_board_activity_event rejection_event));
  assert (
    not
      (Masc.Keeper_world_observation.is_scheduled_automation_event rejection_event));
  assert (
    Masc.Keeper_world_observation.is_completion_authority_rejection_event
      rejection_event);
  assert (
    match
      Masc.Keeper_heartbeat_stimulus_intake.event_queue_trigger_of_stimulus
        rejection_stimulus
    with
    | Some
        Masc.Keeper_world_observation.Completion_authority_rejection_stimulus ->
      true
    | _ -> false);
  assert (
    stimulus_identity_equal
      rejection_stimulus
      { rejection_stimulus with arrived_at = 11.0 });
  assert (
    not
      (stimulus_identity_equal
         rejection_stimulus
         { rejection_stimulus with
           payload =
             Completion_authority_rejected
               { rejection with car_reason = "different reason" }
         }));

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

  (* --- drain_board_all: turn-keyed digest drains every board signal
     regardless of arrival time (RFC-0334 W2). [old_board] arrived far
     outside the retired 2 s window — under the old arrival-keyed drain
     it starved in the queue and cost one extra wake→turn cycle; the
     turn digest consumes it with the rest. *)
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
  let board_digest, rest_queue = drain_board_all q_drain in
  assert (List.length board_digest = 3);
  (match board_digest with
   | first :: _ ->
     (* Explicit mentions enqueue as [Immediate], so they lead the digest. *)
     assert (String.equal first.post_id "rb2")
   | [] -> Alcotest.fail "expected board signals in digest");
  assert (
    List.exists (fun s -> String.equal s.post_id "ob1") board_digest);
  (* Non-board stimuli are not part of the board digest. *)
  assert (length rest_queue = 1);

  (* --- drain_board_all: empty queue --- *)
  let empty_board, empty_rest = drain_board_all empty in
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
               ; terminal = Fusion_failed "denied"
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
    | Fusion_completed { run_id; terminal = Fusion_failed detail; board_post_id; _ } ->
      String.equal run_id "fus-3"
      && String.equal detail "denied"
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

  (* --- transfer recovery: the source outbox is not retired until the exact
         target projection is durable, so a lost HTTP recovery operation is
         repaired by the canonical maintenance sweep. --- *)
  let base_path = temp_dir "keeper-event-queue-transfer-recovery" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
      let from_keeper = "keeper-transfer-recovery-source" in
      let to_keeper = "keeper-transfer-recovery-target" in
      stage_transfer
        ~base_path
        ~from_keeper
        ~to_keeper
        ~source:board_stim
        ~owner_nonce:23
        ~operation_id:"recover-transfer-target";
      Alcotest.(check int)
        "source outbox awaits target projection"
        1
        (load_queue_state ~base_path ~keeper_name:from_keeper
         |> Keeper_event_queue_state.transition_outbox
         |> List.length);
      Alcotest.(check int)
        "target is empty before recovery"
        0
        (registry_snapshot ~base_path to_keeper |> Keeper_event_queue.length);
      (match
         project_transition_canonically
           ~base_path
           ~keeper_name:from_keeper
           ~transition_id:"unused"
       with
       | Ok () -> ()
       | Error detail -> Alcotest.fail detail);
      let recovered_target = load_queue_state ~base_path ~keeper_name:to_keeper in
      Alcotest.(check int)
        "source outbox retires after target projection"
        0
        (load_queue_state ~base_path ~keeper_name:from_keeper
         |> Keeper_event_queue_state.transition_outbox
         |> List.length);
      Alcotest.(check int)
        "target receives the exact transferred source"
        1
        (Keeper_event_queue_state.pending recovered_target |> Keeper_event_queue.length);
      Alcotest.(check int)
        "target accounts the transfer operation durably"
        1
        (Keeper_event_queue_state.accepted_transfer_projections recovered_target
         |> List.length));

  (* --- transfer recovery failure: target storage failure is typed and keeps
         the source outbox authoritative for a later retry. --- *)
  let base_path = temp_dir "keeper-event-queue-transfer-recovery-failure" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      let from_keeper = "keeper-transfer-recovery-failure-source" in
      let to_keeper = "keeper-transfer-recovery-failure-target" in
      stage_transfer
        ~base_path
        ~from_keeper
        ~to_keeper
        ~source:board_stim
        ~owner_nonce:29
        ~operation_id:"recover-transfer-target-failure";
      let target_path =
        Filename.concat
          (Common.keepers_runtime_dir_of_base ~base_path)
          to_keeper
      in
      write_file target_path "directory blocker";
      (match
         with_strict_executor
         @@ fun () ->
         Masc.Keeper_event_queue_recovery.project_owner_result
           ~base_path
           ~keeper_name:from_keeper
       with
       | Error
           (Masc.Keeper_event_queue_recovery.Target_transfer_projection_failed
              { target_keeper; detail }) ->
         Alcotest.(check string)
           "typed target keeper"
           to_keeper
           target_keeper;
         Alcotest.(check bool)
           "typed storage detail"
           true
           (String.length detail > 0)
       | Error error ->
         Alcotest.fail
           (Masc.Keeper_event_queue_recovery.projection_error_to_string error)
       | Ok _ -> Alcotest.fail "target storage failure retired the source outbox");
      Alcotest.(check int)
        "failed target projection retains source outbox"
        1
        (load_queue_state ~base_path ~keeper_name:from_keeper
         |> Keeper_event_queue_state.transition_outbox
         |> List.length));

  (* --- a stale recovery worker cannot retire a newer transfer after it
         projected the target for an earlier transition. --- *)
  let base_path = temp_dir "keeper-event-queue-transfer-recovery-stale-worker" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      let from_keeper = "keeper-transfer-recovery-stale-source" in
      let to_keeper = "keeper-transfer-recovery-stale-target" in
      stage_transfer
        ~base_path
        ~from_keeper
        ~to_keeper
        ~source:board_stim
        ~owner_nonce:31
        ~operation_id:"recover-transfer-first";
      let first_transition_id =
        match
          load_queue_state ~base_path ~keeper_name:from_keeper
          |> Keeper_event_queue_state.transition_outbox
        with
        | [ entry ] -> entry.receipt.transition_id
        | _ -> Alcotest.fail "first transfer did not stage one outbox entry"
      in
      (match
         Masc.Keeper_reaction_ledger.project_event_queue_transition_outbox_result
           ~base_path
           ~keeper_name:from_keeper
           ~expected_transition_id:first_transition_id
       with
       | Ok () -> ()
       | Error detail -> Alcotest.fail detail);
      stage_transfer
        ~base_path
        ~from_keeper
        ~to_keeper
        ~source:bootstrap_stim
        ~owner_nonce:31
        ~operation_id:"recover-transfer-second";
      let second_transition_id =
        match
          load_queue_state ~base_path ~keeper_name:from_keeper
          |> Keeper_event_queue_state.transition_outbox
        with
        | [ entry ] -> entry.receipt.transition_id
        | _ -> Alcotest.fail "second transfer did not stage one outbox entry"
      in
      (match
         Masc.Keeper_reaction_ledger.project_event_queue_transition_outbox_result
           ~base_path
           ~keeper_name:from_keeper
           ~expected_transition_id:first_transition_id
       with
       | Error _ -> ()
       | Ok () -> Alcotest.fail "stale recovery retired the newer transfer");
      let retained_transition_id =
        match
          load_queue_state ~base_path ~keeper_name:from_keeper
          |> Keeper_event_queue_state.transition_outbox
        with
        | [ entry ] -> entry.receipt.transition_id
        | _ -> Alcotest.fail "stale recovery did not preserve one outbox entry"
      in
      Alcotest.(check string)
        "newer transfer remains authoritative"
        second_transition_id
        retained_transition_id);

  (* --- current-only hard cut: the retired v12 filename is not a read,
         migration, or overwrite source for the v14 queue. --- *)
  let base_path = temp_dir "keeper-event-queue-v14-hard-cut" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-v14-hard-cut-test" in
      let keeper_dir =
        Filename.concat
          (Common.keepers_runtime_dir_of_base ~base_path)
          keeper_name
      in
      let retired_path = Filename.concat keeper_dir "event-queue-v12.json" in
      let retired_wal_path =
        Filename.concat keeper_dir "event-queue-transitions-v2.jsonl"
      in
      Fs_compat.mkdir_p keeper_dir;
      write_file retired_path "{retired-v12-evidence";
      write_file retired_wal_path "{retired-v2-wal-evidence\n";
      assert (
        is_empty
          (Keeper_event_queue_persistence.load ~base_path ~keeper_name));
      Keeper_event_queue_persistence.persist
        ~base_path
        ~keeper_name
        (enqueue empty board_stim);
      assert (Sys.file_exists (snapshot_path ~base_path ~keeper_name));
      assert (String.equal (read_file retired_path) "{retired-v12-evidence");
      assert (
        String.equal
          (read_file retired_wal_path)
          "{retired-v2-wal-evidence\n"));

  (* --- strict persisted load rejects malformed current payloads and
         preserves the operator-reset evidence. --- *)
  (match
     stimulus_to_yojson
       { post_id = "duplicate-payload"
       ; urgency = Normal
       ; arrived_at = 9.0
       ; payload = fusion_payload ()
       }
   with
   | `Assoc fields ->
     let malformed =
       `Assoc
         (fields
          @ [ "payload", `Assoc [ "kind", `String "bootstrap" ] ])
     in
     (match stimulus_of_yojson malformed with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "stimulus with duplicate payload loaded")
   | _ -> Alcotest.fail "stimulus serializer did not emit an object");
  let duplicate_discriminator =
    stimulus_to_yojson
      { post_id = "duplicate-discriminator"
      ; urgency = Normal
      ; arrived_at = 9.5
      ; payload = fusion_payload ()
      }
    |> function
    | `Assoc stimulus_fields ->
      `Assoc
        (List.map
           (function
             | "payload", `Assoc payload_fields ->
               "payload", `Assoc (("kind", `String "bootstrap") :: payload_fields)
             | field -> field)
           stimulus_fields)
    | _ -> Alcotest.fail "stimulus serializer did not emit an object"
  in
  (match stimulus_of_yojson duplicate_discriminator with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "stimulus with duplicate payload kind loaded");
  let strict_queue =
    empty
    |> fun queue ->
    enqueue
      queue
      { post_id = "strict-persisted-fusion"
      ; urgency = Normal
      ; arrived_at = 10.0
      ; payload = fusion_payload ()
      }
  in
  let assert_strict_persisted_rejected ~label ~rewrite ~expected_detail =
    let base_path = temp_dir ("keeper-event-queue-" ^ label) in
    Fun.protect
      ~finally:(fun () -> rm_rf base_path)
      (fun () ->
        let keeper_name = "strict-persisted-" ^ label in
        Keeper_event_queue_persistence.persist
          ~base_path
          ~keeper_name
          strict_queue;
        let path = snapshot_path ~base_path ~keeper_name in
        let malformed =
          read_file path
          |> Yojson.Safe.from_string
          |> rewrite
          |> Yojson.Safe.to_string
        in
        write_file path malformed;
        (match
           Keeper_event_queue_persistence.load_state_result
             ~base_path
             ~keeper_name
         with
         | Ok _ ->
           Alcotest.failf "persisted malformed payload loaded: %s" label
         | Error detail ->
           Alcotest.(check bool)
             (label ^ " error requires reset")
             true
             (contains_substring ~needle:"reset required" detail);
           (match expected_detail with
            | None -> ()
            | Some expected ->
              Alcotest.(check bool)
                (label ^ " error preserves decoder detail")
                true
                (contains_substring ~needle:expected detail)));
        Alcotest.(check string)
          (label ^ " evidence is not rewritten")
          malformed
          (read_file path))
  in
  assert_strict_persisted_rejected
    ~label:"missing-terminal"
    ~rewrite:(remove_payload_field ~kind:"fusion_completed" ~field:"terminal")
    ~expected_detail:(Some "terminal");
  let rewrite_fusion_payload ~label rewrite_fields =
    rewrite_payload_fields ~kind:"fusion_completed" ~label rewrite_fields
  in
  let rewrite_terminal rewrite_fields fields =
    List.map
      (function
        | "terminal", `Assoc terminal_fields ->
          "terminal", `Assoc (rewrite_fields terminal_fields)
        | field -> field)
      fields
  in
  assert_strict_persisted_rejected
    ~label:"fusion-output-fields"
    ~rewrite:
      (rewrite_fusion_payload
         ~label:"unexpected output fields"
         (fun fields ->
            ("ok", `Bool true)
            :: ("resolved_answer", `String "conflicting answer")
            :: fields))
    ~expected_detail:None;
  assert_strict_persisted_rejected
    ~label:"fusion-terminal-extra-field"
    ~rewrite:
      (rewrite_fusion_payload
         ~label:"terminal extra field"
         (rewrite_terminal (fun fields -> ("unexpected", `String "value") :: fields)))
    ~expected_detail:None;
  assert_strict_persisted_rejected
    ~label:"fusion-terminal-duplicate-kind"
    ~rewrite:
      (rewrite_fusion_payload
         ~label:"terminal duplicate kind"
         (rewrite_terminal (fun fields -> ("kind", `String "failed") :: fields)))
    ~expected_detail:None;
  assert_strict_persisted_rejected
    ~label:"fusion-terminal-duplicate-message"
    ~rewrite:
      (rewrite_fusion_payload
         ~label:"terminal duplicate message"
         (rewrite_terminal (fun fields ->
            ("message", `String "conflicting message") :: fields)))
    ~expected_detail:None;

  (* --- Durable snapshot load preserves one row per exact stimulus identity. --- *)
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

  (* --- A-fix (RFC: keeper-orphan-stimulus-persistence): a consumed stimulus
         is drained from the current queue state on the genuine-ack path. Here
         the stimulus lives in event-queue-v14.json, mirroring a bootstrap enqueued
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
      (* Genuine-ack path drains the acknowledged pending source. *)
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

  (* --- durable fleet summary: health can see pending work and oldest age. --- *)
  let base_path = temp_dir "keeper-event-queue-fleet-summary" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      let pending_keeper = "keeper-event-queue-pending-summary-test" in
      let runnable_keeper = "keeper-event-queue-runnable-summary-test" in
      let old_pending = { board_stim with post_id = "old-pending"; arrived_at = 10.0 } in
      let newer_pending =
        { bootstrap_stim with post_id = "newer-pending"; arrived_at = 25.0 }
      in
      let runnable_pending =
        { ghost_stim with post_id = "runnable-pending"; arrived_at = 5.0 }
      in
      Keeper_event_queue_persistence.persist
        ~base_path
        ~keeper_name:pending_keeper
        (empty |> fun q -> enqueue q old_pending |> fun q -> enqueue q newer_pending);
      Keeper_event_queue_persistence.persist
        ~base_path
        ~keeper_name:runnable_keeper
        (enqueue empty runnable_pending);
      let noise_keeper_dir =
        Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) "snapshotless"
      in
      Unix.mkdir noise_keeper_dir 0o755;
      let dot_noise_keeper_dir =
        Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) ".worktrees"
      in
      Unix.mkdir dot_noise_keeper_dir 0o755;
      let owner_lifecycle ~keeper_name =
        if String.equal keeper_name pending_keeper
        then Keeper_event_queue_persistence.Paused_dead
        else Keeper_event_queue_persistence.Runnable
      in
      let json =
        Keeper_event_queue_persistence.fleet_summary_json
          ~now:30.0
          ~base_path
          ~owner_lifecycle
      in
      Alcotest.(check string) "summary status" "degraded" (string_field "status" json);
      Alcotest.(check int)
        "keeper_count excludes snapshotless runtime dirs"
        2
        (int_field "keeper_count" json);
      Alcotest.(check int) "pending_count" 3 (int_field "pending_count" json);
      Alcotest.(check int) "total_count" 3 (int_field "total_count" json);
      Alcotest.(check (float 0.001))
        "oldest_age_seconds"
        25.0
        (float_field "oldest_age_seconds" json);
      Alcotest.(check int)
        "runnable backlog count excludes paused owner"
        1
        (int_field "runnable_backlog_count" json);
      Alcotest.(check (float 0.001))
        "runnable oldest age excludes paused owner"
        25.0
        (float_field "runnable_oldest_age_seconds" json);
      Alcotest.(check int)
        "paused/dead backlog count"
        2
        (int_field "paused_dead_backlog_count" json);
      Alcotest.(check int)
        "paused/dead keeper count"
        1
        (List.length (list_field "paused_dead_by_keeper" json));
      Alcotest.(check (float 0.001))
        "paused/dead oldest age"
        20.0
        (float_field "paused_dead_oldest_age_seconds" json);
      Alcotest.(check bool)
        "paused/dead work requires explicit operator action"
        true
        (bool_field "operator_action_required" json);
      Alcotest.(check int)
        "pending_by_keeper count"
        2
        (List.length (list_field "pending_by_keeper" json));
      let pending_summary = keeper_summary pending_keeper json in
      let runnable_summary = keeper_summary runnable_keeper json in
      Alcotest.(check int)
        "pending keeper pending"
        2
        (int_field "pending_count" pending_summary);
      Alcotest.(check string)
        "pending keeper lifecycle"
        "paused_dead"
        (string_field "owner_lifecycle" pending_summary);
      Alcotest.(check int)
        "runnable keeper reports its stimulus as pending"
        1
        (int_field "pending_count" runnable_summary);
      Alcotest.(check string)
        "runnable keeper lifecycle"
        "runnable"
        (string_field "owner_lifecycle" runnable_summary);
      Alcotest.(check (float 0.001))
        "runnable keeper oldest age"
        25.0
        (float_field "oldest_age_seconds" runnable_summary);
      let retained_disabled_json =
        Keeper_event_queue_persistence.fleet_summary_json
          ~now:30.0
          ~base_path
          ~owner_lifecycle:(fun ~keeper_name:_ ->
            Keeper_event_queue_persistence.Retained_disabled)
      in
      Alcotest.(check int)
        "disabled retention remains its own typed backlog"
        3
        (int_field "retained_disabled_backlog_count" retained_disabled_json);
      Alcotest.(check int)
        "disabled retention does not collapse into paused/dead"
        0
        (int_field "paused_dead_backlog_count" retained_disabled_json);
      let shutdown_fenced_json =
        Keeper_event_queue_persistence.fleet_summary_json
          ~now:30.0
          ~base_path
          ~owner_lifecycle:(fun ~keeper_name:_ ->
            Keeper_event_queue_persistence.Shutdown_fenced)
      in
      Alcotest.(check int)
        "shutdown fence remains its own typed backlog"
        3
        (int_field "shutdown_fenced_backlog_count" shutdown_fenced_json);
      Alcotest.(check int)
        "shutdown fence does not collapse into paused/dead"
        0
        (int_field "paused_dead_backlog_count" shutdown_fenced_json));

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
        Keeper_event_queue_persistence.fleet_summary_json
          ~now:30.0
          ~base_path
          ~owner_lifecycle:(fun ~keeper_name:_ ->
            Keeper_event_queue_persistence.Runnable)
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

  (* --- durable fleet summary: missing lifecycle truth is not runnable. --- *)
  let base_path = temp_dir "keeper-event-queue-fleet-summary-lifecycle-missing" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-lifecycle-missing-summary-test" in
      Keeper_event_queue_persistence.persist
        ~base_path
        ~keeper_name
        (empty |> fun q -> enqueue q board_stim);
      let json =
        Keeper_event_queue_persistence.fleet_summary_json
          ~now:30.0
          ~base_path
          ~owner_lifecycle:(fun ~keeper_name:_ ->
            Keeper_event_queue_persistence.Lifecycle_unknown
              "durable keeper metadata missing")
      in
      Alcotest.(check string)
        "unknown lifecycle summary status"
        "degraded"
        (string_field "status" json);
      Alcotest.(check int)
        "unknown lifecycle is excluded from runnable backlog"
        0
        (int_field "runnable_backlog_count" json);
      Alcotest.(check int)
        "unknown lifecycle remains visible"
        1
        (int_field "unclassified_count" json);
      Alcotest.(check bool)
        "unknown lifecycle counts are incomplete"
        false
        (bool_field "counts_complete" json);
      Alcotest.(check bool)
        "unknown lifecycle requires operator action"
        true
        (bool_field "operator_action_required" json));

  (* Build the meta through the shared fixture, not a hand-written object: it
     fills every field of the current schema from
     [Keeper_meta_json_current_schema.all_fields], so a schema change cannot
     leave this helper behind. The hand-written version drifted twice -- it
     passed the removed [last_model_used] (fixed in #26064) and supplies only
     three of the schema's required fields. *)
  let meta_for_keeper keeper_name trace_id =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc [ "name", `String keeper_name; "trace_id", `String trace_id ])
    with
    | Ok meta -> meta
    | Error msg -> Alcotest.fail ("meta parse failed: " ^ msg)
  in

  (* --- registry identity barrier: [base] and [base/.masc] must address one
     live atomic and the same durable owner. Two registrations followed by one
     enqueue through each alias used to leave two live entries whose snapshots
     overwrote each other on the shared canonical file. --- *)
  let base_path = temp_dir "keeper-event-queue-registry-base-alias" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-registry-base-alias-test" in
      let base_path_masc = Filename.concat base_path Common.masc_dirname in
      let meta = meta_for_keeper keeper_name "trace-event-queue-base-alias-test" in
      let queue_post_ids queue =
        Keeper_event_queue.to_list queue
        |> List.map (fun (stimulus : Keeper_event_queue.stimulus) -> stimulus.post_id)
      in
      Masc.Keeper_registry.For_testing.clear ();
      ignore (Masc.Keeper_registry.For_testing.register ~base_path keeper_name meta);
      ignore
        (Masc.Keeper_registry.For_testing.register
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
        (registry_snapshot ~base_path keeper_name
         |> queue_post_ids);
      Alcotest.(check (list string))
        "both alias stimuli share one durable snapshot"
        expected_post_ids
        (Keeper_event_queue_persistence.load
           ~base_path:base_path_masc
           ~keeper_name
         |> queue_post_ids);

      Masc.Keeper_registry.For_testing.clear ();
      ignore
        (Masc.Keeper_registry.For_testing.register
           ~base_path:base_path_masc
           keeper_name
           meta);
      Alcotest.(check (list string))
        "restart through alias restores both stimuli"
        expected_post_ids
        (registry_snapshot
           ~base_path
           keeper_name
         |> queue_post_ids));

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
      Masc.Keeper_registry.For_testing.clear ();
      rm_rf base_path)
    (fun () ->
      let keeper_name = "keeper-event-queue-durable-offline-test" in
      let meta = meta_for_keeper keeper_name "trace-durable-offline-test" in
      Masc.Keeper_registry.For_testing.clear ();
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
        length (registry_snapshot ~base_path keeper_name) = 1);
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
