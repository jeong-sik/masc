(* The Gate replay/resolution wording lives in managed prompt templates
   under the config/prompts/keeper.gate_replay prefix; without a loaded
   registry the
   execution path falls back to bare data and the wording assertions below
   see nothing. Same repo-root idiom test_tool_task_coverage uses — that
   executable passes inside the CI sandbox, so the mechanism is CI-proven. *)
let () =
  Masc.Prompt_defaults.init ()
;;

module AQ = Masc.Keeper_approval_queue
module Rules = Masc.Keeper_approval_queue_rules
module Rule_types = Keeper_approval_queue_rules_types

let reserve_retry_exact ~base_path (entry : Rule_types.pending_approval) =
  AQ.reserve_summary_attempt_retry
    ~base_path
    ~id:entry.id
    ~input_hash:entry.input_hash
    ~sequence:entry.sequence
    ~expected_exact_attempt:entry.exact_attempt
    ~expected_disposition:entry.summary_attempt_disposition
    ~requested_by:"operator"
;;

let check_rearm label expected = function
  | Ok actual -> Alcotest.(check bool) label expected actual
  | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
;;

module Gate = Masc.Keeper_gate
module Registry_queue = Masc.Keeper_registry_event_queue
module Event_queue_persistence = Keeper_event_queue_persistence
module Reaction_ledger = Masc.Keeper_reaction_ledger
module Chat_store = Masc.Keeper_chat_store
module World_observation = Masc.Keeper_world_observation

(* Test-local shim for the excised [Keeper_approval_queue.resolve] wrapper:
   reproduces its unit projection over [resolve_with_policy] so these
   assertions keep exercising the production resolution path. *)
let aq_resolve ~base_path ~id ~decision =
  match AQ.resolve_with_policy ~base_path ~id ~decision () with
  | Ok _ -> Ok ()
  | Error _ as error -> error
;;

let yojson = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

let resolved_history_exn = function
  | Ok history -> history
  | Error error -> Alcotest.fail (Keeper_approval.Audit.read_error_to_string error)
;;

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_approval_queue_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir dir =
  let rec remove path =
    if Sys.is_directory path
    then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  try remove dir with
  | Sys_error _ -> ()
;;

