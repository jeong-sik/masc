(** An async composition's result reaches the Keeper that submitted it.

    A [keeper_compose_*] call declared [execution = "async"] hands back a
    request id and returns. Measured over 2026-08-18..26 on the live store: 22
    submissions produced 12 reads of [keeper_composition_status], and a settled
    result waited a median of 21.9s to be collected against a median 2.7ms of
    work — one waited 47 minutes. The wrapper meant to keep a turn free made
    the answer arrive later than running it inline would have.

    These tests drive [deliver] against a real workspace and read the
    submitter's durable queue, so a result that stops at the enqueue boundary
    is a failure. They also project the queued result the way a turn does,
    because a result the Keeper is woken for but cannot read is the same loss
    with an extra wake. *)

open Alcotest
module Workspace = Masc.Workspace
module Keeper_meta_store = Masc.Keeper_meta_store
module Wake = Masc.Keeper_composition_completion_wake
module Async = Masc.Keeper_msg_async
module Keeper_registry = Masc.Keeper_registry
module Event_queue = Keeper_event_queue
module WO = Masc.Keeper_world_observation
module Prompt = Masc.Keeper_unified_prompt

let submitter = "alpha"
let request_id = "kmsg-0001"
let composition_tool = "keeper_compose_memory-background"

let with_workspace f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc_composition_wake_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir dir 0o755;
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace.default_config dir in
  ignore (Workspace.init config ~agent_name:(Some "operator"));
  Fun.protect
    ~finally:(fun () -> ignore (Workspace.reset config))
    (fun () -> f config)
;;

let ensure_keeper config ~keeper_name =
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
            [ "name", `String keeper_name
            ; "activation_mode", `String "manual"
            ])
    with
    | Ok meta -> meta
    | Error err -> fail ("keeper meta fixture failed: " ^ err)
  in
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok _ -> ()
   | Error err -> fail ("write keeper meta failed: " ^ err));
  ignore
    (Keeper_registry.register_offline
       ~base_path:config.Workspace.base_path
       keeper_name
       meta
     : Keeper_registry.registry_entry)
;;

let queued_results ~base_path ~keeper_name =
  match Keeper_event_queue_persistence.load_result ~base_path ~keeper_name with
  | Error detail -> fail ("event queue load failed: " ^ detail)
  | Ok queue ->
    Event_queue.to_list queue
    |> List.filter_map (fun (stimulus : Event_queue.stimulus) ->
      match stimulus.payload with
      | Event_queue.Composition_completed completion -> Some (stimulus, completion)
      | Event_queue.Board_signal _
      | Event_queue.Board_attention _
      | Event_queue.Bootstrap
      | Event_queue.Fusion_completed _
      | Event_queue.Schedule_due _
      | Event_queue.Connector_attention _
      | Event_queue.Hitl_resolved _
      | Event_queue.Ask_answered _
      | Event_queue.Completion_authority_rejected _
      | Event_queue.Task_outcome _
      | Event_queue.Task_cancelled _
      | Event_queue.Workspace_message _
      | Event_queue.Owned_job_completed _
      | Event_queue.Delegate_completed _ -> None)
;;

let deliver_or_fail config ~terminal =
  match
    Wake.deliver
      ~not_before:0.
      ~base_path:config.Workspace.base_path
      ~keeper_name:submitter
      ~request_id
      ~composition_tool
      ~terminal
  with
  | Ok () -> ()
  | Error detail -> fail ("deliver failed: " ^ detail)
;;

