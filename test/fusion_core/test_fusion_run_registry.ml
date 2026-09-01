(* RFC-0266 Phase 2 — fusion run registry (in-progress + recent visibility).
   Pure in-memory state; tested on isolated [create ()] instances. *)

open Alcotest
module R = Fusion_run_registry

let status_running = function
  | R.Running -> true
  | R.Completed _ -> false
;;

let status_succeeded = function
  | R.Completed (R.Succeeded | R.Succeeded_with_summary _) -> Some true
  | R.Completed (R.Failed _) -> Some false
  | R.Running -> None
;;

let yojson_field j k =
  match j with
  | `Assoc l -> List.assoc_opt k l
  | _ -> None
;;

let yojson_str j k =
  match yojson_field j k with
  | Some (`String s) -> s
  | _ -> Printf.ksprintf failwith "missing string field %s" k
;;

let yojson_int j k =
  match yojson_field j k with
  | Some (`Int value) -> value
  | _ -> Printf.ksprintf failwith "missing int field %s" k
;;

let test_register_then_query () =
  let t = R.create () in
  R.register_running t ~run_id:"r1" ~keeper:"k" ~preset:"balanced" ~topology:Fusion_types.Simple ~started_at:10.0;
  (match R.get t ~run_id:"r1" with
   | Some run ->
     check string "keeper" "k" run.R.keeper;
     check string "preset" "balanced" run.R.preset;
     check bool "is running" true (status_running run.R.status);
     check bool "accepted progress is installed" true
       (match run.R.progress with
        | Some R.Progress_accepted -> true
        | Some _ | None -> false)
   | None -> fail "registered run must be retrievable");
  check int "one run tracked" 1 (List.length (R.list_runs t))
;;

let test_mark_completed () =
  let t = R.create () in
  R.register_running t ~run_id:"r1" ~keeper:"k" ~preset:"deep" ~topology:Fusion_types.Simple ~started_at:1.0;
  R.mark_completed t ~run_id:"r1" ~outcome:R.Succeeded;
  (match R.get t ~run_id:"r1" with
   | Some run -> check (option bool) "completed successfully" (Some true) (status_succeeded run.R.status)
   | None -> fail "run should still be tracked after completion");
  (* a failed completion remains visible, not dropped *)
  R.register_running t ~run_id:"r2" ~keeper:"k" ~preset:"deep" ~topology:Fusion_types.Simple ~started_at:2.0;
  R.mark_completed t ~run_id:"r2"
    ~outcome:(R.Failed { reason = "judge failed"; code = "judge_failed" });
  match R.get t ~run_id:"r2" with
  | Some run -> check (option bool) "completed with failure" (Some false) (status_succeeded run.R.status)
  | None -> fail "failed run must remain visible as a typed completion"
;;

(* Models the finalize-before-suspend invariant that fusion_tool.ml
   [append_chat_failure] relies on after #21821. The real failure path does
   [mark_completed] then a *suspending* chat append (Eio file I/O) that
   re-raises [Eio.Cancel.Cancelled] on shutdown / sibling [Switch.fail]. The
   registry does not distinguish which exception interrupts the append — only
   the *position* of [mark_completed] relative to the raising step decides
   whether the run is finalized or leaks. [Exit] therefore faithfully stands in
   for that raise. [~finalize_first] is exactly the fix vs the bug. *)
let simulate_failure_path ~finalize_first t ~run_id =
  R.register_running t ~run_id ~keeper:"k" ~preset:"deep" ~topology:Fusion_types.Simple ~started_at:3.0;
  try
    if finalize_first
    then
      R.mark_completed t ~run_id
        ~outcome:(R.Failed { reason = "delivery interrupted"; code = "interrupted" });
    raise Exit (* the suspending append re-propagates Cancelled here *)
  with
  | Exit -> ()
;;

let test_finalize_before_suspend_keeps_completed () =
  (* clean: mark_completed precedes the raising step -> run is a failed completion
     even though the notification step never ran. This is the post-#21821 order. *)
  let t = R.create () in
  simulate_failure_path ~finalize_first:true t ~run_id:"clean";
  (match R.get t ~run_id:"clean" with
   | Some run ->
     check (option bool) "finalize-before-raise -> failed completion" (Some false)
       (status_succeeded run.R.status)
   | None -> fail "run must remain visible");
  (* buggy: mark_completed would follow the raising step -> it never runs and the
     run leaks as Running forever (prune never evicts Running). This is the state
     #21821 prevents; the contrast proves the ordering is load-bearing, not
     incidental — mirrors the TLA+ clean/buggy bug-model at the unit level. *)
  let t = R.create () in
  simulate_failure_path ~finalize_first:false t ~run_id:"buggy";
  match R.get t ~run_id:"buggy" with
  | Some run ->
    check bool "finalize-after-raise leaks Running (the bug)" true
      (status_running run.R.status)
  | None -> fail "run must remain visible"
;;

let test_mark_unknown_is_noop () =
  let t = R.create () in
  R.mark_completed t ~run_id:"ghost" ~outcome:R.Succeeded;
  check int "unknown run_id does not create an entry" 0 (List.length (R.list_runs t))
;;

let test_progress_is_typed_and_terminal_safe () =
  let t = R.create () in
  R.register_running t ~run_id:"r-progress" ~keeper:"k" ~preset:"trio"
    ~topology:Fusion_types.Simple ~started_at:4.0;
  R.mark_progress t ~run_id:"r-progress"
    ~progress:(R.Progress_judge_running { expected = 3; answered = 2; failed = 1 });
  (match R.get t ~run_id:"r-progress" with
   | Some { R.progress = Some (R.Progress_judge_running counts); _ } ->
     check int "judge expected" 3 counts.expected;
     check int "judge answered" 2 counts.answered;
     check int "judge failed" 1 counts.failed
   | Some _ -> fail "running run must retain typed judge progress"
   | None -> fail "running run disappeared");
  R.mark_completed t ~run_id:"r-progress"
    ~outcome:
      (R.Succeeded_with_summary
         { decision = R.decision_preview_of_string "recommend — ship"
         ; summary = "Two panels support it."
         });
  R.mark_progress t ~run_id:"r-progress"
    ~progress:(R.Progress_panel_running { expected = 99 });
  match R.get t ~run_id:"r-progress" with
  | Some
      { R.status =
          R.Completed
            (R.Succeeded_with_summary { decision; summary })
      ; progress = None
      ; _
      } ->
    check string "decision remains terminal" "recommend — ship"
      (R.decision_preview_to_string decision);
    check string "summary remains terminal" "Two panels support it." summary
  | Some _ -> fail "terminal progress update must be ignored"
  | None -> fail "completed run disappeared"
;;

let test_decision_preview_bound () =
  let flattened =
    R.decision_preview_to_string
      (R.decision_preview_of_string "  line one\nline\ttwo\r  ")
  in
  check string "whitespace flattens and trims" "line one line two" flattened;
  let long = String.concat " " (List.init 60 (fun _ -> "판정")) in
  let preview = R.decision_preview_to_string (R.decision_preview_of_string long) in
  check bool "long input is capped" true
    (String.length preview <= R.decision_preview_max_bytes);
  check bool "truncation is marked" true
    (String.length preview >= 3
     && String.sub preview (String.length preview - 3) 3 = "...");
  check string "re-applying the constructor is the identity" preview
    (R.decision_preview_to_string (R.decision_preview_of_string preview))
;;

let test_list_newest_first () =
  let t = R.create () in
  R.register_running t ~run_id:"old" ~keeper:"k" ~preset:"p" ~topology:Fusion_types.Simple ~started_at:1.0;
  R.register_running t ~run_id:"new" ~keeper:"k" ~preset:"p" ~topology:Fusion_types.Simple ~started_at:9.0;
  match R.list_runs t with
  | first :: _ -> check string "newest started_at first" "new" first.R.run_id
  | [] -> fail "expected runs"
;;

(* prune invariant: Running survives a flood of completed; oldest completed are
   evicted while the newest are kept (newest-first retention). *)
let test_prune_keeps_running_and_recent () =
  let t = R.create () in
  R.register_running t ~run_id:"active" ~keeper:"k" ~preset:"p" ~topology:Fusion_types.Simple ~started_at:1000.0;
  for i = 0 to 99 do
    let id = Printf.sprintf "c%d" i in
    R.register_running t ~run_id:id ~keeper:"k" ~preset:"p" ~topology:Fusion_types.Simple ~started_at:(float_of_int i);
    R.mark_completed t ~run_id:id ~outcome:R.Succeeded
  done;
  (* the Running run is never evicted *)
  (match R.get t ~run_id:"active" with
   | Some run -> check bool "Running survived the flood" true (status_running run.R.status)
   | None -> fail "Running run must never be pruned");
  (* the most recent completed is retained, the oldest is evicted *)
  check bool "newest completed retained" true (Option.is_some (R.get t ~run_id:"c99"));
  check bool "oldest completed evicted" true (Option.is_none (R.get t ~run_id:"c0"));
  (* total is bounded (retention cap + the one Running) *)
  check bool "registry is bounded under flood" true (List.length (R.list_runs t) <= 65)
;;

(* Phase 4: the shared status vocabulary used by the dashboard route + SSE +
   keeper tool. A typed failure must never collapse into "completed". *)
let test_status_label () =
  check string "running label" "running" (R.status_label R.Running);
  check string "completed label" "completed" (R.status_label (R.Completed R.Succeeded));
  check string "failed label" "failed" (R.status_label
       (R.Completed
          (R.Failed { reason = "judge failed"; code = "parse_error" })))
;;

(* Phase 4: run_to_yojson is the one per-run serializer for every fusion-run
   surface — the field set and the status label are asserted here so a drift
   between the HTTP list, the SSE delta, and the tool is caught at the source. *)
let test_run_to_yojson_shape () =
  let t = R.create () in
  R.register_running t ~run_id:"r-ser" ~keeper:"kx" ~preset:"deep" ~topology:Fusion_types.Simple ~started_at:42.0;
  R.mark_completed t ~run_id:"r-ser"
    ~outcome:
      (R.Failed
         { reason = "fusion aborted: 0 of 3 panels answered, preset requires at least 1"
         ; code = "panels_unavailable"
         });
  match R.get t ~run_id:"r-ser" with
  | None -> fail "run must be present"
  | Some run ->
    let j = R.run_to_yojson run in
    check string "run_id" "r-ser" (yojson_str j "run_id");
    check string "keeper" "kx" (yojson_str j "keeper");
    check string "preset" "deep" (yojson_str j "preset");
    check string "typed failure status label" "failed" (yojson_str j "status");
    (match yojson_field j "started_at" with
     | Some (`Float f) -> check (float 0.001) "started_at" 42.0 f
     | _ -> fail "started_at must serialize as a float field");
    (* 실패 사유는 additive 필드로 실린다 — 상태 표면이 opaque "failed"가 되지
       않게 하는 2026-07-01 사고 회귀 가드. *)
    check string "error field carries failure reason"
      "fusion aborted: 0 of 3 panels answered, preset requires at least 1"
      (yojson_str j "error");
    check string "failure_code field" "panels_unavailable" (yojson_str j "failure_code")