let rec ensure_dir path =
  if Sys.file_exists path
  then ()
  else (
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let store_replay_artifact ~base_path payload =
  let store = Tool_blob_store.create ~base_path in
  Tool_blob_store.put_durable
    store
    ~bytes:payload
    ~mime:"text/plain"
;;

let durable_resolution_opt ~base_path ~keeper_name ~approval_id =
  match Registry_queue.snapshot_result ~base_path keeper_name with
  | Error reason ->
    Alcotest.failf "registry queue snapshot failed: %s" reason
  | Ok queue ->
    queue
    |> Keeper_event_queue.to_list
    |> List.find_map (fun (stimulus : Keeper_event_queue.stimulus) ->
      match stimulus.payload with
      | Keeper_event_queue.Hitl_resolved resolution
        when String.equal resolution.approval_id approval_id ->
        Some resolution
      | _ -> None)
;;

let require_some message = function
  | Some value -> value
  | None -> Alcotest.fail message
;;

let require_ok message = function
  | Ok value -> value
  | Error error -> Alcotest.fail (AQ.storage_error_to_string error)
;;

let pending_entry_exn id =
  AQ.For_testing.get_pending_entry_unchecked ~id |> require_some ("pending approval not found: " ^ id)
;;

let drop_resolution ~base_path ~keeper_name resolution =
  let post_id = Keeper_event_queue.hitl_resolution_post_id resolution in
  match Registry_queue.drop_by_post_id ~base_path keeper_name ~post_id with
  | Ok _ -> ()
  | Error reason -> Alcotest.fail reason
;;


(* Durable HITL wakes are addressed to a Keeper that must exist, so every
   submitted approval gets its recipient's metadata written first. *)
let ensure_keeper_exists ~base_path ~keeper_name =
  let json =
    `Assoc
      [ "name", `String keeper_name
      ; "trace_id", `String ("trace-" ^ keeper_name)
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Error detail -> Alcotest.fail detail
  | Ok meta ->
    (match
       Masc.Keeper_meta_store.replace_snapshot
         (Masc.Workspace.default_config base_path)
         meta
     with
     | Ok () -> ()
     | Error detail -> Alcotest.fail detail)
;;

let submit_submission_with_context
      ?turn_id
      ?request_context
      ?task_id
      ?goal_id
      ?continuation_channel
      ~base_path
      ~keeper_name
      ~input
      ()
  =
  ensure_keeper_exists ~base_path ~keeper_name;
  match
    AQ.submit_pending
      ~keeper_name
      ~tool_name:"external-effect"
      ~input
      ~base_path
      ?turn_id
      ?request_context
      ?task_id
      ?goal_id
      ?continuation_channel
      ()
  with
  | Ok submission -> submission
  | Error error -> Alcotest.fail (AQ.storage_error_to_string error)
;;

let submit_with_context
      ?turn_id
      ?request_context
      ?task_id
      ?goal_id
      ?continuation_channel
      ~base_path
      ~keeper_name
      ~input
      ()
  =
  (submit_submission_with_context
     ?turn_id
     ?request_context
     ?task_id
     ?goal_id
     ?continuation_channel
     ~base_path
     ~keeper_name
     ~input
     ())
    .approval_id
;;

let submit ~base_path ~keeper_name ~input =
  submit_with_context ~base_path ~keeper_name ~input ()
;;

let reject_and_cleanup ~base_path id =
  match aq_resolve ~base_path ~id ~decision:(Rule_types.Decision.Reject "test cleanup") with
  | Ok () -> ()
  | Error error -> Alcotest.fail (AQ.resolve_error_to_string error)
;;

let install_exn ~base_path =
  match AQ.install_persistence ~base_path with
  | Ok report -> report
  | Error error -> Alcotest.fail (AQ.install_error_to_string error)
;;

let check_failed_audit_receipt ~event_type ~stage receipt =
  Alcotest.(check bool)
    "audit event is exact"
    true
    (receipt.Keeper_approval.Audit.event_type = event_type);
  match receipt.write_result with
  | Ok () -> Alcotest.fail "audit failure was reported as recorded"
  | Error failure ->
    Alcotest.(check bool) "audit failure stage is exact" true (failure.stage = stage);
    Alcotest.(check bool)
      "audit failure detail is visible"
      true
      (String.trim failure.detail <> "")
;;

let check_append_failure event_type receipt =
  check_failed_audit_receipt
    ~event_type
    ~stage:Keeper_approval.Audit.Append
    receipt
;;

let test_pending_store_lock_serializes_eio_fibers () =
  Eio_main.run @@ fun _environment ->
  let first_entered, signal_first_entered = Eio.Promise.create () in
  let second_attempted, signal_second_attempted = Eio.Promise.create () in
  let release_first, signal_release_first = Eio.Promise.create () in
  let order = ref [] in
  Eio.Fiber.all
    [ (fun () ->
        AQ.For_testing.with_pending_store_lock (fun () ->
          order := "first_entered" :: !order;
          Eio.Promise.resolve signal_first_entered ();
          Eio.Promise.await release_first;
          order := "first_released" :: !order))
    ; (fun () ->
        Eio.Promise.await first_entered;
        Eio.Promise.resolve signal_second_attempted ();
        AQ.For_testing.with_pending_store_lock (fun () ->
          order := "second_entered" :: !order))
    ; (fun () ->
        Eio.Promise.await second_attempted;
        Eio.Promise.resolve signal_release_first ())
    ];
  Alcotest.(check (list string))
    "second fiber enters only after the yielding durable transition releases"
    [ "first_entered"; "first_released"; "second_entered" ]
    (List.rev !order)
;;

let test_dedup_never_merges_distinct_origins () =
  let base_path = temp_dir () in
  let keeper_name = "queue-distinct-origin" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let input = `Assoc [ "target", `String "same-action" ] in
       let dashboard_a =
         Keeper_continuation_channel.dashboard ~thread_id:"thread-a"
         |> Result.get_ok
       in
       let dashboard_b =
         Keeper_continuation_channel.dashboard ~thread_id:"thread-b"
         |> Result.get_ok
       in
       let first =
         submit_with_context
           ~turn_id:1
           ~continuation_channel:dashboard_a
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       let same =
         submit_with_context
           ~turn_id:1
           ~continuation_channel:dashboard_a
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       Alcotest.(check string) "same origin deduplicates" first same;
       (* The turn that asked is provenance, not origin: a next-turn retry
          of the same call folds onto the approval already pending (#28866).
          Before this change turn 2 here minted a second approval, and on
          2026-08-16 that shape produced three approvals and three replays
          of one identical web_search into the same context. *)
       let retried_next_turn =
         submit_with_context
           ~turn_id:2
           ~continuation_channel:dashboard_a
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       Alcotest.(check string)
         "next-turn retry folds onto the pending approval"
         first
         retried_next_turn;
       let another_channel =
         submit_with_context
           ~turn_id:1
           ~continuation_channel:dashboard_b
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       Alcotest.(check bool) "distinct origin has its own request" true
         (not (String.equal first another_channel));
       List.iter (reject_and_cleanup ~base_path) [ first; another_channel ])
;;

let test_multiple_resolution_projections_keep_fifo_order () =
  let base_path = temp_dir () in
  let keeper_name = "queue-projection-fifo" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let first =
         submit ~base_path ~keeper_name ~input:(`Assoc [ "target", `String "first" ])
       in
       let second =
         submit ~base_path ~keeper_name ~input:(`Assoc [ "target", `String "second" ])
       in
       List.iter (reject_and_cleanup ~base_path) [ first; second ];
       let projected_ids =
         Chat_store.load_all ~base_dir:base_path ~keeper_name
         |> List.filter_map (fun (message : Chat_store.chat_message) ->
           (* Submitting also writes a request row now, so this reads the
              resolution rows only: their order is what FIFO is about here. *)
           Option.bind message.approval_lifecycle (fun lifecycle ->
             match lifecycle.Chat_store.phase with
             | Chat_store.Approval_resolved_approved
             | Chat_store.Approval_resolved_rejected ->
               Some lifecycle.Chat_store.approval_id
             | Chat_store.Approval_requested
             | Chat_store.Approval_replay_applied
             | Chat_store.Approval_replay_applied_with_warning
             | Chat_store.Approval_replay_failed
             | Chat_store.Approval_replay_indeterminate
             | Chat_store.Approval_continuation_recorded -> None))
       in
       Alcotest.(check (list string)) "chat projection preserves resolution FIFO"
         [ first; second ] projected_ids)
;;

let test_world_observation_reconciles_resolved_approval_out_of_pending () =
  let base_path = temp_dir () in
  let keeper_name = "queue-world-reconcile" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let config = Masc.Workspace.default_config base_path in
       let meta =
         match
           Masc_test_deps.meta_of_json_fixture
             (`Assoc
                [ "name", `String keeper_name
                ; "trace_id", `String ("trace-" ^ keeper_name)
                ])
         with
         | Ok meta -> meta
         | Error detail -> Alcotest.fail detail
       in
       (match Masc.Keeper_meta_store.replace_snapshot config meta with
        | Ok () -> ()
        | Error detail -> Alcotest.fail detail);
       let approval_id =
         submit_with_context
           ~task_id:"task-1037"
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "command", `String "git fetch origin main" ])
           ()
       in
       let before =
         World_observation.read_approval_authority_observation ~config ~meta
       in
       (match before.state with
        | World_observation.Approval_authority_complete -> ()
        | Approval_authority_partial _ | Approval_authority_unavailable ->
          Alcotest.fail "fresh pending store was not complete");
       Alcotest.(check (list string))
         "the exact pending id is current"
         [ approval_id ]
         (List.map
            (fun
              (row : World_observation.pending_approval_observation) ->
               row.approval_id)
            before.pending);
       reject_and_cleanup ~base_path approval_id;
       let after =
         World_observation.read_approval_authority_observation ~config ~meta
       in
       (match after.state with
        | World_observation.Approval_authority_complete -> ()
        | Approval_authority_partial _ | Approval_authority_unavailable ->
          Alcotest.fail "resolved store was not complete");
       Alcotest.(check int)
         "the resolved approval is no longer pending"
         0
         (List.length after.pending);
       Alcotest.(check bool)
         "resolution advances the same snapshot revision"
         true
         (after.revision > before.revision);
       let rendered =
         Masc.Keeper_unified_prompt.format_approval_authority_observation after
       in
       Alcotest.(check bool)
         "the next turn explicitly invalidates the historical pending claim"
         true
         (String_util.contains_substring
            rendered
            "Only listed IDs are pending; absent historical IDs are stale"))
;;

(* The measured 2026-08-16 incident, end to end: the retry lands after the
   approval resolved but before its grant was consumed. The resubmission must
   fold onto that unconsumed grant; once the grant is consumed the same call
   is a new effect and opens a fresh approval; a rejected approval never
   absorbs a retry. *)
let test_retry_folds_onto_unconsumed_grant_until_consumed () =
  let base_path = temp_dir () in
  let keeper_name = "queue-grant-fold" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let input = `Assoc [ "target", `String "same-network-read" ] in
       let first =
         submit_submission_with_context
           ~turn_id:11
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       (match
          AQ.resolve_with_policy
            ~base_path
            ~id:first.approval_id
            ~decision:Rule_types.Decision.Approve
            ()
        with
        | Ok _ -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       let retried =
         submit_submission_with_context
           ~turn_id:12
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       Alcotest.(check string)
         "retry after approval reuses the approved id"
         first.approval_id
         retried.approval_id;
       (match retried.disposition with
        | AQ.Folded_onto_unconsumed_grant -> ()
        | AQ.Pending_created _ ->
          Alcotest.fail "retry opened a second approval over an unconsumed grant"
        | AQ.Pending_deduplicated ->
          Alcotest.fail "resolved approval was still reported as pending");
       (match
          AQ.consume_approved_resolution
            ~base_path
            ~id:first.approval_id
            ~keeper_name
            ~tool_name:"external-effect"
            ~input
        with
        | Ok (AQ.Consumption_committed _) -> ()
        | Ok (AQ.Consumption_already_committed | AQ.Consumption_not_matching) ->
          Alcotest.fail "grant consumption did not commit"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       let after_consumption =
         submit_submission_with_context
           ~turn_id:13
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       Alcotest.(check bool)
         "the same call after consumption is a new effect"
         true
         (not (String.equal first.approval_id after_consumption.approval_id));
       (match after_consumption.disposition with
        | AQ.Pending_created _ -> ()
        | AQ.Pending_deduplicated | AQ.Folded_onto_unconsumed_grant ->
          Alcotest.fail "consumed grant absorbed a new effect request");
       reject_and_cleanup ~base_path after_consumption.approval_id;
       let after_rejection =
         submit_submission_with_context
           ~turn_id:14
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       Alcotest.(check bool)
         "a rejected approval never absorbs a retry"
         true
         (not
            (String.equal after_consumption.approval_id after_rejection.approval_id));
       (match after_rejection.disposition with
        | AQ.Pending_created _ -> ()
        | AQ.Pending_deduplicated | AQ.Folded_onto_unconsumed_grant ->
          Alcotest.fail "rejected delivery absorbed a retry");
       reject_and_cleanup ~base_path after_rejection.approval_id)
;;

let check_update label expected = function
  | Ok actual -> Alcotest.(check bool) label expected actual
  | Error error -> Alcotest.fail (AQ.summary_transition_error_to_string error)
;;

type exact_identity =
  { approval_id_arg : string
  ; input_hash_arg : string
  ; sequence_arg : int
  ; slot_id_arg : string
  ; call_id_arg : string
  ; plan_fingerprint_arg : string
  ; request_body_sha256_arg : string
  }

let exact_identity
      ?(slot_id = "slot-exact")
      ?(call_id = "call-exact")
      ?(plan_fingerprint = "plan-exact")
      ?(request_body_sha256 = String.make 64 'a')
      id
  =
  let entry = pending_entry_exn id in
  { approval_id_arg = entry.id
  ; input_hash_arg = entry.input_hash
  ; sequence_arg = entry.sequence
  ; slot_id_arg = slot_id
  ; call_id_arg = call_id
  ; plan_fingerprint_arg = plan_fingerprint
  ; request_body_sha256_arg = request_body_sha256
  }
;;

let run_exact_transition transition identity =
  transition
    ~id:identity.approval_id_arg
    ~input_hash:identity.input_hash_arg
    ~sequence:identity.sequence_arg
    ~slot_id:identity.slot_id_arg
    ~call_id:identity.call_id_arg
    ~plan_fingerprint:identity.plan_fingerprint_arg
    ~request_body_sha256:identity.request_body_sha256_arg
;;

let complete_exact identity summary =
  AQ.complete_summary_exact_attempt
    ~id:identity.approval_id_arg
    ~input_hash:identity.input_hash_arg
    ~sequence:identity.sequence_arg
    ~slot_id:identity.slot_id_arg
    ~call_id:identity.call_id_arg
    ~plan_fingerprint:identity.plan_fingerprint_arg
    ~request_body_sha256:identity.request_body_sha256_arg
    ~summary
;;

let quarantine_exact identity cause =
  AQ.quarantine_summary_exact_attempt
    ~id:identity.approval_id_arg
    ~input_hash:identity.input_hash_arg
    ~sequence:identity.sequence_arg
    ~slot_id:identity.slot_id_arg
    ~call_id:identity.call_id_arg
    ~plan_fingerprint:identity.plan_fingerprint_arg
    ~request_body_sha256:identity.request_body_sha256_arg
    ~cause
;;

let check_exact_update label expected = function
  | Ok { AQ.changed; write_outcome = AQ.Fsync_completed } ->
    Alcotest.(check bool) label expected changed
  | Ok { write_outcome = AQ.Visible_sync_unconfirmed detail; _ } ->
    Alcotest.failf "%s returned visible durability uncertainty: %s" label detail
  | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
;;

let run_exact_transition_with_writer transition ~writer identity =
  transition
    ~save_file_atomic_strict_staged:writer
    ~id:identity.approval_id_arg
    ~input_hash:identity.input_hash_arg
    ~sequence:identity.sequence_arg
    ~slot_id:identity.slot_id_arg
    ~call_id:identity.call_id_arg
    ~plan_fingerprint:identity.plan_fingerprint_arg
    ~request_body_sha256:identity.request_body_sha256_arg
;;

let visible_after_rename_writer_with exception_ path body =
  match Fs_compat.save_file_atomic path body with
  | Error reason -> Alcotest.failf "visible writer could not replace %s: %s" path reason
  | Ok () ->
    Error
      { Fs_compat.path
      ; stage = Fs_compat.After_rename
      ; exception_
      ; backtrace = Printexc.get_raw_backtrace ()
      }
;;

let visible_after_rename_writer =
  visible_after_rename_writer_with (Failure "injected parent sync failure")
;;

let visible_after_rename_cancellation_writer =
  visible_after_rename_writer_with
    (Eio.Cancel.Cancelled (Failure "injected cancellation after rename"))
;;

let before_rename_writer path _body =
  Error
    { Fs_compat.path
    ; stage = Fs_compat.Before_rename
    ; exception_ = Failure "injected pre-rename failure"
    ; backtrace = Printexc.get_raw_backtrace ()
    }
;;

let before_rename_cancellation_writer ~payload ~backtrace path _body =
  Error
    { Fs_compat.path
    ; stage = Fs_compat.Before_rename
    ; exception_ = Eio.Cancel.Cancelled payload
    ; backtrace
    }
;;

let check_visible_update label expected = function
  | Ok
      { AQ.changed
      ; write_outcome = AQ.Visible_sync_unconfirmed detail
      } ->
    Alcotest.(check bool) (label ^ " changed") expected changed;
    Alcotest.(check bool) (label ^ " detail") true (String.trim detail <> "")
  | Ok { write_outcome = AQ.Fsync_completed; _ } ->
    Alcotest.failf "%s unexpectedly reported durable" label
  | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
;;

let expect_summary_rejection label = function
  | Error
      (AQ.Summary_transition_rejected
        (AQ.Summary_exact_attempt_bound _)) ->
    ()
  | Error error ->
    Alcotest.failf
      "%s returned the wrong rejection: %s"
      label
      (AQ.summary_transition_error_to_string error)
  | Ok _ -> Alcotest.failf "%s accepted an execution-uncertain entry" label
;;

let exact_summary ?(context_summary = "Exact attempt summary") model_run_id :
    Rule_types.hitl_context_summary
  =
  { summary_version = 2
  ; generated_at = Unix.gettimeofday ()
  ; model_run_id
  ; context_summary
  ; key_questions = []
  ; judgment = Rule_types.Approve
  ; rationale = "The exact durable attempt supports this judgment."
  }
;;

let read_pending_snapshot ~base_path =
  Yojson.Safe.from_file (AQ.For_testing.pending_store_path ~base_path)
;;

let read_pending_snapshot_bytes ~base_path =
  In_channel.with_open_bin
    (AQ.For_testing.pending_store_path ~base_path)
    In_channel.input_all
;;

let write_pending_snapshot ~base_path json =
  let path = AQ.For_testing.pending_store_path ~base_path in
  ensure_dir (Filename.dirname path);
  Out_channel.with_open_text path (fun channel ->
    output_string channel (Yojson.Safe.pretty_to_string json))
;;

let delivery_json ~entry ~remember_rule =
  `Assoc
    [ "entry", entry
    ; "decision", `Assoc [ "kind", `String "approve" ]
    ; "source", `String "human_operator"
    ; "remember_rule", `Bool remember_rule
    ; "rule_expires_at", `Null
    ; "created_by", `Null
    ; "grant_consumed", `Bool false
    ]
;;

let test_install_serializes_snapshot_read_with_same_base_mutation () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       write_pending_snapshot
         ~base_path
         (`Assoc
             [ "version", `Int 9
            ; "next_sequence", `Int 1
            ; "pending", `List []
            ; "deliveries", `List []
            ]);
       Eio_main.run @@ fun _environment ->
       let snapshot_loaded, signal_snapshot_loaded = Eio.Promise.create () in
       let mutation_attempted, signal_mutation_attempted = Eio.Promise.create () in
       let release_install, signal_release_install = Eio.Promise.create () in
       let install_done, signal_install_done = Eio.Promise.create () in
       let mutation_done, signal_mutation_done = Eio.Promise.create () in
       let mutation_completed_before_release = ref false in
       Eio.Fiber.all
         [ (fun () ->
             let result =
               AQ.For_testing.install_persistence_with_after_load_hook
                 ~base_path
                 ~after_load:(fun () ->
                   Eio.Promise.resolve signal_snapshot_loaded ();
                   Eio.Promise.await release_install)
             in
             Eio.Promise.resolve signal_install_done result)
         ; (fun () ->
             Eio.Promise.await snapshot_loaded;
             Eio.Promise.resolve signal_mutation_attempted ();
             let id =
               submit
                 ~base_path
                 ~keeper_name:"queue-install-race"
                 ~input:(`Assoc [ "target", `String "after-load" ])
             in
             Eio.Promise.resolve signal_mutation_done id)
         ; (fun () ->
             Eio.Promise.await mutation_attempted;
             mutation_completed_before_release :=
               Option.is_some (Eio.Promise.peek mutation_done);
             Eio.Promise.resolve signal_release_install ())
         ];
       Alcotest.(check bool)
         "same-base mutation waits for snapshot installation"
         false
         !mutation_completed_before_release;
       let report = Eio.Promise.await install_done in
       let mutation_id = Eio.Promise.await mutation_done in
       (match report with
        | Error error -> Alcotest.fail (AQ.install_error_to_string error)
        | Ok report -> Alcotest.(check int) "empty snapshot installed" 0 report.loaded_pending);
       let pending =
         AQ.list_pending_entries_for_workspace ~base_path
         |> require_ok "read installed workspace queue"
       in
       Alcotest.(check int) "mutation remains in memory" 1 (List.length pending);
       Alcotest.(check bool)
         "mutation id remains addressable"
         true
         (Option.is_some (AQ.For_testing.get_pending_entry_unchecked ~id:mutation_id));
       let open Yojson.Safe.Util in
       let persisted_ids =
         read_pending_snapshot ~base_path
         |> member "pending"
         |> to_list
         |> List.map (fun entry -> entry |> member "id" |> to_string)
       in
       Alcotest.(check bool)
         "mutation remains in the durable snapshot"
         true
         (List.mem mutation_id persisted_ids))
;;

let test_submit_is_nonblocking_and_exactly_deduplicated () =
  let base_path = temp_dir () in
  let keeper_name = "queue-exact-submit" in
  let audit_appends = ref 0 in
  let sse_frames = ref [] in
  let subscriber_id = "approval-submit-exact-dedupe" in
  let pending_sse_count () =
    List.fold_left
      (fun count frame ->
         match Masc.Sse.data_payload_of_frame frame with
         | Error Masc.Sse.Missing_data_payload -> count
         | Ok payload ->
           let open Yojson.Safe.Util in
           let event = Yojson.Safe.from_string payload in
           if event |> member "type" |> to_string_option = Some "approval:pending"
           then count + 1
           else count)
      0
      !sse_frames
  in
  Fun.protect
    ~finally:(fun () ->
      Masc.Sse.unsubscribe_external subscriber_id;
      Keeper_approval.Audit.For_testing.reset_store ();
      cleanup_dir base_path)
    (fun () ->
       Masc.Sse.subscribe_external
         ~id:subscriber_id
         ~callback:(fun (event : Masc.Sse.external_event) ->
           sse_frames := event.Masc.Sse.ext_frame :: !sse_frames)
         ();
       Keeper_approval.Audit.For_testing.reset_store ();
       Keeper_approval.Audit.For_testing.set_append_jsonl
         (fun _path _json -> incr audit_appends);
       ignore (install_exn ~base_path);
       let input =
         `Assoc
           [ "target", `String "document"
           ; "payload", `Assoc [ "text", `String "hello"; "nonce", `Int 1 ]
           ]
       in
       let request_context =
         `Assoc
           [ ( "initial"
             , `Assoc
                 [ "history_messages", `List [ `String "older exact turn" ]
                 ; "base_system_prompt", `String "exact base policy"
                 ; "turn_system_prompt", `String "exact turn policy"
                 ; "user_message", `String "write the exact document"
                 ] )
           ; "completed_tool_calls", `List []
           ]
       in
       let first_submission =
         submit_submission_with_context
           ~turn_id:12
           ~request_context
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       let first = first_submission.approval_id in
       (match first_submission.disposition with
        | AQ.Pending_created { write_result = Ok (); _ } -> ()
        | AQ.Pending_created { write_result = Error _; _ } ->
          Alcotest.fail "new pending request did not persist its audit"
        | AQ.Pending_deduplicated | AQ.Folded_onto_unconsumed_grant ->
          Alcotest.fail "new pending request was reported as deduplicated");
       let reordered =
         `Assoc
           [ "payload", `Assoc [ "nonce", `Int 1; "text", `String "hello" ]
           ; "target", `String "document"
           ]
       in
       let same_submission =
         submit_submission_with_context
           ~turn_id:12
           ~request_context
           ~base_path
           ~keeper_name
           ~input:reordered
           ()
       in
       let same = same_submission.approval_id in
       Alcotest.(check string) "same exact request" first same;
       (match same_submission.disposition with
        | AQ.Pending_deduplicated -> ()
        | AQ.Folded_onto_unconsumed_grant ->
          Alcotest.fail "pending duplicate matched a delivery, not the pending entry"
        | AQ.Pending_created _ ->
          Alcotest.fail "exact duplicate reported a second pending commit");
       Alcotest.(check int)
         "exact duplicate emits no second pending audit"
         1
         !audit_appends;
       Alcotest.(check int)
         "exact duplicate emits no second pending SSE"
         1
         (pending_sse_count ());
       let open Yojson.Safe.Util in
       let persisted_entry =
         read_pending_snapshot ~base_path
         |> member "pending"
         |> to_list
         |> List.find (fun entry -> String.equal (entry |> member "id" |> to_string) first)
       in
       Alcotest.(check int)
         "exact context wire version"
         1
         (persisted_entry |> member "request_context_version" |> to_int);
       let changed =
         submit
           ~base_path
           ~keeper_name
           ~input:
             (`Assoc
                [ "target", `String "document"
                ; "payload", `Assoc [ "text", `String "hello"; "nonce", `Int 2 ]
                ])
       in
       Alcotest.(check bool) "changed field is a different request" true
         (not (String.equal first changed));
       Alcotest.(check int) "changed request emits its own pending audit" 2 !audit_appends;
       Alcotest.(check int)
         "changed request emits its own pending SSE"
         2
         (pending_sse_count ());
       Alcotest.(check int) "first request sequence" 1 (pending_entry_exn first).sequence;
       Alcotest.(check int)
         "dedup does not consume sequence"
         2
         (pending_entry_exn changed).sequence;
       (match AQ.For_testing.get_pending_entry_unchecked ~id:first with
        | None -> Alcotest.fail "pending request missing"
        | Some entry ->
          Alcotest.(check bool) "summary is not started by queue" true
            (entry.summary_status = Rule_types.Summary_not_requested);
          Alcotest.check (Alcotest.option yojson)
            "exact outer-turn context"
            (Some request_context)
            entry.request_context);
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       (match AQ.For_testing.get_pending_entry_unchecked ~id:first with
        | Some entry ->
          Alcotest.check (Alcotest.option yojson)
            "outer-turn context survives restart"
            (Some request_context)
            entry.request_context
        | None -> Alcotest.fail "pending request was not restored");
       reject_and_cleanup ~base_path first;
       reject_and_cleanup ~base_path changed)
;;

let test_monotonic_sequence_survives_restart () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let first = submit ~base_path ~keeper_name:"sequence-owner" ~input:(`Int 1) in
       let second = submit ~base_path ~keeper_name:"sequence-owner" ~input:(`Int 2) in
       Alcotest.(check int) "first durable sequence" 1 (pending_entry_exn first).sequence;
       Alcotest.(check int) "second durable sequence" 2 (pending_entry_exn second).sequence;
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let third = submit ~base_path ~keeper_name:"sequence-owner" ~input:(`Int 3) in
       Alcotest.(check int) "restart continues sequence" 3 (pending_entry_exn third).sequence;
       let open Yojson.Safe.Util in
       Alcotest.(check int)
         "next sequence is durable"
         4
         (read_pending_snapshot ~base_path |> member "next_sequence" |> to_int))
;;

let hitl_concurrency_key = "keeper.hitl.max_concurrent_per_keeper"

let with_hitl_concurrency n f =
  let restore () = ignore (Masc.Runtime_params.clear_by_key hitl_concurrency_key) in
  (match Masc.Runtime_params.set_by_key hitl_concurrency_key (`Int n) with
   | Ok () -> ()
   | Error detail -> Alcotest.failf "could not set HITL concurrency: %s" detail);
  Fun.protect ~finally:restore f
;;

let test_same_owner_drain_uses_sequence_not_wall_clock () =
  let base_path = temp_dir () in
  let other_base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path;
      cleanup_dir other_base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       ignore (install_exn ~base_path:other_base_path);
       let first = submit ~base_path ~keeper_name:"fifo-owner" ~input:(`Int 1) in
       let second = submit ~base_path ~keeper_name:"fifo-owner" ~input:(`Int 2) in
       let other =
         submit ~base_path:other_base_path ~keeper_name:"fifo-owner" ~input:(`Int 3)
       in
       let first = { (pending_entry_exn first) with requested_at = 500.0 } in
       let second = { (pending_entry_exn second) with requested_at = 1.0 } in
       let expected_global =
         if String.compare base_path other_base_path < 0
         then [ first.id; second.id; other ]
         else [ other; first.id; second.id ]
       in
       let actual_global =
         [ base_path; other_base_path ]
         |> List.sort String.compare
         |> List.concat_map (fun base_path ->
              AQ.list_pending_entries_for_workspace ~base_path
              |> require_ok "read workspace-local FIFO")
         |> List.map (fun (entry : Rule_types.pending_approval) -> entry.id)
       in
       Alcotest.(check (list string))
         "workspace projections compose deterministic FIFO"
         expected_global
         actual_global;
       with_hitl_concurrency 2 @@ fun () ->
       let ready =
         Gate.For_testing.ready_auto_judges_for_owner
           ~base_path
           ~keeper_name:"fifo-owner"
           [ second; first ]
       in
       Alcotest.(check (list string))
         "same-owner worker slots preserve durable sequence"
         [ first.id; second.id ]
         (List.map
            (fun (entry : Rule_types.pending_approval) -> entry.id)
            ready))
;;

(* Owner selection used to read only the FIFO head, so a head that never
   becomes startable on its own froze every later approval for that Keeper.
   Two durable shapes reach that state and neither clears without an operator:
   a judgment that concluded in [Require_human], which [resolve_judgment]
   persists no transition for, and a pre-worker failure awaiting an explicit
   retry. Observed live on 2026-07-28 holding 18 approvals across two Keepers,
   the oldest for 2416s. *)
let head_of_line_owner = "head-of-line-owner"

let require_human_summary () : Rule_types.hitl_context_summary =
  { summary_version = Rule_types.current_hitl_context_summary_version
  ; generated_at = 1.0
  ; model_run_id = "model-run-head-of-line"
  ; context_summary = "head approval was handed to a human"
  ; key_questions = []
  ; judgment = Rule_types.Require_human
  ; rationale = "operator decision required"
  }
;;

let completed_exact_binding (entry : Rule_types.pending_approval) =
  Rule_types.exact_attempt_binding_with_status
    (Rule_types.make_exact_attempt_binding
       ~approval_id:entry.id
       ~input_hash:entry.input_hash
       ~sequence:entry.sequence
       ~slot_id:"slot-head-of-line"
       ~call_id:"call-head-of-line"
       ~plan_fingerprint:"plan-head-of-line"
       ~request_body_sha256:"sha256-head-of-line"
       ())
    Rule_types.Exact_completed
;;

let check_owner_selection label ~base_path ~expected entries =
  match
    Gate.For_testing.ready_auto_judges_for_owner
      ~base_path
      ~keeper_name:head_of_line_owner
      entries
  with
  | selected ->
    Alcotest.(check (list string))
      label
      expected
      (List.map
         (fun (entry : Rule_types.pending_approval) -> entry.id)
         selected)
;;

let test_terminal_head_does_not_stall_owner_queue () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let head =
         pending_entry_exn
           (submit ~base_path ~keeper_name:head_of_line_owner ~input:(`Int 1))
       in
       let follower =
         pending_entry_exn
           (submit ~base_path ~keeper_name:head_of_line_owner ~input:(`Int 2))
       in
       Alcotest.(check bool)
         "head carries the earlier durable sequence"
         true
         (head.sequence < follower.sequence);
       with_hitl_concurrency 4 @@ fun () ->
       check_owner_selection
         "startable work fills owner slots in durable order"
         ~base_path
         ~expected:[ head.id; follower.id ]
         [ follower; head ];
       let judged_head =
         { head with
           Rule_types.summary_status = Rule_types.Summary_available (require_human_summary ())
         ; Rule_types.summary_attempt_disposition = Rule_types.Summary_attempt_settled
         ; Rule_types.exact_attempt = Rule_types.Exact_bound (completed_exact_binding head)
         }
       in
       check_owner_selection
         "a Require_human head releases the owner slot to the next approval"
         ~base_path
         ~expected:[ follower.id ]
         [ judged_head; follower ];
       let blocked_head =
         { head with
           Rule_types.summary_status = Rule_types.Summary_pending
         ; Rule_types.summary_attempt_disposition =
             Rule_types.Summary_attempt_pre_worker_unavailable
               { reason_code = Rule_types.Summary_pre_worker_auto_judge_unavailable
               ; operator_detail =
                   "HITL summary: exact outer-turn request context is unavailable"
               }
         }
       in
       check_owner_selection
         "a pre-worker-blocked head releases the owner slot to the next approval"
         ~base_path
         ~expected:[ follower.id ]
         [ blocked_head; follower ])
;;

let test_workspace_drain_isolates_owner_failures () =
  let calls = ref [] in
  let drain_owner ~base_path ~keeper_name =
    calls := (base_path, keeper_name) :: !calls;
    match keeper_name with
    | "owner-a" -> Error "owner-a queue unavailable"
    | "owner-b" ->
      Ok
        ({ started_ids = [ "approval-b" ]
         ; failures = []
         }
          : Gate.For_testing.owner_drain_outcome)
    | "owner-c" ->
      Ok
        ({ started_ids = []
         ; failures = [ "approval-c", "owner-c worker unavailable" ]
         }
          : Gate.For_testing.owner_drain_outcome)
    | unexpected -> Alcotest.failf "unexpected owner %s" unexpected
  in
  let owners =
    [ "/workspace", "owner-a"
    ; "/workspace", "owner-b"
    ; "/workspace", "owner-c"
    ]
  in
  let report =
    Gate.For_testing.drain_auto_judge_owners_with ~drain_owner owners
  in
  Alcotest.(check (list (pair string string)))
    "every owner is attempted after an earlier failure"
    owners
    (List.rev !calls);
  Alcotest.(check (list string))
    "healthy owner still starts"
    [ "approval-b" ]
    report.started_ids;
  (match report.failures with
   | [ workspace_failure; worker_failure ] ->
     Alcotest.(check string)
       "workspace failure owner"
       "owner-a"
       workspace_failure.keeper_name;
     Alcotest.(check (option string))
       "workspace failure has no approval identity"
       None
       workspace_failure.approval_id;
     Alcotest.(check string)
       "worker failure owner"
       "owner-c"
       worker_failure.keeper_name;
     Alcotest.(check (option string))
       "worker failure keeps approval identity"
       (Some "approval-c")
       worker_failure.approval_id
   | failures ->
     Alcotest.failf "expected two owner-local failures, got %d" (List.length failures))
;;

let test_each_owner_claims_bounded_parallel_workers () =
  (* Real concurrent proof: fibers race the per-owner claim, exercising both
     same-owner fan-out and the independent owner boundary under Atomic CAS. *)
  let base_path = temp_dir () in
  let suffix = string_of_int (int_of_float (Unix.gettimeofday () *. 1_000_000.0)) in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let owner_a = "owner-a-" ^ suffix in
       let owner_b = "owner-b-" ^ suffix in
       let entry_a1 =
         pending_entry_exn (submit ~base_path ~keeper_name:owner_a ~input:(`Int 1))
       in
       let entry_a2 =
         pending_entry_exn (submit ~base_path ~keeper_name:owner_a ~input:(`Int 2))
       in
       let entry_b1 =
         pending_entry_exn (submit ~base_path ~keeper_name:owner_b ~input:(`Int 1))
       in
       let entry_a3 =
         pending_entry_exn (submit ~base_path ~keeper_name:owner_a ~input:(`Int 3))
       in
       let winners_a = Atomic.make 0 in
       let winners_b = Atomic.make 0 in
       let claim entry winners =
         if Gate.For_testing.claim_auto_judge entry
         then ignore (Atomic.fetch_and_add winners 1)
       in
       with_hitl_concurrency 2 @@ fun () ->
       Eio_main.run (fun _env ->
         Eio.Switch.run (fun sw ->
           Eio.Fiber.fork ~sw (fun () -> claim entry_a1 winners_a);
           Eio.Fiber.fork ~sw (fun () -> claim entry_a2 winners_a);
           Eio.Fiber.fork ~sw (fun () -> claim entry_a3 winners_a);
           Eio.Fiber.fork ~sw (fun () -> claim entry_b1 winners_b)));
       Alcotest.(check int) "owner A fills two slots" 2 (Atomic.get winners_a);
       Alcotest.(check int) "owner B claims independently" 1 (Atomic.get winners_b);
       let active_a =
         Gate.For_testing.active_auto_judges_for_owner
           ~base_path
           ~keeper_name:owner_a
       in
       Alcotest.(check int) "owner A active count is bounded" 2 (List.length active_a);
       let entries_a = [ entry_a1; entry_a2; entry_a3 ] in
       let active_entry =
         List.find
           (fun (entry : Rule_types.pending_approval) -> List.mem entry.id active_a)
           entries_a
       in
       let waiting_entry =
         List.find
           (fun (entry : Rule_types.pending_approval) ->
              not (List.mem entry.id active_a))
           entries_a
       in
       Gate.For_testing.release_auto_judge active_entry;
       Alcotest.(check bool) "waiting same-owner work claims the released slot" true
         (Gate.For_testing.claim_auto_judge waiting_entry);
       List.iter Gate.For_testing.release_auto_judge entries_a;
       Gate.For_testing.release_auto_judge entry_b1)
;;

(* The Gate projection is cached under a key built from
   [store_revision_for_workspace], so any write that changes what the queue
   publishes has to move that number. It did not: only the availability
   transitions moved it, and the dashboard kept serving a resolved approval as
   still pending for the cache's whole life. Operators answered the same row
   again on the next poll -- one live approval carries three [resolved] audit
   rows from a single actor. Both halves are asserted, because an enqueue that
   never reaches a reader and a resolution that never leaves one are the same
   defect from opposite ends. *)
let test_queue_writes_advance_the_projection_revision () =
  let base_path = temp_dir () in
  let keeper_name = "queue-revision-cache" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let installed = AQ.store_revision_for_workspace ~base_path in
       let approval_id =
         submit_with_context
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "target", `String "revision" ])
           ()
       in
       let after_enqueue = AQ.store_revision_for_workspace ~base_path in
       Alcotest.(check bool)
         "an enqueued ask advances the projection revision"
         true
         (after_enqueue > installed);
       (match aq_resolve ~base_path ~id:approval_id
                ~decision:Rule_types.Decision.Approve with
        | Ok () -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       Alcotest.(check bool)
         "a resolved ask advances the projection revision"
         true
         (AQ.store_revision_for_workspace ~base_path > after_enqueue))
;;

let test_delivery_wire_shape_drops_request_context () =
  let base_path = temp_dir () in
  let keeper_name = "queue-delivery-context" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       (* Stands in for the production capture, which is the whole outer turn
          (history_messages + system prompts). Padded so a regression that
          re-inlines it into the delivery shows up in the byte assertion below,
          not only in the shape assertions. *)
       let bulky_history =
         List.init 64 (fun i ->
           `String (Printf.sprintf "outer turn message %d %s" i (String.make 256 'x')))
       in
       let request_context =
         `Assoc
           [ ( "initial"
             , `Assoc
                 [ "history_messages", `List bulky_history
                 ; "base_system_prompt", `String (String.make 512 'b')
                 ] )
           ; "completed_tool_calls", `List []
           ]
       in
       let context_bytes = String.length (Yojson.Safe.to_string request_context) in
       let id =
         submit_with_context
           ~turn_id:7
           ~request_context
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "target", `String "document" ])
           ()
       in
       (match aq_resolve ~base_path ~id ~decision:Rule_types.Decision.Approve with
        | Ok () -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       let open Yojson.Safe.Util in
       let delivery_entry =
         read_pending_snapshot ~base_path
         |> member "deliveries"
         |> to_list
         |> List.map (fun delivery -> delivery |> member "entry")
         |> List.find_opt (fun entry ->
           String.equal (entry |> member "id" |> to_string) id)
       in
       (match delivery_entry with
        | None -> Alcotest.fail "approved request did not persist a delivery"
        | Some delivery_entry ->
          Alcotest.check yojson
            "delivery drops the summary-only request context"
            `Null
            (delivery_entry |> member "request_context");
          Alcotest.check yojson
            "delivery drops the context version marker"
            `Null
            (delivery_entry |> member "request_context_version"));
       let snapshot_bytes = String.length (read_pending_snapshot_bytes ~base_path) in
       Alcotest.(check bool)
         (Printf.sprintf
            "resolved snapshot (%d bytes) stays under the dropped context (%d bytes)"
            snapshot_bytes
            context_bytes)
         true
         (snapshot_bytes < context_bytes);
       (* The trimmed delivery shape must still load: the reader keys the
          version field off request_context presence, so absent is legal. *)
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path))
;;