let persist_completion_result config status =
  let entry : Async.entry =
    { request_id; keeper_name = submitter; base_path = config.Workspace.base_path
    ; submitted_by = submitter
    ; request_context = Some [ "composition_tool", `String composition_tool
        ; "composition_run_id", `String "original-run"
        ; "parent_tool_use_id", `String "original-invocation"
        ; "source_turn", `Int 7
        ; "source_task_id", `String "original-task" ]
    ; status; submitted_at = 1.; completed_at = Some 2. } in
  match Async.For_testing.persist_terminal_record entry with
  | Ok () -> ()
  | Error detail -> fail ("persist completion fixture failed: " ^ detail)
;;

(* The whole point of the change: the Keeper is told, on its own queue, keyed
   on the request id the tool handed it. *)
let the_result_reaches_the_submitter () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:submitter;
    deliver_or_fail config ~terminal:Event_queue.Composition_succeeded;
    match
      queued_results ~base_path:config.Workspace.base_path ~keeper_name:submitter
    with
    | [ (stimulus, completion) ] ->
      check
        string
        "the result is keyed on the request id the tool handed back"
        ("keeper-composition:" ^ request_id)
        stimulus.post_id;
      check string "and correlates to that same id" request_id completion.cc_request_id;
      check
        string
        "the result names which composition finished"
        composition_tool
        completion.cc_tool
    | [] -> fail "the submitter's queue holds no result"
    | _ :: _ :: _ -> fail "one request produced more than one result")
;;

(* A success carries no body on purpose: the result is already durable in the
   async request record and keeper_composition_status reads it by request id.
   A failure carries its detail, which exists nowhere else the Keeper can act
   on. *)
let a_failure_carries_its_detail () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:submitter;
    deliver_or_fail
      config
      ~terminal:(Event_queue.Composition_failed "node search: store unavailable");
    match
      queued_results ~base_path:config.Workspace.base_path ~keeper_name:submitter
    with
    | [ (_, { cc_terminal = Event_queue.Composition_failed detail; _ }) ] ->
      check
        string
        "the failure detail travels with the wake"
        "node search: store unavailable"
        detail
    | _ -> fail "a failed composition must arrive as Composition_failed")
;;

(* Redelivery of the same settlement collapses onto the entry already queued:
   the request id is the whole key, so a replay does not wake the submitter
   twice about one request. *)
let the_same_result_arrives_once () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:submitter;
    deliver_or_fail config ~terminal:Event_queue.Composition_succeeded;
    deliver_or_fail config ~terminal:Event_queue.Composition_succeeded;
    check
      int
      "a replayed settlement does not queue a second time"
      1
      (List.length
         (queued_results ~base_path:config.Workspace.base_path ~keeper_name:submitter)))
;;

let conflicting_results_leave_the_original_delivery () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:submitter;
    deliver_or_fail config ~terminal:Event_queue.Composition_succeeded;
    let assert_rejected ~tool ~terminal =
      match Wake.deliver ~not_before:0. ~base_path:config.Workspace.base_path
          ~keeper_name:submitter ~request_id ~composition_tool:tool ~terminal with
      | Error _ -> ()
      | Ok () -> fail "same request with conflicting completion payload was accepted" in
    assert_rejected ~tool:composition_tool ~terminal:(Event_queue.Composition_failed "x");
    assert_rejected ~tool:"another-composition" ~terminal:Event_queue.Composition_succeeded;
    match queued_results ~base_path:config.Workspace.base_path ~keeper_name:submitter with
    | [ _, completion ] ->
      check string "original tool remains authoritative" composition_tool completion.cc_tool;
      check bool "original terminal remains authoritative" true
        (completion.cc_terminal = Event_queue.Composition_succeeded)
    | _ -> fail "conflicting settlement changed or duplicated the original delivery")
;;

let uncertain_queue_durability_does_not_acknowledge_delivery () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:submitter;
    let base_path = config.Workspace.base_path in
    let completion = { Event_queue.cc_request_id = request_id
                     ; cc_tool = composition_tool
                     ; cc_terminal = Event_queue.Composition_succeeded } in
    let stimulus : Event_queue.stimulus =
      { post_id = Event_queue.composition_completion_post_id completion
      ; urgency = Event_queue.Immediate
      ; arrived_at = Time_compat.now ()
      ; payload = Event_queue.Composition_completed completion } in
    let parent_syncs = Atomic.make 0 in
    let fail_parent_sync path state =
      Fs_compat.mkdir_p (Filename.dirname path);
      let content = Keeper_event_queue_snapshot_codec.encode_state state in
      Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
        ~sync_parent:(fun _ ->
          ignore (Atomic.fetch_and_add parent_syncs 1);
          raise (Unix.Unix_error (Unix.EIO, "fsync", "completion queue parent")))
        path content
      |> Result.map_error Fs_compat.atomic_replace_failure_to_string in
    let attempt () =
      match Keeper_event_queue_persistence.For_testing.enqueue_stimulus_once_with_confirmation
          ~confirm_snapshot:fail_parent_sync ~already_delivered:(fun () -> Ok false)
          ~base_path ~keeper_name:submitter stimulus with
      | Error _ -> ()
      | Ok () -> fail "queue parent fsync failure acknowledged a one-shot delivery" in
    attempt ();
    check int "renamed but unconfirmed source remains visible" 1
      (List.length (queued_results ~base_path ~keeper_name:submitter));
    attempt ();
    check int "same-source retry crosses parent fsync again" 2 (Atomic.get parent_syncs);
    check int "uncertain durability retry does not duplicate source" 1
      (List.length (queued_results ~base_path ~keeper_name:submitter));
    deliver_or_fail config ~terminal:Event_queue.Composition_succeeded;
    check int "confirmed retry preserves one original result" 1
      (List.length (queued_results ~base_path ~keeper_name:submitter)))
;;

(* The wake is only worth anything if the turn can read what arrived. The
   result has no Board post behind its id, and the block that renders a row's
   title and preview is the Board Activity one; routed anywhere else the
   Keeper wakes with nothing to read. *)
let the_turn_can_read_the_result () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:submitter;
    persist_completion_result config
      (Async.Done { ok = false; body = "node search: timed out"; data = None });
    deliver_or_fail
      config
      ~terminal:(Event_queue.Composition_failed "node search: timed out");
    match
      queued_results ~base_path:config.Workspace.base_path ~keeper_name:submitter
    with
    | [ (stimulus, _) ] ->
      let meta =
        match Keeper_meta_store.read_meta config submitter with
        | Ok (Some meta) -> meta
        | Ok None -> fail "the submitter has no meta"
        | Error err -> fail ("meta load failed: " ^ err)
      in
      (match WO.pending_board_event_of_stimulus ~base_path:config.Workspace.base_path ~meta stimulus with
       | Error _ -> fail "the result must project without a Board read"
       | Ok None -> fail "the result projects to nothing the turn can read"
       | Ok (Some event) ->
         check
           bool
           "the result reaches the block that renders its title and preview"
           true
           (WO.is_board_activity_event event);
         check
           string
           "the row is attributed to the Keeper that submitted the work"
           submitter
           event.WO.author;
         check
           string
           "the row states what finished, how, and under which id"
           (composition_tool ^ " failed " ^ request_id)
           event.WO.title;
         let projected = Yojson.Safe.from_string event.WO.preview in
         check string "the original failure detail is available"
           "node search: timed out"
           Yojson.Safe.Util.(projected |> member "terminal_detail" |> to_string);
         check string "the failure points to the exact original result" request_id
           Yojson.Safe.Util.(projected |> member "result_reference" |> member "arguments" |> member "request_id" |> to_string))
    | _ -> fail "the submitter's queue holds no result")
;;

(* The row the Keeper actually reads in its turn prompt.

   [board_event_fields] is the last step before prompt quoting, so this is the
   text the model sees. Pinned because the whole change is worth nothing if
   the Keeper is woken and the row does not say which composition settled or
   under which id it can read the result. *)
let the_prompt_row_says_what_settled () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:submitter;
    let exports = `Assoc [ "answer", `Assoc [ "available", `Bool true; "value", `String "selected answer" ] ] in
    persist_completion_result config
      (Async.Done { ok = true; body = "complete durable result";
        data = Some (`Assoc [ "exports", exports; "nodes", `List [] ]) });
    deliver_or_fail config ~terminal:Event_queue.Composition_succeeded;
    match
      queued_results ~base_path:config.Workspace.base_path ~keeper_name:submitter
    with
    | [ (stimulus, _) ] ->
      let meta =
        match Keeper_meta_store.read_meta config submitter with
        | Ok (Some meta) -> meta
        | Ok None -> fail "the submitter has no meta"
        | Error err -> fail ("meta load failed: " ^ err)
      in
      (match WO.pending_board_event_of_stimulus ~base_path:config.Workspace.base_path ~meta stimulus with
       | Ok (Some event) ->
         let fields = Prompt.For_testing.board_event_fields event in
         let field name =
           match List.assoc_opt name fields with
           | Some value -> value
           | None -> fail ("the prompt row carries no " ^ name ^ " field")
         in
         check string "the row is labelled as a settled composition"
           "keeper_composition_completed" (field "event");
         check string "and addressed by the request id the tool handed back"
           ("keeper-composition:" ^ request_id) (field "post_id");
         check string "the title names the composition, the outcome, and the id"
           (composition_tool ^ " succeeded " ^ request_id) (field "title");
         let projected = Yojson.Safe.from_string (field "preview") in
         check bool "success has canonical result proof" true
           Yojson.Safe.Util.(projected |> member "result_available" |> to_bool);
         check string "the next prompt carries the selected answer" "selected answer"
           Yojson.Safe.Util.(projected |> member "exports" |> member "answer" |> member "value" |> to_string);
         check string "the answer remains joined to the original task" "original-task"
           Yojson.Safe.Util.(projected |> member "source" |> member "source_task_id" |> to_string);
         check string "and to the actual run" "original-run"
           Yojson.Safe.Util.(projected |> member "source" |> member "composition_run_id" |> to_string);
         Printf.printf "composition_completion_projection_trial canonical_result=true selected_answer_in_prompt=true status_reads_to_recover_selected_answer=0 prompt_preview_bytes=%d model_latency_measured=false\n%!"
           (String.length (field "preview"))
       | Ok None -> fail "the result projects to nothing the turn can read"
       | Error _ -> fail "the result must project without a Board read")
    | _ -> fail "the submitter's queue holds no result")
;;

let projected_completion config ~reader =
  let meta = match Keeper_meta_store.read_meta config reader with
    | Ok (Some meta) -> meta | Ok None -> fail "projection reader metadata is missing"
    | Error detail -> fail detail in
  match queued_results ~base_path:config.Workspace.base_path ~keeper_name:submitter with
  | [ stimulus, _ ] ->
    (match WO.pending_board_event_of_stimulus ~base_path:config.Workspace.base_path ~meta stimulus with
     | Ok (Some event) ->
       let fields = Prompt.For_testing.board_event_fields event in
       let preview = match List.assoc_opt "preview" fields with
         | Some preview -> preview | None -> fail "completion has no structured result projection" in
       Yojson.Safe.from_string preview
     | Ok None -> fail "completion did not reach the next prompt"
     | Error unavailable -> fail (Masc.Keeper_world_observation_board_signal.unavailable_to_string unavailable))
  | _ -> fail "projection did not find one original completion"
;;

let a_large_export_remains_an_exact_reference () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:submitter;
    let value = String.make (Common.max_agent_core_inline_result_bytes + 1) 'x' in
    let data = `Assoc [ "exports", `Assoc [ "answer", `Assoc [ "available", `Bool true; "value", `String value ] ] ] in
    persist_completion_result config (Async.Done { ok = true; body = value; data = Some data });
    deliver_or_fail config ~terminal:Event_queue.Composition_succeeded;
    let projected = projected_completion config ~reader:submitter in
    check bool "large selected value is explicitly referenced" false
      Yojson.Safe.Util.(projected |> member "result_inline" |> to_bool);
    check bool "partial JSON is not substituted for the value" true
      Yojson.Safe.Util.(projected |> member "exports" = `Null);
    let exact_id = Yojson.Safe.Util.(projected |> member "result_reference" |> member "arguments" |> member "request_id" |> to_string) in
    check string "result lookup remains exact" request_id exact_id;
    (match Async.poll ~base_path:config.Workspace.base_path ~caller:submitter exact_id with
     | Async.Found { status = Async.Done { data = Some original; _ }; _ } ->
       check string "reference recovers the complete original export" value
         Yojson.Safe.Util.(original |> member "exports" |> member "answer" |> member "value" |> to_string)
     | _ -> fail "large selected result could not be recovered by its exact reference"))
;;

let partial_failure_is_visible_with_the_available_result () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:submitter;
    let exports = `Assoc
        [ "answer", `Assoc [ "available", `Bool true; "value", `String "independent answer" ]
        ; "other", `Assoc [ "available", `Bool false; "error", `Assoc [ "kind", `String "producer_unavailable" ] ] ] in
    let detail = "independent branch returned; other branch failed" in
    let data = `Assoc [ "exports", exports
                      ; "cause", `Assoc [ "kind", `String "tool_did_not_complete" ]
                      ; "effect_disposition", `String "effect_outcome_unknown" ] in
    persist_completion_result config (Async.Done { ok = false; body = detail; data = Some data });
    deliver_or_fail config ~terminal:(Event_queue.Composition_failed detail);
    let projected = projected_completion config ~reader:submitter in
    check string "partial result does not promote the terminal" "failed"
      Yojson.Safe.Util.(projected |> member "outcome" |> to_string);
    check string "independent result remains available" "independent answer"
      Yojson.Safe.Util.(projected |> member "exports" |> member "answer" |> member "value" |> to_string);
    check bool "failed branch is explicit" false
      Yojson.Safe.Util.(projected |> member "exports" |> member "other" |> member "available" |> to_bool);
    check string "unknown effect is retained" "effect_outcome_unknown"
      Yojson.Safe.Util.(projected |> member "effect_disposition" |> to_string);
    check string "original failure cause is retained" "tool_did_not_complete"
      Yojson.Safe.Util.(projected |> member "cause" |> member "kind" |> to_string))
;;

let missing_or_inconsistent_result_is_explicit () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:submitter;
    deliver_or_fail config ~terminal:Event_queue.Composition_succeeded;
    let unavailable = projected_completion config ~reader:submitter in
    check bool "a notification is not result proof" false
      Yojson.Safe.Util.(unavailable |> member "result_available" |> to_bool);
    check string "missing request is explicit" "canonical_result_unavailable"
      Yojson.Safe.Util.(unavailable |> member "result_error" |> member "kind" |> to_string);
    persist_completion_result config
      (Async.Done { ok = false; body = "canonical failure"; data = None });
    let inconsistent = projected_completion config ~reader:submitter in
    check bool "a stale success cannot authorize a failed canonical result" false
      Yojson.Safe.Util.(inconsistent |> member "result_available" |> to_bool);
    check string "terminal disagreement is explicit" "terminal_mismatch"
      Yojson.Safe.Util.(inconsistent |> member "result_error" |> member "kind" |> to_string))
;;

let another_keeper_cannot_read_the_result () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:submitter;
    ensure_keeper config ~keeper_name:"another-keeper";
    let data = `Assoc [ "exports", `Assoc [ "secret", `Assoc [ "available", `Bool true; "value", `String "owned result" ] ] ] in
    persist_completion_result config (Async.Done { ok = true; body = "owned result"; data = Some data });
    deliver_or_fail config ~terminal:Event_queue.Composition_succeeded;
    let rejected = projected_completion config ~reader:"another-keeper" in
    check bool "different Keeper has no canonical result authority" false
      Yojson.Safe.Util.(rejected |> member "result_available" |> to_bool);
    check bool "unowned result is not injected into the next prompt" true
      Yojson.Safe.Util.(rejected |> member "exports" = `Null))
;;

(* The queue is durable, so a result that cannot be read back is lost on the
   next restart — silently, because the reader has no other copy. *)
let the_result_survives_a_round_trip () =
  List.iter
    (fun terminal ->
       let completion =
         { Event_queue.cc_request_id = request_id
         ; cc_tool = composition_tool
         ; cc_terminal = terminal
         }
       in
       let stimulus : Event_queue.stimulus =
         { Event_queue.post_id = Event_queue.composition_completion_post_id completion
         ; urgency = Event_queue.Normal
         ; arrived_at = 1.0
         ; payload = Event_queue.Composition_completed completion
         }
       in
       match Event_queue.stimulus_of_yojson (Event_queue.stimulus_to_yojson stimulus) with
       | Error detail -> fail ("the result cannot be read back: " ^ detail)
       | Ok decoded ->
         check
           bool
           "the result is the same after a round trip"
           true
           (Event_queue.stimulus_identity_equal decoded stimulus))
    [ Event_queue.Composition_succeeded
    ; Event_queue.Composition_failed "store unavailable"
    ; Event_queue.Composition_cancelled "operator: no longer needed"
    ]
;;

(* A composition result is read before the Board backlog it landed behind.

   [pending_entries] is urgency-sorted and stable, so an entry at [Normal]
   queues after every [Normal] already there — and Board attention stimuli are
   [Normal]. Measured on the live fleet, one Keeper held 151 of them; at
   [Normal] this wake would be read on the 152nd turn, which is slower than
   the polling it replaces. [Immediate] is the same urgency [Hitl_resolved]
   uses, for the same reason: an answer to something this Keeper asked for is
   not the same kind of event as somebody else posting to the Board. *)
let a_result_is_read_before_the_board_backlog () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:submitter;
    let base_path = config.Workspace.base_path in
    let board_post index : Event_queue.stimulus =
      { post_id = Printf.sprintf "p-board-%d" index
      ; urgency = Event_queue.Normal
      ; arrived_at = 100.0 +. float_of_int index
      ; payload =
          Event_queue.Board_signal
            { kind = Event_queue.Post_created
            ; author = "somebody-else"
            ; title = "a post this Keeper did not ask for"
            ; content = ""
            ; hearth = None
            ; updated_at = Some (100.0 +. float_of_int index)
            }
      }
    in
    let completion =
      { Event_queue.cc_request_id = request_id
      ; cc_tool = composition_tool
      ; cc_terminal = Event_queue.Composition_succeeded
      }
    in
    (* Every Board entry arrives first, so arrival order alone would put the
       result last. *)
    let queue =
      List.fold_left
        Event_queue.enqueue
        Event_queue.empty
        (List.init 8 board_post
         @ [ { Event_queue.post_id =
                 Event_queue.composition_completion_post_id completion
             ; urgency = Event_queue.Immediate
             ; arrived_at = 900.0
             ; payload = Event_queue.Composition_completed completion
             }
           ])
    in
    Keeper_event_queue_persistence.persist ~base_path ~keeper_name:submitter queue;
    match
      Keeper_event_queue_persistence.load_state_result ~base_path ~keeper_name:submitter
    with
    | Error detail -> fail ("queue state load failed: " ^ detail)
    | Ok state ->
      (match
         Keeper_event_queue_state.select_when
           ~now:(Unix.gettimeofday ())
           ~ready:(fun _ -> true)
           state
       with
       | None -> fail "nothing was selectable"
       | Some entry ->
         (match entry.Keeper_event_queue_state.source.payload with
          | Event_queue.Composition_completed picked ->
            check
              string
              "the result is selected ahead of eight earlier Board entries"
              request_id
              picked.Event_queue.cc_request_id
          | Event_queue.Board_signal _ ->
            fail
              "the result queued behind the Board backlog; at Normal urgency it \
               would be read only after every Board entry ahead of it"
          | _ -> fail "an unexpected payload was selected")))
;;

(* Which settled statuses wake the submitter. A status the broker can reach
   and this does not announce is a silent drop — the exact failure this module
   exists to end — so every one is named. *)
let every_settled_status_is_announced () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:submitter;
    let base_path = config.Workspace.base_path in
    let settle ~request_id status =
      let entry : Async.entry =
        { request_id
        ; keeper_name = submitter
        ; base_path
        ; submitted_by = submitter
        ; request_context = None
        ; status
        ; submitted_at = 1.0
        ; completed_at = Some 2.0
        }
      in
      Wake.on_worker_settled
        ~base_path
        ~composition_tool
        (Async.Status_settlement
           { entry; durability = Async.Durable; origin = Async.Transition_commit })
    in
    let settled =
      [ "kmsg-done-ok", Async.Done { ok = true; body = "{}"; data = None }
      ; "kmsg-done-err", Async.Done { ok = false; body = "boom"; data = None }
      ; "kmsg-lost", Async.Lost { reason = "worker vanished" }
      ; ( "kmsg-persist"
        , Async.Persistence_failed { attempted_status = Async.State_transition "done"; reason = "disk full" } )
      ; ( "kmsg-cancel"
        , Async.Cancelled { reason = "no longer needed"; cancelled_by = "operator" } )
      ]
    in
    List.iter (fun (id, status) -> settle ~request_id:id status) settled;
    check
      int
      "every settled status wakes the submitter exactly once"
      (List.length settled)
      (List.length (queued_results ~base_path ~keeper_name:submitter));
    (* A request still in flight is not a settlement to announce. Announcing
       one would tell the Keeper its work is done while it is still running. *)
    List.iter
      (fun (id, status) -> settle ~request_id:id status)
      [ "kmsg-queued", Async.Queued
      ; "kmsg-running", Async.Running
      ; ( "kmsg-cancelling"
        , Async.Cancelling { reason = "stop"; cancelled_by = "operator" } )
      ];
    check
      int
      "a request still in flight adds nothing to the queue"
      (List.length settled)
      (List.length (queued_results ~base_path ~keeper_name:submitter)))
;;

(* A settlement the store does not hold as canonical truth is not announced.
   Telling a Keeper its work succeeded on evidence that may not survive is
   worse than leaving it to read the record itself. *)
let a_non_durable_settlement_is_not_announced () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:submitter;
    let base_path = config.Workspace.base_path in
    let entry : Async.entry =
      { request_id
      ; keeper_name = submitter
      ; base_path
      ; submitted_by = submitter
      ; request_context = None
      ; status = Async.Done { ok = true; body = "{}"; data = None }
      ; submitted_at = 1.0
      ; completed_at = Some 2.0
      }
    in
    Wake.on_worker_settled
      ~base_path
      ~composition_tool
      (Async.Status_settlement
         { entry
         ; durability = Async.Volatile_persistence_failure
         ; origin = Async.Transition_commit
         });
    check
      int
      "a settlement that is not durably canonical is not announced"
      0
      (List.length (queued_results ~base_path ~keeper_name:submitter)))
;;

let completion_delivery_recovers_without_replaying_or_reconsuming () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:submitter;
    let module Outbox = Masc.Keeper_composition_completion_outbox in
    let module Queue = Masc.Keeper_registry_event_queue in
    let base_path = config.Workspace.base_path in
    Eio.Switch.run @@ fun background_sw ->
    let release_worker, release = Eio.Promise.create () in
    let worker_settled, settled = Eio.Promise.create () in
    let dispatched = Atomic.make 0 in
    let accepted = Async.submit_with_request_id
        ~request_context:[ "composition_tool", `String composition_tool
                         ; "composition_run_id", `String "outbox-run"
                         ; "parent_tool_use_id", `String "original-invocation" ]
        ~on_accepted:(fun request_id ->
          Outbox.prepare ~base_path ~keeper_name:submitter ~request_id ~composition_tool
          |> Result.map_error Outbox.error_to_string)
        ~on_worker_settled:(fun settlement ->
          Wake.on_worker_settled ~base_path ~composition_tool settlement;
          Eio.Promise.resolve settled ())
        ~background_sw ~base_path ~caller:submitter ~keeper_name:submitter
        ~f:(fun ~request_id:_ _request_sw ->
          ignore (Atomic.fetch_and_add dispatched 1);
          Eio.Promise.await release_worker;
          Tool_result.make_ok ~tool_name:composition_tool ~start_time:(Tool_timing.start ())
            ~data:(`Assoc [ "exports", `Assoc [ "answer", `String "original result" ] ]) ()) ()
      |> Result.get_ok in
    check bool "completion obligation precedes worker acceptance" true
      (accepted.acceptance = Async.Durably_accepted);
    let waiting = Wake.reconcile ~base_path |> Result.get_ok in
    check int "active request keeps one delivery obligation" 1 waiting.waiting;
    let queue_path = Filename.concat
        (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) submitter)
        Keeper_event_queue_persistence.snapshot_filename in
    Fs_compat.mkdir_p (Filename.dirname queue_path);
    Fs_compat.save_file queue_path "broken queue snapshot";
    Eio.Promise.resolve release ();
    Eio.Promise.await worker_settled;
    let failed = Wake.reconcile ~base_path |> Result.get_ok in
    check int "actual queue storage failure retains delivery" 1 (List.length failed.failures);
    check int "failed delivery does not claim success" 0 failed.delivered;
    check int "worker executed once" 1 (Atomic.get dispatched);
    (match Async.load_canonical_durable_terminal ~base_path ~caller:submitter accepted.request_id with
     | Ok proof ->
       (match (Async.durable_terminal_entry proof).status with
        | Async.Done { ok = true; data = Some data; _ } ->
          check string "original result survives notification failure" "original result"
            Yojson.Safe.Util.(data |> member "exports" |> member "answer" |> to_string)
        | _ -> fail "canonical worker result was lost")
     | Error error -> fail (Async.canonical_terminal_error_to_string error));
    Sys.remove queue_path;
    Async.For_testing.clear ();
    let queued_but_unacknowledged = Outbox.flush ~base_path
        ~deliver:(fun ~composition_tool entry ->
          match Wake.deliver ~base_path ~not_before:entry.Async.submitted_at
              ~keeper_name:entry.Async.submitted_by
              ~request_id:entry.request_id ~composition_tool ~terminal:Event_queue.Composition_succeeded with
          | Error _ as error -> error
          | Ok () -> Error "injected interruption after durable enqueue, before producer acknowledgement")
      |> Result.get_ok in
    check int "enqueue-ack gap leaves the same obligation" 1 (List.length queued_but_unacknowledged.failures);
    let source = match queued_results ~base_path ~keeper_name:submitter with
      | [ source, completion ] ->
        check string "recovery delivers the original request" accepted.request_id completion.cc_request_id;
        source
      | _ -> fail "recovery lost or duplicated completion" in
    let selection = match Queue.select_when_result ~base_path submitter ~now:(Time_compat.now ()) ~ready:(fun _ -> true) with
      | Ok (Some selection) -> selection
      | _ -> fail "recovered completion was not admitted" in
    Masc.Keeper_reaction_ledger.record_event_queue_turn_started ~base_path ~keeper_name:submitter source;
    (match Queue.terminalize_pending_turn_completed_result ~base_path submitter
        ~applied_at:(Time_compat.now ()) ~selection with
     | Ok (Queue.Turn_source_acked _) -> ()
     | Ok Queue.Turn_selection_withdrawn -> fail "completion disappeared before consumption"
     | Error detail -> fail detail);
    let ledger_store =
      Dated_jsonl.open_store
        (Masc.Keeper_reaction_ledger.location ~base_path ~keeper_name:submitter)
    in
    let ledger_paths = Dated_jsonl.range_day_file_paths_result ledger_store
        ~since:"1970-01-01" ~until:"9999-12-31" |> Result.get_ok in
    check bool "consumption has physical ledger evidence" true (ledger_paths <> []);
    let originals = List.map (fun path -> path, Fs_compat.load_file path) ledger_paths in
    List.iter (fun (path, _) -> Fs_compat.save_file path "{broken consumption evidence}\n") originals;
    let unreadable = Wake.reconcile ~base_path |> Result.get_ok in
    check int "corrupted consumption evidence retains the original obligation" 1
      (List.length unreadable.failures);
    check int "unproven absence does not retire delivery" 0 unreadable.delivered;
    check int "corrupted evidence cannot re-enqueue consumed source" 0
      (List.length (queued_results ~base_path ~keeper_name:submitter));
    List.iter (fun (path, contents) -> Fs_compat.save_file path contents) originals;
    let recovered = Wake.reconcile ~base_path |> Result.get_ok in
    check int "consumed completion retires its pending obligation" 1 recovered.delivered;
    check int "recovered completion is not consumed again" 0 (List.length (queued_results ~base_path ~keeper_name:submitter));
    check int "delivery recovery never replays the worker" 1 (Atomic.get dispatched);
    let empty = Wake.reconcile ~base_path |> Result.get_ok in
    check int "retired obligations leave the pending partition" 0 empty.inspected;
    Printf.printf "composition_completion_trial dispatches=%d initial_queue_failure=true restart_memory_cleared=true recovered_deliveries=%d duplicate_pending=0\n%!"
      (Atomic.get dispatched) recovered.delivered)
;;

let produce_pending_completion ~base_path keeper_name body =
  let module Outbox = Masc.Keeper_composition_completion_outbox in
  Eio.Switch.run (fun background_sw ->
    let done_, settled = Eio.Promise.create () in
    let request = Async.submit_with_request_id
        ~request_context:["composition_tool",`String composition_tool;
          "source_task_id",`String (keeper_name ^ "-original-task")]
        ~on_accepted:(fun request_id ->
          Outbox.prepare ~base_path ~keeper_name ~request_id ~composition_tool
          |> Result.map_error Outbox.error_to_string)
        (* Leave actual durable completion obligations for recovery; the
           producer switch joins its own physical worker before returning. *)
        ~on_worker_settled:(fun _ -> Eio.Promise.resolve settled ())
        ~background_sw ~base_path ~caller:keeper_name ~keeper_name
        ~f:(fun ~request_id:_ _ ->
          Tool_result.make_ok ~tool_name:composition_tool ~start_time:(Tool_timing.start ())
            ~data:(`Assoc ["original_output",`String body]) ()) ()
      |> Result.get_ok in
    Eio.Promise.await done_;
    request)
;;

let independent_completion_owners_keep_original_proofs () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:"alpha";
    ensure_keeper config ~keeper_name:"beta";
    let module Outbox = Masc.Keeper_composition_completion_outbox in
    let module Fence = Masc.Keeper_shutdown_intake_fence in
    let base_path = config.Workspace.base_path in
    let produce = produce_pending_completion ~base_path in
    let alpha = produce "alpha" "alpha output" in
    let beta = produce "beta" "beta output" in
    let discovered = Outbox.discover ~base_path |> Result.get_ok in
    let beta_hint = List.find (fun (pending : Outbox.pending) ->
        String.equal pending.request_id beta.request_id) discovered.entries in
    let canonical request keeper_name =
      match Async.load_canonical_durable_terminal ~base_path ~caller:keeper_name request with
      | Ok proof -> Async.durable_terminal_entry proof
      | Error error -> fail (Async.canonical_terminal_error_to_string error) in
    let original_alpha = canonical alpha.request_id "alpha" in
    let original_beta = canonical beta.request_id "beta" in
    Eio.Switch.run (fun sw ->
      let entered, enter = Eio.Promise.create () in
      let released, release = Eio.Promise.create () in
      let beta_done, publish_beta = Eio.Promise.create () in
      let alpha_blocked, publish_blocked = Eio.Promise.create () in
      let alpha_done, publish_alpha = Eio.Promise.create () in
      let fence = ref None in
      Fun.protect ~finally:(fun () ->
        if not (Eio.Promise.is_resolved released) then Eio.Promise.resolve release ();
        Option.iter (fun operation_id ->
          ignore (Fence.rollback_shutdown ~base_path ~keeper_name:"alpha" ~operation_id)) !fence)
        (fun () ->
          let holder = Eio.Fiber.fork_promise ~sw (fun () ->
            Fence.run_durable_intake_if_open ~base_path ~keeper_name:"alpha" (fun _ ->
              Eio.Promise.resolve enter ();
              Eio.Promise.await released)) in
          Eio.Promise.await entered;
          let discoveries = Eio.Stream.create 0 in
          let recovery = Wake.create ~base_path
            ~on_discovery:(fun ~base_path:_ result -> Eio.Stream.add discoveries result)
            ~on_report:(fun ~keeper_name report ->
            if String.equal keeper_name "beta" then (
              if not (Eio.Promise.is_resolved beta_done) then Eio.Promise.resolve publish_beta report)
            else if String.equal keeper_name "alpha" then (
              if not (Eio.Promise.is_resolved alpha_blocked) then Eio.Promise.resolve publish_blocked report
              else if not (Eio.Promise.is_resolved alpha_done) then Eio.Promise.resolve publish_alpha report)
            else fail "completion recovery changed original owner") () in
          let pulse () =
            Wake.pulse ~sw recovery;
            let result = Eio.Stream.take discoveries in
            (* Let the observer's pure discovery cleanup finish. The original
               owner may still be blocked; this is not owner quiescence. *)
            Eio.Fiber.yield ();
            match result with
            | Ok () -> () | Error error -> fail (Outbox.error_to_string error) in
          pulse ();
          let beta_report = Eio.Promise.await beta_done in
          (match beta_report.failures with [] -> () | _ -> fail "independent completion failed");
          check bool "alpha remains behind its actual intake lock" false
            (Eio.Promise.is_resolved alpha_blocked);
          (match queued_results ~base_path ~keeper_name:"beta" with
           | [_, completion] -> check string "independent original completion committed"
               beta.request_id completion.Event_queue.cc_request_id
           | _ -> fail "alpha's queue wait blocked beta");
          let later = produce "alpha" "later alpha output" in
          pulse ();
          let operation_id = Masc.Keeper_shutdown_types.Operation_id.generate () in
          fence := Some operation_id;
          ignore (Fence.begin_shutdown ~base_path ~keeper_name:"alpha" ~operation_id);
          Eio.Promise.resolve release ();
          (match Eio.Promise.await_exn holder with
           | Fence.Intake_committed () -> ()
           | Intake_shutdown_reserved _ -> fail "the already admitted lock holder changed");
          let blocked = Eio.Promise.await alpha_blocked in
          (match blocked.failures with
           | [id, error] ->
               check string "active batch retains original request" alpha.request_id id;
               (match error with
                | Outbox.Storage_failed _ -> ()
                | Invalid_obligation _ | Request_unavailable _ | Canonical_result_unavailable _ ->
                    fail "fresh intake fence was not checked")
           | [] | _ :: _ -> fail "active original batch was replaced or duplicated");
          (match queued_results ~base_path ~keeper_name:"alpha" with
           | [] -> () | _ :: _ -> fail "shutdown fence admitted a completion");
          ignore (Fence.rollback_shutdown ~base_path ~keeper_name:"alpha" ~operation_id);
          fence := None;
          pulse ();
          let recovered = Eio.Promise.await alpha_done in
          (match recovered.failures with [] -> () | _ -> fail "original completions did not recover");
          check (list string) "fresh batch delivers both exact original requests"
            (List.sort String.compare [alpha.request_id;later.request_id])
            (queued_results ~base_path ~keeper_name:"alpha"
             |> List.map (fun (_, completion) -> completion.Event_queue.cc_request_id)
             |> List.sort String.compare);
          check bool "alpha canonical output and Task provenance retained" true
            (canonical alpha.request_id "alpha" = original_alpha);
          check bool "beta canonical output and Task provenance retained" true
            (canonical beta.request_id "beta" = original_beta);
          (* An already acknowledged original hint is not delivery authority. *)
          (match Outbox.recover beta_hint ~deliver:(fun ~composition_tool (entry : Async.entry) ->
             match Wake.terminal_of_status entry.status with
             | None -> Error "no canonical terminal"
             | Some terminal -> Wake.deliver ~base_path ~not_before:entry.submitted_at
                 ~keeper_name:entry.submitted_by ~request_id:entry.request_id ~composition_tool ~terminal) with
           | Ok Outbox.Retired -> ()
           | Ok (Waiting | Delivered) | Error _ -> fail "acknowledged hint borrowed delivery authority");
          (match queued_results ~base_path ~keeper_name:"beta" with
           | [_, completion] when String.equal completion.Event_queue.cc_request_id beta.request_id -> ()
           | [] | _ :: _ -> fail "repeated pulses changed beta's exact queued result"))))
;;

let discovery_failure_retains_original_completion_and_recovers_with_partial_damage () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:"alpha";
    ensure_keeper config ~keeper_name:"beta";
    let module Outbox = Masc.Keeper_composition_completion_outbox in
    let base_path = config.Workspace.base_path in
    let original = produce_pending_completion ~base_path "alpha" "original output" in
    let canonical () =
      match Async.load_canonical_durable_terminal ~base_path ~caller:"alpha" original.request_id with
      | Ok proof -> Async.durable_terminal_entry proof
      | Error error -> fail (Async.canonical_terminal_error_to_string error) in
    let original_proof = canonical () in
    (* Fault the production partition itself, preserving the exact original
       obligation for restoration; no replacement outbox reader is installed. *)
    let directory = Filename.concat
        (Common.masc_dir_from_base_path ~base_path)
        "composition-completion-delivery/pending" in
    let saved_directory = directory ^ ".fixture-saved" in
    Unix.rename directory saved_directory;
    Fs_compat.save_file directory "outbox directory unavailable during discovery";
    let exception Discovery_observer_failed in
    let discoveries = Eio.Stream.create 0 in
    let recovery = Wake.create ~base_path ~on_discovery:(fun ~base_path result ->
      Eio.Stream.add discoveries (base_path,result);
      match result with
      | Ok () -> ()
      | Error _ -> raise Discovery_observer_failed) () in
    let independent : Event_queue.stimulus =
      {post_id="independent-during-completion-discovery";urgency=Normal;
       arrived_at=201.;payload=Bootstrap} in
    let failed = Eio.Switch.run (fun sw ->
      Wake.pulse ~sw recovery;
      (* Commit actual independent work before joining discovery observation. *)
      (match Masc.Keeper_registry_event_queue.enqueue_durable_result
          ~base_path "beta" independent with
       | Ok () -> () | Error detail -> fail detail);
      Eio.Stream.take discoveries) in
    (match failed with
     | observed_base, Error (Outbox.Storage_failed _) ->
         check string "discovery failure keeps original workspace" base_path observed_base
     | _, Error (Outbox.Invalid_obligation _ | Request_unavailable _
                | Canonical_result_unavailable _) ->
         fail "directory failure lost its original storage-error type"
     | _, Ok () -> fail "failed or unfinished discovery became success");
    (match queued_results ~base_path ~keeper_name:"alpha" with
     | [] -> () | _ :: _ -> fail "unavailable discovery admitted a completion");
    (match Keeper_event_queue_persistence.load_result ~base_path ~keeper_name:"beta" with
     | Error detail -> fail detail
     | Ok queue -> check bool "independent durable work retains its source" true
         (Event_queue.to_list queue
          |> List.exists (Event_queue.stimulus_identity_equal independent)));
    check bool "failed discovery preserves original terminal and Task provenance" true
      (canonical () = original_proof);
    Sys.remove directory;
    Unix.rename saved_directory directory;
    let damaged_name = "malformed-obligation.json" in
    let damaged_path = Filename.concat directory damaged_name in
    let damaged_bytes = "not-json\n" in
    Fs_compat.save_file damaged_path damaged_bytes;
    let fresh_round () = Eio.Switch.run (fun sw ->
      Wake.pulse ~sw recovery;
      Eio.Stream.take discoveries) in
    let require_returned = function
      | observed_base, Ok () -> check string "fresh discovery retains workspace" base_path observed_base
      | _, Error error -> fail (Outbox.error_to_string error) in
    require_returned (fresh_round ());
    let require_original () =
      match queued_results ~base_path ~keeper_name:"alpha" with
      | [_, completion] ->
          check string "exact original request reaches its submitter"
            original.request_id completion.Event_queue.cc_request_id;
          check string "original composition producer is retained"
            composition_tool completion.cc_tool;
          (match completion.cc_terminal with
           | Event_queue.Composition_succeeded -> ()
           | Composition_failed _ | Composition_cancelled _ ->
               fail "discovery changed the canonical outcome")
      | [] | _ :: _ -> fail "original completion was lost, replaced or duplicated" in
    require_original ();
    require_returned (fresh_round ());
    require_original ();
    check bool "recovery preserves canonical output, original Task and producer context" true
      (canonical () = original_proof);
    (match Outbox.discover ~base_path with
     | Error error -> fail (Outbox.error_to_string error)
     | Ok discovery ->
         (match discovery.entries with
          | [] -> () | _ :: _ -> fail "delivered original obligation was not retired");
         (match discovery.failures with
          | [name, Outbox.Invalid_obligation _] ->
              check string "partial failure keeps its original filename" damaged_name name
          | [] | _ :: _ -> fail "partial malformed obligation was hidden or reattributed"));
    check string "partial damage stays visible and unchanged"
      damaged_bytes (Fs_compat.load_file damaged_path))
;;

let rec mkdir_p path =
  if path = "" || path = "." || path = "/"
  then ()
  else if Sys.file_exists path
  then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

(* The completion path the P2 was reported on: a torn row in a partition older
   than the request must not reject the delivery of a brand-new completion.
   Before the floor existed, the strict absence scan read every partition and
   turned that unrelated damage into [Stimulus_storage_error]. *)
let an_older_torn_row_does_not_block_a_new_completion () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:submitter;
    let base_path = config.Workspace.base_path in
    let dir =
      Filename.concat
        (Masc.Keeper_reaction_ledger.store_dir ~base_path ~keeper_name:submitter)
        "2020-01"
    in
    mkdir_p dir;
    Out_channel.with_open_bin
      (Filename.concat dir "01.jsonl")
      (fun oc -> output_string oc "not-json\n");
    (match
       Wake.deliver
         ~not_before:(Unix.gettimeofday ())
         ~base_path
         ~keeper_name:submitter
         ~request_id
         ~composition_tool
         ~terminal:Event_queue.Composition_succeeded
     with
     | Ok () -> ()
     | Error detail ->
       fail ("an older partition's torn row rejected a new completion: " ^ detail));
    match queued_results ~base_path ~keeper_name:submitter with
    | [ _, completion ] ->
      check string "the new completion is delivered" request_id completion.cc_request_id
    | _ -> fail "older ledger damage lost or duplicated the completion")
;;

let () =
  run
    "keeper composition completion wake"
    [ ( "delivery"
      , [ test_case "the result reaches the submitter" `Quick
            the_result_reaches_the_submitter
        ; test_case "delivery recovers without replay or repeated consumption" `Quick
            completion_delivery_recovers_without_replaying_or_reconsuming
        ; test_case "independent completion owners retain original proof and fresh authority" `Quick
            independent_completion_owners_keep_original_proofs
        ; test_case "async discovery failure preserves original completion and partial damage" `Quick
            discovery_failure_retains_original_completion_and_recovers_with_partial_damage
        ; test_case "a failure carries its detail" `Quick a_failure_carries_its_detail
        ; test_case "the same result arrives once" `Quick the_same_result_arrives_once
        ; test_case "conflicting results preserve the original" `Quick
            conflicting_results_leave_the_original_delivery
        ; test_case "uncertain queue durability cannot acknowledge delivery" `Quick
            uncertain_queue_durability_does_not_acknowledge_delivery
        ; test_case "an older torn ledger row does not block a new completion" `Quick
            an_older_torn_row_does_not_block_a_new_completion
        ] )
    ; ( "the turn"
      , [ test_case "can read the result" `Quick the_turn_can_read_the_result
        ; test_case "the prompt row says what settled" `Quick
            the_prompt_row_says_what_settled
        ; test_case "the result survives a round trip" `Quick
            the_result_survives_a_round_trip
        ; test_case "large exports remain exact references" `Quick
            a_large_export_remains_an_exact_reference
        ; test_case "partial failure preserves available results and unknown effects" `Quick
            partial_failure_is_visible_with_the_available_result
        ; test_case "missing or inconsistent result remains explicit" `Quick
            missing_or_inconsistent_result_is_explicit
        ; test_case "another Keeper cannot read a result" `Quick
            another_keeper_cannot_read_the_result
        ] )
    ; ( "ordering"
      , [ test_case "a result is read before the Board backlog" `Quick
            a_result_is_read_before_the_board_backlog
        ] )
    ; ( "settlement"
      , [ test_case "every settled status is announced" `Quick
            every_settled_status_is_announced
        ; test_case "a non-durable settlement is not announced" `Quick
            a_non_durable_settlement_is_not_announced
        ] )
    ]
;;
