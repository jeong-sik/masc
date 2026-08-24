(** A delegated turn's answer reaches the Keeper that asked for it.

    [masc_keeper_delegate] hands back an operation id and returns. Over
    2026-08-17..24 the live workspace recorded 4 delegations started, 0 reads
    of [masc_keeper_delegate_status], and 10 cancels: every answer was written
    somewhere the asker never looked.

    These tests drive [deliver] against a real workspace and read the asker's
    durable queue, so an answer that stops at the enqueue boundary is a
    failure. They also project the queued answer the way a turn does, because
    an answer the Keeper is woken for but cannot read is the same loss with an
    extra wake. *)

open Alcotest
module Workspace = Masc.Workspace
module Keeper_meta_store = Masc.Keeper_meta_store
module Wake = Masc.Keeper_delegate_completion_wake
module Ops = Masc.Keeper_tool_surface_ops
module Keeper_registry = Masc.Keeper_registry
module Event_queue = Keeper_event_queue
module WO = Masc.Keeper_world_observation

let asker = "alpha"
let delegate = "beta"
let operation_id = "kmsg-0001"

let with_workspace f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc_delegate_wake_%d_%d"
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
            ; "agent_name", `String ("keeper-" ^ keeper_name ^ "-agent")
            ; "autoboot_enabled", `Bool false
            ])
    with
    | Ok meta -> meta
    | Error err -> fail ("keeper meta fixture failed: " ^ err)
  in
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok _ -> ()
   | Error err -> fail ("write keeper meta failed: " ^ err));
  (* Registry membership, not the meta file, is what [delegate_continuation_channel]
     reads: the question it asks is whether this caller owns a queue somebody
     drains, and a Keeper calling the tool from its own turn is up. *)
  ignore
    (Keeper_registry.register_offline
       ~base_path:config.Workspace.base_path
       keeper_name
       meta
     : Keeper_registry.registry_entry)
;;

let queued_answers ~base_path ~keeper_name =
  match Keeper_event_queue_persistence.load_result ~base_path ~keeper_name with
  | Error detail -> fail ("event queue load failed: " ^ detail)
  | Ok queue ->
    Event_queue.to_list queue
    |> List.filter_map (fun (stimulus : Event_queue.stimulus) ->
      match stimulus.payload with
      | Event_queue.Delegate_completed completion -> Some (stimulus, completion)
      | Event_queue.Board_signal _
      | Event_queue.Board_attention _
      | Event_queue.Bootstrap
      | Event_queue.Fusion_completed _
      | Event_queue.Schedule_due _
      | Event_queue.Connector_attention _
      | Event_queue.Hitl_resolved _
      | Event_queue.Manual_compaction_requested
      | Event_queue.Completion_authority_rejected _
      | Event_queue.Task_cancelled _
      | Event_queue.Workspace_message _ -> None)
;;

let deliver_or_fail config ~terminal =
  match
    Wake.deliver
      ~base_path:config.Workspace.base_path
      ~asked_by:asker
      ~operation_id
      ~delegate
      ~terminal
  with
  | Ok () -> ()
  | Error detail -> fail ("deliver failed: " ^ detail)
;;

(* The whole point of the change: the reply lands on the asker's queue, not
   the delegate's, and it carries the text rather than a pointer the asker
   would have to go read. *)
let reply_reaches_the_asker () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:asker;
    ensure_keeper config ~keeper_name:delegate;
    deliver_or_fail config ~terminal:(Event_queue.Delegate_replied "the answer");
    let base_path = config.Workspace.base_path in
    (match queued_answers ~base_path ~keeper_name:asker with
     | [ (stimulus, completion) ] ->
       check
         string
         "the answer is keyed on the operation the asker holds"
         ("keeper-delegate:" ^ operation_id)
         stimulus.post_id;
       check string "the answer names who ran the turn" delegate completion.dc_keeper;
       check
         string
         "the answer correlates to the asker's own operation id"
         operation_id
         completion.dc_operation_id;
       (match completion.dc_terminal with
        | Event_queue.Delegate_replied reply ->
          check string "the reply text travels with the wake" "the answer" reply
        | Event_queue.Delegate_no_reply | Event_queue.Delegate_failed _ ->
          fail "a reply must arrive as Delegate_replied")
     | [] -> fail "the asker's queue holds no answer"
     | _ :: _ :: _ -> fail "one delegation produced more than one answer");
    check
      int
      "the Keeper that ran the turn is not told about its own answer"
      0
      (List.length (queued_answers ~base_path ~keeper_name:delegate)))
;;

(* A failure is as much an answer as a reply: the asker stops waiting either
   way, so the detail has to survive the trip. *)
let failure_reaches_the_asker () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:asker;
    deliver_or_fail config ~terminal:(Event_queue.Delegate_failed "provider timed out");
    match queued_answers ~base_path:config.Workspace.base_path ~keeper_name:asker with
    | [ (_, { dc_terminal = Event_queue.Delegate_failed detail; _ }) ] ->
      check string "the failure detail travels with the wake" "provider timed out" detail
    | _ -> fail "a failed delegation must arrive as Delegate_failed")