let test_resolution_is_durable_and_origin_scoped () =
  let base_path = temp_dir () in
  let keeper_name = "queue-origin" in
  let unrelated_keeper = "queue-unrelated" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let input = `Assoc [ "target", `String "document"; "body", `String "hello" ] in
       let id = submit ~base_path ~keeper_name ~input in
       let result =
         AQ.resolve_with_policy
           ~base_path
           ~id
           ~decision:Rule_types.Decision.Approve
           ~remember_rule:true
           ~created_by:"operator"
           ()
       in
       let resolution_result =
         match result with
         | Ok result -> result
         | Error error -> Alcotest.fail (AQ.resolve_error_to_string error)
       in
       Alcotest.(check bool) "exact rule persisted" true
         (Option.is_some resolution_result.remembered_rule);
       Alcotest.(check bool) "pending removed" false
         (Option.is_some (AQ.For_testing.get_pending_entry_unchecked ~id));
       (* Two rows: the request is recorded when the call is parked, the
          resolution when it is answered. *)
       (match Chat_store.load_all ~base_dir:base_path ~keeper_name with
        | [ { role = Chat_store.Role.System
            ; approval_lifecycle = Some requested
            ; _
            }
          ; { role = Chat_store.Role.System
            ; approval_lifecycle = Some lifecycle
            ; _
            } ] ->
          Alcotest.(check bool) "the parked call was recorded first" true
            (requested.phase = Chat_store.Approval_requested);
          Alcotest.(check string) "approved status carries approval id" id
            lifecycle.approval_id;
          Alcotest.(check bool) "approval is not yet effect-applied" true
            (lifecycle.phase = Chat_store.Approval_resolved_approved)
        | rows ->
          Alcotest.failf
            "expected a request row and an approval status row, got %d"
            (List.length rows));
       let resolution =
         match durable_resolution_opt ~base_path ~keeper_name ~approval_id:id with
         | None -> Alcotest.fail "origin Keeper did not receive durable resolution"
         | Some resolution -> resolution
       in
       (match resolution.decision with
        | Keeper_event_queue.Hitl_approved -> ()
        | Keeper_event_queue.Hitl_rejected _ ->
          Alcotest.fail "expected approved resolution");
       (match AQ.approved_resolution_request ~base_path ~id with
        | Ok (Some request) ->
          Alcotest.(check string) "journal keeper" keeper_name request.keeper_name;
          Alcotest.(check string) "journal operation" "external-effect" request.tool_name;
          Alcotest.(check bool) "journal complete input" true
            (Yojson.Safe.equal input request.input)
        | Ok None -> Alcotest.fail "approved journal was consumed before Gate use"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       Alcotest.(check bool) "unrelated Keeper receives no resolution" true
         (Option.is_none
            (durable_resolution_opt
               ~base_path
               ~keeper_name:unrelated_keeper
               ~approval_id:id));
       Alcotest.(check bool) "exact remembered request matches" true
         (match
            Rules.find_matching_rule
              ~base_path
              ~keeper_name
              ~tool_name:"external-effect"
              ~input
              ()
          with
          | Ok (Rule_types.Rule_match_active _) -> true
          | Ok (Rule_types.Rule_match_expired _ | Rule_types.Rule_match_absent) -> false
          | Error error -> Alcotest.fail (Rule_types.rule_store_error_to_string error));
       (match
          AQ.consume_approved_resolution
            ~base_path
            ~id
            ~keeper_name
            ~tool_name:"external-effect"
            ~input:(`Assoc [ "target", `String "other" ])
        with
        | Ok AQ.Consumption_not_matching -> ()
        | Ok (AQ.Consumption_committed _ | AQ.Consumption_already_committed) ->
          Alcotest.fail "changed input consumed the exact grant"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       (match
          AQ.consume_approved_resolution
            ~base_path
            ~id
            ~keeper_name
            ~tool_name:"external-effect"
            ~input
        with
        | Ok (AQ.Consumption_committed _) -> ()
        | Ok (AQ.Consumption_already_committed | AQ.Consumption_not_matching) ->
          Alcotest.fail "exact request did not consume its grant"
       | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       let replay_output = {|{"result":"durable replay"}|} in
       let replay_output_ref =
         store_replay_artifact ~base_path replay_output
       in
       (match
          AQ.record_consumed_resolution_replay
            ~base_path
            ~id
            ~outcome:(AQ.Replay_applied replay_output_ref)
        with
        | Ok AQ.Replay_recorded -> ()
        | Ok AQ.Replay_already_recorded ->
          Alcotest.fail "first replay outcome write was already present"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       (match
          AQ.record_consumed_resolution_replay
            ~base_path
            ~id
            ~outcome:(AQ.Replay_applied replay_output_ref)
        with
        | Ok AQ.Replay_already_recorded -> ()
        | Ok AQ.Replay_recorded ->
          Alcotest.fail "identical replay outcome was rewritten as new"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       let different_ref =
         store_replay_artifact ~base_path "different outcome"
       in
       (match
          AQ.record_consumed_resolution_replay
            ~base_path
            ~id
            ~outcome:(AQ.Replay_failed different_ref)
        with
        | Error (AQ.Grant_replay_outcome_conflict actual_id) ->
          Alcotest.(check string) "conflict identifies approval" id actual_id
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error)
        | Ok _ -> Alcotest.fail "conflicting replay outcome replaced durable truth");
       let open Yojson.Safe.Util in
       let delivery_wire =
         read_pending_snapshot ~base_path
         |> member "deliveries"
         |> to_list
         |> List.find (fun delivery ->
           String.equal
             (delivery |> member "entry" |> member "id" |> to_string)
             id)
       in
       (match delivery_wire with
        | `Assoc fields ->
          Alcotest.(check bool)
            "authorization delivery has no derived replay field"
            true
            (Option.is_none (List.assoc_opt "replay_outcome" fields))
        | _ -> Alcotest.fail "delivery wire is not an object");
       let replay_results_path =
         AQ.For_testing.replay_results_store_path ~base_path
       in
       Alcotest.(check bool)
         "replay outcome is isolated in its derived projection"
         true
         (Sys.file_exists replay_results_path);
       let replay_results = Yojson.Safe.from_file replay_results_path in
       Alcotest.(check int)
         "replay sidecar v1"
         1
         (replay_results |> member "version" |> to_int);
       let replay_outcome_wire =
         replay_results
         |> member "outcomes"
         |> to_list
         |> List.hd
         |> member "outcome"
       in
       Alcotest.(check bool)
         "current sidecar uses a typed output reference"
         true
         (replay_outcome_wire |> member "output_ref" <> `Null);
       Alcotest.(check bool)
         "current sidecar carries no raw legacy output field"
         true
         (replay_outcome_wire |> member "output" = `Null);
       let fresh_replay_message =
         Masc.Keeper_gate_replay.compose_model_message
           ~base_path
           ~user_message:"continue"
           ~hitl_resolution:(Some resolution)
           ~replay_delivery:
             (Some
                ( id
                , Masc.Keeper_gate_replay.Applied
                    { operation = "external-effect"
                    ; output_ref = replay_output_ref
                    ; journal =
                        Masc.Keeper_gate_replay.Replay_journal_recorded
                    } ))
       in
       let fresh_replay_text =
         fresh_replay_message.Masc.Keeper_gate_replay.text
       in
       Alcotest.(check bool)
         "fresh replay replaces pre-replay one-shot authorization"
         false
         (String_util.contains_substring
            fresh_replay_text
            "The one-shot authorization belongs");
       Alcotest.(check bool)
         "fresh replay reference is model-visible"
         true
         (String_util.contains_substring
            fresh_replay_text
            "Host Gate replay completed");
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       (match AQ.approved_resolution_delivery ~base_path ~id with
        | Ok
            { state = AQ.Resolution_consumed
            ; replay_outcome = Some (AQ.Replay_applied output_ref)
            ; _
            } ->
          Alcotest.(check string)
            "replay output identity survives restart"
            replay_output_ref.sha256
            output_ref.sha256
        | Ok _ -> Alcotest.fail "restart lost the consumed replay outcome"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       let retry_message =
         Masc.Keeper_gate_replay.user_message_with_hitl_resolution
           ~base_path
           ~user_message:"continue"
           (Some resolution)
       in
       let retry_text = retry_message.Masc.Keeper_gate_replay.text in
       Alcotest.(check bool)
         "retry reads durable replay evidence without stale authorization"
         false
         (String_util.contains_substring
            retry_text
            "The one-shot authorization belongs");
       Alcotest.(check bool)
         "retry forbids replaying consumed operation"
         true
         (String_util.contains_substring
            retry_text
            "Do not request the approved operation again");
       let projected_text =
         match retry_message.replay_evidence with
         | None -> Alcotest.fail "retry lost its replay evidence projection"
         | Some evidence ->
           (match
              Masc.Keeper_gate_replay.project_model_input
                ~base_path
                evidence
                [ Agent_core.Types.user_msg retry_text ]
            with
            | Ok [ _canonical; projected ] ->
              Agent_core.Types.text_of_content projected.content
            | Ok _ ->
              Alcotest.fail "replay projection did not append exact evidence"
            | Error detail -> Alcotest.fail (Agent_core.Error.to_string detail))
       in
       let replay_evidence =
         projected_text
         |> String.split_on_char '\n'
         |> List.rev
         |> List.find (fun line -> not (String.equal (String.trim line) ""))
         |> Yojson.Safe.from_string
       in
       Alcotest.(check string)
         "provider-only projection preserves the exact replay artifact identity"
         replay_output_ref.sha256
         (match
            replay_evidence
            |> Yojson.Safe.Util.member "untrusted_tool_output_ref"
            |> Tool_output.normalized_artifact_ref_of_json
          with
          | Tool_output.Decoded_normalized_artifact_ref decoded -> decoded.sha256
          | Tool_output.Not_normalized_artifact_ref ->
            Alcotest.fail "provider replay evidence lost its artifact reference"
          | Tool_output.Invalid_normalized_artifact_ref { detail } ->
            Alcotest.fail detail);
       drop_resolution ~base_path ~keeper_name resolution)
;;

let test_remembered_rule_carries_requested_expiry () =
  let base_path = temp_dir () in
  let keeper_name = "queue-expiry-origin" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let input = `Assoc [ "target", `String "document" ] in
       let id = submit ~base_path ~keeper_name ~input in
       let expires_at = Unix.gettimeofday () +. 600.0 in
       let result =
         AQ.resolve_with_policy
           ~base_path
           ~id
           ~decision:Rule_types.Decision.Approve
           ~remember_rule:true
           ~rule_expires_at:expires_at
           ~created_by:"operator"
           ()
       in
       (match result with
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error)
        | Ok { remembered_rule = None } ->
          Alcotest.fail "approved remember_rule resolution must persist a rule"
        | Ok { remembered_rule = Some rule } ->
          Alcotest.(check (option (float 0.0)))
            "rule carries requested expiry"
            (Some expires_at)
            rule.expires_at);
       (* A same-request replay stays idempotent only when the expiry matches. *)
       (match
          AQ.resolve_with_policy
            ~base_path
            ~id
            ~decision:Rule_types.Decision.Approve
            ~remember_rule:true
            ~rule_expires_at:expires_at
            ~created_by:"operator"
            ()
        with
        | Ok _ -> ()
        | Error error ->
          Alcotest.fail
            ("identical expiry re-resolution must be idempotent: "
             ^ AQ.resolve_error_to_string error));
       match Rules.list_rules ~base_path () with
       | Error error -> Alcotest.fail (Rule_types.rule_store_error_to_string error)
       | Ok [ rule ] ->
         Alcotest.(check (option (float 0.0)))
           "persisted rule carries requested expiry"
           (Some expires_at)
           rule.expires_at
       | Ok rules ->
         Alcotest.failf "one remembered rule expected, got %d" (List.length rules))
;;