;;

(* 성공 run에는 error/failure_code 필드가 없어야 한다(additive-only 계약). *)
let test_run_to_yojson_success_has_no_failure_fields () =
  let t = R.create () in
  R.register_running t ~run_id:"r-ok" ~keeper:"kx" ~preset:"deep" ~topology:Fusion_types.Simple ~started_at:1.0;
  R.mark_completed t ~run_id:"r-ok" ~outcome:R.Succeeded;
  match R.get t ~run_id:"r-ok" with
  | None -> fail "run must be present"
  | Some run ->
    let j = R.run_to_yojson run in
    check bool "no error field on success" true (Option.is_none (yojson_field j "error"));
    check bool "no failure_code field on success" true
      (Option.is_none (yojson_field j "failure_code"))
;;

let test_run_to_yojson_progress_and_summary () =
  let t = R.create () in
  R.register_running t ~run_id:"r-rich" ~keeper:"kx" ~preset:"trio"
    ~topology:Fusion_types.Simple ~started_at:5.0;
  R.mark_progress t ~run_id:"r-rich"
    ~progress:(R.Progress_computed { expected = 3; answered = 2; failed = 1 });
  let running = Option.get (R.get t ~run_id:"r-rich") |> R.run_to_yojson in
  check string "running stage" "computed" (yojson_str running "stage");
  (match yojson_field running "progress" with
   | Some (`Assoc _ as progress) ->
     check int "progress expected" 3 (yojson_int progress "panel_expected");
     check int "progress answered" 2 (yojson_int progress "panel_answered");
     check int "progress failed" 1 (yojson_int progress "panel_failed")
   | Some _ | None -> fail "running progress must serialize as an object");
  R.mark_completed t ~run_id:"r-rich"
    ~outcome:
      (R.Succeeded_with_summary
         { decision = R.decision_preview_of_string "answer"
         ; summary = "Use the typed projection."
         });
  let completed = Option.get (R.get t ~run_id:"r-rich") |> R.run_to_yojson in
  check string "completed stage" "completed" (yojson_str completed "stage");
  check string "decision" "answer" (yojson_str completed "decision");
  check string "summary" "Use the typed projection."
    (yojson_str completed "summary");
  check bool "completed progress is null" true
    (yojson_field completed "progress" = Some `Null)
;;

let () =
  run
    "fusion_run_registry"
    [ ( "rfc-0266-phase2"
      , [ test_case "register then query" `Quick test_register_then_query
        ; test_case "mark completed with typed outcomes" `Quick test_mark_completed
        ; test_case
            "finalize before suspend keeps Completed (buggy order leaks Running)"
            `Quick
            test_finalize_before_suspend_keeps_completed
        ; test_case "mark unknown run_id is a no-op" `Quick test_mark_unknown_is_noop
        ; test_case "progress is typed and terminal-safe" `Quick
            test_progress_is_typed_and_terminal_safe
        ; test_case "decision preview constructor enforces the bound" `Quick
            test_decision_preview_bound
        ; test_case "list_runs is newest-first" `Quick test_list_newest_first
        ; test_case "prune keeps Running + recent completed" `Quick test_prune_keeps_running_and_recent
        ] )
    ; ( "rfc-0266-phase4"
      , [ test_case "status_label vocabulary" `Quick test_status_label
        ; test_case "run_to_yojson shape + label" `Quick test_run_to_yojson_shape
        ; test_case "run_to_yojson success omits failure fields" `Quick
            test_run_to_yojson_success_has_no_failure_fields
        ; test_case "run_to_yojson exposes progress and summary" `Quick
            test_run_to_yojson_progress_and_summary
        ] )
    ]
;;