;;

(* Redelivery of the same answer collapses onto the entry already queued: the
   operation id is the whole key, so a replay does not wake the asker twice
   about one request. *)
let the_same_answer_arrives_once () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:asker;
    let terminal = Event_queue.Delegate_replied "the answer" in
    deliver_or_fail config ~terminal;
    deliver_or_fail config ~terminal;
    check
      int
      "a replayed answer does not queue a second time"
      1
      (List.length
         (queued_answers ~base_path:config.Workspace.base_path ~keeper_name:asker)))
;;

(* The wake is only worth anything if the turn can read what arrived. This is
   the arm that decides it: the answer has no Board post behind its id, and
   the block that renders a row's title and preview is the Board Activity one.
   Routed anywhere else the Keeper wakes with nothing to read. *)
let the_turn_can_read_the_answer () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:asker;
    deliver_or_fail config ~terminal:(Event_queue.Delegate_replied "the answer");
    match queued_answers ~base_path:config.Workspace.base_path ~keeper_name:asker with
    | [ (stimulus, _) ] ->
      let meta =
        match Keeper_meta_store.read_meta config asker with
        | Ok (Some meta) -> meta
        | Ok None -> fail "the asker has no meta"
        | Error err -> fail ("meta load failed: " ^ err)
      in
      (match WO.pending_board_event_of_stimulus ~meta stimulus with
       | Error _ -> fail "the answer must project without a Board read"
       | Ok None -> fail "the answer projects to nothing the turn can read"
       | Ok (Some event) ->
         check
           bool
           "the answer reaches the block that renders its title and preview"
           true
           (WO.is_board_activity_event event);
         check string "the row is attributed to the Keeper that answered" delegate
           event.WO.author;
         check
           bool
           "the reply text is what the turn reads"
           true
           (String.equal event.WO.preview "the answer"))
    | _ -> fail "the asker's queue holds no answer")
;;

(* The queue is durable, so an answer that cannot be read back is lost on the
   next restart — silently, because the reader has no other copy. *)
let the_answer_survives_a_round_trip () =
  List.iter
    (fun terminal ->
       let completion =
         { Event_queue.dc_operation_id = operation_id
         ; dc_keeper = delegate
         ; dc_terminal = terminal
         }
       in
       let stimulus : Event_queue.stimulus =
         { Event_queue.post_id = Event_queue.delegate_completion_post_id completion
         ; urgency = Event_queue.Normal
         ; arrived_at = 1.0
         ; payload = Event_queue.Delegate_completed completion
         }
       in
       match Event_queue.stimulus_of_yojson (Event_queue.stimulus_to_yojson stimulus) with
       | Error detail -> fail ("the answer cannot be read back: " ^ detail)
       | Ok decoded ->
         check
           bool
           "the answer is the same after a round trip"
           true
           (Event_queue.stimulus_identity_equal decoded stimulus))
    [ Event_queue.Delegate_replied "the answer"
    ; Event_queue.Delegate_no_reply
    ; Event_queue.Delegate_failed "provider timed out"
    ]
;;

(* Who reads the reply decides where it goes. A Keeper reads its own queue; an
   operator driving the tool over HTTP is watching the dashboard, and sending
   its answer to a queue no Keeper owns would leave it undrained. *)
let only_a_keeper_is_answered_on_its_queue () =
  with_workspace (fun config ->
    ensure_keeper config ~keeper_name:asker;
    (match Ops.delegate_continuation_channel ~config ~submitted_by:asker with
     | Some (Keeper_continuation_channel.Keeper { keeper_name }) ->
       check string "a Keeper is answered on its own queue" asker keeper_name
     | Some other ->
       fail
         ("a Keeper must be answered on its own queue, got "
          ^ Keeper_continuation_channel.kind_label other)
     | None -> fail "a Keeper must be answered on its own queue");
    check
      bool
      "a caller that owns no queue keeps the channel it is watching"
      true
      (Option.is_none
         (Ops.delegate_continuation_channel ~config ~submitted_by:"operator")))
;;

let () =
  run
    "keeper delegate completion wake"
    [ ( "delivery"
      , [ test_case "the reply reaches the asker" `Quick reply_reaches_the_asker
        ; test_case "a failure reaches the asker" `Quick failure_reaches_the_asker
        ; test_case "the same answer arrives once" `Quick the_same_answer_arrives_once
        ] )
    ; ( "readability"
      , [ test_case "the turn can read the answer" `Quick the_turn_can_read_the_answer
        ; test_case
            "the answer survives a round trip"
            `Quick
            the_answer_survives_a_round_trip
        ] )
    ; ( "routing"
      , [ test_case
            "only a Keeper is answered on its queue"
            `Quick
            only_a_keeper_is_answered_on_its_queue
        ] )
    ]
;;
