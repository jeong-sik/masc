(* Board-unavailable-result — keeper_world_observation_board_signal's
   [Board_unavailable] exception (and [raise_unavailable]) were removed in
   favor of an explicit [(_, board_unavailable) result] contract.

   Incident this replaces: [Board_dispatch.get_post] returning
   [Post_not_found] (a post swept from the in-memory store — permanent) was
   modeled as a transient exception. Nothing on the stimulus-intake path
   caught it, so it crashed the keeper heartbeat cycle via the generic
   handler in [keeper_heartbeat_loop.ml], the lease was requeued as
   [Cycle_crashed], and the SAME poisoned stimulus re-crashed every
   heartbeat forever.

   These tests pin:
   1. the incident's exact shape (a stimulus naming a post_id that was never
      created) does not raise, is reported as [Error unavailable] naming the
      missing post, and the stimulus-intake layer consumes it without
      crashing — stable across a second pass.
   2. a source that renders no observation still spends an admission slot,
      and a missing post does not.
   3. a queued comment keeps its own author and body after later replies.
   4. Board replay routes exact replies instead of historical participation. *)

open Alcotest
open Masc

(* These tests check how the Board routes a text, not who is declared: every
   name with the shape of a Keeper name stands for itself. *)
let every_name_declared =
  Recipient_lookup.make (fun candidate ->
    Ok
      (Result.to_option
         (Board.Agent_id.parse (Recipient_lookup.Candidate.to_string candidate))))
;;

let () = Mirage_crypto_rng_unix.use_default ()
let () = Random.self_init ()