let test_cycle_grant_uses_exact_effect_and_is_consumed_once () =
  let base_path = temp_dir () in
  let keeper_name = "queue-one-shot-origin" in
  let input =
    `Assoc
      [ "target", `String "same-shape"
      ; "payload", `Assoc [ "value", `Int 1 ]
      ]
  in
  let continuation_channel =
    Keeper_continuation_channel.dashboard ~thread_id:"origin-thread"
    |> Result.get_ok
  in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let approval_id =
         submit_with_context
           ~turn_id:17
           ~task_id:"task-origin"
           ~continuation_channel
           ~base_path
           ~keeper_name
           ~input
           ()
       in
       (match aq_resolve ~base_path ~id:approval_id ~decision:Rule_types.Decision.Approve with
        | Ok () -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       let resolution =
         match
           durable_resolution_opt ~base_path ~keeper_name ~approval_id
         with
         | Some resolution -> resolution
         | None -> Alcotest.fail "approved resolution was not delivered"
       in
       AQ.For_testing.reset_runtime_state ();
       let report = install_exn ~base_path in
       Alcotest.(check int) "unconsumed grant restored" 1 report.replayed_deliveries;
       (match AQ.approved_resolution_state ~base_path ~id:approval_id with
        | Ok AQ.Resolution_unconsumed -> ()
        | Ok AQ.Resolution_consumed -> Alcotest.fail "restart lost the unconsumed grant"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       let grant =
         match Gate.cycle_grant_of_resolution resolution with
         | Some grant -> grant
         | None -> Alcotest.fail "approved resolution did not create a cycle grant"
       in
       (* The two lease-settlement assertions that used to sit here and below
          checked that a wake producing no cycle outcome requeued the lease
          instead of acknowledging it, so the grant's stimulus was not dropped.
          #25969 replaced claim/settle with peek/ack: nothing computes a
          settlement any more, and "no turn ran" is expressed by not calling
          [ack_pending] at all. That PR deleted the same class of assertion
          from test_keeper_event_queue_state_v2.ml but left these two, which is
          why this executable stopped compiling. The property now belongs to
          the peek/ack intake path rather than to this file; see #25980. *)
       let request ~input ~task_id ~goal_ids : Gate.request =
         { keeper_name
         ; operation = "external-effect"
         ; input
         ; base_path
         ; sandbox_profile = None
         ; causal_context =
             Some { Gate.turn_id = Some 99; snapshot = `Assoc [] }
         ; task_id
         ; continuation_channel = None
         }
       in
       let source_of = function
         | Gate.Allow { source; _ } -> source
         | Gate.Deferred _ -> Alcotest.fail "keeper Always Allow unexpectedly deferred"
         | Gate.Unavailable reason ->
           Alcotest.fail (Gate.unavailable_reason_to_string reason)
       in
       (match
          Gate.decide
            ~cycle_grant:grant
            ~keeper_always_allow:true
            (request
               ~input:(`Assoc [ "target", `String "different" ])
               ~task_id:(Some "task-other")
               ~goal_ids:[ "goal-other" ])
          |> source_of
        with
        | Gate.Keeper_always_allow -> ()
        | Gate.One_shot_resolution _
        | Gate.Exact_always_rule _
        | Gate.Workspace_always_allow
        | Gate.Readonly_sandbox ->
          Alcotest.fail "different exact input consumed the grant");
       (match
          Gate.decide
            ~cycle_grant:grant
            ~keeper_always_allow:true
            (request
               ~input
               ~task_id:(Some "task-other")
               ~goal_ids:[ "goal-other" ])
          |> source_of
        with
        | Gate.One_shot_resolution actual_id ->
          Alcotest.(check string) "exact approval id" approval_id actual_id
        | Gate.Exact_always_rule _
        | Gate.Keeper_always_allow
        | Gate.Workspace_always_allow
        | Gate.Readonly_sandbox ->
          Alcotest.fail "exact effect did not consume its one-shot grant");
       (match
          Gate.decide
            ~cycle_grant:grant
            ~keeper_always_allow:true
            (request ~input ~task_id:None ~goal_ids:[])
          |> source_of
        with
        | Gate.Keeper_always_allow -> ()
        | Gate.One_shot_resolution _
        | Gate.Exact_always_rule _
        | Gate.Workspace_always_allow
        | Gate.Readonly_sandbox ->
          Alcotest.fail "one-shot grant was consumed more than once");
       AQ.For_testing.reset_runtime_state ();
       let _ = install_exn ~base_path in
       (match AQ.approved_resolution_state ~base_path ~id:approval_id with
        | Ok AQ.Resolution_consumed -> ()
        | Ok AQ.Resolution_unconsumed ->
          Alcotest.fail "consumed grant reappeared after restart"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       drop_resolution ~base_path ~keeper_name resolution)
;;

let test_pre_effect_replay_failure_retires_grant_and_unblocks_continuation () =
  let base_path = temp_dir () in
  let keeper_name = "queue-pre-effect-replay-failure" in
  let input = `Assoc [ "target", `String "unavailable-sandbox" ] in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let approval_id = submit ~base_path ~keeper_name ~input in
       (match
          aq_resolve
            ~base_path
            ~id:approval_id
            ~decision:Rule_types.Decision.Approve
        with
        | Ok () -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       let resolution =
         durable_resolution_opt ~base_path ~keeper_name ~approval_id
         |> require_some "approved resolution was not delivered"
       in
       (match
          Masc.Keeper_gate_replay.For_testing.settle_pre_effect_failure
            ~base_path
            ~approval_id
            ~operation:"external-effect"
            ~detail:"sandbox unavailable before effect"
        with
        | Ok
            { Masc.Keeper_gate_replay.outcome =
                Failed { journal = Replay_journal_recorded; _ }
            ; terminal_effect_receipt = None
            } -> ()
        | Ok execution ->
          Alcotest.failf
            "pre-effect failure did not settle durably: %s"
            (Masc.Keeper_gate_replay.outcome_to_string execution.outcome)
        | Error detail -> Alcotest.fail detail);
       (match AQ.approved_resolution_delivery ~base_path ~id:approval_id with
        | Ok
            { state = AQ.Resolution_consumed
            ; replay_outcome = Some (AQ.Replay_failed _)
            ; _
            } -> ()
        | Ok _ -> Alcotest.fail "pre-effect failure left an actionable grant"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       Alcotest.(check bool)
         "failed replay is visible in chat"
         true
         (Chat_store.approval_lifecycle_phase_present
            ~base_dir:base_path
            ~keeper_name
            ~approval_id
            ~phase:Chat_store.Approval_replay_failed);
       (match
          AQ.ensure_settled_continuation_chat_projection
            ~base_path
            ~keeper_name
            ~resolution
        with
        | Ok AQ.Continuation_projection_recorded -> ()
        | Ok AQ.Continuation_projection_not_ready ->
          Alcotest.fail "terminal failure did not unblock continuation"
        | Error detail -> Alcotest.fail detail);
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       (match AQ.approved_resolution_delivery ~base_path ~id:approval_id with
        | Ok
            { state = AQ.Resolution_consumed
            ; replay_outcome = Some (AQ.Replay_failed _)
            ; _
            } -> ()
        | Ok _ -> Alcotest.fail "restart revived the failed replay grant"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       Alcotest.(check bool)
         "continuation receipt survives restart"
         true
         (AQ.continuation_chat_projection_present
            ~base_path
            ~keeper_name
            ~approval_id))
;;

let test_exact_binding_codec_validates_entry_identity () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name:"queue-exact-codec"
           ~input:(`Assoc [ "request", `String "codec" ])
       in
       check_update "mark exact codec pending" true (AQ.mark_summary_pending ~id);
       let identity = exact_identity id in
       let invalid_hashes =
         [ "malformed", String.make 63 'a' ^ "g"
         ; "uppercase", String.make 64 'A'
         ; "non-64", String.make 63 'a'
         ]
       in
       List.iter
         (fun (label, request_body_sha256_arg) ->
            let invalid = { identity with request_body_sha256_arg } in
            match run_exact_transition AQ.bind_summary_exact_attempt invalid with
            | Error
                (AQ.Exact_attempt_rejected
                  (AQ.Exact_attempt_invalid_identity "request_body_sha256")) ->
              ()
            | Error error ->
              Alcotest.failf
                "%s runtime hash returned the wrong error: %s"
                label
                (AQ.exact_attempt_error_to_string error)
            | Ok _ ->
              Alcotest.failf "%s runtime hash was accepted" label)
         invalid_hashes;
       check_exact_update
         "bind valid exact identity"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt identity);
       let snapshot = read_pending_snapshot ~base_path in
       let open Yojson.Safe.Util in
       Alcotest.(check int) "v9 snapshot" 9 (snapshot |> member "version" |> to_int);
       let exact_json =
         snapshot
         |> member "pending"
         |> to_list
         |> List.hd
         |> member "exact_attempt"
       in
       (match Rule_types.exact_attempt_state_of_yojson_with_error exact_json with
        | Ok (Rule_types.Exact_bound binding) ->
          Alcotest.(check string)
            "codec approval identity"
            identity.approval_id_arg
            binding.approval_id;
          Alcotest.(check string)
            "codec input identity"
            identity.input_hash_arg
            binding.input_hash;
          Alcotest.(check int)
            "codec sequence identity"
            identity.sequence_arg
            binding.sequence
        | Ok _ -> Alcotest.fail "bound exact attempt decoded as another state"
        | Error reason -> Alcotest.fail reason);
       let replace_field field value = function
         | `Assoc fields ->
           `Assoc ((field, value) :: List.remove_assoc field fields)
         | _ -> Alcotest.fail "exact attempt object expected"
       in
       check_exact_update
         "quarantine exact codec fixture"
         true
         (quarantine_exact identity Rule_types.Exact_flow_execution_failed);
       let quarantined_exact_json =
         read_pending_snapshot ~base_path
         |> member "pending"
         |> to_list
         |> List.hd
         |> member "exact_attempt"
       in
       Alcotest.(check string)
         "flow execution failure is encoded"
         "flow_execution_failed"
         (quarantined_exact_json
          |> member "quarantine_cause"
          |> to_string);
       (match
          Rule_types.exact_attempt_state_of_yojson_with_error quarantined_exact_json
        with
        | Ok
            (Rule_types.Exact_bound
              { status =
                  Rule_types.Exact_quarantined
                    Rule_types.Exact_flow_execution_failed
              ; _
              }) ->
          ()
        | Ok _ ->
          Alcotest.fail
            "flow execution failure decoded as another exact state"
        | Error reason -> Alcotest.fail reason);
       List.iter
         (fun removed_cause ->
            match
              Rule_types.exact_attempt_state_of_yojson_with_error
                (replace_field
                   "quarantine_cause"
                   (`String removed_cause)
                   quarantined_exact_json)
            with
            | Error _ -> ()
            | Ok _ ->
              Alcotest.failf
                "removed quarantine cause %s was decoded"
                removed_cause)
         [ "post_dispatch_failure"
         ; "provenance_mismatch"
         ; "restart_uncertainty"
         ];
       (match
          Rule_types.exact_attempt_state_of_yojson_with_error
            (replace_field "call_id" (`String " ") exact_json)
        with
        | Error _ -> ()
        | Ok _ -> Alcotest.fail "blank exact call identity decoded");
       List.iter
         (fun (label, hash) ->
            match
              Rule_types.exact_attempt_state_of_yojson_with_error
                (replace_field
                   "request_body_sha256"
                   (`String hash)
                   exact_json)
            with
            | Error _ -> ()
            | Ok _ -> Alcotest.failf "%s codec hash was accepted" label)
         invalid_hashes;
       let mutate_snapshot field value =
         match snapshot with
         | `Assoc snapshot_fields ->
           let pending =
             match List.assoc_opt "pending" snapshot_fields with
             | Some (`List entries) ->
               `List
                 (List.map
                    (function
                      | `Assoc entry_fields ->
                        let exact_attempt =
                          List.assoc "exact_attempt" entry_fields
                          |> replace_field field value
                        in
                        `Assoc
                          (("exact_attempt", exact_attempt)
                           :: List.remove_assoc "exact_attempt" entry_fields)
                      | _ -> Alcotest.fail "pending entry object expected")
                    entries)
             | _ -> Alcotest.fail "pending list expected"
           in
           `Assoc
             (("pending", pending)
              :: List.remove_assoc "pending" snapshot_fields)
         | _ -> Alcotest.fail "snapshot object expected"
       in
       List.iter
         (fun (field, value) ->
            AQ.For_testing.reset_runtime_state ();
            write_pending_snapshot ~base_path (mutate_snapshot field value);
            match AQ.install_persistence ~base_path with
            | Error _ -> ()
            | Ok _ ->
              Alcotest.failf
                "current binding with mismatched %s installed"
                field)
         [ "approval_id", `String "different-approval"
         ; "input_hash", `String "different-input-hash"
         ; "sequence", `Int (identity.sequence_arg + 1)
         ])
;;

let test_exact_attempt_binding_release_and_conflicts () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name:"queue-exact-binding"
           ~input:(`Assoc [ "request", `String "bind" ])
       in
       check_update "mark exact binding pending" true (AQ.mark_summary_pending ~id);
       let first = exact_identity id in
       check_exact_update
         "first exact bind"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt first);
       check_exact_update
         "same exact bind is idempotent"
         false
         (run_exact_transition AQ.bind_summary_exact_attempt first);
       let conflicting = { first with call_id_arg = "call-conflicting" } in
       (match run_exact_transition AQ.bind_summary_exact_attempt conflicting with
        | Error
            (AQ.Exact_attempt_rejected
              (AQ.Exact_attempt_identity_conflict _)) ->
          ()
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "conflicting active exact identity was accepted");
       check_exact_update
         "release before dispatch"
         true
         (run_exact_transition
            AQ.release_summary_exact_attempt_before_dispatch
            first);
       check_exact_update
         "same release is idempotent"
         false
         (run_exact_transition
            AQ.release_summary_exact_attempt_before_dispatch
            first);
       (match run_exact_transition AQ.bind_summary_exact_attempt first with
        | Error
            (AQ.Exact_attempt_rejected
              (AQ.Exact_attempt_status_conflict _)) ->
          ()
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "released identity rebound as a new attempt");
       let replacement =
         { first with
           slot_id_arg = "slot-replacement"
         ; call_id_arg = "call-replacement"
         ; plan_fingerprint_arg = "plan-replacement"
         ; request_body_sha256_arg = String.make 64 'b'
         }
       in
       check_exact_update
         "new identity replaces released attempt"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt replacement);
       check_rearm
         "bound restart is not rearmed"
         false
         (reserve_retry_exact ~base_path (pending_entry_exn id));
       let quarantine_cause = Rule_types.Exact_domain_invalid_output in
       check_exact_update
         "quarantine replacement"
         true
         (quarantine_exact replacement quarantine_cause);
       (match pending_entry_exn id with
        | { summary_status = Rule_types.Summary_failed { reason }
          ; exact_attempt =
              Rule_types.Exact_bound
                { status =
                    Rule_types.Exact_quarantined
                      Rule_types.Exact_domain_invalid_output
                ; _
                }
          ; _
          } ->
          Alcotest.(check string)
            "quarantine summary reason"
            "Auto Judge exact attempt quarantined: domain_invalid_output"
            reason
        | _ -> Alcotest.fail "quarantine cause was not durably typed");
       check_exact_update
         "same quarantine cause is idempotent"
         false
         (quarantine_exact replacement quarantine_cause);
       (match quarantine_exact replacement Rule_types.Exact_cancellation with
        | Error
            (AQ.Exact_attempt_rejected
              (AQ.Exact_attempt_status_conflict _)) ->
          ()
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "different quarantine cause was accepted");
       (match
          run_exact_transition
            AQ.release_summary_exact_attempt_before_dispatch
            replacement
        with
        | Error
            (AQ.Exact_attempt_rejected
              (AQ.Exact_attempt_status_conflict _)) ->
          ()
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "quarantined exact attempt was released"))
;;


let test_restart_classifies_uncertain_and_released_recovery () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let prepare label =
         let id =
           submit
             ~base_path
             ~keeper_name:("queue-exact-restart-" ^ label)
             ~input:(`Assoc [ "request", `String label ])
         in
         check_update
           ("mark " ^ label ^ " pending")
           true
           (AQ.mark_summary_pending ~id);
         let identity = exact_identity id in
         check_exact_update
           ("bind " ^ label ^ " attempt")
           true
           (run_exact_transition AQ.bind_summary_exact_attempt identity);
         id, identity
       in
       let uncertain_id, uncertain_identity = prepare "uncertain" in
       let released_id, released_identity = prepare "released" in
       check_exact_update
         "release no-dispatch proof"
         true
         (run_exact_transition
            AQ.release_summary_exact_attempt_before_dispatch
            released_identity);
       check_rearm
         "live released pending work does not enter restart-only recovery"
         false
         (reserve_retry_exact ~base_path (pending_entry_exn released_id));
       (match pending_entry_exn released_id with
        | { exact_attempt =
              Rule_types.Exact_bound
                { status = Rule_types.Exact_released_before_dispatch; _ }
          ; summary_status = Rule_types.Summary_pending
          ; _
          } ->
          ()
        | _ ->
          Alcotest.fail
            "live recovery attempt changed released no-dispatch proof");
       let assert_restart_states label =
         (match pending_entry_exn uncertain_id with
          | { exact_attempt =
                Rule_types.Exact_bound
                  { status = Rule_types.Exact_restart_quarantined
                  ; slot_id
                  ; call_id
                  ; _
                  }
            ; _
            } ->
            Alcotest.(check string)
              (label ^ " uncertain slot")
              uncertain_identity.slot_id_arg
              slot_id;
            Alcotest.(check string)
              (label ^ " uncertain call")
              uncertain_identity.call_id_arg
              call_id
          | _ ->
            Alcotest.fail
              (label ^ " did not quarantine dispatch-uncertain attempt"));
         match pending_entry_exn released_id with
         | { exact_attempt =
               Rule_types.Exact_bound
                 { status = Rule_types.Exact_released_recovery_required
                 ; slot_id
                 ; call_id
                 ; _
                 }
           ; _
           } ->
           Alcotest.(check string)
             (label ^ " released slot")
             released_identity.slot_id_arg
             slot_id;
           Alcotest.(check string)
             (label ^ " released call")
             released_identity.call_id_arg
             call_id
         | _ ->
           Alcotest.fail
             (label ^ " did not latch released operator recovery")
       in
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       assert_restart_states "first install";
       let first_snapshot = read_pending_snapshot_bytes ~base_path in
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       assert_restart_states "second install";
       let second_snapshot = read_pending_snapshot_bytes ~base_path in
       Alcotest.(check string)
         "second install does not rewrite stable exact states"
         first_snapshot
         second_snapshot;
       check_rearm
         "explicit operator recovery clears restart-only released binding"
         true
         (reserve_retry_exact ~base_path (pending_entry_exn released_id));
       (match pending_entry_exn released_id with
        | { summary_status = Rule_types.Summary_pending
          ; exact_attempt = Rule_types.Exact_unbound
          ; _
          } ->
          ()
        | _ ->
          Alcotest.fail
            "operator recovery did not restore one fresh unbound flow");
       let bulk_id, bulk_identity = prepare "released-bulk" in
       check_exact_update
         "release bulk recovery fixture"
         true
         (run_exact_transition
            AQ.release_summary_exact_attempt_before_dispatch
            bulk_identity);
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       check_rearm
         "operator recovery rearms the selected restart-classified release"
         true
         (reserve_retry_exact ~base_path (pending_entry_exn bulk_id));
       match pending_entry_exn bulk_id with
       | { summary_status = Rule_types.Summary_pending
         ; exact_attempt = Rule_types.Exact_unbound
         ; _
         } ->
         ()
       | _ ->
         Alcotest.fail
           "bulk operator recovery did not restore fresh unbound work")
;;

let test_exact_attempt_completion_is_atomic () =

  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name:"queue-exact-completion"
           ~input:(`Assoc [ "request", `String "complete" ])
       in
       check_update "mark exact completion pending" true (AQ.mark_summary_pending ~id);
       let identity = exact_identity id in
       check_exact_update
         "bind completion attempt"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt identity);
       let mismatched_summary = exact_summary "different-call-id" in
       (match complete_exact identity mismatched_summary with
        | Error
            (AQ.Exact_attempt_rejected
              (AQ.Exact_attempt_provenance_mismatch
                { approval_id; expected_call_id; actual_model_run_id })) ->
          Alcotest.(check string) "provenance approval" id approval_id;
          Alcotest.(check string)
            "provenance expected call"
            identity.call_id_arg
            expected_call_id;
          Alcotest.(check string)
            "provenance actual model run"
            mismatched_summary.model_run_id
            actual_model_run_id
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "mismatched completion provenance was accepted");
       (match pending_entry_exn id with
        | { summary_status = Rule_types.Summary_pending
          ; exact_attempt =
              Rule_types.Exact_bound { status = Rule_types.Exact_dispatch_uncertain; _ }
          ; _
          } ->
          ()
        | _ -> Alcotest.fail "provenance rejection mutated the exact attempt");
       let summary = exact_summary identity.call_id_arg in
       check_exact_update
         "complete exact attempt"
         true
         (complete_exact identity summary);
       (match pending_entry_exn id with
        | { summary_status = Rule_types.Summary_available durable_summary
          ; exact_attempt =
              Rule_types.Exact_bound { status = Rule_types.Exact_completed; _ }
          ; _
          } ->
          Alcotest.(check string)
            "summary and completion share one entry"
            summary.model_run_id
            durable_summary.model_run_id
        | _ -> Alcotest.fail "exact completion did not atomically store both fields");
       let open Yojson.Safe.Util in
       let persisted_entry =
         read_pending_snapshot ~base_path
         |> member "pending"
         |> to_list
         |> List.hd
       in
       Alcotest.(check string)
         "durable exact status"
         "completed"
         (persisted_entry
          |> member "exact_attempt"
          |> member "status"
          |> to_string);
       Alcotest.(check string)
         "durable summary from the same snapshot"
         summary.model_run_id
         (persisted_entry
          |> member "summary_status"
          |> member "summary"
          |> member "model_run_id"
          |> to_string);
       check_exact_update
         "same completion is idempotent"
         false
         (complete_exact identity summary);
       let conflicting =
         { summary with context_summary = "Conflicting exact summary" }
       in
       (match complete_exact identity conflicting with
        | Error
            (AQ.Exact_attempt_rejected
              (AQ.Exact_attempt_content_conflict actual)) ->
          Alcotest.(check string) "content conflict identity" id actual
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "conflicting exact completion was accepted"))
;;

let test_exact_attempt_bind_storage_failure_is_not_success () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name:"queue-exact-bind-storage-failure"
           ~input:(`Assoc [ "request", `String "bind" ])
       in
       check_update "mark storage failure pending" true (AQ.mark_summary_pending ~id);
       let identity = exact_identity id in
       let store_path = AQ.For_testing.pending_store_path ~base_path in
       Sys.remove store_path;
       Unix.mkdir store_path 0o755;
       (match run_exact_transition AQ.bind_summary_exact_attempt identity with
        | Error (AQ.Exact_attempt_storage_error _) -> ()
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "failed exact binding persistence reported success");
       match pending_entry_exn id with
       | { exact_attempt = Rule_types.Exact_unbound; _ } -> ()
       | _ -> Alcotest.fail "failed exact binding persistence mutated memory")
;;

let test_exact_attempt_staged_durability_and_idempotent_rewrite () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let prepare label =
         let id =
           submit
             ~base_path
             ~keeper_name:("queue-exact-staged-" ^ label)
             ~input:(`Assoc [ "request", `String label ])
         in
         check_update
           ("mark " ^ label ^ " pending")
           true
           (AQ.mark_summary_pending ~id);
         id, exact_identity id
       in
       let assert_status label id expected =
         match pending_entry_exn id with
         | { exact_attempt = Rule_types.Exact_bound { status; _ }; _ } ->
           Alcotest.(check string)
             label
             expected
             (Rule_types.exact_attempt_status_to_string status)
         | _ -> Alcotest.failf "%s did not retain an exact binding" label
       in
       let resolved_id =
         submit
           ~base_path
           ~keeper_name:"queue-exact-staged-resolved"
           ~input:(`Assoc [ "request", `String "resolved" ])
       in
       (match
          AQ.resolve_with_policy
            ~base_path
            ~id:resolved_id
            ~decision:Rule_types.Decision.Approve
            ()
        with
        | Ok _ -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       let bind_id, bind_identity = prepare "bind" in
       check_visible_update
         "visible bind"
         true
         (run_exact_transition_with_writer
            AQ.For_testing.bind_summary_exact_attempt_with_writer
            ~writer:visible_after_rename_writer
            bind_identity);
       assert_status "visible bind memory" bind_id "dispatch_uncertain";
       check_exact_update
         "idempotent bind confirms durability"
         false
         (run_exact_transition AQ.bind_summary_exact_attempt bind_identity);
       let before_id, before_identity = prepare "before-rename" in
       let revision_before_failure =
         AQ.store_revision_for_workspace ~base_path
       in
       (match
          run_exact_transition_with_writer
            AQ.For_testing.bind_summary_exact_attempt_with_writer
            ~writer:before_rename_writer
            before_identity
        with
        | Error (AQ.Exact_attempt_storage_error _) -> ()
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error)
        | Ok _ -> Alcotest.fail "pre-rename binding failure reported success");
         Alcotest.(check bool)
           "runtime write failure advances queue authority"
           true
           (AQ.store_revision_for_workspace ~base_path
            > revision_before_failure);
         (match AQ.list_pending_entries_for_workspace ~base_path with
          | Error _ -> ()
         | Ok _ ->
            Alcotest.fail
              "runtime write failure did not latch workspace unavailable");
         (match
            AQ.submit_pending
              ~base_path
              ~keeper_name:"queue-exact-staged-before-rename"
              ~tool_name:"fs_write"
              ~input:(`Assoc [ "request", `String "before-rename" ])
              ()
          with
          | Error _ -> ()
          | Ok _ ->
            Alcotest.fail
              "unavailable queue reported a duplicate submission as success");
         (match
            AQ.resolve_with_policy
              ~base_path
              ~id:resolved_id
              ~decision:Rule_types.Decision.Approve
              ()
          with
          | Error (AQ.Persistence_failed _) -> ()
          | Error error -> Alcotest.fail (AQ.resolve_error_to_string error)
          | Ok _ ->
            Alcotest.fail
              "unavailable queue delivered a stale resolution as success");
         AQ.For_testing.reset_runtime_state ();
         ignore (install_exn ~base_path);
         (match pending_entry_exn before_id with
          | { exact_attempt = Rule_types.Exact_unbound; _ } -> ()
          | _ -> Alcotest.fail "pre-rename failure mutated exact binding memory");
         let cancel_before_id, cancel_before_identity =
           prepare "cancel-before-rename"
         in
         let cancellation_payload =
           Failure ("injected cancellation before rename: " ^ cancel_before_id)
         in
         let cancellation_backtrace = Printexc.get_callstack 32 in
         (match
            run_exact_transition_with_writer
              AQ.For_testing.bind_summary_exact_attempt_with_writer
              ~writer:
                (before_rename_cancellation_writer
                   ~payload:cancellation_payload
                   ~backtrace:cancellation_backtrace)
              cancel_before_identity
          with
          | exception Eio.Cancel.Cancelled observed_payload ->
            let observed_backtrace = Printexc.get_raw_backtrace () in
            Alcotest.(check bool)
              "pre-rename cancellation payload preserved"
              true
              (observed_payload == cancellation_payload);
            let expected_backtrace =
              Printexc.raw_backtrace_to_string cancellation_backtrace
            in
            let observed_backtrace =
              Printexc.raw_backtrace_to_string observed_backtrace
            in
            Alcotest.(check bool)
              "pre-rename cancellation backtrace preserved"
              true
              (String.starts_with
                 ~prefix:expected_backtrace
                 observed_backtrace)
          | Error error ->
            Alcotest.failf
              "pre-rename cancellation became an exact error: %s"
              (AQ.exact_attempt_error_to_string error)
          | Ok _ ->
            Alcotest.fail "pre-rename cancellation reported a write outcome");
         (match pending_entry_exn cancel_before_id with
          | { exact_attempt = Rule_types.Exact_unbound; _ } -> ()
          | _ -> Alcotest.fail "pre-rename cancellation mutated exact memory");
         let cancel_after_id, cancel_after_identity =
           prepare "cancel-after-rename"
         in
         check_visible_update
           "post-rename cancellation is visible"
           true
           (run_exact_transition_with_writer
              AQ.For_testing.bind_summary_exact_attempt_with_writer
              ~writer:visible_after_rename_cancellation_writer
              cancel_after_identity);
         assert_status
           "post-rename cancellation converges memory"
           cancel_after_id
           "dispatch_uncertain";
       let release_id, release_identity = prepare "release" in
       check_exact_update
         "bind release fixture"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt release_identity);
       check_visible_update
         "visible release"
         true
         (run_exact_transition_with_writer
            AQ.For_testing.release_summary_exact_attempt_before_dispatch_with_writer
            ~writer:visible_after_rename_writer
            release_identity);
       assert_status
         "visible release memory"
         release_id
         "released_before_dispatch";
       check_exact_update
         "idempotent release confirms durability"
         false
         (run_exact_transition
            AQ.release_summary_exact_attempt_before_dispatch
            release_identity);
       List.iter
         (fun (label, cause) ->
            match quarantine_exact release_identity cause with
            | Error
                (AQ.Exact_attempt_rejected
                  (AQ.Exact_attempt_status_conflict _)) ->
              ()
            | Error error ->
              Alcotest.fail
                (AQ.exact_attempt_error_to_string error)
            | Ok _ ->
              Alcotest.failf
                "released binding accepted %s"
                label)
         [ "domain-invalid output", Rule_types.Exact_domain_invalid_output
         ; "attempt replay", Rule_types.Exact_attempt_replay
         ];
       assert_status
         "rejected causes preserve release"
         release_id
         "released_before_dispatch";
       check_exact_update
         "typed release uncertainty terminalization"
         true
         (quarantine_exact
            release_identity
            Rule_types.Exact_terminal_persistence_failure);
       assert_status "release terminal memory" release_id "quarantined";
       let terminalize_released label cause =
         let id, identity = prepare label in
         check_exact_update
           ("bind " ^ label)
           true
           (run_exact_transition
              AQ.bind_summary_exact_attempt
              identity);
         check_exact_update
           ("release " ^ label)
           true
           (run_exact_transition
              AQ.release_summary_exact_attempt_before_dispatch
              identity);
         check_exact_update
           ("quarantine " ^ label)
           true
           (quarantine_exact identity cause);
         match pending_entry_exn id with
         | { exact_attempt =
               Rule_types.Exact_bound
                 { status = Rule_types.Exact_quarantined actual; _ }
           ; _
           } when actual = cause ->
           ()
         | _ ->
           Alcotest.failf
             "%s did not retain its exact quarantine cause"
             label
       in
       terminalize_released
         "release-cancellation"
         Rule_types.Exact_cancellation;
       terminalize_released
         "release-flow-execution-failed"
         Rule_types.Exact_flow_execution_failed;
       let quarantine_id, quarantine_identity = prepare "quarantine" in
       check_exact_update
         "bind quarantine fixture"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt quarantine_identity);
       check_visible_update
         "visible quarantine"
         true
         (AQ.For_testing.quarantine_summary_exact_attempt_with_writer
            ~save_file_atomic_strict_staged:visible_after_rename_writer
            ~id:quarantine_identity.approval_id_arg
            ~input_hash:quarantine_identity.input_hash_arg
            ~sequence:quarantine_identity.sequence_arg
            ~slot_id:quarantine_identity.slot_id_arg
            ~call_id:quarantine_identity.call_id_arg
            ~plan_fingerprint:quarantine_identity.plan_fingerprint_arg
            ~request_body_sha256:quarantine_identity.request_body_sha256_arg
            ~cause:Rule_types.Exact_flow_execution_failed);
       assert_status
         "visible quarantine memory"
         quarantine_id
         "quarantined";
       check_exact_update
         "idempotent quarantine confirms durability"
         false
         (quarantine_exact
            quarantine_identity
            Rule_types.Exact_flow_execution_failed);
       let complete_id, complete_identity = prepare "complete" in
       check_exact_update
         "bind completion fixture"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt complete_identity);
       let summary = exact_summary complete_identity.call_id_arg in
       check_visible_update
         "visible completion"
         true
         (AQ.For_testing.complete_summary_exact_attempt_with_writer
            ~save_file_atomic_strict_staged:visible_after_rename_writer
            ~id:complete_identity.approval_id_arg
            ~input_hash:complete_identity.input_hash_arg
            ~sequence:complete_identity.sequence_arg
            ~slot_id:complete_identity.slot_id_arg
            ~call_id:complete_identity.call_id_arg
            ~plan_fingerprint:complete_identity.plan_fingerprint_arg
            ~request_body_sha256:complete_identity.request_body_sha256_arg
            ~summary);
       assert_status "visible completion memory" complete_id "completed";
       check_exact_update
         "idempotent completion confirms durability"
         false
         (complete_exact complete_identity summary))
;;

let test_exact_completed_restart_requires_fsync_confirmation () =
  let base_path = temp_dir () in
  let keeper_name = "queue-exact-restart-fsync" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "request", `String "restart-fsync" ])
       in
       check_update "mark exact restart pending" true (AQ.mark_summary_pending ~id);
       let identity = exact_identity id in
       check_exact_update
         "bind exact restart identity"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt identity);
       let summary = exact_summary identity.call_id_arg in
       check_exact_update
         "complete exact restart summary"
         true
         (complete_exact identity summary);
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let observed_calls = ref 0 in
       let injected_completion write_outcome
             ~id:actual_id
             ~input_hash
             ~sequence
             ~slot_id
             ~call_id
             ~plan_fingerprint
             ~request_body_sha256
             ~summary:(actual_summary : Rule_types.hitl_context_summary)
         =
         incr observed_calls;
         Alcotest.(check string) "recovery approval identity" id actual_id;
         Alcotest.(check string)
           "recovery input identity"
           identity.input_hash_arg
           input_hash;
         Alcotest.(check int)
           "recovery sequence identity"
           identity.sequence_arg
           sequence;
         Alcotest.(check string)
           "recovery slot identity"
           identity.slot_id_arg
           slot_id;
         Alcotest.(check string)
           "recovery call identity"
           identity.call_id_arg
           call_id;
         Alcotest.(check string)
           "recovery plan identity"
           identity.plan_fingerprint_arg
           plan_fingerprint;
         Alcotest.(check string)
           "recovery body identity"
           identity.request_body_sha256_arg
           request_body_sha256;
         Alcotest.(check string)
           "recovery summary identity"
           summary.model_run_id
           actual_summary.model_run_id;
         Ok { AQ.changed = false; write_outcome }
       in
       let deterministic_report =
         Gate.For_testing.resume_persisted_auto_judges_with_exact_completion
           ~complete_summary_exact_attempt:
             (fun
               ~id:_
               ~input_hash:_
               ~sequence:_
               ~slot_id:_
               ~call_id:_
               ~plan_fingerprint:_
               ~request_body_sha256:_
               ~summary:_ ->
              Error
                (AQ.Exact_attempt_rejected
                   (AQ.Exact_attempt_content_conflict id)))
           ~base_path
       in
       (match deterministic_report.failures with
        | [ { Gate.code =
                Gate.Resume_completion_rejected
                  Gate.Completion_content_conflict
            ; _
            } ] ->
          ()
        | _ ->
          Alcotest.fail
            "deterministic completion rejection lost its typed recovery code");
       (match AQ.For_testing.get_pending_entry_unchecked ~id with
        | Some { summary_attempt_disposition = Rule_types.Summary_attempt_settled; _ } ->
          ()
        | _ ->
          Alcotest.fail
            "deterministic completion rejection changed durable disposition");
       let visible_report =
         Gate.For_testing.resume_persisted_auto_judges_with_exact_completion
           ~complete_summary_exact_attempt:
             (injected_completion
                (AQ.Visible_sync_unconfirmed
                   "injected recovery parent sync failure"))
           ~base_path
       in
       Alcotest.(check int) "visible recovery candidate" 1 visible_report.requested;
       Alcotest.(check int)
         "visible recovery finalizes zero"
         0
         (List.length visible_report.finalized_ids);
       Alcotest.(check int)
         "visible recovery records failure"
         1
         (List.length visible_report.failures);
       Alcotest.(check bool) "visible recovery keeps pending" true
         (Option.is_some (AQ.For_testing.get_pending_entry_unchecked ~id));
       let error_report =
         Gate.For_testing.resume_persisted_auto_judges_with_exact_completion
           ~complete_summary_exact_attempt:
             (fun
               ~id:_
               ~input_hash:_
               ~sequence:_
               ~slot_id:_
               ~call_id:_
               ~plan_fingerprint:_
               ~request_body_sha256:_
               ~summary:_ ->
              Error
                (AQ.Exact_attempt_storage_error
                   { path = "injected"; reason = "before rename" }))
           ~base_path
       in
       Alcotest.(check int)
         "error recovery finalizes zero"
         0
         (List.length error_report.finalized_ids);
       Alcotest.(check int)
         "error recovery records failure"
         1
         (List.length error_report.failures);
       Alcotest.(check bool) "error recovery keeps pending" true
         (Option.is_some (AQ.For_testing.get_pending_entry_unchecked ~id));
       let durable_report = Gate.resume_persisted_auto_judges ~base_path in
       Alcotest.(check (list string))
         "fsync-confirmed recovery finalizes once"
         [ id ]
         durable_report.finalized_ids;
       Alcotest.(check int)
         "fsync-confirmed recovery has no failure"
         0
         (List.length durable_report.failures);
       Alcotest.(check int)
         "injected exact identity confirmations"
         1
         !observed_calls;
       Alcotest.(check bool) "durable recovery removes pending" true
         (Option.is_none (AQ.For_testing.get_pending_entry_unchecked ~id));
       let resolution =
         durable_resolution_opt ~base_path ~keeper_name ~approval_id:id
         |> require_some "fsync-confirmed recovery did not finalize"
       in
       drop_resolution ~base_path ~keeper_name resolution)
;;

(* A stricter keeper override can hold one keeper in auto_judge above an
   always_allow workspace. Boot recovery admits owners by their EFFECTIVE
   mode, so that keeper's queue is still served — the old workspace-mode
   short-circuit recovered nothing for it, leaving its approvals queued
   with nothing sweeping them. *)
let test_override_only_auto_judge_owner_is_recovered () =
  let base_path = temp_dir () in
  let keeper_name = "queue-override-island" in
  let bystander = "queue-workspace-loose" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let config = Masc.Workspace.default_config base_path in
       (match
          Masc.Keeper_gate_mode.set config ~actor:"test"
            Masc.Keeper_gate_mode.Always_allow
        with
        | Ok _ -> ()
        | Error e -> Alcotest.fail e);
       (match
          Masc.Keeper_gate_mode.set_for_keeper config ~actor:"test"
            ~keeper_name
            (Some Masc.Keeper_gate_mode.Auto_judge)
        with
        | Ok _ -> ()
        | Error e -> Alcotest.fail e);
       let id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "request", `String "override-island" ])
       in
       let bystander_id =
         submit
           ~base_path
           ~keeper_name:bystander
           ~input:(`Assoc [ "request", `String "workspace-loose" ])
       in
       let report = Gate.resume_persisted_auto_judges ~base_path in
       Alcotest.(check int)
         "only the override-held owner is a recovery candidate"
         1
         report.requested;
       Alcotest.(check bool)
         "override owner's entry was picked up"
         true
         (List.mem id (report.started_ids @ report.finalized_ids)
          || List.exists
               (fun (failure : Gate.auto_judge_resume_failure) ->
                  String.equal failure.approval_id id)
               report.failures);
       Alcotest.(check bool)
         "workspace-loose bystander stays pending, untouched by auto-judge"
         true
         (Option.is_some
            (AQ.For_testing.get_pending_entry_unchecked ~id:bystander_id)))
;;

(* The operator recovery entry point shares the sweep's per-owner admission
   (#31321 residue): on an always_allow workspace with one keeper pinned to
   auto_judge, the old workspace-mode guard refused with "requires auto_judge
   mode" — the exact stalled-owner configuration the escape hatch exists
   for. It must now run and report, not refuse. *)
let test_operator_recovery_admits_override_only_workspace () =
  let base_path = temp_dir () in
  let keeper_name = "queue-recovery-override" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let config = Masc.Workspace.default_config base_path in
       (match
          Masc.Keeper_gate_mode.set config ~actor:"test"
            Masc.Keeper_gate_mode.Always_allow
        with
        | Ok _ -> ()
        | Error e -> Alcotest.fail e);
       (match
          Masc.Keeper_gate_mode.set_for_keeper config ~actor:"test"
            ~keeper_name
            (Some Masc.Keeper_gate_mode.Auto_judge)
        with
        | Ok _ -> ()
        | Error e -> Alcotest.fail e);
       let id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "request", `String "recovery-override" ])
       in
       ignore id;
       (* This fixture publishes no exact-output registry, so the call may
          stop at the later topology-readiness gate; the regression under
          test is only the FIRST gate — the workspace-mode refusal that
          used to fire before any per-owner resolution. *)
       match Gate.request_operator_auto_judge_recovery ~base_path with
       | Ok _ -> ()
       | Error e ->
           Alcotest.(check bool)
             ("refusal is not the workspace-mode guard: " ^ e)
             false
             (String_util.contains_substring e "requires auto_judge mode"))
;;

let test_current_snapshot_rejects_unbound_available_summary () =
  let base_path = temp_dir () in
  let keeper_name = "queue-recovered-exact-unbound" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "request", `String "recovered-unbound" ])
       in
       check_update
         "mark recovered-unbound summary pending"
         true
         (AQ.mark_summary_pending ~id);
       let entry = pending_entry_exn id in
       (match
          AQ.mark_summary_attempt_identity_unbound
            ~base_path
            ~id
            ~input_hash:entry.input_hash
            ~sequence:entry.sequence
        with
        | Ok changed ->
          Alcotest.(check bool)
            "persist identity-unbound disposition"
            true
            changed
        | Error error ->
          Alcotest.fail (AQ.exact_attempt_error_to_string error));
       let summary = exact_summary "recovered-unbound-call" in
       let snapshot =
         match read_pending_snapshot ~base_path with
         | `Assoc fields ->
           let pending =
             match List.assoc_opt "pending" fields with
             | Some (`List entries) ->
               List.map
                 (function
                   | `Assoc entry_fields as entry_json ->
                     if
                       List.assoc_opt "id" entry_fields
                       = Some (`String id)
                     then
                       `Assoc
                         (("summary_status",
                            Rule_types.summary_status_to_yojson
                              (Rule_types.Summary_available summary))
                          :: List.remove_assoc "summary_status" entry_fields)
                     else entry_json
                   | entry_json -> entry_json)
                 entries
             | _ -> Alcotest.fail "pending snapshot omitted its pending rows"
           in
           `Assoc
             (("pending", `List pending) :: List.remove_assoc "pending" fields)
         | _ -> Alcotest.fail "pending snapshot root was not an object"
       in
       write_pending_snapshot ~base_path snapshot;
       let original = read_pending_snapshot_bytes ~base_path in
       AQ.For_testing.reset_runtime_state ();
       (match AQ.install_persistence ~base_path with
        | Error (AQ.Install_storage_failed _) -> ()
        | Ok _ ->
          Alcotest.fail
            "current snapshot installed Exact_unbound with an available summary");
       Alcotest.(check string)
         "rejected current snapshot is preserved"
         original
         (read_pending_snapshot_bytes ~base_path))
;;

let test_blocked_disposition_requires_operator_rearm_before_bind () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name:"queue-blocked-bind"
           ~input:(`String "blocked-bind")
       in
       check_update
         "mark blocked bind pending"
         true
         (AQ.mark_summary_pending ~id);
       let entry = pending_entry_exn id in
       (match
          AQ.mark_summary_attempt_identity_unbound
            ~base_path
            ~id
            ~input_hash:entry.input_hash
            ~sequence:entry.sequence
        with
        | Ok true -> ()
        | Ok false -> Alcotest.fail "identity-unbound disposition was not stored"
        | Error error ->
          Alcotest.fail (AQ.exact_attempt_error_to_string error));
       let identity =
         exact_identity
           ~slot_id:"slot-blocked-bind"
           ~call_id:"call-blocked-bind"
           id
       in
       (match run_exact_transition AQ.bind_summary_exact_attempt identity with
        | Error
            (AQ.Exact_attempt_rejected
               (AQ.Exact_attempt_disposition_conflict
                  { disposition = Rule_types.Summary_attempt_identity_unbound; _ })) ->
          ()
        | Error error ->
          Alcotest.fail
            ("blocked bind returned the wrong rejection: "
             ^ AQ.exact_attempt_error_to_string error)
        | Ok _ ->
          Alcotest.fail "blocked disposition bound without operator rearm");
       let entry = pending_entry_exn id in
       (match
          AQ.reserve_summary_attempt_retry
            ~base_path
            ~id
            ~input_hash:entry.input_hash
            ~sequence:entry.sequence
            ~expected_exact_attempt:entry.exact_attempt
            ~expected_disposition:entry.summary_attempt_disposition
            ~requested_by:"operator:test"
        with
        | Ok true -> ()
        | Ok false -> Alcotest.fail "operator rearm did not change blocked row"
        | Error error ->
          Alcotest.fail (AQ.exact_attempt_error_to_string error));
       let reserved_entry = pending_entry_exn id in
       check_rearm
         "in-flight start reservation cannot be reserved again"
         false
         (reserve_retry_exact ~base_path reserved_entry);
       (match
          AQ.mark_summary_attempt_identity_unbound
            ~base_path
            ~id
            ~input_hash:reserved_entry.input_hash
            ~sequence:reserved_entry.sequence
        with
        | Ok true -> ()
        | Ok false ->
          Alcotest.fail
            "pre-bind start reservation did not settle identity-unbound"
        | Error error ->
          Alcotest.fail (AQ.exact_attempt_error_to_string error));
       let retryable_entry = pending_entry_exn id in
       check_rearm
         "pre-bind terminal failure restores explicit retryability"
         true
         (reserve_retry_exact ~base_path retryable_entry);
       (match AQ.For_testing.get_pending_entry_unchecked ~id with
        | Some
            { summary_status = Rule_types.Summary_pending
            ; exact_attempt = Rule_types.Exact_unbound
            ; summary_attempt_disposition =
                Rule_types.Summary_attempt_pre_worker_unavailable
                  { reason_code = Rule_types.Summary_pre_worker_start_reserved
                  ; operator_detail
                  }
            ; _
            }
          when
            String.equal
              operator_detail
              AQ.summary_attempt_start_reserved_operator_detail ->
          ()
        | Some _ ->
          Alcotest.fail
            "operator retry persisted an intermediate ready disposition"
        | None -> Alcotest.fail "operator retry removed the pending row");
       check_exact_update
         "rearmed disposition permits one exact bind"
         true
         (run_exact_transition AQ.bind_summary_exact_attempt identity);
       reject_and_cleanup ~base_path id)
;;

let test_orphaned_start_reservation_reclaims_to_ready () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name:"queue-orphan-start"
           ~input:(`String "orphan-start")
       in
       check_update
         "mark orphan-start pending"
         true
         (AQ.mark_summary_pending ~id);
       let entry = pending_entry_exn id in
       (* Reserve the worker start exactly as [reserve_pre_worker_start] does, then
          treat a hard restart as leaving the durable row stranded: the in-memory
          settle to identity-unbound never ran. *)
       (match
          AQ.mark_summary_attempt_pre_worker_unavailable
            ~base_path
            ~id
            ~input_hash:entry.input_hash
            ~sequence:entry.sequence
            ~reason_code:Rule_types.Summary_pre_worker_start_reserved
            ~operator_detail:AQ.summary_attempt_start_reserved_operator_detail
        with
        | Ok true -> ()
        | Ok false -> Alcotest.fail "start reservation was not stored"
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error));
       let reserved = pending_entry_exn id in
       (match
          AQ.release_orphaned_start_reservation
            ~base_path
            ~id
            ~input_hash:reserved.input_hash
            ~sequence:reserved.sequence
        with
        | Ok true -> ()
        | Ok false ->
          Alcotest.fail "orphaned start reservation was not reclaimed"
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error));
       (match AQ.For_testing.get_pending_entry_unchecked ~id with
        | Some
            { summary_status = Rule_types.Summary_pending
            ; exact_attempt = Rule_types.Exact_unbound
            ; summary_attempt_disposition = Rule_types.Summary_attempt_ready
            ; _
            } ->
          ()
        | Some _ ->
          Alcotest.fail "reclaim did not restore the ready disposition"
        | None -> Alcotest.fail "reclaim removed the pending row");
       (* A ready row is not a start reservation: a second reclaim is a no-op and
          never disturbs a row it should not own. *)
       let ready = pending_entry_exn id in
       (match
          AQ.release_orphaned_start_reservation
            ~base_path
            ~id
            ~input_hash:ready.input_hash
            ~sequence:ready.sequence
        with
        | Ok false -> ()
        | Ok true ->
          Alcotest.fail "reclaim touched a row that was not a start reservation"
        | Error error -> Alcotest.fail (AQ.exact_attempt_error_to_string error));
       reject_and_cleanup ~base_path id)
;;

let test_operator_recovery_skips_terminal_exact_failure () =
  let base_path = temp_dir () in
  let keeper_name = "queue-summary-operator-recovery" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let quarantined_id =
         submit ~base_path ~keeper_name ~input:(`String "quarantined")
       in
       check_update
         "mark exact failure pending"
         true
         (AQ.mark_summary_pending ~id:quarantined_id);
       let quarantined_identity =
         exact_identity
           ~slot_id:"slot-quarantined"
           ~call_id:"call-quarantined"
           quarantined_id
       in
       check_exact_update
         "bind terminal exact failure"
         true
         (run_exact_transition
            AQ.bind_summary_exact_attempt
            quarantined_identity);
       check_exact_update
         "quarantine terminal exact failure"
         true
         (quarantine_exact
            quarantined_identity
            Rule_types.Exact_flow_execution_failed);
       check_rearm
         "explicit operator action cannot reopen exact quarantine"
         false
         (reserve_retry_exact ~base_path (pending_entry_exn quarantined_id));
       (match AQ.For_testing.get_pending_entry_unchecked ~id:quarantined_id with
        | Some
            { summary_status = Rule_types.Summary_failed _
            ; exact_attempt =
                Rule_types.Exact_bound
                  { status =
                      Rule_types.Exact_quarantined Rule_types.Exact_flow_execution_failed
                  ; _
                  }
            ; _
            } ->
          ()
        | Some _ | None ->
          Alcotest.fail "bulk recovery changed a terminal exact quarantine");
       reject_and_cleanup ~base_path quarantined_id)
;;

let test_summary_owner_retirement_is_atomic_and_owner_scoped () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let pending keeper_name value =
         let id =
           submit
             ~base_path
             ~keeper_name
             ~input:(`String value)
         in
         check_update
           "mark pending"
           true
           (AQ.mark_summary_pending ~id);
         id
       in
       let owner = "retirement-blocked" in
       let bound = pending owner "bound" in
       let sibling = pending owner "sibling" in
       let retirable = pending "retirement-unbound" "retire" in
       check_exact_update
         "bind blocker"
         true
         (run_exact_transition
            AQ.bind_summary_exact_attempt
            (exact_identity ~slot_id:"slot" ~call_id:"call" bound));
       (match
          AQ.retire_summary_owner
            ~base_path
            ~keeper_name:owner
            ~reason:"retired"
        with
        | Error
            (AQ.Summary_owner_retirement_exact_attempt_unsettled _) ->
          ()
        | Error error ->
          Alcotest.fail
            (AQ.summary_owner_retirement_error_to_string error)
        | Ok _ -> Alcotest.fail "bound owner retirement succeeded");
       (match AQ.For_testing.get_pending_entry_unchecked ~id:bound with
        | Some
            { summary_status = Rule_types.Summary_pending
            ; exact_attempt = Rule_types.Exact_bound binding
            ; _
            } ->
          Alcotest.(check string)
            "bound call unchanged"
            "call"
            binding.call_id
        | Some _ | None ->
          Alcotest.fail "bound entry changed on failed retirement");
       (match AQ.For_testing.get_pending_entry_unchecked ~id:sibling with
        | Some { summary_status = Rule_types.Summary_pending; _ } -> ()
        | Some _ | None ->
          Alcotest.fail "blocked retirement partially mutated");
       (match
          AQ.retire_summary_owner
            ~base_path
            ~keeper_name:"retirement-unbound"
            ~reason:"retired"
        with
        | Error error ->
          Alcotest.fail
            (AQ.summary_owner_retirement_error_to_string error)
        | Ok ids ->
          Alcotest.(check (list string))
            "retired ids"
            [ retirable ]
            ids);
       match AQ.For_testing.get_pending_entry_unchecked ~id:retirable with
       | Some
           { summary_status = Rule_types.Summary_failed { reason = "retired" }
           ; _
           } ->
         ()
       | Some _ | None ->
         Alcotest.fail "pending summary was not terminalized")
