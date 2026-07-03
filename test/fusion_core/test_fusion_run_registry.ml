(* RFC-0266 Phase 2 — fusion run registry (in-progress + recent visibility).
   Pure in-memory state; tested on isolated [create ()] instances. *)

open Alcotest
module R = Fusion_run_registry

let status_running = function
  | R.Running -> true
  | R.Completed _ -> false
;;

let status_completed_ok = function
  | R.Completed { ok; _ } -> Some ok
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

let test_register_then_query () =
  let t = R.create () in
  R.register_running t ~run_id:"r1" ~keeper:"k" ~preset:"balanced" ~started_at:10.0;
  (match R.get t ~run_id:"r1" with
   | Some run ->
     check string "keeper" "k" run.R.keeper;
     check string "preset" "balanced" run.R.preset;
     check bool "is running" true (status_running run.R.status)
   | None -> fail "registered run must be retrievable");
  check int "one run tracked" 1 (List.length (R.list_runs t))
;;

let test_mark_completed () =
  let t = R.create () in
  R.register_running t ~run_id:"r1" ~keeper:"k" ~preset:"deep" ~started_at:1.0;
  R.mark_completed t ~run_id:"r1" ~ok:true ();
  (match R.get t ~run_id:"r1" with
   | Some run -> check (option bool) "completed ok=true" (Some true) (status_completed_ok run.R.status)
   | None -> fail "run should still be tracked after completion");
  (* a failed completion records ok=false, not a drop *)
  R.register_running t ~run_id:"r2" ~keeper:"k" ~preset:"deep" ~started_at:2.0;
  R.mark_completed t ~run_id:"r2" ~ok:false ();
  match R.get t ~run_id:"r2" with
  | Some run -> check (option bool) "completed ok=false" (Some false) (status_completed_ok run.R.status)
  | None -> fail "failed run must remain visible as Completed{ok=false}"
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
  R.register_running t ~run_id ~keeper:"k" ~preset:"deep" ~started_at:3.0;
  try
    if finalize_first then R.mark_completed t ~run_id ~ok:false ();
    raise Exit (* the suspending append re-propagates Cancelled here *)
  with
  | Exit -> ()
;;

let test_finalize_before_suspend_keeps_completed () =
  (* clean: mark_completed precedes the raising step -> run is Completed{ok=false}
     even though the notification step never ran. This is the post-#21821 order. *)
  let t = R.create () in
  simulate_failure_path ~finalize_first:true t ~run_id:"clean";
  (match R.get t ~run_id:"clean" with
   | Some run ->
     check (option bool) "finalize-before-raise -> Completed{ok=false}" (Some false)
       (status_completed_ok run.R.status)
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
  R.mark_completed t ~run_id:"ghost" ~ok:true ();
  check int "unknown run_id does not create an entry" 0 (List.length (R.list_runs t))
;;

let test_list_newest_first () =
  let t = R.create () in
  R.register_running t ~run_id:"old" ~keeper:"k" ~preset:"p" ~started_at:1.0;
  R.register_running t ~run_id:"new" ~keeper:"k" ~preset:"p" ~started_at:9.0;
  match R.list_runs t with
  | first :: _ -> check string "newest started_at first" "new" first.R.run_id
  | [] -> fail "expected runs"
;;

(* prune invariant: Running survives a flood of completed; oldest completed are
   evicted while the newest are kept (newest-first retention). *)
let test_prune_keeps_running_and_recent () =
  let t = R.create () in
  R.register_running t ~run_id:"active" ~keeper:"k" ~preset:"p" ~started_at:1000.0;
  for i = 0 to 99 do
    let id = Printf.sprintf "c%d" i in
    R.register_running t ~run_id:id ~keeper:"k" ~preset:"p" ~started_at:(float_of_int i);
    R.mark_completed t ~run_id:id ~ok:true ()
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
   keeper tool. "failed" (ok=false) must never collapse into "completed". *)
let test_status_label () =
  check string "running label" "running" (R.status_label R.Running);
  check string "completed label" "completed" (R.status_label (R.Completed { ok = true; failure = None; failure_code = None }));
  check string "failed label" "failed" (R.status_label
       (R.Completed
          { ok = false
          ; failure = Some "judge failed"
          ; failure_code = Some "parse_error"
          }))
;;

(* Phase 4: run_to_yojson is the one per-run serializer for every fusion-run
   surface — the field set and the status label are asserted here so a drift
   between the HTTP list, the SSE delta, and the tool is caught at the source. *)
let test_run_to_yojson_shape () =
  let t = R.create () in
  R.register_running t ~run_id:"r-ser" ~keeper:"kx" ~preset:"deep" ~started_at:42.0;
  R.mark_completed t ~run_id:"r-ser"
    ~failure:"fusion aborted: 0 of 3 panels answered, preset requires at least 1"
    ~failure_code:"panels_unavailable" ~ok:false ();
  match R.get t ~run_id:"r-ser" with
  | None -> fail "run must be present"
  | Some run ->
    let j = R.run_to_yojson run in
    check string "run_id" "r-ser" (yojson_str j "run_id");
    check string "keeper" "kx" (yojson_str j "keeper");
    check string "preset" "deep" (yojson_str j "preset");
    check string "status label (ok=false -> failed)" "failed" (yojson_str j "status");
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
  R.register_running t ~run_id:"r-ok" ~keeper:"kx" ~preset:"deep" ~started_at:1.0;
  R.mark_completed t ~run_id:"r-ok" ~ok:true ();
  match R.get t ~run_id:"r-ok" with
  | None -> fail "run must be present"
  | Some run ->
    let j = R.run_to_yojson run in
    check bool "no error field on success" true (Option.is_none (yojson_field j "error"));
    check bool "no failure_code field on success" true
      (Option.is_none (yojson_field j "failure_code"))
;;

let () =
  run
    "fusion_run_registry"
    [ ( "rfc-0266-phase2"
      , [ test_case "register then query" `Quick test_register_then_query
        ; test_case "mark completed (ok true/false)" `Quick test_mark_completed
        ; test_case
            "finalize before suspend keeps Completed (buggy order leaks Running)"
            `Quick
            test_finalize_before_suspend_keeps_completed
        ; test_case "mark unknown run_id is a no-op" `Quick test_mark_unknown_is_noop
        ; test_case "list_runs is newest-first" `Quick test_list_newest_first
        ; test_case "prune keeps Running + recent completed" `Quick test_prune_keeps_running_and_recent
        ] )
    ; ( "rfc-0266-phase4"
      , [ test_case "status_label vocabulary" `Quick test_status_label
        ; test_case "run_to_yojson shape + label" `Quick test_run_to_yojson_shape
        ; test_case "run_to_yojson success omits failure fields" `Quick
            test_run_to_yojson_success_has_no_failure_fields
        ] )
    ]
;;