(** Temp directory for test isolation — set before any Board.global call
    (mirrors test_board_dispatch.ml's [fresh_test_base_path]). *)
let fresh_test_base_path () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-board-unavailable-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir
;;

let with_eio f () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ignore (fresh_test_base_path ());
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ~recipient_lookup:every_name_declared ();
  f ()
;;

let test_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String name
         ; "trace_id", `String ("trace-" ^ name)
         ])
  with
  | Ok meta -> meta
  | Error message -> Alcotest.failf "test meta failed: %s" message
;;

let poison_post_id = "nonexistent-post-poison-test"

(* A [Board_signal] stimulus naming a post_id that was never created in this
   test's isolated JSONL store — the exact shape of the reported incident
   (post swept from the store between the signal firing and the keeper
   consuming it). *)
let poison_board_signal_stimulus () : Keeper_event_queue.stimulus =
  { Keeper_event_queue.post_id = poison_post_id
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = Time_compat.now ()
  ; payload =
      Keeper_event_queue.Board_signal
        { kind = Keeper_event_queue.Post_created
        ; author = "external-author"
        ; title = "poison stimulus"
        ; content = "references a post_id that was never created"
        ; hearth = None
        ; updated_at = Some (Time_compat.now ())
        }
  }
;;

(* (1) [pending_board_event_of_stimulus] must report the failed board read
   as [Error unavailable] — never raise — naming the missing post, the
   dominant real crash-loop cause. *)
let test_poison_stimulus_reports_permanent_error () =
  let meta = test_meta "poison-report" in
  match
    Keeper_world_observation.pending_board_event_of_stimulus ~base_path:(Sys.getenv "MASC_BASE_PATH")
      ~meta
      (poison_board_signal_stimulus ())
  with
  | Ok _ -> fail "a stimulus naming a nonexistent post must not resolve to Ok"
  | Error unavailable ->
    check
      bool
      "post_id names the missing post"
      true
      (String.equal
         unavailable.Keeper_world_observation_board_signal.post_id
         poison_post_id);
    check
      bool
      "answers that the post is missing (masc keeper-cycle-exception incident cause)"
      true
      (unavailable.Keeper_world_observation_board_signal.error
       = Board.Read_post_not_found poison_post_id)
;;

(* (1) The stimulus-intake layer is where the crash actually happened:
   [Board_signal.raise_unavailable] propagated past every catch site up to
   [keeper_heartbeat_loop.ml]'s generic exception handler, which requeued
   the lease as [Cycle_crashed] — so the SAME poisoned stimulus re-crashed
   the keeper heartbeat every cycle forever. This pins the fix: the intake
   helper must not raise, must return [], and a second pass over the same
   stimulus (simulating the next heartbeat cycle re-leasing the same
   durable stimulus) must ALSO return [] — the counterfactual for the old
   loop, which would have crashed again here instead. *)
let test_poison_stimulus_intake_does_not_crash_and_stays_dropped () =
  let meta = test_meta "poison-intake" in
  let stim = poison_board_signal_stimulus () in
  let first_pass =
    Keeper_heartbeat_stimulus_intake.pending_board_events_of_stimulus_result ~base_path:(Sys.getenv "MASC_BASE_PATH")
      ~meta_after_triage:meta
      stim
  in
  (match first_pass with
   | Keeper_heartbeat_stimulus_intake.Stimulus_consumed events ->
     check
       int
       "first pass produces no pending_board_event (consumed, not crashed)"
       0
       (List.length events)
   | Keeper_heartbeat_stimulus_intake.Stimulus_connector_retry_later _
   | Keeper_heartbeat_stimulus_intake.Stimulus_connector_missing _
   | Keeper_heartbeat_stimulus_intake.Stimulus_ask_retry_later _
   | Keeper_heartbeat_stimulus_intake.Stimulus_ask_missing _
   | Keeper_heartbeat_stimulus_intake.Stimulus_job_unavailable _
   | Keeper_heartbeat_stimulus_intake.Stimulus_addon_unavailable _
   | Keeper_heartbeat_stimulus_intake.Stimulus_completion_rejection_obsolete
   | Keeper_heartbeat_stimulus_intake.Stimulus_completion_rejection_retry_later _
   | Keeper_heartbeat_stimulus_intake.Stimulus_ask_not_answered _ ->
     fail "Board source reported another source's read failure");
  let second_pass =
    Keeper_heartbeat_stimulus_intake.pending_board_events_of_stimulus_result ~base_path:(Sys.getenv "MASC_BASE_PATH")
      ~meta_after_triage:meta
      stim
  in
  match second_pass with
  | Keeper_heartbeat_stimulus_intake.Stimulus_consumed events ->
    check
      int
      "second pass over the same stimulus stays empty (no crash-loop resurgence)"
      0
      (List.length events)
  | Keeper_heartbeat_stimulus_intake.Stimulus_connector_retry_later _
   | Keeper_heartbeat_stimulus_intake.Stimulus_connector_missing _
   | Keeper_heartbeat_stimulus_intake.Stimulus_ask_retry_later _
   | Keeper_heartbeat_stimulus_intake.Stimulus_ask_missing _
   | Keeper_heartbeat_stimulus_intake.Stimulus_job_unavailable _
   | Keeper_heartbeat_stimulus_intake.Stimulus_addon_unavailable _
   | Keeper_heartbeat_stimulus_intake.Stimulus_completion_rejection_obsolete
   | Keeper_heartbeat_stimulus_intake.Stimulus_completion_rejection_retry_later _
   | Keeper_heartbeat_stimulus_intake.Stimulus_ask_not_answered _ ->
    fail "Board source reported another source's read failure"
;;

let test_poison_durable_source_is_retired_during_intake () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run
  @@ fun sw ->
  let base_path = fresh_test_base_path () in
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ~recipient_lookup:every_name_declared ();
  Keeper_registry.For_testing.clear ();
  Fun.protect
    ~finally:(fun () -> Keeper_registry.For_testing.clear ())
  @@ fun () ->
  let meta = test_meta "poison-durable" in
  let config = Workspace.default_config base_path in
  let ctx : _ Keeper_types_profile.context =
    { config
    ; agent_name = "board-unavailable-test"
    ; sw
    ; clock = Eio.Stdenv.clock env
    ; proc_mgr = None
    ; net = None
    ; publication_recovery_provider =
        Masc_test_deps.non_runtime_publication_recovery_provider
    }
  in
  ignore (Keeper_registry.For_testing.register ~base_path meta.name meta);
  let stimulus = poison_board_signal_stimulus () in
  (match
     Keeper_registry_event_queue.enqueue_durable_result
       ~base_path
       meta.name
       stimulus
   with
   | Ok () -> ()
   | Error message -> failf "failed to seed durable poison: %s" message);
  let intake =
    Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx
      ~meta_after_triage:meta
      ~pending_board_events:[]
  in
  check int "no empty source is offered to a provider turn" 0
    (Keeper_heartbeat_source_batch.count intake.source_batch);
  check int "no fabricated Board observation is returned" 0
    (List.length intake.pending_board_events);
  check bool "permanent retirement is not an intake error" true
    (Option.is_none intake.event_queue_intake_error);
  let queued =
    match Keeper_registry_event_queue.snapshot_result ~base_path meta.name with
    | Ok queue -> queue
    | Error message -> failf "failed to reload durable queue: %s" message
  in
  check int "the permanently unavailable durable source is acknowledged" 0
    (Keeper_event_queue.length queued)
;;

(* Actual Board and durable queue stores. The configured admission limit bounds
   the sources carried by one turn; these cases do not run a provider or claim
   that a full Keeper turn completed. *)
let with_intake_sources ~max_events f =
  Masc_test_deps.with_process_env "MASC_KEEPER_ADMISSION_MAX_EVENTS"
    (Some (string_of_int max_events))
  @@ fun () ->
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run
  @@ fun sw ->
  let base_path = fresh_test_base_path () in
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ~recipient_lookup:every_name_declared ();
  Keeper_registry.For_testing.clear ();
  Fun.protect
    ~finally:(fun () -> Keeper_registry.For_testing.clear ())
  @@ fun () ->
  let meta = test_meta "intake-sources" in
  let config = Workspace.default_config base_path in
  let ctx : _ Keeper_types_profile.context =
    { config
    ; agent_name = "board-unavailable-test"
    ; sw
    ; clock = Eio.Stdenv.clock env
    ; proc_mgr = None
    ; net = None
    ; publication_recovery_provider =
        Masc_test_deps.non_runtime_publication_recovery_provider
    }
  in
  ignore (Keeper_registry.For_testing.register ~base_path meta.name meta);
  let create_source label =
    match
      Board_dispatch.create_post ~author:"external-author" ~content:label
        ~post_kind:Board.Human_post ~visibility:Board.Internal ()
    with
    | Ok post -> Board.Post_id.to_string post.id
    | Error error -> failf "failed to create Board source: %s" (Board.show_board_error error)
  in
  let seed stimulus =
    match Keeper_registry_event_queue.enqueue_durable_result ~base_path meta.name stimulus with
    | Ok () -> ()
    | Error message -> failf "failed to seed durable stimulus: %s" message
  in
  let seed_board label =
    let post_id = create_source label in
    seed { (poison_board_signal_stimulus ()) with post_id };
    post_id
  in
  let intake () =
    Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[]
  in
  let pending () =
    match Keeper_registry_event_queue.pending_selections_result ~base_path meta.name with
    | Ok selections -> selections
    | Error message -> failf "failed to reload durable selections: %s" message
  in
  let ack selection =
    match Keeper_registry_event_queue.ack_pending_result ~base_path meta.name ~selection with
    | Ok () -> ()
    | Error message -> failf "failed to acknowledge selected source: %s" message
  in
  f ~seed ~seed_board ~intake ~pending ~ack
;;

let admitted_ids intake =
  Keeper_heartbeat_source_batch.stimuli intake.Keeper_heartbeat_stimulus_intake.source_batch
  |> List.map (fun (stimulus : Keeper_event_queue.stimulus) -> stimulus.post_id)
;;

let test_empty_observation_source_still_spends_an_admission_slot () =
  with_intake_sources ~max_events:1 @@ fun ~seed ~seed_board ~intake ~pending:_ ~ack:_ ->
  let bootstrap =
    { (poison_board_signal_stimulus ()) with
      post_id = "bootstrap-limit"; payload = Keeper_event_queue.Bootstrap }
  in
  seed bootstrap;
  let (_ : string) = seed_board "must not join the Bootstrap turn at limit1" in
  let selected = intake () in
  check (list string) "Bootstrap is admitted despite producing no Board observation"
    [ bootstrap.post_id ] (admitted_ids selected);
  check int "the later source was not rendered" 0 (List.length selected.pending_board_events)
;;

let test_permanent_absence_does_not_spend_an_admission_slot () =
  with_intake_sources ~max_events:1 @@ fun ~seed ~seed_board ~intake ~pending ~ack:_ ->
  seed (poison_board_signal_stimulus ());
  let readable = seed_board "readable source after permanently absent post" in
  let selected = intake () in
  check (list string) "a retired poison does not block a readable source"
    [ readable ] (admitted_ids selected);
  check int "only permanent absence is ACKed during intake" 1 (List.length (pending ()))
;;

let rejection_ok = function Ok value -> value | Error detail -> fail detail

let rejection_workspace_ok = function
  | Ok value -> value
  | Error error -> fail (Masc_domain.masc_error_to_string error)

let prepare_intake_rejection () =
  let config = Workspace.default_config (Sys.getenv "MASC_BASE_PATH") in
  let producer = "intake-sources" in
  let verification_id = "vrf-intake-original" in
  let reason = "submitted evidence does not prove the requested result" in
  let authority = Masc_domain.System_llm_agent {agent_run_id="intake-verifier"} in
  ignore (Workspace.init config ~agent_name:(Some producer));
  ignore (Workspace.add_task config ~title:"repair rejected work" ~priority:1
    ~description:"exercise the durable rejection consumer boundary");
  let backlog = rejection_ok (Workspace_backlog.read_backlog_r config) in
  let task_id = match backlog.tasks with
    | [task] -> task.Masc_domain.id
    | [] | _ :: _ :: _ -> fail "expected one Task" in
  let tasks = List.map (fun (task : Masc_domain.task) ->
    {task with task_status=Masc_domain.AwaitingVerification
      {assignee=producer; started_at="2026-10-23T00:00:00Z";
       submitted_at=Masc_domain.now_iso (); verification_id}}) backlog.tasks in
  Workspace.write_backlog config {backlog with tasks};
  ignore (rejection_workspace_ok (Workspace.commit_verdict_r config ~authority
    ~verdict:(Masc_domain.Verdict_rejected {reason}) ~task_id ~verification_id ()));
  let rejection : Keeper_event_queue.completion_authority_rejection =
    {car_task_id=task_id; car_verification_id=verification_id;
     car_reason=reason; car_authority=authority} in
  let stimulus =
    { (poison_board_signal_stimulus ()) with
      post_id=Keeper_event_queue.completion_authority_rejection_post_id rejection;
      payload=Keeper_event_queue.Completion_authority_rejected rejection } in
  config, task_id, verification_id, stimulus
;;

let test_delivered_rejection_remains_current_at_intake () =
  with_intake_sources ~max_events:1 @@ fun ~seed ~seed_board:_ ~intake ~pending ~ack:_ ->
  let config,task_id,verification_id,stimulus = prepare_intake_rejection () in
  seed stimulus;
  rejection_ok (Workspace_task_rejection_outbox.acknowledge config ~task_id ~verification_id);
  let selected = intake () in
  check (list string) "delivery ACK retains current consumer authority"
    [stimulus.post_id] (admitted_ids selected);
  check int "current rejection is projected" 1 (List.length selected.pending_board_events);
  check int "current rejection carries its turn trigger" 1 (List.length selected.event_queue_triggers);
  check int "admission leaves the exact queue source for turn settlement" 1 (List.length (pending ()))
;;

let test_superseded_rejection_is_retired_before_projection () =
  with_intake_sources ~max_events:1 @@ fun ~seed ~seed_board ~intake ~pending ~ack:_ ->
  let config,task_id,_verification_id,stimulus = prepare_intake_rejection () in
  seed stimulus;
  ignore (rejection_workspace_ok (Workspace.transition_task_r config
    ~agent_name:"intake-sources" ~task_id ~action:Masc_domain.Submit_for_verification
    ~prepare_verification_request:(fun ~task ~assignee ~verification_id ~claim:_ ->
      Verification.create_request ~base_path:config.base_path ~request_id:verification_id
        ~task_id:task.Masc_domain.id ~output:(`Assoc []) ~criteria:[] ~worker:assignee ()
      |> Result.map (fun _ -> ()))
    ~notes:"note:repaired the evidence and resubmitted" ()));
  let path = Workspace_backlog.backlog_path config in
  let fields = Yojson.Safe.from_file path |> Yojson.Safe.Util.to_assoc in
  Yojson.Safe.to_file path (`Assoc (List.remove_assoc "delivered_completion_rejections" fields));
  let before = rejection_ok (Workspace_backlog.read_backlog_r config) in
  let readable = seed_board "independent work after superseded rejection" in
  let selected = intake () in
  check (list string) "obsolete rejection spends no admission slot" [readable] (admitted_ids selected);
  check int "obsolete rejection has no turn trigger" 0 (List.length selected.event_queue_triggers);
  check int "only independent work remains queued" 1 (List.length (pending ()));
  let after = rejection_ok (Workspace_backlog.read_backlog_r config) in
  check bool "stale queue ACK cannot change the newer submission" true (before=after)
;;

let test_missing_or_malformed_delivered_evidence_preserves_active_rejection () =
  List.iter (fun malformed ->
    with_intake_sources ~max_events:1 @@ fun ~seed ~seed_board ~intake ~pending ~ack:_ ->
    let config,task_id,verification_id,stimulus = prepare_intake_rejection () in
    seed stimulus;
    rejection_ok (Workspace_task_rejection_outbox.acknowledge config ~task_id ~verification_id);
    let path = Workspace_backlog.backlog_path config in
    let fields = Yojson.Safe.from_file path |> Yojson.Safe.Util.to_assoc
      |> List.remove_assoc "delivered_completion_rejections" in
    let document = `Assoc (if malformed then ("delivered_completion_rejections",`Null)::fields else fields) in
    Yojson.Safe.to_file path document;
    let before = In_channel.with_open_text path In_channel.input_all in
    let readable = seed_board "independent source after uncertain old rejection" in
    let selected = intake () in
    check (list string) "uncertain rejection grants no admission but allows independent work"
      [readable] (admitted_ids selected);
    check int "uncertain rejection has no trigger" 0 (List.length selected.event_queue_triggers);
    check int "old A and independent source both remain queued" 2 (List.length (pending ()));
    check string "missing or corrupt evidence never rewrites authority" before
      (In_channel.with_open_text path In_channel.input_all);
    match selected.event_queue_intake_error with
    | Some (Keeper_heartbeat_stimulus_intake.Completion_rejection_read_failed _ as error) ->
      check bool "uncertain evidence is typed retry, not cycle failure" false
        (Keeper_heartbeat_stimulus_intake.event_queue_intake_error_counts_as_cycle_failure error)
    | None | Some _ -> fail "uncertain old rejection lost its retry outcome") [false;true]
;;

let test_unread_rejection_authority_retains_source_and_allows_siblings () =
  with_intake_sources ~max_events:1 @@ fun ~seed ~seed_board ~intake ~pending ~ack:_ ->
  let config,_task_id,_verification_id,stimulus = prepare_intake_rejection () in
  seed stimulus;
  let readable = seed_board "independent work after unread rejection authority" in
  let path = Workspace_backlog.backlog_path config in
  let corrupt = "not an authoritative backlog\n" in
  Out_channel.with_open_text path (fun out -> output_string out corrupt);
  let selected = intake () in
  check (list string) "unread authority does not block independent sources" [readable] (admitted_ids selected);
  check int "unread rejection is not projected" 1 (List.length selected.pending_board_events);
  check int "unread rejection adds no trigger" 0 (List.length selected.event_queue_triggers);
  check int "both exact queue sources remain pending" 2 (List.length (pending ()));
  check string "unread primary bytes are preserved" corrupt (In_channel.with_open_text path In_channel.input_all);
  match selected.event_queue_intake_error with
  | Some (Keeper_heartbeat_stimulus_intake.Completion_rejection_read_failed _ as error) ->
    check bool "authority read failure is retry, not a crashed cycle" false
      (Keeper_heartbeat_stimulus_intake.event_queue_intake_error_counts_as_cycle_failure error)
  | None | Some (Keeper_heartbeat_stimulus_intake.Pending_selection_failed _
      | Keeper_heartbeat_stimulus_intake.Connector_read_failed _
      | Keeper_heartbeat_stimulus_intake.Connector_item_missing _
      | Keeper_heartbeat_stimulus_intake.Ask_read_failed _
      | Keeper_heartbeat_stimulus_intake.Job_result_unavailable _
      | Keeper_heartbeat_stimulus_intake.Addon_result_unavailable _) ->
    fail "unread canonical authority lost its typed retry outcome"
;;

(* Comments are ordered by [created_at], and by random id when two share it,
   so each post and comment lands strictly after the one before to keep the
   thread in the order this test writes it. *)
let write_spacing_seconds = 0.01

let create_thread ~title content =
  Unix.sleepf write_spacing_seconds;
  match
    Board_dispatch.create_post
      ~author:"external-author"
      ~content
      ~title
      ~post_kind:Board.Human_post
      ()
  with
  | Ok post -> Board.Post_id.to_string post.id
  | Error error -> failf "post: %s" (Board.show_board_error error)
;;

let add_comment ~post_id ~author content =
  Unix.sleepf write_spacing_seconds;
  match Board_dispatch.add_comment ~post_id ~author ~content () with
  | Ok comment -> Board.Comment_id.to_string comment.id
  | Error error -> failf "comment: %s" (Board.show_board_error error)
;;

let comment_event ~meta ~post_id ~comment_id ~author content =
  let stimulus : Keeper_event_queue.stimulus =
    { Keeper_event_queue.post_id
    ; urgency = Keeper_event_queue.Normal
    ; arrived_at = Time_compat.now ()
    ; payload =
        Keeper_event_queue.Board_signal
          { kind = Keeper_event_queue.Comment_added { comment_id; parent_id = None }
          ; author
          ; title = "thread"
          ; content
          ; hearth = None
          ; updated_at = Some (Time_compat.now ())
          }
    }
  in
  match Keeper_world_observation.pending_board_event_of_stimulus ~base_path:(Sys.getenv "MASC_BASE_PATH") ~meta stimulus with
  | Error unavailable ->
    failf
      "comment event read failed: %s"
      (Keeper_world_observation_board_signal.unavailable_to_string unavailable)
  | Ok None -> fail "a comment stimulus produced no event"
  | Ok (Some event) -> event
;;

let test_queued_comment_keeps_its_author_and_body () =
  let meta = test_meta "queued-reader" in
  let post_id = create_thread ~title:"thread" "thread topic" in
  ignore (add_comment ~post_id ~author:meta.name "earlier participation" : string);
  let first = add_comment ~post_id ~author:"first-author" "first reply" in
  ignore (add_comment ~post_id ~author:"later-author" "later reply" : string);
  let event = comment_event ~meta ~post_id ~comment_id:first ~author:"first-author" "first reply" in
  check (option string) "queued author" (Some "first-author") event.latest_external_author;
  check (option string) "queued body" (Some "first reply") event.latest_external_preview;
  check bool "unrelated later replies are not attached" true
    (Option.is_none event.replies_after_own_comment)
;;

let test_board_replay_routes_exact_replies () =
  let base_path = Sys.getenv "MASC_BASE_PATH" in
  let poster = test_meta "reply-poster" in
  let parent_author = test_meta "reply-parent" in
  let bystander = test_meta "reply-bystander" in
  Keeper_registry.For_testing.clear ();
  Fun.protect ~finally:(fun () -> Keeper_registry.For_testing.clear ())
  @@ fun () ->
  let post_id =
    match Board_dispatch.create_post ~author:poster.name ~content:"thread topic"
            ~title:"thread" ~post_kind:Board.Human_post () with
    | Ok post -> Board.Post_id.to_string post.id
    | Error error -> fail (Board.show_board_error error)
  in
  let parent_id = add_comment ~post_id ~author:parent_author.name "parent comment" in
  ignore (add_comment ~post_id ~author:bystander.name "past participation" : string);
  let metas = [poster; parent_author; bystander] in
  List.iter (fun (meta : Keeper_meta_contract.keeper_meta) ->
    ignore (Keeper_registry.For_testing.register ~base_path meta.name meta);
    ignore (Keeper_world_observation.collect_board_events ~base_path ~meta)) metas;
  let collect (meta : Keeper_meta_contract.keeper_meta) =
    let snapshot () =
      match Keeper_event_queue_persistence.load_result ~base_path ~keeper_name:meta.name with
      | Ok queue -> Keeper_event_queue.to_list queue | Error detail -> fail detail in
    let before = snapshot () in
    let events, _, _ = Keeper_world_observation.collect_board_events ~base_path ~meta in
    check int "live replay uses durable queue, not ephemeral events" 0 (List.length events);
    snapshot ()
    |> List.filter (fun source ->
         not (List.exists (Keeper_event_queue.stimulus_identity_equal source) before))
    |> List.filter_map (fun source ->
         match Keeper_world_observation.pending_board_event_of_stimulus ~base_path ~meta source with
         | Ok event -> event
         | Error unavailable -> fail (Keeper_world_observation_board_signal.unavailable_to_string unavailable))
  in
  ignore (add_comment ~post_id ~author:"external" "top-level comment" : string);
  check int "post author receives top-level reply on own post" 1 (List.length (collect poster));
  check int "past parent author does not receive unrelated reply" 0 (List.length (collect parent_author));
  check int "past participant does not receive unrelated reply" 0 (List.length (collect bystander));
  Unix.sleepf write_spacing_seconds;
  (match Board_dispatch.add_comment ~post_id ~parent_id ~author:"external"
           ~content:"direct answer" () with
   | Ok _ -> () | Error error -> fail (Board.show_board_error error));
  List.iter (fun meta ->
    match collect meta with
    | [event] ->
      check (option string) "actual nested reply body" (Some "direct answer")
        event.Keeper_world_observation.latest_external_preview;
      check bool "comment event" true (match event.event_kind with Board_comment_added _ -> true | _ -> false)
    | events -> failf "expected one direct reply, got %d" (List.length events))
    [poster; parent_author];
  check int "unrelated participant still excluded" 0 (List.length (collect bystander));
  List.iter (fun meta -> check int "next tick has no repeated reply" 0
    (List.length (collect meta))) metas;
  ignore (add_comment ~post_id ~author:"external" "@reply-bystander explicit answer" : string);
  check int "explicit comment mention replays without prior-parent match" 1
    (List.length (collect bystander));
  check int "explicit audience does not turn into post-author delivery" 0
    (List.length (collect poster));
  Unix.sleepf write_spacing_seconds;
  (match Board_dispatch.update_post ~post_id ~editor:poster.name
           ~content:"@reply-bystander mention added by editing" () with
   | Ok _ -> () | Error error -> fail (Board.show_board_error error));
  check int "mention added by editing an old post replays" 1
    (List.length (collect bystander));
  ignore (add_comment ~post_id ~author:"external" "unrelated later comment" : string);
  check int "later comment does not repeat inherited post mention" 0
    (List.length (collect bystander))
;;

let test_missing_parent_comment_does_not_abort_later_comment_replay () =
  let base_path = Sys.getenv "MASC_BASE_PATH" in
  let parent_author = test_meta "replay-parent-survivor" in
  Keeper_registry.For_testing.clear ();
  Fun.protect ~finally:(fun () -> Keeper_registry.For_testing.clear ())
  @@ fun () ->
  let post_id =
    match Board_dispatch.create_post ~author:"external-poster" ~content:"thread topic"
            ~title:"thread" ~post_kind:Board.Human_post () with
    | Ok post -> Board.Post_id.to_string post.id
    | Error error -> fail (Board.show_board_error error)
  in
  let parent_id = add_comment ~post_id ~author:parent_author.name "keeper parent comment" in
  ignore (Keeper_registry.For_testing.register ~base_path parent_author.name parent_author);
  ignore (Keeper_world_observation.collect_board_events ~base_path ~meta:parent_author);
  Unix.sleepf write_spacing_seconds;
  let expired_parent_id = "c-" ^ String.make 32 '1' in
  (match Board_dispatch.add_comment ~post_id ~parent_id:expired_parent_id
           ~author:"external" ~content:"reply to expired comment" () with
   | Ok _ -> () | Error error -> fail (Board.show_board_error error));
  Unix.sleepf write_spacing_seconds;
  (match Board_dispatch.add_comment ~post_id ~parent_id
           ~author:"external" ~content:"reply after expired-parent sibling" () with
   | Ok _ -> () | Error error -> fail (Board.show_board_error error));
  let events, _, _ =
    Keeper_world_observation.collect_board_events ~base_path ~meta:parent_author
  in
  check int "live replay uses durable queue" 0 (List.length events);
  let queued =
    match Keeper_event_queue_persistence.load_result ~base_path ~keeper_name:parent_author.name with
    | Ok queue -> Keeper_event_queue.to_list queue
    | Error detail -> fail detail
  in
  check int "later reply on the same post still replays after expired-parent sibling"
    1 (List.length queued)
;;

let test_catchup_storage_failure_retains_cursor () =
  let base_path = Sys.getenv "MASC_BASE_PATH" in
  let meta = test_meta "catchup-storage" in
  ignore (Keeper_registry.For_testing.register ~base_path meta.name meta);
  Fun.protect
    ~finally:(fun () -> Keeper_registry.For_testing.unregister ~base_path meta.name)
  @@ fun () ->
  ignore (create_thread ~title:"baseline" "before cursor" : string);
  ignore (Keeper_world_observation.collect_board_events ~base_path ~meta);
  let before = Keeper_registry.get_board_cursor ~base_path meta.name in
  ignore (create_thread ~title:"addressed" "@catchup-storage preserve this" : string);
  let path = Filename.concat
      (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) meta.name)
      Keeper_event_queue_schema.snapshot_filename in
  Fs_compat.mkdir_p (Filename.dirname path);
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> if Sys.file_exists path && Sys.is_directory path then Unix.rmdir path)
    (fun () ->
      ignore (Keeper_world_observation.collect_board_events ~base_path ~meta);
      check bool "failed admission did not advance cursor" true
        (before = Keeper_registry.get_board_cursor ~base_path meta.name));
  ignore (Keeper_world_observation.collect_board_events ~base_path ~meta);
  let queue = match Keeper_event_queue_persistence.load_result ~base_path ~keeper_name:meta.name with
    | Ok queue -> queue | Error detail -> fail detail in
  check int "retry durably admits the missed event" 1 (Keeper_event_queue.length queue);
  check bool "successful admission advances cursor" true
    (before <> Keeper_registry.get_board_cursor ~base_path meta.name)
;;

(* [`Reply] queues a comment with a parent, [`Top_level] one without: the
   parent survives the queue as [Some id] and its absence as [None], so both
   sides of the optional field make the same round trip. *)
let accepted_comment_identity_survives_queue_projection ~shape () =
  let module Signal = Keeper_world_observation_board_signal in
  let post_id = create_thread ~title:"queued identity" "thread topic" in
  let parent_id =
    match shape with
    | `Reply -> Some (add_comment ~post_id ~author:"parent-author" "parent")
    | `Top_level -> None
  in
  let captured = ref None in
  Board_dispatch.set_board_signal_hook (fun addressed -> captured := Some addressed);
  Fun.protect ~finally:(fun () -> Board_dispatch.set_board_signal_hook (fun _ -> ()))
  @@ fun () ->
  let accepted =
    match Board_dispatch.add_comment ~post_id ?parent_id ~author:"reply-author"
            ~content:"the queued reply" () with
    | Ok comment -> comment
    | Error error -> fail (Board.show_board_error error)
  in
  let signal =
    match !captured with
    | Some addressed -> addressed.Board_dispatch.signal
    | None -> fail "accepted comment did not emit a signal"
  in
  let stimulus : Keeper_event_queue.stimulus =
    { post_id; urgency = Normal; arrived_at = Time_compat.now ()
    ; payload = Board_signal (Signal.board_stimulus_of_board_signal signal)
    }
  in
  let restored =
    match Keeper_event_queue.stimulus_of_yojson
            (Keeper_event_queue.stimulus_to_yojson stimulus) with
    | Ok restored -> restored
    | Error detail -> fail detail
  in
  ignore (add_comment ~post_id ~author:"later-author" "a later reply" : string);
  let observation =
    match restored.payload with
    | Keeper_event_queue.Board_signal board ->
      (match Signal.board_observation_of_board_stimulus ~post_id board with
       | Ok observation -> observation
       | Error unavailable -> fail (Signal.unavailable_to_string unavailable))
    | _ -> fail "restored queue payload is not a Board signal"
  in
  (match observation.kind with
   | Signal.Observed_comment_added identity ->
     check string "accepted comment ID" (Board.Comment_id.to_string accepted.id)
       (Board.Comment_id.to_string identity.comment_id);
     check (option string) "accepted parent ID" parent_id
       (Option.map Board.Comment_id.to_string identity.parent_id)
   | _ -> fail "restored signal is not a comment");
  check string "queued author does not become the later author"
    "reply-author" observation.author;
  check string "queued body does not become the later body"
    "the queued reply" observation.content
;;

(* The queue only checks that a comment identity is non-empty. One that is
   not a Board comment id is refused where the queue meets the keeper, as a
   failed Board read, instead of reaching a consumer as a trusted id. *)
let test_malformed_queued_comment_identity_is_a_failed_read () =
  let module Signal = Keeper_world_observation_board_signal in
  let queued ~comment_id ~parent_id : Keeper_event_queue.board_stimulus =
    { kind = Keeper_event_queue.Comment_added { comment_id; parent_id }
    ; author = "reply-author"
    ; title = "thread"
    ; content = "a reply"
    ; hearth = None
    ; updated_at = None
    }
  in
  let refused what stimulus =
    match Signal.board_observation_of_board_stimulus ~post_id:"p-queued" stimulus with
    | Ok _ -> failf "%s: a malformed identity became an observation" what
    | Error unavailable ->
      check bool (what ^ " is reported as the identity parse")
        true (unavailable.Signal.operation = Signal.Parse_queued_comment_identity);
      check string (what ^ " names the post") "p-queued" unavailable.Signal.post_id
  in
  refused "comment id" (queued ~comment_id:"not-a-comment-id" ~parent_id:None);
  (* The shape Board.Comment_id.generate mints, written out so the test needs
     no random source. *)
  let valid = "c-" ^ String.make 32 'a' in
  refused "parent id" (queued ~comment_id:valid ~parent_id:(Some "not-a-comment-id"))
;;

let () =
  run
    "keeper_board_unavailable"
    [ ( "poison stimulus (masc keeper-cycle-exception incident)"
      , [ test_case
            "pending_board_event_of_stimulus names the missing post, does not raise"
            `Quick
            (with_eio test_poison_stimulus_reports_permanent_error)
        ; test_case
            "stimulus intake consumes without crash, stable on repeat"
            `Quick
            (with_eio test_poison_stimulus_intake_does_not_crash_and_stays_dropped)
        ; test_case
            "durable poison is acknowledged during intake"
            `Quick
            test_poison_durable_source_is_retired_during_intake
        ] )
    ; ( "admission"
      , [ test_case "an empty-observation source still spends an admission slot" `Quick
            test_empty_observation_source_still_spends_an_admission_slot
        ; test_case "permanent absence does not spend an admission slot" `Quick
            test_permanent_absence_does_not_spend_an_admission_slot
        ; test_case "delivered rejection remains current at intake" `Quick
            test_delivered_rejection_remains_current_at_intake
        ; test_case "superseded rejection retires before projection" `Quick
            test_superseded_rejection_is_retired_before_projection
        ; test_case "missing or malformed delivered evidence preserves active old rejection" `Quick
            test_missing_or_malformed_delivered_evidence_preserves_active_rejection
        ; test_case "unread rejection authority retains source and allows siblings" `Quick
            test_unread_rejection_authority_retains_source_and_allows_siblings
        ] )
    ; ( "replies after own comment"
      , [ test_case
            "catchup storage failure retains cursor"
            `Quick
            (with_eio test_catchup_storage_failure_retains_cursor)
        ; test_case
            "accepted comment identity survives queue projection"
            `Quick
            (with_eio (accepted_comment_identity_survives_queue_projection ~shape:`Reply))
        ; test_case
            "a top-level comment keeps no parent through queue projection"
            `Quick
            (with_eio (accepted_comment_identity_survives_queue_projection ~shape:`Top_level))
        ; test_case
            "a malformed queued comment identity is a failed read"
            `Quick
            test_malformed_queued_comment_identity_is_a_failed_read
        ; test_case
            "queued comment keeps its author and body"
            `Quick
            (with_eio test_queued_comment_keeps_its_author_and_body)
        ; test_case
            "Board replay routes exact replies"
            `Quick
            (with_eio test_board_replay_routes_exact_replies)
        ; test_case
            "missing parent comment does not abort later comment replay"
            `Quick
            (with_eio test_missing_parent_comment_does_not_abort_later_comment_replay)
        ] )
    ]
;;
