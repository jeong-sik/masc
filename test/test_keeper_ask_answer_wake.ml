(* The loop between a human answering and the Keeper that asked.

   Before this, an answer was validated, written to the log, and the request
   returned 200 — and the Keeper was never told. It could only find out by
   calling masc_ask_status, and nothing prompted it to. In a live workspace
   with ten Keepers and a month of history, not one question had ever been
   asked: asking was a dead end.

   These tests cover the two halves that close it. The wake has to survive the
   durable queue, and the row the Keeper reads has to carry what the human
   actually said. *)

open Masc
open Alcotest

let choice ~id ~label =
  match Keeper_ask.choice ~choice_id:id ~label () with
  | Ok c -> c
  | Error e -> failf "choice: %s" (Keeper_ask.invalid_choice_to_string e)
;;

let question ~id ~header ~choices =
  match
    Keeper_ask.question ~question_id:id ~header ~prompt:("Which way for " ^ header ^ "?")
      ~choices ~mode:Keeper_ask.Single ~free_text:Keeper_ask.Choices_only
  with
  | Ok q -> q
  | Error e -> failf "question: %s" (Keeper_ask.invalid_question_to_string e)
;;

let ask_with questions =
  match
    Keeper_ask.ask ~ask_id:"ask-1" ~keeper_name:"alpha" ~questions ~context:"why"
      ~continuation:(Keeper_continuation_channel.unrouted "test")
      ~asked_at:100. ()
  with
  | Ok a -> a
  | Error e -> failf "ask: %s" (Keeper_ask.invalid_ask_to_string e)
;;

let answers_for ask submissions =
  match Keeper_ask.parse_answers ~ask ~submissions with
  | Ok answers -> answers
  | Error failures ->
    failf "answers: %s"
      (String.concat ", " (List.map Keeper_ask.invalid_answer_to_string failures))
;;

let responder =
  { Keeper_ask.surface = Surface_ref.Dashboard { session_id = None }
  ; actor_id = Some "U1"
  ; display_name = Some "Vincent"
  }
;;