;;

let test_dashboard_resolve_rejects_cross_workspace_approval () =
  let base_a = temp_dir () in
  let base_b = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_a;
      cleanup_dir base_b)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path:base_a);
       let approval_id =
         submit
           ~base_path:base_a
           ~keeper_name:"queue-resolve-base-a"
           ~input:(`Assoc [ "request", `String "base-a" ])
       in
       ignore (install_exn ~base_path:base_b);
       let resolve ~decision ~remember_rule =
         Server_dashboard_http.dashboard_gate_resolve_http_json
           ~base_path:base_b
           ~created_by:"operator-b"
           ~args:
             (`Assoc
                 [ "id", `String approval_id
                 ; "decision", `String decision
                 ; "reason", `String "cross-workspace probe"
                 ; "remember_rule", `Bool remember_rule
                 ])
       in
       List.iter
         (fun (decision, remember_rule) ->
            match resolve ~decision ~remember_rule with
            | Error
                (Server_dashboard_http.Gone
                   (AQ.Not_found missing_id)) ->
              Alcotest.(check string)
                "cross-workspace id is indistinguishable from missing"
                approval_id
                missing_id
            | Error error ->
              Alcotest.fail
                (Server_dashboard_http.approval_resolve_http_error_to_string error)
            | Ok _ -> Alcotest.fail "workspace B resolved workspace A approval")
         [ "approve", true; "reject", false ];
       Alcotest.(check bool)
         "source approval remains pending"
         true
         (Option.is_some (AQ.For_testing.get_pending_entry_unchecked ~id:approval_id));
       List.iter
         (fun base_path ->
            Alcotest.(check bool)
              "cross-workspace resolve did not persist a rule"
              false
              (Sys.file_exists
                 (AQ.For_testing.always_allowed_store_path ~base_path)))
         [ base_a; base_b ];
       ignore (install_exn ~base_path:base_a);
       reject_and_cleanup ~base_path:base_a approval_id)
;;

let test_malformed_snapshot_fails_install_and_is_observed () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       write_pending_snapshot
         ~base_path
         (`Assoc
            [ "version", `Int 9
            ; "next_sequence", `Int 1
            ; "pending", `String "malformed-pending-array"
            ; "deliveries", `List []
            ]);
       let before =
         Masc.Otel_metric_store.metric_value_or_zero
           Masc.Otel_metric_store.metric_persistence_read_drops
           ~labels:[ "surface", "keeper_gate_pending"; "reason", "invalid_payload" ]
           ()
       in
       (match AQ.install_persistence ~base_path with
        | Ok _ -> Alcotest.fail "malformed snapshot must not install"
       | Error (AQ.Install_storage_failed _) -> ()
        );
       Alcotest.(check bool)
         "failed install leaves workspace unavailable"
         true
         (Result.is_error
            (AQ.list_pending_entries_for_workspace ~base_path));
       (match
          AQ.submit_pending
            ~keeper_name:"queue-invalid-store"
            ~tool_name:"external-effect"
            ~input:(`Assoc [ "target", `String "must-not-overwrite" ])
            ~base_path
            ()
        with
        | Error _ -> ()
        | Ok _ -> Alcotest.fail "an invalid installed store must remain unavailable");
       let persisted = read_pending_snapshot ~base_path in
       Alcotest.(check bool) "invalid store is not overwritten" true
         (Yojson.Safe.equal
            persisted
            (`Assoc
               [ "version", `Int 9
               ; "next_sequence", `Int 1
               ; "pending", `String "malformed-pending-array"
               ; "deliveries", `List []
               ]));
       let after =
         Masc.Otel_metric_store.metric_value_or_zero
           Masc.Otel_metric_store.metric_persistence_read_drops
           ~labels:[ "surface", "keeper_gate_pending"; "reason", "invalid_payload" ]
           ()
       in
       Alcotest.(check bool) "malformed snapshot observed" true (after -. before >= 1.0))
;;

let test_partial_pending_snapshot_preserves_readable_entries () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let approval_id =
         submit
           ~base_path
           ~keeper_name:"queue-partial-read"
           ~input:(`Assoc [ "request", `String "readable" ])
       in
       let snapshot =
         match read_pending_snapshot ~base_path with
         | `Assoc fields ->
           (match List.assoc_opt "pending" fields with
            | Some (`List entries) ->
              `Assoc
                ( ("pending", `List (entries @ [ `String "malformed-entry" ]))
                  :: List.remove_assoc "pending" fields )
            | _ -> Alcotest.fail "pending snapshot array expected")
         | _ -> Alcotest.fail "pending snapshot object expected"
       in
       write_pending_snapshot ~base_path snapshot;
       let original = read_pending_snapshot ~base_path in
       AQ.For_testing.reset_runtime_state ();
       let before =
         Masc.Otel_metric_store.metric_value_or_zero
           Masc.Otel_metric_store.metric_persistence_read_drops
           ~labels:[ "surface", "keeper_gate_pending"; "reason", "invalid_payload" ]
           ()
       in
       let report = install_exn ~base_path in
       Alcotest.(check int) "one valid pending entry installed" 1 report.loaded_pending;
       let entries, read_errors =
         require_ok
           "partial pending list"
           (AQ.list_pending_entries_with_read_errors_for_workspace ~base_path)
       in
       (match entries with
        | [ entry ] -> Alcotest.(check string) "valid entry remains visible" approval_id entry.id
        | _ -> Alcotest.fail "expected exactly one readable pending entry");
       Alcotest.(check int)
         "one pending entry read error is exposed"
         1
         (List.length read_errors);
       (match
          AQ.submit_pending
            ~keeper_name:"queue-partial-read"
            ~tool_name:"external-effect"
            ~input:(`Assoc [ "target", `String "must-not-overwrite" ])
            ~base_path
            ()
        with
        | Error _ -> ()
        | Ok _ -> Alcotest.fail "partially readable store must remain unavailable");
       Alcotest.(check bool)
         "partially readable source is preserved"
         true
         (Yojson.Safe.equal original (read_pending_snapshot ~base_path));
       let after =
         Masc.Otel_metric_store.metric_value_or_zero
           Masc.Otel_metric_store.metric_persistence_read_drops
           ~labels:[ "surface", "keeper_gate_pending"; "reason", "invalid_payload" ]
           ()
       in
       Alcotest.(check bool) "partial entry error observed" true (after -. before >= 1.0))
