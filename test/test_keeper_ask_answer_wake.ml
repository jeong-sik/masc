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
  let answers = List.assoc "answers" fields |> Yojson.Safe.from_string
      |> Yojson.Safe.Util.to_list in
  check (list string) "complete answers retain exact per-question identities"
    ["format";"details"]
    (List.map (fun value -> Yojson.Safe.Util.(value |> member "question_id" |> to_string)) answers);
  check (list string) "all question answers survive model-facing field projection"
    [format;details]
    (List.map (fun value -> Yojson.Safe.Util.(value |> member "response" |> member "text" |> to_string)) answers);
  check bool "display answer and short excerpt are not repeated in model input" false
    (List.mem_assoc "preview" fields || List.mem_assoc "latest_external_preview" fields)
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

(* Run the real SDK handler: input preparation changes the run carrier after
   handler entry, then storage and answered input must retain the first owner. *)
let test_ask_producer_keeps_frozen_source_through_answer () =
  with_persistence @@ fun config ensure_keeper ->
  ensure_keeper "alpha";
  ignore (Masc_test_deps.init_unified_tool_registry ());
  let base_path = config.Workspace.base_path in
  let cell = Keeper_tool_call_log.create_turn_ctx_cell () in
  let set_source trace turn =
    Keeper_tool_call_log.set_turn_context ~cell ~agent_name:"alpha"
      ~trace_id:trace ~keeper_turn_id:turn ~turn:999 ~task_id:"current-execution-task" () in
  set_source "producer-trace" 17;
  let publication_recovery : Keeper_publication_recovery_availability.turn_context =
    {provider=Keeper_publication_recovery_availability.non_runtime_provider;keeper_name="alpha"} in
  let handler = Keeper_tools_agent_core_handler.make_keeper_tool_handler_from_meta
      ~name:"masc_ask" ~input_schema:Tool_schemas_operator_surface.ask.Masc_domain.input_schema
      ~config ~meta ~publication_recovery
      ~ctx_snapshot:(Keeper_context_runtime.create ~eio:false ~system_prompt:"Ask source fixture")
      ~keeper_turn_id:(fun () -> Some 900)
      ~source_context:(fun () -> Some (Keeper_tool_call_log_context.get_turn_context_record ~cell ()))
      ~prepare_input:(fun input -> set_source "later-same-keeper-run" 900; Ok input) () in
  let arguments = `Assoc
      ["questions",`List [`Assoc ["header",`String "decision";"prompt",`String "Which original action?";
        "mode",`String "single";"free_text",`Bool true]];
       "task_id",`String "explicit-related-task";"goal_id",`String "explicit-related-goal"] in
  let result = handler arguments in
  check bool "real SDK handler records question" true (Tool_result.is_success result);
  let ask_id = Tool_result.message result |> Yojson.Safe.from_string
      |> Yojson.Safe.Util.member "ask_id" |> Yojson.Safe.Util.to_string in
  let read_original () = match Keeper_ask_store.rows_result ~base_path ~keeper_name:"alpha" with
    | Ok (Keeper_ask_store.Stored_rows rows) -> List.assoc ask_id rows
    | Ok Missing_log -> fail "real handler did not persist its Ask"
    | Error error -> fail (Keeper_ask_store.read_error_to_string error) in
  let ask,_ = read_original () in
  check (option string) "related Task is never replaced by execution Task"
    (Some "explicit-related-task") ask.task_id;
  check (option string) "original source includes trace and absolute Keeper turn"
    (Some "producer-trace#17") (Option.map Ids.Turn_ref.to_string ask.source_turn_ref);
  Keeper_ask_store.answer ~base_path ~keeper_name:"alpha" ~ask_id
    ~submissions:["q1",Keeper_ask.Wrote "keep original action"] ~responder ~now:200.
    |> Result.get_ok |> ignore;
  (match read_original () with
   | original_ask,Keeper_ask.Answered_by {answers;responder;answered_at} ->
       let row = Keeper_world_observation.pending_board_event_of_ask_answer
           ~meta ~ask:original_ask ~answers ~responder ~answered_at in
       let origin = Keeper_unified_prompt.For_testing.board_event_fields row
           |> List.assoc "ask_origin" |> Yojson.Safe.from_string in
       check string "canonical answer keeps the producer identity after other work"
         "producer-trace#17" Yojson.Safe.Util.(origin |> member "source_turn_ref" |> to_string)
   | _,(Keeper_ask.Open | Keeper_ask.Withdrawn_because _) -> fail "answer not stored");
  let call_unobserved ?source_turn_ref arguments =
    let ctx : Mcp_tool_runtime_ask.context = {config;agent_name="alpha";arguments} in
    let result = Mcp_tool_runtime_ask.handle_ask ?source_turn_ref
        ~tool_name:"masc_ask" ~start_time:(Tool_timing.start ()) ctx |> Option.get in
    check bool "unobserved callers can still ask" true (Tool_result.is_success result);
    let id = Tool_result.message result |> Yojson.Safe.from_string
        |> Yojson.Safe.Util.member "ask_id" |> Yojson.Safe.Util.to_string in
    Keeper_ask_store.open_asks ~base_path ~keeper_name:"alpha"
      |> List.find (fun (ask : Keeper_ask.ask) -> ask.ask_id=id) in
  let forged = match arguments with
    | `Assoc fields -> `Assoc (("source_turn_ref",`String "forged-source#123")::fields)
    | _ -> fail "fixture arguments" in
  let external_ask = call_unobserved forged in
  check bool "a client argument cannot supply host provenance" true (external_ask.source_turn_ref=None);
  Keeper_tool_call_log.set_turn_context ~cell ~agent_name:"alpha" ~turn:123 ~keeper_turn_id:123 ();
  let partial = Keeper_tool_call_log_context.get_turn_context_record ~cell () in
  let partial_ask = call_unobserved ?source_turn_ref:(Keeper_tool_call_log_context.source_turn_ref partial) arguments in
  check bool "a turn number without its trace cannot acquire provenance" true
    (partial_ask.source_turn_ref=None);
  let event = Keeper_ask.event_to_json (Keeper_ask.Asked ask) in
  let malformed = match event with
    | `Assoc fields -> `Assoc (List.map (function
        | "ask",`Assoc fields -> "ask",`Assoc (List.map (function
            | "source_turn_ref",_ -> "source_turn_ref",`String "missing-turn-coordinate"
            | field -> field) fields)
        | field -> field) fields)
    | _ -> fail "canonical Asked event" in
  check bool "malformed stored source is refused" true
    (Result.is_error (Keeper_ask.event_of_json malformed));
  let legacy_turn_event turn_value =
    match event with
    | `Assoc fields ->
      `Assoc
        (List.map
           (function
             | "ask", `Assoc ask_fields ->
               ( "ask"
               , `Assoc
                   (("turn_id", turn_value)
                    :: List.filter
                         (fun (key, _) -> not (String.equal key "source_turn_ref"))
                         ask_fields) )
             | field -> field)
           fields)
    | _ -> fail "canonical Asked event"
  in
  (match Keeper_ask.event_of_json (legacy_turn_event (`Int 17)) with
   | Ok (Keeper_ask.Asked decoded) ->
     check (option string) "legacy turn_id without trace decodes as unobserved source" None
       (Option.map Ids.Turn_ref.to_string decoded.source_turn_ref)
   | Ok (Keeper_ask.Answered _ | Keeper_ask.Withdrawn _) -> fail "expected Asked event"
   | Error detail -> fail ("valid legacy turn_id rejected: " ^ detail));
  check bool "malformed legacy turn_id is refused" true
    (Result.is_error (Keeper_ask.event_of_json (legacy_turn_event (`Int 0)))
     && Result.is_error (Keeper_ask.event_of_json (legacy_turn_event (`String "bad"))))
;;

let persist_answer ~base_path ~keeper_name ~ask_id ?task_id ?(answered_at = 200.) () =
  let continuation = Keeper_continuation_channel.dashboard ~thread_id:"original-ask-thread" |> Result.get_ok in
  let ask = Keeper_ask.ask ~ask_id ~keeper_name
      ~questions:[ question ~id:"q1" ~header:"deploy" ~choices:[ choice ~id:"c1" ~label:"yes" ] ]
      ~context:"original task" ?task_id ~continuation ~asked_at:100. () |> Result.get_ok in
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

let test_original_question_input_uses_canonical_store_and_keeps_unlinked_state () =
  with_persistence @@ fun config ensure_keeper ->
  let base_path = config.Workspace.base_path and keeper_name = "alpha" in
  ensure_keeper keeper_name;
  let chosen = Keeper_ask.choice ~choice_id:"choice-original" ~label:"원래 선택지"
      ~description:"ORIGINAL_CHOICE_DETAIL\n기존 작업의 결정" () |> Result.get_ok in
  let multi = Keeper_ask.question ~question_id:"choice-question" ~header:"same header"
      ~prompt:"ORIGINAL_CHOICE_PROMPT: 원래 작업에서 어느 선택지를 고를까요?"
      ~choices:[chosen;choice ~id:"other-choice" ~label:"다른 선택지"]
      ~mode:Keeper_ask.Multi ~free_text:Keeper_ask.Choices_only |> Result.get_ok in
  let full_prompt = String.concat "\n" (List.init 25 (fun _ -> "원래 질문의 긴 설명")) ^ "\nORIGINAL_PROMPT_TAIL" in
  let written = Keeper_ask.question ~question_id:"written-question" ~header:"same header"
      ~prompt:full_prompt ~choices:[] ~mode:Keeper_ask.Single
      ~free_text:(Keeper_ask.Free_text_allowed {hint=Some "ORIGINAL_WRITING_HINT"}) |> Result.get_ok in
  let skipped = question ~id:"skipped-question" ~header:"decline"
      ~choices:[choice ~id:"unused" ~label:"not selected"] in
  let ask = Keeper_ask.ask ~ask_id:"canonical-original-context" ~keeper_name
      ~questions:[multi;written;skipped] ~context:"ORIGINAL_ASK_PURPOSE\n원래 이유 전체"
      ~task_id:"task-101" ~goal_id:"goal-original" ~source_turn_ref:(Ids.Turn_ref.make ~trace_id:"original-asking-trace" ~absolute_turn:17)
      ~continuation:(Keeper_continuation_channel.unrouted "original context fixture")
      ~asked_at:100. () |> Result.get_ok in
  Keeper_ask_store.record_ask ~base_path ask |> Result.get_ok;
  let text = "CANONICAL_WRITTEN_ANSWER\nquote=\"원문\"\\tail" in
  Keeper_ask_store.answer ~base_path ~keeper_name ~ask_id:ask.ask_id
    ~submissions:[written.question_id,Keeper_ask.Wrote text;
      skipped.question_id,Keeper_ask.Skipped;
      multi.question_id,Keeper_ask.Chose {choice_ids=["other-choice";"choice-original"]}]
    ~responder ~now:200. |> Result.get_ok |> ignore;
  check bool "late losing answer is refused" true
    (Result.is_error (Keeper_ask_store.answer ~base_path ~keeper_name ~ask_id:ask.ask_id
      ~submissions:[written.question_id,Keeper_ask.Wrote "LOSING_ANSWER"] ~responder ~now:201.));
  let current = Keeper_id.Task_id.of_string "task-900" |> Result.get_ok in
  let current_meta = {meta with current_task_id=Some current} in
  let read_input ask_id = match Keeper_ask_store.rows_result ~base_path ~keeper_name with
    | Ok (Keeper_ask_store.Stored_rows rows) ->
        (match List.assoc ask_id rows with
         | original_ask,Keeper_ask.Answered_by {answers;responder;answered_at} ->
             Keeper_world_observation.pending_board_event_of_ask_answer
               ~meta:current_meta ~ask:original_ask ~answers ~responder ~answered_at
         | _,(Keeper_ask.Open | Keeper_ask.Withdrawn_because _) -> fail "canonical answer missing")
    | Ok Missing_log -> fail "canonical log missing"
    | Error error -> fail (Keeper_ask_store.read_error_to_string error) in
  let row = read_input ask.ask_id in
  let fields = Keeper_unified_prompt.For_testing.board_event_fields row in
  let origin = List.assoc "ask_origin" fields |> Yojson.Safe.from_string in
  let open Yojson.Safe.Util in
  check string "original Task is not current Task" "task-101" (origin |> member "task_id" |> to_string);
  check string "original Goal" "goal-original" (origin |> member "goal_id" |> to_string);
  check string "original asking execution" "original-asking-trace#17"
    (origin |> member "source_turn_ref" |> to_string);
  check string "original purpose remains complete" (Option.get ask.context) (origin |> member "context" |> to_string);
  check (float 0.) "canonical first answer time" 200. (origin |> member "answered_at" |> to_float);
  check string "canonical exact input identity"
    (Keeper_ask.answer_source_id ~ask_id:ask.ask_id ~answered_at:200. |> Option.get)
    (origin |> member "answer_source_id" |> to_string);
  let questions = List.assoc "questions" fields |> Yojson.Safe.from_string |> to_list in
  check string "complete original prompt tail survives canonical storage" full_prompt
    (List.nth questions 1 |> member "prompt" |> to_string);
  check string "choice description survives canonical storage" (Option.get chosen.description)
    (List.hd questions |> member "choices" |> to_list |> List.hd |> member "description" |> to_string);
  let answers = List.assoc "answers" fields |> Yojson.Safe.from_string |> to_list in
  check (list string) "exact per-question binding follows original question order"
    [multi.question_id;written.question_id;skipped.question_id]
    (List.map (fun value -> value |> member "question_id" |> to_string) answers);
  check (list string) "selected identities retain canonical selection order"
    ["other-choice";"choice-original"]
    (List.hd answers |> member "response" |> member "choice_ids" |> to_list |> List.map to_string);
  check string "canonical text wins over later submission" text
    (List.nth answers 1 |> member "response" |> member "text" |> to_string);
  check string "declined is not an empty written answer" "skipped"
    (List.nth answers 2 |> member "response" |> member "kind" |> to_string);
  check bool "display changes do not remint answer identity" true
    (Keeper_world_observation.same_board_event_identity row {row with title="changed display";preview="changed preview"});
  let unlinked = persist_answer ~base_path ~keeper_name ~ask_id:"canonical-unlinked" () |> fun ask -> read_input ask.ask_id in
  let unlinked = Keeper_unified_prompt.For_testing.board_event_fields unlinked
      |> List.assoc "ask_origin" |> Yojson.Safe.from_string in
  List.iter (fun key -> check bool "absent original binding stays explicit and unobserved" true
    (member key unlinked = `Null)) ["task_id";"goal_id";"source_turn_ref"];
  check int "input projection did not enqueue a wake" 0 (List.length (pending_asks ~base_path ~keeper_name))
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
  let deferred_hint_logs_since since_seq =
    let expected = Printf.sprintf "answer wake durably pending; live hint deferred ask_id=%s" ask.ask_id in
    Log.Ring.recent ~since_seq ~module_filter:"Keeper" ~order:`Oldest_first ()
    |> List.filter (fun (entry : Log.Ring.entry) -> String.equal entry.message expected)
    |> List.length
  in
  let seq0 = (Log.Ring.bounds ()).total - 1 in
  let recovered = reconcile_or_fail ~base_path in
  check int "canonical record recovers without another answer" 1 recovered.enqueued;
  check int "recovery has no retained failures" 0 (List.length recovered.failures);
  check int "initial enqueue logs deferred wake hint once" 1 (deferred_hint_logs_since seq0);
  let source = match pending_asks ~base_path ~keeper_name with
    | [ source, payload ] ->
        check string "original ask pointer" ask.ask_id payload.Keeper_event_queue.ask_id;
        check bool "original continuation is retained" true (payload.channel = ask.continuation);
        check (float 0.) "canonical answer timestamp is stable" 200. source.Keeper_event_queue.arrived_at;
        source
    | _ -> fail "recovery did not create one exact answer source" in
  let seq1 = (Log.Ring.bounds ()).total - 1 in
  (match Wake.deliver ~base_path ~keeper_name ~ask_id:ask.ask_id with
   | Ok Wake.Already_pending -> ()
   | Ok _ -> fail "pending answer delivery was not idempotent"
   | Error error -> fail (Wake.error_to_string error));
  check int "already-pending delivery suppresses repeat deferred wake log" 0 (deferred_hint_logs_since seq1);
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

let test_followup_publishes_sources_before_join () =
  with_persistence @@ fun config ensure_keeper ->
  let base_path=config.Workspace.base_path and keeper_name="alpha" in
  ensure_keeper keeper_name;
  let task_id = match Workspace_task_create.add_task_with_result config ~created_by:keeper_name
      ~title:"original streamed Task" ~priority:3 ~description:"source delivery fixture" with
    | Ok created -> created.task_id
    | Error error -> fail (Workspace_task_create.add_task_error_to_string error) in
  let ask = persist_answer ~base_path ~keeper_name ~ask_id:"streamed-original" ~task_id () in
  let resolution = match Keeper_ask_store.rows_result ~base_path ~keeper_name with
    | Ok (Keeper_ask_store.Stored_rows rows) -> snd (List.assoc ask.ask_id rows)
    | Ok Missing_log | Error _ -> fail "stream source lost its canonical answer" in
  let task_ready,task_resolve = Eio.Promise.create () in
  let release,release_resolve = Eio.Promise.create () in
  let started = ref None and joined = ref false in
  let observed,_ = Eio.Fiber.pair
      (fun () ->
        let result = Wake.observe_followup ~base_path ~keeper_name ~ask ~resolution
            ~on_started:(fun identity ->
              check bool "one canonical answer capture starts the source stream" true (Option.is_none !started);
              started := Some identity)
            ~on_source:(fun identity source ->
              (match !started with
               | Some original -> check bool "every source retains the original answer" true
                   (original=identity)
               | None -> fail "source preceded canonical identity");
              match source with
              | Wake.Reaction_evidence _ -> Eio.Promise.await release
              | Tool_results _ -> ()
              | Linked_task (Wake.Task_observed value) ->
                check string "early Task belongs to the original question" task_id value.task_id;
                Eio.Promise.resolve task_resolve ()
              | Linked_task (Task_unlinked | Task_missing _ | Task_unavailable _) ->
                fail "original streamed Task was unavailable") () in
        joined := true;
        result)
      (fun () ->
        Eio.Promise.await task_ready;
        check bool "a usable Task source arrives before the aggregate settles" false !joined;
        Eio.Promise.resolve release_resolve ()) in
  check bool "all source readers still settle the aggregate" true (Result.is_ok observed);
  check int "streaming observations create no wake" 0 (List.length (pending_asks ~base_path ~keeper_name))
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
  let observe () = Wake.observe_followup ~base_path ~keeper_name ~ask ~resolution ()
      |> function Ok value -> value | Error detail -> fail detail in
  let before = observe () |> Wake.followup_to_json in
  check bool "no turn is invented from recording the answer" true
    (Yojson.Safe.Util.member "turn_started_at" (Yojson.Safe.Util.member "reaction_evidence" before) = `Null);
  check int "observing never enqueues a wake" 0 (List.length (pending_asks ~base_path ~keeper_name));
  (match Wake.deliver ~base_path ~keeper_name ~ask_id:ask.ask_id with
   | Ok _ -> () | Error error -> fail (Wake.error_to_string error));
  let source = match pending_asks ~base_path ~keeper_name with
    | [source, _] -> source | _ -> fail "original wake did not persist exactly once" in
  Keeper_reaction_ledger.record_event_queue_turn_started ~base_path ~keeper_name source;
  let entered = observe () |> Wake.followup_to_json in
  check bool "original source turn entry is observed" true
    (Yojson.Safe.Util.member "turn_started_at" (Yojson.Safe.Util.member "reaction_evidence" entered) <> `Null);
  let left, right = Eio.Fiber.pair observe observe in
  check string "concurrent native reader results retain the same exact source"
    left.stimulus_id right.stimulus_id;
  let other_payload = {Keeper_event_queue.ask_id="other-question"; channel=ask.continuation} in
  let other = {source with post_id=Keeper_event_queue.ask_answered_post_id other_payload;
      payload=Keeper_event_queue.Ask_answered other_payload} in
  Keeper_reaction_ledger.record_event_queue_turn_finished ~base_path ~keeper_name
    ~disposition:"test-boundary" other;
  let unrelated = observe () |> Wake.followup_to_json in
  check bool "another question cannot supply a turn boundary" true
    (Yojson.Safe.Util.member "turn_finished_at" (Yojson.Safe.Util.member "reaction_evidence" unrelated) = `Null);
  Keeper_reaction_ledger.record_event_queue_turn_finished ~base_path ~keeper_name
    ~disposition:"test-boundary" source;
  let finished = observe () |> Wake.followup_to_json in
  check bool "the original turn boundary is observed" true
    (Yojson.Safe.Util.member "turn_finished_at" (Yojson.Safe.Util.member "reaction_evidence" finished) <> `Null);
  check int "repeated observation never duplicates the pending source" 1
    (List.length (pending_asks ~base_path ~keeper_name));
  check bool "another Keeper cannot inherit this question's source" true
    (Result.is_error (Wake.observe_followup ~base_path ~keeper_name:"beta" ~ask ~resolution ()));
  List.iter (fun field -> check bool "followup metadata carries no human content or invented action" true
    (Yojson.Safe.Util.member field finished = `Null)) ["answers";"questions";"responder";"tool_action";"quarantine_reason"];
  Dated_jsonl.append (Dated_jsonl.open_store (Keeper_reaction_ledger.location ~base_path ~keeper_name))
    (`Assoc ["stimulus_id", `String left.stimulus_id; "record_kind", `String "reaction"]);
  let quarantined = observe () |> Wake.followup_to_json in
  check bool "quarantined matching row marks evidence incomplete" false
    (Yojson.Safe.Util.member "evidence_complete" (Yojson.Safe.Util.member "reaction_evidence" quarantined) |> Yojson.Safe.Util.to_bool);
  check bool "quarantined matching row exposes its quarantine reason code" true
    (match Yojson.Safe.Util.member "quarantine_reason" (Yojson.Safe.Util.member "reaction_evidence" quarantined) with
     | `String reason -> String.length reason > 0
     | _ -> false)
;;

let test_followup_keeps_original_task_through_archive_and_read_failure () =
  with_persistence @@ fun config ensure_keeper ->
  let base_path = config.Workspace.base_path and keeper_name = "alpha" in
  ensure_keeper keeper_name;
  let create title = match Workspace_task_create.add_task_with_result config
      ~title ~priority:3 ~description:"private Task description" with
    | Ok created -> created.task_id
    | Error error -> fail (Workspace_task_create.add_task_error_to_string error) in
  let original_id = create "original question Task" in
  let unrelated_id = create "a later unrelated Task" in
  let backlog () = Workspace_backlog.read_backlog_r config |> Result.get_ok in
  let original = List.find (fun (task : Masc_domain.task) -> task.id = original_id) (backlog ()).tasks in
  let unrelated = List.find (fun (task : Masc_domain.task) -> task.id = unrelated_id) (backlog ()).tasks in
  let replace tasks = Workspace_utils.with_file_lock config (Workspace_backlog.backlog_lock_path config)
      (fun () -> Workspace_backlog.write_backlog config {(backlog ()) with tasks}) in
  let at = "2026-10-17T00:00:00Z" in
  let done_status : Masc_domain.task_status = Done {assignee="other-worker";completed_at=at;notes=Some "private notes"} in
  let in_progress : Masc_domain.task_status = InProgress {assignee="replacement-worker";started_at=at} in
  replace [{original with task_status=in_progress};{unrelated with task_status=done_status}];
  let ask = persist_answer ~base_path ~keeper_name ~ask_id:"original-task" ~task_id:original_id () in
  let resolution ask = match Keeper_ask_store.rows_result ~base_path ~keeper_name with
    | Ok (Keeper_ask_store.Stored_rows rows) -> snd (List.assoc ask.Keeper_ask.ask_id rows)
    | Ok Missing_log -> fail "canonical answer disappeared"
    | Error error -> fail (Keeper_ask_store.read_error_to_string error) in
  let observe ask = match Wake.observe_followup ~base_path ~keeper_name ~ask ~resolution:(resolution ask) () with
    | Ok value -> value | Error detail -> fail detail in
  let check_status label location status = match (observe ask).linked_task with
    | Wake.Task_observed value ->
        check string (label ^ " original Task") original_id value.task_id;
        check bool (label ^ " phase and source") true
          (value.location=location && value.status=status && Float.is_finite value.observed_at)
    | Task_unlinked | Task_missing _ | Task_unavailable _ -> fail (label ^ ": Task not observed") in
  check_status "different worker and unrelated Done" Workspace_query.Task_backlog in_progress;
  let submitted : Masc_domain.task_status = AwaitingVerification
      {assignee="replacement-worker";started_at=at;submitted_at=at;verification_id="verification-original"} in
  replace [{original with task_status=submitted}];
  check_status "submission is awaiting verification" Workspace_query.Task_backlog submitted;
  let archived = {original with task_status=done_status} in
  Workspace_task_id.append_archive_tasks config [archived] |> Result.get_ok;
  replace [{unrelated with task_status=done_status}];
  let done_metadata : Masc_domain.task_status = Done {assignee="other-worker";completed_at=at;notes=None} in
  check_status "archived original" Workspace_query.Task_archive done_metadata;
  let wire = Wake.followup_to_json (observe ask) |> Yojson.Safe.to_string in
  List.iter (fun secret -> check bool "free text excluded" false (contains wire secret))
    ["private notes";"private Task description";"original question Task"];
  let cancelled : Masc_domain.task_status = Cancelled {cancelled_by="operator";cancelled_at=at;reason=None} in
  Workspace_task_id.append_archive_tasks config [{original with task_status=cancelled}] |> Result.get_ok;
  check_status "archive rewrite invalidates index" Workspace_query.Task_archive cancelled;
  Workspace_task_id.drop_archive_tasks config ~ids:[original_id] |> Result.get_ok;
  check bool "missing remains unobserved" true
    (match (observe ask).linked_task with Task_missing id -> id=original_id
     | Task_unlinked | Task_observed _ | Task_unavailable _ -> false);
  let write_archive rows = Workspace_utils.write_json config (Workspace_utils.archive_path config)
      (`Assoc ["tasks",`List rows;"last_updated",`String at]) in
  let original_json = Masc_domain.task_to_yojson archived in
  write_archive [original_json;`Assoc ["id",`String unrelated_id;"status",`String "corrupt"]];
  check_status "unrelated known-id corrupt row" Workspace_query.Task_archive done_metadata;
  write_archive [original_json;original_json];
  check bool "duplicate original identity is unavailable" true
    (match (observe ask).linked_task with Task_unavailable {task_id;_} -> task_id=original_id
     | Task_unlinked | Task_observed _ | Task_missing _ -> false);
  write_archive [`Assoc ["status",`String "done"]];
  check bool "unidentified row cannot prove absence" true
    (match (observe ask).linked_task with Task_unavailable _ -> true
     | Task_unlinked | Task_observed _ | Task_missing _ -> false);
  replace [{original with task_status=in_progress}];
  Workspace_task_id.drop_archive_tasks config ~ids:[original_id] |> Result.get_ok;
  check_status "restored primary" Workspace_query.Task_backlog in_progress;
  replace [{original with task_status=done_status}];
  write_archive [original_json];
  Workspace_utils.write_json config (Workspace_backlog.backlog_path config) (`String "broken primary");
  check bool "recovery and archive cannot replace unreadable primary" true
    (match (observe ask).linked_task with Task_unavailable _ -> true
     | Task_unlinked | Task_observed _ | Task_missing _ -> false);
  let unlinked = persist_answer ~base_path ~keeper_name ~ask_id:"no-task" () in
  check bool "unlinked question does not need Task storage" true
    (match (observe unlinked).linked_task with Task_unlinked -> true
     | Task_unavailable _ | Task_observed _ | Task_missing _ -> false);
  check int "observation never enqueued an answer" 0 (List.length (pending_asks ~base_path ~keeper_name))
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
  let observed = match Wake.observe_followup ~base_path ~keeper_name ~ask ~resolution () with
    | Ok observed -> Wake.followup_to_json observed | Error detail -> fail detail in
  check bool "queue settlement is an independent positive fact" true
    (Yojson.Safe.Util.member "queue_settled_at" (Yojson.Safe.Util.member "reaction_evidence" observed) <> `Null);
  check bool "queue settlement supplies neither turn entry nor boundary" true
    (Yojson.Safe.Util.member "turn_started_at" (Yojson.Safe.Util.member "reaction_evidence" observed) = `Null
     && Yojson.Safe.Util.member "turn_finished_at" (Yojson.Safe.Util.member "reaction_evidence" observed) = `Null)
;;

let test_followup_matches_committed_answer_input_tool_rows () =
  with_persistence @@ fun config ensure_keeper ->
  Eio.Switch.run @@ fun sw ->
  Keeper_tool_call_log.reset_for_testing ();
  Eio.Switch.on_release sw (fun () ->
    Option.iter (fun store -> Keeper_tool_call_index.forget_for_ledger
        ~ledger_dir:(Dated_jsonl.base_dir store)) (Keeper_tool_call_log.store ());
    Keeper_tool_call_log.reset_for_testing ());
  let base_path = config.Workspace.base_path and keeper_name = "alpha" in
  ensure_keeper keeper_name;
  let task_id = match Workspace_task_create.add_task_with_result config ~created_by:keeper_name
      ~title:"original followup Task" ~priority:3 ~description:"independent observation fixture" with
    | Ok created -> created.task_id
    | Error error -> fail (Workspace_task_create.add_task_error_to_string error) in
  let ask = persist_answer ~base_path ~keeper_name ~ask_id:"tool-source" ~task_id () in
  let answers, answered_at, resolution = match Keeper_ask_store.rows_result ~base_path ~keeper_name with
    | Ok (Keeper_ask_store.Stored_rows rows) ->
        (match snd (List.assoc ask.ask_id rows) with
         | Keeper_ask.Answered_by ({answers;answered_at;_} as answer) ->
             answers, answered_at, Keeper_ask.Answered_by answer
         | Keeper_ask.Open | Keeper_ask.Withdrawn_because _ -> fail "answer was not canonical")
    | Ok Missing_log -> fail "canonical answer disappeared"
    | Error error -> fail (Keeper_ask_store.read_error_to_string error) in
  let row = Keeper_world_observation.pending_board_event_of_ask_answer
      ~meta ~ask ~answers ~responder ~answered_at in
  let source = match row.event_kind with
    | Keeper_world_observation.Ask_answered_row {answer_source_id=Some source;_} -> source
    | Ask_answered_row {answer_source_id=None;_}
    | Board_post_created | Board_post_updated | Board_comment_added _
    | Board_reaction_changed _ | Board_vote_cast _ | Fusion_completed
    | Delegate_completed _ | Composition_completed | Owned_job_completed _
    | Schedule_due _ | External_attention _ | Completion_authority_rejected _
    | Task_outcome _ | Task_cancelled _ -> fail "canonical answer input did not retain its exact source" in
  let other_source = Keeper_ask.answer_source_id ~ask_id:ask.ask_id ~answered_at:(answered_at+.1.)
      |> Option.get in
  Keeper_tool_call_log.init ~base_path ();
  let observe () = match Wake.observe_followup ~base_path ~keeper_name ~ask ~resolution () with
    | Ok value -> value | Error detail -> fail detail in
  let actions () = match (observe ()).tool_actions with
    | Ok actions -> actions | Error detail -> fail detail in
  check int "an initialized ledger does not invent a Tool result" 0 (actions ()).observed_count;
  let original = Keeper_tool_call_log.create_turn_ctx_cell ()
  and interleaved = Keeper_tool_call_log.create_turn_ctx_cell () in
  Keeper_tool_call_log.set_turn_context ~cell:original ~trace_id:"original-trace"
    ~keeper_turn_id:17 ~answer_source_ids:[source] ();
  Keeper_tool_call_log.set_turn_context ~cell:interleaved ~trace_id:"other-trace"
    ~keeper_turn_id:18 ~answer_source_ids:[other_source] ();
  let invocation () = Agent_core.Tool_contract.Invocation.create
      ~tool_use_id:"repeated-provider-id" ~turn:1
      ~schedule:{planned_index=0;batch_index=0;batch_size=1;execution_mode=Serial}
      ~completion:Agent_core.Tool_contract.Continue_after_success in
  let emit ?disposition ~invocation ~cell ~keeper_name ~execution_id ~wire_outcome () =
    let context = Keeper_tool_call_log_context.get_turn_context_record ~cell () in
    Keeper_tool_call_log.log_call ~keeper_name ~tool_name:"Read"
      ~input:(`Assoc []) ~output_text:"private result" ~duration_ms:1. ~wire_outcome ?disposition
      ~execution_id:(Ids.Execution_id.of_string execution_id)
      ~physical_execution_id:(Keeper_tool_call_log.invocation_execution_id ~invocation)
      ?trace_id:context.trace_id ?keeper_turn_id:context.keeper_turn_id
      ~answer_source_ids:context.answer_source_ids ~on_committed:(fun () -> ()) () in
  let original_invocation = invocation () in
  emit ~invocation:original_invocation ~cell:original ~keeper_name ~execution_id:"original-tool" ~wire_outcome:Tool_result.Ok ();
  emit ~invocation:(invocation ()) ~cell:interleaved ~keeper_name ~execution_id:"other-answer-time" ~wire_outcome:Tool_result.Ok ();
  emit ~invocation:(invocation ()) ~cell:original ~keeper_name:"beta" ~execution_id:"other-keeper" ~wire_outcome:Tool_result.Ok ();
  let observed = actions () in
  check int "only the original canonical answer input supplies a Tool result" 1 observed.observed_count;
  (match observed.latest with
   | Some action ->
       check string "the original logical identity survives interleaved context" "original-tool" action.execution_id;
       check string "the physical invocation survives repeated access"
         (Ids.Execution_id.to_string (Keeper_tool_call_log.invocation_execution_id ~invocation:original_invocation))
         action.physical_execution_id;
       check string "the original input turn remains exact" "original-trace" action.trace_id;
       check int "the original Keeper turn remains exact" 17 action.keeper_turn_id
   | None -> fail "physical Tool identity was lost");
  let reaction_path = Keeper_reaction_ledger.store_dir ~base_path ~keeper_name in
  let detached = reaction_path ^ ".fixture-detached" in
  let had_reactions = Sys.file_exists reaction_path in
  if had_reactions then Unix.rename reaction_path detached;
  Fs_compat.mkdir_p (Filename.dirname reaction_path);
  Fun.protect ~finally:(fun () ->
      Unix.unlink reaction_path;
      if had_reactions then Unix.rename detached reaction_path) (fun () ->
    Out_channel.with_open_bin reaction_path (fun channel -> output_string channel "unreadable reaction directory\n");
    let partial = observe () in
    check bool "reaction storage failure stays explicit" true (Result.is_error partial.reactions);
    check int "reaction storage failure cannot hide a committed Tool result" 1
      (match partial.tool_actions with Ok actions -> actions.observed_count | Error detail -> fail detail);
    check bool "reaction storage failure cannot hide the original Task" true
      (match partial.linked_task with
       | Wake.Task_observed value -> value.task_id=task_id && value.status=Masc_domain.Todo
       | Task_unlinked | Task_missing _ | Task_unavailable _ -> false);
    let wire = Wake.followup_to_json partial in
    check bool "reaction failure is an unavailable branch, not empty turn evidence" true
      (Yojson.Safe.Util.member "reaction_evidence" wire = `Assoc ["state", `String "unavailable"]);
    check int "partial evidence observation does not enqueue a wake" 0
      (List.length (pending_asks ~base_path ~keeper_name)));
  let failed_invocation = invocation () in
  emit ~invocation:failed_invocation ~cell:original ~keeper_name ~execution_id:"failed-tool" ~wire_outcome:Tool_result.Error ();
  check int "observed errors are results, not proof of successful effects" 2 (actions ()).observed_count;
  emit ~invocation:(invocation ()) ~cell:original ~keeper_name ~execution_id:"failed-tool" ~wire_outcome:Tool_result.Ok ();
  check int "a fresh recheck of one logical node is a distinct physical result" 3 (actions ()).observed_count;
  emit ~disposition:(Tool_result.Completed ()) ~invocation:(invocation ()) ~cell:original
    ~keeper_name ~execution_id:"typed-completed" ~wire_outcome:Tool_result.Error ();
  emit ~disposition:(Tool_result.Deferred ()) ~invocation:(invocation ()) ~cell:original
    ~keeper_name ~execution_id:"typed-deferred" ~wire_outcome:Tool_result.Error ();
  emit ~disposition:(Tool_result.Failed Tool_result.Runtime_failure) ~invocation:(invocation ()) ~cell:original
    ~keeper_name ~execution_id:"typed-failed" ~wire_outcome:Tool_result.Ok ();
  emit ~invocation:(invocation ()) ~cell:original ~keeper_name ~execution_id:"unknown-result"
    ~wire_outcome:Tool_result.Unknown ();
  (* Append a structurally valid physical observation whose outcome field is
     damaged. Its original answer/turn identity stays in the cohort. *)
  let path = Keeper_tool_call_log.current_log_path () |> Option.get in
  let template = Fs_compat.load_file path |> String.split_on_char '\n'
    |> List.filter_map (fun line -> if String.trim line="" then None else Some (Yojson.Safe.from_string line))
    |> List.find (fun row -> Yojson.Safe.Util.member "execution_id" row = `String "original-tool") in
  let malformed_id = Keeper_tool_call_log.invocation_execution_id ~invocation:(invocation ()) |> Ids.Execution_id.to_string in
  let malformed = match template with
    | `Assoc fields -> `Assoc (("physical_execution_id",`String malformed_id)
        :: ("execution_id",`String "malformed-result") :: ("disposition",`Bool true)
        :: List.filter (fun (key,_) -> not (List.mem key ["physical_execution_id";"execution_id";"disposition"])) fields)
    | _ -> fail "committed fixture result was not an object" in
  let channel = open_out_gen [Open_wronly;Open_append;Open_binary] 0o600 path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () ->
    output_string channel (Yojson.Safe.to_string malformed ^ "\n"));
  let classified = actions () in
  check int "every original physical result remains observed" 8 classified.observed_count;
  check int "typed completion wins over a failed wire delivery" 3 classified.outcomes.succeeded;
  check int "typed and wire failures remain failures" 2 classified.outcomes.failed;
  check int "typed deferral is not flattened into wire failure" 1 classified.outcomes.deferred;
  check int "unknown outcome remains separate" 1 classified.outcomes.unsettled;
  check int "malformed outcome retains its physical observation" 1 classified.outcomes.malformed;
  check bool "Tool outcomes cannot advance the original Task" true
    (match (observe ()).linked_task with
     | Wake.Task_observed value -> value.task_id=task_id && value.status=Masc_domain.Todo
     | Task_unlinked | Task_missing _ | Task_unavailable _ -> false);
  Keeper_tool_call_log.log_call ~keeper_name ~tool_name:"native-operand"
    ~input:(`Assoc []) ~output_text:"logical value" ~duration_ms:0. ~wire_outcome:Tool_result.Ok
    ~execution_id:(Ids.Execution_id.of_string "logical-only")
    ~answer_source_ids:[source] ~on_committed:(fun () -> ()) ();
  check int "a logical-only row neither invents a call nor hides known physical results" 8 (actions ()).observed_count;
  check int "observing Tool rows does not enqueue an answer again" 0
    (List.length (pending_asks ~base_path ~keeper_name));
  emit ~invocation:failed_invocation ~cell:original ~keeper_name ~execution_id:"failed-tool" ~wire_outcome:Tool_result.Error ();
  check bool "duplicate execution evidence cannot become a confident count" true
    (Result.is_error (observe ()).tool_actions);
  let path = Keeper_tool_call_log.current_log_path () |> Option.get in
  Fs_compat.save_file path "";
  emit ~invocation:(invocation ()) ~cell:interleaved ~keeper_name ~execution_id:"replacement-unrelated" ~wire_outcome:Tool_result.Ok ();
  check int "ledger shrink rebuilds source membership instead of inheriting stale offsets" 0
    (actions ()).observed_count;
  Keeper_tool_call_log.init ~base_path:(Filename.concat base_path "other-workspace") ();
  check bool "another workspace cannot supply a Tool observation" true
    (Result.is_error (observe ()).tool_actions)
;;

let () =
  run "keeper_ask_answer_wake"
    [ ( "wake"
      , [ test_case "real Ask producer preserves frozen source through storage and answer" `Quick
            test_ask_producer_keeps_frozen_source_through_answer
        ; test_case "original question input uses canonical store and preserves absent bindings" `Quick
            test_original_question_input_uses_canonical_store_and_keeps_unlinked_state
        ; test_case "original linked Task survives archive and read failure" `Quick
            test_followup_keeps_original_task_through_archive_and_read_failure
        ; test_case "Tool followup binds exact canonical answer inputs and committed rows" `Quick
            test_followup_matches_committed_answer_input_tool_rows
        ; test_case "queue settlement does not invent a turn" `Quick
            test_followup_queue_settlement_does_not_invent_a_turn
        ; test_case "followup reads exact source without waking" `Quick
            test_followup_reads_exact_source_without_waking
        ; test_case "followup publishes original Task source before aggregate join" `Quick
            test_followup_publishes_sources_before_join
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