let meta =
  let json =
    `Assoc
      [ ("name", `String "alpha")
      ; ("trace_id", `String "trace-ask-alpha")
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> failf "meta: %s" err
;;

let contains haystack needle =
  let hn = String.length haystack and nn = String.length needle in
  let rec at i = i + nn <= hn && (String.sub haystack i nn = needle || at (i + 1)) in
  at 0
;;

(* The wake carries a pointer, so it has to come back out of the durable queue
   as the same pointer. A writer without a matching reader is how the field
   would go quiet. *)
let test_the_wake_survives_the_queue () =
  let payload =
    { Keeper_event_queue.ask_id = "ask-1"
    ; channel = Keeper_continuation_channel.unrouted "test"
    }
  in
  let stimulus =
    { Keeper_event_queue.post_id = Keeper_event_queue.ask_answered_post_id payload
    ; urgency = Keeper_event_queue.Normal
    ; arrived_at = 12.5
    ; payload = Keeper_event_queue.Ask_answered payload
    }
  in
  match
    Keeper_event_queue.stimulus_of_yojson (Keeper_event_queue.stimulus_to_yojson stimulus)
  with
  | Error e -> failf "the wake did not survive the queue: %s" e
  | Ok back ->
    (match back.Keeper_event_queue.payload with
     | Keeper_event_queue.Ask_answered read ->
       check string "ask_id" "ask-1" read.Keeper_event_queue.ask_id
     | _ -> fail "decoded as some other stimulus")
;;

(* One answer per question, so the ask id alone identifies the wake. *)
let test_the_wake_is_keyed_by_the_question () =
  let key ask_id =
    Keeper_event_queue.ask_answered_post_id
      { Keeper_event_queue.ask_id
      ; channel = Keeper_continuation_channel.unrouted "test"
      }
  in
  check string "keyed by the ask" "keeper-ask:ask-1" (key "ask-1");
  check bool "different asks do not collide" false
    (String.equal (key "ask-1") (key "ask-2"))
;;

(* The Keeper reads labels, not identities. Answers reference choice ids so
   that rewording a choice cannot orphan them — which means the row has to do
   the resolving, or the Keeper is handed an opaque id. *)
let test_the_row_says_what_the_human_picked () =
  let ask =
    ask_with
      [ question ~id:"q1" ~header:"deploy"
          ~choices:
            [ choice ~id:"c1" ~label:"roll forward"
            ; choice ~id:"c2" ~label:"roll back"
            ]
      ]
  in
  let answers = answers_for ask [ "q1", Keeper_ask.Chose { choice_ids = [ "c2" ] } ] in
  let row =
    Keeper_world_observation.pending_board_event_of_ask_answer ~meta ~ask ~answers
      ~responder ~answered_at:200.
  in
  check bool "the label, not the id" true
    (contains row.Keeper_world_observation.preview "roll back");
  check bool "the id is not what the Keeper reads" false
    (contains row.Keeper_world_observation.preview "c2");
  check bool "which question" true
    (contains row.Keeper_world_observation.preview "deploy");
  check string "who answered" "Vincent" row.Keeper_world_observation.author;
  check string "identity points back at the ask" "keeper-ask:ask-1"
    row.Keeper_world_observation.post_id
;;

(* Free text and a declined question are answers too; neither may come through
   blank. *)
let test_written_and_skipped_answers_are_readable () =
  let ask =
    ask_with
      [ (match
           Keeper_ask.question ~question_id:"q1" ~header:"notes" ~prompt:"Anything?"
             ~choices:[]
             ~mode:Keeper_ask.Single
             ~free_text:(Keeper_ask.Free_text_allowed { hint = None })
         with
         | Ok q -> q
         | Error e -> failf "question: %s" (Keeper_ask.invalid_question_to_string e))
      ]
  in
  let written =
    Keeper_world_observation.pending_board_event_of_ask_answer ~meta ~ask
      ~answers:(answers_for ask [ "q1", Keeper_ask.Wrote "ship it on Friday" ])
      ~responder ~answered_at:200.
  in
  check bool "the words the human wrote" true
    (contains written.Keeper_world_observation.preview "ship it on Friday");
  let skipped =
    Keeper_world_observation.pending_board_event_of_ask_answer ~meta ~ask
      ~answers:(answers_for ask [ "q1", Keeper_ask.Skipped ])
      ~responder ~answered_at:200.
  in
  check bool "a declined question still says so" true
    (contains skipped.Keeper_world_observation.preview "skipped")
;;

let test_complete_multi_question_answers_reach_the_prompt () =
  let written_question id header =
    match Keeper_ask.question ~question_id:id ~header ~prompt:header ~choices:[]
        ~mode:Keeper_ask.Single
        ~free_text:(Keeper_ask.Free_text_allowed { hint = None }) with
    | Ok question -> question
    | Error error -> fail (Keeper_ask.invalid_question_to_string error)
  in
  let ask = ask_with
      [ written_question "format" "행사 형태"
      ; written_question "details" "확정 정보"
      ] in
  let format = String.concat " " (List.init 80 (fun _ -> "허구의 오프라인 전시입니다.")) in
  let details = "2026-10-17 14:00–17:00 / 은빛정류장 전시실 / 무료. 주최와 링크는 미정이며 만들지 마세요." in
  let row = Keeper_world_observation.pending_board_event_of_ask_answer
      ~meta ~ask
      ~answers:(answers_for ask
        [ "format", Keeper_ask.Wrote format; "details", Keeper_ask.Wrote details ])
      ~responder ~answered_at:200. in
  let fields = Keeper_unified_prompt.For_testing.board_event_fields row in
  check string "all question answers survive model-facing field projection"
    ("행사 형태: " ^ format ^ " · 확정 정보: " ^ details)
    (List.assoc "preview" fields)
;;

(* The row is what the turn renders. Left out of the rendered set, the Keeper
   is woken with an empty pending-events list — a wake it cannot act on, which
   is the failure this whole change is about. *)
let test_the_row_is_one_the_turn_renders () =
  let ask =
    ask_with
      [ question ~id:"q1" ~header:"deploy" ~choices:[ choice ~id:"c1" ~label:"yes" ] ]
  in
  let row =
    Keeper_world_observation.pending_board_event_of_ask_answer ~meta ~ask
      ~answers:(answers_for ask [ "q1", Keeper_ask.Chose { choice_ids = [ "c1" ] } ])
      ~responder ~answered_at:200.
  in
  check bool "rendered" true (Keeper_world_observation.is_board_activity_event row)
;;

(* No Board post stands behind this row. Marked as a human's post, the Keeper
   read it as one it could fetch and burned a masc_board_post_get on
   "Invalid post_id: keeper-ask" — seen four times in one live run before this
   was corrected. *)
let test_the_row_is_not_a_board_post () =
  let ask =
    ask_with
      [ question ~id:"q1" ~header:"deploy" ~choices:[ choice ~id:"c1" ~label:"yes" ] ]
  in
  let row =
    Keeper_world_observation.pending_board_event_of_ask_answer ~meta ~ask
      ~answers:(answers_for ask [ "q1", Keeper_ask.Chose { choice_ids = [ "c1" ] } ])
      ~responder ~answered_at:200.
  in
  check bool "nothing to fetch" true
    (row.Keeper_world_observation.post_kind = Board.System_post)

;;

(* Recording the answer and telling the Keeper are one act, so the route cannot
   report success when only the first half happened. An operator who reads 200
   stops thinking about it while the Keeper waits forever. *)
let test_an_undelivered_answer_is_not_reported_as_success () =
  let status, body =
    Server_routes_http_keeper_stream.ask_answer_response ~ask_id:"ask-1"
      ~actor:"test-operator" ~answer_count:1 ~open_remaining:0 ~delivered:false
  in
  check bool "not a success" true (status = `Internal_server_error);
  (match body with
   | `Assoc fields ->
     check bool "says the keeper was not told" true
       (List.assoc_opt "delivered" fields = Some (`Bool false));
     check bool "and says so in words" true (List.mem_assoc "error" fields)
   | _ -> fail "the body is not an object")
