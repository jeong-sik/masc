(* RFC-0266 Phase 1 — fusion async-completion wake + actionable delivery.

   The wake (Fusion_sink.wake_keeper_on_fusion_completion -> wakeup_keeper) needs
   a live registry, so it is exercised end-to-end at runtime rather than here.
   These unit checks pin the two compile-passing-but-silently-wrong failure
   modes a stub could introduce:

   1. the closed-sum helpers must classify the new [Fusion_completed] variant
      (label / is_board_signal / reaction-ledger kind); and
   2. a completed fusion must become a NON-EMPTY [pending_board_event] carrying
      the resolved answer — returning [] (like the Bootstrap/No_progress_recovery
      arms) would compile but silently drop the result, defeating the RFC. *)

open Alcotest
open Masc

(* substring check without pulling in the [str] library *)
let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.equal (String.sub haystack i nl) needle || go (i + 1)) in
  nl = 0 || go 0
;;

let temp_base_path prefix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))
;;

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path
;;

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""
;;

(* Board_dispatch.create_post (via Fusion_sink.emit) needs a live Eio
   scheduler for its lock/cancellation-context effects (Effect.Unhandled
   (Eio.Cancel.Get_context) otherwise) — same [Eio_main.run] +
   [Fs_compat.set_fs] wrapper test_board_dispatch.ml's [with_eio] uses. *)
let with_isolated_base_path prefix f =
  let base_dir = temp_base_path prefix in
  let old_base = Sys.getenv_opt "MASC_BASE_PATH" in
  let old_base_input = Sys.getenv_opt "MASC_BASE_PATH_INPUT" in
  Fun.protect
    ~finally:(fun () ->
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      restore_env "MASC_BASE_PATH" old_base;
      restore_env "MASC_BASE_PATH_INPUT" old_base_input;
      try remove_tree base_dir with _ -> ())
    (fun () ->
      Unix.putenv "MASC_BASE_PATH" base_dir;
      Unix.putenv "MASC_BASE_PATH_INPUT" base_dir;
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      f base_dir)
;;

let make_meta ?(name = "fusion-keeper") () : Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ ("name", `String name)
         ; ("agent_name", `String name)
         ; ("trace_id", `String "test-trace-fusion")
         ])
  with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_meta failed: %s" e)
;;

let fusion_payload
      ?(run_id = "fus-1")
      ?(ok = true)
      ?(resolved_answer = "use approach B because it is reversible")
      ?(board_post_id = "post-77")
      ()
  : Keeper_event_queue.fusion_completion
  =
  { run_id; ok; resolved_answer; board_post_id }
;;

let fusion_stimulus ?run_id ?ok ?resolved_answer ?board_post_id () : Keeper_event_queue.stimulus =
  { post_id = "ignored-by-fusion-arm"
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = 1000.0
  ; payload =
      Keeper_event_queue.Fusion_completed
        (fusion_payload ?run_id ?ok ?resolved_answer ?board_post_id ())
  }
;;

let judge_synthesis resolved_answer : Fusion_types.judge_synthesis =
  { consensus = []
  ; contradictions = []
  ; partial_coverage = []
  ; unique_insights = []
  ; blind_spots = []
  ; resolved_answer
  ; decision = Fusion_types.Answer resolved_answer
  }
;;

let bg_payload
      ?(bg_run_id = "bg-1")
      ?(bg_kind = Keeper_event_queue.Subprocess)
      ?(bg_outcome = Keeper_event_queue.Bg_ok "background output")
      ?(bg_board_post_id = "post-bg-1")
      ()
  : Keeper_event_queue.bg_job_completion
  =
  { bg_run_id; bg_kind; bg_outcome; bg_board_post_id }
;;

let bg_stimulus ?bg_run_id ?bg_kind ?bg_outcome ?bg_board_post_id ()
  : Keeper_event_queue.stimulus
  =
  { post_id = "ignored-by-bg-arm"
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = 2000.0
  ; payload =
      Keeper_event_queue.Bg_completed
        (bg_payload ?bg_run_id ?bg_kind ?bg_outcome ?bg_board_post_id ())
  }
;;

let scheduled_wake
      ?(schedule_id = "sched-1")
      ?(due_at = 3000.0)
      ?(payload_digest = "digest-1")
      ?(title = Some "Scheduled lane wake")
      ?(message = "SCHEDULE-ANSWER-TOKEN")
      ()
  : Keeper_event_queue.scheduled_wake
  =
  { schedule_id; due_at; payload_digest; title; message }
;;

let schedule_stimulus ?schedule_id ?due_at ?payload_digest ?title ?message ()
  : Keeper_event_queue.stimulus
  =
  let wake = scheduled_wake ?schedule_id ?due_at ?payload_digest ?title ?message () in
  { post_id = Keeper_event_queue.schedule_due_post_id wake
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = 3000.0
  ; payload = Keeper_event_queue.Schedule_due wake
  }
;;

(* (1) closed-sum helpers classify the new variant *)
let test_closed_sum_helpers () =
  let p = Keeper_event_queue.Fusion_completed (fusion_payload ()) in
  check string "payload_kind_label" "fusion_completed" (Keeper_event_queue.payload_kind_label p);
  check bool "is_board_signal is false" false (Keeper_event_queue.is_board_signal p);
  check
    string
    "reaction_ledger stimulus_kind_to_string"
    "fusion_completed"
    (Keeper_reaction_ledger.stimulus_kind_to_string Keeper_reaction_ledger.Fusion_completed)
;;

(* (2) THE behavioral guard: a completed fusion becomes a non-empty actionable
   pending_board_event that carries the resolved answer. *)
let test_fusion_completion_is_actionable () =
  let meta = make_meta () in
  let fc = fusion_payload ~resolved_answer:"ANSWER-TOKEN-xyz" ~board_post_id:"post-77" () in
  let ev : Keeper_world_observation.pending_board_event =
    Keeper_world_observation.pending_board_event_of_fusion_completion
      ~meta
      ~arrived_at:1000.0
      fc
  in
  check string "post_id correlates to the board post" "post-77" ev.post_id;
  check bool "preview carries the resolved answer" true (contains ~needle:"ANSWER-TOKEN-xyz" ev.preview);
  (* RFC-0247: a self-authored System_post fusion result renders observationally,
     not as trusted operator instruction. *)
  check
    bool
    "provenance is Self_narrative"
    true
    (match ev.provenance with
     | Keeper_world_observation.Self_narrative -> true
     | _ -> false);
  (* the stimulus path yields Some (not None like Bootstrap/No_progress_recovery) *)
  match
    Keeper_world_observation.pending_board_event_of_stimulus
      ~continuity_summary:""
      ~meta
      (fusion_stimulus ~resolved_answer:"ANSWER-TOKEN-xyz" ())
  with
  | Some (ev : Keeper_world_observation.pending_board_event) ->
    check bool "stimulus path preview carries the answer" true (contains ~needle:"ANSWER-TOKEN-xyz" ev.preview)
  | None -> fail "Fusion_completed stimulus must produce Some pending_board_event, not None"
;;

(* RFC-0290: a completed background job follows the same non-empty delivery
   contract as Fusion_completed. *)
let test_bg_completion_is_actionable () =
  let meta = make_meta ~name:"bg-keeper" () in
  let bg =
    bg_payload
      ~bg_run_id:"bg-42"
      ~bg_outcome:(Keeper_event_queue.Bg_ok "BG-ANSWER-TOKEN")
      ~bg_board_post_id:"post-bg-42"
      ()
  in
  let ev : Keeper_world_observation.pending_board_event =
    Keeper_world_observation.pending_board_event_of_bg_job_completion
      ~meta
      ~arrived_at:2000.0
      bg
  in
  check string "post_id correlates to the board post" "post-bg-42" ev.post_id;
  check
    bool
    "title names the background subprocess completion"
    true
    (contains ~needle:"Background subprocess complete" ev.title);
  check
    bool
    "preview carries the background output"
    true
    (contains ~needle:"BG-ANSWER-TOKEN" ev.preview);
  check
    bool
    "provenance is Self_narrative"
    true
    (match ev.provenance with
     | Keeper_world_observation.Self_narrative -> true
     | _ -> false);
  match
    Keeper_world_observation.pending_board_event_of_stimulus
      ~continuity_summary:""
      ~meta
      (bg_stimulus ~bg_outcome:(Keeper_event_queue.Bg_ok "BG-ANSWER-TOKEN") ())
  with
  | Some (ev : Keeper_world_observation.pending_board_event) ->
    check
      bool
      "stimulus path preview carries the background output"
      true
      (contains ~needle:"BG-ANSWER-TOKEN" ev.preview)
  | None -> fail "Bg_completed stimulus must produce Some pending_board_event, not None"
;;

let test_bg_failure_missing_board_post_id_fallback () =
  let meta = make_meta ~name:"bg-keeper" () in
  let bg =
    bg_payload
      ~bg_run_id:"bg-9"
      ~bg_outcome:(Keeper_event_queue.Bg_failed "exit status 127")
      ~bg_board_post_id:""
      ()
  in
  let ev : Keeper_world_observation.pending_board_event =
    Keeper_world_observation.pending_board_event_of_bg_job_completion
      ~meta
      ~arrived_at:2000.0
      bg
  in
  check string "synthetic fallback post id" "bg-run:bg-9" ev.post_id;
  check bool "title marks failure" true (contains ~needle:"failed" ev.title);
  check
    bool
    "preview carries failure reason"
    true
    (contains ~needle:"exit status 127" ev.preview)
;;

let test_scheduled_wake_is_actionable () =
  let meta = make_meta ~name:"schedule-keeper" () in
  let wake = scheduled_wake ~message:"SCHEDULE-ANSWER-TOKEN" () in
  let ev : Keeper_world_observation.pending_board_event =
    Keeper_world_observation.pending_board_event_of_scheduled_wake
      ~meta
      ~arrived_at:3000.0
      wake
  in
  check string "post_id correlates to schedule" "schedule-due:sched-1" ev.post_id;
  check bool "preview carries schedule message" true
    (contains ~needle:"SCHEDULE-ANSWER-TOKEN" ev.preview);
  check bool "provenance is Automation" true
    (match ev.provenance with
     | Keeper_world_observation.Automation -> true
     | _ -> false);
  match
    Keeper_world_observation.pending_board_event_of_stimulus
      ~continuity_summary:""
      ~meta
      (schedule_stimulus ~message:"SCHEDULE-ANSWER-TOKEN" ())
  with
  | Some (ev : Keeper_world_observation.pending_board_event) ->
    check bool "stimulus path preview carries the schedule message" true
      (contains ~needle:"SCHEDULE-ANSWER-TOKEN" ev.preview)
  | None -> fail "Schedule_due stimulus must produce Some pending_board_event, not None"
;;

(* (3) an empty board_post_id (sink failed to create the post) still delivers
   the answer under a synthetic, non-empty post id. *)
let test_missing_board_post_id_fallback () =
  let meta = make_meta () in
  let fc = fusion_payload ~run_id:"fus-9" ~board_post_id:"" () in
  let ev : Keeper_world_observation.pending_board_event =
    Keeper_world_observation.pending_board_event_of_fusion_completion ~meta ~arrived_at:1.0 fc
  in
  check string "synthetic fallback post id" "fusion-run:fus-9" ev.post_id
;;

let test_emit_board_failure_is_best_effort () =
  with_isolated_base_path "fusion-board-best-effort" (fun base_dir ->
    let keeper = "bad/keeper" in
    let run_id = Printf.sprintf "fus-board-fail-%d" (Random.bits ()) in
    let resolved_answer = "BOARD-BEST-EFFORT-ANSWER" in
    Fusion_run_registry.register_running (Fusion_run_registry.global ()) ~run_id ~keeper
      ~preset:"unit-test" ~started_at:1.0;
    let result =
      Fusion_sink.emit ~base_dir ~keeper ~run_id ~question:"q" ~panel:[]
        ~judge:(Ok (judge_synthesis resolved_answer)) ~judges:[]
        ~judge_usage:Fusion_types.zero_usage
    in
    check bool "board failure does not fail emit" true (Result.is_ok result);
    (match Fusion_run_registry.get (Fusion_run_registry.global ()) ~run_id with
     | Some run ->
       (match run.Fusion_run_registry.status with
        | Fusion_run_registry.Completed { ok = true; _ } -> ()
        | Fusion_run_registry.Completed { ok = false; _ } ->
          fail "fusion run should complete with ok=true"
        | Fusion_run_registry.Running -> fail "fusion run should not remain running")
     | None -> fail "fusion run should remain visible");
    let messages = Keeper_chat_store.load ~base_dir ~keeper_name:keeper in
    (* Keeper_chat_store.encode_line auto-derives blocks from message content
       for assistant rows when the caller passes [blocks:None] (RFC-0235 P3),
       so [m.blocks] is not [None] here — the check is that no *Fusion* card
       (which would point at the board post that failed to be created) is
       among whatever blocks got auto-derived. *)
    let answer_without_card =
      List.exists
        (fun (m : Keeper_chat_store.chat_message) ->
           contains ~needle:resolved_answer m.content
           &&
           match m.blocks with
           | None -> true
           | Some blocks ->
             not
               (List.exists
                  (function
                    | Keeper_chat_blocks.Fusion _ -> true
                    | _ -> false)
                  blocks))
        messages
    in
    check bool "chat lane receives answer without fusion card block" true answer_without_card)
;;

let () =
  run
    "fusion_wake"
    [ ( "rfc-0266"
      , [ test_case "closed-sum helpers classify Fusion_completed" `Quick test_closed_sum_helpers
        ; test_case
            "fusion completion is actionable (non-empty, carries answer)"
            `Quick
            test_fusion_completion_is_actionable
        ; test_case
            "missing board_post_id falls back to fusion-run id"
            `Quick
            test_missing_board_post_id_fallback
        ; test_case
            "emit treats board post failure as best-effort"
            `Quick
            test_emit_board_failure_is_best_effort
        ; test_case
            "background completion is actionable (non-empty, carries output)"
            `Quick
            test_bg_completion_is_actionable
        ; test_case
            "background failure falls back to bg-run id"
            `Quick
            test_bg_failure_missing_board_post_id_fallback
        ; test_case
            "scheduled wake is actionable (non-empty, carries message)"
            `Quick
            test_scheduled_wake_is_actionable
        ] )
    ]
;;