;;

let test_unsupported_version_snapshot_requires_runtime_reset () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       write_pending_snapshot
         ~base_path
         (`Assoc
            [ "version", `Int 8
            ; "pending", `List []
            ; "deliveries", `List []
            ]);
       let original = read_pending_snapshot_bytes ~base_path in
       (match AQ.install_persistence ~base_path with
        | Ok _ -> Alcotest.fail "unsupported version must fail install"
        | Error
            (AQ.Install_storage_failed
              { reason =
                  "gate_pending.version 8 is unsupported (current 9); reset \
                   runtime state before restarting MASC"
              ; _
              }) ->
          ()
        | Error error ->
          Alcotest.failf
            "unsupported version returned the wrong error: %s"
            (AQ.install_error_to_string error));
       let store_path = AQ.For_testing.pending_store_path ~base_path in
       Alcotest.(check bool) "original remains for operator reset" true
         (Sys.file_exists store_path);
       let preserved = read_pending_snapshot_bytes ~base_path in
       Alcotest.(check string) "content preserved byte-for-byte" original preserved)
;;

let test_unreadable_snapshot_fails_closed_and_is_preserved () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       let store_path = AQ.For_testing.pending_store_path ~base_path in
       ensure_dir (Filename.dirname store_path);
       Out_channel.with_open_text store_path (fun channel ->
         output_string channel "{not-json");
       (match AQ.install_persistence ~base_path with
        | Ok _ -> Alcotest.fail "unreadable snapshot must not install"
        | Error _ -> ());
       Alcotest.(check bool) "file left in place" true
         (Sys.file_exists store_path))
;;

let test_malformed_replay_sidecar_is_scoped_and_preserved () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       ignore
         (submit
            ~base_path
            ~keeper_name:"queue-malformed-replay-sidecar"
            ~input:(`Assoc [ "target", `String "pending" ]));
       let sidecar_path =
         AQ.For_testing.replay_results_store_path ~base_path
       in
       Out_channel.with_open_text sidecar_path (fun channel ->
         output_string channel "{not-json");
       AQ.For_testing.reset_runtime_state ();
       (match AQ.install_persistence ~base_path with
        | Ok
            { loaded_pending = 1
            ; replay_projection_error = Some { path; _ }
            ; _
            } ->
          Alcotest.(check string)
            "malformed sidecar owns only the projection error path"
            sidecar_path
            path
        | Ok _ ->
          Alcotest.fail "malformed replay sidecar was not reported"
        | Error error ->
          Alcotest.fail
            ("malformed replay sidecar blocked the authorization store: "
             ^ AQ.install_error_to_string error));
       Alcotest.(check bool)
         "malformed sidecar remains for operator repair"
         true
         (Sys.file_exists sidecar_path);
       Alcotest.(check string)
         "malformed sidecar is preserved byte-for-byte"
         "{not-json"
         (In_channel.with_open_bin sidecar_path In_channel.input_all))
;;

let test_replay_sidecar_rejects_raw_output_wire () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let sidecar_path =
         AQ.For_testing.replay_results_store_path ~base_path
       in
       ensure_dir (Filename.dirname sidecar_path);
       Yojson.Safe.to_file
         sidecar_path
         (`Assoc
            [ "version", `Int 1
            ; ( "outcomes"
              , `List
                  [ `Assoc
                      [ "approval_id", `String "approval-raw-output"
                      ; ( "outcome"
                        , `Assoc
                            [ "kind", `String "applied"
                            ; "output", `String "legacy raw output"
                            ] )
                      ]
                  ] )
            ]);
       AQ.For_testing.reset_runtime_state ();
       (match AQ.install_persistence ~base_path with
        | Ok
            { replay_projection_error = Some { path; _ }; _ } ->
          Alcotest.(check string)
            "raw output wire owns only the projection error"
            sidecar_path
            path
        | Ok _ ->
          Alcotest.fail "raw replay output wire was not rejected"
        | Error error ->
          Alcotest.fail
            ("raw replay output wire blocked the authorization store: "
             ^ AQ.install_error_to_string error));
       let keeper_name = "queue-ready-despite-raw-replay-wire" in
       let input = `Assoc [ "target", `String "current" ] in
       let approval_id = submit ~base_path ~keeper_name ~input in
       (match
          aq_resolve
            ~base_path
            ~id:approval_id
            ~decision:Rule_types.Decision.Approve
        with
        | Ok () -> ()
        | Error error ->
          Alcotest.fail
            ("projection error blocked Gate resolution: "
             ^ AQ.resolve_error_to_string error));
       (match
          AQ.consume_approved_resolution
            ~base_path
            ~id:approval_id
            ~keeper_name
            ~tool_name:"external-effect"
            ~input
        with
        | Ok (AQ.Consumption_committed _) -> ()
        | Ok _ ->
          Alcotest.fail "projection error blocked exact grant consumption"
        | Error error ->
          Alcotest.fail
            ("projection error blocked the authorization store: "
             ^ AQ.grant_error_to_string error));
       let output_ref =
         store_replay_artifact ~base_path "current replay result"
       in
       (match
          AQ.record_consumed_resolution_replay
            ~base_path
            ~id:approval_id
            ~outcome:(AQ.Replay_applied output_ref)
        with
        | Error (AQ.Grant_replay_projection_unavailable { path; _ }) ->
          Alcotest.(check string)
            "only replay-result publication remains unavailable"
            sidecar_path
            path
        | Error error ->
          Alcotest.fail
            ("wrong scoped replay projection error: "
             ^ AQ.grant_error_to_string error)
        | Ok _ ->
          Alcotest.fail "invalid projection was overwritten automatically");
       let persisted = Yojson.Safe.from_file sidecar_path in
       Alcotest.(check string)
         "rejected raw output remains untouched"
         "legacy raw output"
         Yojson.Safe.Util.(
           persisted
           |> member "outcomes"
           |> index 0
           |> member "outcome"
           |> member "output"
           |> to_string))
;;