;;

let test_a_delivered_answer_is_a_success () =
  let status, body =
    Server_routes_http_keeper_stream.ask_answer_response ~ask_id:"ask-1"
      ~actor:"test-operator" ~answer_count:1 ~open_remaining:0 ~delivered:true
  in
  check bool "success" true (status = `OK);
  (match body with
   | `Assoc fields ->
     check bool "delivered" true
       (List.assoc_opt "delivered" fields = Some (`Bool true));
     check bool "nothing to explain" false (List.mem_assoc "error" fields)
   | _ -> fail "the body is not an object")

;;

module Wake = Keeper_ask_answer_wake
module Queue = Keeper_registry_event_queue

let with_persistence f =
  let base_path = Filename.temp_file "masc-ask-answer-wake-" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o700;
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace.default_config base_path in
  ignore (Workspace.init config ~agent_name:(Some "test-operator"));
  let owners = ref [] in
  let ensure_keeper keeper_name =
    let meta = match Masc_test_deps.meta_of_json_fixture
        (`Assoc [ "name", `String keeper_name; "activation_mode", `String "manual" ]) with
      | Ok meta -> meta | Error error -> fail error in
    (match Keeper_meta_store.replace_snapshot config meta with
     | Ok _ -> () | Error error -> fail error);
    ignore (Keeper_registry.register_offline ~base_path keeper_name meta);
    owners := keeper_name :: !owners in
  let rec remove path =
    if Sys.is_directory path then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path in
  Fun.protect ~finally:(fun () ->
      List.iter (Keeper_registry.For_testing.unregister ~base_path) !owners;
      Fs_compat.clear_fs ();
      remove base_path)
    (fun () -> f config ensure_keeper)
;;

let persist_answer ~base_path ~keeper_name ~ask_id ?(answered_at = 200.) () =
  let continuation = Keeper_continuation_channel.dashboard ~thread_id:"original-ask-thread" |> Result.get_ok in
  let ask = Keeper_ask.ask ~ask_id ~keeper_name
      ~questions:[ question ~id:"q1" ~header:"deploy" ~choices:[ choice ~id:"c1" ~label:"yes" ] ]
      ~context:"original task" ~continuation ~asked_at:100. () |> Result.get_ok in
  (match Keeper_ask_store.record_ask ~base_path ask with
   | Ok () -> () | Error error -> fail error);
  (match Keeper_ask_store.answer ~base_path ~keeper_name ~ask_id
      ~submissions:[ "q1", Keeper_ask.Chose { choice_ids = [ "c1" ] } ] ~responder ~now:answered_at with
   | Ok _ -> () | Error error -> fail (Keeper_ask_store.answer_failure_to_string error));
  ask
;;

(* A torn write from before the answer: predating the canonical answer time,
   it must be outside every delivery-evidence window. *)
let write_preanswer_corruption ~base_path ~keeper_name =
  let dir = Filename.concat
      (Keeper_reaction_ledger.store_dir ~base_path ~keeper_name) "2020-01" in
  Fs_compat.mkdir_p dir;
  Fs_compat.save_file (Filename.concat dir "01.jsonl") "{torn pre-answer write}\n"
;;

let pending_asks ~base_path ~keeper_name =
  match Keeper_event_queue_persistence.load_result ~base_path ~keeper_name with
  | Error error -> fail error
  | Ok queue -> Keeper_event_queue.to_list queue
      |> List.filter_map (fun (source : Keeper_event_queue.stimulus) ->
          match source.payload with
          | Keeper_event_queue.Ask_answered payload -> Some (source, payload)
          | Keeper_event_queue.Board_signal _ | Board_attention _ | Bootstrap
          | Fusion_completed _ | Composition_completed _ | Schedule_due _
          | Owned_job_completed _
          | Connector_attention _ | Hitl_resolved _ | Completion_authority_rejected _
          | Task_outcome _ | Task_cancelled _ | Workspace_message _ | Delegate_completed _ -> None)
;;

let reconcile_or_fail ~base_path =
  match Wake.reconcile ~base_path with
  | Ok report -> report
  | Error error -> fail (Keeper_ask_store.read_error_to_string error)
;;

let terminalize_answer ~base_path ~keeper_name source =
  let selection = match Queue.select_when_result ~base_path keeper_name ~now:300. ~ready:(fun _ -> true) with
    | Ok (Some selection) -> selection
    | Ok None -> fail "answer source was not admitted"
    | Error error -> fail error in
  Keeper_reaction_ledger.record_event_queue_turn_started ~base_path ~keeper_name source;
  match Queue.terminalize_pending_turn_completed_result ~base_path keeper_name ~applied_at:301. ~selection with
  | Ok (Queue.Turn_source_acked _) -> ()
  | Ok Queue.Turn_selection_withdrawn -> fail "answer source was withdrawn"
  | Error error -> fail error
;;

let test_recorded_answer_recovers_once_on_original_continuation () =
  with_persistence @@ fun config ensure_keeper ->
  let base_path = config.Workspace.base_path in
  let keeper_name = "alpha" in
  ensure_keeper keeper_name;
  let ask = persist_answer ~base_path ~keeper_name ~ask_id:"answer-recovery" () in
  let log_path = Keeper_ask_store.log_path ~base_path ~keeper_name in
  let original_log = Fs_compat.load_file log_path in
  let queue_path = Filename.concat
      (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
      Keeper_event_queue_persistence.snapshot_filename in
  Fs_compat.mkdir_p (Filename.dirname queue_path);
  Fs_compat.save_file queue_path "invalid queue snapshot";
  (match Wake.deliver ~base_path ~keeper_name ~ask_id:ask.ask_id with
   | Error (Wake.Queue_storage_failed _) -> ()
   | Error error -> fail (Wake.error_to_string error)
   | Ok _ -> fail "failed queue storage acknowledged answer delivery");
  let status, receipt = Server_routes_http_keeper_stream.ask_answer_response
      ~ask_id:ask.ask_id ~actor:"operator" ~answer_count:1 ~open_remaining:0 ~delivered:false in
  check bool "recorded but undelivered remains HTTP500" true (status = `Internal_server_error);
  check bool "receipt preserves the recorded answer" true
    Yojson.Safe.Util.(receipt |> member "recorded" |> to_bool);
  check string "receipt correlates to the exact ask" ask.ask_id
    Yojson.Safe.Util.(receipt |> member "ask_id" |> to_string);
  Unix.unlink queue_path;
  let recovered = reconcile_or_fail ~base_path in
  check int "canonical record recovers without another answer" 1 recovered.enqueued;
  check int "recovery has no retained failures" 0 (List.length recovered.failures);
  let source = match pending_asks ~base_path ~keeper_name with
    | [ source, payload ] ->
        check string "original ask pointer" ask.ask_id payload.Keeper_event_queue.ask_id;
        check bool "original continuation is retained" true (payload.channel = ask.continuation);
        check (float 0.) "canonical answer timestamp is stable" 200. source.Keeper_event_queue.arrived_at;
        source
    | _ -> fail "recovery did not create one exact answer source" in
  (match Wake.deliver ~base_path ~keeper_name ~ask_id:ask.ask_id with
   | Ok Wake.Already_pending -> ()
   | Ok _ -> fail "pending answer delivery was not idempotent"
   | Error error -> fail (Wake.error_to_string error));
  check int "duplicate delivery leaves one pending source" 1 (List.length (pending_asks ~base_path ~keeper_name));
  terminalize_answer ~base_path ~keeper_name source;
  let repeated = reconcile_or_fail ~base_path in
  check int "accepted source evidence suppresses re-enqueue" 0 repeated.enqueued;
  check int "accepted source is recognized by exact evidence" 1 repeated.already_delivered;
  check int "accepted source stays absent from pending" 0 (List.length (pending_asks ~base_path ~keeper_name));
  check string "delivery and recovery never replay the answer write" original_log (Fs_compat.load_file log_path)
;;

let test_durable_write_failure_is_recovered_from_the_answer_record () =
  with_persistence @@ fun config ensure_keeper ->
  let base_path = config.Workspace.base_path in
  ensure_keeper "alpha";
  let ask = persist_answer ~base_path ~keeper_name:"alpha" ~ask_id:"write-failure" () in
  let payload = { Keeper_event_queue.ask_id = ask.ask_id; channel = ask.continuation } in
  let source = { Keeper_event_queue.post_id = Keeper_event_queue.ask_answered_post_id payload;
    urgency = Keeper_event_queue.Normal; arrived_at = 200.; payload = Keeper_event_queue.Ask_answered payload } in
  let before = Fs_compat.load_file (Keeper_ask_store.log_path ~base_path ~keeper_name:"alpha") in
  (match Keeper_event_queue_persistence.For_testing.enqueue_stimulus_once_with_confirmation
      ~base_path ~keeper_name:"alpha"
      ~already_delivered:(fun () -> Keeper_reaction_ledger.event_queue_delivery_seen_for_source_strict_result
        ~base_path ~keeper_name:"alpha" ~not_before:source.arrived_at ~post_id:source.post_id
        ~stimulus_kind:(Keeper_reaction_ledger.stimulus_kind_of_event_queue source)
        |> Result.map_error Keeper_reaction_ledger.strict_delivery_evidence_error_to_string)
      ~confirm_snapshot:(fun _path _state -> Error "injected durable snapshot confirmation failure") source with
   | Error _ -> () | Ok () -> fail "snapshot confirmation failure acknowledged delivery");
  check int "failed confirmation does not publish pending answer" 0 (List.length (pending_asks ~base_path ~keeper_name:"alpha"));
  let report = reconcile_or_fail ~base_path in
  check int "recovery uses the original canonical answer" 1 report.enqueued;
  check string "recovery does not answer again" before
    (Fs_compat.load_file (Keeper_ask_store.log_path ~base_path ~keeper_name:"alpha"))
;;

let test_corrupt_delivery_evidence_cannot_recreate_an_accepted_source () =
  with_persistence @@ fun config ensure_keeper ->
  let base_path = config.Workspace.base_path in
  ensure_keeper "alpha";
  let ask = persist_answer ~base_path ~keeper_name:"alpha" ~ask_id:"evidence-recovery" () in
  (match Wake.deliver ~base_path ~keeper_name:"alpha" ~ask_id:ask.ask_id with
   | Ok Wake.Enqueued -> () | Ok _ -> fail "fresh answer was not enqueued"
   | Error error -> fail (Wake.error_to_string error));
  let source = match pending_asks ~base_path ~keeper_name:"alpha" with
    | [ source, _ ] -> source | _ -> fail "answer source is missing" in
  terminalize_answer ~base_path ~keeper_name:"alpha" source;
  let paths = Dated_jsonl.range_day_file_paths_result
      (Dated_jsonl.open_store (Keeper_reaction_ledger.location ~base_path ~keeper_name:"alpha"))
      ~since:"1970-01-01" ~until:"9999-12-31" |> Result.get_ok in
  check bool "real accepted-source ledger files exist" true (paths <> []);
  let originals = List.map (fun path -> path, Fs_compat.load_file path) paths in
  List.iter (fun (path, _) -> Fs_compat.save_file path "{corrupt delivery evidence}\n") originals;
  let blocked = reconcile_or_fail ~base_path in
  check int "incomplete evidence retains one recovery failure" 1 (List.length blocked.failures);
  check int "incomplete evidence cannot authorize re-enqueue" 0 blocked.enqueued;
  check int "accepted source remains absent from pending" 0 (List.length (pending_asks ~base_path ~keeper_name:"alpha"));
  List.iter (fun (path, bytes) -> Fs_compat.save_file path bytes) originals;
  let restored = reconcile_or_fail ~base_path in
  check int "restored exact evidence recognizes delivered source" 1 restored.already_delivered;
  check int "restoration never recreates that source" 0 restored.enqueued
;;

(* A torn ledger write from before the answer predates every delivery this
   answer can produce: it must not make the evidence incomplete, must not
   reject enqueue, and must not hide delivery evidence written after the
   answer. *)
let test_fresh_answer_delivers_past_preanswer_corruption () =
  with_persistence @@ fun config ensure_keeper ->
  let base_path = config.Workspace.base_path in
  ensure_keeper "alpha";
  write_preanswer_corruption ~base_path ~keeper_name:"alpha";
  let ask = persist_answer ~base_path ~keeper_name:"alpha" ~ask_id:"post-corruption-answer"
      ~answered_at:(Unix.gettimeofday ()) () in
  (match Wake.deliver ~base_path ~keeper_name:"alpha" ~ask_id:ask.ask_id with
   | Ok Wake.Enqueued -> ()
   | Ok _ -> fail "fresh answer after pre-answer corruption was not enqueued"
   | Error error -> fail (Wake.error_to_string error));
  let source = match pending_asks ~base_path ~keeper_name:"alpha" with
    | [ source, _ ] -> source | _ -> fail "answer source is missing" in
  terminalize_answer ~base_path ~keeper_name:"alpha" source;
  let repeated = reconcile_or_fail ~base_path in
  check int "in-window delivery evidence suppresses re-enqueue" 0 repeated.enqueued;
  check int "in-window delivery evidence recognizes the delivered source" 1 repeated.already_delivered;
  check int "corruption before the answer never blocks this keeper again" 0
    (List.length repeated.failures)
;;

(* The maintenance pulse takes the same bounded evidence path, so a fresh
   answer recorded after old corruption recovers on the next pulse. *)
let test_reconcile_delivers_past_preanswer_corruption () =
  with_persistence @@ fun config ensure_keeper ->
  let base_path = config.Workspace.base_path in
  ensure_keeper "alpha";
  write_preanswer_corruption ~base_path ~keeper_name:"alpha";
  ignore (persist_answer ~base_path ~keeper_name:"alpha" ~ask_id:"pulse-corruption-answer"
      ~answered_at:(Unix.gettimeofday ()) ());
  let report = reconcile_or_fail ~base_path in
  check int "recovery enqueues the fresh answer past pre-answer corruption" 1 report.enqueued;
  check int "recovery has no retained failures" 0 (List.length report.failures);
  check int "one exact answer source is pending" 1
    (List.length (pending_asks ~base_path ~keeper_name:"alpha"))
;;

let test_lifecycle_fence_defers_delivery_until_recovery () =
  with_persistence @@ fun config ensure_keeper ->
  let base_path = config.Workspace.base_path in
  ensure_keeper "alpha";
  ignore (persist_answer ~base_path ~keeper_name:"alpha" ~ask_id:"fenced-answer" ());
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  ignore (Keeper_shutdown_intake_fence.begin_shutdown ~base_path ~keeper_name:"alpha" ~operation_id);
  Fun.protect ~finally:(fun () ->
      ignore (Keeper_shutdown_intake_fence.rollback_shutdown ~base_path ~keeper_name:"alpha" ~operation_id))
    (fun () ->
      let blocked = reconcile_or_fail ~base_path in
      check int "shutdown intake fence retains delivery failure" 1 (List.length blocked.failures);
      check int "fence admits no answer source" 0 blocked.enqueued;
      check int "pending stays empty" 0 (List.length (pending_asks ~base_path ~keeper_name:"alpha")));
  let recovered = reconcile_or_fail ~base_path in
  check int "existing pulse recovers after the fence opens" 1 recovered.enqueued
;;

let test_canonical_owner_survives_a_nonidentity_filename () =
  with_persistence @@ fun config ensure_keeper ->
  let base_path = config.Workspace.base_path in
  let keeper_name = "alpha.one" in
  ensure_keeper keeper_name;
  let ask = persist_answer ~base_path ~keeper_name ~ask_id:"owner-spelling" () in
  let path = Keeper_ask_store.log_path ~base_path ~keeper_name in
  let stem = Filename.chop_suffix (Filename.basename path) ".jsonl" in
  check bool "fixture crosses a nonidentity sanitizer" false (String.equal keeper_name stem);
  (match Keeper_ask_store.rows_result ~base_path ~keeper_name:stem with
   | Error (Keeper_ask_store.Log_decode_failed _) -> ()
   | Error error -> fail (Keeper_ask_store.read_error_to_string error)
   | Ok _ -> fail "filename alias was accepted as canonical owner");
  let recovered = reconcile_or_fail ~base_path in
  check int "discovery uses the recorded canonical Keeper name" 1 recovered.enqueued;
  check int "owner spelling has no recovery failure" 0 (List.length recovered.failures);
  match pending_asks ~base_path ~keeper_name with
  | [ _, payload ] -> check string "original ask arrives at canonical owner" ask.ask_id payload.Keeper_event_queue.ask_id
  | _ -> fail "sanitized filename lost its canonical owner"
;;

let test_already_answered_receipt_keeps_the_conflict () =
  let ask = ask_with [ question ~id:"q1" ~header:"deploy" ~choices:[ choice ~id:"c1" ~label:"yes" ] ] in
  let answers = answers_for ask [ "q1", Keeper_ask.Chose { choice_ids = [ "c1" ] } ] in
  List.iter (fun delivered ->
    let status, body = Server_routes_http_keeper_stream.ask_already_answered_response
        ~ask_id:ask.ask_id ~answers ~answered_at:200. ~delivered in
    check bool "canonical answer remains HTTP409" true (status = `Conflict);
    let open Yojson.Safe.Util in
    check string "receipt uses exact ask id" ask.ask_id (body |> member "ask_id" |> to_string);
    check bool "canonical answer is recorded" true (body |> member "recorded" |> to_bool);
    check bool "delivery is explicit" delivered (body |> member "delivered" |> to_bool);
    check string "canonical state is answered" "answered" (body |> member "state" |> to_string);
    check bool "no requesting losing actor is called winner" true (member "actor" body = `Null)) [ true; false ]
;;

let test_followup_reads_exact_source_without_waking () =
  with_persistence @@ fun config ensure_keeper ->
  let base_path = config.Workspace.base_path and keeper_name = "alpha" in
  ensure_keeper keeper_name;
  let ask = persist_answer ~base_path ~keeper_name ~ask_id:"followup-original" () in
  let resolution = match Keeper_ask_store.rows_result ~base_path ~keeper_name with
    | Ok (Keeper_ask_store.Stored_rows rows) -> snd (List.assoc ask.ask_id rows)
    | Ok Missing_log -> fail "canonical answer disappeared"
    | Error error -> fail (Keeper_ask_store.read_error_to_string error) in
  let observe () = Wake.observe_followup ~base_path ~keeper_name ~ask ~resolution
      |> function Ok value -> value | Error detail -> fail detail in
  let before = observe () |> Wake.followup_to_json in
  check bool "no turn is invented from recording the answer" true
    (Yojson.Safe.Util.member "turn_started_at" before = `Null);
  check int "observing never enqueues a wake" 0 (List.length (pending_asks ~base_path ~keeper_name));
  (match Wake.deliver ~base_path ~keeper_name ~ask_id:ask.ask_id with
   | Ok _ -> () | Error error -> fail (Wake.error_to_string error));
  let source = match pending_asks ~base_path ~keeper_name with
    | [source, _] -> source | _ -> fail "original wake did not persist exactly once" in
  Keeper_reaction_ledger.record_event_queue_turn_started ~base_path ~keeper_name source;
  let entered = observe () |> Wake.followup_to_json in
  check bool "original source turn entry is observed" true
    (Yojson.Safe.Util.member "turn_started_at" entered <> `Null);
  let left, right = Eio.Fiber.both observe observe in
  check string "concurrent native reader results retain the same exact source"
    left.stimulus_id right.stimulus_id;
  let other_payload = {Keeper_event_queue.ask_id="other-question"; channel=ask.continuation} in
  let other = {source with post_id=Keeper_event_queue.ask_answered_post_id other_payload;
      payload=Keeper_event_queue.Ask_answered other_payload} in
  Keeper_reaction_ledger.record_event_queue_turn_finished ~base_path ~keeper_name
    ~disposition:"test-boundary" other;
  let unrelated = observe () |> Wake.followup_to_json in
  check bool "another question cannot supply a turn boundary" true
    (Yojson.Safe.Util.member "turn_finished_at" unrelated = `Null);
  Keeper_reaction_ledger.record_event_queue_turn_finished ~base_path ~keeper_name
    ~disposition:"test-boundary" source;
  let finished = observe () |> Wake.followup_to_json in
  check bool "the original turn boundary is observed" true
    (Yojson.Safe.Util.member "turn_finished_at" finished <> `Null);
  check int "repeated observation never duplicates the pending source" 1
    (List.length (pending_asks ~base_path ~keeper_name));
  check bool "another Keeper cannot inherit this question's source" true
    (Result.is_error (Wake.observe_followup ~base_path ~keeper_name:"beta" ~ask ~resolution));
  List.iter (fun field -> check bool "followup metadata carries no human content or invented action" true
    (Yojson.Safe.Util.member field finished = `Null)) ["answers";"questions";"responder";"tool_action";"quarantine_reason"];
  Dated_jsonl.append (Dated_jsonl.open_store (Keeper_reaction_ledger.location ~base_path ~keeper_name))
    (`Assoc ["stimulus_id", `String left.stimulus_id; "record_kind", `String "reaction"]);
  let quarantined = observe () |> Wake.followup_to_json in
  check bool "quarantined matching row marks evidence incomplete" false
    (Yojson.Safe.Util.member "evidence_complete" quarantined |> Yojson.Safe.Util.to_bool);
  check bool "quarantined matching row exposes its quarantine reason code" true
    (match Yojson.Safe.Util.member "quarantine_reason" quarantined with
     | `String reason -> String.length reason > 0
     | _ -> false)
;;

let test_followup_queue_settlement_does_not_invent_a_turn () =
  with_persistence @@ fun config ensure_keeper ->
  let base_path = config.Workspace.base_path and keeper_name = "alpha" in
  ensure_keeper keeper_name;
  let ask = persist_answer ~base_path ~keeper_name ~ask_id:"queue-only" () in
  let resolution = match Keeper_ask_store.rows_result ~base_path ~keeper_name with
    | Ok (Keeper_ask_store.Stored_rows rows) -> snd (List.assoc ask.ask_id rows)
    | Ok Missing_log -> fail "answer disappeared"
    | Error error -> fail (Keeper_ask_store.read_error_to_string error) in
  (match Wake.deliver ~base_path ~keeper_name ~ask_id:ask.ask_id with
   | Ok _ -> () | Error error -> fail (Wake.error_to_string error));
  let selection = match Queue.select_when_result ~base_path keeper_name ~now:300. ~ready:(fun _ -> true) with
    | Ok (Some selection) -> selection
    | Ok None -> fail "original wake not selected" | Error detail -> fail detail in
  (match Queue.terminalize_pending_turn_completed_result ~base_path keeper_name ~applied_at:301. ~selection with
   | Ok (Queue.Turn_source_acked _) -> ()
   | Ok Queue.Turn_selection_withdrawn -> fail "original selection withdrawn" | Error detail -> fail detail);
  let observed = match Wake.observe_followup ~base_path ~keeper_name ~ask ~resolution with
    | Ok observed -> Wake.followup_to_json observed | Error detail -> fail detail in
  check bool "queue settlement is an independent positive fact" true
    (Yojson.Safe.Util.member "queue_settled_at" observed <> `Null);
  check bool "queue settlement supplies neither turn entry nor boundary" true
    (Yojson.Safe.Util.member "turn_started_at" observed = `Null
     && Yojson.Safe.Util.member "turn_finished_at" observed = `Null)
;;

let () =
  run "keeper_ask_answer_wake"
    [ ( "wake"
      , [ test_case "queue settlement does not invent a turn" `Quick
            test_followup_queue_settlement_does_not_invent_a_turn
        ; test_case "followup reads exact source without waking" `Quick
            test_followup_reads_exact_source_without_waking
        ; test_case "the wake survives the queue" `Quick test_the_wake_survives_the_queue
        ; test_case "the wake is keyed by the question" `Quick
            test_the_wake_is_keyed_by_the_question
        ; test_case "an undelivered answer is not reported as success" `Quick
            test_an_undelivered_answer_is_not_reported_as_success
        ; test_case "a delivered answer is a success" `Quick
            test_a_delivered_answer_is_a_success
        ; test_case "recorded answer recovers once on original continuation" `Quick
            test_recorded_answer_recovers_once_on_original_continuation
        ; test_case "durable write failure recovers from the answer record" `Quick
            test_durable_write_failure_is_recovered_from_the_answer_record
        ; test_case "corrupt delivery evidence cannot recreate accepted source" `Quick
            test_corrupt_delivery_evidence_cannot_recreate_an_accepted_source
        ; test_case "fresh answer delivers past pre-answer corruption" `Quick
            test_fresh_answer_delivers_past_preanswer_corruption
        ; test_case "reconcile delivers past pre-answer corruption" `Quick
            test_reconcile_delivers_past_preanswer_corruption
        ; test_case "lifecycle fence defers answer delivery" `Quick
            test_lifecycle_fence_defers_delivery_until_recovery
        ; test_case "canonical owner survives nonidentity filename" `Quick
            test_canonical_owner_survives_a_nonidentity_filename
        ; test_case "already answered receipt keeps the conflict" `Quick
            test_already_answered_receipt_keeps_the_conflict

        ] )
    ; ( "row"
      , [ test_case "the row says what the human picked" `Quick
            test_the_row_says_what_the_human_picked
        ; test_case "written and skipped answers are readable" `Quick
            test_written_and_skipped_answers_are_readable
        ; test_case "complete multi-question answers reach the prompt" `Quick
            test_complete_multi_question_answers_reach_the_prompt
        ; test_case "the row is one the turn renders" `Quick
            test_the_row_is_one_the_turn_renders
        ; test_case "the row is not a Board post" `Quick
            test_the_row_is_not_a_board_post
        ] )
    ]
;;
