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
let composition_tool = "keeper_compose_background-snapshot"

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
            ; "autoboot_enabled", `Bool false
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
      | Event_queue.Manual_compaction_requested
      | Event_queue.Completion_authority_rejected _
      | Event_queue.Task_cancelled _
      | Event_queue.Workspace_message _
      | Event_queue.Delegate_completed _ -> None)
;;

let deliver_or_fail config ~terminal =
  match
    Wake.deliver
      ~base_path:config.Workspace.base_path
      ~keeper_name:submitter
      ~request_id
      ~composition_tool
      ~terminal
  with
  | Ok () -> ()
  | Error detail -> fail ("deliver failed: " ^ detail)
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
      ~terminal:(Event_queue.Composition_failed "node board: store unavailable");
    match
      queued_results ~base_path:config.Workspace.base_path ~keeper_name:submitter
    with
    | [ (_, { cc_terminal = Event_queue.Composition_failed detail; _ }) ] ->
      check
        string
        "the failure detail travels with the wake"
        "node board: store unavailable"
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

(* The wake is only worth anything if the turn can read what arrived. The
   result has no Board post behind its id, and the block that renders a row's
   title and preview is the Board Activity one; routed anywhere else the
   Keeper wakes with nothing to read. *)
let the_turn_can_read_the_result () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:submitter;
    deliver_or_fail
      config
      ~terminal:(Event_queue.Composition_failed "node clock: timed out");
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
      (match WO.pending_board_event_of_stimulus ~meta stimulus with
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
         check
           bool
           "the failure detail is what the turn reads"
           true
           (String.equal event.WO.preview "node clock: timed out"))
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
      (match WO.pending_board_event_of_stimulus ~meta stimulus with
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
         (* No preview on success: the result is in the async request record,
            and the id to read it with is in the title above. Same as
            Delegate_no_reply, which also has no text to show. *)
         check string "a success shows no body" "" (field "preview")
       | Ok None -> fail "the result projects to nothing the turn can read"
       | Error _ -> fail "the result must project without a Board read")
    | _ -> fail "the submitter's queue holds no result")
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
      (match Keeper_event_queue_state.select_when ~ready:(fun _ -> true) state with
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
        , Async.Persistence_failed { attempted_status = "done"; reason = "disk full" } )
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

let () =
  run
    "keeper composition completion wake"
    [ ( "delivery"
      , [ test_case "the result reaches the submitter" `Quick
            the_result_reaches_the_submitter
        ; test_case "a failure carries its detail" `Quick a_failure_carries_its_detail
        ; test_case "the same result arrives once" `Quick the_same_result_arrives_once
        ] )
    ; ( "the turn"
      , [ test_case "can read the result" `Quick the_turn_can_read_the_result
        ; test_case "the prompt row says what settled" `Quick
            the_prompt_row_says_what_settled
        ; test_case "the result survives a round trip" `Quick
            the_result_survives_a_round_trip
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