let test_persisted_delivery_replays_before_origin_wake () =
  let base_path = temp_dir () in
  let keeper_name = "queue-replay-origin" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "target", `String "replay" ])
       in
       let pending_entry =
         match read_pending_snapshot ~base_path with
         | `Assoc fields ->
           (match List.assoc_opt "pending" fields with
            | Some (`List [ entry ]) -> entry
            | _ -> Alcotest.fail "expected one persisted pending entry")
         | _ -> Alcotest.fail "expected pending snapshot object"
       in
       write_pending_snapshot
         ~base_path
         (`Assoc
             [ "version", `Int 9
            ; "next_sequence", `Int 2
            ; "pending", `List []
            ; ( "deliveries"
              , `List
                  [ `Assoc
                      [ "entry", pending_entry
                      ; "decision", `Assoc [ "kind", `String "approve" ]
                      ; "source", `String "human_operator"
                      ; "remember_rule", `Bool false
                      ; "created_by", `Null
                      ; "grant_consumed", `Bool false
                      ]
                  ] )
            ]);
       AQ.For_testing.reset_runtime_state ();
       let report = install_exn ~base_path in
       Alcotest.(check int) "no pending restored" 0 report.loaded_pending;
       Alcotest.(check int) "delivery replayed" 1 report.replayed_deliveries;
       let resolution =
         match durable_resolution_opt ~base_path ~keeper_name ~approval_id:id with
         | Some resolution -> resolution
         | None -> Alcotest.fail "replayed delivery did not reach origin queue"
       in
       let open Yojson.Safe.Util in
       let snapshot = read_pending_snapshot ~base_path in
       Alcotest.(check int) "unconsumed delivery remains journaled" 1
         (snapshot |> member "deliveries" |> to_list |> List.length);
       (match
          AQ.consume_approved_resolution
            ~base_path
            ~id
            ~keeper_name
            ~tool_name:"external-effect"
            ~input:(`Assoc [ "target", `String "replay" ])
        with
        | Ok (AQ.Consumption_committed _) -> ()
        | Ok (AQ.Consumption_already_committed | AQ.Consumption_not_matching) ->
          Alcotest.fail "replayed exact grant was not consumed"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       let snapshot = read_pending_snapshot ~base_path in
       Alcotest.(check int) "consumption tombstone remains explicit" 1
         (snapshot |> member "deliveries" |> to_list |> List.length);
       Alcotest.(check bool) "consumption tombstone is committed" true
         (snapshot
          |> member "deliveries"
          |> to_list
          |> List.hd
          |> member "grant_consumed"
          |> to_bool);
       drop_resolution ~base_path ~keeper_name resolution)
;;

let test_observed_delivery_preserves_grant_without_replaying_wake () =
  let base_path = temp_dir () in
  let keeper_name = "queue-acked-replay-origin" in
  let input = `Assoc [ "target", `String "acked-replay" ] in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id = submit ~base_path ~keeper_name ~input in
       (match
          aq_resolve
            ~base_path
            ~id
            ~decision:Rule_types.Decision.Approve
        with
        | Ok () -> ()
        | Error error ->
          Alcotest.fail (AQ.resolve_error_to_string error));
       let resolution =
         match
           durable_resolution_opt
             ~base_path
             ~keeper_name
             ~approval_id:id
         with
         | Some resolution -> resolution
         | None -> Alcotest.fail "HITL wake was not durably queued"
       in
       let selection =
         match
           Event_queue_persistence.select_when_result
             ~base_path
             ~keeper_name
             ~now:(Unix.gettimeofday ())
             ~ready:(fun _ -> true)
         with
       | Ok (Some selection) -> selection
       | Ok None -> Alcotest.fail "HITL wake was not durably queued"
       | Error detail -> Alcotest.fail detail
       in
       Reaction_ledger.record_event_queue_turn_started
         ~base_path
         ~keeper_name
         selection.source;
       (match
          Event_queue_persistence.ack_pending_result
            ~base_path
            ~keeper_name
            ~selection
            ()
        with
        | Ok () -> ()
        | Error detail -> Alcotest.fail detail);
       let post_id =
         Keeper_event_queue.hitl_resolution_post_id resolution
       in
       (match
          Reaction_ledger.event_queue_turn_started_seen_for_source_result
            ~base_path
            ~keeper_name
            ~post_id
            ~stimulus_kind:Reaction_ledger.Hitl_resolved
        with
        | Ok true -> ()
        | Ok false ->
          Alcotest.failf
            "turn-started delivery evidence was not found: %s"
            (Reaction_ledger.summary_for_keeper
               ~base_path
               ~keeper_name
               ~limit:10
             |> Yojson.Safe.to_string)
        | Error error ->
          Alcotest.fail
            (Reaction_ledger.event_queue_reaction_evidence_error_to_string
               error));
       AQ.For_testing.reset_runtime_state ();
       let report = install_exn ~base_path in
       Alcotest.(check int)
         "observed wake is not replayed"
         0
         report.replayed_deliveries;
       Alcotest.(check bool)
         "observed wake stays absent after ack"
         true
         (Option.is_none
            (durable_resolution_opt
               ~base_path
               ~keeper_name
               ~approval_id:id));
       (match AQ.approved_resolution_state ~base_path ~id with
        | Ok AQ.Resolution_unconsumed -> ()
        | Ok AQ.Resolution_consumed ->
          Alcotest.fail "wake acknowledgement consumed the exact grant"
        | Error error ->
          Alcotest.fail (AQ.grant_error_to_string error));
       (match
          AQ.consume_approved_resolution
            ~base_path
            ~id
            ~keeper_name
            ~tool_name:"external-effect"
            ~input
        with
        | Ok (AQ.Consumption_committed _) -> ()
        | Ok
            ( AQ.Consumption_already_committed
            | AQ.Consumption_not_matching ) ->
          Alcotest.fail "preserved exact grant was not consumable"
       | Error error ->
          Alcotest.fail (AQ.grant_error_to_string error)))
;;

let test_cancelled_delivery_preserves_grant_without_replaying_wake () =
  let base_path = temp_dir () in
  let keeper_name = "queue-cancelled-replay-origin" in
  let input = `Assoc [ "target", `String "cancelled-replay" ] in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let id = submit ~base_path ~keeper_name ~input in
       (match
          aq_resolve
            ~base_path
            ~id
            ~decision:Rule_types.Decision.Approve
        with
        | Ok () -> ()
        | Error error ->
          Alcotest.fail (AQ.resolve_error_to_string error));
       let resolution =
         durable_resolution_opt
           ~base_path
           ~keeper_name
           ~approval_id:id
         |> require_some "HITL wake was not durably queued"
       in
       let selection =
         Event_queue_persistence.select_when_result
           ~base_path
           ~keeper_name
           ~now:(Unix.gettimeofday ())
           ~ready:(fun _ -> true)
         |> function
         | Ok (Some selection) -> selection
         | Ok None -> Alcotest.fail "HITL wake was not selectable"
         | Error detail -> Alcotest.fail detail
       in
       let cancellation : Keeper_event_queue_state.accepted_cancellation =
         { source = selection.source
         ; source_incarnation = selection.admitted_revision
         ; operator_operation_id = "cancel-approved-wake"
         ; reason = "source Keeper was removed"
         }
       in
       let receipt =
         match
           Event_queue_persistence.cancel_pending_accepted_result
             ~base_path
             ~keeper_name
             ~applied_at:(Unix.gettimeofday ())
             ~cancellation
             ()
         with
         | Ok (Event_queue_persistence.Transition_applied receipt)
         | Ok (Event_queue_persistence.Transition_already_applied receipt) ->
           receipt
         | Ok
             (Event_queue_persistence.Transition_committed_followup_failed
                { detail; _ }) ->
           Alcotest.fail detail
         | Error detail -> Alcotest.fail detail
       in
       (match
          Reaction_ledger.project_event_queue_transition_outbox_result
            ~base_path
            ~keeper_name
            ~expected_transition_id:receipt.transition_id
        with
        | Ok () -> ()
        | Error detail -> Alcotest.fail detail);
       let post_id =
         Keeper_event_queue.hitl_resolution_post_id resolution
       in
       (match
          Reaction_ledger.event_queue_delivery_seen_for_source_result
            ~base_path
            ~keeper_name
            ~post_id
            ~stimulus_kind:Reaction_ledger.Hitl_resolved
        with
        | Ok true -> ()
        | Ok false ->
          Alcotest.fail "accepted cancellation was not delivery evidence"
        | Error error ->
          Alcotest.fail
            (Reaction_ledger.event_queue_reaction_evidence_error_to_string
               error));
       AQ.For_testing.reset_runtime_state ();
       let report = install_exn ~base_path in
       Alcotest.(check int)
         "cancelled wake is not replayed"
         0
         report.replayed_deliveries;
       Alcotest.(check bool)
         "cancelled wake stays absent after restart"
         true
         (Option.is_none
            (durable_resolution_opt
               ~base_path
               ~keeper_name
               ~approval_id:id));
       match AQ.approved_resolution_state ~base_path ~id with
       | Ok AQ.Resolution_unconsumed -> ()
       | Ok AQ.Resolution_consumed ->
         Alcotest.fail "wake cancellation consumed the exact grant"
       | Error error ->
         Alcotest.fail (AQ.grant_error_to_string error))
;;

let test_one_delivery_replay_failure_does_not_stop_others () =
  let base_path = temp_dir () in
  let keeper_name = "queue-independent-replay" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let first_id, second_id, successful_id =
         List.init 3 (fun index ->
           submit ~base_path ~keeper_name ~input:(`Assoc [ "target", `Int index ]))
         |> List.sort (fun left right -> String.compare right left)
         |> function
         | [ first; second; third ] -> first, second, third
         | _ -> Alcotest.fail "three approvals expected"
       in
       let pending_entries =
         let open Yojson.Safe.Util in
         read_pending_snapshot ~base_path |> member "pending" |> to_list
       in
       let entry_for id =
         let open Yojson.Safe.Util in
         match
           List.find_opt
             (fun json -> String.equal (json |> member "id" |> to_string) id)
             pending_entries
         with
         | Some entry -> entry
         | None -> Alcotest.fail ("missing persisted entry " ^ id)
       in
       let entry_at sequence id =
         match entry_for id with
         | `Assoc fields ->
           `Assoc (("sequence", `Int sequence) :: List.remove_assoc "sequence" fields)
         | _ -> Alcotest.fail "persisted entry object expected"
       in
       write_pending_snapshot
         ~base_path
         (`Assoc
             [ "version", `Int 9
            ; "next_sequence", `Int 4
            ; "pending", `List []
            ; ( "deliveries"
              , `List
                  [ delivery_json
                      ~entry:(entry_at 1 first_id)
                      ~remember_rule:true
                  ; delivery_json
                      ~entry:(entry_at 2 second_id)
                      ~remember_rule:true
                  ; delivery_json
                      ~entry:(entry_at 3 successful_id)
                      ~remember_rule:false
                  ] )
            ]);
       let rules_path = AQ.For_testing.always_allowed_store_path ~base_path in
       ensure_dir (Filename.dirname rules_path);
       Unix.mkdir rules_path 0o755;
       AQ.For_testing.reset_runtime_state ();
       let report = install_exn ~base_path in
       Alcotest.(check int) "independent delivery replayed" 1 report.replayed_deliveries;
       Alcotest.(check int)
         "two replay failures reported"
         2
         (List.length report.delivery_replay_failures);
       Alcotest.(check (list string))
         "replay failures preserve durable sequence"
         [ first_id; second_id ]
         (List.map (fun failure -> failure.AQ.approval_id) report.delivery_replay_failures);
       Alcotest.(check bool) "later delivery reached origin" true
         (Option.is_some
            (durable_resolution_opt
               ~base_path
               ~keeper_name
               ~approval_id:successful_id));
       List.iter
         (fun approval_id ->
            match durable_resolution_opt ~base_path ~keeper_name ~approval_id with
            | Some resolution -> drop_resolution ~base_path ~keeper_name resolution
            | None -> ())
         [ first_id; second_id; successful_id ])
;;

let test_submit_surfaces_storage_failure () =
  let base_path = Filename.temp_file "queue-storage-error" "" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      try Sys.remove base_path with
      | Sys_error _ -> ())
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       match
         AQ.submit_pending
           ~keeper_name:"queue-storage-error"
           ~tool_name:"external-effect"
           ~input:(`Assoc [ "target", `String "x" ])
           ~base_path
           ()
       with
       | Ok _ -> Alcotest.fail "submission must not succeed without durable storage"
       | Error _ ->
         (match AQ.list_pending_entries_for_workspace ~base_path with
          | Ok entries ->
            Alcotest.(check int) "memory not mutated" 0 (List.length entries)
          | Error error ->
            Alcotest.fail (AQ.storage_error_to_string error)))
;;

let test_default_auto_judge_defers_without_blocking () =
  let base_path = temp_dir () in
  let keeper_name = "queue-default-auto-judge" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       ignore (install_exn ~base_path);
       let request : Gate.request =
         { keeper_name
         ; operation = "external-effect"
         ; input = `Assoc [ "target", `String "auto-judge" ]
         ; base_path
         ; sandbox_profile = None
         ; causal_context =
             Some { Gate.turn_id = Some 9; snapshot = `Assoc [] }
         ; task_id = Some "task-auto-judge"
         ; continuation_channel = None
         }
       in
       match Gate.decide ~keeper_always_allow:false request with
       | Gate.Deferred
           { approval_id; reason = Gate.Auto_judge_unavailable detail; _ } ->
         Alcotest.(check bool) "unavailable reason is explicit" true
           (String.length detail > 0);
         (match AQ.For_testing.get_pending_entry_unchecked ~id:approval_id with
          | Some
              { summary_status = Rule_types.Summary_pending
              ; exact_attempt = Rule_types.Exact_unbound
              ; summary_attempt_disposition =
                  Rule_types.Summary_attempt_pre_worker_unavailable
                    { reason_code =
                        Rule_types.Summary_pre_worker_auto_judge_unavailable
                    ; operator_detail
                    }
              ; _
              } when String.equal operator_detail detail ->
            let blocked =
              match AQ.For_testing.get_pending_entry_unchecked ~id:approval_id with
              | Some entry -> entry
              | None -> Alcotest.fail "durable blocked row disappeared"
            in
            check_rearm
              "explicit operator retry reserves pre-worker start"
              true
              (reserve_retry_exact ~base_path blocked)
          | Some _ ->
            Alcotest.fail "Auto Judge pre-worker failure lost its durable reason"
          | None -> Alcotest.fail "Auto Judge request was not durably queued");
         reject_and_cleanup ~base_path approval_id
       | Gate.Deferred { reason = Gate.Judge_requested; _ } ->
         Alcotest.fail "test unexpectedly has a running server Auto Judge context"
       | Gate.Deferred { reason = (Gate.Human_requested | Gate.Mode_state_invalid _); _ } ->
         Alcotest.fail "default Gate mode did not select Auto Judge"
       | Gate.Allow _ -> Alcotest.fail "default Auto Judge allowed without a verdict"
       | Gate.Unavailable reason ->
         Alcotest.fail (Gate.unavailable_reason_to_string reason))
;;

let test_unavailable_cycle_grant_never_falls_through () =
  let base_path = temp_dir () in
  let keeper_name = "queue-stale-grant" in
  let input = `Assoc [ "target", `String "exact" ] in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let approval_id = submit ~base_path ~keeper_name ~input in
       (match aq_resolve ~base_path ~id:approval_id ~decision:Rule_types.Decision.Approve with
        | Ok () -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       let resolution =
         durable_resolution_opt ~base_path ~keeper_name ~approval_id
         |> require_some "approved resolution was not delivered"
       in
       let grant =
         Gate.cycle_grant_of_resolution resolution
         |> require_some "approved resolution lacked grant"
       in
       let request : Gate.request =
         { keeper_name
         ; operation = "external-effect"
         ; input
         ; base_path
         ; sandbox_profile = None
         ; causal_context = None
         ; task_id = None
         ; continuation_channel = None
         }
       in
       AQ.For_testing.reset_runtime_state ();
       (match Gate.decide ~cycle_grant:grant ~keeper_always_allow:true request with
        | Gate.Unavailable (Gate.Approval_grant_unavailable _) -> ()
        | Gate.Allow _ ->
          Alcotest.fail "unconsumed grant failure fell through to Always Allow"
        | Gate.Deferred _ ->
          Alcotest.fail "unconsumed grant failure created a second approval"
        | Gate.Unavailable _ ->
          Alcotest.fail "unexpected unavailable reason for unreadable grant");
       ignore (install_exn ~base_path);
       (match Gate.decide ~cycle_grant:grant ~keeper_always_allow:false request with
        | Gate.Allow { source = Gate.One_shot_resolution actual; _ } ->
          Alcotest.(check string) "grant remains unconsumed" approval_id actual
        | Gate.Allow _ -> Alcotest.fail "restored exact grant used the wrong source"
        | Gate.Deferred _ -> Alcotest.fail "restored exact grant did not authorize"
        | Gate.Unavailable reason ->
          Alcotest.fail (Gate.unavailable_reason_to_string reason));
       drop_resolution ~base_path ~keeper_name resolution)
;;

let test_nonapproved_resolution_payload_is_delivered () =
  let base_path = temp_dir () in
  let keeper_name = "queue-resolution-payload" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let reject_id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "target", `String "reject" ])
       in
       let rationale = "Use the project-scoped target." in
       (match
          aq_resolve
            ~base_path
            ~id:reject_id
            ~decision:(Rule_types.Decision.Reject rationale)
        with
        | Ok () -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       let rejected =
         durable_resolution_opt
           ~base_path
           ~keeper_name
           ~approval_id:reject_id
         |> require_some "rejection resolution was not delivered"
       in
       (match rejected.decision with
        | Keeper_event_queue.Hitl_rejected actual ->
          Alcotest.(check string) "rejection rationale" rationale actual
        | _ -> Alcotest.fail "rejection resolution lost its typed decision");
       Alcotest.(check bool)
         "rejection is not a grant"
         true
         (Option.is_none (Gate.cycle_grant_of_resolution rejected));
       (match Chat_store.load_all ~base_dir:base_path ~keeper_name with
        | [ { role = Chat_store.Role.System
            ; approval_lifecycle = Some requested
            ; _
            }
          ; { role = Chat_store.Role.System
            ; approval_lifecycle = Some lifecycle
            ; _
            } ] ->
          Alcotest.(check bool) "the parked call was recorded first" true
            (requested.phase = Chat_store.Approval_requested);
          Alcotest.(check bool) "rejection status is durable" true
            (lifecycle.phase = Chat_store.Approval_resolved_rejected)
        | rows ->
          Alcotest.failf
            "expected a request row and a rejection status row, got %d"
            (List.length rows));
       drop_resolution ~base_path ~keeper_name rejected)
;;

let test_canonical_replay_repairs_stale_chat_receipt_once () =
  let base_path = temp_dir () in
  let keeper_name = "queue-replay-chat-correction" in
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let input = `Assoc [ "target", `String "replay-correction" ] in
       let approval_id = submit ~base_path ~keeper_name ~input in
       (match
          aq_resolve
            ~base_path
            ~id:approval_id
            ~decision:Rule_types.Decision.Approve
        with
        | Ok () -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       (match
          AQ.consume_approved_resolution
            ~base_path
            ~id:approval_id
            ~keeper_name
            ~tool_name:"external-effect"
            ~input
        with
        | Ok (AQ.Consumption_committed _) -> ()
        | Ok (AQ.Consumption_already_committed | AQ.Consumption_not_matching) ->
          Alcotest.fail "fixture approval grant was not consumed"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       let stale_ref = store_replay_artifact ~base_path "stale failed replay" in
       let canonical_ref = store_replay_artifact ~base_path "canonical applied replay" in
       let stale_lifecycle : Chat_store.approval_lifecycle =
         { approval_id
         ; tool_name = Some "external-effect"
         ; phase = Chat_store.Approval_replay_failed
         ; artifact_ref = Some stale_ref
         ; call_summary = None
         }
       in
       (match
          Chat_store.append_approval_lifecycle_once
            ~base_dir:base_path
            ~keeper_name
            ~lifecycle:stale_lifecycle
        with
        | Ok (Chat_store.Appended _) -> ()
        | Ok (Chat_store.Already_present _) | Error _ ->
          Alcotest.fail "stale replay chat fixture was not appended");
       (match
          AQ.record_consumed_resolution_replay
            ~base_path
            ~id:approval_id
            ~outcome:(AQ.Replay_applied canonical_ref)
        with
        | Ok AQ.Replay_recorded -> ()
        | Ok AQ.Replay_already_recorded | Error _ ->
          Alcotest.fail "canonical replay outcome was not recorded");
       let canonical_outcome =
         match AQ.approved_resolution_delivery ~base_path ~id:approval_id with
         | Ok { replay_outcome = Some outcome; _ } -> outcome
         | Ok _ -> Alcotest.fail "canonical replay outcome is absent"
         | Error error -> Alcotest.fail (AQ.grant_error_to_string error)
       in
       (match
          AQ.ensure_replay_chat_projection
            ~base_path
            ~keeper_name
            ~approval_id
            ~tool_name:(Some "external-effect")
            ~call_summary:None
            ~outcome:canonical_outcome
        with
        | Ok () -> ()
        | Error detail -> Alcotest.fail detail);
       (match
          AQ.ensure_replay_chat_projection
            ~base_path
            ~keeper_name
            ~approval_id
            ~tool_name:(Some "external-effect")
            ~call_summary:None
            ~outcome:canonical_outcome
        with
        | Ok () -> ()
        | Error detail -> Alcotest.fail detail);
       (match
          AQ.ensure_replay_chat_projection
            ~base_path
            ~keeper_name
            ~approval_id
            ~tool_name:(Some "external-effect")
            ~call_summary:None
            ~outcome:(AQ.Replay_failed stale_ref)
        with
        | Error _ -> ()
        | Ok () -> Alcotest.fail "stale replay displaced the correction");
       let lifecycle_rows =
         Chat_store.load_all ~base_dir:base_path ~keeper_name
         |> List.filter (fun (message : Chat_store.chat_message) ->
           match message.approval_lifecycle with
           | Some lifecycle -> String.equal lifecycle.approval_id approval_id
           | None -> false)
       in
       Alcotest.(check int) "request, resolution, stale replay, correction" 4
         (List.length lifecycle_rows);
       let phases =
         List.filter_map
           (fun (message : Chat_store.chat_message) ->
              Option.map
                (fun lifecycle -> lifecycle.Chat_store.phase)
                message.approval_lifecycle)
           lifecycle_rows
       in
       match phases with
       | [ Chat_store.Approval_requested
         ; Chat_store.Approval_resolved_approved
         ; Chat_store.Approval_replay_failed
         ; Chat_store.Approval_replay_applied
         ] -> ()
       | _ -> Alcotest.fail "canonical correction history is incomplete")
;;

let test_audit_store_failure_keeps_defer_committed_and_visible () =
  let base_path = temp_dir () in
  let keeper_name = "queue-audit-store-failure" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_approval.Audit.For_testing.reset_store ();
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       Keeper_approval.Audit.For_testing.reset_store ();
       ignore (install_exn ~base_path);
       Keeper_approval.Audit.For_testing.set_store_create_probe
         (fun ~base_path:_ ->
           failwith
             "deterministic audit store failure /private/operator/.ssh/id_ed25519");
       let request : Gate.request =
         { keeper_name
         ; operation = "external-effect"
         ; input = `Assoc [ "target", `String "store-create" ]
         ; base_path
         ; sandbox_profile = None
         ; causal_context = None
         ; task_id = None
         ; continuation_channel = None
         }
       in
       match Gate.decide ~keeper_always_allow:false request with
       | Gate.Deferred { approval_id; audit_receipts = [ receipt ]; _ } ->
         check_failed_audit_receipt
           ~event_type:Keeper_approval.Audit.Pending
           ~stage:Keeper_approval.Audit.Store_create
           receipt;
         (match receipt.write_result with
          | Ok () -> Alcotest.fail "audit failure was reported as recorded"
          | Error failure ->
            Alcotest.(check bool)
              "audit receipt omits exception paths"
              false
              (String.contains failure.detail '/'));
         (match AQ.For_testing.get_pending_entry_unchecked ~id:approval_id with
          | Some _ -> ()
          | None ->
            Alcotest.fail
              "audit store failure rolled back the durable pending mutation")
       | Gate.Deferred _ -> Alcotest.fail "defer returned a non-canonical audit receipt set"
       | Gate.Allow _ -> Alcotest.fail "unapproved request bypassed Gate"
       | Gate.Unavailable reason ->
         Alcotest.fail (Gate.unavailable_reason_to_string reason))
;;

let test_audit_cleanup_failure_preserves_recorded_receipt () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_approval.Audit.For_testing.reset_store ();
      cleanup_dir base_path)
    (fun () ->
       Keeper_approval.Audit.For_testing.reset_store ();
       Keeper_approval.Audit.For_testing.set_append_jsonl_cleanup_failure
         "deterministic descriptor close failure";
       let receipt =
         Keeper_approval.Audit.record
           ~base_path
           ~event_type:Keeper_approval.Audit.Pending
           ~id:"cleanup-settlement"
           ~keeper_name:"queue-audit-cleanup-failure"
           ~tool_name:"external-effect"
           ()
       in
       (match receipt.write_result with
        | Ok () -> ()
        | Error _ ->
          Alcotest.fail
            "durably recorded append was collapsed into a failed receipt");
       (match receipt.cleanup_failure with
        | None -> Alcotest.fail "descriptor cleanup failure was hidden"
        | Some failure ->
          Alcotest.(check bool)
            "cleanup stage is exact"
            true
            (failure.stage = Keeper_approval.Audit.Append_cleanup));
       let open Yojson.Safe.Util in
       let wire = Keeper_approval.Audit.receipt_to_yojson receipt in
       Alcotest.(check bool)
         "wire keeps durable append recorded"
         true
         (wire |> member "recorded" |> to_bool);
       Alcotest.(check string)
         "cleanup warning stays typed"
         "append_cleanup"
         (wire |> member "cleanup_failure" |> member "stage" |> to_string))
;;

let test_audit_append_failure_keeps_resolution_rule_and_grant_committed () =
  let base_path = temp_dir () in
  let keeper_name = "queue-audit-append-failure" in
  let input = `Assoc [ "target", `String "append" ] in
  Fun.protect
    ~finally:(fun () ->
      Keeper_approval.Audit.For_testing.reset_store ();
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       Keeper_approval.Audit.For_testing.reset_store ();
       ignore (install_exn ~base_path);
       let approval_id = submit ~base_path ~keeper_name ~input in
       Keeper_approval.Audit.For_testing.set_append_jsonl
         (fun _path _json ->
            failwith "deterministic approval audit append failure");
       let resolution =
         match
           AQ.resolve_with_policy
             ~base_path
             ~id:approval_id
             ~decision:Rule_types.Decision.Approve
             ~remember_rule:true
             ~created_by:"test-operator"
             ()
         with
         | Ok result -> result
         | Error error -> Alcotest.fail (AQ.resolve_error_to_string error)
       in
       (match resolution.audit_receipts with
        | [ rule_receipt; resolved_receipt ] ->
          check_append_failure Keeper_approval.Audit.Rule_created rule_receipt;
          check_append_failure Keeper_approval.Audit.Resolved resolved_receipt
        | _ -> Alcotest.fail "resolution did not return both mutation receipts");
       (match
          Rules.find_matching_rule
            ~base_path
            ~keeper_name
            ~tool_name:"external-effect"
            ~input
            ()
        with
        | Ok (Rule_types.Rule_match_active _) -> ()
        | Ok (Rule_types.Rule_match_expired _ | Rule_types.Rule_match_absent) ->
          Alcotest.fail "audit append failure rolled back the remembered rule"
        | Error error -> Alcotest.fail (Rule_types.rule_store_error_to_string error));
       Alcotest.(check int)
         "resolved request left pending queue"
         0
         (match AQ.list_pending_entries_for_workspace ~base_path with
          | Ok entries -> List.length entries
          | Error error -> Alcotest.fail (AQ.storage_error_to_string error));
       let durable_resolution =
         durable_resolution_opt ~base_path ~keeper_name ~approval_id
         |> require_some "approved resolution was not delivered"
       in
       let cycle_grant =
         Gate.cycle_grant_of_resolution durable_resolution
         |> require_some "approved resolution lacked its one-shot grant"
       in
       let request : Gate.request =
         { keeper_name
         ; operation = "external-effect"
         ; input
         ; base_path
         ; sandbox_profile = None
         ; causal_context = None
         ; task_id = None
         ; continuation_channel = None
         }
       in
       let audit_frames = ref [] in
       let subscriber_id = "approval-audit-append-failure" in
       Masc.Sse.subscribe_external
         ~id:subscriber_id
         ~callback:(fun (event : Masc.Sse.external_event) ->
           audit_frames := event.Masc.Sse.ext_frame :: !audit_frames)
         ();
       Fun.protect
         ~finally:(fun () -> Masc.Sse.unsubscribe_external subscriber_id)
         (fun () ->
            (match Gate.decide ~cycle_grant ~keeper_always_allow:false request with
             | Gate.Allow
                 { source = Gate.One_shot_resolution actual
                 ; audit_receipts = [ consumed_receipt; allowed_receipt ]
                 } ->
               Alcotest.(check string) "exact grant id" approval_id actual;
               check_append_failure
                 Keeper_approval.Audit.Grant_consumed
                 consumed_receipt;
               check_append_failure
                 Keeper_approval.Audit.Gate_allowed
                 allowed_receipt
             | Gate.Allow _ ->
               Alcotest.fail "one-shot authorization receipts were incomplete"
             | Gate.Deferred _ -> Alcotest.fail "committed grant did not authorize"
             | Gate.Unavailable reason ->
               Alcotest.fail (Gate.unavailable_reason_to_string reason));
            let audit_events =
              !audit_frames
              |> List.rev
              |> List.filter_map (fun frame ->
                match Masc.Sse.data_payload_of_frame frame with
                | Error Masc.Sse.Missing_data_payload -> None
                | Ok payload ->
                  let json = Yojson.Safe.from_string payload in
                  let open Yojson.Safe.Util in
                  if json |> member "type" |> to_string_option = Some "approval:audit"
                  then Some json
                  else None)
            in
            Alcotest.(check int)
              "failed authorization audits are projected"
              2
              (List.length audit_events);
            let open Yojson.Safe.Util in
            Alcotest.(check (list string))
              "authorization audit event order"
              [ "grant_consumed"; "gate_allowed" ]
              (List.map
                 (fun event -> event |> member "payload" |> member "audit" |> member "event" |> to_string)
                 audit_events);
            List.iter
              (fun event ->
                 let payload = event |> member "payload" in
                 Alcotest.(check string)
                   "authorization audit subject"
                   approval_id
                   (payload |> member "id" |> to_string);
                 Alcotest.(check bool)
                   "authorization audit reports append failure"
                   false
                   (payload |> member "audit" |> member "recorded" |> to_bool))
              audit_events);
       (match
          AQ.consume_approved_resolution
            ~base_path
            ~id:approval_id
            ~keeper_name
            ~tool_name:"external-effect"
            ~input
        with
        | Ok AQ.Consumption_already_committed -> ()
        | Ok (AQ.Consumption_committed _ | AQ.Consumption_not_matching) ->
          Alcotest.fail "consumed grant became authorizable again"
        | Error error -> Alcotest.fail (AQ.grant_error_to_string error));
       drop_resolution ~base_path ~keeper_name durable_resolution)
;;

let test_cancelled_audit_observation_preserves_committed_allow () =
  let base_path = temp_dir () in
  let keeper_name = "queue-audit-cancelled-observer" in
  let subscriber_id = "approval-audit-cancelled-observer" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Sse.unsubscribe_external subscriber_id;
      Keeper_approval.Audit.For_testing.reset_store ();
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       Keeper_approval.Audit.For_testing.reset_store ();
       ignore (install_exn ~base_path);
       Keeper_approval.Audit.For_testing.set_append_jsonl
         (fun _path _json -> failwith "deterministic audit append failure");
       Masc.Sse.subscribe_external
         ~id:subscriber_id
         ~callback:(fun _ ->
           raise
             (Eio.Cancel.Cancelled
                (Failure "cancelled approval audit observation")))
         ();
       let request : Gate.request =
         { keeper_name
         ; operation = "external-effect"
         ; input = `Assoc [ "target", `String "cancelled-observer" ]
         ; base_path
         ; sandbox_profile = None
         ; causal_context = None
         ; task_id = None
         ; continuation_channel = None
         }
       in
       let authorization =
         match Gate.decide ~keeper_always_allow:true request with
         | Gate.Allow authorization -> authorization
         | Gate.Deferred _ -> Alcotest.fail "Always Allow unexpectedly deferred"
         | Gate.Unavailable reason ->
           Alcotest.fail (Gate.unavailable_reason_to_string reason)
       in
       (match authorization.audit_receipts with
        | [ receipt ] -> check_append_failure Keeper_approval.Audit.Gate_allowed receipt
        | _ -> Alcotest.fail "Always Allow did not retain its exact audit receipt");
       let execution =
         Masc.Keeper_tool_execution.failure "effect failed after authorization"
         |> Masc.Keeper_tool_execution.with_gate_authorization authorization
       in
       let metadata =
         execution.metadata
         |> require_some "failed tool execution discarded Gate authorization metadata"
       in
       let open Yojson.Safe.Util in
       Alcotest.(check string)
         "failed tool result keeps the committed Gate decision"
         "allow"
         (metadata |> member "gate" |> member "decision" |> to_string);
       Alcotest.(check int)
         "failed tool result keeps the audit receipt"
         1
         (metadata |> member "gate" |> member "audit_receipts" |> to_list |> List.length))
;;

let test_audit_lock_wait_cancellation_remains_cancellation () =
  let base_path = temp_dir () in
  let owner_entered = Atomic.make false in
  let release_owner = Atomic.make false in
  let holder =
    Domain.spawn (fun () ->
      Keeper_approval.Audit.For_testing.with_audit_io_lock (fun () ->
        Atomic.set owner_entered true;
        while not (Atomic.get release_owner) do
          Domain.cpu_relax ()
        done))
  in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set release_owner true;
      Domain.join holder;
      Keeper_approval.Audit.For_testing.reset_store ();
      cleanup_dir base_path)
    (fun () ->
       while not (Atomic.get owner_entered) do
         Domain.cpu_relax ()
       done;
       Eio_main.run @@ fun _environment ->
       Eio.Switch.run @@ fun sw ->
       let cancel_context, resolve_cancel_context = Eio.Promise.create () in
       let result, resolve_result = Eio.Promise.create () in
       Eio.Fiber.fork ~sw (fun () ->
         let outcome =
           try
             Eio.Cancel.sub (fun cancellation ->
               Eio.Promise.resolve resolve_cancel_context cancellation;
               `Receipt
                 (Keeper_approval.Audit.record
                    ~base_path
                    ~event_type:Keeper_approval.Audit.Gate_allowed
                    ~id:"audit-lock-cancellation"
                    ~keeper_name:"queue-audit-lock-cancellation"
                    ~tool_name:"external-effect"
                    ()))
           with
           | Eio.Cancel.Cancelled _ -> `Cancellation_escaped
         in
         Eio.Promise.resolve resolve_result outcome);
       let cancellation = Eio.Promise.await cancel_context in
       Eio.Cancel.cancel cancellation (Failure "cancel audit lock waiter");
       match Eio.Promise.await result with
       | `Receipt _ ->
         Alcotest.fail "audit lock cancellation was relabelled as a write failure"
       | `Cancellation_escaped -> ())
;;

let test_http_success_exposes_failed_resolution_and_rule_delete_audit () =
  let base_path = temp_dir () in
  let keeper_name = "queue-audit-http-failure" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_approval.Audit.For_testing.reset_store ();
      AQ.For_testing.reset_runtime_state ();
      cleanup_dir base_path)
    (fun () ->
       AQ.For_testing.reset_runtime_state ();
       Keeper_approval.Audit.For_testing.reset_store ();
       ignore (install_exn ~base_path);
       let approval_id =
         submit
           ~base_path
           ~keeper_name
           ~input:(`Assoc [ "target", `String "http" ])
       in
       Keeper_approval.Audit.For_testing.set_append_jsonl
         (fun _path _json -> failwith "deterministic HTTP audit append failure");
       let response =
         match
           Server_dashboard_http.dashboard_gate_resolve_http_json
             ~base_path
             ~created_by:"http-test-operator"
             ~args:
               (`Assoc
                  [ "id", `String approval_id
                  ; "decision", `String "approve"
                  ; "remember_rule", `Bool true
                  ])
         with
         | Ok json -> json
         | Error error ->
           Alcotest.fail
             (Server_dashboard_http.approval_resolve_http_error_to_string error)
       in
       let open Yojson.Safe.Util in
       Alcotest.(check bool) "HTTP mutation stayed successful" true
         (response |> member "ok" |> to_bool);
       let rule_id = response |> member "rule_id" |> to_string in
       let receipts = response |> member "audit_receipts" |> to_list in
       Alcotest.(check int) "HTTP exposes rule and resolution receipts" 2
         (List.length receipts);
       List.iter
         (fun receipt ->
            Alcotest.(check bool) "HTTP receipt reports missing audit" false
              (receipt |> member "recorded" |> to_bool);
            Alcotest.(check string) "HTTP receipt carries exact append stage" "append"
              (receipt |> member "stage" |> to_string))
         receipts;
       let delete_response =
         match
           Server_dashboard_http.dashboard_gate_rule_delete_http_json
             ~base_path
             ~args:(`Assoc [ "id", `String rule_id ])
         with
         | Ok json -> json
         | Error error -> Alcotest.fail error
       in
       Alcotest.(check bool) "HTTP rule delete stayed successful" true
         (delete_response |> member "ok" |> to_bool);
       let delete_receipt = delete_response |> member "audit" in
       Alcotest.(check yojson) "delete receipt event"
         (`String "rule_deleted")
         (delete_receipt |> member "event");
       Alcotest.(check bool) "delete receipt reports missing audit" false
         (delete_receipt |> member "recorded" |> to_bool);
       Alcotest.(check string) "delete receipt carries exact append stage" "append"
         (delete_receipt |> member "stage" |> to_string))
;;

(* #26126: resolution writes the judge evidence the entry carried onto the
   resolved audit event, so the decision remains explainable after the entry
   leaves the pending queue. *)
let test_resolved_audit_event_carries_judge_evidence () =
  let base_path = temp_dir () in
  let keeper_name = "queue-judge-evidence" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_approval.Audit.For_testing.reset_store ();
      cleanup_dir base_path)
    (fun () ->
       ignore (install_exn ~base_path);
       let id =
         submit ~base_path ~keeper_name ~input:(`Assoc [ "target", `String "doc" ])
       in
       (match aq_resolve ~base_path ~id ~decision:Rule_types.Decision.Approve with
        | Ok () -> ()
        | Error error -> Alcotest.fail (AQ.resolve_error_to_string error));
       let history =
         Keeper_approval.Audit.list_recent_resolved
           ~base_path
           ~now_ts:(Unix.gettimeofday ())
           ~window_minutes:60
           ()
         |> resolved_history_exn
       in
       let open Yojson.Safe.Util in
       let row =
         List.find_opt
           (fun row -> String.equal (row |> member "id" |> to_string) id)
           history.resolved_rows
       in
       match row with
       | None -> Alcotest.fail "resolved decision missing from history"
       | Some row ->
         Alcotest.check yojson
           "summary_status recorded at resolution"
           (`String "not_requested")
           (row |> member "summary_status");
         Alcotest.check yojson
           "exact_attempt recorded at resolution"
           (Rule_types.exact_attempt_state_to_yojson Rule_types.Exact_unbound)
           (row |> member "exact_attempt"))
;;

(* The summary is derived from the persisted input. Every shape the fleet
   sends has to land on one line or in [None] -- never in a guess -- and the
   cap may not split a multibyte char. *)
let test_call_summary_of_input () =
  let check_summary label expected input =
    Alcotest.(check (option string)) label expected (AQ.call_summary_of_input input)
  in
  let argv text =
    `Assoc [ "input", `Assoc [ "argv", `List [ `String "bash"; `String "-lc"; `String text ] ] ]
  in
  check_summary "argv is joined onto one line"
    (Some "bash -lc cd repos/masc && git log --oneline -8 -- test/dune")
    (argv "cd repos/masc && git log --oneline -8 -- test/dune");
  check_summary "a newline ends the summary" (Some "first line")
    (argv "first line\nsecond line");
  check_summary "an identity call names its provider surface"
    (Some "github/issue_write")
    (`Assoc [ "provider_id", `String "github"; "remote_name", `String "issue_write" ]);
  check_summary "an ascii cap cuts at the budget"
    (Some ("bash -lc " ^ String.make 71 'a'))
    (argv (String.make 120 'a'));
  (* The join starts with "bash -lc " (9 bytes), so the budget lands inside the
     24th Korean char: the boundary backs up to 78 bytes, whole chars only. *)
  check_summary "the cap does not split a multibyte char"
    (Some ("bash -lc " ^ String.concat "" (List.init 23 (fun _ -> "가"))))
    (argv (String.concat "" (List.init 40 (fun _ -> "가"))));
  check_summary "a blank argv is no summary" None (argv "   ");
  check_summary "a non-string argv is no summary" None
    (`Assoc [ "input", `Assoc [ "argv", `List [ `Int 1 ] ] ]);
  check_summary "an input naming neither argv nor a provider is no summary" None
    (`Assoc [ "input", `Assoc [ "cwd", `String "/tmp" ] ]);
  check_summary "a non-object input is no summary" None (`String "tool_execute");
  check_summary "top-level argv is extracted"
    (Some "git status")
    (`Assoc [ "argv", `List [ `String "git"; `String "status" ] ]);
  check_summary "top-level script is extracted"
    (Some "dune build")
    (`Assoc [ "script", `String "dune build" ]);
  check_summary "top-level command is extracted"
    (Some "echo hello")
    (`Assoc [ "command", `String "echo hello" ]);
  check_summary "nested args with script is extracted"
    (Some "pytest -v")
    (`Assoc [ "args", `Assoc [ "script", `String "pytest -v" ] ]);
  check_summary "top-level file_path is extracted"
    (Some "lib/keeper.ml")
    (`Assoc [ "file_path", `String "lib/keeper.ml" ]);
  check_summary "null argv falls through to script"
    (Some "npm test")
    (`Assoc [ "argv", `Null; "script", `String "npm test" ]);
  check_summary "null script falls through to command"
    (Some "make check")
    (`Assoc [ "script", `Null; "command", `String "make check" ]);
  check_summary "leading blank lines in script are skipped to first non-empty line"
    (Some "pytest -v")
    (`Assoc [ "script", `String "\n\n  pytest -v\n" ]);
  check_summary "production gate request envelope extracts script"
    (Some "python -m unittest")
    (`Assoc
       [ "schema", `String "masc.keeper_gate.request.v1"
       ; "input", `Assoc [ "script", `String "python -m unittest"; "cwd", `String "." ]
       ; "cwd", `String "."
       ]);
  check_summary "nested arguments with query is extracted"
    (Some "masc architecture")
    (`Assoc [ "arguments", `Assoc [ "query", `String "masc architecture" ] ]);
  check_summary "excessive recursion depth returns None safely"
    None
    (`Assoc
       [ "input"
       , `Assoc
           [ "args"
           , `Assoc
               [ "arguments"
               , `Assoc
                   [ "input"
                   , `Assoc
                       [ "args"
                       , `Assoc [ "script", `String "too deep" ] ] ] ] ] ])
;;

let () =
  Alcotest.run
    "Keeper_approval_queue"
    [ ( "call summary"
      , [ Alcotest.test_case "of input" `Quick test_call_summary_of_input ] )
    ; ( "nonhierarchical queue"
      , [ Alcotest.test_case
            "durable lock serializes Eio fibers"
            `Quick
            test_pending_store_lock_serializes_eio_fibers
        ; Alcotest.test_case
            "install serializes snapshot read with mutation"
            `Quick
            test_install_serializes_snapshot_read_with_same_base_mutation
        ; Alcotest.test_case
            "submit is nonblocking and exact"
            `Quick
            test_submit_is_nonblocking_and_exactly_deduplicated
        ; Alcotest.test_case
            "durable sequence survives restart"
            `Quick
            test_monotonic_sequence_survives_restart
        ; Alcotest.test_case
            "same owner drains by durable sequence"
            `Quick
            test_same_owner_drain_uses_sequence_not_wall_clock
        ; Alcotest.test_case
            "multiple resolution projections keep FIFO order"
            `Quick
            test_multiple_resolution_projections_keep_fifo_order
        ; Alcotest.test_case
            "world observation reconciles resolved approval out of pending"
            `Quick
            test_world_observation_reconciles_resolved_approval_out_of_pending
        ; Alcotest.test_case
            "terminal head does not stall the owner queue"
            `Quick
            test_terminal_head_does_not_stall_owner_queue
        ; Alcotest.test_case
            "workspace drain isolates owner failures"
            `Quick
            test_workspace_drain_isolates_owner_failures
        ; Alcotest.test_case
            "each owner activates bounded parallel workers"
            `Quick
            test_each_owner_claims_bounded_parallel_workers
        ; Alcotest.test_case
            "dedup keeps distinct origins"
            `Quick
            test_dedup_never_merges_distinct_origins
        ; Alcotest.test_case
            "retry folds onto unconsumed grant until consumed"
            `Quick
            test_retry_folds_onto_unconsumed_grant_until_consumed
        ; Alcotest.test_case
            "resolution wakes only origin"
            `Quick
            test_resolution_is_durable_and_origin_scoped
        ; Alcotest.test_case
            "resolved audit event carries judge evidence"
            `Quick
            test_resolved_audit_event_carries_judge_evidence
        ; Alcotest.test_case
            "remembered rule carries requested expiry"
            `Quick
            test_remembered_rule_carries_requested_expiry
        ; Alcotest.test_case
            "cycle grant binds origin and is consumed once"
            `Quick
            test_cycle_grant_uses_exact_effect_and_is_consumed_once
        ; Alcotest.test_case
            "pre-effect replay failure retires grant and continues"
            `Quick
            test_pre_effect_replay_failure_retires_grant_and_unblocks_continuation
        ; Alcotest.test_case
            "canonical replay repairs stale chat receipt once"
            `Quick
            test_canonical_replay_repairs_stale_chat_receipt_once
        ; Alcotest.test_case
            "exact binding codec validates identity and current causes"
            `Quick
            test_exact_binding_codec_validates_entry_identity
        ; Alcotest.test_case
            "exact binding release and conflicts"
            `Quick
            test_exact_attempt_binding_release_and_conflicts
        ; Alcotest.test_case
            "restart classifies uncertain and released states stably"
            `Quick
            test_restart_classifies_uncertain_and_released_recovery
        ; Alcotest.test_case
            "exact completion is atomic"
            `Quick
            test_exact_attempt_completion_is_atomic
          ; Alcotest.test_case
              "exact bind storage failure is not success"
              `Quick
              test_exact_attempt_bind_storage_failure_is_not_success
          ; Alcotest.test_case
              "exact staged durability converges and rewrites"
              `Quick
              test_exact_attempt_staged_durability_and_idempotent_rewrite
        ; Alcotest.test_case
            "dashboard resolve rejects cross-workspace approval"
            `Quick
            test_dashboard_resolve_rejects_cross_workspace_approval
        ; Alcotest.test_case
            "operator recovery skips terminal exact failures"
            `Quick
            test_operator_recovery_skips_terminal_exact_failure
        ; Alcotest.test_case
            "summary owner retirement is atomic and owner scoped"
            `Quick
            test_summary_owner_retirement_is_atomic_and_owner_scoped
        ; Alcotest.test_case
              "exact restart finalization requires fsync"
              `Quick
              test_exact_completed_restart_requires_fsync_confirmation
        ; Alcotest.test_case
            "override-only auto_judge owner is recovered"
            `Quick
            test_override_only_auto_judge_owner_is_recovered
        ; Alcotest.test_case
            "operator recovery admits an override-only workspace"
            `Quick
            test_operator_recovery_admits_override_only_workspace
        ; Alcotest.test_case
            "current snapshot rejects unbound available summary"
            `Quick
            test_current_snapshot_rejects_unbound_available_summary
        ; Alcotest.test_case
            "blocked disposition requires operator rearm before bind"
            `Quick
            test_blocked_disposition_requires_operator_rearm_before_bind
        ; Alcotest.test_case
            "orphaned start reservation reclaims to ready"
            `Quick
            test_orphaned_start_reservation_reclaims_to_ready
        ; Alcotest.test_case
            "malformed snapshot is explicit"
            `Quick
            test_malformed_snapshot_fails_install_and_is_observed
        ; Alcotest.test_case
            "partial pending snapshot preserves readable entries"
            `Quick
            test_partial_pending_snapshot_preserves_readable_entries
        ; Alcotest.test_case
            "unsupported version requires runtime reset"
            `Quick
            test_unsupported_version_snapshot_requires_runtime_reset
        ; Alcotest.test_case
            "unreadable current snapshot is preserved"
            `Quick
            test_unreadable_snapshot_fails_closed_and_is_preserved
        ; Alcotest.test_case
            "malformed replay sidecar is preserved"
            `Quick
            test_malformed_replay_sidecar_is_scoped_and_preserved
        ; Alcotest.test_case
            "raw replay output wire is rejected"
            `Quick
            test_replay_sidecar_rejects_raw_output_wire
        ; Alcotest.test_case
            "delivery journal replays"
            `Quick
            test_persisted_delivery_replays_before_origin_wake
        ; Alcotest.test_case
            "observed delivery preserves grant without replaying wake"
            `Quick
            test_observed_delivery_preserves_grant_without_replaying_wake
        ; Alcotest.test_case
            "cancelled delivery preserves grant without replaying wake"
            `Quick
            test_cancelled_delivery_preserves_grant_without_replaying_wake
        ; Alcotest.test_case
            "one replay failure does not stop others"
            `Quick
            test_one_delivery_replay_failure_does_not_stop_others
        ; Alcotest.test_case
            "storage failure is returned"
            `Quick
            test_submit_surfaces_storage_failure
        ; Alcotest.test_case
            "default Auto Judge defers without blocking"
            `Quick
            test_default_auto_judge_defers_without_blocking
        ; Alcotest.test_case
            "unavailable grant never falls through"
            `Quick
            test_unavailable_cycle_grant_never_falls_through
        ; Alcotest.test_case
            "non-approved resolution payload is delivered"
            `Quick
            test_nonapproved_resolution_payload_is_delivered
        ; Alcotest.test_case
            "audit store failure keeps defer committed and visible"
            `Quick
            test_audit_store_failure_keeps_defer_committed_and_visible
        ; Alcotest.test_case
            "audit cleanup failure preserves recorded receipt"
            `Quick
            test_audit_cleanup_failure_preserves_recorded_receipt
        ; Alcotest.test_case
            "audit append failure keeps authority mutations committed"
            `Quick
            test_audit_append_failure_keeps_resolution_rule_and_grant_committed
        ; Alcotest.test_case
            "cancelled audit observation preserves committed Allow"
            `Quick
            test_cancelled_audit_observation_preserves_committed_allow
        ; Alcotest.test_case
            "audit lock wait cancellation remains cancellation"
            `Quick
            test_audit_lock_wait_cancellation_remains_cancellation
        ; Alcotest.test_case
            "HTTP success exposes failed resolution and rule audit"
            `Quick
            test_http_success_exposes_failed_resolution_and_rule_delete_audit
        ; Alcotest.test_case
            "delivery wire shape drops the request context"
            `Quick
            test_delivery_wire_shape_drops_request_context
        ; Alcotest.test_case
            "queue writes advance the projection revision"
            `Quick
            test_queue_writes_advance_the_projection_revision
        ] )
    ]
;;
